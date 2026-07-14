import AppKit

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
    /// holds it in voice-processing mode (Google Meet, Zoom, FaceTime…).
    var onMicBusy: (() -> Void)?
    /// The key was held but nothing was captured (mic still waking from sleep,
    /// device not ready) — tell the user instead of failing silently.
    var onNothingHeard: (() -> Void)?
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
        monitor.onEsc = { [weak self] in self?.cancelRecording() }
        recorder.onTruncated = { [weak self] in
            self?.onError?(Lf("Recording truncated at %d seconds (limit)", AudioRecorder.maxDurationSec))
        }
        recorder.onLevel = { [weak self] level in
            self?.onLevel?(level)
        }
        recorder.onMicBusyDetected = { [weak self] in
            guard let self, self.state == .recording else { return }
            _ = self.recorder.stop()
            Log.d("mic busy detected early -> stop + notify")
            self.onMicBusy?()   // before .idle so the idle transition can't hide it
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
        state = .recording
        Self.soundStart?.play()
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

    /// Esc while recording: discard the audio, transcribe nothing.
    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        state = .idle
        onCancelled?()
    }

    private func endRecording() {
        guard state == .recording else { return }
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
                    onMicBusy?()
                } else {
                    Log.d("empty after \(String(format: "%.1f", held))s hold -> nothing heard")
                    onNothingHeard?()
                }
            }
            state = .idle
            return  // accidental short press or unusable capture
        }

        let translate = activeTranslate
        let floats = AudioRecorder.floatSamples(fromPCM: pcm)

        // Energy numbers: logged for calibration, and used as the fallback
        // gate if the VAD model is unavailable.
        let window = AudioRecorder.sampleRate / 10
        var windowRMS: [Double] = []
        var i = 0
        while i < floats.count {
            let end = min(i + window, floats.count)
            var e: Double = 0
            for j in i..<end { e += Double(floats[j]) * Double(floats[j]) }
            windowRMS.append((e / Double(end - i)).squareRoot())
            i = end
        }
        windowRMS.sort()
        let p90 = windowRMS[min(windowRMS.count - 1, Int(Double(windowRMS.count) * 0.9))]
        let rms = windowRMS.reduce(0, +) / Double(max(windowRMS.count, 1))
        Log.d("recorded \(String(format: "%.2f", duration))s rms=\(String(format: "%.4f", rms)) p90=\(String(format: "%.4f", p90))")

        state = .transcribing
        let language = Settings.shared.language
        let prompt = Settings.shared.prompt
        let tier = Settings.shared.modelTier
        Task {
            // Speech gate: Silero VAD decides whether anyone actually spoke —
            // it detects speech-ness, not loudness, so quiet voices pass while
            // speech-free audio never reaches Whisper (which hallucinates
            // confident phrases on it). Energy heuristic is the fallback only.
            let speech = await SpeechGate.shared.hasSpeech(floats) ?? (p90 > 0.012)
            guard speech else {
                Log.d("silence gate -> empty result")
                await MainActor.run { self.finish(text: "", seconds: 0, translate: translate) }
                return
            }
            await self.transcribeLocal(floats: floats, language: language,
                                       prompt: prompt, tier: tier, translate: translate)
        }
    }

    private func transcribeLocal(floats: [Float], language: String,
                                 prompt: String, tier: ModelTier, translate: Bool) async {
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
            await finish(text: processed, seconds: Date().timeIntervalSince(started), translate: translate)
        } catch {
            await MainActor.run {
                self.state = .idle
                self.onError?(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func finish(text: String, seconds: Double, translate: Bool) {
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
