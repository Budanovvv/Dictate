import AppKit
import SwiftUI

/// The window that carries `MeetingPillView` — the meeting transcript's
/// minimized form.
///
/// Built on the dictation HUD's panel rather than on the transcript window:
/// borderless, non-activating, `.statusBar` level, and it rides to whatever
/// Space is in front. Those four are what let a recording stay visible over a
/// full-screen call without ever taking the keyboard away from it — the same
/// reasoning (and the same hard-won `.moveToActiveSpace`) as the pill that
/// shows while dictating.
///
/// The one thing it does that the HUD deliberately does not: it takes mouse
/// clicks. The HUD is a read-only status light and ignores the mouse entirely;
/// this one carries Stop, and a recording you cannot stop from the thing that
/// says you are recording would be a poor trade for the transcript we hid.
final class MeetingPill {
    private var panel: NSPanel?
    private let session: MeetingSession
    private let onStop: () -> Void
    private let onExpand: () -> Void
    private let onHide: () -> Void

    init(session: MeetingSession,
         onStop: @escaping () -> Void,
         onExpand: @escaping () -> Void,
         onHide: @escaping () -> Void) {
        self.session = session
        self.onStop = onStop
        self.onExpand = onExpand
        self.onHide = onHide
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// `from` is the frame the transcript window occupied a moment ago. The
    /// pill takes its place — top-left to top-left — so the eye that was
    /// reading the window finds it without hunting: the window did not vanish,
    /// it got smaller where it stood. Bottom centre (the dictation pill's spot)
    /// turned out to be far enough from the window that the collapse read as
    /// "everything closed" instead (field test 2026-08-19).
    func show(from frame: NSRect? = nil) {
        let panel = ensurePanel()
        if !panel.isVisible {
            position(panel, from: frame)
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        Log.d("pill: meeting pill shown at \(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            // The HUD's race, avoided the same way: a hide that finishes AFTER
            // a new show would otherwise pull a freshly shown pill off screen.
            guard let panel, panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let view = MeetingPillView(session: session, onStop: onStop,
                                   onExpand: onExpand, onHide: onHide)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: MeetingPillView.size)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        // Drag it out of the way of whatever it lands on; where it is left is
        // where the next meeting finds it (AppKit remembers the frame for the
        // life of the process, which is as long as this panel exists).
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    /// Where the window stood, or — with no window to inherit from — the
    /// bottom centre the dictation pill uses.
    private func position(_ panel: NSPanel, from frame: NSRect?) {
        let size = panel.frame.size
        let screen = frame.flatMap { f in NSScreen.screens.first { $0.frame.intersects(f) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        guard let frame else {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.minY + 24))
            return
        }
        // Top-left to top-left, then clamped: a window near a screen edge must
        // not push the pill off it.
        let x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(frame.maxY - size.height, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Lets a window decide, at the moment it is closed, whether it should close
/// at all. Small enough to live here because the meeting transcript is the
/// only window in the app that has an opinion: while it is recording, closing
/// it means "make it smaller", not "throw it away".
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private let shouldClose: () -> Bool

    init(shouldClose: @escaping () -> Bool) {
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }
}
