import AppKit
import SwiftUI

/// The window that carries `MeetingPillView` — the meeting transcript's
/// minimized form.
///
/// Built on the dictation HUD's panel rather than on the transcript window:
/// borderless, non-activating, `.statusBar` level, and it rides to whatever
/// Space is in front. Those four are what let a recording stay visible over a
/// full-screen call without ever taking the keyboard away from it — the same
/// reasoning as the pill that shows while dictating — though this one joins
/// ALL Spaces and follows the person across displays.
///
/// The one thing it does that the HUD deliberately does not: it takes mouse
/// clicks. The HUD is a read-only status light and ignores the mouse entirely;
/// this one carries Stop, and a recording you cannot stop from the thing that
/// says you are recording would be a poor trade for the transcript we hid.
@MainActor
final class MeetingPill {
    private var panel: NSPanel?
    private let session: MeetingSession
    private let onStop: () -> Void
    private let onExpand: () -> Void
    private let onHide: () -> Void
    /// The user dragged the pill this session — following is off until the
    /// pill is next shown.
    private var pinnedByDrag = false
    /// The didMove observation's token — held for the panel's lifetime.
    private var moveObserver: (any NSObjectProtocol)?
    /// Repositions the pill onto the display the user is working on.
    private var followTimer: Timer?
    /// Ticks the mouse has been on a different display than the pill.
    private var awayTicks = 0

    /// The pill follows the person ACROSS DISPLAYS: Spaces are covered by
    /// canJoinAllSpaces, but a window's coordinates live on one monitor —
    /// so a 2 s watch moves it to the display the pointer has settled on
    /// (two ticks of hysteresis; a passing mouse does not drag it around).
    /// The pill keeps its relative position on the new screen. Off after a
    /// manual drag: a hand-placed pill is a choice.
    private func startFollowing() {
        pinnedByDrag = false
        awayTicks = 0
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followTick() }
        }
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        awayTicks = 0
    }

    private func followTick() {
        guard let panel, panel.isVisible, !pinnedByDrag else { return }
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              let current = panel.screen, target !== current else {
            awayTicks = 0
            return
        }
        awayTicks += 1
        guard awayTicks >= 2 else { return }
        awayTicks = 0
        // Same RELATIVE spot on the new display, clamped inside it.
        let from = current.visibleFrame
        let to = target.visibleFrame
        let size = panel.frame.size
        let fx = from.width > size.width
            ? (panel.frame.minX - from.minX) / (from.width - size.width) : 0.5
        let fy = from.height > size.height
            ? (panel.frame.minY - from.minY) / (from.height - size.height) : 0
        positioningProgrammatically = true
        panel.setFrameOrigin(NSPoint(
            x: to.minX + fx * max(to.width - size.width, 0),
            y: to.minY + fy * max(to.height - size.height, 0)))
        positioningProgrammatically = false
        Log.d("pill: followed to \(target.localizedName)")
    }

    /// True while position() moves the panel itself, so the did-move observer
    /// records only the USER's drags — a programmatic placement must not
    /// overwrite a remembered spot.
    private var positioningProgrammatically = false

    /// The window is exactly as big as what the pill draws — the capsule
    /// grows with a notice, the education card is another shape entirely, and
    /// the clock widens at ten minutes. Anything larger would be an invisible
    /// rectangle over someone's call, eating the clicks aimed at it.
    ///
    /// The TOP-left corner survives a resize: it is the corner the eye tracks,
    /// and the corner the remembered spot is stored as.
    private func resize(to size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        // Whole points, so the window AppKit ends up with is the window this
        // asked for — a fractional height would come back rounded, read as a
        // new size, and set a resize bouncing off itself forever.
        let want = CGSize(width: ceil(size.width), height: ceil(size.height))
        let old = panel.frame
        guard abs(old.width - want.width) >= 1
                || abs(old.height - want.height) >= 1 else { return }
        var frame = NSRect(x: old.minX, y: old.maxY - want.height,
                           width: want.width, height: want.height)
        // The card is wider and taller than the capsule it replaces: a pill
        // left near an edge must not grow off the screen.
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX),
                                 max(visible.maxX - frame.width, visible.minX))
            frame.origin.y = min(max(frame.minY, visible.minY),
                                 max(visible.maxY - frame.height, visible.minY))
        }
        positioningProgrammatically = true
        panel.setFrame(frame, display: true)
        positioningProgrammatically = false
    }

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

    /// Set when the person clicked Hide: the pill stays away for the rest of
    /// this recording unless brought back — from the menu bar, which keeps the
    /// time and the stop control for as long as the recording runs (design:
    /// hidden state). Any explicit show (a new recording, minimizing the
    /// window, Bring It Back) clears it.
    private(set) var isUserHidden = false

    func hideByUser() {
        isUserHidden = true
        hide()
    }

    func showAgain() { show() }

    /// `from` is the frame the transcript window occupied a moment ago. The
    /// pill takes its place — top-left to top-left — so the eye that was
    /// reading the window finds it without hunting: the window did not vanish,
    /// it got smaller where it stood. Bottom centre (the dictation pill's spot)
    /// turned out to be far enough from the window that the collapse read as
    /// "everything closed" instead (field test 2026-08-19).
    func show(from frame: NSRect? = nil) {
        isUserHidden = false
        let panel = ensurePanel()
        if !panel.isVisible {
            position(panel, from: frame)
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        startFollowing()
        Log.d("pill: meeting pill shown at \(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        stopFollowing()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            MainActor.assumeIsolated {   // animation completion, main by construction
                // The HUD's race, avoided the same way: a hide that finishes AFTER
                // a new show would otherwise pull a freshly shown pill off screen.
                guard let panel, panel.alphaValue == 0 else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let view = MeetingPillView(session: session, onStop: onStop,
                                   onExpand: onExpand, onHide: onHide,
                                   onSize: { [weak self] in self?.resize(to: $0) })
        let hosting = PillHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

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
        // Dragging lives in the view (MeetingPillView's WindowDragGesture),
        // not here: a borderless window whose every pixel is SwiftUI has no
        // background left for AppKit to grab, so this flag moved nothing.
        // All Spaces, not move-once: the pill is the recording's visible
        // mark and must be wherever the person is looking (owner's call,
        // 2026-08-29) — including other apps' full-screen Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // A drag is a choice worth keeping ACROSS launches, not just for the
        // life of the process — the next meeting's pill appears where the last
        // one was left.
        // The token must be KEPT — a discarded block-observer token
        // deallocates and the observation dies silently (the corner-menu
        // bug's pattern, 2026-08-31).
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {   // queue: .main observer, main by construction
                guard let self, !self.positioningProgrammatically,
                      let frame = self.panel?.frame else { return }
                Settings.shared.meetingPillTopLeft = [frame.minX, frame.maxY]
                // A hand-placed pill stays where the hand put it: dragging turns
                // the display-following off until the next recording.
                self.pinnedByDrag = true
            }
        }
        self.panel = panel
        return panel
    }

    /// Where the window stood, or — with no window to inherit from — the
    /// bottom centre the dictation pill uses.
    private func position(_ panel: NSPanel, from frame: NSRect?) {
        positioningProgrammatically = true
        defer { positioningProgrammatically = false }
        let size = panel.frame.size
        // A spot the user once dragged the pill to outranks everything —
        // clamped into a CURRENT screen, because the display it was left on
        // may be gone (unplugged monitor) and a pill off every screen is a
        // recording indicator nobody can see.
        if let stored = Settings.shared.meetingPillTopLeft, stored.count == 2 {
            let top = NSPoint(x: stored[0], y: stored[1])
            // A point just INSIDE the pill, because the stored corner sits on
            // the window's edge and a rectangle does not contain its own top.
            let inside = NSPoint(x: top.x + 1, y: top.y - 1)
            let screen = NSScreen.screens.first { $0.visibleFrame.contains(inside) }
                ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let x = min(max(top.x, visible.minX), visible.maxX - size.width)
                let y = min(max(top.y - size.height, visible.minY),
                            visible.maxY - size.height)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }
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

/// The pill's hosting view, for one reason: it answers the FIRST mouse.
///
/// The pill is only ever looked at while someone else's app is frontmost —
/// the call is. A click on a window of an inactive app is normally spent on
/// activation and never reaches the view; this panel does not activate
/// anything, so that click would be spent on nothing at all. Answering it
/// means Stop stops on the first press, and a drag starts on the first press,
/// without making the person visit Dictate first.
@MainActor
private final class PillHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Lets a window decide, at the moment it is closed, whether it should close
/// at all. Small enough to live here because the meeting transcript is the
/// only window in the app that has an opinion: while it is recording, closing
/// it means "make it smaller", not "throw it away".
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private let shouldClose: () -> Bool

    init(shouldClose: @escaping () -> Bool) {
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }
}
