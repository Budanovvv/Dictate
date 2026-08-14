import Combine
import Foundation
import NaturalLanguage

/// One meeting's score against a query — the unit the ranking rules work on.
/// The URL is the meeting's identity everywhere else in this window, so it is
/// the identity here too.
struct MeetingMatch: Equatable {
    let id: URL
    let score: Double
    /// WHERE in the meeting the score came from: the clock time of the section
    /// that matched, or nil when what matched was the meeting's own title or
    /// summary — those are about the whole hour and point at no moment in
    /// particular.
    ///
    /// This is the difference between a search that finds a meeting and one
    /// that answers a question. "We discussed somewhere how Shannon would test
    /// it" is three minutes out of fifty, and a row that opens a fifty-minute
    /// transcript at the top has not found them.
    let moment: String?

    init(id: URL, score: Double, moment: String? = nil) {
        self.id = id
        self.score = score
        self.moment = moment
    }
}

/// Finding a meeting again.
///
/// Two searches share one field, and they answer different questions.
///
/// LITERAL search asks "which transcript contains these characters?" and it is
/// the one that must never regress: it is how the owner finds a Russian word he
/// remembers hearing, a speaker's name, a phone number. It reads the turns.
///
/// SEMANTIC search asks "which meeting was ABOUT this?", and it reads the
/// English things a meeting says about itself: its title, its one-line summary,
/// and — since sections — a line per few minutes of it. "договорились про
/// юзкейс" cannot find "решили насчёт сценария" by characters; it can by
/// meaning. The results are ADDITIVE — a second, clearly separated group under
/// the exact hits, never a reordering of them.
///
/// A section hit answers with a MOMENT, which is the point of the whole
/// exercise: the owner is not looking for a meeting, he is looking for the
/// three minutes inside it, and a row that opens a fifty-minute transcript at
/// the top has not found them.
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
    /// 0.80 rather than the 0.85 this shipped with, re-measured once meetings
    /// carry sections (2026-08-14). A section line is a whole clause and a
    /// query is two or three words, and the two land further apart than a
    /// three-word TITLE and the same query do — so the right section is
    /// routinely a hundredth or two behind some short title, and an 0.85 cut
    /// under that title excluded it. At 0.80 the same nineteen probes answer
    /// eleven questions instead of nine with no new false groups.
    ///
    /// This is the rule that does the real work, because a single absolute cut
    /// cannot do it. The scale of the numbers moves with the query: the correct
    /// meeting for "legal" scores 0.523 while a false positive for "pricing"
    /// reaches 0.561, so no threshold separates them. WITHIN one query the gap
    /// is obvious every time — "agent onboarding" gives 0.702, 0.685, then a
    /// cliff to 0.496; "food and diet" gives 0.561, then 0.329. Keeping what is
    /// within 80% of the best answer cuts at those cliffs without cutting the
    /// right section off behind some shorter, blunter title.
    static let relative = 0.80

    /// …and the best answer has to STAND OUT from the archive, by this much
    /// over the median SUBJECT's score (see `background(of:)`).
    ///
    /// The rule the other two cannot express, and the one that catches the
    /// worst failure mode. A query the archive has no answer for can still
    /// score 0.527 against seven meetings at once — "договорились про юзкейс",
    /// translated to "Agreed on a use-case", did exactly that and filled the
    /// group with five unrelated system-issue meetings (measured live,
    /// 2026-08-13). There is no cliff there for the relative cut to find,
    /// because the query is not discriminating: it is mildly like everything.
    ///
    /// 0.25, not the 0.18 this shipped with, and the two numbers are not
    /// comparable: 0.18 was a margin over the median MEETING and this is a
    /// margin over the median SUBJECT, which sits lower because a meeting is
    /// scored by its best part. Re-measured over nineteen probes on the
    /// owner's archive (2026-08-14), the two bands are again well apart —
    /// a query with a real answer beats the background by 0.25 to 0.43
    /// ("changing the agent's name" 0.327, "agent onboarding" 0.407), while a
    /// query without one manages 0.17 to 0.21 ("hiring" 0.167, "notarization"
    /// 0.208, "quarterly budget" 0.221). The band between them is 0.04 wide;
    /// when the archive grows, measure it again. The one query that still gets
    /// through is "pricing" at 0.323 → "Recording process", which was already
    /// a false positive under every previous rule.
    static let standout = 0.25

    /// Below this many meetings a median says nothing, and the standout rule is
    /// not applied — in an archive of two, the "median" IS the other meeting.
    static let standoutMinimum = 4

    /// The median of every SUBJECT the archive has, not of every meeting.
    ///
    /// The change sections forced, and the one that did the real work in the
    /// re-calibration. A meeting scores as its best subject does, so a meeting
    /// with thirteen sections gets thirteen chances and one with a bare title
    /// gets one — and a median taken over MEETINGS therefore moves with how
    /// many of them happen to have been sectioned yet, which is a property of
    /// the backfill rather than of the query. Taken over subjects it measures
    /// what the standout rule is actually asking: how much this query likes
    /// everything in the archive, so that "it likes one thing far more" means
    /// something. Measured on the owner's archive with nineteen probes: over
    /// meetings, 9 of 13 real questions answered; over subjects, 11 — with the
    /// same single false group ("pricing" → "Recording process", the known one)
    /// and the same five of six empty questions correctly answered with
    /// silence.
    static func background(of scores: [Double]) -> Double? {
        guard !scores.isEmpty else { return nil }
        return scores.sorted()[scores.count / 2]
    }

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
    /// `background` is the archive's median SUBJECT score for this query (see
    /// `background(of:)`); nil falls back to the median meeting, which is what
    /// an archive with nothing indexed yet can offer.
    static func related(_ scored: [MeetingMatch], background: Double? = nil,
                        excluding: Set<URL> = [],
                        floor: Double = floor, relative: Double = relative,
                        standout: Double = standout, limit: Int = limit) -> [MeetingMatch] {
        let ranked = scored.sorted { $0.score > $1.score }
        guard let best = ranked.first?.score, best >= floor else { return [] }
        if ranked.count >= standoutMinimum {
            let median = background ?? ranked[ranked.count / 2].score
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
    /// One thing that can be said about a meeting, and where in the meeting it
    /// points.
    struct Subject: Equatable {
        let text: String
        /// nil for the title and the summary — they describe the whole hour.
        let moment: String?
    }

    static func subjects(of meeting: ArchivedMeeting) -> [Subject] {
        var subjects: [Subject] = []
        for text in [meeting.title, meeting.summary] {
            guard let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clean.isEmpty else { continue }
            subjects.append(Subject(text: clean, moment: nil))
        }
        // …and every section, which is what turns a hit into a place. A meeting
        // therefore offers one or two subjects before it has been sectioned and
        // ten to fifteen afterwards — which is why the three rules below had to
        // be re-measured rather than inherited (see `floor`).
        for section in meeting.sections {
            let clean = section.line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            subjects.append(Subject(text: clean, moment: section.time))
        }
        return subjects
    }

    /// A vector and the moment it stands for — what the index holds.
    struct SubjectVector: Equatable {
        let vector: [Double]
        let moment: String?
    }

    /// A meeting scores as well as its best part does, and it answers WITH that
    /// part — see `subjects`.
    ///
    /// Ties go to the earlier subject, which means the title and the summary
    /// win a tie against a section. That is the right way round: a meeting
    /// whose whole subject IS the query should open at the beginning, not at
    /// whichever section happens to phrase it identically.
    static func best(query: [Double], subjects: [SubjectVector]) -> (score: Double, moment: String?)? {
        var best: (score: Double, moment: String?)?
        for subject in subjects {
            let score = cosine(query, subject.vector)
            if best == nil || score > best!.score { best = (score, subject.moment) }
        }
        return best
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

    /// How much this query likes the archive in general — the median score of
    /// every indexed subject, which is what the standout rule measures the
    /// best answer against. Published beside the matches because the two are
    /// one answer: a score means nothing without the noise it stands out from.
    @Published private(set) var background: Double = 0

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

    /// meeting URL → the vectors of its title, its summary and every section.
    private var index: [URL: [MeetingSearch.SubjectVector]] = [:]
    /// What the index was built from, so an unchanged reload is free.
    private var indexed: [URL: [MeetingSearch.Subject]] = [:]

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
        var next: [URL: [MeetingSearch.SubjectVector]] = [:]
        var nextSource: [URL: [MeetingSearch.Subject]] = [:]
        var built = 0, vectorCount = 0
        for meeting in meetings {
            let subjects = MeetingSearch.subjects(of: meeting)
            guard !subjects.isEmpty else { continue }
            nextSource[meeting.url] = subjects
            if indexed[meeting.url] == subjects, let cached = index[meeting.url] {
                next[meeting.url] = cached
                vectorCount += cached.count
                continue
            }
            // Lowercased, and measured: the same query against the same
            // archive scored the right meeting 0.627 lowercased against 0.544
            // as written, and moved two true hits above their noise.
            let vectors = subjects.compactMap { subject in
                embedding.vector(for: subject.text.lowercased())
                    .map { MeetingSearch.SubjectVector(vector: $0, moment: subject.moment) }
            }
            guard !vectors.isEmpty else { continue }
            next[meeting.url] = vectors
            vectorCount += vectors.count
            built += 1
        }
        index = next
        indexed = nextSource
        if built > 0 {
            Log.d("search: indexed \(built) meeting(s) by meaning (\(index.count) total, \(vectorCount) vectors)")
        }
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
            background = 0
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
        guard let embedding, let query = embedding.vector(for: english.lowercased()) else {
            background = 0
            return []
        }
        var everySubject: [Double] = []
        let matches: [MeetingMatch] = index.compactMap { url, vectors in
            var best: (score: Double, moment: String?)?
            for subject in vectors {
                let score = MeetingSearch.cosine(query, subject.vector)
                everySubject.append(score)
                if best == nil || score > best!.score { best = (score, subject.moment) }
            }
            return best.map { MeetingMatch(id: url, score: $0.score, moment: $0.moment) }
        }
        background = MeetingSearch.background(of: everySubject) ?? 0
        return matches
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
