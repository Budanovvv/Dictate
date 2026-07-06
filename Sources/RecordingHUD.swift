import AppKit
import SwiftUI

/// Floating status panel at the bottom of the screen. Never takes focus or mouse events.
final class HUDModel: ObservableObject {
    enum Mode: Equatable {
        case recording, transcribing, done, empty, downloading, warming, cancelled
    }

    @Published var mode: Mode = .recording
    @Published var level: Double = 0
    @Published var elapsed: Int = 0
    @Published var downloadProgress: Double = 0
    @Published var words: Int = 0
    @Published var seconds: Double = 0
}

final class RecordingHUD {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var elapsedTimer: Timer?
    private var hideWork: DispatchWorkItem?

    func showRecording() {
        cancelHide()
        model.mode = .recording
        model.level = 0
        model.elapsed = 0
        startElapsed()
        show()
    }

    func showTranscribing() {
        cancelHide()
        stopElapsed()
        model.mode = .transcribing
        show()
    }

    func showDownloading(_ progress: Double) {
        cancelHide()
        stopElapsed()
        model.downloadProgress = progress
        model.mode = .downloading
        show()
    }

    /// Model is downloaded but still loading into memory — first dictation after launch.
    func showWarming() {
        cancelHide()
        stopElapsed()
        model.mode = .warming
        show()
    }

    /// Esc pressed: brief flash, then hide.
    func showCancelled() {
        cancelHide()
        stopElapsed()
        model.mode = .cancelled
        show()
        scheduleHide(after: 0.8)
    }

    /// success=false shows the "empty" state.
    func showResult(success: Bool, words: Int = 0, seconds: Double = 0) {
        cancelHide()
        stopElapsed()
        model.words = words
        model.seconds = seconds
        model.mode = success ? .done : .empty
        show()
        scheduleHide(after: success ? 1.4 : 1.6)
    }

    private func scheduleHide(after delay: Double) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        stopElapsed()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    func setLevel(_ level: Double) {
        model.level = model.level * 0.5 + level * 0.5
    }

    // MARK: - private

    private func startElapsed() {
        stopElapsed()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.elapsed += 1
        }
    }

    private func stopElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func show() {
        let panel = ensurePanel()
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 56)

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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 110))
    }
}

// MARK: - View

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            icon
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 260, height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.2), value: model.mode)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.mode {
        case .recording:
            PulsingDot()
        case .transcribing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20)).foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating, value: model.mode)
        case .empty:
            Image(systemName: "waveform.slash")
                .font(.system(size: 18)).foregroundStyle(.secondary)
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18)).foregroundStyle(.tint)
        case .warming:
            ProgressView().controlSize(.small)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .recording:
            Equalizer(level: model.level)
            Text(timeString(model.elapsed))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        case .transcribing:
            Text(L("Recognizing…")).font(.system(size: 14, weight: .medium))
        case .done:
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Inserted")).font(.system(size: 13, weight: .medium))
                if model.words > 0 {
                    Text(Lf("Words: %d · %.1f s", model.words, model.seconds))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .empty:
            Text(L("Didn't catch that — hold the key while you speak"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                if model.downloadProgress < 0.999 {
                    Text(Lf("Downloaded %d of %d MB", Int(model.downloadProgress * 950), 950))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                    ProgressView(value: model.downloadProgress).frame(width: 150)
                } else {
                    Text(L("Warming up the model…")).font(.system(size: 12, weight: .medium))
                }
            }
        case .warming:
            Text(L("Warming up the model…")).font(.system(size: 13, weight: .medium))
        case .cancelled:
            Text(L("Cancelled")).font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 11, height: 11)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct Equalizer: View {
    let level: Double
    // Bell-curve weights: center bars are taller
    private let weights: [Double] = [0.35, 0.55, 0.75, 0.95, 1.0, 0.95, 0.75, 0.55, 0.35]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Brand.gradient)
                    .frame(width: 3.5, height: barHeight(i))
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let minH = 3.0
        let maxH = 24.0
        let h = minH + (maxH - minH) * level * weights[i]
        return CGFloat(max(minH, h))
    }
}
