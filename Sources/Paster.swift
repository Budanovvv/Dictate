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

        guard focusLooksEditable() else {
            Log.d("paste: no text focus -> kept in clipboard")
            return keepInClipboard(text, pb)
        }

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

    /// Best-effort probe of the system-wide focused element. Only a confident
    /// "not a text target" blocks the paste: AX info is often missing or wrong
    /// (Chromium builds its tree lazily), so unknown roles and errors paste
    /// as before — a false negative here would break dictation into real apps.
    private static func focusLooksEditable() -> Bool {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef else { return true }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return true }

        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return true }
        Log.d("paste: focused role=\(role)")

        let definitelyNotText: Set<String> = [
            kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
            kAXMenuButtonRole, kAXMenuItemRole, kAXMenuBarItemRole, kAXWindowRole,
            kAXImageRole, kAXStaticTextRole, kAXScrollAreaRole, kAXOutlineRole,
            kAXTableRole, kAXListRole, kAXRowRole, kAXCellRole, kAXToolbarRole,
            "AXLink", kAXSplitGroupRole, kAXSliderRole, kAXTabGroupRole,
        ]
        if definitelyNotText.contains(role) { return false }

        // Unknown role (web area, group…): editable web content usually
        // exposes a selected-text attribute; either way stay permissive.
        return true
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
