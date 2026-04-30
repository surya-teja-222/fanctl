import ArgumentParser
import Foundation

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Raw write of a numeric value to an SMC key (via the MFC helper)."
    )

    @Argument(help: "4-char SMC key, e.g. F0Tg")
    var key: String

    @Argument(help: "Numeric value (encoded according to the key's SMC type).")
    var value: Double

    @Flag(name: .long, help: "Required for any key not starting with F (fans). Other keys are gated to prevent foot-guns.")
    var force: Bool = false

    func run() throws {
        if !key.hasPrefix("F") && !force {
            throw ValidationError("Refusing to write non-fan key '\(key)' without --force.")
        }
        let smc = try SMCConnection()
        let info = try smc.keyInfo(key: key)
        let bytes = try SMCEncode.bytes(forType: info.dataType, double: value)

        let helper = MFCHelperClient()
        try helper.open()
        try helper.write(key: key, payload: bytes)
        try helper.close()

        let (_, after) = try smc.readBytes(key: key)
        let v = SMCValue.decode(type: info.dataType, bytes: after)
        print("\(key)  type=\(info.dataType)  wrote=\(value)  read-back=\(v.display)")
    }
}
