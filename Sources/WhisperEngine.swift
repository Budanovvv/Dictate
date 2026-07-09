import Foundation
import WhisperKit

/// Local transcription on WhisperKit (CoreML/Neural Engine).
/// Models are downloaded once into Application Support.
actor WhisperEngine {
    static let shared = WhisperEngine()

    private var pipe: WhisperKit?
    private var loadedVariant: String?

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

    nonisolated func isModelDownloaded(tier: ModelTier) -> Bool {
        FileManager.default.fileExists(atPath: Self.variantDir(tier.variant).path)
    }

    /// Model for this tier is loaded into memory.
    func isReady(for tier: ModelTier) -> Bool {
        pipe != nil && loadedVariant == tier.variant
    }

    /// Downloads (if needed) and loads the selected model. progress: 0…1.
    func prepare(tier: ModelTier, progress: @Sendable @escaping (Double) -> Void) async throws {
        if pipe != nil, loadedVariant == tier.variant { return }
        let variant = tier.variant

        let modelFolder = try await WhisperKit.download(
            variant: variant,
            downloadBase: Self.modelsBase,
            progressCallback: { p in progress(p.fractionCompleted) }
        )

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
        pipe = try await WhisperKit(config)
        loadedVariant = variant
        // Old tiers would otherwise pile up on disk (~1 GB each)
        Self.removeOtherModels(keeping: variant)
    }

    private static func removeOtherModels(keeping variant: String) {
        let repoDir = modelsBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path) else { return }
        for item in items where item != variant {
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

    /// Transcribes audio (16 kHz float). language "" → auto-detect.
    /// prompt — terms dictionary. translate=true → translate to English.
    /// onProgress: overall fraction of audio processed (0…1) + words so far.
    func transcribe(floats: [Float], language: String, prompt: String,
                    translate: Bool = false,
                    onProgress: (@Sendable (Double, Int) -> Void)? = nil) async throws -> String {
        guard let pipe else {
            throw NSError(domain: "Dictate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Whisper model not loaded"])
        }

        var promptTokens: [Int]? = nil
        if !prompt.isEmpty, let tokenizer = pipe.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty { promptTokens = tokens }
        }

        let options = DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: language.isEmpty ? nil : language,
            // prefill is REQUIRED: without it the <|translate|> task token is not
            // injected and translation silently degrades to plain transcription.
            usePrefillPrompt: true,
            detectLanguage: language.isEmpty,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            chunkingStrategy: .vad  // split long recordings at pauses — more reliable
        )
        var callback: TranscriptionCallback = nil
        if let onProgress {
            let tally = ProgressTally()
            let durationSec = Double(floats.count) / Double(WhisperKit.sampleRate)
            callback = { [weak pipe] update in
                if let words = tally.update(windowId: update.windowId, text: update.text) {
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
        return results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
