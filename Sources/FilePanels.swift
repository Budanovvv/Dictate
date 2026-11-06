import AppKit

/// Save and open panels from the meetings window, shown as sheets on it.
///
/// The meetings window is a non-activating panel that happily sits in another
/// app's full-screen Space — the owner's PyCharm, a full-screen call. A
/// free-standing `NSSavePanel.begin` from there never reaches the screen:
/// measured 2026-11-06 with a standalone harness, a regular-policy app's
/// begin() panel ended up on NO Space at all (or on the display's desktop),
/// with or without `NSApp.activate()` first and whatever the parent's
/// collection behaviour. The owner saw Export… do nothing, then found the
/// panel waiting on the desktop. A sheet is a child of the window, so it
/// lands in the window's own Space every time — the harness put it there in
/// every configuration, including the external display.
enum FilePanels {
    static let meetingsWindowID = NSUserInterfaceItemIdentifier("dictate.meetings")

    /// The meetings window, if it is on screen to carry a sheet.
    static var meetingsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier == meetingsWindowID && $0.isVisible }
    }

    /// Shows `panel` as a sheet on the meetings window; with that window not
    /// on screen, as a free panel the old way (activate, then begin) — the
    /// only case where there is no Space to get wrong.
    static func present(_ panel: NSSavePanel,
                        completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = meetingsWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
            return
        }
        NSApp.activate()
        // Next runloop turn: activation must settle or the panel can open
        // behind the frontmost app (2026-08-31).
        DispatchQueue.main.async { panel.begin(completionHandler: completion) }
    }
}
