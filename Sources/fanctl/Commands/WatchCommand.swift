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
        feeds it through an EMA smoother, and slews fan RPM gradually toward
        the curve's target — both up and down. Releases fans to firmware-managed
        mode only after RPM has ramped down to --start-rpm and temperature has
        dropped --release-hysteresis °C below the lowest pivot.

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

    @Option(name: .long, help: "Max RPM change per tick. Lower = smoother and quieter, but slower thermal response.")
    var stepRpm: Double = 250

    @Option(name: .long, help: "RPM floor when first engaging forced mode and the value to ramp down to before releasing to auto.")
    var startRpm: Double = 1000

    @Option(name: .long, help: "Stay in forced mode until smoothed temp drops this many °C below the lowest pivot before releasing.")
    var releaseHysteresis: Double = 5

    @Option(name: .long, help: "EMA smoothing factor for temperature, 0..1. Lower = smoother, slower. 1.0 = no smoothing.")
    var smoothing: Double = 0.4

    @Flag(name: .long, help: "Print every tick, not just transitions.")
    var verbose: Bool = false

    func run() throws {
        // Swift's stdout switches to block-buffering when not a tty (e.g. when
        // launchd redirects to a file). Force line-buffering so per-tick logs
        // land immediately in /var/log/fanctl.log.
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)

        guard smoothing > 0, smoothing <= 1 else {
            throw ValidationError("--smoothing must be in (0, 1].")
        }
        guard stepRpm > 0 else {
            throw ValidationError("--step-rpm must be positive.")
        }

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
            stepRpm: stepRpm,
            startRpm: startRpm,
            releaseHysteresis: releaseHysteresis,
            smoothing: smoothing,
            verbose: verbose
        )
        WatchRuntime.shared = runtime

        let sigint  = installSignalHandler(SIGINT)
        let sigterm = installSignalHandler(SIGTERM)
        _ = sigint; _ = sigterm   // retain for the lifetime of run()

        print("fanctl watch  curve=\(spec)  fans=\(fanCount)  sensors=\(sensors.count)  interval=\(Int(interval))s  step=\(Int(stepRpm))  start=\(Int(startRpm))  release-hyst=\(releaseHysteresis)°C  smoothing=\(smoothing)")
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
    private let stepRpm: Double
    private let startRpm: Double
    private let releaseHysteresis: Double
    private let smoothing: Double
    private let verbose: Bool
    private let lowestPivot: Double

    // nil = fans are released to firmware auto. Non-nil = last RPM we forced.
    private var currentRPM: Double?
    private var smoothedTemp: Double?

    init(smc: SMCConnection, fc: FanController, fanCount: Int,
         curve: FanCurve, sensors: [String],
         stepRpm: Double, startRpm: Double,
         releaseHysteresis: Double, smoothing: Double, verbose: Bool) {
        self.smc = smc
        self.fc = fc
        self.fanCount = fanCount
        self.curve = curve
        self.sensors = sensors
        self.stepRpm = stepRpm
        self.startRpm = startRpm
        self.releaseHysteresis = releaseHysteresis
        self.smoothing = smoothing
        self.verbose = verbose
        self.lowestPivot = curve.pivots.first?.temp ?? 0
    }

    func tick() {
        var rawMax = -Double.infinity
        for name in sensors {
            guard let (info, data) = try? smc.readBytes(key: name),
                  let d = SMCValue.decode(type: info.dataType, bytes: data).asDouble,
                  d > -50, d < 120 else { continue }
            if d > rawMax { rawMax = d }
        }
        guard rawMax > -Double.infinity else {
            if verbose { log("no temps available this tick") }
            return
        }

        let temp: Double
        if let prev = smoothedTemp {
            temp = smoothing * rawMax + (1 - smoothing) * prev
        } else {
            temp = rawMax
        }
        smoothedTemp = temp

        switch curve.evaluate(temp: temp) {
        case .auto:
            handleAutoTarget(temp: temp, rawMax: rawMax)
        case .rpm(let curveTarget):
            handleRpmTarget(curveTarget, temp: temp, rawMax: rawMax)
        }
    }

    private func handleAutoTarget(temp: Double, rawMax: Double) {
        guard let cur = currentRPM else {
            if verbose { logTemp(temp, rawMax, "auto (idle)") }
            return
        }
        // Ramp down toward startRpm; release once we reach the floor and the
        // smoothed temp confirms we're well below the lowest pivot.
        let next = max(cur - stepRpm, startRpm)
        if next <= startRpm && temp < lowestPivot - releaseHysteresis {
            writeAll { try fc.auto(id: $0) }
            currentRPM = nil
            logTemp(temp, rawMax, "released to auto from \(Int(cur)) RPM")
            return
        }
        if next != cur {
            writeAll { try fc.force(id: $0, rpm: next) }
            currentRPM = next
            logTemp(temp, rawMax, "ramping down \(Int(cur)) → \(Int(next)) RPM")
        } else if verbose {
            logTemp(temp, rawMax, "holding \(Int(cur)) RPM (waiting for temp to drop below \(Int(lowestPivot - releaseHysteresis))°C)")
        }
    }

    private func handleRpmTarget(_ curveTarget: Double, temp: Double, rawMax: Double) {
        guard let cur = currentRPM else {
            // First crossing into the curve — start gentle at startRpm.
            let initial = min(startRpm, curveTarget)
            writeAll { try fc.force(id: $0, rpm: initial) }
            currentRPM = initial
            logTemp(temp, rawMax, "engaging at \(Int(initial)) RPM (curve wants \(Int(curveTarget)))")
            return
        }
        let next: Double
        if cur < curveTarget {
            next = min(cur + stepRpm, curveTarget)
        } else if cur > curveTarget {
            next = max(cur - stepRpm, curveTarget)
        } else {
            next = cur
        }
        if next != cur {
            writeAll { try fc.force(id: $0, rpm: next) }
            currentRPM = next
            let arrow = next > cur ? "↑" : "↓"
            logTemp(temp, rawMax, "\(arrow) \(Int(cur)) → \(Int(next)) RPM (target \(Int(curveTarget)))")
        } else if verbose {
            logTemp(temp, rawMax, "holding \(Int(cur)) RPM (at target)")
        }
    }

    func releaseAll() {
        writeAll { try fc.auto(id: $0) }
        currentRPM = nil
    }

    private func writeAll(_ op: (Int) throws -> Void) {
        for i in 0..<fanCount { _ = try? op(i) }
    }

    private func logTemp(_ smoothed: Double, _ raw: Double, _ msg: String) {
        log(String(format: "%.1f°C (raw %.1f) → %@", smoothed, raw, msg))
    }

    private func log(_ msg: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        print("[\(fmt.string(from: Date()))] \(msg)")
    }
}
