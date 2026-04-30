import Foundation
import IOKit

// AppleSMC IOConnectCallStructMethod uses a fixed 80-byte struct. We treat it
// as a raw byte buffer with hardcoded offsets to avoid Swift/C alignment
// ambiguity. Layout matches Apple's SMCKeyData_t:
//
//   off  size  field
//     0     4  key (FourCC)
//    28     4  keyInfo.dataSize (UInt32)
//    32     4  keyInfo.dataType (FourCC)  — must be zero on write or the
//                                            kernel silently no-ops the call
//    36     1  keyInfo.dataAttributes (UInt8)
//    40     1  result
//    41     1  status
//    42     1  data8 (the SMC command byte)
//    44     4  data32
//    48    32  bytes (payload)
//
// Multi-byte numeric fields are host byte order (little-endian on arm64) for
// struct framing; payload values follow SMC's per-type encoding.

private enum SMCOffset {
    static let key = 0
    static let dataSize = 28
    static let dataType = 32
    static let result = 40
    static let status = 41
    static let command = 42
    static let data32 = 44
    static let payload = 48
    static let structSize = 80
}

enum SMCCommand: UInt8 {
    case readBytes   = 5
    case writeBytes  = 6
    case readIndex   = 8
    case readKeyInfo = 9
}

struct SMCKeyInfo {
    let dataSize: UInt32
    let dataType: String   // FourCC, e.g. "ui32", "flt ", "fp1f"
    let attributes: UInt8
}

final class SMCConnection {
    private var conn: io_connect_t = 0
    private var infoCache: [String: SMCKeyInfo] = [:]

    var matchedServiceName: String = "?"

    init(verbose: Bool = false) throws {
        // Apple Silicon's IOServiceMatching("AppleSMC") matches multiple
        // services, including the read-only AppleSMCKeysEndpoint. We iterate
        // and open the first that succeeds.
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                              IOServiceMatching("AppleSMC"),
                                              &iter)
        guard kr == kIOReturnSuccess, iter != 0 else {
            throw SMCError.serviceNotFound
        }
        defer { IOObjectRelease(iter) }

        var lastErr: kern_return_t = 0
        var attempt = 0
        while case let svc = IOIteratorNext(iter), svc != 0 {
            attempt += 1
            let className = Self.className(of: svc)
            let r = IOServiceOpen(svc, mach_task_self_, 0, &conn)
            IOObjectRelease(svc)
            if verbose {
                FileHandle.standardError.write(Data(
                    "smc: attempt \(attempt) class=\(className) → \(r == 0 ? "OK" : "0x\(String(r, radix: 16))")\n".utf8))
            }
            if r == kIOReturnSuccess {
                matchedServiceName = className
                return
            }
            lastErr = r
        }
        throw lastErr == 0 ? SMCError.serviceNotFound : SMCError.openFailed(lastErr)
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    private static func className(of svc: io_service_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        return buf.withUnsafeMutableBufferPointer {
            IOObjectGetClass(svc, $0.baseAddress) == KERN_SUCCESS
                ? String(cString: $0.baseAddress!) : "?"
        }
    }

    // MARK: - Raw call

    private func call(input: [UInt8]) throws -> [UInt8] {
        precondition(input.count == SMCOffset.structSize)
        var output = [UInt8](repeating: 0, count: SMCOffset.structSize)
        var outSize: size_t = SMCOffset.structSize

        let r = input.withUnsafeBytes { inBuf -> kern_return_t in
            output.withUnsafeMutableBytes { outBuf -> kern_return_t in
                IOConnectCallStructMethod(
                    conn,
                    /* selector */ 2,
                    inBuf.baseAddress, SMCOffset.structSize,
                    outBuf.baseAddress, &outSize
                )
            }
        }
        guard r == kIOReturnSuccess else { throw SMCError.callFailed(r) }
        guard outSize == SMCOffset.structSize else {
            throw SMCError.bufferTooSmall(expected: SMCOffset.structSize, got: outSize)
        }

        let status = output[SMCOffset.status]
        if status == 0x85 { throw SMCError.keyNotFound("???") }
        if status != 0   { throw SMCError.smcStatus(status) }
        return output
    }

    // MARK: - Buffer helpers (host-order load/store)

    private static func writeLE32(_ buf: inout [UInt8], at offset: Int, _ value: UInt32) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { src in
            buf.replaceSubrange(offset..<offset + 4, with: src)
        }
    }

    private static func readLE32(_ buf: [UInt8], at offset: Int) -> UInt32 {
        UInt32(littleEndian: buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }

    // MARK: - Public API

    /// Returns metadata (size + type) for an SMC key. Cached after first lookup
    /// — keyInfo is static per boot.
    func keyInfo(key: String) throws -> SMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        let keyCode = try FourCC.encode(key)
        var input = [UInt8](repeating: 0, count: SMCOffset.structSize)
        Self.writeLE32(&input, at: SMCOffset.key, keyCode)
        input[SMCOffset.command] = SMCCommand.readKeyInfo.rawValue

        do {
            let out = try call(input: input)
            let info = SMCKeyInfo(
                dataSize:   Self.readLE32(out, at: SMCOffset.dataSize),
                dataType:   FourCC.decode(Self.readLE32(out, at: SMCOffset.dataType)),
                attributes: out[36]
            )
            infoCache[key] = info
            return info
        } catch SMCError.keyNotFound {
            throw SMCError.keyNotFound(key)
        }
    }

    /// Reads the raw bytes for a key. Caller is responsible for decoding by type.
    func readBytes(key: String) throws -> (info: SMCKeyInfo, data: [UInt8]) {
        let info = try keyInfo(key: key)
        let keyCode = try FourCC.encode(key)
        var input = [UInt8](repeating: 0, count: SMCOffset.structSize)
        Self.writeLE32(&input, at: SMCOffset.key, keyCode)
        Self.writeLE32(&input, at: SMCOffset.dataSize, info.dataSize)
        Self.writeLE32(&input, at: SMCOffset.dataType, try FourCC.encode(info.dataType))
        input[SMCOffset.command] = SMCCommand.readBytes.rawValue

        let out = try call(input: input)
        let n = Int(info.dataSize)
        guard n <= 32 else {
            throw SMCError.unsupportedType("payload \(n) bytes > 32")
        }
        let data = Array(out[SMCOffset.payload..<(SMCOffset.payload + n)])
        return (info, data)
    }

    /// Returns the SMC key at an index (0..<count). Used to enumerate all keys.
    func keyAt(index: UInt32) throws -> String {
        var input = [UInt8](repeating: 0, count: SMCOffset.structSize)
        Self.writeLE32(&input, at: SMCOffset.data32, index)
        input[SMCOffset.command] = SMCCommand.readIndex.rawValue
        let out = try call(input: input)
        return FourCC.decode(Self.readLE32(out, at: SMCOffset.key))
    }

    /// Total number of SMC keys exposed by the firmware.
    func keyCount() throws -> UInt32 {
        let (info, data) = try readBytes(key: "#KEY")
        guard info.dataSize == 4, data.count == 4 else {
            throw SMCError.unsupportedType("#KEY size=\(info.dataSize)")
        }
        return UInt32(bigEndian: data.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        })
    }

    /// Writes raw bytes to a key. The dataType slot at offset 32 must remain
    /// zero — the kernel rejects writes that set it.
    func writeBytes(key: String, data: [UInt8]) throws {
        let info = try keyInfo(key: key)
        guard data.count == Int(info.dataSize) else {
            throw SMCError.bufferTooSmall(expected: Int(info.dataSize), got: data.count)
        }
        let keyCode = try FourCC.encode(key)
        var input = [UInt8](repeating: 0, count: SMCOffset.structSize)
        Self.writeLE32(&input, at: SMCOffset.key, keyCode)
        Self.writeLE32(&input, at: SMCOffset.dataSize, info.dataSize)
        input[SMCOffset.command] = SMCCommand.writeBytes.rawValue
        for (i, b) in data.enumerated() {
            input[SMCOffset.payload + i] = b
        }
        _ = try call(input: input)
    }
}
