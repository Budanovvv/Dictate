import AppKit

/// Key names by virtual keycode. Base names are English and translated at
/// display time via L(...); letters return the character itself.
enum KeyNames {
    private static let known: [Int: String] = [
        61: "Right Option (⌥)",
        58: "Left Option (⌥)",
        54: "Right Command (⌘)",
        55: "Left Command (⌘)",
        60: "Right Shift (⇧)",
        56: "Left Shift (⇧)",
        62: "Right Control (⌃)",
        59: "Left Control (⌃)",
        63: "Fn (🌐)",
        57: "Caps Lock",
        49: "Space",
        53: "Escape",
        48: "Tab",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
    ]

    /// Modifier keys whose events arrive as flagsChanged.
    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let functionKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
    ]

    static func isSafeHotkey(_ code: Int) -> Bool {
        modifierKeyCodes.contains(code) || functionKeyCodes.contains(code)
    }

    /// Base (English) name — the form stored in settings.
    static func baseName(forKeyCode code: Int, event: NSEvent? = nil) -> String {
        if let n = known[code] { return n }
        if let chars = event?.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return "Key \(code)"
    }

    static func displayName(_ baseName: String) -> String {
        L(baseName)
    }
}
