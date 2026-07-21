import AppKit

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

    private let monitor = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var paused = false {
        didSet { if paused, state == .recording { _ = recorder.stop(); state = .idle } }
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
    /// Model download progress 0…1.
    var onModelDownload: ((Double) -> Void)?
    /// Model downloaded but still loading into memory.
    var onWarmup: (() -> Void)?
    var onWarmupDone: (() -> Void)?
    /// Recording cancelled via Esc.
    var onCancelled: (() -> Void)?
    /// No text cursor — the result went to the clipboard instead of being pasted.
    var onCopiedInstead: (() -> Void)?
    /// The key was held but the mic delivered no audio because another app
    /// holds it in voice-processing mode (Google Meet, Zoom, FaceTime…). The
    /// argument is that app's name when known, for a specific message.
    var onMicBusy: ((String?) -> Void)?
    /// The key was held but nothing was captured (mic still waking from sleep,
    /// device not ready) — tell the user instead of failing silently.
    var onNothingHeard: (() -> Void)?
    /// Audio was captured but far too quiet for any speech — suggest moving
    /// closer to the mic instead of the generic "didn't catch that".
    var onTooQuiet: (() -> Void)?
    /// Audio was captured but heavily clipped (input gain too high / too loud) —
    /// suggest backing off, so the distortion that defeats recognition is named.
    var onTooLoud: (() -> Void)?
    private(set) var lastResult: String?
    /// Recent results, newest first (in memory only — never written to disk).
    private(set) var history: [String] = []
    private(set) var lastStats: (words: Int, seconds: Double)?
    /// Whether the last result came from the translate key (onboarding checklist).
    private(set) var lastWasTranslate = false
    private var tapRetryTimer: Timer?
    private var tapFailureReported = false
    /// Current recording was started by the translate key.
    private var activeTranslate = false
    /// When the current recording's key went down — used to tell an accidental
    /// tap (released almost immediately) from a real attempt that captured no
    /// audio, so only the latter gets a "didn't hear you" message.
    private var pressedAt: Date?
    /// App that was frontmost when the key was RELEASED — the intended paste
    /// target. Captured at release, not press, so "hold key, click into the
    /// target field, speak" stays legal; the guard covers only the recognition
    /// window, where an app switch would send ⌘V to the wrong place.
    private var targetAppPID: pid_t?
    /// Cancels the in-flight recognition. Held so Esc (or a superseding
    /// dictation) can flip it: the WhisperKit decode callback reads it from a
    /// background thread to stop early, and finish() reads it to discard a
    /// partial result. Thread-safe because both sides touch it off the main
    /// actor.
    private var activeCancel: CancelToken?
    /// The recognition Task, so cancel() can tear it down.
    private var transcribeTask: Task<Void, Never>?
    /// Hands-free auto-stop bookkeeping (only when the setting is on): whether
    /// this recording has heard speech yet (so a silent lead-in never triggers
    /// a stop), and when the last above-threshold level arrived.
    private var autoStopArmed = false
    private var autoStopHeardSpeech = false
    private var autoStopLastLoud = Date()
    /// Pre-roll audio captured at key-press (Int16 PCM), prepended to a real
    /// dictation so a word begun just before the press isn't lost. nil when the
    /// pre-roll setting is off.
    private var prerollPCM: Data?

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
            self.autoStopTick(level: level)
        }
        recorder.onMicBusyDetected = { [weak self] in
            guard let self, self.state == .recording else { return }
            let app = self.recorder.busyAppName
            _ = self.recorder.stop()
            Log.d("mic busy detected early -> stop + notify")
            self.onMicBusy?(app)   // before .idle so the idle transition can't hide it
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
            tapRetryTimer?.invalidate()
            tapRetryTimer = nil
            tapFailureReported = false
        } else {
            if !tapFailureReported {
                tapFailureReported = true
                onError?(L("Accessibility permission is off, so the key can't be heard. Turn it on in System Settings → Privacy & Security → Accessibility — Dictate picks it up automatically, no restart needed."))
            }
            scheduleTapRetry()
        }
        return ok
    }

    /// Retry tap creation every 3 s so granting permission doesn't require a restart.
    private func scheduleTapRetry() {
        guard tapRetryTimer == nil else { return }
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.monitor.start() {
                self.tapRetryTimer?.invalidate()
                self.tapRetryTimer = nil
                self.tapFailureReported = false
            }
        }
    }

    /// Loads an already-downloaded model at startup so the first dictation doesn't wait.
    /// If it isn't downloaded, does nothing — transcribeLocal downloads lazily with progress.
    func preloadModel() {
        Task { await SpeechGate.shared.prewarm() }
        let tier = Settings.shared.modelTier
        guard WhisperEngine.shared.isModelDownloaded(tier: tier) else { return }
        Task { try? await WhisperEngine.shared.prepare(tier: tier) { _ in } }
    }

    /// Restarts key capture (after the hotkey changes in settings).
    func restart() {
        monitor.stop()
        _ = start()
    }

    func shutdown() {
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        monitor.stop()
        if state == .recording { _ = recorder.stop() }
    }

    private func isTranslateKey(_ code: Int64) -> Bool {
        if let t = Settings.shared.translateKeyCode { return Int64(t) == code }
        return false
    }

    // Push-to-talk: press starts, release stops.
    private func handlePress(_ code: Int64) {
        Log.d("press code=\(code) state=\(state) paused=\(paused)")
        beginRecording(translate: isTranslateKey(code))
    }

    private func handleRelease(_ code: Int64) {
        // Only the key that started the recording ends it.
        guard isTranslateKey(code) == activeTranslate else { return }
        Log.d("release code=\(code) state=\(state)")
        endRecording()
    }

    private func beginRecording(translate: Bool) {
        guard !paused, state == .idle else { return }
        activeTranslate = translate
        pressedAt = Date()
        autoStopArmed = Settings.shared.autoStopOnSilence
        autoStopHeardSpeech = false
        autoStopLastLoud = Date()
        // Snapshot the pre-roll ring at press: it holds audio from just before
        // now, prepended only if this turns into a real dictation (so a stray
        // tap can't manufacture one out of ambient sound).
        prerollPCM = Settings.shared.prerollEnabled ? PrerollBuffer.shared.snapshot() : nil
        state = .recording
        Self.soundStart?.play()
        // Wake the target app's accessibility tree now, while the user speaks:
        // Chromium/Electron/WebKit build it lazily and otherwise expose no
        // focused element at paste time, sending dictation to a manual ⌘V even
        // with a live cursor. Doing it here gives the tree seconds to populate.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            Paster.wakeAccessibility(pid: pid)
        }
        // Load the model while the user is speaking, so it's warm by the
        // time they release — hides the one-time warm-up behind the speech.
        preloadModel()
        // start() returns immediately now: it hands the blocking input bring-up
        // (which can take seconds on a cold/Bluetooth mic) to a background
        // queue, so the pill renders and the UI stays responsive. It never
        // fails synchronously — the recorder retries a not-yet-ready device and
        // reports via onRecoveryFailed.
        recorder.start()
    }

    /// Esc: abandon the current dictation, whatever stage it's in. While
    /// recording, drop the audio before it's ever transcribed. While
    /// recognizing, flip the cancel token — WhisperKit stops decoding early and
    /// finish() throws the partial result away (no insert, no history). Idle is
    /// a no-op.
    private func cancel() {
        switch state {
        case .recording:
            _ = recorder.stop()
            state = .idle
            onCancelled?()
        case .transcribing:
            activeCancel?.cancel()
            transcribeTask?.cancel()
            state = .idle
            onCancelled?()   // before nothing else can hide it
        case .idle:
            break
        }
    }

    /// Hands-free: runs on the main thread for every level update. Once speech
    /// has been heard, a long-enough quiet stretch ends the recording as if the
    /// key were released. A silent lead-in never triggers it, so nothing stops
    /// before the user has actually spoken.
    private func autoStopTick(level: Double) {
        guard autoStopArmed, state == .recording else { return }
        if level >= 0.08 {
            autoStopHeardSpeech = true
            autoStopLastLoud = Date()
            return
        }
        guard autoStopHeardSpeech else { return }
        if Date().timeIntervalSince(autoStopLastLoud) >= Settings.shared.autoStopSilenceSeconds {
            Log.d("hands-free: silence \(String(format: "%.1f", Settings.shared.autoStopSilenceSeconds))s -> auto stop")
            autoStopArmed = false
            endRecording()
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        autoStopArmed = false
        let (pcm, duration) = recorder.stop()
        Self.soundStop?.play()
        targetAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        guard duration >= 0.3 else {
            // Nothing usable was captured. A quick tap (< 0.5 s) is an
            // accidental touch — stay silent as before. But if the key was
            // genuinely held, the mic gave us nothing: say so instead of
            // seeming deaf. A foreign input format means another app owns the
            // mic (Meet/Zoom); otherwise it was likely still waking up.
            // The message fires before state = .idle so the idle transition
            // doesn't hide it (same ordering as finish()).
            let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
            if held >= 0.5 {
                if recorder.sawForeignFormat {
                    Log.d("empty after \(String(format: "%.1f", held))s hold -> mic busy")
                    onMicBusy?(recorder.busyAppName)
                } else {
                    Log.d("empty after \(String(format: "%.1f", held))s hold -> nothing heard")
                    onNothingHeard?()
                }
            }
            state = .idle
            return  // accidental short press or unusable capture
        }

        // Snapshot the level stats now — a later dictation resets the recorder
        // while this one's recognition Task may still be deciding what to show.
        let peak = recorder.peakLevel
        let clip = recorder.clippedFraction

        let translate = activeTranslate
        // Prepend the pre-roll to a confirmed dictation (leading silence in it
        // is trimmed below, so a quiet ring adds nothing but a caught onset).
        let fullPCM: Data
        if let pre = prerollPCM, !pre.isEmpty {
            Log.d("preroll: prepending \(pre.count)B (~\(String(format: "%.2f", Double(pre.count) / Double(AudioRecorder.sampleRate * 2)))s)")
            fullPCM = pre + pcm
        } else {
            fullPCM = pcm
        }
        prerollPCM = nil
        let floats = AudioRecorder.floatSamples(fromPCM: fullPCM)

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
        // 150 ms margin so a quiet word onset is never clipped. Conservative on
        // purpose — a low threshold plus the margin can only shorten pure
        // silence, and it never touches audio between the first and last voiced
        // window. Speeds recognition and cuts edge hallucinations.
        let speechFloats = Self.trimSilence(floats, energies: energies, window: window, p90: p90)

        state = .transcribing
        let language = Settings.shared.language
        let prompt = Settings.shared.prompt
        let tier = Settings.shared.modelTier
        let token = CancelToken()
        activeCancel = token
        transcribeTask = Task {
            // Speech gate: Silero VAD decides whether anyone actually spoke —
            // it detects speech-ness, not loudness, so quiet voices pass while
            // speech-free audio never reaches Whisper (which hallucinates
            // confident phrases on it). Energy heuristic is the fallback only.
            let speech = await SpeechGate.shared.hasSpeech(floats) ?? (p90 > 0.012)
            guard speech else {
                Log.d("silence gate -> empty result (peak=\(String(format: "%.3f", peak)) clip=\(String(format: "%.3f", clip)))")
                await MainActor.run {
                    self.reportEmptyCapture(peak: peak, clip: clip, token: token)
                }
                return
            }
            await self.transcribeLocal(floats: speechFloats, language: language,
                                       prompt: prompt, tier: tier, translate: translate, token: token)
        }
    }

    /// Nothing recognizable was captured though the key was held and audio came
    /// in. Pick the most useful nudge: heavy clipping → "too loud"; a very low
    /// peak → "too quiet"; otherwise the generic "didn't catch that". Ordering
    /// mirrors finish(): fire before state = .idle so nothing hides the pill.
    @MainActor
    private func reportEmptyCapture(peak: Double, clip: Double, token: CancelToken) {
        guard !token.isCancelled else { return }
        onResultText?("")
        if clip > 0.02 {
            onTooLoud?()
        } else if peak < 0.02 {
            onTooQuiet?()
        } else {
            onNothingHeard?()
        }
        state = .idle
    }

    /// Drops pure-silence windows from the head and tail, keeping a margin so a
    /// quiet onset/offset survives. Returns the original array unchanged when
    /// there's no clear silence to cut (or nothing voiced at all).
    private static func trimSilence(_ floats: [Float], energies: [Double],
                                    window: Int, p90: Double) -> [Float] {
        guard p90 > 0, !energies.isEmpty, floats.count > window * 4 else { return floats }
        let threshold = p90 * 0.08
        guard let firstVoiced = energies.firstIndex(where: { $0 > threshold }),
              let lastVoiced = energies.lastIndex(where: { $0 > threshold }) else { return floats }
        let margin = 2   // windows (~200 ms) of padding on each side
        let startWin = max(0, firstVoiced - margin)
        let endWin = min(energies.count - 1, lastVoiced + margin)
        let start = startWin * window
        let end = min(floats.count, (endWin + 1) * window)
        guard start < end, end - start < floats.count else { return floats }
        return Array(floats[start..<end])
    }

    private func transcribeLocal(floats: [Float], language: String,
                                 prompt: String, tier: ModelTier, translate: Bool,
                                 token: CancelToken) async {
        do {
            let ready = await WhisperEngine.shared.isReady(for: tier)
            if !ready {
                // Not loaded yet (dictated before preload finished). The loading
                // usually overlapped the recording, so the remaining wait is short —
                // keep the normal "Recognizing…" spinner rather than a scary
                // "warming up" message. Only surface progress if the model still
                // needs downloading (never happens after onboarding).
                let downloaded = WhisperEngine.shared.isModelDownloaded(tier: tier)
                try await WhisperEngine.shared.prepare(tier: tier) { [weak self] p in
                    guard !downloaded else { return }
                    DispatchQueue.main.async { self?.onModelDownload?(p) }
                }
            }
            let started = Date()
            let (text, detected) = try await WhisperEngine.shared.transcribe(
                floats: floats, language: language, prompt: prompt, translate: translate,
                isCancelled: { token.isCancelled },
                onProgress: { [weak self] fraction, words in
                    DispatchQueue.main.async { self?.onTranscribeProgress?(fraction, words) }
                }
            )
            // Fillers are cleaned strictly in THIS dictation's language:
            // the chosen one, or whatever Whisper detected in auto mode;
            // translate output is always English.
            let fillerLanguage: String? = Settings.shared.removeFillers
                ? (translate ? "en" : (language.isEmpty ? detected : language))
                : nil
            let processed = Replacements.process(text, rules: Settings.shared.replacements,
                                                 fillerLanguage: fillerLanguage)
            await finish(text: processed, seconds: Date().timeIntervalSince(started),
                         translate: translate, token: token)
        } catch {
            await MainActor.run {
                // A user-cancelled recognition may surface as a thrown error;
                // cancel() already moved us to idle and showed "Cancelled", so
                // stay silent instead of flashing a scary error message.
                guard !token.isCancelled else { return }
                self.state = .idle
                self.onError?(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func finish(text: String, seconds: Double, translate: Bool, token: CancelToken) {
        // Esc arrived while this recognition was finishing: throw the (partial)
        // result away — no insertion, no history. cancel() already set idle and
        // showed "Cancelled".
        guard !token.isCancelled else {
            Log.d("finish: discarded — cancelled by Esc")
            return
        }
        lastResult = text
        lastWasTranslate = translate
        let words = text.split(whereSeparator: \.isWhitespace).count
        lastStats = text.isEmpty ? nil : (words, seconds)
        if !text.isEmpty {
            history.insert(text, at: 0)
            if history.count > 10 { history.removeLast() }
        }
        var copied = false
        if !text.isEmpty, !suppressInsertion {
            copied = Paster.insert(text, expectedTargetPID: targetAppPID) == .keptInClipboard
        }
        Log.d("result words=\(words) seconds=\(String(format: "%.1f", seconds)) copied=\(copied) empty=\(text.isEmpty)")
        if copied {
            onCopiedInstead?()
        } else {
            onResult?(!text.isEmpty, words, seconds)
        }
        onResultText?(text)
        state = .idle
    }

    /// Skip insertion, deliver text via onResultText only (onboarding "try it" box).
    var suppressInsertion = false
}
