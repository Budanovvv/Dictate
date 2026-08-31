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

/// The manual update check's answer: one line in a small panel at the top
/// of the screen — the same always-visible manners as the call card
/// (status-bar level, every Space, shown regardless of activation), because
/// this app never activates and anything less simply isn't seen. Transient
/// by design: it states a fact and leaves; a click dismisses it early.
/// (The no-timeout rule covers DECISION cards — this one asks nothing.)
@MainActor
enum UpdateNotice {
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
            .frame(maxWidth: 340)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
    }
}
