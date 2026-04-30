import Foundation

struct EnumeratedKey {
    let name: String
    let info: SMCKeyInfo?
}

enum KeyEnumerator {
    /// Walks all SMC keys via READ_INDEX, optionally filtered. With `withInfo:
    /// true`, fetches keyInfo per key (needed for typed display, slower for
    /// large enumerations). With `false`, callers can lazily fetch info via
    /// `smc.keyInfo(key:)` which is cached.
    static func all(smc: SMCConnection,
                    matching: ((String) -> Bool)? = nil,
                    withInfo: Bool = true) throws -> [EnumeratedKey] {
        let count = try smc.keyCount()
        var out: [EnumeratedKey] = []
        out.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let name = try? smc.keyAt(index: i) else { continue }
            if let pred = matching, !pred(name) { continue }
            let info = withInfo ? (try? smc.keyInfo(key: name)) : nil
            if withInfo && info == nil { continue }
            out.append(EnumeratedKey(name: name, info: info))
        }
        return out
    }
}
