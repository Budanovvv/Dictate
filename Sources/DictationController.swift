import AppKit
import Carbon.HIToolbox

/// A one-shot cancellation flag, safe to read from any thread. One per
/// dictation: the WhisperKit decode callback polls `isCancelled` off the main
/// actor, so it can't be a plain main-thread Bool.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Core logic: hotkey → record → transcribe → insert.
final class DictationController {
    enum State {
        case idle, recording, transcribing
    }

    /// One-shot outcomes that end a dictation without a normal result — the
    /// HUD shows exactly one pill per notice. A single callback (instead of a
    /// callback per case) so adding a notice can't silently miss a subscriber.
    enum Notice {
        /// Recording cancelled via Esc.
        case cancelled
        /// No text cursor — the result went to the clipboard instead of being pasted.
        case copiedInstead
        /// The key was held but the mic delivered no audio because another app
        /// holds it in voice-processing mode (Google Meet, Zoom, FaceTime…).
        /// The payload is that app's name when known, for a specific message.
        case micBusy(String?)
        /// The key was held but nothing was captured (mic still waking from
        /// sleep, device not ready) — tell the user instead of failing silently.
        case nothingHeard
        /// Audio was captured but far too quiet for any speech — suggest moving
        /// closer to the mic instead of the generic "didn't catch that".
        case tooQuiet
        /// Audio was captured but heavily clipped (input gain too high / too
        /// loud) — suggest backing off, so the distortion that defeats
        /// recognition is named.
        case tooLoud
        /// The dictation was translated with Apple Translation, but macOS has
        /// no data for that language pair. The native text is inserted anyway
        /// (nothing is lost) — this says why it came out in the spoken
        /// language and where to fix it.
        case translateDataMissing
    }

    private let monitor = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var paused = false {
        didSet {
            if paused, state == .recording {
                stopLivePreview()
                resetLiveTyping()
                _ = recorder.stop()
                state = .idle
            }
        }
    }
    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?
    /// Voice level 0…1 while recording.
    var onLevel: ((Double) -> Void)?
    /// Transcription progress: fraction of audio processed (0…1) + words so far.
    var onTranscribeProgress: ((Double, Int) -> Void)?
    /// Result ready: success, word count, transcription seconds.
    var onResult: ((Bool, Int, Double) -> Void)?
    /// Transcribed text (for the onboarding "try it" box).
    var onResultText: ((String) -> Void)?
    /// Model download progress 0…1 + total size in MB of the model in flight.
    var onModelDownload: ((Double, Int) -> Void)?
    /// A dictation ended without a normal result — see Notice.
    var onNotice: ((Notice) -> Void)?
    /// Rolling live transcription of the current recording (fast model over
    /// the growing buffer) — the HUD shows it while the user speaks.
    var onLivePreview: ((String) -> Void)?
    /// Recent results, newest first (in memory only — never written to disk).
    private(set) var history: [String] = []
    private(set) var lastStats: (words: Int, seconds: Double)?
    /// Whether the last result came from the translate key (onboarding checklist).
    private(set) var lastWasTranslate = false
    private var tapRetryTimer: Timer?
    private var tapFailureReported = false
    /// Current recording was started by the translate key. Read by the HUD
    /// (via AppDelegate) to show the translate variant of the pill; set BEFORE
    /// state changes to .recording, so onStateChange reads the correct value.
    private(set) var activeTranslate = false
    /// When the current recording's key went down — used to tell an accidental
    /// tap (released almost immediately) from a real attempt that captured no
    /// audio, so only the latter gets a "didn't hear you" message.
    private var pressedAt: Date?
    /// App that was frontmost when the key was RELEASED — the intended paste
    /// target. Captured at release, not press, so "hold key, click into the
    /// target field, speak" stays legal; the guard covers only the recognition
    /// window, where an app switch would send ⌘V to the wrong place.
    private var targetAppPID: pid_t?
    /// Cancels the in-flight recognition. Held so Esc can flip it: the
    /// WhisperKit decode callback reads it from a background thread to stop
    /// early, and finish() reads it to discard a partial result. Thread-safe
    /// because both sides touch it off the main actor.
    private var activeCancel: CancelToken?
    /// The recognition Task, so cancel() can tear it down.
    private var transcribeTask: Task<Void, Never>?
    /// Live preview machinery: a 1.2 s cadence re-decodes the growing buffer
    /// with the fast model. `previewBusy` keeps one decode in flight at most;
    /// the token early-stops a decode the moment the key is released, so the
    /// final transcription never waits behind a stale preview pass.
    private var previewTimer: Timer?
    private var previewBusy = false
    private var previewCancel: CancelToken?
    /// Live typing: non-nil only while this dictation types into the focused
    /// app as the user speaks. Armed once in beginRecording (see armLiveTyping)
    /// and fed from the preview cycle, whose hypotheses it turns into words
    /// that can never need erasing.
    private var liveEngine: CommitEngine?
    /// The app live typing started in. Anything else being frontmost means the
    /// text would land in a foreign window — see typeLive.
    private var liveTargetPID: pid_t?
    /// Live typing is over for this dictation (target app changed, secure
    /// input): the engine keeps committing, but everything from here on is
    /// delivered by the normal paste path at the end.
    private var liveFrozen = false
    /// Committed text that was never typed because we froze — pasted together
    /// with the final remainder, so nothing spoken is lost.
    private var liveUntyped = ""
    /// Last moment the mic was above the speech threshold — live typing's own
    /// VAD, for the silence force-commit.
    private var liveLastLoudAt = Date()
    /// One silence flush per pause — reset the moment speech resumes.
    private var liveSilenceFlushed = false
    /// Silence that flushes the engine's whole tail. The pause tells us the
    /// audio behind those words will not change any more; 0.6 s is long enough
    /// that a between-words breath doesn't trigger it.
    private static let liveSilenceCommit: TimeInterval = 0.6
    /// Every live insertion goes through this one serial queue, enqueued only
    /// from the main actor — so chunks reach the document in commit order and
    /// the final remainder can never overtake them, while TypeInjector's ~2 ms
    /// per 20 characters stays off the main thread.
    private static let typeQueue = DispatchQueue(label: "com.dictate.livetyping")

    private static let soundStart = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)
    private static let soundStop = NSSound(contentsOfFile: "/System/Library/Sounds/Purr.aiff", byReference: true)

    /// Starts the global hotkey capture. Returns false if the tap couldn't be created.
    @discardableResult
    func start() -> Bool {
        var codes: Set<Int64> = [Int64(Settings.shared.hotkeyKeyCode)]
        if let t = Settings.shared.translateKeyCode { codes.insert(Int64(t)) }
        monitor.keyCodes = codes
        monitor.onPress = { [weak self] code in self?.handlePress(code) }
        monitor.onRelease = { [weak self] code in self?.handleRelease(code) }
        monitor.onEsc = { [weak self] in self?.cancel() }
        recorder.onTruncated = { [weak self] in
            self?.onError?(Lf("Recording truncated at %d seconds (limit)", AudioRecorder.maxDurationSec))
        }
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            self.onLevel?(level)
            // AudioRecorder delivers levels on the main thread; the silence
            // flush inside types text (MainActor-isolated), so make the
            // isolation explicit instead of relying on the convention.
            MainActor.assumeIsolated {
                self.liveLevelTick(level: level)
            }
        }
        recorder.onMicBusyDetected = { [weak self] in
            guard let self, self.state == .recording else { return }
            let app = self.recorder.busyAppName
            _ = self.recorder.stop()
            Log.d("mic busy detected early -> stop + notify")
            self.onNotice?(.micBusy(app))   // before .idle so the idle transition can't hide it
            self.state = .idle
        }
        recorder.onRecoveryFailed = { [weak self] nothingRecorded in
            guard let self, self.state == .recording else { return }
            _ = self.recorder.stop()
            self.state = .idle
            self.onError?(nothingRecorded
                ? Lf("Couldn't start recording: %@", L("Microphone unavailable (no input audio format)"))
                : L("Audio device changed during recording — recording cancelled, please try again."))
        }
        let ok = monitor.start()
        if ok {
            tapFailureReported = false
        } else if !tapFailureReported {
            tapFailureReported = true
            onError?(L("Accessibility permission is off, so the key can't be heard. Turn it on in System Settings → Privacy & Security → Accessibility — Dictate picks it up automatically, no restart needed."))
        }
        scheduleTapHealthCheck()
        return ok
    }

    /// Permanent 3 s health check. Covers both directions without a restart:
    /// permission granted later → the failed tap gets created; permission
    /// REVOKED later → the tap silently stops receiving events (no
    /// tapDisabled* arrives for that) and only recreating it can tell — so a
    /// live-looking tap is re-verified too, and the warning fires once.
    private func scheduleTapHealthCheck() {
        guard tapRetryTimer == nil else { return }
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.monitor.isAlive { return }
            Log.d("tap: dead at health check -> recreating")
            if self.monitor.start() {
                Log.d("tap: recreated")
                self.tapFailureReported = false
            } else if !self.tapFailureReported {
                self.tapFailureReported = true
                self.onError?(L("Accessibility permission is off, so the key can't be heard. Turn it on in System Settings → Privacy & Security → Accessibility — Dictate picks it up automatically, no restart needed."))
            }
        }
    }

    /// Loads the already-downloaded model at startup so the first dictation
    /// doesn't wait. A missing model is skipped — transcribeLocal downloads it
    /// lazily with progress when actually needed.
    func preloadModel() {
        Task { await SpeechGate.shared.prewarm() }
        preload(tier: .fast)
    }

    private func preload(tier: ModelTier) {
        guard WhisperEngine.shared.isModelDownloaded(tier: tier) else { return }
        Task {
            // Not fire-and-forget silence: a failed preload (offline tokenizer
            // fetch on a fresh install, HF hiccup) left the onboarding's
            // "Preparing the model…" spinning forever with nothing running.
            // The callers retry; the log names the reason.
            do { try await WhisperEngine.shared.prepare(tier: tier) { _ in } }
            catch { Log.d("model: preload failed: \(error.localizedDescription)") }
        }
    }

    /// Restarts key capture (after the hotkey changes in settings).
    func restart() {
        monitor.stop()
        _ = start()
    }

    func shutdown() {
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        keyStateTimer?.invalidate()
        keyStateTimer = nil
        monitor.stop()
        stopLivePreview()
        resetLiveTyping()
        if state == .recording { _ = recorder.stop() }
    }

    private func isTranslateKey(_ code: Int64) -> Bool {
        if let t = Settings.shared.translateKeyCode { return Int64(t) == code }
        return false
    }

    // Push-to-talk: press starts, release stops.
    private func handlePress(_ code: Int64) {
        Log.d("press code=\(code) state=\(state) paused=\(paused)")
        beginRecording(key: code, translate: isTranslateKey(code))
    }

    private func handleRelease(_ code: Int64) {
        // Only the key that started the recording ends it.
        guard isTranslateKey(code) == activeTranslate else { return }
        Log.d("release code=\(code) state=\(state)")
        endRecording()
    }

    private func beginRecording(key code: Int64, translate: Bool) {
        guard !paused, state == .idle else { return }
        activeTranslate = translate
        pressedAt = Date()
        state = .recording
        startKeyStateWatchdog(key: code)
        Self.soundStart?.play()
        // Wake the target app's accessibility tree now, while the user speaks:
        // Chromium/Electron/WebKit build it lazily and otherwise expose no
        // focused element at paste time, sending dictation to a manual ⌘V even
        // with a live cursor. Doing it here gives the tree seconds to populate.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            Paster.wakeAccessibility(pid: pid)
        }
        // Decided once, here: everything live typing needs to know (the target
        // app, the focus, the settings) is true or false now, and re-asking
        // mid-dictation would only produce a mode that flickers.
        armLiveTyping(translate: translate)
        // Load the model while the user is speaking, so it's warm by the
        // time they release — hides the one-time warm-up behind the speech.
        preloadModel()
        // start() returns immediately now: it hands the blocking input bring-up
        // (which can take seconds on a cold/Bluetooth mic) to a background
        // queue, so the pill renders and the UI stays responsive. It never
        // fails synchronously — the recorder retries a not-yet-ready device and
        // reports via onRecoveryFailed.
        recorder.start()
        startLivePreview()
    }

    // MARK: - Lost-release safety net

    /// A release lost by the event tap (disabled at the wrong moment) used to
    /// leave a push-to-talk recording running until the user pressed again —
    /// seen live 2026-08-06: a 42 s stuck recording pasted garbage. The tap
    /// can't be made lossless, but the PHYSICAL key state can always be read
    /// (CGEventSource.keyState — the same source the tap resync trusts). While
    /// recording, poll it: the key up for two consecutive ticks while we still
    /// think it's held means the release never reached us — stop the recording
    /// as if it had. Costs a lost release at most ~2 s of tail, not 42.
    private var keyStateTimer: Timer?
    private var keyUpTicks = 0

    private func startKeyStateWatchdog(key code: Int64) {
        keyUpTicks = 0
        keyStateTimer?.invalidate()
        keyStateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard state == .recording else {
                keyStateTimer?.invalidate()
                keyStateTimer = nil
                return
            }
            if HotkeyMonitor.isKeyPhysicallyDown(code) {
                keyUpTicks = 0
                return
            }
            keyUpTicks += 1
            guard keyUpTicks >= 2 else { return }
            Log.d("hotkey: key \(code) physically up \(keyUpTicks)s into recording — release was lost, forcing stop")
            endRecording()
        }
    }

    // MARK: - Live preview

    private func startLivePreview() {
        guard Settings.shared.livePreview else { return }
        // 0.75 s: LocalAgreement latency is ~2× this interval, so the cadence
        // is THE live-typing lag knob. previewBusy keeps a slow decode from
        // piling passes up, so a short interval is safe on any machine.
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.previewTick()
        }
    }

    private func stopLivePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewCancel?.cancel()
        previewCancel = nil
    }

    private func previewTick() {
        guard state == .recording, !previewBusy else { return }
        let pcm = recorder.currentPCM()
        // Wait for ≥1 s of audio AND an audible signal — Whisper hallucinates
        // confident phrases on silence, and a phantom preview line is worse
        // than none.
        guard pcm.count >= AudioRecorder.sampleRate * 2, recorder.peakLevel > 0.02 else { return }
        let language = Settings.shared.language
        let prompt = Settings.shared.prompt
        let token = CancelToken()
        previewCancel = token
        previewBusy = true
        Task { [weak self] in
            defer { DispatchQueue.main.async { self?.previewBusy = false } }
            guard await WhisperEngine.shared.isReady(for: .fast) else { return }
            let floats = AudioRecorder.floatSamples(fromPCM: pcm)
            // Long recordings: preview only the tail — a full re-decode of the
            // whole buffer every tick grows quadratically.
            let window = Array(floats.suffix(30 * AudioRecorder.sampleRate))
            let started = Date()
            guard let (text, _) = try? await WhisperEngine.shared.transcribe(
                floats: window, tier: .fast, language: language, prompt: prompt,
                isCancelled: { token.isCancelled }) else { return }
            Log.d(String(format: "live: pass %.2fs over %.1fs audio",
                         Date().timeIntervalSince(started),
                         Double(window.count) / Double(AudioRecorder.sampleRate)))
            await MainActor.run {
                guard let self, self.state == .recording, !token.isCancelled,
                      !text.isEmpty else { return }
                self.handlePreview(text)
            }
        }
    }

    // MARK: - Live typing

    /// A fresh hypothesis over the growing buffer. Without live typing it is
    /// the pill's whole line, as before; with it, the hypothesis is first fed
    /// to the engine, everything that became safe goes into the document, and
    /// only what is still settling stays in the pill — the committed part is
    /// deliberately absent from the HUD, it already lives in the user's app.
    @MainActor
    private func handlePreview(_ text: String) {
        guard let engine = liveEngine else {
            onLivePreview?(text)
            return
        }
        // A pause is the strongest agreement signal there is: flush the tail
        // the engine is still holding before feeding it anything newer.
        if Date().timeIntervalSince(liveLastLoudAt) >= Self.liveSilenceCommit {
            typeLive(liveProcessed(engine.forceCommit().newlyCommitted))
        }
        let update = engine.ingest(hypothesis: text)
        Log.d("live: ingest -> commit \(update.newlyCommitted.count) chars, tail \(update.volatileTail.split(whereSeparator: \.isWhitespace).count) words")
        typeLive(liveProcessed(update.newlyCommitted))
        // Frozen: nothing reaches the document any more, so the pill has to
        // show everything that is still owed — held-back text included.
        onLivePreview?(liveFrozen
            ? (liveUntyped + " " + update.volatileTail).trimmingCharacters(in: .whitespaces)
            : update.volatileTail)
    }

    /// Live typing's own VAD, fed by every level update: the last moment the
    /// mic was above the speech threshold (the same 0.08 hands-free uses).
    /// Silence flushes the engine's tail IMMEDIATELY from here — waiting for
    /// the next preview tick added up to a full interval of extra lag to the
    /// strongest commit signal there is.
    @MainActor
    private func liveLevelTick(level: Double) {
        guard liveEngine != nil, state == .recording else { return }
        if level >= 0.08 {
            liveLastLoudAt = Date()
            liveSilenceFlushed = false
            return
        }
        guard !liveSilenceFlushed, !liveFrozen,
              Date().timeIntervalSince(liveLastLoudAt) >= Self.liveSilenceCommit,
              let engine = liveEngine else { return }
        liveSilenceFlushed = true
        let update = engine.forceCommit()
        guard !update.newlyCommitted.isEmpty else { return }
        Log.d("live: silence flush \(update.newlyCommitted.count) chars")
        typeLive(liveProcessed(update.newlyCommitted))
        onLivePreview?(update.volatileTail)
    }

    /// Decides, once per dictation, whether words go into the app while the
    /// user is still speaking. Every condition here is a reason the mode
    /// cannot work rather than a preference: translation rewrites the text as
    /// a whole (there is nothing stable to type early), the live cycle IS the
    /// preview cycle, and typing needs a text cursor that is ours to write into.
    private func armLiveTyping(translate: Bool) {
        resetLiveTyping()
        guard Settings.shared.liveTyping, !translate, !suppressInsertion,
              Settings.shared.livePreview else { return }
        guard !IsSecureEventInputEnabled() else {
            Log.d("live: secure input is on -> normal mode")
            return
        }
        guard Paster.hasEditableFocus() else {
            Log.d("live: no text focus -> normal mode")
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        liveTargetPID = pid
        liveLastLoudAt = Date()
        liveEngine = CommitEngine(holdBackPhrases: Self.holdBackPhrases())
        Log.d("live: armed (pid \(pid))")
    }

    private func resetLiveTyping() {
        liveEngine = nil
        liveTargetPID = nil
        liveFrozen = false
        liveSilenceFlushed = false
        liveUntyped = ""
    }

    /// Everything Replacements can rewrite, so that the engine never lets one
    /// of these phrases out in two pieces: the built-in voice commands of all
    /// languages (they are all active at once) plus the user's own literal
    /// rules. A "re:" rule is a regex with no word form — it can never match
    /// the engine's word-by-word hold-back, and is left out.
    private static func holdBackPhrases() -> [String] {
        var phrases = Replacements.commandsByLanguage.values.flatMap { $0.map(\.phrase) }
        phrases += Settings.shared.replacements.compactMap { rule -> String? in
            guard let phrase = rule.first?.trimmingCharacters(in: .whitespaces),
                  !phrase.isEmpty, !phrase.hasPrefix("re:") else { return nil }
            return phrase
        }
        return phrases
    }

    /// Runs the normal post-processing over one committed chunk. The engine's
    /// hold-back guarantees a replaceable phrase always arrives whole, so this
    /// sees the same phrases the final pass would. Fillers are cleaned only
    /// when the dictation language is known — in auto mode there is no
    /// detected language yet, and the final pass will do it.
    ///
    /// Replacements.tidy trims both edges, and the chunk's leading space is
    /// what joins it to the text already in the document: it is set aside
    /// before processing and put back after.
    private func liveProcessed(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }
        let language = Settings.shared.language
        let separator = String(chunk.prefix(while: \.isWhitespace))
        let body = String(chunk.dropFirst(separator.count))
        let processed = Replacements.process(
            body, rules: Settings.shared.replacements,
            fillerLanguage: Settings.shared.removeFillers && !language.isEmpty ? language : nil)
        // A chunk that was nothing but a filler leaves no separator behind.
        return processed.isEmpty ? "" : separator + processed
    }

    /// Puts one chunk into the focused app. The target is re-checked before
    /// every insertion, because the one thing that must never happen is text
    /// meant for one window landing in another: the moment the frontmost app
    /// is not the one we started in (or secure input comes up over a password
    /// field), live typing is over for this dictation and the rest is kept for
    /// the paste path.
    @MainActor
    private func typeLive(_ text: String) {
        guard !text.isEmpty else { return }
        if !liveFrozen {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != liveTargetPID {
                liveFrozen = true
                Log.d("live: frontmost app changed -> frozen")
            } else if IsSecureEventInputEnabled() {
                liveFrozen = true
                Log.d("live: secure input came up -> frozen")
            }
        }
        guard !liveFrozen else {
            liveUntyped += text
            return
        }
        Self.typeQueue.async { TypeInjector.type(text) }
    }

    /// The full pass arrived: deliver whatever live typing has not put in the
    /// document yet. Alignment runs against the RAW transcription — the engine
    /// committed raw words, before any replacements — and only the remainder
    /// it hands back is processed and inserted.
    @MainActor
    private func deliverLive(rawFinal: String) -> Paster.Outcome {
        guard let engine = liveEngine else { return .pasted }
        let remainder = liveProcessed(engine.finish(finalText: rawFinal))
        // A line break in the remainder (a trailing "new line" command) can't
        // be typed — TypeInjector flattens \n to a space because a synthesized
        // Return sends messages in chats. The paste path inserts it correctly.
        if !liveFrozen, remainder.contains("\n") {
            Log.d("live: final tail has line breaks -> paste path")
            return Paster.paste(remainder.trimmingCharacters(in: .whitespaces),
                                expectedTargetPID: targetAppPID)
        }
        // typeLive keeps the invariant either way: it types the remainder, or
        // (if the target is gone) adds it to what is still owed.
        if liveFrozen { liveUntyped += remainder } else { typeLive(remainder) }
        if !liveFrozen {
            // The same trailing space the paste path adds, for the same
            // reason: without it two dictations in a row glue into one word.
            if !engine.committedText.isEmpty { typeLive(" ") }
            Log.d("live: final tail \(remainder.count) chars typed")
            return .pasted
        }
        // Frozen — by the target app changing now or at any point earlier.
        // Everything still owed goes out as one ordinary paste, with all the
        // checks that path makes of its own.
        let pending = liveUntyped.trimmingCharacters(in: .whitespaces)
        liveUntyped = ""
        guard !pending.isEmpty else { return .pasted }
        Log.d("live: frozen -> \(pending.count) chars via the paste path")
        return Paster.paste(pending, expectedTargetPID: targetAppPID)
    }

    /// Esc: abandon the current dictation, whatever stage it's in. While
    /// recording, drop the audio before it's ever transcribed. While
    /// recognizing, flip the cancel token — WhisperKit stops decoding early and
    /// finish() throws the partial result away (no insert, no history). Idle is
    /// a no-op.
    private func cancel() {
        switch state {
        case .recording:
            stopLivePreview()
            // Whatever live typing already committed stays in the document —
            // it cannot be taken back, and it was said. Only the volatile tail
            // is thrown away, together with the audio.
            resetLiveTyping()
            _ = recorder.stop()
            state = .idle
            onNotice?(.cancelled)
        case .transcribing:
            activeCancel?.cancel()
            transcribeTask?.cancel()
            resetLiveTyping()
            state = .idle
            onNotice?(.cancelled)   // before nothing else can hide it
        case .idle:
            break
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        // Hold length = press→release, measured BEFORE anything that can
        // block: soundStop and the frontmostApplication XPC below stalled
        // ~0.8 s in the wild, and a Date() taken after them inflated a 0.24 s
        // accidental tap into a "1.0 s hold" that showed a spurious "nothing
        // heard" (live log 2026-08-06 12:24).
        let held = pressedAt.map { -$0.timeIntervalSinceNow } ?? 0
        keyStateTimer?.invalidate()
        keyStateTimer = nil
        stopLivePreview()
        let (pcm, duration) = recorder.stop()
        Self.soundStop?.play()
        targetAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        guard duration >= 0.3 else {
            // Nothing usable was captured. A quick tap is an accidental
            // touch — stay silent as before. But if the key was genuinely
            // held, the mic gave us nothing: say so instead of seeming deaf.
            // A foreign input format means another app owns the mic
            // (Meet/Zoom); otherwise it was likely still waking up.
            // The message fires before state = .idle so the idle transition
            // doesn't hide it (same ordering as finish()).
            switch DictationPolicy.zeroCaptureVerdict(held: held,
                                                      foreignHeld: recorder.sawForeignFormat) {
            case .micBusy:
                Log.d("empty after \(String(format: "%.1f", held))s hold -> mic busy")
                onNotice?(.micBusy(recorder.busyAppName))
            case .none:
                break
            default:
                Log.d("empty after \(String(format: "%.1f", held))s hold -> nothing heard")
                onNotice?(.nothingHeard)
            }
            resetLiveTyping()
            state = .idle
            return  // accidental short press or unusable capture
        }

        // Snapshot the level stats now — a later dictation resets the recorder
        // while this one's recognition Task may still be deciding what to show.
        let peak = recorder.peakLevel
        let clip = recorder.clippedFraction
        let micForeign = recorder.sawForeignFormat
        let micBusyApp = recorder.busyAppName

        let translate = activeTranslate
        state = .transcribing
        let language = Settings.shared.language
        let prompt = Settings.shared.prompt
        // One route for everything: turbo transcribes, and a translating
        // dictation then hands the text to Apple's on-device Translation —
        // English included. Whisper's own task=translate lost the A/B (it
        // compressed long speech and produced clumsy English) and is gone.
        let appleTarget: String? = translate ? Settings.shared.translateTargetCode : nil
        let tier: ModelTier = .fast
        if translate { Log.d("translate → \(appleTarget ?? "?") via apple") }
        let token = CancelToken()
        activeCancel = token
        transcribeTask = Task {
            // Sample conversion, per-window RMS and silence trimming are three
            // full passes over up to ~5M samples — kept off the main thread so
            // the UI can't hitch between key release and "Recognizing…".
            let floats = AudioRecorder.floatSamples(fromPCM: pcm)

            // Per-0.1s-window energy, in temporal order (bounds are read from it
            // before it's sorted for the p90/mean summary).
            let window = AudioRecorder.sampleRate / 10
            var energies: [Double] = []
            var i = 0
            while i < floats.count {
                let end = min(i + window, floats.count)
                var e: Double = 0
                for j in i..<end { e += Double(floats[j]) * Double(floats[j]) }
                energies.append((e / Double(end - i)).squareRoot())
                i = end
            }
            let windowRMS = energies.sorted()
            let p90 = windowRMS[min(windowRMS.count - 1, Int(Double(windowRMS.count) * 0.9))]
            let rms = windowRMS.reduce(0, +) / Double(max(windowRMS.count, 1))
            Log.d("recorded \(String(format: "%.2f", duration))s rms=\(String(format: "%.4f", rms)) p90=\(String(format: "%.4f", p90)) peak=\(String(format: "%.3f", peak)) clip=\(String(format: "%.3f", clip))")

            // Trim leading/trailing silence before Whisper: windows well below the
            // speech level (< 8% of p90) at the very edges are dropped, keeping a
            // ~200 ms margin so a quiet word onset is never clipped. Conservative
            // on purpose — a low threshold plus the margin can only shorten pure
            // silence, and it never touches audio between the first and last
            // voiced window. Speeds recognition and cuts edge hallucinations.
            let speechFloats = AudioRecorder.trimSilence(floats, energies: energies,
                                                         window: window, p90: p90)

            // Speech gate: Silero VAD decides whether anyone actually spoke —
            // it detects speech-ness, not loudness, so quiet voices pass while
            // speech-free audio never reaches Whisper (which hallucinates
            // confident phrases on it). Energy heuristic is the fallback only.
            let speech = await SpeechGate.shared.hasSpeech(floats) ?? (p90 > 0.012)
            guard speech else {
                Log.d("silence gate -> empty result (peak=\(String(format: "%.3f", peak)) clip=\(String(format: "%.3f", clip)))")
                await MainActor.run {
                    self.reportEmptyCapture(peak: peak, clip: clip, foreign: micForeign,
                                            busyApp: micBusyApp, token: token)
                }
                return
            }
            await self.transcribeLocal(floats: speechFloats, language: language,
                                       prompt: prompt, tier: tier, translate: translate,
                                       appleTarget: appleTarget, token: token)
        }
    }

    /// Nothing recognizable was captured though the key was held and audio came
    /// in. Pick the most useful nudge: a foreign-held mic that delivered only
    /// digital silence → "mic busy" naming the culprit; heavy clipping → "too
    /// loud"; a very low peak → "too quiet"; otherwise the generic "didn't
    /// catch that". Ordering mirrors finish(): fire before state = .idle so
    /// nothing hides the pill.
    @MainActor
    private func reportEmptyCapture(peak: Double, clip: Double, foreign: Bool,
                                    busyApp: String?, token: CancelToken) {
        resetLiveTyping()
        guard !token.isCancelled else { return }
        onResultText?("")
        switch DictationPolicy.emptyCaptureVerdict(peak: peak, clip: clip, foreignHeld: foreign) {
        case .micBusy: onNotice?(.micBusy(busyApp))
        case .tooLoud: onNotice?(.tooLoud)
        case .tooQuiet: onNotice?(.tooQuiet)
        case .nothingHeard: onNotice?(.nothingHeard)
        }
        state = .idle
    }

    private func transcribeLocal(floats: [Float], language: String,
                                 prompt: String, tier: ModelTier, translate: Bool,
                                 appleTarget: String?, token: CancelToken) async {
        do {
            let ready = await WhisperEngine.shared.isReady(for: tier)
            if !ready {
                // Not loaded yet (dictated before preload finished). Two very
                // different waits hide here. A missing model has to download
                // (real progress, essentially only before onboarding is done).
                // An already-downloaded one still has to be loaded and compiled
                // for the Neural Engine — up to minutes the first time, with no
                // progress callback of any kind, and the plain "Recognizing…"
                // spinner made that look like a freeze. A full bar is exactly
                // the HUD's "Warming up the model…" state, so say so.
                let downloaded = WhisperEngine.shared.isModelDownloaded(tier: tier)
                if downloaded, !token.isCancelled {
                    await MainActor.run { self.onModelDownload?(1.0, tier.sizeMB) }
                }
                try await WhisperEngine.shared.prepare(tier: tier) { [weak self] p in
                    // token: Esc already showed "Cancelled" — a late progress
                    // update would flash the download pill over it.
                    guard !downloaded, !token.isCancelled else { return }
                    DispatchQueue.main.async { self?.onModelDownload?(p, tier.sizeMB) }
                }
                // Hand the pill back to recognition. The download/warm-up state
                // owns the HUD until told otherwise, and setTranscribeProgress
                // only updates a pill that is already in the transcribing state —
                // without this the bar would sit at "Warming up…" for the whole
                // recognition. Replaying the current state (still .transcribing)
                // is enough; no state churn.
                if !token.isCancelled {
                    await MainActor.run { self.onStateChange?(self.state) }
                }
            }
            let started = Date()
            let (text, detected) = try await WhisperEngine.shared.transcribe(
                floats: floats, tier: tier, language: language, prompt: prompt,
                isCancelled: { token.isCancelled },
                onProgress: { [weak self] fraction, words in
                    DispatchQueue.main.async { self?.onTranscribeProgress?(fraction, words) }
                }
            )
            // Fillers are cleaned strictly in THIS dictation's language: the
            // chosen one, or whatever Whisper detected in auto mode. The text
            // is always still in the spoken language here — translation runs
            // after the cleanup, for every target.
            let fillerLanguage: String? = Settings.shared.removeFillers
                ? (language.isEmpty ? detected : language)
                : nil
            var processed = Replacements.process(text, rules: Settings.shared.replacements,
                                                 fillerLanguage: fillerLanguage)
            // Set when the text stayed in the spoken language because macOS has
            // no data for the pair — finish() turns it into a pill, otherwise
            // the user only sees "the translation key stopped translating".
            var dataMissing = false
            // Target == spoken language: there is nothing to translate, and
            // macOS has no such pair — asking would fail the dictation into a
            // "translation data missing" pill over text that is already right.
            let spoken = language.isEmpty ? detected : language
            if let appleTarget, appleTarget != spoken, !processed.isEmpty, !token.isCancelled {
                do {
                    processed = try await AppleTranslator.shared.translateSmart(
                        processed, to: appleTarget, source: spoken)
                } catch {
                    // Keep the native transcription rather than losing the
                    // dictation. Only the missing-data case is actionable;
                    // the rest stay in the log.
                    dataMissing = (error as? TranslateError) == .dataMissing
                    Log.d("apple translate failed (\(appleTarget)): \(error.localizedDescription) — inserting native text")
                }
            }
            await finish(text: processed, rawText: text, seconds: Date().timeIntervalSince(started),
                         translate: translate, translateDataMissing: dataMissing, token: token)
        } catch {
            await MainActor.run {
                // A user-cancelled recognition may surface as a thrown error;
                // cancel() already moved us to idle and showed "Cancelled", so
                // stay silent instead of flashing a scary error message.
                self.resetLiveTyping()
                guard !token.isCancelled else { return }
                self.state = .idle
                self.onError?(error.localizedDescription)
            }
        }
    }

    /// - Parameter rawText: the transcription before post-processing. Only live
    ///   typing needs it: the engine committed raw words, so the final text has
    ///   to be aligned against the raw form to see what is left to insert.
    @MainActor
    private func finish(text: String, rawText: String = "", seconds: Double, translate: Bool,
                        translateDataMissing: Bool = false, token: CancelToken) {
        // Esc arrived while this recognition was finishing: throw the (partial)
        // result away — no insertion, no history. cancel() already set idle and
        // showed "Cancelled".
        guard !token.isCancelled else {
            Log.d("finish: discarded — cancelled by Esc")
            return
        }
        lastWasTranslate = translate
        let words = text.split(whereSeparator: \.isWhitespace).count
        lastStats = text.isEmpty ? nil : (words, seconds)
        if !text.isEmpty {
            history.insert(text, at: 0)
            if history.count > 10 { history.removeLast() }
            // Translate-tip bookkeeping: a translate result anywhere (incl. the
            // onboarding try-out) silences the tip forever; the dictation
            // counter tracks only real usage.
            if translate { Settings.shared.translateUsedEver = true }
            if !suppressInsertion { Settings.shared.dictationCount += 1 }
        }
        var copied = false
        if !text.isEmpty, !suppressInsertion {
            // Live typing already put most of this in the document — inserting
            // `text` again would duplicate the whole dictation.
            copied = liveEngine != nil
                ? deliverLive(rawFinal: rawText) == .keptInClipboard
                : Paster.paste(text, expectedTargetPID: targetAppPID) == .keptInClipboard
        }
        resetLiveTyping()
        Log.d("result words=\(words) seconds=\(String(format: "%.1f", seconds)) copied=\(copied) empty=\(text.isEmpty)")
        // One pill per dictation. "Copied" wins: without it the text is
        // nowhere the user can see. Untranslated text is at least in place.
        if copied {
            onNotice?(.copiedInstead)
        } else if translateDataMissing, !text.isEmpty {
            onNotice?(.translateDataMissing)
        } else {
            onResult?(!text.isEmpty, words, seconds)
        }
        onResultText?(text)
        state = .idle
    }

    /// Skip insertion, deliver text via onResultText only (onboarding "try it" box).
    var suppressInsertion = false
}
