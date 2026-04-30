import ArgumentParser
import Foundation

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Read a single SMC key by 4-char code."
    )

    @Argument(help: "4-char SMC key, e.g. F0Ac, TC0P, #KEY")
    var key: String

    @Flag(name: .long, help: "Print raw payload bytes alongside the decoded value.")
    var raw: Bool = false

    func run() throws {
        let smc = try SMCConnection()
        let (info, data) = try smc.readBytes(key: key)
        let val = SMCValue.decode(type: info.dataType, bytes: data)
        print("\(key)  type=\(info.dataType) size=\(info.dataSize)  \(val.display)")
        if raw {
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("  raw: \(hex)")
        }
    }
}
