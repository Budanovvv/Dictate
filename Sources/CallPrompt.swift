import AppKit
import SwiftUI

/// The detection card (design StartRecording/MeetingsOff): a small
/// non-activating panel at the top of the screen the moment a call is
/// recognised. Two styles of the same card:
///
/// * `.prompt` — noticing is on. "Zoom call started", Record / Not this
///   one. The first one ever carries the consent line and replaces the old
///   consent dialog for detected calls.
/// * `.offer` — noticing is OFF. "Zoom call — not being recorded": a
///   one-time education that the feature exists, with its own decline
///   bookkeeping — two declines (or "don't offer this again") retire it
///   for good.
///
/// The card stays until answered — moving between screens must not cost
/// the offer (owner's call, 2026-08-29; the designer's ten-second timer is
/// deliberately not implemented). The one thing that dismisses it
/// unanswered is the call itself ending. There is NO automatic mode and no
/// "always record" checkbox: the offer is automatic, the recording never
/// is (owner's call — the mockup's checkbox predates that decision).
@MainActor
final class CallPrompt {
    enum Style { case prompt, offer }

    private var panel: NSPanel?

    func show(platform: String?, style: Style, record: @escaping () -> Void) {
        hide()
        let firstEver = style == .prompt && !Settings.shared.meetingConsentSeen
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
        // offer is in front of them.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: CallPromptCard(
            platform: platform,
            style: style,
            firstEver: firstEver,
            onRecord: { [weak self] in
                Log.d("call: prompt → record")
                Settings.shared.meetingConsentSeen = true
                self?.hide()
                record()
            },
            onDecline: { [weak self] in
                Log.d("call: prompt → not this one")
                if style == .offer {
                    Settings.shared.callOfferDeclines += 1
                }
                self?.hide()
            },
            onNever: { [weak self] in
                Log.d("call: offer → never again")
                Settings.shared.callOfferRetired = true
                self?.hide()
            }))
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.midX - panel.frame.width / 2,
                                         y: v.maxY - panel.frame.height - 12))
        }
        Log.d("call: prompt shown (\(platform ?? "unnamed"), \(style)) at \(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y)) on \(NSScreen.main?.localizedName ?? "?")")
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

/// The design's card (StartRecording.dc): pulsing record dot, the call's
/// name, a full-width accent Record with the ring glyph, Not this one.
private struct CallPromptCard: View {
    let platform: String?
    let style: CallPrompt.Style
    let firstEver: Bool
    let onRecord: () -> Void
    let onDecline: () -> Void
    let onNever: () -> Void

    @State private var pulse = false

    private var headline: String {
        switch style {
        case .prompt:
            return platform.map { Lf("%@ call started", $0) } ?? L("Call started")
        case .offer:
            return platform.map { Lf("%@ call — not being recorded", $0) }
                ?? L("Call — not being recorded")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Circle()
                    .fill(DS.record)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 0.55 : 1)
                Text(headline)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
            }
            if firstEver {
                // The consent dialog's legal line — this card replaces that
                // dialog for detected calls, and says so.
                Text(L("Dictate will record your microphone and the audio from the call, and keep the transcript on this Mac. Recording other people may require their consent where you are."))
                    .font(.system(size: 11.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if style == .offer {
                Text(L("Call recording is off, so this one is passing untranscribed. Turning it on gives you a searchable transcript and a summary afterwards, kept on this Mac."))
                    .font(.system(size: 11.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(action: onRecord) {
                    HStack(spacing: 7) {
                        RecordRing()
                        Text(style == .offer ? L("Record this call") : L("Record"))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.accent))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEmphasis()
                Button(style == .offer ? L("Not now") : L("Not this one"), action: onDecline)
                    .buttonStyle(.dsRegular)
            }
            if firstEver {
                Text(L("Asked once. After this, the panel is the short version above."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if style == .offer {
                Button(L("Don't offer this again"), action: onNever)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .pointerStyle(.link)
            }
        }
        .padding(EdgeInsets(top: 15, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 380, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatCount(7, autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// The record glyph of the design: a ring with a filled centre.
struct RecordRing: View {
    var size: CGFloat = 13
    var body: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: 1.5)
            Circle().frame(width: size * 0.32, height: size * 0.32)
        }
        .frame(width: size, height: size)
    }
}
