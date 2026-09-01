import XCTest

/// The archive parses the very files the app writes — the format is the
/// contract between a recording made today and a window opened next month,
/// so it is pinned here rather than trusted.
final class TranscriptParsingTests: XCTestCase {

    private let sample = """
    # Meeting transcript — August 10, 2026 at 9:17 AM

    **[09:17:52] You:** Давай начнём.

    **[09:18:26] Speaker 1:** Да, я готов.

    **[09:18:31] Speaker 1:** Продолжаю мысль.

    """

    func testParsesEntries() {
        let entries = MeetingArchive.parse(markdown: sample, youLabel: "You")
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].time, "09:17:52")
        XCTAssertEqual(entries[0].speaker, "You")
        XCTAssertEqual(entries[0].text, "Давай начнём.")
        XCTAssertTrue(entries[0].isYou)
        XCTAssertFalse(entries[1].isYou)
    }

    func testTitleIsNotAnEntry() {
        let entries = MeetingArchive.parse(markdown: "# Meeting transcript — x\n\n", youLabel: "You")
        XCTAssertTrue(entries.isEmpty)
    }

    func testWrappedTextJoinsThePreviousEntry() {
        let text = "**[09:17:52] You:** first part\nsecond part\n"
        let entries = MeetingArchive.parse(markdown: text, youLabel: "You")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "first part second part")
    }

    func testConsecutiveEntriesOfOneVoiceBecomeOneTurn() {
        let turns = MeetingArchive.turns(MeetingArchive.parse(markdown: sample, youLabel: "You"))
        XCTAssertEqual(turns.count, 2)                      // You, then Speaker 1 ×2
        XCTAssertEqual(turns[1].entries.count, 2)
        XCTAssertEqual(turns[1].time, "09:18:26")           // the turn starts when it started
        XCTAssertEqual(turns[1].text, "Да, я готов. Продолжаю мысль.")
    }

    func testClockParsingRejectsNonsense() {
        XCTAssertEqual(MeetingArchive.seconds(fromClock: "01:02:03"), 3723)
        XCTAssertNil(MeetingArchive.seconds(fromClock: "25:00:00"))
        XCTAssertNil(MeetingArchive.seconds(fromClock: "hello"))
    }
}

/// The owner's own turns must be recognized in a transcript written in ANY of
/// the shipped languages.
///
/// The archive used to compare the speaker label with `L("You")` — the word
/// for "You" in the language the window happens to be in RIGHT NOW. A file
/// carries whatever word was current when it was written and never changes, so
/// switching the app to German turned every English "You" in the archive into
/// a stranger: it took a colour out of the speaker palette and painted the
/// owner as someone else. Found while shooting the German UI (2026-08-13).
final class OwnerLabelTests: XCTestCase {

    /// Written in English, read with the Russian label — and the other way
    /// round. Neither the file nor the reader may have to agree on a language.
    func testOwnerIsRecognizedAcrossLanguages() {
        let english = "**[09:17:52] You:** hi\n"
        XCTAssertTrue(MeetingArchive.parse(markdown: english, youLabel: "Вы")[0].isYou)

        let russian = "**[09:17:52] Вы:** привет\n"
        XCTAssertTrue(MeetingArchive.parse(markdown: russian, youLabel: "You")[0].isYou)

        let german = "**[09:17:52] Sie:** hallo\n"
        XCTAssertTrue(MeetingArchive.parse(markdown: german, youLabel: "You")[0].isYou)
    }

    /// …while everyone else stays a stranger, whatever the reader's language.
    func testOtherSpeakersAreNotTheOwner() {
        let text = "**[09:17:52] Speaker 1:** hi\n\n**[09:18:00] Anna:** hello\n"
        let entries = MeetingArchive.parse(markdown: text, youLabel: "Вы")
        XCTAssertFalse(entries[0].isYou)
        XCTAssertFalse(entries[1].isYou)
    }

    /// Every language the app ships must contribute its word, or a transcript
    /// recorded in that language would be the next German bug.
    func testEveryShippedLanguageContributesItsWord() {
        for language in AppLanguage.allCases where language != .system {
            let word = Localization.shared.string("You", in: language)
            XCTAssertTrue(MeetingArchive.youLabels.contains(word),
                          "\"\(word)\" (\(language.rawValue)) is not recognized as the owner")
        }
    }
}

/// The summary lives in the .md, on its own line under the italic date — so
/// renaming in Finder, reading in a Markdown app and hand-editing all keep
/// working, exactly as they do for the title.
final class MeetingSummaryFileTests: XCTestCase {

    private let titled = """
    # Release planning
    _August 10, 2026 at 9:17 AM_

    **[09:17:52] You:** Обсудим релиз.

    **[09:18:26] Speaker 1:** Готов.

    """

    private let summary = "Release 2.4 slips a week; notarization still fails on the CI box."

    func testSummarySurvivesARoundTrip() {
        let written = MeetingArchive.applying(summary: summary, to: titled)
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: written), summary)
    }

    /// The whole hazard of putting a plain line in a file whose entries are
    /// parsed by prefix: it must be neither an entry nor part of one.
    func testSummaryNeverLeaksIntoTheTranscript() {
        let written = MeetingArchive.applying(summary: summary, to: titled)
        let entries = MeetingArchive.parse(markdown: written, youLabel: "You")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].text, "Обсудим релиз.")
        XCTAssertFalse(entries.contains { $0.text.contains("notarization") })
        XCTAssertFalse(entries.contains { $0.speaker.contains("Release") })
    }

    func testTitleAndDateAreUntouched() {
        let written = MeetingArchive.applying(summary: summary, to: titled)
        XCTAssertEqual(MeetingArchive.parseTitle(markdown: written), "Release planning")
        XCTAssertTrue(written.contains("_August 10, 2026 at 9:17 AM_"))
    }

    func testASecondSummaryReplacesTheFirst() {
        let once = MeetingArchive.applying(summary: summary, to: titled)
        let twice = MeetingArchive.applying(summary: "Something else entirely, at length.",
                                            to: once)
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: twice),
                       "Something else entirely, at length.")
        XCTAssertFalse(twice.contains("notarization"))
        XCTAssertEqual(MeetingArchive.parse(markdown: twice, youLabel: "You").count, 2)
    }

    /// Renaming a meeting rewrites its header — and must not throw away the
    /// sentence underneath while it is in there.
    func testRetitlingKeepsTheSummary() {
        let written = MeetingArchive.applying(summary: summary, to: titled)
        let renamed = MeetingArchive.applying(title: "Release 2.4", dateLine: "D", to: written)
        XCTAssertEqual(MeetingArchive.parseTitle(markdown: renamed), "Release 2.4")
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: renamed), summary)
    }

    /// nil means "leave whatever is there alone" — the case that makes
    /// retitling safe.
    func testNoSummaryChangesNothing() {
        let written = MeetingArchive.applying(summary: summary, to: titled)
        XCTAssertEqual(MeetingArchive.applying(summary: nil, to: written), written)
    }

    func testATranscriptWithoutOneHasNoSummary() {
        XCTAssertNil(MeetingArchive.parseSummary(markdown: titled))
    }

    /// The head may carry a metadata comment between the date and the
    /// summary. Found live 2026-09-01: the first transcript ever written
    /// with a source line showed the comment AS its summary — in the card
    /// and above the transcript.
    func testSourceCommentIsNotTheSummary() {
        let sourced = """
        # Release planning
        _August 10, 2026 at 9:17 AM_
        <!-- source: Google Meet -->
        \(summary)

        **[09:17:52] You:** Обсудим релиз.

        """
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: sourced), summary)
        XCTAssertEqual(MeetingArchive.parseSource(markdown: sourced), "Google Meet")
    }

    /// A freshly recorded call carries its source from creation; the summary
    /// written at the end must land under the comment, not inside it — and
    /// neither may evict the other.
    func testSummaryLandsUnderTheSourceComment() {
        let sourced = """
        # Release planning
        _August 10, 2026 at 9:17 AM_
        <!-- source: Zoom -->

        **[09:17:52] You:** Обсудим релиз.

        """
        let written = MeetingArchive.applying(summary: summary, to: sourced)
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: written), summary)
        XCTAssertEqual(MeetingArchive.parseSource(markdown: written), "Zoom")
        XCTAssertEqual(MeetingArchive.parse(markdown: written, youLabel: "You").count, 1)
        let replaced = MeetingArchive.applying(summary: "Another sentence entirely.",
                                               to: written)
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: replaced),
                       "Another sentence entirely.")
        XCTAssertFalse(replaced.contains("notarization"))
    }

    /// A sourced transcript with no summary still has none — the comment
    /// must not be promoted to one by the skipping logic either.
    func testSourcedTranscriptWithoutSummaryHasNone() {
        let sourced = """
        # Release planning
        _August 10, 2026 at 9:17 AM_
        <!-- source: Zoom -->

        **[09:17:52] You:** Обсудим релиз.

        """
        XCTAssertNil(MeetingArchive.parseSummary(markdown: sourced))
    }

    /// An unnamed transcript has no italic date line to hang a summary under,
    /// so there is nowhere to put one — and nothing is written.
    func testUnnamedTranscriptIsLeftAlone() {
        let unnamed = "# Meeting transcript — August 10, 2026 at 9:17 AM\n\n**[09:17:52] You:** hi\n"
        XCTAssertEqual(MeetingArchive.applying(summary: summary, to: unnamed), unnamed)
        XCTAssertNil(MeetingArchive.parseSummary(markdown: unnamed))
    }

    /// A summary is one line by construction — a newline in it would leave its
    /// tail sitting in the file as something the parser has to explain.
    func testAMultiLineSummaryIsFlattened() {
        let written = MeetingArchive.applying(summary: "First line\nsecond line", to: titled)
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: written), "First line second line")
        XCTAssertEqual(MeetingArchive.parse(markdown: written, youLabel: "You").count, 2)
    }
}

/// A meeting named by the on-device model keeps its date visible: the title
/// goes on the H1, the date on an italic line right under it. That italic
/// line is the marker — it tells a named transcript from one still known by
/// its date, without guessing whether an H1 "looks like" a date in some
/// language.
final class MeetingTitleTests: XCTestCase {

    private let untitled = """
    # Meeting transcript — August 10, 2026 at 9:17 AM

    **[09:17:52] You:** Обсудим релиз.

    """

    func testUntitledTranscriptHasNoTitle() {
        XCTAssertNil(MeetingArchive.parseTitle(markdown: untitled))
    }

    func testTitlingKeepsTheDateAndTheEntries() {
        let titled = MeetingArchive.applying(title: "Планы по релизу",
                                             dateLine: "August 10, 2026 at 9:17 AM",
                                             to: untitled)
        XCTAssertEqual(MeetingArchive.parseTitle(markdown: titled), "Планы по релизу")
        XCTAssertTrue(titled.contains("_August 10, 2026 at 9:17 AM_"))
        XCTAssertEqual(MeetingArchive.parse(markdown: titled, youLabel: "You").count, 1)
    }

    func testRetitlingReplacesRatherThanStacks() {
        let once = MeetingArchive.applying(title: "Первый", dateLine: "D", to: untitled)
        let twice = MeetingArchive.applying(title: "Второй", dateLine: "D", to: once)
        XCTAssertEqual(MeetingArchive.parseTitle(markdown: twice), "Второй")
        XCTAssertFalse(twice.contains("Первый"))
        XCTAssertEqual(twice.components(separatedBy: "_D_").count - 1, 1)
    }
}

/// Titled transcripts get titled FILES, with the date still in front so the
/// folder sorts chronologically in Finder.
final class MeetingFileNameTests: XCTestCase {

    func testUntitledKeepsThePlainStamp() {
        XCTAssertEqual(MeetingArchive.fileName(stamp: "2026-08-10 09.17", title: nil),
                       "2026-08-10 09.17.md")
    }

    func testTitleFollowsTheDate() {
        XCTAssertEqual(MeetingArchive.fileName(stamp: "2026-08-10 09.17", title: "Release planning"),
                       "2026-08-10 09.17 — Release planning.md")
    }

    func testPathCharactersAreReplacedNotDropped() {
        let name = MeetingArchive.fileName(stamp: "2026-08-10 09.17", title: "Q3/Q4: plans")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.dropLast(3).contains(":"))
        XCTAssertTrue(name.contains("Q3-Q4"))
    }

    func testOverlongTitleIsTrimmed() {
        let long = String(repeating: "слово ", count: 40)
        let name = MeetingArchive.fileName(stamp: "2026-08-10 09.17", title: long)
        XCTAssertLessThanOrEqual(name.count, 60 + "2026-08-10 09.17 — .md".count)
    }

    func testEmptyishTitleFallsBackToTheStamp() {
        XCTAssertEqual(MeetingArchive.fileName(stamp: "2026-08-10 09.17", title: "  ..  "),
                       "2026-08-10 09.17.md")
    }

    /// The file name is the authoritative record of WHEN a meeting happened:
    /// saving a title rewrites the file atomically, which resets the
    /// creation date — it once made every transcript claim it was recorded
    /// the minute it was retitled (caught live 2026-08-10).
    func testStartedDateComesFromTheName() {
        let date = MeetingArchive.startedDate(fileName: "2026-08-10 09.17 — Release planning.md")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        XCTAssertEqual(date.map { f.string(from: $0) }, "2026-08-10 09.17")
    }

    func testLegacyMeetingPrefixStillParses() {
        let date = MeetingArchive.startedDate(fileName: "Meeting 2026-08-09 13.56.md")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        XCTAssertEqual(date.map { f.string(from: $0) }, "2026-08-09 13.56")
    }

    func testAForeignNameHasNoDate() {
        XCTAssertNil(MeetingArchive.startedDate(fileName: "notes.md"))
    }

    func testCollisionsGetASuffix() {
        let taken: Set<String> = ["2026-08-10 09.17 — Standup.md",
                                  "2026-08-10 09.17 — Standup 2.md"]
        XCTAssertEqual(MeetingArchive.uniqueName("2026-08-10 09.17 — Standup.md") { taken.contains($0) },
                       "2026-08-10 09.17 — Standup 3.md")
    }

    func testFreeNameIsUsedAsIs() {
        XCTAssertEqual(MeetingArchive.uniqueName("a.md") { _ in false }, "a.md")
    }
}

/// The model answers in free text; the sidebar needs a label.
final class TitleSanitizingTests: XCTestCase {

    func testStripsQuotesAndTrailingPeriod() {
        XCTAssertEqual(MeetingTitler.sanitize("\"Release planning.\""), "Release planning")
    }

    func testDropsAModelPreamble() {
        XCTAssertEqual(MeetingTitler.sanitize("Title: Weekly sync"), "Weekly sync")
    }

    func testKeepsOnlyTheFirstLine() {
        XCTAssertEqual(MeetingTitler.sanitize("Weekly sync\nThis meeting was about…"),
                       "Weekly sync")
    }

    func testTrimsAnOverlongTitle() {
        let long = "one two three four five six seven eight nine ten"
        XCTAssertEqual(MeetingTitler.sanitize(long)?.split(separator: " ").count, 7)
    }

    func testRejectsEmptyOrTokenOutput() {
        XCTAssertNil(MeetingTitler.sanitize("   "))
        XCTAssertNil(MeetingTitler.sanitize("\"\""))
        XCTAssertNil(MeetingTitler.sanitize("ok"))     // too short to be a title
    }

    func testStripsAModelAnnouncement() {
        XCTAssertEqual(MeetingTitler.sanitize("Meeting Title: Technical issue resolution"),
                       "Technical issue resolution")
        // Seen live while retitling the existing meetings (2026-08-10).
        XCTAssertEqual(MeetingTitler.sanitize("Meeting Transcript: New System Implementation"),
                       "New System Implementation")
    }

    func testARealTitleKeepsItsColon() {
        XCTAssertEqual(MeetingTitler.sanitize("Q3: plans and risks"), "Q3: plans and risks")
    }

    func testExcerptStaysWithinTheLimit() {
        let entries = (0..<200).map {
            TranscriptEntry(time: "09:00:00", speaker: "You", text: "фраза номер \($0)", isYou: true)
        }
        XCTAssertLessThanOrEqual(MeetingTitler.excerpt(from: entries).count,
                                 MeetingTitler.excerptLimit)
    }

    /// The excerpt must represent the WHOLE meeting: reading only the opening
    /// titled a work call "Aunt won't be there" (field run 2026-08-10).
    func testExcerptSpansTheWholeMeeting() {
        let entries = (0..<200).map {
            TranscriptEntry(time: "09:00:00", speaker: "You",
                            text: String(repeating: "слово ", count: 10) + "\($0)", isYou: true)
        }
        let text = MeetingTitler.excerpt(from: entries)
        XCTAssertTrue(text.contains(" 0"))            // the opening is kept
        // …and something from the last third made it in as well.
        let tailReached = (140..<200).contains { text.contains(" \($0)") }
        XCTAssertTrue(tailReached)
    }

    func testShortMeetingIsQuotedWhole() {
        let entries = [TranscriptEntry(time: "09:00:00", speaker: "You", text: "привет", isYou: true),
                       TranscriptEntry(time: "09:00:05", speaker: "Speaker 1", text: "и тебе", isYou: false)]
        // The owner's turn arrives under the model-facing label, not the word
        // the transcript shows a reader — see MeetingTitler.ownerLabel.
        XCTAssertEqual(MeetingTitler.excerpt(from: entries),
                       "\(MeetingTitler.ownerLabel): привет\nSpeaker 1: и тебе")
    }

    /// Russian is not one of the model's languages — it must be routed
    /// through translation instead of being handed over raw.
    func testUnsupportedLanguageIsRouted() {
        XCTAssertTrue(MeetingTitler.needsTranslation(language: "ru"))
        XCTAssertFalse(MeetingTitler.needsTranslation(language: "en"))
        XCTAssertFalse(MeetingTitler.needsTranslation(language: "de"))
        XCTAssertFalse(MeetingTitler.needsTranslation(language: nil))   // unknown: let it try
    }

    func testDominantLanguageIsDetected() {
        XCTAssertEqual(MeetingTitler.dominantLanguage(of: "Давайте обсудим релиз и планы на неделю"), "ru")
        XCTAssertEqual(MeetingTitler.dominantLanguage(of: "Let us discuss the release plan"), "en")
    }
}

/// The summary is a sentence rather than a label, and it is written into the
/// file as a single line above the first entry — so its cleaner has two jobs
/// the title's does not: keep it on one line, and keep it off the three
/// prefixes that mean something else in our own format.
final class SummarySanitizingTests: XCTestCase {

    private let good = "Slips to March; the lease runs out in February"

    func testAGoodFragmentIsLeftAlone() {
        XCTAssertEqual(MeetingTitler.sanitizeSummary(good), good)
    }

    /// A subject line, not prose — the full stop the model likes to add goes.
    func testATrailingFullStopIsDropped() {
        XCTAssertEqual(MeetingTitler.sanitizeSummary("Needs a second shift to hit March volumes."),
                       "Needs a second shift to hit March volumes")
    }

    func testEverythingCollapsesToOneLine() {
        let cleaned = MeetingTitler.sanitizeSummary("Slips to March;\nthe lease runs out in February")
        XCTAssertEqual(cleaned, good)
        XCTAssertFalse(cleaned?.contains("\n") ?? true)
    }

    func testStripsAModelAnnouncement() {
        XCTAssertEqual(MeetingTitler.sanitizeSummary("Summary: \(good)"), good)
    }

    /// The line must never start with `#`, `_` or `**[` — the file's own
    /// prefixes for a heading, the date and an entry.
    func testNeverStartsWithAFormatPrefix() {
        for noise in ["**\(good)**", "_\(good)_", "# \(good)", "\"\(good)\""] {
            let cleaned = MeetingTitler.sanitizeSummary(noise)
            XCTAssertNotNil(cleaned)
            XCTAssertFalse(cleaned!.hasPrefix("#"))
            XCTAssertFalse(cleaned!.hasPrefix("_"))
            XCTAssertFalse(cleaned!.hasPrefix("*"))
        }
    }

    /// "The meeting focused on…" is the filler this feature exists to avoid:
    /// the prompt asks for the subject and mostly gets it, and this is the net
    /// for the line in eight that still reports an event.
    func testDropsAReportingOpening() {
        XCTAssertEqual(
            MeetingTitler.sanitizeSummary("The meeting focused on the progress of the release."),
            "The progress of the release")
        XCTAssertEqual(
            MeetingTitler.sanitizeSummary("Participants discussed which supplier to keep this year."),
            "Which supplier to keep this year")
        // Seen live in the backfill of the owner's own archive (2026-08-13).
        XCTAssertEqual(
            MeetingTitler.sanitizeSummary("Discussed UI functionality and feedback, and the accuracy of it."),
            "UI functionality and feedback, and the accuracy of it")
    }

    func testARealSubjectKeepsItsOpening() {
        XCTAssertEqual(MeetingTitler.sanitizeSummary("The release slipped a week, and here is why"),
                       "The release slipped a week, and here is why")
    }

    /// The ceiling itself, asserted once so a change to it is a decision
    /// rather than an accident. 90 while the summary lived only in a sidebar
    /// row; 240 once the transcript opened on it; 320 after measuring the
    /// archive — median 131, and the only three summaries being cut all sat at
    /// 238–239, one clause short of finishing.
    func testTheDefaultCeilingOnlyCatchesARunaway() {
        // 800: above anything the model has produced (316 is the record) and
        // below a generation that has gone wrong. It should never fire on a
        // real summary — see the measurements in sanitizeSummary's comment.
        let runaway = String(repeating: "a", count: 2000)
        XCTAssertLessThanOrEqual(MeetingTitler.sanitizeSummary(runaway)?.count ?? 0, 801)
        XCTAssertGreaterThan(MeetingTitler.sanitizeSummary(runaway)?.count ?? 0, 700)
        // A real one passes through untouched.
        let real = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(MeetingTitler.sanitizeSummary(real), real)
    }

    /// Given a ceiling, an overlong summary prefers to end where the model
    /// ended a sentence — the behaviour, tested independently of what the
    /// ceiling happens to be.
    func testAnOverlongSummaryEndsOnASentence() {
        let long = "Notarization fails on the CI box. The certificate also expired last " +
                   "week and nothing can ship until somebody renews it."
        let cleaned = MeetingTitler.sanitizeSummary(long, maxCharacters: 90)
        XCTAssertNotNil(cleaned)
        XCTAssertLessThanOrEqual(cleaned!.count, 90)
        XCTAssertEqual(cleaned, "Notarization fails on the CI box")
    }

    /// One runaway fragment has no full stop to end on — it ends on a word,
    /// and says so.
    func testAnOverlongSingleSentenceIsCutOnAWord() {
        let long = String(repeating: "warehouse lease renewal ", count: 20)
        let cleaned = MeetingTitler.sanitizeSummary(long, maxCharacters: 90)
        XCTAssertNotNil(cleaned)
        XCTAssertLessThanOrEqual(cleaned!.count, 91)
        XCTAssertTrue(cleaned!.hasSuffix("…"))
        XCTAssertFalse(cleaned!.contains("warehous…"))
    }

    /// A summary that fits is left exactly as the model wrote it — the case
    /// the raised ceiling exists for.
    func testATwoSentenceSummaryNowSurvivesWhole() {
        let real = "Notarization fails on the CI box. The certificate expired last week " +
                   "and nothing ships until somebody renews it"
        XCTAssertEqual(MeetingTitler.sanitizeSummary(real), real)
    }

    /// A line too short to say anything is worse than an empty line — the row
    /// simply shows nothing.
    func testRejectsNothingMuch() {
        XCTAssertNil(MeetingTitler.sanitizeSummary("   "))
        XCTAssertNil(MeetingTitler.sanitizeSummary("Blockchain call"))   // seen live
        XCTAssertNil(MeetingTitler.sanitizeSummary("\"\""))
    }
}

/// The summary sits one line under the title, so it has to say something the
/// title does not. One that only repeats it spends two lines on one fact — and
/// the row is better off showing nothing at all.
final class SummaryRestatementTests: XCTestCase {

    /// Both measured in the owner's own archive, 2026-08-13.
    func testAnEchoOfTheTitleIsRejected() {
        XCTAssertTrue(MeetingTitler.restates(title: "Log writing process",
                                             summary: "Log writing process"))
        XCTAssertTrue(MeetingTitler.restates(title: "UI transcription issues",
                                             summary: "UI transcription issues"))
    }

    /// Case and punctuation must not be enough to smuggle a repeat past.
    func testPunctuationAndCaseDoNotDisguiseIt() {
        XCTAssertTrue(MeetingTitler.restates(title: "Phone system setup",
                                             summary: "phone system setup, completed"))
        XCTAssertTrue(MeetingTitler.restates(title: "System testing",
                                             summary: "System testing!"))
    }

    /// A line that adds substance keeps its place, even when it repeats a word
    /// or two of the title — which a real one usually does.
    func testALineThatAddsSomethingSurvives() {
        XCTAssertFalse(MeetingTitler.restates(
            title: "Shannon demo",
            summary: "Shannon wants to show the demo to Rus, but it is unclear without context"))
        XCTAssertFalse(MeetingTitler.restates(
            title: "Warehouse move",
            summary: "Slips to March; the lease runs out in February"))
    }
}

/// Renaming a voice must touch the LABEL only — never the words somebody
/// spoke, even when they said the speaker's name out loud.
final class SpeakerRenameTests: XCTestCase {

    func testRenamesEveryLabelOfThatVoice() {
        let text = """
        **[09:18:26] Speaker 1:** Привет.

        **[09:19:00] Speaker 1:** И ещё раз.

        """
        let renamed = MeetingArchive.renaming(markdown: text, from: "Speaker 1", to: "Anna")
        XCTAssertEqual(renamed.components(separatedBy: "Anna:**").count - 1, 2)
        XCTAssertFalse(renamed.contains("Speaker 1"))
    }

    func testSpokenWordsAreNeverTouched() {
        // The transcript quotes the label inside the speech itself.
        let text = "**[09:18:26] Speaker 2:** Speaker 1 said it first.\n"
        let renamed = MeetingArchive.renaming(markdown: text, from: "Speaker 1", to: "Anna")
        XCTAssertTrue(renamed.contains("Speaker 1 said it first."))
        XCTAssertTrue(renamed.contains("] Speaker 2:**"))
    }

    func testOtherVoicesKeepTheirLabels() {
        let text = "**[09:18:26] You:** hi\n\n**[09:18:30] Speaker 1:** hello\n"
        let renamed = MeetingArchive.renaming(markdown: text, from: "Speaker 1", to: "Anna")
        XCTAssertTrue(renamed.contains("] You:**"))
        XCTAssertTrue(renamed.contains("] Anna:**"))
    }
}
