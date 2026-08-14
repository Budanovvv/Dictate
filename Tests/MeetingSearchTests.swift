import XCTest

/// Searching the archive. Two questions share one field — "which transcript
/// contains these characters" and "which meeting was about this" — and the
/// rules that decide what the owner sees are pinned here.
///
/// Every semantic test uses FIXED vectors, never the model. What is being
/// tested is the ranking policy, and a test that called NLEmbedding would pass
/// or fail on whichever assets happen to be on the machine running it.
final class MeetingSearchTests: XCTestCase {

    // MARK: - Fixtures

    private func meeting(_ name: String, title: String?, summary: String?,
                         says: [String] = [], speaker: String = "Speaker 1",
                         sections: [TranscriptSection] = []) -> ArchivedMeeting {
        let entries = says.map {
            TranscriptEntry(time: "09:17:52", speaker: speaker, text: $0, isYou: false)
        }
        return ArchivedMeeting(id: URL(fileURLWithPath: "/tmp/\(name).md"),
                               url: URL(fileURLWithPath: "/tmp/\(name).md"),
                               started: Date(timeIntervalSince1970: 0),
                               entries: entries, title: title, summary: summary,
                               sections: sections)
    }

    private func subject(_ text: String, _ moment: String? = nil) -> MeetingSearch.Subject {
        MeetingSearch.Subject(text: text, moment: moment)
    }

    private func vector(_ v: [Double], _ moment: String? = nil) -> MeetingSearch.SubjectVector {
        MeetingSearch.SubjectVector(vector: v, moment: moment)
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).md") }

    private func match(_ name: String, _ score: Double) -> MeetingMatch {
        MeetingMatch(id: url(name), score: score)
    }

    // MARK: - Literal search must not regress

    /// The search that has always been here, and the one the owner relies on to
    /// find a word he remembers hearing.
    func testLiteralFindsSpokenWordsInAnyLanguage() {
        let archive = [
            meeting("a", title: "Release planning", summary: "2.4 slipped a week",
                    says: ["Давай начнём с оплаты подрядчику"]),
            meeting("b", title: "Standup", summary: "Nothing to report", says: ["All good"]),
        ]
        XCTAssertEqual(MeetingSearch.literal(archive, query: "оплаты").map(\.url), [url("a")])
        XCTAssertEqual(MeetingSearch.literal(archive, query: "all good").map(\.url), [url("b")])
    }

    /// Case-insensitive, and a speaker's name counts as much as a word said.
    func testLiteralMatchesSpeakerNamesAndIgnoresCase() {
        let archive = [meeting("a", title: nil, summary: nil, says: ["Yes"], speaker: "Ruslan")]
        XCTAssertEqual(MeetingSearch.literal(archive, query: "RUSLAN").count, 1)
        XCTAssertEqual(MeetingSearch.literal(archive, query: "ruslan").count, 1)
    }

    /// A number in a transcript is exactly the kind of thing meaning cannot
    /// find and characters can.
    func testLiteralFindsNumbers() {
        let archive = [meeting("a", title: "Pricing", summary: nil, says: ["It came to 4500 euro"])]
        XCTAssertEqual(MeetingSearch.literal(archive, query: "4500").count, 1)
    }

    /// An empty query is not a search — it is the plain list, unchanged.
    func testEmptyQueryReturnsEverything() {
        let archive = [meeting("a", title: "A", summary: nil), meeting("b", title: "B", summary: nil)]
        XCTAssertEqual(MeetingSearch.literal(archive, query: "").count, 2)
        XCTAssertEqual(MeetingSearch.literal(archive, query: "   ").count, 2)
    }

    // MARK: - What a meeting is scored on

    /// Title and summary, separately — the measured decision (a joined string
    /// ranked an unrelated meeting above the right one).
    func testSubjectsAreTitleAndSummarySeparately() {
        let m = meeting("a", title: "Release planning", summary: "2.4 slipped a week")
        XCTAssertEqual(MeetingSearch.subjects(of: m),
                       [subject("Release planning"), subject("2.4 slipped a week")])
    }

    /// …and every section, each carrying the moment it starts at. This is what
    /// turns a hit into a place: the title and the summary describe the whole
    /// hour and point nowhere, a section points at three minutes.
    func testSubjectsIncludeSectionsWithTheirMoments() {
        let m = meeting("a", title: "Release planning", summary: "2.4 slipped a week",
                        sections: [TranscriptSection(time: "09:20:11", line: "Notarization fails on CI"),
                                   TranscriptSection(time: "09:24:03", line: "Pricing for the pilot")])
        XCTAssertEqual(MeetingSearch.subjects(of: m), [
            subject("Release planning"),
            subject("2.4 slipped a week"),
            subject("Notarization fails on CI", "09:20:11"),
            subject("Pricing for the pilot", "09:24:03"),
        ])
    }

    /// A meeting the model never named or summarized has nothing to score, and
    /// must not be scored on an empty string.
    func testSubjectsSkipMissingAndBlankParts() {
        XCTAssertEqual(MeetingSearch.subjects(of: meeting("a", title: "Standup", summary: nil)),
                       [subject("Standup")])
        XCTAssertTrue(MeetingSearch.subjects(of: meeting("b", title: nil, summary: nil)).isEmpty)
        XCTAssertTrue(MeetingSearch.subjects(of: meeting("c", title: "  ", summary: "\n")).isEmpty)
    }

    /// A meeting scores as well as its BEST part does: a query that hits the
    /// summary must not be dragged down by an unrelated title.
    func testScoreTakesTheBestPart() {
        let query = [1.0, 0.0]
        let subjects = [vector([0.0, 1.0]), vector([1.0, 0.0])]   // title unrelated, summary exact
        XCTAssertEqual(MeetingSearch.best(query: query, subjects: subjects)!.score, 1.0, accuracy: 1e-9)
    }

    func testScoreOfNothingIsNil() {
        XCTAssertNil(MeetingSearch.best(query: [1.0, 0.0], subjects: []))
    }

    /// A meeting answers with the part that won: a section hit brings its
    /// moment along, so the click can land there.
    func testBestReportsTheMomentOfTheWinningSubject() {
        let subjects = [vector([0.0, 1.0]), vector([0.9, 0.1], "10:26:17"), vector([0.5, 0.5], "10:31:02")]
        XCTAssertEqual(MeetingSearch.best(query: [1.0, 0.0], subjects: subjects)?.moment, "10:26:17")
    }

    /// A tie goes to the meeting as a whole, not to whichever section happens
    /// to phrase it the same way — a meeting that IS the answer opens at the
    /// beginning.
    func testTieGoesToTheWholeMeeting() {
        let subjects = [vector([1.0, 0.0]), vector([1.0, 0.0], "10:26:17")]
        XCTAssertNil(MeetingSearch.best(query: [1.0, 0.0], subjects: subjects)?.moment)
    }

    // MARK: - Cosine

    func testCosine() {
        XCTAssertEqual(MeetingSearch.cosine([1, 0], [1, 0]), 1.0, accuracy: 1e-9)
        XCTAssertEqual(MeetingSearch.cosine([1, 0], [0, 1]), 0.0, accuracy: 1e-9)
        XCTAssertEqual(MeetingSearch.cosine([1, 0], [-1, 0]), -1.0, accuracy: 1e-9)
        // Length must not matter — only direction.
        XCTAssertEqual(MeetingSearch.cosine([1, 1], [7, 7]), 1.0, accuracy: 1e-9)
    }

    /// A zero vector scores zero, not NaN — a NaN in the list would make the
    /// sort meaningless rather than putting one meeting in the wrong place.
    func testCosineOfDegenerateVectorsIsZeroNotNaN() {
        XCTAssertEqual(MeetingSearch.cosine([0, 0], [1, 0]), 0)
        XCTAssertEqual(MeetingSearch.cosine([], []), 0)
        XCTAssertEqual(MeetingSearch.cosine([1, 0], [1, 0, 0]), 0)   // mismatched, not a crash
    }

    // MARK: - The ranking policy

    /// An archive-shaped list: the given scores, then the long dull tail every
    /// real query has under it. The ranking reads the MEDIAN, so a four-element
    /// fixture is not a small archive — it is an archive whose median is one of
    /// the answers, which is a different thing entirely.
    private func archive(_ scores: [Double], tail: Int = 14,
                         from: Double = 0.33) -> [MeetingMatch] {
        var all = scores.enumerated().map { match("top\($0.offset)", $0.element) }
        all += (0..<tail).map { match("tail\($0)", from - Double($0) * 0.015) }
        return all.shuffled()      // order in must not matter
    }

    private func topURLs(_ count: Int) -> [URL] { (0..<count).map { url("top\($0)") } }

    /// Every ranking test below passes the archive's BACKGROUND — the median
    /// score of every indexed subject for that query — because that is what
    /// the app passes, and the standout threshold is calibrated against it.
    /// The numbers are the measured ones (2026-08-14).
    private func related(_ scored: [MeetingMatch], background: Double) -> [URL] {
        MeetingSearch.related(scored, background: background).map(\.id)
    }

    /// The floor: a query with no answer in the archive shows no group at all,
    /// rather than the least-bad meeting the archive happens to hold.
    func testNothingIsRelatedWhenEverythingScoresBadly() {
        XCTAssertTrue(related(archive([0.39, 0.30, 0.12]), background: 0.22).isEmpty)
    }

    /// The relative cut, which is one of the rules doing the real work: two
    /// clear answers, then a cliff, and the cliff is where the group ends.
    /// These are the measured scores for "agent onboarding" on the owner's
    /// archive.
    func testRelativeCutKeepsTheClusterAndDropsTheTail() {
        let scored = archive([0.702, 0.685, 0.496, 0.452])
        XCTAssertEqual(related(scored, background: 0.295), topURLs(2))
    }

    /// …and a weak-but-real best answer still brings its cluster, which a
    /// single absolute threshold could not do: these are the measured scores
    /// for "transcription is slow", where every true hit sits below the score a
    /// FALSE positive reached on another query.
    func testAWeakBestAnswerStillBringsItsCluster() {
        let scored = archive([0.473, 0.466, 0.450, 0.335], from: 0.30)
        XCTAssertEqual(related(scored, background: 0.128), topURLs(3))
    }

    /// The background is the median of every SUBJECT, not of every meeting —
    /// the change sections forced. A meeting is scored by its best part, so a
    /// meeting with thirteen sections gets thirteen chances; a median over
    /// meetings would then move with how much of the archive the backfill has
    /// reached, which is not a property of the query.
    func testBackgroundIsTheMedianSubjectScore() {
        XCTAssertEqual(MeetingSearch.background(of: [0.1, 0.5, 0.9])!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(MeetingSearch.background(of: [0.9, 0.1])!, 0.9, accuracy: 1e-9)
        XCTAssertNil(MeetingSearch.background(of: []))
    }

    /// With no background to judge against — an archive nothing is indexed for
    /// — the rule falls back to the median meeting rather than admitting
    /// everything.
    func testWithoutABackgroundTheMedianMeetingIsStillUsed() {
        let scored = archive([0.702, 0.685, 0.496, 0.452])
        XCTAssertFalse(MeetingSearch.related(scored).isEmpty)
    }

    /// The standout rule, and the reason it exists: a query the archive has no
    /// answer for can still score 0.527 against seven meetings at once. There
    /// is no cliff to find because the query is mildly like everything — these
    /// are the measured scores for "Agreed on a use-case", which filled the
    /// group with five unrelated meetings before this rule.
    func testAQueryThatIsMildlyLikeEverythingIsRelatedToNothing() {
        let scored = archive([0.527, 0.527, 0.521, 0.508, 0.473, 0.467, 0.458],
                             tail: 11, from: 0.442)
        XCTAssertTrue(related(scored, background: 0.38).isEmpty)
    }

    /// The same shape with the archive's mass pulled down — the top has
    /// something to stand out FROM, and now it does.
    func testTheSameTopScoreStandsOutOverAQuieterArchive() {
        let scored = archive([0.527, 0.520], tail: 16, from: 0.30)
        XCTAssertEqual(related(scored, background: 0.20), topURLs(2))
    }

    /// A median says nothing about an archive of three, where it IS one of the
    /// answers. Below that size the standout rule stands aside rather than
    /// silencing a new user's whole library.
    func testAnArchiveTooSmallForAMedianIsJudgedOnTheScoresAlone() {
        let scored = [match("a", 0.70), match("b", 0.68), match("c", 0.65)]
        XCTAssertEqual(MeetingSearch.related(scored).count, 3)
    }

    /// Best first — the group is a ranking, not a set.
    func testRelatedIsSortedByScore() {
        let scored = archive([0.70, 0.65, 0.61])
        XCTAssertEqual(MeetingSearch.related(scored).map(\.id), topURLs(3))
    }

    /// A meeting already listed among the exact hits must not appear again
    /// under "related" — the same row twice reads as two answers.
    func testLiteralHitsAreNotRepeated() {
        let scored = archive([0.70, 0.68, 0.65])
        let related = MeetingSearch.related(scored, excluding: [url("top1")])
        XCTAssertEqual(related.map(\.id), [url("top0"), url("top2")])
    }

    /// Excluding the TOP hit must not raise the bar for everyone else: the
    /// literal search finding the best match is not a reason to hide the rest.
    func testExcludingTheBestKeepsTheRestOfTheCluster() {
        let scored = archive([0.70, 0.68, 0.30])
        XCTAssertEqual(MeetingSearch.related(scored, excluding: [url("top0")]).map(\.id),
                       [url("top1")])
    }

    /// The group is a hint, not a second archive.
    func testRelatedIsCapped() {
        let scored = archive((0..<12).map { 0.90 - Double($0) * 0.001 }, tail: 20, from: 0.30)
        XCTAssertEqual(MeetingSearch.related(scored).count, MeetingSearch.limit)
    }

    /// The cap is applied after the exclusion, so removing exact hits promotes
    /// the meetings behind them instead of shortening the group.
    func testCapCountsWhatIsActuallyShown() {
        let scored = archive((0..<12).map { 0.90 - Double($0) * 0.001 }, tail: 20, from: 0.30)
        let related = MeetingSearch.related(scored, excluding: [url("top0"), url("top1")])
        XCTAssertEqual(related.count, MeetingSearch.limit)
        XCTAssertEqual(related.first?.id, url("top2"))
    }

    func testNothingScoredIsNothingRelated() {
        XCTAssertTrue(MeetingSearch.related([]).isEmpty)
    }

    // MARK: - When a query is worth asking the model about

    /// Two characters match half the archive by meaning and nothing by intent.
    /// Literal search still answers them, which is what such a query is for.
    func testVeryShortQueriesAreLiteralOnly() {
        XCTAssertFalse(MeetingSearch.worthEmbedding("ab"))
        XCTAssertFalse(MeetingSearch.worthEmbedding("  a  "))
        XCTAssertTrue(MeetingSearch.worthEmbedding("demo"))
        XCTAssertTrue(MeetingSearch.worthEmbedding("демо"))
    }

    // MARK: - Choosing the language to translate the query from

    /// The recognizer's single best answer is not enough evidence from two
    /// words: "блокчейн" comes back as Bulgarian with full confidence, and
    /// Bulgarian is a pack this Mac does not have. The candidates are walked in
    /// order, so a Russian word misread as Bulgarian still reaches the index
    /// through Russian.
    func testCandidatesOfferMoreThanTheTopGuess() {
        let candidates = MeetingSearch.languageCandidates(for: "блокчейн")
        XCTAssertTrue(candidates.count > 1, "only \(candidates)")
        XCTAssertTrue(candidates.contains("ru"), "\(candidates)")
        XCTAssertFalse(candidates.contains("en"), "\(candidates)")
    }

    /// An English query needs no translation at all, and must be recognized as
    /// such — a needless hop through a system service is a second of latency
    /// for an answer already in hand.
    func testEnglishQueriesAreNotTranslated() {
        XCTAssertNil(MeetingSearch.foreignLanguage(of: "agent onboarding"))
        XCTAssertNil(MeetingSearch.foreignLanguage(of: "demo problems"))
        XCTAssertNil(MeetingSearch.foreignLanguage(of: "legal"))
    }

    /// …including the ones the recognizer's TOP guess gets wrong. "google meet
    /// is broken" comes back as Dutch ahead of English, and the first build of
    /// this spent 1.05 s translating it into "Google Meet is broken" (measured
    /// live, 2026-08-13). English anywhere in the candidates is enough.
    func testEnglishBehindAWrongTopGuessIsStillEnglish() {
        XCTAssertNil(MeetingSearch.foreignLanguage(of: "google meet is broken"))
    }

    /// A Cyrillic query looks like nothing else, and does need the hop.
    func testRussianQueriesAreTranslated() {
        XCTAssertNotNil(MeetingSearch.foreignLanguage(of: "юридический вопрос"))
        XCTAssertNotNil(MeetingSearch.foreignLanguage(of: "договорились про юзкейс"))
    }
}
