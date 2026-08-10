import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Names a finished meeting from what was said in it, using the language
/// model built into macOS 26 (Apple Intelligence). Nothing is downloaded and
/// nothing leaves the Mac — the model is already part of the system, so the
/// privacy promise holds.
///
/// This is NOT the AI-polish story that was removed: polish rewrote the
/// user's own words, which a dictation must never do. Here the transcript
/// stays verbatim and the model only writes a label for it — and when the
/// model is unavailable (older macOS, Apple Intelligence off), the meeting
/// simply keeps its date-and-time name.
enum MeetingTitler {

    /// How much of the conversation the model reads. Meetings state their
    /// subject early, and a short excerpt keeps the call fast and well
    /// inside the context window.
    static let excerptLimit = 1200

    /// Builds the excerpt: speaker-labelled lines, oldest first, capped.
    static func excerpt(from entries: [TranscriptEntry], limit: Int = excerptLimit) -> String {
        var lines: [String] = []
        var total = 0
        for entry in entries {
            let line = "\(entry.speaker): \(entry.text)"
            let cost = line.count + (lines.isEmpty ? 0 : 1)   // + the newline
            if total + cost > limit { break }
            lines.append(line)
            total += cost
        }
        // A meeting shorter than one line still deserves a try.
        if lines.isEmpty, let first = entries.first {
            lines.append(String("\(first.speaker): \(first.text)".prefix(limit)))
        }
        return lines.joined(separator: "\n")
    }

    /// Model output arrives as free text: it can bring quotes, a trailing
    /// period, a "Title:" prefix or a whole extra sentence. Squeeze it into
    /// something that fits a sidebar row, or reject it.
    static func sanitize(_ raw: String, maxWords: Int = 7, maxCharacters: Int = 60) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the first line only — models like to explain themselves.
        if let newline = text.firstIndex(where: \.isNewline) {
            text = String(text[text.startIndex..<newline])
        }
        for prefix in ["Title:", "Заголовок:", "Название:"] where
            text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'«»*_.…"))
        guard !text.isEmpty else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count > maxWords {
            text = words.prefix(maxWords).joined(separator: " ")
        }
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces)
        }
        // A "title" that is really a refusal or an empty gesture is worse
        // than the date the meeting already has.
        guard text.count >= 3 else { return nil }
        return text
    }

    /// Generates a title, or nil when the model can't or won't produce one.
    /// Never throws into the caller: a nameless meeting is a cosmetic loss,
    /// and the transcript itself is already safe on disk.
    static func title(for entries: [TranscriptEntry]) async -> String? {
        guard !entries.isEmpty else { return nil }
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            Log.d("title: system model needs macOS 26 — keeping the date name")
            return nil
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            Log.d("title: system model unavailable (\(reason)) — keeping the date name")
            return nil
        }
        let session = LanguageModelSession(instructions: """
            You name meeting transcripts. Given an excerpt of a conversation, \
            reply with a title of at most 6 words naming what the meeting is \
            about. Write the title in the language the participants speak. \
            Reply with the title only — no quotes, no punctuation at the end, \
            no explanation.
            """)
        do {
            let response = try await session.respond(
                to: excerpt(from: entries),
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 24))
            guard let title = sanitize(response.content) else {
                Log.d("title: model returned nothing usable")
                return nil
            }
            Log.d("title: \"\(title)\"")
            return title
        } catch {
            Log.d("title: generation failed (\(error.localizedDescription))")
            return nil
        }
        #else
        return nil
        #endif
    }
}
