import Foundation

/// BLE identifiers of the PitPat / SupeRun controller board.
public enum PadBLE {
    public static let service = "FBA0"
    public static let write = "FBA1"
    public static let notify = "FBA2"
}

/// Speeds on the wire are thousandths of a km/h, whatever the pad's panel shows.
/// The pad only keeps whole tenths of a km/h, so every speed we send is on that grid.
public enum PadSpeed {
    public static let minUnits = 1000
    public static let maxUnits = 6000
    static let gridUnits = 100
    static let unitsPerMph = 1609.344

    static func snap(_ units: Int) -> Int {
        Int((Double(units) / Double(gridUnits)).rounded()) * gridUnits
    }

    public static func clamp(_ units: Int) -> Int {
        min(max(snap(units), minUnits), maxUnits)
    }

    public static func units(mph: Double) -> Int { clamp(Int((mph * unitsPerMph).rounded())) }
    public static func units(kmh: Double) -> Int { clamp(Int((kmh * 1000).rounded())) }

    public static func mph(units: Int) -> Double { Double(units) / unitsPerMph }
    public static func kmh(units: Int) -> Double { Double(units) / 1000 }

    /// One press of the panel's + or -: 0.1 of whatever unit the panel shows.
    /// In mph the step starts from the number the panel displays, so each press moves it.
    public static func step(from current: Int, direction: Int, imperial: Bool) -> Int {
        guard imperial else { return clamp(current + direction * gridUnits) }
        let shown = (mph(units: current) * 10).rounded() / 10
        return units(mph: shown + Double(direction) * 0.1)
    }
}

public enum PadCommand: Equatable {
    case start(units: Int)
    case setSpeed(units: Int)
    case pause
    case stop

    // The firmware only checks that this looks like a user id; every app sends a constant.
    static let userID: UInt64 = 58_965_456_623

    public static let heartbeat = Data([0x6A, 0x05, 0xFD, 0xF8, 0x43])

    /// A 23-byte packet: 6A 17 ... speed ... command, user id, XOR checksum, 43.
    public var packet: Data {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = 0x6A
        b[1] = 0x17
        var units = 0
        var command: UInt8 = 0
        var magic: UInt8 = 1
        switch self {
        case .start(let u):
            units = PadSpeed.clamp(u)
            command = 4
        case .setSpeed(let u):
            units = PadSpeed.clamp(u)
            command = 4
            magic = 5
        case .pause:
            command = 2
        case .stop:
            command = 0
        }
        b[6] = UInt8((units >> 8) & 0xFF)
        b[7] = UInt8(units & 0xFF)
        b[8] = magic
        b[10] = 80
        b[12] = command
        for i in 0..<8 {
            b[13 + i] = UInt8((Self.userID >> UInt64(56 - i * 8)) & 0xFF)
        }
        var checksum: UInt8 = 0
        for i in 1...20 { checksum ^= b[i] }
        b[21] = checksum
        b[22] = 0x43
        return Data(b)
    }
}

public struct PadStatus: Equatable {
    public enum State: Equatable { case stopped, starting, running, paused }

    public var state: State
    public var speedUnits: Int
    public var targetUnits: Int
    public var maxUnits: Int
    public var distanceMeters: Int
    public var calories: Int
    public var steps: Int
    public var durationSeconds: Int
    public var firmware: Int
    /// Whether the pad's own panel shows mph. The wire is km/h either way.
    public var imperial: Bool
    public var serial: String?
}

public enum PadFrame {
    /// Decodes a status notification, or returns nil for a frame this app does not understand.
    /// Frames start with 0x66/0x67/0x68 depending on firmware, carry their own length in
    /// byte 1, end in 0x43, and put an XOR of everything between at the end.
    public static func parse(_ data: Data) -> PadStatus? {
        let b = [UInt8](data)
        guard b.count >= 31, Int(b[1]) == b.count, b[b.count - 1] == 0x43 else { return nil }
        var checksum: UInt8 = 0
        for i in 1..<(b.count - 2) { checksum ^= b[i] }
        guard checksum == b[b.count - 2] else { return nil }

        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }

        let maxUnits = u16(27)
        guard (1000...20000).contains(maxUnits) else { return nil }

        let flags = b[26]
        let state: PadStatus.State
        switch flags & 0x18 {
        case 0x18: state = .starting
        case 0x08: state = .running
        case 0x10: state = .paused
        default: state = .stopped
        }

        var serial: String?
        if b.count >= 48 {
            let text = b[32..<48]
            if text.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }) {
                serial = String(decoding: text, as: UTF8.self)
            }
        }

        return PadStatus(
            state: state,
            speedUnits: u16(3),
            targetUnits: u16(5),
            maxUnits: maxUnits,
            distanceMeters: u32(7),
            calories: u16(18),
            steps: u32(14),
            durationSeconds: u32(20) / 1000,
            firmware: Int(b[25]),
            imperial: flags & 0x80 != 0,
            serial: serial
        )
    }
}
