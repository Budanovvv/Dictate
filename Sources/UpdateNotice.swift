import AppKit
import SwiftUI

/// The app's top-of-screen notice chassis, shared by the call card and the
/// update notice (they were 18 duplicated lines before 2026-08-31): a
/// borderless non-activating panel at status-bar level that joins every
/// Space, sized to its content and centred under the menu bar. Callers
/// order it front and keep the reference.
@MainActor
func makeTopNoticePanel(hosting: NSView) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    hosting.frame.size = hosting.fittingSize
    panel.contentView = hosting
    panel.setContentSize(hosting.fittingSize)
    if let screen = NSScreen.main {
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - panel.frame.width / 2,
                                     y: v.maxY - panel.frame.height - 12))
    }
    return panel
}

/// One line in a small panel at the top of the screen — the manual update
/// check's answer, a finished model download, a model that will not run on
/// this Mac. The same always-visible manners as the call card (status-bar
/// level, every Space, shown regardless of activation), because this app
/// never activates and anything less simply isn't seen. Transient by design:
/// it states a fact and leaves; a click dismisses it early. (The no-timeout
/// rule covers DECISION cards — this one asks nothing.)
///
/// NOT the recording HUD: that pill is the dictation in flight, every mode
/// it has replaces the previous one, and it hides itself in seconds at the
/// bottom of the screen — a fact about a 2.5 GB download would either
/// interrupt a recording or be gone before anyone looked.
@MainActor
enum TopNotice {
    private static var panel: NSPanel?
    private static var timer: Timer?

    static func show(_ line: String) {
        hide()
        let panel = makeTopNoticePanel(
            hosting: NSHostingView(rootView: NoticeCard(line: line) { hide() }))
        panel.orderFrontRegardless()
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            Task { @MainActor in hide() }
        }
    }

    static func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct NoticeCard: View {
    let line: String
    let dismiss: () -> Void

    var body: some View {
        Text(line)
            .font(.system(size: 12.5, weight: .medium))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            // A FIXED width, not a maximum: with only a ceiling the hosting
            // view's fittingSize came back 1637 pt tall for a three-line
            // notice, and the panel — placed from its own height — landed
            // in the middle of the screen (seen 2026-09-13).
            .frame(width: 340, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
    }
}
