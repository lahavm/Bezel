import Foundation

/// Control messages sent to the scrcpy server over its control socket.
/// Every field is big-endian, matching the server's reader.
enum ControlMessages {
    enum Action: UInt8 {
        case down = 0
        case up = 1
        case move = 2
    }

    private static let injectKeycode: UInt8 = 0
    private static let injectTouch: UInt8 = 2
    private static let injectScroll: UInt8 = 3
    private static let backOrScreenOn: UInt8 = 4

    static func key(code: UInt32, down: Bool, repeatCount: UInt32 = 0, meta: UInt32 = 0) -> Data {
        var data = Data([injectKeycode, down ? 0 : 1])
        data.appendBE(code)
        data.appendBE(repeatCount)
        data.appendBE(meta)
        return data
    }

    static func touch(_ action: Action, x: Int32, y: Int32, width: UInt16, height: UInt16) -> Data {
        var data = Data([injectTouch, action.rawValue])
        data.appendBE(UInt64(1)) // pointer id
        data.appendBE(x)
        data.appendBE(y)
        data.appendBE(width)
        data.appendBE(height)
        data.appendBE(action == .up ? UInt16(0) : UInt16.max) // pressure
        data.appendBE(action == .up ? UInt32(0) : UInt32(1)) // action button: primary
        data.appendBE(action == .up ? UInt32(0) : UInt32(1)) // pressed buttons
        return data
    }

    static func scroll(x: Int32, y: Int32, width: UInt16, height: UInt16, dx: Int16, dy: Int16) -> Data {
        var data = Data([injectScroll])
        data.appendBE(x)
        data.appendBE(y)
        data.appendBE(width)
        data.appendBE(height)
        data.appendBE(dx)
        data.appendBE(dy)
        return data
    }

    /// The system back action, or wakes the screen when it is off.
    static let back = Data([backOrScreenOn])
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
