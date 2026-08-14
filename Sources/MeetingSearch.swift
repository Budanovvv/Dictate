import Combine
import Foundation
import NaturalLanguage

/// One meeting's score against a query — the unit the ranking rules work on.
/// The URL is the meeting's identity everywhere else in this window, so it is
/// the identity here too.
struct MeetingMatch: Equatable {
    let id: URL
    let score: Double
}

/// Finding a meeting again.
///
/// Two searches share one field, and they answer different questions.
///
/// LITERAL search asks "which transcript contains these characters?" and it is
/// the one that must never regress: it is how the owner finds a Russian word he
/// remembers hearing, a speaker's name, a phone number. It reads the turns.
///
/// SEMANTIC search asks "which meeting was ABOUT this?", and it reads only the
/// title and the one-line English summary each meeting carries. "договорились
/// про юзкейс" cannot find "решили насчёт сценария" by characters; it can by
/// meaning. The results are ADDITIVE — a second, clearly separated group under
/// the exact hits, never a reordering of them.
///
/// Everything in this type is a pure decision, unit-tested with fixed vectors:
/// the model lives in `MeetingMeaning` below, and none of the rules that decide
/// what the owner sees depend on it.
enum MeetingSearch {

    // MARK: - Literal

    /// The search that has always been here: does any turn, or any speaker's
    /// name, contain what was typed.
    static func literal(_ meetings: [ArchivedMeeting], query: String) -> [ArchivedMeeting] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.entries.contains {
                $0.text.lowercased().contains(q) || $0.speaker.lowercased().contains(q)
            }
        }
    }

    // MARK: - Semantic ranking

    /// Below this, nothing is related to anything.
    ///
    /// Calibrated on the owner's own 18 meetings, 2026-08-13, not guessed. A
    /// query with a real answer scores it between 0.47 and 0.70 ("transcription
    /// is slow" → 0.473 is the weakest true hit; "agent onboarding" → 0.702 the
    /// strongest), while a query with no answer in the archive tops out at
    /// 0.39–0.47 ("hiring" → 0.391, "payment to the contractor" → 0.470). The
    /// floor sits under the true hits and takes one spurious row with it, which
    /// is the right side to err on: a wrong row in a group titled "Related" is
    /// cheap, a meeting the owner cannot find is not.
    static let floor = 0.45

    /// …and then only what is close to the BEST answer for THIS query.
    ///
    /// This is the rule that does the real work, because a single absolute cut
    /// cannot do it. The scale of the numbers moves with the query: the correct
    /// meeting for "legal" scores 0.523 while a false positive for "pricing"
    /// reaches 0.561, so no threshold separates them. WITHIN one query the gap
    /// is obvious every time — "agent onboarding" gives 0.702, 0.685, then a
    /// cliff to 0.496; "food and diet" gives 0.561, then 0.329. Keeping what is
    /// within 85% of the best answer cuts exactly at those cliffs.
    static let relative = 0.85

    /// …and the best answer has to STAND OUT from the archive, by this much
    /// over the median meeting's score.
    ///
    /// The rule the other two cannot express, and the one that catches the
    /// worst failure mode. A query the archive has no answer for can still
    /// score 0.527 against seven meetings at once — "договорились про юзкейс",
    /// translated to "Agreed on a use-case", did exactly that and filled the
    /// group with five unrelated system-issue meetings (measured live,
    /// 2026-08-13). There is no cliff there for the relative cut to find,
    /// because the query is not discriminating: it is mildly like everything.
    /// Measured against the median, the difference is stark — every query with
    /// a real answer beats the median by 0.19 to 0.35, while every query
    /// without one manages 0.10 to 0.18. (The margin between those two bands is
    /// thin: 0.175 for "quarterly budget" against 0.188 for "demo problems".
    /// The one query that gets through, "pricing" at 0.227, was already a false
    /// positive under every other rule.)
    static let standout = 0.18

    /// Below this many meetings a median says nothing, and the standout rule is
    /// not applied — in an archive of two, the "median" IS the other meeting.
    static let standoutMinimum = 4

    /// A "related" group is a hint, not a second archive. Five is more than any
    /// query on the owner's archive produced.
    static let limit = 5

    /// The meetings worth showing as related, best first.
    ///
    /// `scored` must be EVERY meeting, not a pre-filtered shortlist: the
    /// standout rule reads the archive's median, and a shortlist has no median
    /// worth reading.
    ///
    /// `excluding` is the literal result: a meeting already listed under the
    /// exact hits must not appear a second time under "related", or the same
    /// row is offered twice as if it were two answers. The cap is applied AFTER
    /// that removal, so excluding the top hit promotes the next one rather than
    /// leaving a shorter group.
    static func related(_ scored: [MeetingMatch], excluding: Set<URL> = [],
                        floor: Double = floor, relative: Double = relative,
                        standout: Double = standout, limit: Int = limit) -> [MeetingMatch] {
        let ranked = scored.sorted { $0.score > $1.score }
        guard let best = ranked.first?.score, best >= floor else { return [] }
        if ranked.count >= standoutMinimum {
            let median = ranked[ranked.count / 2].score
            guard best - median >= standout else { return [] }
        }
        let cut = max(floor, best * relative)
        return ranked
            .filter { $0.score >= cut && !excluding.contains($0.id) }
            .prefix(limit)
            .map { $0 }
    }

    /// Cosine similarity. Zero for a zero vector rather than a NaN — a meeting
    /// the model had nothing to say about must score badly, not poison the sort.
    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// What a meeting is scored on: its title and its summary, SEPARATELY.
    ///
    /// Separately, and this is the measured part. Embedding the two joined into
    /// one string dilutes both: "agent onboarding" then ranked "Business
    /// meeting about legal issue" (0.458) ABOVE "AI system onboarding" (0.304),
    /// because a 90-character sentence and a 3-word query land in different
    /// neighbourhoods however related they are. Scored apart and taken at their
    /// best, the same query gives "AI system onboarding" 0.702 and "Agent
    /// Discussion" 0.685 with the next meeting at 0.496 (measured on the
    /// owner's archive, 2026-08-13).
    static func subjects(of meeting: ArchivedMeeting) -> [String] {
        [meeting.title, meeting.summary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A meeting scores as well as its best part does — see `subjects`.
    static func score(query: [Double], subjects: [[Double]]) -> Double? {
        let scores = subjects.map { cosine(query, $0) }
        return scores.max()
    }

    /// A query too short to mean anything. Two characters match half the
    /// archive by meaning and nothing by intent; literal search still answers
    /// them, which is what a two-character query is actually for.
    static let minimumQuery = 3

    static func worthEmbedding(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumQuery
    }

    // MARK: - What language the query is in

    /// The languages the query might be in, likeliest first.
    ///
    /// Plural, rather than the recognizer's single answer, because a two-word
    /// query is thin evidence and the top answer is wrong in a way that matters
    /// here: "блокчейн" comes back as Bulgarian with 1.00 confidence, and
    /// Bulgarian is a language pack this Mac does not have. The caller walks
    /// these in order and takes the first one macOS can actually translate, so
    /// a Russian word misread as Bulgarian still reaches the index through
    /// Russian.
    static func languageCandidates(for query: String, maximum: Int = 3) -> [String] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(query)
        return recognizer.languageHypotheses(withMaximum: maximum)
            .sorted { $0.value > $1.value }
            .map { $0.key.rawValue.split(separator: "-").first.map(String.init) ?? $0.key.rawValue }
            .filter { $0 != "und" }
    }

    /// The query's language when it is NOT English, and nil when English is
    /// even a possibility.
    ///
    /// "Even a possibility", not "the best guess", and this was measured too:
    /// "google meet is broken" comes back as DUTCH ahead of English, and the
    /// first build of this dutifully sent it to the translator — 1.05 s of
    /// system service to be handed back "Google Meet is broken". A few English
    /// words look like several languages; a Cyrillic query looks like nothing
    /// else. So English anywhere in the candidates means the query is answered
    /// on this keystroke, and only a query with no English reading at all pays
    /// for a translation.
    static func foreignLanguage(of query: String) -> String? {
        let candidates = languageCandidates(for: query)
        guard !candidates.contains("en"), let first = candidates.first else { return nil }
        return first
    }
}

/// The semantic index: one vector per meeting, held in memory.
///
/// Deliberately NOT a file. Eighteen meetings, one short string each, 1.8 ms
/// per vector — the whole index is built in the time it takes the window to
/// draw, and a sidecar cache would buy nothing while adding a disk format, an
/// invalidation rule and a way for the app to disagree with the user's own
/// files. If an archive ever reaches thousands of meetings this becomes worth
/// revisiting; at that size the honest answer is probably a real index, not a
/// cache of this one.
///
/// Nothing here ticks: vectors are built when the library reloads, and the
/// query is scored when the query changes. At rest this object does nothing.
@MainActor
final class MeetingMeaning: ObservableObject {
    static let shared = MeetingMeaning()

    /// Meetings related to the current query, best first — before the literal
    /// hits are removed (the view owns that, since it owns the literal search).
    @Published private(set) var matches: [MeetingMatch] = []

    /// nil when macOS has no English sentence embedding, and then `matches`
    /// stays empty forever: the "related" group never appears and search
    /// behaves exactly as it did before this existed.
    ///
    /// English only, on purpose. `NLEmbedding.sentenceEmbedding` exists for
    /// en/es/fr and NOT for ru/uk/de, and the multilingual
    /// `NLContextualEmbedding` measured barely above noise on this archive
    /// (0.797 for the right answer against 0.720 for unrelated small talk) with
    /// its Cyrillic assets absent from the Mac. What makes an English-only
    /// index enough is that every meeting's summary is written in English even
    /// when the meeting was Russian — the owner's decision, and the reason a
    /// Russian meeting is findable at all.
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    /// meeting URL → the vectors of its title and summary.
    private var index: [URL: [[Double]]] = [:]
    /// What the index was built from, so an unchanged reload is free.
    private var indexed: [URL: [String]] = [:]

    /// Bumped by every new query; a translation that comes back for an older
    /// one is dropped rather than answering a question nobody is asking now.
    private var generation = 0
    /// Queries already translated this run. The owner types a phrase one
    /// character at a time and the debounce still fires more than once — a
    /// second identical translation is a system service call for an answer
    /// already in hand.
    private var translations: [String: String] = [:]

    /// How long typing has to settle before a query is sent to the translator.
    /// Embedding is 1.8 ms and runs live; translation is a system service and
    /// must not be asked once per keystroke.
    private let settle: Duration = .milliseconds(400)

    private init() {}

    // MARK: - Index

    /// Builds (or refreshes) the vectors. Called when the library loads and on
    /// every reload; meetings whose title and summary have not changed keep
    /// the vectors they already have, so a reload after a rename costs one
    /// meeting's worth of work rather than eighteen.
    func index(_ meetings: [ArchivedMeeting]) {
        guard let embedding else { return }
        var next: [URL: [[Double]]] = [:]
        var nextSource: [URL: [String]] = [:]
        var built = 0
        for meeting in meetings {
            let subjects = MeetingSearch.subjects(of: meeting)
            guard !subjects.isEmpty else { continue }
            nextSource[meeting.url] = subjects
            if indexed[meeting.url] == subjects, let cached = index[meeting.url] {
                next[meeting.url] = cached
                continue
            }
            // Lowercased, and measured: the same query against the same
            // archive scored the right meeting 0.627 lowercased against 0.544
            // as written, and moved two true hits above their noise.
            let vectors = subjects.compactMap { embedding.vector(for: $0.lowercased()) }
            guard !vectors.isEmpty else { continue }
            next[meeting.url] = vectors
            built += 1
        }
        index = next
        indexed = nextSource
        if built > 0 { Log.d("search: indexed \(built) meeting(s) by meaning (\(index.count) total)") }
    }

    // MARK: - Query

    /// Scores the archive against what the owner typed.
    ///
    /// An English query is answered synchronously — 1.8 ms, so the related
    /// group appears with the same keystroke the exact hits do. A query in
    /// another language needs a hop through Apple Translation first, which is a
    /// system service: it waits for the typing to settle, and if the language
    /// pack is not on the Mac it silently does nothing at all. That last part
    /// is a hard rule, not politeness — a translation request from an invisible
    /// window once asked macOS for download consent that had nowhere to appear,
    /// and the app bounced in the Dock forever. Packs are downloaded from
    /// Settings, never from a keystroke.
    func search(_ query: String) {
        generation &+= 1
        let generation = generation
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard embedding != nil, MeetingSearch.worthEmbedding(clean) else {
            matches = []
            return
        }
        guard let source = MeetingSearch.foreignLanguage(of: clean) else {
            matches = score(clean)
            return
        }
        if let english = translations[clean] {
            matches = score(english)
            return
        }
        // Nothing to show until the translation lands: showing the untranslated
        // query's scores would be scoring Cyrillic against an English model,
        // which is noise wearing the clothes of an answer.
        matches = []
        let settle = settle
        Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard let self, generation == self.generation else { return }
            guard let english = await Self.english(clean, from: source) else { return }
            guard generation == self.generation else { return }
            self.translations[clean] = english
            self.matches = self.score(english)
        }
    }

    private func score(_ english: String) -> [MeetingMatch] {
        guard let embedding, let query = embedding.vector(for: english.lowercased()) else { return [] }
        return index.compactMap { url, vectors in
            MeetingSearch.score(query: query, subjects: vectors).map { MeetingMatch(id: url, score: $0) }
        }
    }

    // MARK: - Translating the query

    /// The query in English, or nil — in which case the related group simply
    /// does not appear and literal search carries on alone. Every failure is
    /// silent by design: an empty group is the honest answer, and a search
    /// field is not a place to explain a language pack.
    private static func english(_ query: String, from language: String) async -> String? {
        for candidate in MeetingSearch.languageCandidates(for: query) where candidate != "en" {
            // Ask first, translate second. AppleTranslator.translate checks
            // this too but sleeps 1.5 s before giving up, which is a long time
            // to hold a search field; and a pack that is missing must fail
            // here, never by asking macOS to fetch it.
            guard await AppleTranslator.isInstalled(from: candidate, to: "en") else { continue }
            do {
                let started = Date()
                let english = try await AppleTranslator.shared.translate(query, to: "en", source: candidate)
                Log.d(String(format: "search: \"%@\" %@→en \"%@\" in %.2fs", query, candidate,
                             english, Date().timeIntervalSince(started)))
                return english
            } catch {
                Log.d("search: could not translate \(candidate)→en (\(error)) — literal results only")
                return nil
            }
        }
        Log.d("search: no installed pack for \(language)→en — literal results only")
        return nil
    }
}
