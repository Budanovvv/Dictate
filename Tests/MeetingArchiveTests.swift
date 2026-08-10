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
