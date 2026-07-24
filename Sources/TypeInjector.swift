import CoreGraphics
import Foundation

/// Append-only unicode typing into whatever app has the cursor. Never deletes
/// anything: CommitEngine only hands over text that can no longer change, so
/// there is nothing here but forward motion — no backspaces, no revisions, and
/// therefore none of the races that make synthetic editing of a foreign
/// document unsafe.
///
/// The text travels as a unicode payload on a keycode-0 event
/// (CGEventKeyboardSetUnicodeString), the same route espanso and every other
/// cross-app text expander takes: it works in Chromium/Electron and terminals,
/// needs no keyboard-layout translation, and inserts characters the user's
/// layout cannot type at all. Known limitation: keycode-0 unicode events do not
/// survive some remote-desktop/VM clients — those need the clipboard path.
enum TypeInjector {
    /// The magic CGPoint marking our synthetic events. Real events always carry
    /// the pointer position, which no display ever puts here — so HotkeyMonitor's
    /// tap can tell our typing apart from the user's keyboard and ignore it
    /// (without this, dictating into a text field would look like a storm of
    /// hotkey presses).
    static let syntheticEventLocation = CGPoint(x: -13337, y: -31337)

    /// CGEventKeyboardSetUnicodeString silently truncates longer strings. The
    /// limit is undocumented; espanso hit the same wall (src/mac/native.mm) and
    /// settled on 20 UTF-16 units per event, which is what we send.
    private static let chunkLimit = 20
    /// Apps that rebuild their layout on every keystroke (Electron, Slack) drop
    /// events posted back to back; 2 ms of breathing room is the cheapest
    /// insurance against a swallowed chunk.
    private static let chunkPauseMicroseconds: UInt32 = 2000

    /// Types text at the cursor. Blocks the calling thread for ~2 ms per 20
    /// characters, so long text belongs off the main thread.
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let payload = withoutLineBreaks(text)
        guard !payload.isEmpty else { return }
        // A private source carries no keyboard state of its own: the push-to-talk
        // key is physically HELD while we type, and an event inheriting the
        // session state would arrive as ⌥-character in every app.
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.d("type: no event source")
            return
        }
        let chunks = chunked(payload)
        for chunk in chunks {
            post(chunk, source: source)
            usleep(chunkPauseMicroseconds)
        }
        Log.d("type: \(payload.count) chars in \(chunks.count) chunk(s)")
    }

    private static func post(_ units: [UniChar], source: CGEventSource) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            // Belt and braces over the private source: whatever the user holds
            // (our own hotkey included) must not modify what we type.
            event.flags = []
            event.location = syntheticEventLocation
            event.post(tap: .cghidEventTap)
        }
    }

    /// Splits into ≤20 UTF-16 units WITHOUT cutting a grapheme cluster: half an
    /// emoji or a bare combining mark is not something we may ever leave in a
    /// user's document. A single cluster longer than the limit (a long ZWJ
    /// emoji) goes out whole and takes its chances with the truncation.
    private static func chunked(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > chunkLimit {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Line breaks are not typed in v1: a synthesized Return sends the message
    /// in every chat app, which is exactly the mistake that cannot be undone.
    /// Each run of breaks becomes one space (dropping them outright would glue
    /// two words together); the line break itself is recovered by the final
    /// reconciliation pass through the normal paste path.
    private static func withoutLineBreaks(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        Log.d("type: line break(s) dropped — Return would send the message")
        return text.replacingOccurrences(of: "[\r\n]+", with: " ", options: .regularExpression)
    }
}
