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
    /// changeCount of OUR pasteboard write. If it moved by restore() time,
    /// someone else (the user's ⌘C, a clipboard manager) wrote after us —
    /// restoring the snapshot would silently destroy their copy.
    private static var ourChangeCount: Int?

    /// The user-facing insertion switch (Settings › Keys, design: "Insert
    /// text by"): pasting is instant but borrows the clipboard for a moment;
    /// typing rides the same unicode-event route live typing uses and works
    /// in apps that block paste (some terminals, remote desktops).
    @discardableResult
    static func insert(_ text: String, expectedTargetPID: pid_t? = nil) -> Outcome {
        Settings.shared.insertByTyping
            ? type(text, expectedTargetPID: expectedTargetPID)
            : paste(text, expectedTargetPID: expectedTargetPID)
    }

    /// Insert by synthetic typing. Same safety gates as paste — target app
    /// unchanged, a real text cursor — and the same clipboard fallback when
    /// they fail. Line breaks still take the paste path: a synthesized Return
    /// sends messages in chats, so TypeInjector refuses to type them.
    @discardableResult
    static func type(_ text: String, expectedTargetPID: pid_t? = nil) -> Outcome {
        guard !text.isEmpty else { return .pasted }
        let pb = NSPasteboard.general
        if let expectedTargetPID,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != expectedTargetPID {
            Log.d("type: frontmost app changed -> kept in clipboard (now \(front.bundleIdentifier ?? "?"))")
            return keepInClipboard(text, pb)
        }
        let (editable, role) = focusProbe()
        guard editable else {
            Log.d("type: no text focus (role=\(role ?? "nil")) -> kept in clipboard")
            return keepInClipboard(text, pb)
        }
        if text.contains("\n") {
            Log.d("type: line breaks -> paste path")
            return paste(text, expectedTargetPID: expectedTargetPID)
        }
        // Trailing space for the same reason paste adds one: back-to-back
        // dictations must not glue into one word.
        let insertion = text.last?.isWhitespace == true ? text : text + " "
        Log.d("type: injecting \(insertion.count) chars")
        // Off the main thread: TypeInjector blocks ~2 ms per 20 characters.
        DispatchQueue.global(qos: .userInitiated).async { TypeInjector.type(insertion) }
        return .pasted
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
        ourChangeCount = pb.changeCount

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
        ourChangeCount = nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        return .keptInClipboard
    }

    /// Is there a real text cursor right now? Same verdict the paste path uses,
    /// asked before a dictation starts: live typing may only arm itself when
    /// the answer is an unambiguous yes.
    static func hasEditableFocus() -> Bool {
        focusProbe().editable
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
        // No focused element → keep in clipboard and let the user place a
        // cursor. But Chromium/Electron/WebKit report nothing here until their
        // lazy AX tree is built, so an empty first read isn't proof of "no
        // cursor": wake the frontmost app's accessibility and read once more.
        var focused = systemWideFocusedElement()
        if focused == nil, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            wakeAccessibility(pid: pid)
            focused = systemWideFocusedElement()
            Log.d("paste: no focus on first read, woke \(pid) -> \(focused == nil ? "still empty" : "got element")")
        }
        guard let element = focused else { return (false, nil) }

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

    private static func systemWideFocusedElement() -> AXUIElement? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef else { return nil }
        // A guarded cast, not as!: the attribute is documented to be an
        // AXUIElement, but a misbehaving client returning something else
        // must cost us a nil, not a crash.
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// Wakes an app's lazily-built accessibility tree. Two dialects, both set
    /// blindly: AXManualAccessibility is what Electron listens to, while plain
    /// Chromium — including the ChatGPT desktop app's "Codex Framework" shell,
    /// which ignored the Electron spelling and kept dictation on the manual ⌘V
    /// path (log 2026-07-26 11:08) — only answers to AXEnhancedUserInterface,
    /// the signal VoiceOver sends. Known Chromium quirk of the latter: it can
    /// affect window move/resize animation (the Rectangle-vs-Chrome story) —
    /// acceptable for the app the user is actively dictating into.
    /// Native apps ignore both unknown attributes, so the empty-desktop "no
    /// cursor" case (Finder) stays blocked. Best called at record start, giving
    /// the app the whole speech + recognition window to build the tree.
    static func wakeAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// When the last synthetic ⌘V was posted. The paste events carry
    /// flags=Command ONLY, and posting them REWRITES the session's modifier
    /// flags state: a physically held push-to-talk modifier vanishes from
    /// CGEventSource.flagsState until the next REAL flagsChanged event
    /// arrives. Harmless while pastes and recordings never overlapped; the
    /// dictation pipeline made a mid-recording paste normal, and the
    /// lost-release watchdog read the clobbered state as "key up" and cut a
    /// live recording at 2 s (log 2026-08-09 11:44). Anyone treating
    /// flagsState as physical ground truth must check this first.
    private(set) static var lastSyntheticPasteAt: Date?

    private static func sendCmdV() {
        lastSyntheticPasteAt = Date()
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
        defer {
            pendingRestore = nil
            restoreWork = nil
            ourChangeCount = nil
        }
        // Someone wrote to the pasteboard after us — their content wins,
        // the snapshot is stale.
        if let ours = ourChangeCount, pb.changeCount != ours {
            Log.d("paste: pasteboard changed by someone else -> skip restore")
            return
        }
        pb.clearContents()
        if let items = pendingRestore, !items.isEmpty {
            pb.writeObjects(items)
        }
    }
}
