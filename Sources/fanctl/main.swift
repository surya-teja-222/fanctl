import ArgumentParser
import Foundation

struct Fanctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fanctl",
        abstract: "Apple Silicon fan control via the SMC interface.",
        subcommands: [
            ListCommand.self, GetCommand.self, TempsCommand.self,
            SetCommand.self, FanCommand.self, MFCCommand.self,
        ]
    )
}

Fanctl.main()
