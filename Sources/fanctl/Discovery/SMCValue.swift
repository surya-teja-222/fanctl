import Foundation

// SMC payload decoding. On Apple Silicon, multi-byte numeric payloads are
// stored in host byte order (little-endian on arm64). Classic Intel SMC docs
// say BE; Apple's M-series firmware changed the convention.

enum SMCValue {
    case uint(UInt64)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case string(String)
    case raw([UInt8])

    var asDouble: Double? {
        switch self {
        case .uint(let v):   return Double(v)
        case .int(let v):    return Double(v)
        case .double(let v): return v
        case .bool(let b):   return b ? 1 : 0
        default:             return nil
        }
    }

    var display: String {
        switch self {
        case .uint(let v):   return "\(v)"
        case .int(let v):    return "\(v)"
        case .double(let v): return String(format: "%.3f", v)
        case .bool(let b):   return b ? "true" : "false"
        case .string(let s): return "\"\(s)\""
        case .raw(let b):    return "0x" + b.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func decode(type: String, bytes: [UInt8]) -> SMCValue {
        let trimmed = type.trimmingCharacters(in: .whitespaces)

        switch trimmed {
        case "ui8":
            guard bytes.count >= 1 else { return .raw(bytes) }
            return .uint(UInt64(bytes[0]))
        case "ui16":
            guard bytes.count >= 2 else { return .raw(bytes) }
            return .uint(UInt64(loadLE(UInt16.self, bytes)))
        case "ui32":
            guard bytes.count >= 4 else { return .raw(bytes) }
            return .uint(UInt64(loadLE(UInt32.self, bytes)))
        case "si8":
            guard bytes.count >= 1 else { return .raw(bytes) }
            return .int(Int64(Int8(bitPattern: bytes[0])))
        case "si16":
            guard bytes.count >= 2 else { return .raw(bytes) }
            return .int(Int64(Int16(bitPattern: loadLE(UInt16.self, bytes))))
        case "flt":
            guard bytes.count >= 4 else { return .raw(bytes) }
            return .double(Double(Float(bitPattern: loadLE(UInt32.self, bytes))))
        case "flag":
            guard bytes.count >= 1 else { return .raw(bytes) }
            return .bool(bytes[0] != 0)
        default:
            // Fixed-point families: fpXY = unsigned, spXY = signed, where Y
            // (a hex digit) is the number of fractional bits.
            if (trimmed.hasPrefix("fp") || trimmed.hasPrefix("sp")),
               trimmed.count == 4,
               let frac = Int(String(trimmed.last!), radix: 16),
               bytes.count >= 2
            {
                let raw = loadLE(UInt16.self, bytes)
                let divisor = Double(1 << frac)
                let val = trimmed.hasPrefix("sp")
                    ? Double(Int16(bitPattern: raw)) / divisor
                    : Double(raw) / divisor
                return .double(val)
            }
            if trimmed.hasPrefix("ch"),
               let s = String(bytes: bytes.prefix { $0 != 0 }, encoding: .ascii) {
                return .string(s)
            }
            return .raw(bytes)
        }
    }

    private static func loadLE<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8]) -> T {
        T(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }
}
