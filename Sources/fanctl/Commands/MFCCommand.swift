import ArgumentParser
import Foundation

struct MFCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mfc",
        abstract: "Drive the Macs Fan Control privileged helper via XPC.",
        discussion: """
        Direct SMC writes are kernel-gated on Apple Silicon. As a workaround,
        fanctl can pipe write commands through MFC's already-installed
        privileged helper. The helper may reject our connection due to its
        client-code-signing check; this command surfaces the actual error.
        """,
        subcommands: [Probe.self, Write.self]
    )

    struct Probe: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "probe",
            abstract: "Try to connect + open. Tells us if the helper accepts our code-signing."
        )
        func run() throws {
            let c = MFCHelperClient()
            print("Connected to com.crystalidea.macsfancontrol.smcwrite. Sending open...")
            try c.open()
            print("open OK. Helper accepted our connection.")
            try c.close()
            print("close OK.")
        }
    }

    struct Write: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "write",
            abstract: "Write an SMC key via the MFC helper (e.g. F0Tg, F0Md)."
        )
        @Argument(help: "4-char SMC key.") var key: String
        @Argument(help: "Numeric value (encoded according to key's SMC type).") var value: Double

        func run() throws {
            // Read keyInfo via our direct connection (reads work).
            let smc = try SMCConnection()
            let info = try smc.keyInfo(key: key)
            let bytes = try SMCEncode.bytes(forType: info.dataType, double: value)

            let c = MFCHelperClient()
            try c.open()
            try c.write(key: key, payload: bytes)
            try c.close()

            // Read back to confirm
            let (_, after) = try smc.readBytes(key: key)
            let v = SMCValue.decode(type: info.dataType, bytes: after)
            print("\(key)  type=\(info.dataType)  wrote=\(value)  read-back=\(v.display)")
        }
    }
}
