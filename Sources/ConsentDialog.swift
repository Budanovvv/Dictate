import AppKit
import SwiftUI

/// The one-time "Record this call?" consent, drawn in the app's own dialog
/// vocabulary (design: Settings.dc consent) instead of NSAlert's. Modal,
/// because nothing about a recording may start until it is answered.
///
/// Keys keep their earlier, deliberate meaning: Return starts, Esc declines —
/// and the visual focus ring sits on Don't Record, so the safe answer reads
/// as the resting default (design critique 8a).
enum ConsentDialog {

    /// Runs modally. true = start recording.
    @MainActor
    static func run() -> Bool {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 404, height: 10),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: ConsentCard(
            decline: { NSApp.stopModal(withCode: .cancel) },
            start: { NSApp.stopModal(withCode: .OK) }))
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        // The caller needs a synchronous answer, so there is no runloop
        // turn to let activation settle — instead the panel is FORCED
        // visible regardless of who is frontmost: modal level, ordered in
        // before the modal loop starts. Without this, a consent asked while
        // the app is not active can run modal behind another app's windows
        // (the trap the update alert fell into, 2026-08-31).
        panel.level = .modalPanel
        panel.orderFrontRegardless()
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response == .OK
    }
}

private struct ConsentCard: View {
    let decline: () -> Void
    let start: () -> Void
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(DS.accent)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "video")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                )
            Text(L("Record this call?"))
                .font(.system(size: 14.5, weight: .semibold))
            Text(L("Dictate will record your microphone and the audio from the call, and keep the transcript on this Mac. Recording other people may require their consent where you are."))
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Asked once. After this, recording starts from the menu bar without a prompt. Esc means don't record."))
                .font(DS.helpText)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                Button(L("Don't Record")) { decline() }
                    .buttonStyle(.dsWide)
                    .keyboardShortcut(.cancelAction)
                    // The design's focus ring: the safe answer LOOKS like
                    // where the keyboard rests.
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DS.accent.opacity(0.4), lineWidth: 3.5)
                        .padding(-2)
                        .allowsHitTesting(false))
                Button(L("Start Recording")) { start() }
                    .buttonStyle(.dsWide)
                    .fontWeight(.bold)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 18, trailing: 24))
        .frame(width: 404)
    }
}
