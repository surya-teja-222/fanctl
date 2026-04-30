import ArgumentParser
import Foundation

struct TempsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "temps",
        abstract: "Print all temperature sensors and their current readings."
    )

    @Option(name: .long, help: "Hide sensors below this °C (filters out broken/unused entries).")
    var min: Double = -50

    func run() throws {
        let smc = try SMCConnection()
        // Temperature keys start with 'T'; readBytes will fetch keyInfo
        // (and cache it) so we skip per-key info in the enumerator.
        let keys = try KeyEnumerator.all(smc: smc,
                                         matching: { $0.hasPrefix("T") },
                                         withInfo: false)

        var rows: [(name: String, value: Double, type: String)] = []
        for k in keys {
            guard let (info, data) = try? smc.readBytes(key: k.name) else { continue }
            let v = SMCValue.decode(type: info.dataType, bytes: data)
            guard let d = v.asDouble else { continue }
            // Reasonable temperature range: -50 to 200. Outside is junk.
            if d < min || d > 200 { continue }
            rows.append((k.name, d, info.dataType))
        }

        rows.sort { $0.value > $1.value }
        print("Found \(rows.count) temperature readings (filtered, sorted hottest first):\n")
        for r in rows {
            print(String(format: "  %@  %6.2f °C  (%@)", r.name, r.value, r.type))
        }
    }
}
