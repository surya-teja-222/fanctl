import Foundation

// 4-character codes packed big-endian into a UInt32. SMC keys ("F0Tg",
// "TC0P", "#KEY") and type tags ("ui32", "flt ") both use this layout.
enum FourCC {
    static func encode(_ s: String) throws -> UInt32 {
        let bytes = Array(s.utf8)
        guard bytes.count == 4 else {
            throw SMCError.invalidKey(s)
        }
        return bytes.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    static func decode(_ v: UInt32) -> String {
        withUnsafeBytes(of: v.bigEndian) {
            String(bytes: $0, encoding: .ascii) ?? "????"
        }
    }
}
