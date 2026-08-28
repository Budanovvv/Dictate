import AppKit
import SwiftUI

/// The detection prompt (mechanical shell — visuals follow the designer's
/// card when it lands): a small non-activating panel at the top of the
/// screen the moment a call is recognised. Record is primary, "Not this
/// one" declines for this call. It stays until answered — moving between
/// screens must not cost the offer (owner's call, 2026-08-29); the one
/// thing that dismisses it unanswered is the call itself ending. There is
/// deliberately NO automatic mode: the offer is automatic, the recording
/// never is.
///
/// Non-activating on purpose: the person is JOINING A CALL — a prompt that
/// steals the keyboard from Zoom at that exact moment would be the app
/// working against its user.
///
/// The very first prompt ever carries the consent card's legal line and
/// stands in for it — answered once, like the dialog it replaces.
@MainActor
final class CallPrompt {
    private var panel: NSPanel?

    /// Shows the prompt for a recognised call. `record` runs on the primary
    /// action, after consent bookkeeping.
    func show(platform: String?, record: @escaping () -> Void) {
        hide()
        let firstEver = !Settings.shared.meetingConsentSeen
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        // The card CHASES the person: whatever Space or full-screen app
        // they are on when it appears — or move to while it waits — the
        // offer is in front of them (owner's rule: wherever I am).
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: CallPromptCard(
            platform: platform,
            firstEver: firstEver,
            onRecord: { [weak self] in
                Log.d("call: prompt → record")
                Settings.shared.meetingConsentSeen = true
                self?.hide()
                record()
            },
            onDecline: { [weak self] in
                Log.d("call: prompt → not this one")
                self?.hide()
            }))
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        // Top-centre of the screen with the keyboard focus — under the menu
        // bar, where the eyes already are while a call window opens.
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.midX - panel.frame.width / 2,
                                         y: v.maxY - panel.frame.height - 12))
        }
        Log.d("call: prompt shown (\(platform ?? "unnamed")) at \(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y)) on \(NSScreen.main?.localizedName ?? "?")")
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// The call the card was offering ended before anyone answered.
    func callOver() {
        guard panel != nil else { return }
        Log.d("call: prompt → dismissed, call over")
        hide()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CallPromptCard: View {
    let platform: String?
    let firstEver: Bool
    let onRecord: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Circle().fill(DS.record).frame(width: 8, height: 8)
                Text(platform.map { Lf("%@ call started", $0) } ?? L("Call started"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            if firstEver {
                // The consent dialog's legal line, said here because this
                // prompt replaces that dialog for detected calls.
                Text(L("Dictate will record your microphone and the audio from the call, and keep the transcript on this Mac. Recording other people may require their consent where you are."))
                    .font(.system(size: 11.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Not this one"), action: onDecline)
                    .buttonStyle(.dsRegular)
                Button(action: onRecord) {
                    HStack(spacing: 6) {
                        Circle().fill(.white).frame(width: 7, height: 7)
                        Text(L("Record"))
                    }
                }
                .buttonStyle(.dsPrimary)
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 12, trailing: 15))
        .frame(width: 380, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}
