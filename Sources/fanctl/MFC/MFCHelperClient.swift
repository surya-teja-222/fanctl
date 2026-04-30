import Foundation

// XPC client for Macs Fan Control's privileged helper. Apple Silicon's kernel
// gates direct AppleSMC writes; this client proxies write commands through
// MFC's already-trusted helper. Reads still work via SMCConnection directly.
//
// Service: com.crystalidea.macsfancontrol.smcwrite (privileged Mach service).
//
// Wire protocol (XPC dictionary):
//   { "command": "open" }
//   { "command": "close" }
//   { "command": "write", "key": "F0Tg", "value": "<hex payload>" }

enum MFCHelperError: Error, CustomStringConvertible {
    case connectionInvalid
    case connectionInterrupted
    case unexpectedReplyType
    case helperReplyError(String)

    var description: String {
        switch self {
        case .connectionInvalid: return "XPC connection invalid (helper rejected our code-signing or service unavailable)"
        case .connectionInterrupted: return "XPC connection interrupted"
        case .unexpectedReplyType: return "XPC reply was not a dictionary"
        case .helperReplyError(let s): return "Helper error: \(s)"
        }
    }
}

final class MFCHelperClient {
    private enum Cmd {
        static let key   = "command"
        static let open  = "open"
        static let close = "close"
        static let write = "write"
    }
    private enum Field {
        static let key   = "key"
        static let value = "value"
        static let type  = "type"
        static let reply = "reply"
    }
    private static let serviceName = "com.crystalidea.macsfancontrol.smcwrite"

    private let conn: xpc_connection_t
    private let queue = DispatchQueue(label: "fanctl.mfc.xpc")

    init() {
        conn = xpc_connection_create_mach_service(
            Self.serviceName,
            queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
        xpc_connection_set_event_handler(conn) { _ in }
        xpc_connection_resume(conn)
    }

    deinit {
        xpc_connection_cancel(conn)
    }

    func open() throws {
        try send([Cmd.key: Cmd.open])
    }

    func close() throws {
        try send([Cmd.key: Cmd.close])
    }

    func write(key: String, payload: [UInt8]) throws {
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        try send([
            Cmd.key:     Cmd.write,
            Field.key:   key,
            Field.value: hex,
        ])
    }

    private func send(_ dict: [String: String]) throws {
        let msg = xpc_dictionary_create(nil, nil, 0)
        for (k, v) in dict {
            xpc_dictionary_set_string(msg, k, v)
        }
        let reply = xpc_connection_send_message_with_reply_sync(conn, msg)
        let type = xpc_get_type(reply)

        if type == XPC_TYPE_ERROR {
            if reply === XPC_ERROR_CONNECTION_INVALID {
                throw MFCHelperError.connectionInvalid
            }
            if reply === XPC_ERROR_CONNECTION_INTERRUPTED {
                throw MFCHelperError.connectionInterrupted
            }
            let desc = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                .map { String(cString: $0) } ?? "<unknown>"
            throw MFCHelperError.helperReplyError(desc)
        }
        guard type == XPC_TYPE_DICTIONARY else {
            throw MFCHelperError.unexpectedReplyType
        }
        if let typeBytes = xpc_dictionary_get_string(reply, Field.type) {
            let typeStr = String(cString: typeBytes)
            if typeStr != "success" && typeStr != "OK" {
                let detail = xpc_dictionary_get_string(reply, Field.reply)
                    .map { String(cString: $0) } ?? "<no detail>"
                throw MFCHelperError.helperReplyError("type=\(typeStr) detail=\(detail)")
            }
        }
    }
}
