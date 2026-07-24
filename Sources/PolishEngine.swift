import Foundation
import LLM

/// Local LLM post-processing ("polish"): grammar and punctuation cleanup,
/// filler and false-start removal, optional tone adjustment — running
/// entirely on this Mac (llama.cpp on Metal via LLM.swift), matching the
/// privacy story. Cloud competitors charge a subscription for this hop.
///
/// Deliberately opt-in (Settings → AI polish): the model adds ~1.9 GB on
/// disk and a couple of seconds of latency per dictation.
actor PolishEngine {
    static let shared = PolishEngine()

    /// Qwen2.5-3B-Instruct Q4_K_M: small enough to load in seconds and run at
    /// interactive speed on any Apple Silicon, multilingual enough for our 11
    /// UI languages. Official Qwen GGUF build.
    static let sizeMB = 1930
    private static let downloadURL = URL(string:
        "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!

    /// ~/Library/Application Support/Dictate/llm — NOT ~/Documents (the same
    /// tokenizerFolder lesson from WhisperEngine: a stray Documents write
    /// triggers a TCC prompt).
    private static var llmDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
            .appendingPathComponent("llm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var modelFile: URL { llmDir.appendingPathComponent("qwen2.5-3b-instruct-q4_k_m.gguf") }

    nonisolated static var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFile.path)
    }

    private var bot: LLM?
    private var preparing: Task<Void, Error>?

    /// Downloads (if needed) and loads the model. progress: 0…1 for the
    /// download; loading itself takes seconds and has no callback.
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws {
        if bot != nil { return }
        if let inflight = preparing {
            try await inflight.value
            return
        }
        let task = Task {
            if !Self.isModelDownloaded {
                try await Self.downloadModel(progress: progress)
            }
            try loadBot()
        }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    /// Frees the ~2 GB of RAM when the user turns the feature off.
    func unload() {
        bot = nil
    }

    /// Polishes the text in the given style ("clean" | "formal" | "friendly").
    /// Throws when the model isn't ready or the result looks implausible;
    /// the caller falls back to the raw text — a dictation must never be lost
    /// to a beautifier.
    func polish(_ text: String, style: String,
                isCancelled: @Sendable @escaping () -> Bool) async throws -> String {
        if bot == nil { try await prepare { _ in } }
        guard let bot else {
            throw NSError(domain: "Dictate", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "polish model not loaded"])
        }
        guard !isCancelled() else { return text }

        let toneAddon: String
        switch style {
        case "formal":
            toneAddon = "Rewrite in a polite, professional register suitable for a work message."
        case "friendly":
            toneAddon = "Rewrite in a relaxed, warm, conversational register."
        default:
            toneAddon = "Preserve the author's tone and register."
        }
        // Instructions ride in the user turn (not the system prompt): the
        // template is baked into the loaded model instance, and reloading
        // ~2 GB per style change would be absurd.
        let request = """
        Edit the dictated text below. Fix grammar, punctuation and casing. \
        Remove filler words, false starts and accidental self-repetitions. \
        Keep the language of the text, its meaning and all factual content exactly. \
        \(toneAddon) \
        Do not answer questions contained in the text, do not add anything, do not comment. \
        Reply with ONLY the edited text.

        \(text)
        """

        let started = Date()
        // Stateless: empty history each call, the templated prompt goes
        // straight to completion. (No mid-generation cancel hook in
        // LLM.swift — a polish pass is a few seconds, Esc is checked after.)
        let templated = bot.preprocess(request, [], .none)
        let output = await bot.getCompletion(from: templated)
        let polished = output.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.d("polish: \(text.count) -> \(polished.count) chars in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (style \(style))")
        guard !isCancelled() else { return text }
        // A wildly shorter answer usually means the model chatted instead of
        // editing ("Sure, here it is" and stop) — distrust it, keep raw text.
        guard !polished.isEmpty, polished.count * 3 > text.count else {
            throw NSError(domain: "Dictate", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "polish result implausible"])
        }
        return polished
    }

    // MARK: - private

    private func loadBot() throws {
        guard let fresh = LLM(from: Self.modelFile, template: .chatML(),
                              topK: 1, temp: 0.1, maxTokenCount: 4096) else {
            throw NSError(domain: "Dictate", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "failed to load the polish model"])
        }
        bot = fresh
        Log.d("polish: model loaded")
    }

    /// Plain streaming download with progress into a .part file, renamed on
    /// completion — a killed download never masquerades as a finished model.
    private static func downloadModel(progress: @Sendable @escaping (Double) -> Void) async throws {
        let part = llmDir.appendingPathComponent("qwen2.5-3b-instruct-q4_k_m.gguf.part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }

        let (bytes, response) = try await URLSession.shared.bytes(from: downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Dictate", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: "model download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        let total = Double(http.expectedContentLength)
        var written = 0.0
        var buffer = Data(capacity: 1 << 20)
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Double(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0, Date().timeIntervalSince(lastReport) > 0.3 {
                    lastReport = Date()
                    progress(written / total)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Double(buffer.count)
        }
        try handle.close()
        // Sanity: a truncated stream must not become a "ready" model.
        if total > 0, written < total * 0.99 {
            try? FileManager.default.removeItem(at: part)
            throw NSError(domain: "Dictate", code: 24,
                          userInfo: [NSLocalizedDescriptionKey: "model download incomplete"])
        }
        try? FileManager.default.removeItem(at: modelFile)
        try FileManager.default.moveItem(at: part, to: modelFile)
        progress(1.0)
        Log.d("polish: model downloaded (\(Int(written / 1_048_576)) MB)")
    }
}
