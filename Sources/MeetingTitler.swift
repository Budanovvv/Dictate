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
        let lines = entries.map { "\(participant($0)): \($0.text)" }
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

    /// What the model is told to call the owner.
    ///
    /// The transcript labels his turns "You" — or "Вы", or "Du", whichever
    /// word was current when it was written — because that is what a person
    /// reading the file should see. A model reading the same file sees a
    /// PRONOUN, and writes sentences about it: "Shannon and You decide to
    /// focus on developing the system" (measured 2026-08-14). Every prompt in
    /// this file builds its text through `excerpt`, so substituting the label
    /// here fixes the title, the summary and the sections at once — and it is
    /// safe in every language, because `isYou` is decided by the parser
    /// against all eleven shipped words rather than by matching the current
    /// interface language (see MeetingArchive.youLabels).
    static let ownerLabel = "Host"

    private static func participant(_ entry: TranscriptEntry) -> String {
        entry.isYou ? ownerLabel : entry.speaker
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
    /// The ceiling was 90, and 90 was the width of a sidebar row: the summary
    /// used to live ONLY in that row, so it was sized to fit two lines of it.
    /// It has a reading pane now — the transcript opens on it — and the row
    /// shows a clamped preview of the same sentence, which is how a mail client
    /// has always done this. So the number is no longer about the list: 240 is
    /// one or two real sentences, enough to say both what a meeting was about
    /// and what came of it, and the row still fills its two lines from the
    /// front of it.
    ///
    /// It stays ONE line in the file regardless — a newline there would hand
    /// the parser a second line to make sense of.
    static func sanitizeSummary(_ raw: String, maxCharacters: Int = 240,
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
        // The dash and the bullet are here for the section lines: they are
        // written into the file AS a Markdown bullet, and a model that hands
        // back "- Pricing" would put two of them on one line.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'«»*_#…-–—•"))
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

        The line under it says what the meeting was ABOUT, taken as a whole, \
        and then what came of it. One or two sentences, at most 240 \
        characters, on a single line.

        Cover the conversation, not its most vivid moment. If an hour went on \
        three subjects, name the three; do not spend the line on one exchange \
        because that exchange was specific. Where you would write "discussion \
        of the topic and the problems raised", write instead which subjects \
        were covered and what was settled about them. Where you would write \
        "participants agreed on the topic", write instead what was decided, \
        naming the people or the things it applies to.

        Never restate the title. Never use a genre word like "demo \
        discussion" or "planning session", and never an abstraction like \
        "system functionality" or "objectives" — use the concrete nouns the \
        conversation itself used.

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
    ///
    /// How much of the meeting the model reads is the ENGINE's business, not
    /// this function's: a large-context engine is handed the whole transcript,
    /// where the 1200-character even sample that Apple's window forces is
    /// where "son Geruslan" and "death recording system" came from. Same
    /// prompt, same filters, more to read.
    static func brief(for entries: [TranscriptEntry],
                      titled existing: String? = nil) async -> MeetingBrief? {
        guard !entries.isEmpty else { return nil }
        guard let engine = await MeetingTextEngines.best() else {
            Log.d("title: no generation engine — keeping the date name")
            return nil
        }
        var text = excerpt(from: entries, limit: engine.briefLimit)
        let language = dominantLanguage(of: text)
        // Unsupported language → translate the excerpt to English first
        // (Apple Translation knows the languages the model doesn't). The
        // title then comes out in English even for a Russian meeting, which
        // beats both of the alternatives: an outright refusal, or a
        // confident invention. An engine that reads the language itself skips
        // this: the hop is not free, it LOSES content on these transcripts.
        let translating = !engine.readsEveryLanguage && needsTranslation(language: language)
        if translating {
            guard #available(macOS 26, *),
                  let english = await translatedToEnglish(text, from: language) else {
                Log.d("title: \(language ?? "?") unsupported and not translatable — keeping the date name")
                return nil
            }
            text = english
        }
        do {
            let started = Date()
            let answer = try await engine.brief(about: text, instructions: instructions)
            guard let title = sanitize(answer.title) else {
                Log.d("title: model returned nothing usable")
                return nil
            }
            let summary = await finished(summary: answer.summary,
                                         under: existing ?? title,
                                         spokenIn: language,
                                         viaEnglish: translating)
            Log.d(String(format: "title: \"%@\" in %.1fs via %@ (%d chars read)", title,
                         Date().timeIntervalSince(started), engine.engineName, text.count))
            if let summary { Log.d("summary: \"\(summary)\"") }
            return MeetingBrief(title: title, summary: summary)
        } catch {
            Log.d("title: generation failed (\(error))")
            return nil
        }
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
    static func translatedToEnglish(_ text: String, from language: String?) async -> String? {
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

/// Breaks a finished meeting into a table of contents: a few minutes at a
/// time, each with one English line saying what was discussed there.
///
/// This exists because a meeting's own summary cannot answer the question the
/// owner actually has. "We discussed somewhere how Shannon would test it —
/// remind me what we said there" is three minutes out of fifty, and one line
/// about the whole hour does not contain it. Nor can the model be handed the
/// transcript and asked: its window is 4096 tokens against a 45–55 KB file,
/// and we have already met `exceededContextWindowSize` doing far less. So the
/// archive is cut into pieces small enough to describe AND small enough to
/// feed — see MeetingPolicy.sectionStarts for where the cuts land and why.
///
/// Sections are ENGLISH for every meeting, in every language, and that is
/// load-bearing rather than a default. It is the same construction the
/// summaries rest on: `NLEmbedding.sentenceEmbedding` exists for English and
/// not for Russian, so a Russian meeting is findable by meaning only because
/// what is indexed about it was written in English. Translating a section back
/// into the language it was spoken in would quietly end cross-language search.
enum MeetingSectioner {

    /// How much of a section the model reads.
    ///
    /// Larger than the whole-meeting excerpt (1200) because a section is one
    /// subject and the point is to describe it precisely; small enough that
    /// the whole call — instructions, passage and answer — stays well under
    /// the 4096-token window. Measured on the archive: sections come out
    /// 1.6–4.9 KB, so most are read whole and the longest are sampled evenly
    /// end to end by the same excerpt rule the title uses.
    static let excerptLimit = 2500

    /// A section line is a subject line like the summary, so it passes through
    /// the summary's cleaner — with a lower floor, because "Pricing for the
    /// pharmacy pilot" is a perfectly good section and would not survive the
    /// summary's 18-character minimum.
    static let minimumCharacters = 12

    /// …and its own ceiling, independent of the summary's.
    ///
    /// A section line has a second home the summary does not: it is written
    /// into the .md, where a person reads it in a Markdown app with the whole
    /// window to spare. 110 is what stops the CUTTING, which was the real
    /// complaint — a third of the first run's lines ended in an ellipsis
    /// mid-word, and a line that has to be amputated was too long to write
    /// rather than too long to show.
    static let maximumCharacters = 130

    /// What the model is told to produce.
    ///
    /// The shape of this prompt is a correction twice over, and both
    /// corrections came from reading what it actually wrote about the owner's
    /// own meetings (2026-08-14).
    ///
    /// Written as the summary's instructions were — "every word must come from
    /// the conversation you are given" — it produced COPIES: sentences lifted
    /// out of the passage, speaker prefix and all ("Shanon: We're pat,
    /// there's no onboarding. That's the beauty. It calls me"). The
    /// instruction meant to prevent invention had invited quotation, and a
    /// passage arriving as "Name: words" lines gave the model the format to
    /// continue in.
    ///
    /// Then, told it could name two subjects "separated by a semicolon", it
    /// stopped writing sentences at all and wrote LISTS: "Slavery; kidneys;
    /// security; legal; responsibility; TECHO; yuzkis; Rails; agent; AI".
    /// A pile of nouns is what this model produces when it cannot find a
    /// thread, and the semicolon was the permission slip. So the semicolon is
    /// gone, the ban on lists is stated outright, and the one thing the line
    /// MUST have — a verb — is the first instruction rather than an
    /// afterthought.
    ///
    /// (There is a second reason a list is the wrong shape, beyond reading
    /// badly. The transcripts contain mistranscriptions — "yuzkis" is
    /// Whisper's mangling of "юзкейс" — and a bad word inside a clause is
    /// survivable, while a bad word in a list of seven is a seventh of the
    /// line.)
    private static let instructions = """
        You are given a passage from the middle of a meeting transcript. Write \
        ONE short line for a table of contents, saying what happened in that \
        passage.

        Your line must be a CLAUSE WITH A VERB — something happened, somebody \
        decided something, somebody has to do something. Never a list of \
        nouns, never words separated by semicolons or commas. If you cannot \
        find one thing the passage is about, say what the people in it were \
        trying to work out.

        Your line is a label, not a continuation of the conversation. Never \
        quote the transcript, never copy a sentence out of it, and never begin \
        with a speaker's name.

        Keep it under 100 characters and stop there — one clause, no full stop \
        at the end, never two sentences. It has to be scannable in a list.

        Say what was at stake — the problem raised, what was decided, or what \
        somebody has to do next — using the concrete nouns the conversation \
        used: the names, the products, the numbers. Never a genre word like \
        "planning session" or "technical discussion", and never an \
        abstraction like "system functionality" or "various topics".

        If the passage really covers two subjects, join them in ONE clause \
        with "and" or "before". Naming two things is honest; listing them is \
        not a description of either.

        Do not describe the meeting as a whole, and do not say that a \
        conversation took place. Do not state any fact the passage does not \
        state — no name, no date and no number that is not in it.

        Write in English.
        """

    /// What the model is told on the ONE retry it gets, when its first answer
    /// was a list or ran past the ceiling. Leading with the failure is what
    /// makes a second attempt worth making: the same prompt at the same
    /// temperature mostly produces the same shape again.
    private static let stricterInstructions = """
        You are given a passage from the middle of a meeting transcript. Write \
        ONE short sentence-like line saying what happened in it.

        Your last attempt was rejected. Do NOT write a list of words or \
        topics. Do NOT separate things with semicolons. Do NOT quote the \
        transcript.

        Write ONE clause with a verb, AT MOST TWELVE WORDS, naming the \
        people and the things the passage is actually about — what was wrong, \
        what was decided, or what somebody has to do next. No full stop at \
        the end.

        Write in English.
        """

    /// The lines for one meeting, in order — or [] when the meeting is too
    /// short to section, the model is unavailable, or it refused every piece.
    ///
    /// `progress` is called after each section so a backfill can be paced and
    /// stopped between calls; returning false abandons the meeting, and a
    /// meeting abandoned halfway writes nothing (a half-filled contents block
    /// is worse than none, because nothing would ever come back to finish it).
    static func sections(for entries: [TranscriptEntry],
                         progress: @escaping @MainActor () async -> Bool = { true })
        async -> [TranscriptSection] {
        let ranges = MeetingArchive.sectionRanges(of: entries)
        guard ranges.count >= 2 else { return [] }
        guard let engine = await MeetingTextEngines.best() else {
            Log.d("sections: no generation engine")
            return []
        }
        let started = Date()
        var out: [TranscriptSection] = []
        for range in ranges {
            guard await progress() else {
                Log.d("sections: abandoned after \(out.count)/\(ranges.count)")
                return []
            }
            let slice = Array(entries[range])
            guard let time = slice.first?.time,
                  let line = await self.line(for: slice, on: engine) else { continue }
            out.append(TranscriptSection(time: time, line: line))
        }
        Log.d(String(format: "sections: %d of %d in %.1fs via %@", out.count, ranges.count,
                     Date().timeIntervalSince(started), engine.engineName))
        // A block with holes in it is still a table of contents; a block with
        // two lines in thirteen is a misleading one. Half is the bar, and it
        // is set by what the model actually does rather than by taste: it
        // declines whole passages outright ("Detected content likely to be
        // unsafe" — a real answer, seen on ordinary business calls), and a
        // meeting where that happens three times in eight is far better off
        // with the five lines that worked than with nothing to search.
        guard out.count >= 2, out.count * 2 >= ranges.count else { return [] }
        return out
    }

    /// One section, one model call — and one retry, with every filter in
    /// between. Which model answers is the engine's business; everything that
    /// decides whether the answer is USABLE lives here, and applies to all of
    /// them.
    private static func line(for slice: [TranscriptEntry],
                             on engine: any MeetingTextEngine) async -> String? {
        var text = MeetingTitler.excerpt(from: slice, limit: engine.sectionLimit)
        guard !text.isEmpty else { return nil }
        let language = MeetingTitler.dominantLanguage(of: text)
        // Asked per section rather than once per meeting: these calls really
        // do switch language halfway through, and the passage in front of the
        // model is the only text whose language matters to it.
        if !engine.readsEveryLanguage, MeetingTitler.needsTranslation(language: language) {
            guard #available(macOS 26, *),
                  let english = await MeetingTitler.translatedToEnglish(text, from: language)
            else { return nil }
            text = english
        }
        // Two attempts at most. The first is the ordinary prompt; the second
        // is told what was wrong with the first, which is the only thing that
        // makes a retry worth its second or two — the same prompt at the same
        // temperature mostly produces the same shape again. A passage that
        // fails twice gets NO line: a keyword list would find badly and read
        // worse, and the block is allowed to have holes in it.
        for attempt in 0..<2 {
            guard let answer = await ask(text, strict: attempt > 0, on: engine) else { continue }
            let raw = withoutSpeakerPrefix(answer, spokenBy: slice)
            let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // Too long to write, not too long to show: rather than amputate it
            // mid-word with an ellipsis, ask again for a shorter one.
            if collapsed.count > maximumCharacters, attempt == 0 {
                Log.d("sections: retrying — \(collapsed.count) characters")
                continue
            }
            guard let line = MeetingTitler.sanitizeSummary(shortened(collapsed),
                                                           maxCharacters: maximumCharacters,
                                                           minCharacters: minimumCharacters)
            else { continue }
            if readsAsAList(line) {
                Log.d("sections: \(attempt == 0 ? "retrying" : "dropping") a list — \"\(line)\"")
                continue
            }
            if quotesThePassage(line, passage: text) {
                Log.d("sections: \(attempt == 0 ? "retrying" : "dropping") a quote — \"\(line)\"")
                continue
            }
            return line
        }
        return nil
    }

    /// The colder second attempt is the whole point of the retry: the same
    /// prompt at the same temperature mostly produces the same shape again.
    private static func ask(_ text: String, strict: Bool,
                            on engine: any MeetingTextEngine) async -> String? {
        do {
            return try await engine.line(about: text,
                                         instructions: strict ? stricterInstructions : instructions,
                                         temperature: strict ? 0.1 : 0.3)
        } catch {
            Log.d("sections: one passage failed (\(error))")
            return nil
        }
    }

    /// A line that ran past the ceiling, ended where a reader would end it.
    ///
    /// The retry asks for something shorter and usually gets it; when the
    /// second answer is long too, the choice is between a line cut mid-phrase
    /// ("…concerns about the non-deterministic nature of the…") and a shorter
    /// line that is whole. A clause boundary — a full stop, then a semicolon,
    /// then a comma — gives a whole one, and only a passage with no boundary
    /// at all falls back to the ellipsis. The result is "Shannon and Yuri
    /// discuss the AI onboarding process" instead of that, which says less and
    /// reads like something a person wrote.
    static func shortened(_ line: String, to limit: Int = maximumCharacters) -> String {
        guard line.count > limit else { return line }
        let head = String(line.prefix(limit))
        for stop in [".!?", ";", ",—–"] {
            guard let at = head.lastIndex(where: { stop.contains($0) }) else { continue }
            let kept = String(head[head.startIndex..<at])
                .trimmingCharacters(in: .whitespaces)
            // A fragment so short it says nothing is worse than a long line.
            // A third of the ceiling, not half: the boundary that saves this
            // is usually the first comma of a two-clause sentence, and half
            // of 130 rejected exactly the case this exists for — "Shannon and
            // Yuri discuss the AI onboarding process" is 49 characters.
            if kept.count >= max(minimumCharacters * 2, limit / 3) { return kept }
        }
        guard let space = head.lastIndex(of: " ") else { return head }
        return String(head[head.startIndex..<space]) + "…"
    }

    /// Whether a line is a pile of nouns rather than a description.
    ///
    /// The failure mode this feature nearly shipped with, and the reason it is
    /// caught HERE rather than only asked against in the prompt: a model that
    /// has no thread to pull produces one of these reliably, and no wording
    /// stops it every time. Every example below is verbatim from the first run
    /// against the owner's archive.
    ///
    /// Three or more semicolon-separated pieces is a list whatever they say
    /// ("demo with Yura; demo with Preoperation; demo with chatbot"). Two is
    /// only a list when both are too short to be clauses — "agent onboarding;
    /// conversation 3" is, while "Change assistant status to active; set up
    /// onboarding" is a real line and survives. And four or more comma-
    /// separated scraps with nothing else holding them together is the same
    /// shape wearing different punctuation.
    static func readsAsAList(_ line: String) -> Bool {
        func pieces(_ separator: Character) -> [String] {
            line.split(separator: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        func words(_ piece: String) -> Int {
            piece.split(whereSeparator: \.isWhitespace).count
        }
        let semicolons = pieces(";")
        if semicolons.count >= 3 { return true }
        if semicolons.count == 2, semicolons.allSatisfy({ words($0) <= 3 }) { return true }
        let commas = pieces(",")
        if commas.count >= 4, commas.allSatisfy({ words($0) <= 3 }) { return true }
        return false
    }

    /// Whether the line is lifted out of the passage rather than written
    /// about it.
    ///
    /// The last of the three shapes this had to learn to refuse, and the one
    /// no instruction reliably prevents: given a passage it cannot summarize,
    /// the model returns a piece of it. Verbatim from the owner's archive —
    /// "We have no options. Speaker 2: guys, let's do it for tomorrow. maybe
    /// it will come out" and "Ruslan, you were flooding us with something...
    /// You corrected what I... What did we talk about?" (2026-08-14). Neither
    /// is a description of anything, and both would have been indexed as one.
    ///
    /// Eight consecutive words is the test, and the number was measured
    /// rather than picked. At six it also refused lines that were real
    /// descriptions which happened to reuse a phrase — "Ruslan and I have
    /// everything according to plan" — and cost a short meeting its whole
    /// block. At eight the dumps are still caught (they run to twelve words
    /// and more) and the honest paraphrases survive. Compared
    /// on letters and digits alone, so punctuation and case cannot smuggle one
    /// past. `passage` must be the text the MODEL saw — for a Russian meeting
    /// that is the translation, not the transcript.
    static func quotesThePassage(_ line: String, passage: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
                .reduce(into: "") { $0.append($1) }
                .split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let shingle = 8
        let needle = words(line), haystack = words(passage)
        guard needle.count >= shingle, haystack.count >= shingle else { return false }
        let text = " " + haystack.joined(separator: " ") + " "
        for start in 0...(needle.count - shingle) {
            let run = needle[start..<(start + shingle)].joined(separator: " ")
            if text.contains(" " + run + " ") { return true }
        }
        return false
    }

    /// Drops a "Shanon:" the model put in front of its answer.
    ///
    /// The prompt now forbids it and the model mostly complies; this is the
    /// net under the rope, and it is exact rather than a guess because the
    /// names it will accept are the ones speaking in THIS passage. A line that
    /// legitimately opens "Pricing: the pharmacy pilot" is untouched, because
    /// "Pricing" is nobody in the room.
    static func withoutSpeakerPrefix(_ line: String, spokenBy slice: [TranscriptEntry]) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let head = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, head.split(whereSeparator: \.isWhitespace).count <= 2,
              slice.contains(where: { nearlyTheSameName($0.speaker, head) })
        else { return line }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// The same person, allowing for the model spelling the name its own way.
    ///
    /// Not pedantry: the transcript calls her "Shanon" (one n, as Whisper
    /// heard it) and the model writes "Shannon", so an exact comparison left
    /// "Shannon: We're pat, there's no onboarding" in the file. One edit of
    /// slack is enough for that class of difference and far too little to
    /// mistake "Pricing" for anybody in the room.
    static func nearlyTheSameName(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x == y { return true }
        guard abs(x.count - y.count) <= 1, min(x.count, y.count) >= 4 else { return false }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], row[j - 1])
            }
            previous = row
        }
        return previous[y.count] <= 1
    }
}

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

    /// Whether the model is currently busy with a summary. Read by the section
    /// backfill, which shares the one on-device model and must not race it
    /// into the same 4096-token window from two directions.
    private(set) var running = false
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

/// Gives the transcripts already on disk the contents block they were recorded
/// without.
///
/// The same shape as MeetingSummaries above, and deliberately more timid,
/// because the bill is an order of magnitude bigger: a summary is one model
/// call, a contents block is eight to thirteen. A whole archive is minutes of
/// inference, not seconds — so this is paced between sections as well as
/// between meetings, and it asks permission to continue before every single
/// call rather than once per meeting.
///
/// It never runs while a meeting is being recorded (the model and the Mac
/// belong to the call), never touches a transcript that already has a block,
/// never retries one the model refused for as long as the app is running, and
/// does nothing at all when there is nothing to do — no timer, no polling.
@MainActor
final class MeetingSections: ObservableObject {
    static let shared = MeetingSections()

    /// Bumped each time a contents block lands on disk — the library's cue to
    /// reload, and the search index's cue to pick the new lines up.
    @Published private(set) var written = 0

    private var running = false
    private var refused: Set<URL> = []

    /// Between meetings. Longer than the summaries' 400 ms because what
    /// precedes it is a dozen model calls rather than one.
    private let breather: Duration = .seconds(1)
    /// Between sections of one meeting. Small, but not zero: back-to-back
    /// inference for minutes on end is exactly what a library opened during
    /// other work must not become.
    private let pause: Duration = .milliseconds(250)

    /// The one way to have every contents block REGENERATED:
    ///
    ///     defaults write com.valentynbudanov.Dictate resectionMeetings -bool YES
    ///
    /// Here for the same reason the summaries have one: the wording of these
    /// lines is a product decision that will change, and without this the
    /// meetings recorded under a worse prompt would keep it forever. The flag
    /// clears itself when the run finishes, so it is a one-shot, not a mode.
    private static let redoKey = "resectionMeetings"

    private init() {}

    func backfill(_ meetings: [ArchivedMeeting], while allowed: @escaping @MainActor () -> Bool) {
        guard !running else { return }
        let redo = UserDefaults.standard.bool(forKey: Self.redoKey)
        if redo { refused.removeAll() }
        let pending = meetings.filter {
            ($0.sections.isEmpty || redo) && !$0.entries.isEmpty && !refused.contains($0.url)
        }
        guard !pending.isEmpty else { return }
        running = true
        Log.d("sections: \(redo ? "regenerating" : "backfilling") \(pending.count) meeting(s)")
        Task { @MainActor in
            defer { running = false }
            for (index, meeting) in pending.enumerated() {
                guard allowed() else {
                    Log.d("sections: backfill paused — a meeting is being recorded")
                    return
                }
                if index > 0 { try? await Task.sleep(for: breather) }
                // One model, one queue: the summaries backfill runs first (its
                // rows are what the library is showing), and this waits rather
                // than competing with it.
                while MeetingSummaries.shared.running {
                    try? await Task.sleep(for: breather)
                    guard allowed() else { return }
                }
                let sections = await MeetingSectioner.sections(for: meeting.entries) { [weak self] in
                    guard let self else { return false }
                    try? await Task.sleep(for: self.pause)
                    return allowed()
                }
                guard !sections.isEmpty,
                      MeetingArchive.setSections(sections, heading: L("Contents"),
                                                 in: meeting.url) else {
                    refused.insert(meeting.url)
                    continue
                }
                written += 1
            }
            if redo { UserDefaults.standard.removeObject(forKey: Self.redoKey) }
            Log.d("sections: backfill done")
        }
    }
}
