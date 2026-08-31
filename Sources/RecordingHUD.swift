import AppKit
import SwiftUI

/// Floating status panel at the bottom of the screen. Never takes focus or mouse events.
final class HUDModel: ObservableObject {
    enum Mode: Equatable {
        case warming
        case recording, transcribing, empty, downloading, cancelled, copied, micBusy, tooQuiet,
             tooLoud, translateTip, translateDataMissing, inserted
    }

    @Published var mode: Mode = .recording
    /// Name of the app the text was inserted into (.inserted; nil = unknown).
    @Published var insertedApp: String?
    /// The delivered text — previewed in the .inserted and .copied states so
    /// the confirmation shows WHAT landed (or what is waiting in the clipboard).
    @Published var resultText = ""
    /// What a click on the pill does in the modes that accept the mouse
    /// (translateTip → dismiss for good, translateDataMissing → open Settings).
    /// Plain var: actions don't render.
    var tapAction: (() -> Void)?
    /// A meeting is being recorded at the same time — the overlay says so
    /// with one quiet line, or the two surfaces tell different stories (8d).
    @Published var alsoMeeting = false
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
    /// >0 while a NEW recording starts before the previous dictation finished
    /// recognizing (design: queued) — a quiet top line says so, and the
    /// footer promises the order.
    @Published var queuedBehind = 0
    /// Words the still-recognizing previous dictation had reached.
    @Published var queuedWords = 0
    /// Live typing engaged: committed words go straight into this app, so the
    /// panel narrates typing instead of previewing (design: liveTyping).
    /// nil = not live typing; "" = live typing into an unnamed app.
    @Published var liveTypingApp: String?
    /// Words already typed into the document this dictation.
    @Published var typedWords = 0
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

@MainActor
final class RecordingHUD {
    private let model = HUDModel()
    /// Where "Translation data isn't downloaded" sends the user on click. The
    /// pill cannot host the macOS translation consent itself (GRABLI: consent
    /// sheets need a real window), so the click opens Settings, which can.
    var onOpenSettings: (() -> Void)?
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

    func showRecording(translate: Bool = false, alsoMeeting: Bool = false,
                       queuedBehind: Int = 0) {
        cancelHide()
        model.translate = translate
        model.alsoMeeting = alsoMeeting
        // The previous dictation is still recognizing — carry its word count
        // into the queued top line before the transcribing display resets.
        model.queuedBehind = queuedBehind
        model.queuedWords = queuedBehind > 0 ? model.transcribeWords : 0
        model.liveTypingApp = nil
        model.typedWords = 0
        model.mode = .recording
        model.level.value = 0
        model.elapsed = 0
        model.liveText = ""
        startElapsed()
        show()
    }

    /// The model is still loading — the first seconds after launch. The
    /// panel says so instead of pretending to record, and flips back to
    /// recording the moment the engine is ready (design DictationOverlay:
    /// warming). Capture keeps running underneath either way.
    func setWarming(_ on: Bool) {
        if on {
            guard model.mode == .recording else { return }
            model.mode = .warming
        } else {
            guard model.mode == .warming else { return }
            model.mode = .recording
        }
    }

    /// Live typing engaged for the current recording: the panel switches to
    /// the typing narration ("Typing into X as you speak").
    func setLiveTyping(app: String?) {
        guard model.mode == .recording else { return }
        model.liveTypingApp = app ?? ""
    }

    /// Forward-only word count of what live typing already put in the document.
    func setTypedWords(_ count: Int) {
        guard model.mode == .recording else { return }
        model.typedWords = max(model.typedWords, count)
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
        // A click is "got it": the tip never comes back. The keyboard user
        // loses nothing — the tip auto-dismisses and is capped at two showings
        // anyway; the click only skips the reminder.
        model.tapAction = { [weak self] in
            Settings.shared.translateTipCount = 2
            self?.hide()
        }
        model.mode = .translateTip
        show()
        // No auto-hide: an actionable state that can vanish mid-reach is a
        // target nobody can trust (design review, 2026-08-27). It waits until
        // clicked or until the next dictation replaces it.
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

    /// No text cursor: the result went to the clipboard, tell how to get it —
    /// and show what "it" is, so the recovery is worth the ⌘V.
    func showCopied(text: String = "") {
        cancelHide()
        stopElapsed()
        model.resultText = text
        model.mode = .copied
        show()
        scheduleHide(after: 2.5)
    }

    /// The text landed. Brief confirmation naming the app it went into, with a
    /// preview of what was delivered — then nothing remains on screen.
    func showInserted(app: String?, text: String) {
        cancelHide()
        stopElapsed()
        model.insertedApp = app
        model.resultText = text
        model.mode = .inserted
        show()
        scheduleHide(after: 1.4)
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
        model.tapAction = { [weak self] in
            self?.onOpenSettings?()
            self?.hide()
        }
        model.mode = .translateDataMissing
        show()
        // Persists like the tip: it carries an action (open Settings), so it
        // stays until acted on or superseded. The menu's "Language Packs…" is
        // the keyboard-reachable twin.
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
        // main-queue dispatch, main by construction
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
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
            MainActor.assumeIsolated {   // animation completion, main by construction
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
    }

    /// Test hook: is the pill currently ordered onto the screen? Used by the
    /// rapid-re-press regression test to prove a stale hide completion no
    /// longer orders a freshly shown pill out.
    var pillIsOnScreen: Bool { panel?.isVisible ?? false }


    func setLevel(_ level: Double) {
        // An attack/decay envelope rather than one symmetric low-pass
        // (owner's remark 2026-08-28 — the bar felt twitchy). Second pass
        // 2026-08-29 ("still aggressive"): the rise now spreads over ~4
        // samples (~a third of a second) and the fall drains even slower —
        // the bar breathes with the sentence, not with every syllable.
        let current = model.level.value
        // Owner tuning 2026-08-31: +25% response on both edges (0.35→0.44
        // rise, 0.12→0.15 fall) — livelier without going back to twitchy.
        model.level.value = level > current
            ? current * 0.56 + level * 0.44
            : current * 0.85 + level * 0.15
    }

    // MARK: - private

    private func startElapsed() {
        stopElapsed()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {   // runloop timer, main by construction
                self?.model.elapsed += 1
            }
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
        // Only the two actionable notices take the mouse; every other state
        // keeps the pill click-through, exactly as it has always been. A
        // stale action from a previous notice must not make, say, the
        // recording pill clickable.
        if model.mode != .translateTip, model.mode != .translateDataMissing {
            model.tapAction = nil
        }
        panel.ignoresMouseEvents = model.tapAction == nil
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
        hosting.frame = NSRect(x: 0, y: 0, width: HUDView.panelSize.width, height: HUDView.panelSize.height)

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
    @State private var noticeHover = false

    /// The panel takes the mouse only in these two states (see show()).
    private var tappable: Bool {
        model.mode == .translateTip || model.mode == .translateDataMissing
    }

    /// The design's 452 pt panel (13h): a fixed grammar top to bottom —
    /// status line (glyph · title · time), the text, the level bar, the key
    /// hint — so the eye lands in the same spot whatever the state. The
    /// hosting frame is taller than any state needs; the drawn material is
    /// what the window shadow hugs.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The previous dictation is still recognizing while a new one
            // records (design: queued): a dimmed line above the live status,
            // separated by a hairline — two facts, one panel, no alarm.
            if model.mode == .recording, model.queuedBehind > 0 {
                HStack(spacing: 9) {
                    TimelineView(.periodic(from: .now, by: 0.35)) { context in
                        GlyphMark(state: .recognizing(phase:
                            Int(context.date.timeIntervalSinceReferenceDate / 0.35)),
                            color: .secondary, width: 15)
                    }
                    Text(model.queuedWords > 0
                         ? Lf("Still recognizing the previous dictation · %d words",
                              model.queuedWords)
                         : L("Still recognizing the previous dictation"))
                        .font(DS.helpText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Lf("%d waiting", model.queuedBehind))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { Divider() }
            }
            HStack(spacing: 9) {
                icon
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(titleIsSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let metric {
                    Text(metric)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 14, trailing: 15))
        .frame(width: 452, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous))
        // The two actionable notices are the only states that accept the
        // mouse — say so before the click: link cursor plus a translate-tint
        // ring on hover (a wash behind the material would be invisible).
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                .strokeBorder(DS.translate.opacity(tappable && noticeHover ? 0.5 : 0),
                              lineWidth: 1.5)
        )
        .onHover { noticeHover = $0 }
        .pointerStyle(tappable ? .link : .default)
        .animation(.easeOut(duration: DS.fade), value: noticeHover)
        .onTapGesture { model.tapAction?() }
        .animation(.easeInOut(duration: 0.2), value: model.mode)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: model.liveText)
        .animation(.easeOut(duration: 0.2), value: model.alsoMeeting)
        .animation(.easeOut(duration: 0.2), value: model.queuedBehind)
        .animation(.easeOut(duration: 0.2), value: model.liveTypingApp)
        // Bottom-anchored inside the fixed frame: the pill sits near the
        // bottom of the screen, so extra states (queued, the meeting line)
        // grow UPWARD and the pill's resting edge never moves.
        .frame(width: HUDView.panelSize.width, height: HUDView.panelSize.height,
               alignment: .bottom)
    }

    /// The fixed hosting frame — roomy enough for the tallest state (queued
    /// top section + three lines of live text + the meeting line). The drawn
    /// material hugs the content; the spare frame is invisible.
    static let panelSize = CGSize(width: 452, height: 244)

    // The mark family is the ONLY drawing of the five states (identity, turn
    // 11): recording is the bars glyph (translate colour when translating),
    // recognizing the dots-on-the-line, and the glyph holds STILL while the
    // level bar below carries the motion (13a). Failure notices keep their
    // small symbols — they are not among the five states.
    @ViewBuilder
    private var icon: some View {
        switch model.mode {
        case .recording:
            GlyphMark(state: .recording(level: 1),
                      color: model.translate ? DS.translate : DS.accent)
        case .transcribing, .warming:
            // The dots walk — a TimelineView that stops itself with the view;
            // recognizing has no level, so this is the surface's one motion.
            TimelineView(.periodic(from: .now, by: 0.35)) { context in
                GlyphMark(state: .recognizing(phase:
                    Int(context.date.timeIntervalSinceReferenceDate / 0.35)),
                    color: model.translate ? DS.translate : DS.accent)
            }
        case .translateTip:
            Image(systemName: "globe")
                .font(.system(size: 17)).foregroundStyle(DS.translate)
        case .translateDataMissing:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 17)).foregroundStyle(DS.translate)
        case .empty:
            Image(systemName: "waveform.slash")
                .font(.system(size: 18)).foregroundStyle(.secondary)
        case .micBusy:
            Image(systemName: "mic.slash")
                .font(.system(size: 17)).foregroundStyle(DS.warn)
        case .tooQuiet:
            Image(systemName: "speaker.wave.1")
                .font(.system(size: 16)).foregroundStyle(DS.warn)
        case .tooLoud:
            Image(systemName: "speaker.wave.3")
                .font(.system(size: 16)).foregroundStyle(DS.record)
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18)).foregroundStyle(DS.accent)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 18)).foregroundStyle(.secondary)
        case .copied:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 17)).foregroundStyle(DS.warn)
        case .inserted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(DS.good)
        }
    }

    /// Below the status line, in the design's fixed order: the TEXT at
    /// reading size (16, three lines, newest words kept), then the level bar,
    /// then the hint.
    @ViewBuilder
    private var content: some View {
        // Live transcription while recording — the panel's main event, at
        // 16 pt (13h). Head-truncated: the newest words are the ones being
        // checked against what was just said.
        if model.mode == .recording, model.liveTypingApp != nil {
            // Live typing (design: liveTyping): the document already holds the
            // words, so the panel shows the count and only the unconfirmed
            // tail — one line, head-truncated.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Lf("%d words typed", model.typedWords))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Text(model.liveText)
                    .font(.system(size: 16))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .contentTransition(.interpolate)
                    .padding(.trailing, 6)
                    // The oldest words leave through a soft edge, not a hard
                    // cut — only once the line is actually overflowing.
                    .mask(LinearGradient(
                        stops: [.init(color: .black.opacity(model.liveText.count > 40 ? 0 : 1),
                                      location: 0),
                                .init(color: .black,
                                      location: model.liveText.count > 40 ? 0.12 : 0)],
                        startPoint: .leading, endPoint: .trailing))
            }
        } else if model.mode == .recording, !model.liveText.isEmpty {
            Text(model.liveText)
                .font(.system(size: 16))
                .lineSpacing(3)
                .lineLimit(3)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                // New words materialize instead of snapping in, and the text
                // keeps a breath of air off the panel's right edge.
                .contentTransition(.interpolate)
                .padding(.trailing, 10)
                // Once all three lines are full the oldest line is being
                // pushed out over the top — let it dissolve there rather
                // than cut. Below that the mask is fully open.
                .mask(LinearGradient(
                    stops: [.init(color: .black.opacity(model.liveText.count > 150 ? 0.1 : 1),
                                  location: 0),
                            .init(color: .black,
                                  location: model.liveText.count > 150 ? 0.3 : 0)],
                    startPoint: .top, endPoint: .bottom))
        } else if (model.mode == .inserted || model.mode == .copied),
                  !model.resultText.isEmpty {
            // What actually landed (or waits in the clipboard) — the
            // confirmation names its object, not just the fact.
            Text(model.resultText)
                .font(.system(size: 14.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let phase = stripPhase {
            WaveStrip(phase: phase, level: model.level, fraction: stripFraction,
                      tint: model.translate ? DS.translate : DS.accent)
        }
        if let cancelHint {
            Text(cancelHint)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        // The queued promise (design): what happens to the two dictations.
        if model.mode == .recording, model.queuedBehind > 0 {
            Text(L("Both will be inserted in the order you spoke them"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        // Both recorders running at once: one quiet line keeps the overlay
        // and the menu bar telling the same story (8d).
        if model.mode == .recording, model.alsoMeeting {
            Text(L("Also recording this meeting"))
                .font(.system(size: 11))
                .foregroundStyle(DS.record)
        }
    }

    /// The affordance line: how to finish, and that Esc bails out. Shown only
    /// while there's something to cancel — recording or recognizing.
    private var cancelHint: String? {
        switch model.mode {
        case .recording:
            // Live typing narrates the mechanism instead (design: liveTyping) —
            // the words are already in the document, nothing waits for release.
            if model.liveTypingApp != nil {
                return L("Only the unconfirmed tail is shown here — the rest is already in the document")
            }
            let key = KeyNames.displayName(model.translate
                ? Settings.shared.translateKeyName : Settings.shared.hotkeyName)
            return Lf("Release %@ to insert", key) + " · " + L("Esc to cancel")
        case .transcribing: return L("Esc to cancel")
        case .warming:
            let key = KeyNames.displayName(model.translate
                ? Settings.shared.translateKeyName : Settings.shared.hotkeyName)
            return Lf("Not ready yet — this takes a few seconds after launch. Keep holding %@ and it will start.", key)
        default: return nil
        }
    }

    private var title: String {
        switch model.mode {
        case .recording:
            // Live typing names its destination (design: liveTyping).
            if let app = model.liveTypingApp {
                return app.isEmpty ? L("Typing as you speak")
                                   : Lf("Typing into %@ as you speak", app)
            }
            guard model.translate else {
                let spoken = Settings.shared.language
                return spoken.isEmpty ? L("Dictating")
                                      : Lf("Dictating in %@", LanguageList.name(for: spoken))
            }
            let target = Settings.shared.translateTargetCode
            return target == "en" ? L("Translating into English")
                                  : Lf("Translating into %@", LanguageList.name(for: target))
        case .transcribing:
            return model.translate ? L("Translating…") : L("Recognizing…")
        case .warming:
            return L("Preparing the model for this Mac")
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
        case .inserted:
            if let app = model.insertedApp, !app.isEmpty {
                return Lf("Inserted into %@", app)
            }
            return L("Inserted")
        }
    }

    private var titleFont: Font {
        switch model.mode {
        case .empty, .copied, .micBusy, .tooQuiet, .tooLoud, .translateTip, .translateDataMissing:
            return .system(size: 12, weight: .semibold)
        case .downloading: return .system(size: 12, weight: .medium).monospacedDigit()
        default: return .system(size: 12, weight: .semibold)
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
        case .recording, .warming: return timeString(model.elapsed)
        case .transcribing: return Lf("Words: %d", model.transcribeWords)
        default: return nil
        }
    }

    /// nil hides the strip (terminal informational flashes).
    private var stripPhase: WaveStrip.Phase? {
        switch model.mode {
        case .recording: return .voice
        case .transcribing, .downloading: return .progress
        case .warming, .empty, .cancelled, .copied, .micBusy, .tooQuiet, .tooLoud, .translateTip,
             .translateDataMissing, .inserted: return nil
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

/// One thin level bar: the equalizer and the progress bar
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
    var tint: Color = DS.accent

    /// One thin bar (13a: one encoding of level, one animated element per
    /// surface). A Canvas, so a level arriving twelve times a second redraws
    /// two paths and never touches layout — the lesson the 23-capsule strip
    /// this replaces was built on stays honoured at a fraction of the ink.
    var body: some View {
        Canvas(opaque: false) { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: size.height / 2)
            context.fill(track, with: .style(.quaternary))
            let filled: CGFloat
            switch phase {
            // ×1.3 boost (was 1.6 — peaks slammed the ceiling): full swing
            // only at genuinely loud speech.
            case .voice: filled = CGFloat(min(1.0, level.value * 1.3))
            case .progress: filled = CGFloat(fraction)
            }
            guard filled > 0.02 else { return }
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0,
                                                  width: size.width * filled,
                                                  height: size.height),
                              cornerRadius: size.height / 2),
                         with: .color(tint))
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
    }
}


