import AppKit
import SwiftUI

/// Floating status panel at the bottom of the screen. Never takes focus or mouse events.
final class HUDModel: ObservableObject {
    enum Mode: Equatable {
        case recording, transcribing, empty, downloading, cancelled, copied, micBusy, tooQuiet,
             tooLoud, translateTip, translateDataMissing
    }

    @Published var mode: Mode = .recording
    /// The current dictation runs on the translate key — the pill confirms the
    /// mode (cyan accent + its own texts), so "did I hold the right key?" is
    /// answered while speaking, and the feature stays visible in daily use.
    @Published var translate = false
    /// Name of the app holding the mic, for the .micBusy message (nil = generic).
    @Published var busyApp: String?
    /// Display name of the translate key, for the .translateTip message.
    @Published var tipKeyName = ""
    /// Rolling live transcription shown while recording ("" = none yet).
    @Published var liveText = ""
    /// The voice level lives in an object of its OWN, not in a @Published
    /// property of this model. It changes about twelve times a second while
    /// recording, and every one of those changes used to re-render the entire
    /// pill — icon, title, metric, hint line and material — to move some bars
    /// by a pixel. Split out, a level invalidates the equalizer and nothing
    /// else — measured, 0.7% of a core off every dictation on top of the rest.
    let level = LevelReading()
    @Published var elapsed: Int = 0
    @Published var downloadProgress: Double = 0
    /// Size of the model being downloaded (fast and translate models differ).
    @Published var downloadTotalMB = 950
    /// Determinate transcription: fraction of audio processed (monotonic) + words so far.
    @Published var transcribeFraction: Double = 0
    @Published var transcribeWords: Int = 0
}

/// The one number that changes at audio rate, on its own so that only the
/// equalizer redraws when it does.
final class LevelReading: ObservableObject {
    @Published var value: Double = 0
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

    func showRecording(translate: Bool = false) {
        cancelHide()
        model.translate = translate
        model.mode = .recording
        model.level.value = 0
        model.elapsed = 0
        model.liveText = ""
        startElapsed()
        show()
    }

    /// Rolling live transcription while the user speaks (fast-model preview).
    func setLivePreview(_ text: String) {
        guard model.mode == .recording else { return }
        model.liveText = text
    }

    func showTranscribing(translate: Bool = false) {
        cancelHide()
        stopElapsed()
        if model.mode != .transcribing {
            model.transcribeFraction = 0
            model.transcribeWords = 0
        }
        model.translate = translate
        model.mode = .transcribing
        show()
    }

    /// One-time discovery nudge: the user has a translate key configured but
    /// has never used it (see AppDelegate.maybeShowTranslateTip for the gates).
    func showTranslateTip(keyName: String) {
        cancelHide()
        stopElapsed()
        model.tipKeyName = keyName
        model.mode = .translateTip
        show()
        scheduleHide(after: 5.0)
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

    func showDownloading(_ progress: Double, totalMB: Int) {
        cancelHide()
        stopElapsed()
        model.downloadProgress = progress
        model.downloadTotalMB = totalMB
        model.mode = .downloading
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
    func showMicBusy(appName: String? = nil) {
        cancelHide()
        stopElapsed()
        model.busyApp = appName
        model.mode = .micBusy
        show()
        scheduleHide(after: 3.0)
    }

    /// The text was inserted, but in the spoken language: macOS has no
    /// translation data for the pair. Longer on screen than the other
    /// notices — it asks the user to go somewhere and do something.
    func showTranslateDataMissing() {
        cancelHide()
        stopElapsed()
        model.mode = .translateDataMissing
        show()
        scheduleHide(after: 4.0)
    }

    /// Audio came in but was far too quiet / too loud for recognition — a
    /// specific nudge instead of the generic "didn't catch that".
    func showTooQuiet() { showLevelNotice(.tooQuiet) }
    func showTooLoud() { showLevelNotice(.tooLoud) }

    private func showLevelNotice(_ mode: HUDModel.Mode) {
        cancelHide()
        stopElapsed()
        model.mode = mode
        show()
        scheduleHide(after: 2.5)
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
    func showResult(success: Bool) {
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
        model.level.value = model.level.value * 0.35 + level * 0.65
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
        // Reset position and alpha only when the pill is actually off screen.
        // A state change on a visible pill (recording → transcribing) must not
        // drop it to alpha 0 and fade back in — that reads as a flash, the
        // opposite of the "one object changing shape" design.
        if !panel.isVisible {
            position(panel)
            panel.alphaValue = 0
        }
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
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 70)

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
        .padding(.vertical, 10)
        .frame(width: 260, height: 70)
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
        case .recording, .transcribing:
            // one structural branch → stable identity: the dot recolors in place.
            // Translate mode is cyan — the color bound to "→ English" since the
            // onboarding key cards, kept consistent through daily use.
            PulsingDot(fill: model.mode == .recording
                       ? (model.translate ? AnyShapeStyle(Brand.cyan) : AnyShapeStyle(Color.red))
                       : AnyShapeStyle(Brand.gradientDiagonal))
        case .translateTip:
            Image(systemName: "globe")
                .font(.system(size: 17)).foregroundStyle(Brand.cyan)
        case .translateDataMissing:
            // Same globe as the tip, but gray: this one reports a shortfall,
            // and gray is what every other "didn't work" pill wears.
            Image(systemName: "globe")
                .font(.system(size: 17)).foregroundStyle(.secondary)
        case .empty:
            Image(systemName: "waveform.slash")
                .font(.system(size: 18)).foregroundStyle(.secondary)
        case .micBusy:
            Image(systemName: "mic.slash")
                .font(.system(size: 17)).foregroundStyle(.secondary)
        case .tooQuiet:
            Image(systemName: "speaker.wave.1")
                .font(.system(size: 16)).foregroundStyle(.secondary)
        case .tooLoud:
            Image(systemName: "speaker.wave.3")
                .font(.system(size: 16)).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 3) {
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
                WaveStrip(phase: phase, level: model.level, fraction: stripFraction)
            }
            // Live transcription takes the hint line's slot while recording:
            // the tail of what's been heard so far, growing from the right.
            if model.mode == .recording, !model.liveText.isEmpty {
                Text(model.liveText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if let cancelHint {
                Text(cancelHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A quiet affordance line: Esc bails out of the current dictation. Shown
    /// only while there's something to cancel — recording or recognizing.
    private var cancelHint: String? {
        switch model.mode {
        case .recording, .transcribing: return L("Esc to cancel")
        default: return nil
        }
    }

    private var title: String {
        switch model.mode {
        case .recording:
            guard model.translate else { return L("Recording…") }
            let target = Settings.shared.translateTargetCode
            return target == "en" ? L("Recording → English…")
                                  : Lf("Recording → %@…", LanguageList.endonym(for: target))
        case .transcribing:
            return model.translate ? L("Translating…") : L("Recognizing…")
        case .translateTip:
            return Lf("Tip: hold %@ instead — your speech comes out in English.", model.tipKeyName)
        case .empty: return L("Sorry, I didn't catch that — could you say it again?")
        case .micBusy:
            if let app = model.busyApp, !app.isEmpty {
                return Lf("%@ is using the microphone right now — close it and try again", app)
            }
            return L("Another app is using the microphone right now — close it and try again")
        case .tooQuiet: return L("That was very quiet — move closer to the microphone")
        case .tooLoud: return L("That was too loud — move back a little from the microphone")
        case .translateDataMissing:
            return L("Translation data isn't downloaded — open Settings to get it")
        case .downloading:
            let total = model.downloadTotalMB
            return model.downloadProgress < 0.999
                ? Lf("Downloaded %d of %d MB", Int(model.downloadProgress * Double(total)), total)
                : L("Warming up the model…")
        case .cancelled: return L("Cancelled")
        case .copied: return L("Not inserted — text copied, press ⌘V to paste")
        }
    }

    private var titleFont: Font {
        switch model.mode {
        case .empty, .copied, .micBusy, .tooQuiet, .tooLoud, .translateTip, .translateDataMissing:
            return .system(size: 11, weight: .medium)
        case .downloading: return .system(size: 12, weight: .medium).monospacedDigit()
        default: return .system(size: 13, weight: .medium)
        }
    }

    private var titleIsSecondary: Bool {
        switch model.mode {
        case .empty, .cancelled, .copied, .micBusy, .tooQuiet, .tooLoud, .translateDataMissing:
            return true
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
        case .transcribing, .downloading: return .progress
        case .empty, .cancelled, .copied, .micBusy, .tooQuiet, .tooLoud, .translateTip,
             .translateDataMissing: return nil
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
///
/// This strip is on screen for every dictation, which is why what it used to
/// cost matters: measured with the pill up and levels arriving at the real
/// rate, the HUD burned 34.4% of a CPU core just to DRAW itself — while the
/// same machine was recording audio and about to run Whisper. Two causes, both
/// now fixed and both worth remembering.
///
/// The bars animated `frame(height:)`. That is a LAYOUT animation: SwiftUI
/// re-lays out the pill sixty times a second, and it did so continuously,
/// because a fresh `.easeOut(0.12)` was started by every audio level — about
/// twelve a second, each one longer than the gap to the next.
///
/// What replaced it is deliberately NOT a `TimelineView`, which is the cheap
/// answer everywhere else in this app. Measured here, wrapping this strip in a
/// periodic timeline cost 6.4% of a core — and it cost the same at 4 Hz as at
/// 12 Hz, which is the tell: a timeline over drawn content keeps the hosting
/// view waking at the display's refresh rate whatever cadence you ask for, and
/// only the visible result is coarse.
///
/// So the strip has no clock of its own. It is redrawn by the thing it reports
/// on: an audio level arrives about twelve times a second and that is exactly
/// when the meter has something new to say. The ripple phase comes from the
/// clock read at draw time, so consecutive levels still land at different
/// points of the wave and the bars dance rather than pump as one — a flat meter
/// reads as "it can't hear me", which is the complaint this strip exists to
/// answer. Nothing here has an implicit animation on it, and nothing polls.
private struct WaveStrip: View {
    enum Phase { case voice, progress }
    let phase: Phase
    /// Observed here and nowhere else — see LevelReading.
    @ObservedObject var level: LevelReading
    let fraction: Double
    /// The equalizer is information, not decoration, so Reduce Motion keeps the
    /// level response and loses only the per-capsule ripple.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Bell-curve weights: center capsules are taller when dancing
    private static let weights: [Double] = (0..<23).map { 0.35 + 0.65 * sin(.pi * Double($0) / 22) }
    private static let barWidth: CGFloat = 3.5
    private static let spacing: CGFloat = 3

    var body: some View {
        bars(at: reduceMotion ? nil : Date())
            .frame(width: 150, height: 16, alignment: .leading)
    }

    /// The whole strip in ONE drawing pass — the lit run and the unlit rest as
    /// two paths inside a single `Canvas`.
    ///
    /// A Canvas builds no views: it hands two paths to a graphics context. The
    /// row used to be 23 `Capsule` views, and rebuilding that little view tree
    /// on every audio level is most of what the old strip charged for.
    private func bars(at date: Date?) -> some View {
        let heights = Self.weights.indices.map { height($0, at: date) }
        let lit = litCount
        return Canvas(opaque: false) { context, size in
            var restPath = Path()
            var x: CGFloat = 0
            for (i, height) in heights.enumerated() {
                defer { x += Self.barWidth + Self.spacing }
                let rect = CGRect(x: x, y: size.height / 2 - height / 2,
                                  width: Self.barWidth, height: height)
                let bar = Path(roundedRect: rect, cornerRadius: Self.barWidth / 2)
                guard i < lit else { restPath.addPath(bar); continue }
                // The brand ramp runs top-to-bottom through EACH capsule, as it
                // always has here: a lit bar is indigo at its cap and cyan at
                // its foot whatever its height, which is what keeps the strip
                // colourful when the bars are short.
                context.fill(bar, with: .linearGradient(
                    Gradient(colors: [Brand.indigo, Brand.cyan]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            }
            context.fill(restPath, with: .style(.quaternary))
        }
    }

    /// How many capsules are lit with the gradient.
    private var litCount: Int {
        switch phase {
        case .voice: return Self.weights.count
        case .progress: return Int((fraction * Double(Self.weights.count)).rounded())
        }
    }

    private func height(_ i: Int, at date: Date?) -> CGFloat {
        guard case .voice = phase else { return 5 }
        // ×1.6 boost: the strip needs full swing at normal speech volume. The
        // ripple gives capsules individual motion instead of one breath — and
        // it runs off the clock, so the meter keeps moving between level
        // samples instead of stepping twelve times a second.
        let boosted = min(1.0, level.value * 1.6)
        let phase = (date?.timeIntervalSinceReferenceDate ?? 0) * 7.5 + Double(i) * 1.7
        let ripple = date == nil ? 1 : 0.55 + 0.45 * sin(phase)
        return CGFloat(max(2.5, 2.5 + 12.5 * boosted * Self.weights[i] * ripple))
    }
}

/// The recording dot, blinked by a clock.
///
/// It used to fade on a `.repeatForever(autoreverses:)` animation, and that one
/// dot cost 8.9% of a core for as long as the pill was up: a repeatForever
/// animation never settles, so SwiftUI asks the window for another frame sixty
/// times a second, forever, and keeps doing it after the view that started it
/// is gone. A blink needs two frames a second. A periodic `TimelineView` gives
/// exactly that and stops itself when the dot goes away.
private struct PulsingDot<S: ShapeStyle>: View {
    let fill: S
    /// Blinking is motion; a steady dot says "recording" just as well.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static var beat: TimeInterval { 0.6 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.beat)) { context in
            Circle()
                .fill(fill)
                .frame(width: 11, height: 11)
                .opacity(reduceMotion || lit(context.date) ? 1 : 0.35)
        }
    }

    private func lit(_ date: Date) -> Bool {
        Int(date.timeIntervalSinceReferenceDate / Self.beat) % 2 == 0
    }
}

