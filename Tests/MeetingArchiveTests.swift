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
        XCTAssertEqual(MeetingTitler.excerpt(from: entries), "You: привет\nSpeaker 1: и тебе")
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
