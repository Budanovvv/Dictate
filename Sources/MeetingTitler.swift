import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Translation)
import Translation
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

    /// Builds the excerpt the model reads. Sampled ACROSS the whole meeting,
    /// not from its first minutes: reading only the opening produced "Aunt
    /// won't be there" for a work call that happened to start with small talk
    /// (measured 2026-08-10). Entries stay in order, so the excerpt still
    /// reads as a conversation.
    static func excerpt(from entries: [TranscriptEntry], limit: Int = excerptLimit) -> String {
        guard !entries.isEmpty else { return "" }
        let lines = entries.map { "\($0.speaker): \($0.text)" }
        // Everything fits: no need to choose.
        let whole = lines.joined(separator: "\n")
        if whole.count <= limit { return whole }
        // Otherwise: work out how many lines the budget affords, then spread
        // exactly that many evenly from the first entry to the last. A fixed
        // stride would run out of budget two thirds in and never show the
        // model how the meeting ended.
        let average = max(1, lines.reduce(0) { $0 + $1.count + 1 } / lines.count)
        let capacity = min(lines.count, max(2, limit / average))
        let step = Double(lines.count - 1) / Double(capacity - 1)
        var picked: [Int] = []
        for slot in 0..<capacity {
            let index = Int((Double(slot) * step).rounded())
            if picked.last != index { picked.append(index) }
        }
        var total = 0
        var kept: [Int] = []
        for index in picked {
            let cost = lines[index].count + (kept.isEmpty ? 0 : 1)
            if total + cost > limit { break }
            kept.append(index)
            total += cost
        }
        return kept.map { lines[$0] }.joined(separator: "\n")
    }

    /// Languages Apple's on-device model handles. Anything else goes through
    /// translation first — it either refuses outright
    /// (unsupportedLanguageOrLocale) or, worse, answers confidently with
    /// nonsense: a Russian work call was titled "Valentine's Day Plans"
    /// because it saw the name "Валентин" (measured 2026-08-10).
    static let modelLanguages: Set<String> = ["en", "fr", "de", "it", "pt", "es", "ja", "ko", "zh"]

    /// The excerpt's dominant language, or nil when it can't be told.
    static func dominantLanguage(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
            .split(separator: "-").first.map(String.init)
    }

    static func needsTranslation(language: String?) -> Bool {
        guard let language else { return false }   // unknown: let the model try
        return !modelLanguages.contains(language)
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
        // Models like to announce what they're doing — "Title:", "Meeting
        // Title:", "Meeting Transcript:". Strip a short leading label that
        // names the artefact rather than the meeting; a real title like
        // "Q3: plans" survives because "q3" is none of these words.
        if let colon = text.range(of: ":") {
            let head = text[text.startIndex..<colon.lowerBound].lowercased()
            let markers = ["title", "meeting", "transcript", "topic", "subject",
                           "заголовок", "название", "тема"]
            if head.split(whereSeparator: \.isWhitespace).count <= 3,
               markers.contains(where: { head.contains($0) }) {
                text = String(text[colon.upperBound...])
            }
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
        var text = excerpt(from: entries)
        let language = dominantLanguage(of: text)
        // Unsupported language → translate the excerpt to English first
        // (Apple Translation knows the languages the model doesn't). The
        // title then comes out in English even for a Russian meeting, which
        // beats both of the alternatives: an outright refusal, or a
        // confident invention.
        if needsTranslation(language: language) {
            guard let english = await translatedToEnglish(text, from: language) else {
                Log.d("title: \(language ?? "?") unsupported and not translatable — keeping the date name")
                return nil
            }
            text = english
        }
        let session = LanguageModelSession(instructions: """
            You name meeting transcripts. Given an excerpt of a conversation, \
            reply with a title of at most 6 words naming what the meeting is \
            about as a whole. Reply with the title only — no quotes, no \
            punctuation at the end, no explanation, no "Title:" prefix.
            """)
        do {
            let response = try await session.respond(
                to: text,
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

    /// Translates the excerpt with the on-device Translation framework. Needs
    /// the language pack installed (the same packs the translate key uses);
    /// without one this fails and the meeting keeps its date name.
    @available(macOS 26, *)
    private static func translatedToEnglish(_ text: String, from language: String?) async -> String? {
        #if canImport(Translation)
        guard let language else { return nil }
        do {
            let session = TranslationSession(
                installedSource: Locale.Language(identifier: language),
                target: Locale.Language(identifier: "en"))
            let started = Date()
            let english = try await session.translate(text).targetText
            Log.d(String(format: "title: translated %@→en in %.1fs", language,
                         Date().timeIntervalSince(started)))
            return english
        } catch {
            Log.d("title: translation failed (\(error.localizedDescription))")
            return nil
        }
        #else
        return nil
        #endif
    }
}
