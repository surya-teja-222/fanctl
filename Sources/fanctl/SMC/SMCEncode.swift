import Foundation

// Encoding side of the payload codec — symmetric with SMCValue.decode.
// Apple Silicon stores multi-byte payloads in host byte order (LE on arm64).

enum SMCEncode {
    static func bytes(forType type: String, double value: Double) throws -> [UInt8] {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "ui8":
            return [UInt8(clamping: Int(value.rounded()))]
        case "ui16":
            return packLE(UInt16(clamping: Int(value.rounded())))
        case "ui32":
            return packLE(UInt32(clamping: Int(value.rounded())))
        case "si8":
            return [UInt8(bitPattern: Int8(clamping: Int(value.rounded())))]
        case "si16":
            return packLE(UInt16(bitPattern: Int16(clamping: Int(value.rounded()))))
        case "flt":
            return packLE(Float(value).bitPattern)
        case "flag":
            return [value == 0 ? 0 : 1]
        default:
            // fpXY (unsigned) / spXY (signed), Y = fractional bits in hex.
            if (trimmed.hasPrefix("fp") || trimmed.hasPrefix("sp")),
               trimmed.count == 4,
               let frac = Int(String(trimmed.last!), radix: 16)
            {
                let scaled = value * Double(1 << frac)
                if trimmed.hasPrefix("sp") {
                    return packLE(UInt16(bitPattern: Int16(clamping: Int(scaled.rounded()))))
                }
                return packLE(UInt16(clamping: Int(scaled.rounded())))
            }
            throw SMCError.unsupportedType(type)
        }
    }

    private static func packLE<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
