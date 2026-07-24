import Foundation
import WhisperKit

/// Local transcription on WhisperKit (CoreML/Neural Engine).
/// Models are downloaded once into Application Support.
actor WhisperEngine {
    static let shared = WhisperEngine()

    /// Loaded pipelines by variant. Keyed rather than a single slot so a future
    /// tier can be resident alongside the current one without a reload.
    private var pipes: [String: WhisperKit] = [:]
    /// In-flight model loads by variant. The actor is reentrant across the
    /// long awaits in prepare (download, WhisperKit init) — without this, the
    /// routine trio of prepare() calls (app-start preload, record-start
    /// preload, the transcribe path) could each pass the "already loaded"
    /// check and start a second parallel ~1 GB model load. Latecomers await
    /// the same task instead.
    private var preparing: [String: Task<Void, Error>] = [:]

    /// Folder for downloaded models: ~/Library/Application Support/Dictate/models
    private static var modelsBase: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func variantDir(_ variant: String) -> URL {
        modelsBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// True when every model component is fully on disk — not just "the folder
    /// exists", which is true even mid-download. Only a complete model counts:
    /// then loading skips the Hugging Face sync entirely (offline-first), and
    /// a killed or racing downloader can't invalidate a working model.
    nonisolated func isModelDownloaded(tier: ModelTier) -> Bool {
        Self.isModelComplete(tier.variant)
    }

    private nonisolated static func isModelComplete(_ variant: String) -> Bool {
        let dir = variantDir(variant)
        let fm = FileManager.default
        for required in ["AudioEncoder.mlmodelc/weights/weight.bin",
                         "TextDecoder.mlmodelc/weights/weight.bin",
                         "MelSpectrogram.mlmodelc/coremldata.bin",
                         "config.json"] {
            guard fm.fileExists(atPath: dir.appendingPathComponent(required).path) else { return false }
        }
        // Leftover *.incomplete markers mean an interrupted download
        if let files = fm.enumerator(atPath: dir.path) {
            for case let f as String in files where f.hasSuffix(".incomplete") { return false }
        }
        return true
    }

    /// Model for this tier is loaded into memory.
    func isReady(for tier: ModelTier) -> Bool {
        pipes[tier.variant] != nil
    }

    /// In-flight plain downloads by variant — download() and prepare() must
    /// see each other: a dictation mid-catch-up would otherwise start a second
    /// Hugging Face sync of the very same variant (the sync re-verifies every
    /// file and can invalidate the half-downloaded copy).
    private var downloading: [String: Task<Void, Error>] = [:]

    /// Download only, no load/compile — the onboarding progress bar stays
    /// honest (loading into the Neural Engine has no progress callback and
    /// would freeze the bar for minutes; it happens in the background via
    /// preloadModel while the user walks the remaining steps).
    func download(tier: ModelTier, progress: @Sendable @escaping (Double) -> Void) async throws {
        let variant = tier.variant
        guard !Self.isModelComplete(variant) else { return }
        if let inflight = downloading[variant] {
            try await inflight.value
            return
        }
        // A prepare() in flight already includes the download — ride it.
        if let inflight = preparing[variant] {
            try await inflight.value
            return
        }
        let task = Task {
            Log.d("model: downloading \(variant)")
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: Self.modelsBase,
                progressCallback: { p in progress(p.fractionCompleted) }
            )
        }
        downloading[variant] = task
        defer { downloading[variant] = nil }
        try await task.value
    }

    /// Downloads (if needed) and loads the selected model. progress: 0…1.
    /// Concurrent calls coalesce into one load; only the first caller's
    /// progress closure reports (they all feed the same HUD anyway).
    func prepare(tier: ModelTier, progress: @Sendable @escaping (Double) -> Void) async throws {
        let variant = tier.variant
        if pipes[variant] != nil { return }
        if let inflight = preparing[variant] {
            try await inflight.value
            return
        }
        let task = Task { try await performPrepare(variant: variant, progress: progress) }
        preparing[variant] = task
        defer { preparing[variant] = nil }
        try await task.value
    }

    private func performPrepare(variant: String,
                                progress: @Sendable @escaping (Double) -> Void) async throws {
        // A plain download() of this variant in flight (the post-update turbo
        // catch-up)? Let it finish — the complete model then loads offline
        // below instead of racing it with a second sync.
        if let inflight = downloading[variant] {
            _ = try? await inflight.value
        }
        // Offline-first: a complete model on disk loads as-is, without asking
        // Hugging Face anything. The network sync runs only for a missing or
        // partial model — it re-verifies every file and, if interrupted (app
        // killed mid-preload) or raced by a second instance, can invalidate
        // a previously working model and trigger a full ~950 MB re-download.
        let modelFolder: URL
        if Self.isModelComplete(variant) {
            Log.d("model: complete on disk — offline load")
            modelFolder = Self.variantDir(variant)
        } else {
            Log.d("model: missing/partial — syncing with Hugging Face")
            modelFolder = try await WhisperKit.download(
                variant: variant,
                downloadBase: Self.modelsBase,
                progressCallback: { p in progress(p.fractionCompleted) }
            )
        }

        let config = WhisperKitConfig(
            model: variant,
            modelFolder: modelFolder.path,
            // Without an explicit path WhisperKit downloads the tokenizer into
            // ~/Documents/huggingface, and macOS shows a "Documents" access prompt.
            // Keep everything in our own folder.
            tokenizerFolder: Self.modelsBase.appendingPathComponent("tokenizers", isDirectory: true),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        pipes[variant] = try await WhisperKit(config)
        // Retired tiers would otherwise pile up on disk (~1 GB each) — the
        // dropped translation model is cleared from existing installs here.
        Self.removeOtherModels()
    }

    private static func removeOtherModels() {
        let keep = Set(ModelTier.allCases.map(\.variant))
        let repoDir = modelsBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path) else { return }
        for item in items where !keep.contains(item) {
            try? FileManager.default.removeItem(at: repoDir.appendingPathComponent(item))
        }
    }

    /// Live transcription progress: word counts per decoding window
    /// (long recordings are VAD-chunked and windows may decode concurrently),
    /// throttled — the token callback fires dozens of times per second.
    private final class ProgressTally: @unchecked Sendable {
        private var wordsPerWindow: [Int: Int] = [:]
        private var lastEmit: CFAbsoluteTime = 0
        private let lock = NSLock()

        /// Total word count, or nil when this update should be skipped.
        func update(windowId: Int, text: String) -> Int? {
            lock.lock(); defer { lock.unlock() }
            wordsPerWindow[windowId] = text.split(whereSeparator: \.isWhitespace).count
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastEmit >= 0.15 else { return nil }
            lastEmit = now
            return wordsPerWindow.values.reduce(0, +)
        }
    }

    /// Transcribes audio (16 kHz float) with the given tier's model.
    /// language "" → auto-detect. prompt — terms dictionary. Transcription
    /// only: translation is Apple Translation's job now, downstream.
    /// onProgress: overall fraction of audio processed (0…1) + words so far.
    /// Returns the text and the language Whisper detected (drives the
    /// language-scoped filler-word cleanup even in auto-detect mode).
    func transcribe(floats: [Float], tier: ModelTier, language: String, prompt: String,
                    isCancelled: (@Sendable () -> Bool)? = nil,
                    onProgress: (@Sendable (Double, Int) -> Void)? = nil) async throws
        -> (text: String, detectedLanguage: String) {
        guard let pipe = pipes[tier.variant] else {
            throw NSError(domain: "Dictate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Whisper model not loaded"])
        }

        var promptTokens: [Int]? = nil
        if !prompt.isEmpty, let tokenizer = pipe.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty { promptTokens = tokens }
        }
        Log.d("prompt: \(prompt.count) chars -> \(promptTokens?.count ?? 0) tokens applied")

        let options = DecodingOptions(
            task: .transcribe,
            language: language.isEmpty ? nil : language,
            // Prefill stays on: it is what makes the task/language tokens land
            // deterministically, and turning it off changed decoding behaviour.
            usePrefillPrompt: true,
            detectLanguage: language.isEmpty,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            chunkingStrategy: .vad  // split long recordings at pauses — more reliable
        )
        var callback: TranscriptionCallback = nil
        if onProgress != nil || isCancelled != nil {
            let tally = ProgressTally()
            let durationSec = Double(floats.count) / Double(WhisperKit.sampleRate)
            callback = { [weak pipe] update in
                // Esc mid-recognition: returning false is WhisperKit's own
                // early-stop — it halts decoding and returns what it has so far
                // (which the caller then discards). Checked first, before any
                // progress work.
                if isCancelled?() == true { return false }
                if let onProgress, let words = tally.update(windowId: update.windowId, text: update.text) {
                    // pipe.progress only ticks at chunk boundaries — a 1–2 chunk
                    // recording would sit at 0% and jump at the end. Blend in a
                    // continuous estimate from decoded words: at a conservative
                    // 3 words/sec of speech it undershoots, so real chunk
                    // completions only ever pull the bar forward, never back.
                    let chunked = pipe?.progress.fractionCompleted ?? 0
                    let estimated = min(Double(words) / 3.0 / max(durationSec, 1), 0.95)
                    onProgress(max(chunked, estimated), words)
                }
                return nil  // nil = keep decoding
            }
        }
        let results = try await pipe.transcribe(audioArray: floats, decodeOptions: options, callback: callback)
        let text = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, results.first?.language ?? language)
    }
}
