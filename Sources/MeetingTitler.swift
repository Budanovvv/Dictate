import Combine
import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Translation)
import Translation
#endif

/// What the model makes of a finished meeting: the name the library shows,
/// and one sentence saying what the meeting was about. Both come out of the
/// SAME model call — the excerpt, the session and (for a Russian meeting) the
/// translation hop are already paid for by the time a title exists, so asking
/// for the sentence as well costs a few hundred milliseconds instead of a
/// second round trip.
struct MeetingBrief {
    let title: String
    /// nil when the model's sentence was unusable — a meeting with a name and
    /// no summary is a normal, complete state.
    let summary: String?
}

/// Names and summarizes a finished meeting from what was said in it, using the
/// language model built into macOS 26 (Apple Intelligence). Nothing is
/// downloaded and nothing leaves the Mac — the model is already part of the
/// system, so the privacy promise holds.
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

    /// The summary is a sentence, not a label, so it gets its own cleaner.
    ///
    /// Two things it must guarantee beyond taste. It returns ONE line: the
    /// summary is written into the transcript as a single line above the first
    /// entry, and a stray newline there would turn the tail of the sentence
    /// into something the parser has to make sense of. And it never starts
    /// with `#`, `_` or `**[`, the three prefixes that mean something else in
    /// our own file format.
    ///
    /// The ceiling is 90 because the row is 240pt wide and shows two lines:
    /// past that the sentence is not shortened, it is truncated, and a line
    /// the reader has to hover to finish is not a summary. The meaning is
    /// asked to live in the first 60 for the same reason — that is one line.
    static func sanitizeSummary(_ raw: String, maxCharacters: Int = 90,
                                minCharacters: Int = 18) -> String? {
        // Every kind of whitespace collapses to a single space — this is what
        // makes the result a single line by construction.
        var text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Same announcement-stripping as the title: "Summary:", "Итог:".
        if let colon = text.range(of: ":") {
            let head = text[text.startIndex..<colon.lowerBound].lowercased()
            let markers = ["summary", "sentence", "about", "meeting", "transcript",
                           "описание", "итог", "резюме", "о чём"]
            if head.split(whereSeparator: \.isWhitespace).count <= 3,
               markers.contains(where: { head.contains($0) }) {
                text = String(text[colon.upperBound...])
            }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'«»*_#…"))
        text = withoutReportingOpening(text)
        guard !text.isEmpty else { return nil }
        if text.count > maxCharacters {
            // Prefer to end where the model ended a sentence; failing that,
            // end on a word and say so with an ellipsis.
            let head = String(text.prefix(maxCharacters))
            if let stop = head.lastIndex(where: { ".!?。".contains($0) }),
               head.distance(from: head.startIndex, to: stop) >= minCharacters {
                text = String(head[head.startIndex...stop])
            } else if let space = head.lastIndex(of: " ") {
                text = String(head[head.startIndex..<space]) + "…"
            } else {
                text = head + "…"
            }
        }
        // A subject line, not prose: a fragment reads better in a list row
        // than a sentence, so the full stop the model likes to add goes. The
        // ellipsis that marks a trim is not punctuation and stays.
        if text.hasSuffix(".") { text = String(text.dropLast()) }
        // A sentence too short to say anything is worse than an empty line —
        // the row simply shows nothing.
        guard text.count >= minCharacters else { return nil }
        return text
    }

    /// A summary that only says the title again, one line under the title.
    ///
    /// The row already carries the title directly above this line, so a
    /// summary that repeats it spends two lines saying one thing. It happens:
    /// a meeting titled "Log writing process" was summarized "Log writing
    /// process" (measured 2026-08-13). Nothing to say is an honest answer, and
    /// the row simply shows the title, the time and the length.
    ///
    /// Compared on letters and digits alone, so punctuation, case and a
    /// stray "the" cannot smuggle a repeat past the test.
    static func restates(title: String, summary: String) -> Bool {
        func key(_ s: String) -> String {
            s.lowercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
                .map(String.init).joined()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let (t, s) = (key(title), key(summary))
        guard !t.isEmpty, !s.isEmpty else { return false }
        return s.contains(t) || t.contains(s)
    }

    /// Openings that report that a meeting happened instead of saying what it
    /// was about — the exact filler the summary exists to avoid.
    ///
    /// The prompt does most of this work and the model mostly complies; this
    /// is the net under the rope, for the one line in eight that still comes
    /// back as "The meeting focused on the progress of a project". English
    /// only, on purpose: English is what every TRANSLATED meeting comes back
    /// in and the most common native case besides, while a native French or
    /// Japanese summary is better left whole than trimmed by a guess at a
    /// language nobody here has measured.
    private static let reportingOpenings = [
        "the meeting focused on ", "the meeting was about ", "the meeting covered ",
        "this meeting was about ", "the meeting discussed ",
        "the call was about ", "this call was about ", "the call focused on ",
        "the discussion focused on ", "the discussion was about ",
        "discussion on ", "discussion about ", "discussion of ",
        "discussed ", "discussing ",
        "participants discussed ", "the participants discussed ",
        "the team discussed ", "they discussed ", "the group discussed ",
        "the conversation focused on ", "the conversation was about ",
    ]

    /// Drops such an opening and puts the sentence back on its feet.
    private static func withoutReportingOpening(_ text: String) -> String {
        let lowered = text.lowercased()
        guard let opening = reportingOpenings.first(where: { lowered.hasPrefix($0) })
        else { return text }
        let rest = String(text.dropFirst(opening.count))
        guard let first = rest.first else { return text }
        return first.uppercased() + rest.dropFirst()
    }

    /// What the model is told to produce. Kept beside the type it fills in,
    /// because the two only make sense together.
    ///
    /// It contains NO example lines, and that is the hard-won part.
    ///
    /// Given three specimens of a good summary, this model copied one
    /// verbatim: two unrelated meetings — one of them a phone call about
    /// phone numbers — were both labelled "Agent onboarding for Shannon, and
    /// the context it needs to be useful". Rewriting them as No/Yes pairs in a
    /// domain no meeting here could be about (a warehouse lease) stopped that,
    /// and then leaked the FACTS instead: a real meeting about a drug
    /// presentation came out as "Project delayed to March; lease expires in
    /// February", which is not a summary but an invention. Turning the pairs
    /// into placeholders leaked the scaffolding — summaries began "No:
    /// Discussion of…". All three measured on the owner's archive, 2026-08-13.
    ///
    /// So the corrections are prose: a phrase to avoid, quoted inline, and
    /// what to write instead. There is nothing in it shaped like an answer,
    /// and the last leak went with it.
    private static let instructions = """
        You label meeting transcripts. Given an excerpt of a conversation, \
        give it a title and one line under it.

        The title names what the meeting was about as a whole, in at most 6 \
        words.

        The line under it adds what the title does NOT say — the substance or \
        the outcome. Write it as a subject line: ONE fragment, at most 90 \
        characters, no full stop at the end, not two sentences.

        Where you would write "discussion of the topic and the problems \
        raised", write instead what specifically was wrong, and for whom. \
        Where you would write "participants agreed on the topic", write \
        instead what was decided, naming the people or the things it applies \
        to. Where you would write "the topic is being discussed", write \
        instead what has to happen next.

        Never restate the title. Never describe the meeting as an event. Never \
        use a genre word like "demo discussion" or "planning session", and \
        never an abstraction like "system functionality" or "objectives" — use \
        the concrete nouns the conversation itself used.

        Every word of your line must come from the conversation you are given. \
        Never invent a name, a date or a number that is not in it.

        If the excerpt never makes the subject clear, say the little that IS \
        clear rather than describing the conversation.

        Write the title in the language the conversation is in, and the line \
        under it in English.
        """

    /// Generates a title and a summary, or nil when the model can't or won't
    /// produce one. Never throws into the caller: a nameless meeting is a
    /// cosmetic loss, and the transcript itself is already safe on disk.
    /// `titled` is the name the meeting ALREADY carries, when it has one. It
    /// matters for one thing: a summary must not repeat the title the reader
    /// can see, and a meeting being backfilled keeps the title in its file —
    /// the one the model invents on the way past is thrown away. Judging the
    /// summary against that discarded title dropped two good lines and kept
    /// one that echoed the visible name (measured 2026-08-13).
    static func brief(for entries: [TranscriptEntry],
                      titled existing: String? = nil) async -> MeetingBrief? {
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
        let session = LanguageModelSession(instructions: instructions)
        do {
            let started = Date()
            // ONE call for both. Guided generation (the @Generable type below)
            // rather than two free-text lines to parse: the model fills named
            // fields, so a chatty answer cannot put the summary in the title.
            // The response cap is load-bearing, not tuning. Without it the
            // framework reserves the rest of the 4096-token window for an
            // answer it will never need, and a perfectly ordinary meeting
            // comes back as "Content contains 4091 tokens, which exceeds the
            // maximum allowed context size of 4096" — two of the owner's
            // eighteen transcripts failed exactly that way until this was put
            // back (it was there for the title before guided generation, and
            // dropping it is what broke them). A title and a 90-character
            // line do not need 80 tokens; the meetings that were failing now
            // pass.
            let answer = try await session.respond(
                to: text, generating: ModelBrief.self,
                options: GenerationOptions(temperature: 0.3,
                                           maximumResponseTokens: 80)).content
            guard let title = sanitize(answer.title) else {
                Log.d("title: model returned nothing usable")
                return nil
            }
            let summary = await finished(summary: answer.summary,
                                         under: existing ?? title,
                                         spokenIn: language,
                                         viaEnglish: needsTranslation(language: language))
            Log.d(String(format: "title: \"%@\" in %.1fs", title,
                         Date().timeIntervalSince(started)))
            if let summary { Log.d("summary: \"\(summary)\"") }
            return MeetingBrief(title: title, summary: summary)
        } catch {
            Log.d("title: generation failed (\(error.localizedDescription))")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The ONE place a generated summary passes through on its way to the
    /// file — deliberately a seam.
    ///
    /// Summaries are English for every meeting, in every language — the
    /// owner's call (2026-08-13). Translating one back into the meeting's
    /// language would go here, and nowhere else: `viaEnglish` and `language`
    /// are the two facts such a hop would need, and they are already in hand.
    /// The seam exists so that decision stays cheap to revisit; it is not
    /// currently used.
    private static func finished(summary raw: String, under title: String,
                                 spokenIn language: String?,
                                 viaEnglish: Bool) async -> String? {
        _ = (language, viaEnglish)
        guard let summary = sanitizeSummary(raw) else { return nil }
        guard !restates(title: title, summary: summary) else {
            Log.d("summary: only said the title again — leaving the line empty")
            return nil
        }
        return summary
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

#if canImport(FoundationModels)
/// The shape the model must answer in. Guided generation means the two fields
/// arrive separately instead of as a paragraph we would have to cut in half.
@available(macOS 26, *)
@Generable
struct ModelBrief {
    @Guide(description: "A title of at most 6 words naming what the meeting is about.")
    var title: String
    @Guide(description: """
        The line that adds what the title does not say: what was wrong, what \
        was decided, or what happens next. Never restates the title. Uses the \
        concrete nouns the conversation used — names, artifacts, numbers — \
        never abstractions like "system functionality" or "objectives". ONE \
        fragment, not a sentence, with no full stop at the end. At most 90 \
        characters, and the meaning is in the first 60.
        """)
    var summary: String
}
#endif

/// Gives the transcripts already on disk the summary they were recorded
/// without.
///
/// Summaries arrived after ~17 meetings had already been recorded, and a
/// library where only the newest row says anything is worse than one where
/// none do. So the library backfills as it is opened: newest first (the rows
/// the owner is actually looking at), ONE meeting at a time, written straight
/// into the .md so it happens exactly once in the life of that file.
///
/// Everything here is deliberately timid. It never starts while a meeting is
/// being recorded — the model and the Mac belong to the call. It never
/// regenerates a summary that exists. It never retries a meeting the model
/// refused or failed for as long as the app is running, so a transcript the
/// model will not touch ("May contain sensitive content" is a real answer)
/// costs one attempt rather than one per glance at the library. And when it
/// has nothing to do it does nothing at all: no timer, no polling, no work
/// that could show up as idle CPU in the meetings window.
@MainActor
final class MeetingSummaries: ObservableObject {
    static let shared = MeetingSummaries()

    /// Bumped each time a summary lands on disk — the library's cue to reload.
    @Published private(set) var written = 0

    private var running = false
    /// Meetings the model has already declined once this run.
    private var refused: Set<URL> = []

    /// Pause between meetings. Not a rate limit the model imposes — a promise
    /// that a library opened during other work does not become a queue of
    /// inference the Mac has to chew through back to back.
    private let breather: Duration = .milliseconds(400)

    /// The one way to get a summary REGENERATED once it exists:
    ///
    ///     defaults write com.valentynbudanov.Dictate resummarizeMeetings -bool YES
    ///
    /// The next opening of the library then rewrites every summary in the
    /// archive instead of only the missing ones, and the flag clears itself
    /// when the run finishes, so it is a one-shot rather than a mode. It is
    /// here because the wording of these lines is a product decision that has
    /// already changed once: without a way to redo them, the meetings recorded
    /// before a better prompt would keep the worse summary forever, and the
    /// alternative — deleting a line out of the user's own files by hand — is
    /// not something the app should make anyone do.
    private static let redoKey = "resummarizeMeetings"

    private init() {}

    /// `allowed` is asked again before every meeting, not just once at the
    /// start: a call can begin halfway through a backfill, and when it does the
    /// rest of the queue waits for the next time the library is opened.
    func backfill(_ meetings: [ArchivedMeeting], while allowed: @escaping @MainActor () -> Bool) {
        guard !running else { return }
        let redo = UserDefaults.standard.bool(forKey: Self.redoKey)
        if redo { refused.removeAll() }
        let pending = meetings.filter {
            ($0.summary == nil || redo) && !$0.entries.isEmpty && !refused.contains($0.url)
        }
        guard !pending.isEmpty else { return }
        running = true
        Log.d("summary: \(redo ? "regenerating" : "backfilling") \(pending.count) meeting(s)")
        Task { @MainActor in
            defer { running = false }
            for (index, meeting) in pending.enumerated() {
                guard allowed() else {
                    Log.d("summary: backfill paused — a meeting is being recorded")
                    return
                }
                // Between every pair, whether the last one worked or not: a
                // library opened during other work must not become a queue of
                // inference the Mac chews through back to back.
                if index > 0 { try? await Task.sleep(for: breather) }
                guard let brief = await MeetingTitler.brief(for: meeting.entries,
                                                            titled: meeting.title),
                      let summary = brief.summary else {
                    refused.insert(meeting.url)
                    continue
                }
                // A transcript this old may never have been named either (the
                // model was unavailable that day) — it gets both, and its file
                // follows the new name.
                var url = meeting.url
                if meeting.title == nil {
                    url = MeetingArchive.retitle(meeting, to: brief.title)
                }
                guard MeetingArchive.setSummary(summary, in: url) else {
                    refused.insert(meeting.url)
                    continue
                }
                written += 1
            }
            // A one-shot, not a mode: whatever asked for the redo has had it.
            if redo { UserDefaults.standard.removeObject(forKey: Self.redoKey) }
            Log.d("summary: backfill done")
        }
    }
}
