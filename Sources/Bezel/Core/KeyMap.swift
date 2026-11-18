import AppKit

/// Turns Mac key presses into Android key events.
enum KeyMap {
    enum Stroke {
        case key(code: UInt32, meta: UInt32)
        case back
    }

    /// Android meta state for a held shift.
    private static let shiftMeta: UInt32 = 0x1

    private static let specials: [UInt16: UInt32] = [
        36: 66, 76: 66, // return, keypad enter
        48: 61, // tab
        51: 67, // delete (backspace)
        117: 112, // forward delete
        115: 122, // home
        119: 123, // end
        116: 92, // page up
        121: 93, // page down
        123: 21, 124: 22, 125: 20, 126: 19 // arrows
    ]

    private static let characters: [Character: UInt32] = [
        "a": 29, "b": 30, "c": 31, "d": 32, "e": 33, "f": 34, "g": 35,
        "h": 36, "i": 37, "j": 38, "k": 39, "l": 40, "m": 41, "n": 42,
        "o": 43, "p": 44, "q": 45, "r": 46, "s": 47, "t": 48, "u": 49,
        "v": 50, "w": 51, "x": 52, "y": 53, "z": 54,
        "0": 7, "1": 8, "2": 9, "3": 10, "4": 11,
        "5": 12, "6": 13, "7": 14, "8": 15, "9": 16,
        " ": 62, "-": 69, "=": 70, "[": 71, "]": 72, "\\": 73,
        ";": 74, "'": 75, "`": 68, ",": 55, ".": 56, "/": 76,
        "\n": 66, "\r": 66, "\t": 61
    ]

    static func stroke(for event: NSEvent) -> Stroke? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘ belongs to the app's own menus, and control/option combinations
        // rarely have a sensible Android equivalent.
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return nil
        }
        if event.keyCode == 53 { return .back }

        let meta: UInt32 = flags.contains(.shift) ? shiftMeta : 0
        if let code = specials[event.keyCode] {
            return .key(code: code, meta: meta)
        }
        guard let text = event.charactersIgnoringModifiers?.lowercased(),
              let character = text.first,
              let code = characters[character] else { return nil }
        return .key(code: code, meta: meta)
    }
}
