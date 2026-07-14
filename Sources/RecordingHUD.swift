import AppKit
import SwiftUI

/// Floating status panel at the bottom of the screen. Never takes focus or mouse events.
final class HUDModel: ObservableObject {
    enum Mode: Equatable {
        case recording, transcribing, empty, downloading, warming, cancelled, copied, micBusy
    }

    @Published var mode: Mode = .recording
    @Published var level: Double = 0
    @Published var elapsed: Int = 0
    @Published var downloadProgress: Double = 0
    /// Determinate transcription: fraction of audio processed (monotonic) + words so far.
    @Published var transcribeFraction: Double = 0
    @Published var transcribeWords: Int = 0
    /// Bumped on every level update — drives the equalizer ripple.
    @Published var levelTick = 0
}

final class RecordingHUD {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var elapsedTimer: Timer?
    private var hideWork: DispatchWorkItem?
    /// True between show() and hide(): the pill is meant to be on screen. A
    /// hide() fade that finishes AFTER a new show() must not order the panel
    /// out. Reading panel.alphaValue in the completion proved unreliable — the
    /// window's model alphaValue reads 0 even once a fresh show() has animated
    /// it back toward 1, so the guard never fired (0 "hide skipped" in logs)
    /// and every rapid re-press flashed the Recording pill for ~8 ms then
    /// ordered it out. This explicit intent flag decides it deterministically.
    private var wantsVisible = false

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
        if model.mode != .transcribing {
            model.transcribeFraction = 0
            model.transcribeWords = 0
        }
        model.mode = .transcribing
        show()
    }

    /// Progress from the recognizer. The bar only moves forward: chunks finish
    /// at uneven speed, and a bar that jumps back reads as a glitch. Capped at
    /// 97% — the "Inserted" state tops the strip up for real.
    func setTranscribeProgress(_ fraction: Double, words: Int) {
        guard model.mode == .transcribing else { return }
        model.transcribeFraction = max(model.transcribeFraction, min(fraction, 0.97))
        // Words is the sum across decoding windows and can wobble down as a
        // window's hypothesis is revised mid-decode. Clamp it forward-only —
        // same as the bar — so the counter climbs smoothly instead of jumping.
        model.transcribeWords = max(model.transcribeWords, words)
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

    /// No text cursor: the result went to the clipboard, tell how to get it.
    func showCopied() {
        cancelHide()
        stopElapsed()
        model.mode = .copied
        show()
        scheduleHide(after: 2.5)
    }

    /// Another app holds the mic (voice-processing) — dictation got no audio.
    /// Actionable message so the user knows it's not "speak louder".
    func showMicBusy() {
        cancelHide()
        stopElapsed()
        model.mode = .micBusy
        show()
        scheduleHide(after: 3.0)
    }

    /// Esc pressed: brief flash, then hide.
    func showCancelled() {
        cancelHide()
        stopElapsed()
        model.mode = .cancelled
        show()
        scheduleHide(after: 0.8)
    }

    /// Success has no frame of its own: the text appearing at the cursor IS
    /// the confirmation — the strip just tops up and the pill slips away.
    /// success=false shows the "empty" state (there reality shows nothing,
    /// so the pill is the only messenger).
    func showResult(success: Bool, words: Int = 0, seconds: Double = 0) {
        cancelHide()
        stopElapsed()
        if success {
            guard model.mode == .transcribing else { hide(); return }
            model.transcribeFraction = 1
            scheduleHide(after: 0.55)
        } else {
            model.mode = .empty
            show()
            scheduleHide(after: 1.6)
        }
    }

    private func scheduleHide(after delay: Double) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        stopElapsed()
        wantsVisible = false
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            // A show() may have started while this fade was in flight (rapid
            // back-to-back dictations) — its completion must not yank the
            // freshly shown pill off screen. show() sets wantsVisible = true,
            // so a re-press between hide() and this completion cancels the
            // order-out. Only order out if nothing asked to be visible since.
            guard let self, let panel else { return }
            if self.wantsVisible {
                Log.d("hud: hide skipped — a new show is in flight")
            } else {
                panel.orderOut(nil)
                Log.d("hud: hidden (ordered out)")
            }
        }
    }

    /// Test hook: is the pill currently ordered onto the screen? Used by the
    /// rapid-re-press regression test to prove a stale hide completion no
    /// longer orders a freshly shown pill out.
    var pillIsOnScreen: Bool { panel?.isVisible ?? false }

    func setLevel(_ level: Double) {
        // Weighted toward the new sample so the bars track speech peaks snappily
        // instead of averaging them into a gentle breathing motion.
        model.level = model.level * 0.35 + level * 0.65
        model.levelTick &+= 1
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
        wantsVisible = true
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        Log.d("hud: show \(model.mode) visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) origin=\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))")
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
        // .moveToActiveSpace, not .canJoinAllSpaces: the pill must appear on
        // whatever Space is active at show() time, INCLUDING another app's
        // full-screen Space. canJoinAllSpaces+stationary left the panel on
        // desktop Spaces only — invisible while dictating into a full-screen
        // app (log signature: "hud: show … activeSpace=false").
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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

    // One accent (the brand gradient) plus a single earned semantic color —
    // the red REC dot. Neutral states stay gray; no system blue, no green.
    // The pill is one permanent skeleton (icon slot · title · metric · strip):
    // state changes mutate parameters of the SAME views, so transitions read
    // as one object changing shape, not as screens replacing each other.
    @ViewBuilder
    private var icon: some View {
        switch model.mode {
        case .recording, .transcribing, .warming:
            // one structural branch → stable identity: the dot recolors in place
            PulsingDot(fill: model.mode == .recording
                       ? AnyShapeStyle(Color.red)
                       : AnyShapeStyle(Brand.gradientDiagonal))
        case .empty:
            Image(systemName: "waveform.slash")
                .font(.system(size: 18)).foregroundStyle(.secondary)
        case .micBusy:
            Image(systemName: "mic.slash")
                .font(.system(size: 17)).foregroundStyle(.secondary)
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18)).foregroundStyle(Brand.gradientDiagonal)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 18)).foregroundStyle(.secondary)
        case .copied:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 17)).foregroundStyle(.secondary)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(titleIsSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                if let metric {
                    Spacer(minLength: 8)
                    Text(metric)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let phase = stripPhase {
                WaveStrip(phase: phase, level: model.level,
                          tick: model.levelTick, fraction: stripFraction)
            }
        }
    }

    private var title: String {
        switch model.mode {
        case .recording: return L("Recording…")
        case .transcribing: return L("Recognizing…")
        case .empty: return L("Sorry, I didn't catch that — could you say it again?")
        case .micBusy: return L("Another app is using the microphone right now — close it and try again")
        case .downloading:
            return model.downloadProgress < 0.999
                ? Lf("Downloaded %d of %d MB", Int(model.downloadProgress * 950), 950)
                : L("Warming up the model…")
        case .warming: return L("Warming up the model…")
        case .cancelled: return L("Cancelled")
        case .copied: return L("Not inserted — text copied, press ⌘V to paste")
        }
    }

    private var titleFont: Font {
        switch model.mode {
        case .empty, .copied, .micBusy: return .system(size: 11, weight: .medium)
        case .downloading: return .system(size: 12, weight: .medium).monospacedDigit()
        default: return .system(size: 13, weight: .medium)
        }
    }

    private var titleIsSecondary: Bool {
        switch model.mode {
        case .empty, .cancelled, .copied, .micBusy: return true
        default: return false
        }
    }

    private var metric: String? {
        switch model.mode {
        case .recording: return timeString(model.elapsed)
        case .transcribing: return Lf("Words: %d", model.transcribeWords)
        default: return nil
        }
    }

    /// nil hides the strip (terminal informational flashes).
    private var stripPhase: WaveStrip.Phase? {
        switch model.mode {
        case .recording: return .voice
        case .transcribing, .downloading, .warming: return .progress
        case .empty, .cancelled, .copied, .micBusy: return nil
        }
    }

    private var stripFraction: Double {
        switch model.mode {
        case .transcribing: return model.transcribeFraction
        case .downloading: return model.downloadProgress
        default: return 0
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One permanent row of 23 brand capsules: the equalizer and the progress bar
/// are the same objects changing height and color — dancing while recording,
/// settling into a segmented bar that fills capsule by capsule while
/// recognizing, topping up right before the pill slips away.
private struct WaveStrip: View {
    enum Phase { case voice, progress }
    let phase: Phase
    let level: Double
    /// Bumps with every level update — gives each capsule its own motion.
    let tick: Int
    let fraction: Double

    // Bell-curve weights: center capsules are taller when dancing
    private static let weights: [Double] = (0..<23).map { 0.35 + 0.65 * sin(.pi * Double($0) / 22) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { i in
                Capsule()
                    .fill(i < litCount ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.quaternary))
                    .frame(width: 3.5, height: barHeight(i))
            }
        }
        .frame(width: 150, height: 16, alignment: .leading)
        .animation(.easeOut(duration: 0.12), value: tick)
        .animation(.spring(duration: 0.45), value: phase)
        .animation(.easeOut(duration: 0.25), value: litCount)
    }

    /// How many capsules are lit with the gradient.
    private var litCount: Int {
        switch phase {
        case .voice: return Self.weights.count
        case .progress: return Int((fraction * Double(Self.weights.count)).rounded())
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        guard case .voice = phase else { return 5 }
        // ×3 boost: the 12 pt strip needs full swing at normal speech volume.
        // The ripple gives capsules individual motion instead of one breath.
        let boosted = min(1.0, level * 1.6)
        let ripple = 0.55 + 0.45 * sin(Double(tick) * 0.6 + Double(i) * 1.7)
        let h = 2.5 + 12.5 * boosted * Self.weights[i] * ripple
        return CGFloat(max(2.5, h))
    }
}

private struct PulsingDot<S: ShapeStyle>: View {
    let fill: S
    @State private var on = false
    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 11, height: 11)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

