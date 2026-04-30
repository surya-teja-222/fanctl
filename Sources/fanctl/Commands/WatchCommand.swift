import ArgumentParser
import Foundation

enum CurvePreset: String, ExpressibleByArgument, CaseIterable {
    case cool, balanced, aggressive

    var spec: String {
        switch self {
        case .cool:       return "50:2500,65:4500,80:max"
        case .balanced:   return "60:2500,75:4500,85:max"
        case .aggressive: return "45:3000,60:5000,75:max"
        }
    }
}

struct WatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Continuously match fan RPM to a temperature curve.",
        discussion: """
        Polls all temperature sensors every --interval seconds, picks the max,
        and sets all fans to the curve's RPM at that temperature. Releases
        fans to firmware-managed mode when temp drops below the lowest pivot.

        Presets:
          cool        50:2500,65:4500,80:max   (recommended for "always cool")
          balanced    60:2500,75:4500,85:max   (quieter at light load)
          aggressive  45:3000,60:5000,75:max   (always audible, max cooling)

        Press Ctrl-C to release fans to auto and exit cleanly.
        """
    )

    @Option(name: .long, help: "Built-in curve preset.")
    var preset: CurvePreset = .cool

    @Option(name: .long, help: "Override preset with explicit pivots: \"<°C>:<rpm>,...,<°C>:max\".")
    var curve: String?

    @Option(name: .long, help: "Poll interval (seconds).")
    var interval: Double = 5

    @Option(name: .long, help: "Skip a write if the new RPM differs from the current target by less than this.")
    var hysteresis: Double = 200

    @Flag(name: .long, help: "Print every tick, not just transitions.")
    var verbose: Bool = false

    func run() throws {
        let smc = try SMCConnection()
        let fc = FanController(smc: smc)
        let fanCount = try fc.count()
        guard fanCount > 0 else {
            throw ValidationError("No fans found.")
        }

        let firstFan = try fc.read(id: 0)
        let spec = curve ?? preset.spec
        let parsed = try FanCurve.parse(spec, maxRPM: firstFan.max)

        print("Discovering temperature sensors...")
        let sensors = try discoverValidTempKeys(smc: smc)
        guard !sensors.isEmpty else {
            throw ValidationError("No usable temperature sensors found.")
        }

        let runtime = WatchRuntime(
            smc: smc, fc: fc, fanCount: fanCount,
            curve: parsed, sensors: sensors,
            hysteresis: hysteresis, verbose: verbose
        )
        WatchRuntime.shared = runtime

        let sigint  = installSignalHandler(SIGINT)
        let sigterm = installSignalHandler(SIGTERM)
        _ = sigint; _ = sigterm   // retain for the lifetime of run()

        print("fanctl watch  curve=\(spec)  fans=\(fanCount)  sensors=\(sensors.count)  interval=\(Int(interval))s")
        print("Ctrl-C to release and exit.\n")

        runtime.tick()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { runtime.tick() }
        timer.resume()
        _ = timer

        dispatchMain()
    }

    private func installSignalHandler(_ sig: Int32) -> DispatchSourceSignal {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            print("\nReleasing fans to auto...")
            WatchRuntime.shared?.releaseAll()
            Foundation.exit(0)
        }
        src.resume()
        signal(sig, SIG_IGN)
        return src
    }

    private func discoverValidTempKeys(smc: SMCConnection) throws -> [String] {
        let keys = try KeyEnumerator.all(smc: smc,
                                         matching: { $0.hasPrefix("T") },
                                         withInfo: false)
        var valid: [String] = []
        for k in keys {
            guard let (info, data) = try? smc.readBytes(key: k.name),
                  let d = SMCValue.decode(type: info.dataType, bytes: data).asDouble,
                  d > -50, d < 120 else { continue }
            valid.append(k.name)
        }
        return valid
    }
}

final class WatchRuntime {
    static var shared: WatchRuntime?

    private let smc: SMCConnection
    private let fc: FanController
    private let fanCount: Int
    private let curve: FanCurve
    private let sensors: [String]
    private let hysteresis: Double
    private let verbose: Bool

    private var lastTarget: Double?
    private var lastWasAuto = true

    init(smc: SMCConnection, fc: FanController, fanCount: Int,
         curve: FanCurve, sensors: [String], hysteresis: Double, verbose: Bool) {
        self.smc = smc
        self.fc = fc
        self.fanCount = fanCount
        self.curve = curve
        self.sensors = sensors
        self.hysteresis = hysteresis
        self.verbose = verbose
    }

    func tick() {
        var maxTemp = -Double.infinity
        for name in sensors {
            guard let (info, data) = try? smc.readBytes(key: name),
                  let d = SMCValue.decode(type: info.dataType, bytes: data).asDouble,
                  d > -50, d < 120 else { continue }
            if d > maxTemp { maxTemp = d }
        }
        guard maxTemp > -Double.infinity else {
            if verbose { log("no temps available this tick") }
            return
        }

        switch curve.evaluate(temp: maxTemp) {
        case .auto:
            if !lastWasAuto {
                writeAll { try fc.auto(id: $0) }
                lastWasAuto = true
                lastTarget = nil
                log(String(format: "%.1f°C → auto (released)", maxTemp))
            } else if verbose {
                log(String(format: "%.1f°C → auto", maxTemp))
            }

        case .rpm(let target):
            let needWrite = lastWasAuto
                || lastTarget == nil
                || abs(target - (lastTarget ?? 0)) > hysteresis
            if needWrite {
                writeAll { try fc.force(id: $0, rpm: target) }
                lastWasAuto = false
                lastTarget = target
                log(String(format: "%.1f°C → %d RPM", maxTemp, Int(target)))
            } else if verbose {
                log(String(format: "%.1f°C → %d (holding %d)", maxTemp, Int(target), Int(lastTarget!)))
            }
        }
    }

    func releaseAll() {
        writeAll { try fc.auto(id: $0) }
    }

    private func writeAll(_ op: (Int) throws -> Void) {
        for i in 0..<fanCount { _ = try? op(i) }
    }

    private func log(_ msg: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        print("[\(fmt.string(from: Date()))] \(msg)")
    }
}
