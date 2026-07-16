import AppKit
import ApplicationServices
import CoreGraphics

/// Inserts text via clipboard + simulated Cmd+V, then restores the clipboard.
/// Saves a full pasteboard snapshot (all data types, not just the string);
/// rapid consecutive pastes are serialized so the original is never clobbered
/// by our own text.
enum Paster {
    enum Outcome {
        case pasted
        /// No text cursor anywhere — the text was left in the clipboard for a
        /// manual ⌘V instead (a synthetic ⌘V would vanish and the clipboard
        /// restore would then erase the dictation entirely).
        case keptInClipboard
    }

    private static var pendingRestore: [NSPasteboardItem]?
    private static var restoreWork: DispatchWorkItem?

    @discardableResult
    static func insert(_ text: String, expectedTargetPID: pid_t? = nil) -> Outcome {
        paste(text, expectedTargetPID: expectedTargetPID)
    }

    @discardableResult
    static func paste(_ text: String, expectedTargetPID: pid_t? = nil) -> Outcome {
        guard !text.isEmpty else { return .pasted }
        let pb = NSPasteboard.general

        // The synthetic ⌘V lands wherever the focus is NOW. If the user
        // switched apps while recognition was running, a blind paste would
        // drop the text into the wrong window — keep it in the clipboard.
        if let expectedTargetPID,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != expectedTargetPID {
            Log.d("paste: frontmost app changed -> kept in clipboard (now \(front.bundleIdentifier ?? "?"))")
            return keepInClipboard(text, pb)
        }

        let (editable, role) = focusProbe()
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        guard editable else {
            Log.d("paste: no text focus (\(app) role=\(role ?? "nil")) -> kept in clipboard")
            return keepInClipboard(text, pb)
        }
        // Blind ⌘V path: the target isn't a confirmed text field, only "not
        // provably wrong". If the text lands nowhere the user gets no HUD, so
        // record where it went — the only breadcrumb when a paste goes astray.
        Log.d("paste: sending ⌘V -> \(app) role=\(role ?? "nil")")

        // If a restore from the previous paste is still pending, the original
        // is already saved — don't overwrite it with our own text
        if pendingRestore == nil {
            pendingRestore = snapshot(pb)
        }
        restoreWork?.cancel()

        // Trailing space so back-to-back dictations don't glue into one word.
        // Only on the auto-paste path: history, the onboarding box and text
        // kept in the clipboard for a manual ⌘V stay verbatim.
        let insertion = text.last?.isWhitespace == true ? text : text + " "
        pb.clearContents()
        pb.setString(insertion, forType: .string)

        // Short pause so the pasteboard server applies the change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            sendCmdV()
        }

        // Restore the clipboard after the target app has read it
        let work = DispatchWorkItem { restore() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        return .pasted
    }

    private static func keepInClipboard(_ text: String, _ pb: NSPasteboard) -> Outcome {
        restoreWork?.cancel()
        restoreWork = nil
        pendingRestore = nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        return .keptInClipboard
    }

    /// Best-effort probe of the system-wide focused element. Blocks the paste
    /// on a confident "not a text target" — and on "nothing is focused at all":
    /// an empty focus is exactly "no text cursor", the case the manual ⌘V HUD
    /// exists for, and a blind paste there is how dictation vanishes into the
    /// void. For an ambiguous role (a group or web area that may or may not hold
    /// an editor) we don't guess by name — a role denylist is always leaky, as a
    /// dictation lost into Finder's AXGroup showed. Instead we ask the element
    /// whether it can actually take text. Returns the verdict plus the focused
    /// role (nil when AX gave us an element with no readable role) so the caller
    /// can log where a blind paste lands.
    private static func focusProbe() -> (editable: Bool, role: String?) {
        var focusedRef: CFTypeRef?
        // No focused element → keep in clipboard and let the user place a cursor.
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef else { return (false, nil) }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return (canEditText(element), nil) }

        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return (true, role) }

        // Anything else — group, web area, unknown — pastes only if it exposes
        // a text-editing capability. Real editors (including contentEditable web
        // content) do; containers like Finder's file view don't.
        return (canEditText(element), role)
    }

    /// Does the focused element actually hold a text cursor? Merely *reading*
    /// kAXSelectedTextRange is not proof: Finder's desktop AXGroup answers it
    /// too (a dictation vanished exactly there — log 2026-07-16 11:59, range=true,
    /// role=AXGroup). What separates a real text input — native or contentEditable
    /// web content — is that the selection range is *settable*: that's how apps
    /// place the cursor programmatically, and passive containers don't allow it.
    /// Logs both raw signals: the one breadcrumb if the verdict is ever wrong
    /// for some app.
    private static func canEditText(_ element: AXUIElement) -> Bool {
        var rangeRef: CFTypeRef?
        let hasRange = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        var settable: DarwinBoolean = false
        let rangeSettable = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
        Log.d("paste: capability range=\(hasRange) rangeSettable=\(rangeSettable)")
        return rangeSettable
    }

    private static func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let items = pendingRestore, !items.isEmpty {
            pb.writeObjects(items)
        }
        pendingRestore = nil
        restoreWork = nil
    }
}
