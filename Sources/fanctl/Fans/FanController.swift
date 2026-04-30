import Foundation

struct FanState {
    let id: Int
    let mode: UInt8       // 0 = auto, 1 = forced
    let actual: Double    // current RPM
    let target: Double    // requested RPM (only meaningful in forced mode)
    let min: Double       // firmware's recommended forced-mode floor
    let max: Double
}

enum FanMode: UInt8 {
    case auto   = 0
    case forced = 1
}

private enum FanKey {
    static let count                  = "FNum"
    static func mode(_ id: Int)   -> String { "F\(id)Md" }
    static func actual(_ id: Int) -> String { "F\(id)Ac" }
    static func target(_ id: Int) -> String { "F\(id)Tg" }
    static func min(_ id: Int)    -> String { "F\(id)Mn" }
    static func max(_ id: Int)    -> String { "F\(id)Mx" }
}

final class FanController {
    let smc: SMCConnection
    private let helper: MFCHelperClient
    private var helperOpened = false

    init(smc: SMCConnection) {
        self.smc = smc
        self.helper = MFCHelperClient()
    }

    deinit {
        if helperOpened { try? helper.close() }
    }

    private func ensureHelperOpen() throws {
        if !helperOpened {
            try helper.open()
            helperOpened = true
        }
    }

    private func readDouble(_ key: String) throws -> Double {
        let (info, data) = try smc.readBytes(key: key)
        return SMCValue.decode(type: info.dataType, bytes: data).asDouble ?? 0
    }

    func count() throws -> Int {
        Int(try readDouble(FanKey.count))
    }

    func read(id: Int) throws -> FanState {
        FanState(
            id:     id,
            mode:   UInt8(try readDouble(FanKey.mode(id))),
            actual: try readDouble(FanKey.actual(id)),
            target: try readDouble(FanKey.target(id)),
            min:    try readDouble(FanKey.min(id)),
            max:    try readDouble(FanKey.max(id))
        )
    }

    func setMode(id: Int, _ mode: FanMode) throws {
        try ensureHelperOpen()
        let bytes = try SMCEncode.bytes(forType: "ui8", double: Double(mode.rawValue))
        try helper.write(key: FanKey.mode(id), payload: bytes)
    }

    func setTargetRPM(id: Int, rpm: Double) throws {
        try ensureHelperOpen()
        let bytes = try SMCEncode.bytes(forType: "flt", double: rpm)
        try helper.write(key: FanKey.target(id), payload: bytes)
    }

    /// Take control of a fan and set a target RPM. Bounds-checks against Mn/Mx.
    /// Use `forceBelowMin: true` to permit RPMs below the firmware's recommended
    /// floor (the firmware may simply ignore them).
    func force(id: Int, rpm: Double, forceBelowMin: Bool = false) throws {
        let s = try read(id: id)
        var clamped = rpm
        if !forceBelowMin {
            clamped = max(s.min, clamped)
        }
        clamped = min(s.max, clamped)
        try setMode(id: id, .forced)
        try setTargetRPM(id: id, rpm: clamped)
    }

    /// Release a fan back to firmware-managed auto mode.
    func auto(id: Int) throws {
        try setMode(id: id, .auto)
    }

    /// Best-effort release of every fan. Safe to call from signal handlers.
    func autoAllBestEffort() {
        if let n = try? count() {
            for i in 0..<n {
                _ = try? auto(id: i)
            }
        }
    }
}
