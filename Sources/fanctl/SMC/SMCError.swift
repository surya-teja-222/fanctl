import Foundation
import IOKit

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case smcStatus(UInt8)
    case invalidKey(String)
    case unsupportedType(String)
    case bufferTooSmall(expected: Int, got: Int)

    var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC IOService not found"
        case .openFailed(let r):
            return "IOServiceOpen failed: 0x\(String(r, radix: 16))"
        case .callFailed(let r):
            return "IOConnectCallStructMethod failed: 0x\(String(r, radix: 16))"
        case .keyNotFound(let k):
            return "SMC key not found: \(k)"
        case .smcStatus(let s):
            return "SMC returned status byte: 0x\(String(s, radix: 16))"
        case .invalidKey(let k):
            return "Invalid 4-char SMC key: \"\(k)\""
        case .unsupportedType(let t):
            return "Unsupported SMC data type: \(t)"
        case .bufferTooSmall(let exp, let got):
            return "Buffer too small: expected \(exp), got \(got)"
        }
    }
}
