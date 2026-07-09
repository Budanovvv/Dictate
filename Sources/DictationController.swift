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
        // HUD first: bringing the input up can block the main thread for
        // seconds on a cold or Bluetooth mic (hardware wake + SCO
        // negotiation). The small delay lets the pill render before that;
        // start() itself never fails synchronously — the recorder retries a
        // not-yet-ready device and reports via onRecoveryFailed.
        state = .recording
        Self.soundStart?.play()
        // Load the model while the user is speaking, so it's warm by the
        // time they release — hides the one-time warm-up behind the speech.
        preloadModel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.state == .recording else { return }
            self.recorder.start()
        }
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

        guard duration >= 0.3 else {
            state = .idle
            return  // accidental short press
        }

        let translate = activeTranslate
        let floats = AudioRecorder.floatSamples(fromPCM: pcm)

        // Silence gate: Whisper hallucinates confident phrases on speech-free
        // audio ("Thank you for watching…"), especially when translating.
        // Compare the LOUDEST 100 ms windows, not the average: speech is
        // spiky (syllables peak several times above its mean) while room
        // noise is stationary — measured on this mic: silence rms ≈ 0.006
        // flat, speech rms ≈ 0.015 with peaks well above 0.02.
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
        guard p90 > 0.012 else {
            Log.d("silence gate -> empty result")
            Task { @MainActor in self.finish(text: "", seconds: 0, translate: translate) }
            return
        }

        state = .transcribing
        let language = Settings.shared.language
        let prompt = Settings.shared.prompt
        let tier = Settings.shared.modelTier
        Task { await self.transcribeLocal(floats: floats, language: language,
                                          prompt: prompt, tier: tier, translate: translate) }
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
            let text = try await WhisperEngine.shared.transcribe(
                floats: floats, language: language, prompt: prompt, translate: translate,
                onProgress: { [weak self] fraction, words in
                    DispatchQueue.main.async { self?.onTranscribeProgress?(fraction, words) }
                }
            )
            await finish(text: text, seconds: Date().timeIntervalSince(started), translate: translate)
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
            copied = Paster.insert(text) == .keptInClipboard
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
