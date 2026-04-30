import ArgumentParser
import Foundation

private func formatFan(_ s: FanState) -> String {
    let modeStr = s.mode == 0 ? "auto" : "forced"
    return "fan \(s.id): mode=\(modeStr)  actual=\(Int(s.actual)) RPM  target=\(Int(s.target))  min=\(Int(s.min))  max=\(Int(s.max))"
}

struct FanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fan",
        abstract: "Read or control a single fan.",
        subcommands: [Show.self, Rpm.self, Auto.self, All.self]
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print current state of one fan."
        )
        @Argument(help: "Fan id (0..N-1).") var id: Int

        func run() throws {
            let fc = FanController(smc: try SMCConnection())
            print(formatFan(try fc.read(id: id)))
        }
    }

    struct All: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "all",
            abstract: "Print state of every fan."
        )
        func run() throws {
            let fc = FanController(smc: try SMCConnection())
            let n = try fc.count()
            print("Fans: \(n)")
            for i in 0..<n {
                print("  " + formatFan(try fc.read(id: i)))
            }
        }
    }

    struct Rpm: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rpm",
            abstract: "Force a fan to a specific RPM (sets mode=forced)."
        )
        @Argument(help: "Fan id.") var id: Int
        @Argument(help: "Target RPM.") var rpm: Double
        @Flag(name: .long, help: "Allow RPMs below the firmware's recommended Mn floor.")
        var below: Bool = false

        func run() throws {
            let fc = FanController(smc: try SMCConnection())
            try fc.force(id: id, rpm: rpm, forceBelowMin: below)
            // Read-back is stale until firmware applies (~5–10s). Report what we
            // commanded and let the user follow up with `fanctl fan show`.
            print("fan \(id) → forced, requested \(Int(rpm)) RPM (firmware will converge over ~10s)")
        }
    }

    struct Auto: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "auto",
            abstract: "Release a fan back to firmware-managed auto mode."
        )
        @Argument(help: "Fan id, or 'all'.") var idOrAll: String

        func run() throws {
            let fc = FanController(smc: try SMCConnection())
            if idOrAll == "all" {
                let n = try fc.count()
                for i in 0..<n { try fc.auto(id: i) }
                print("All \(n) fans → auto")
                return
            }
            guard let id = Int(idOrAll) else {
                throw ValidationError("Expected fan id (integer) or 'all'.")
            }
            try fc.auto(id: id)
            print("fan \(id) → auto")
        }
    }
}
