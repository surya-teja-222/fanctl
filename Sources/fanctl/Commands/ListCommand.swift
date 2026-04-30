import ArgumentParser
import Foundation

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Enumerate SMC keys, optionally filtered by prefix or substring."
    )

    @Option(name: .long, help: "Only show keys with this prefix (e.g. F, T, V).")
    var prefix: String?

    @Option(name: .long, help: "Only show keys whose names contain this substring.")
    var contains: String?

    @Flag(name: .long, help: "Also print the live decoded value for each key.")
    var values: Bool = false

    @Flag(name: .long, help: "Names only. Skip type/size lookup (much faster).")
    var fast: Bool = false

    func run() throws {
        let smc = try SMCConnection()
        let predicate = makePredicate(prefix: prefix, contains: contains)
        let keys = try KeyEnumerator.all(smc: smc, matching: predicate, withInfo: !fast)
        print("Found \(keys.count) keys")
        for k in keys {
            if fast {
                print("  \(k.name)")
                continue
            }
            let info = k.info!
            var line = "  \(k.name.padding(toLength: 5, withPad: " ", startingAt: 0))"
                + "  type=\(info.dataType.padding(toLength: 5, withPad: " ", startingAt: 0))"
                + " size=\(info.dataSize)"
            if values {
                if let (_, data) = try? smc.readBytes(key: k.name) {
                    line += "  \(SMCValue.decode(type: info.dataType, bytes: data).display)"
                } else {
                    line += "  <read failed>"
                }
            }
            print(line)
        }
    }

    private func makePredicate(prefix: String?, contains: String?) -> ((String) -> Bool)? {
        var checks: [(String) -> Bool] = []
        if let p = prefix   { checks.append { $0.hasPrefix(p) } }
        if let c = contains { checks.append { $0.contains(c) } }
        guard !checks.isEmpty else { return nil }
        return { name in checks.allSatisfy { $0(name) } }
    }
}
