import XCTest

/// The vocabulary's defences. Every test here exists because a tag system that
/// lets the same idea be written two ways stops answering questions within a
/// month — the documented way this class of feature dies.
final class MeetingTagsTests: XCTestCase {

    func testTheSameIdeaCannotForkOnCaseOrSpacing() {
        // The single highest-value rule: "Acme Corp", "acme corp" and
        // "ACME-Corp" must be one tag, without the user thinking about it.
        for written in ["Acme Corp", "acme corp", "ACME-Corp", "  acme   corp  ", "#Acme_Corp"] {
            XCTAssertEqual(MeetingTags.normalize(written), "acme-corp", written)
        }
    }

    func testPunctuationNeverEntersTheVocabulary() {
        XCTAssertEqual(MeetingTags.normalize("acme, corp."), "acme-corp")
        XCTAssertEqual(MeetingTags.normalize("«продукт»"), "продукт")
        XCTAssertNil(MeetingTags.normalize("!!!"))
        XCTAssertNil(MeetingTags.normalize("   "))
    }

    func testDepthThroughSlashSurvives() {
        // #product/agent is how note systems get hierarchy for free.
        XCTAssertEqual(MeetingTags.normalize("Product/Agent"), "product/agent")
    }

    func testNonLatinTagsAreKept() {
        XCTAssertEqual(MeetingTags.normalize("Клиенты"), "клиенты")
    }

    // MARK: - Reading a transcript

    private let header = """
    # Product daily
    _August 25, 2026 at 10:00 AM_

    #wholecall #product

    A summary of what happened.

    **[10:00:00] You:** Hello.
    """

    func testTagsAreReadFromTheHeader() {
        XCTAssertEqual(MeetingTags.parse(markdown: header), ["product", "wholecall"])
    }

    func testSomethingSaidInTheMeetingIsNotATag() {
        // "#1 priority" spoken aloud must never become a tag, which is why
        // only the header is inspected AND every token must be a hashtag.
        let md = """
        # Product daily
        _August 25, 2026 at 10:00 AM_

        **[10:00:00] You:** That is our #1 priority.
        """
        XCTAssertEqual(MeetingTags.parse(markdown: md), [])
    }

    func testAContentsHeadingIsNotATagLine() {
        // "## Contents" starts with a hash and must not be mistaken for one.
        XCTAssertNil(MeetingTags.parseLine("## Contents"))
        XCTAssertNil(MeetingTags.parseLine("# Product daily"))
        XCTAssertNil(MeetingTags.parseLine("#wholecall and some prose"))
    }

    // MARK: - Writing

    func testTagsGoUnderTheDateLine() {
        let md = "# Product daily\n_August 25, 2026 at 10:00 AM_\n\nA summary.\n"
        let out = MeetingTags.applying(["Product", "wholecall"], to: md)
        let lines = out.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines[0], "# Product daily")
        XCTAssertEqual(lines[1], "_August 25, 2026 at 10:00 AM_")
        XCTAssertEqual(lines[2], "#product #wholecall")
    }

    func testWritingTwiceReplacesRatherThanAccumulates() {
        let once = MeetingTags.applying(["product"], to: header)
        let twice = MeetingTags.applying(["client"], to: once)
        XCTAssertEqual(MeetingTags.parse(markdown: twice), ["client"])
        XCTAssertEqual(twice.components(separatedBy: "#client").count - 1, 1)
    }

    func testAnEmptyListRemovesTheLine() {
        let out = MeetingTags.applying([], to: header)
        XCTAssertEqual(MeetingTags.parse(markdown: out), [])
        XCTAssertTrue(out.contains("A summary of what happened."))
        XCTAssertTrue(out.contains("**[10:00:00] You:** Hello."))
    }

    func testTheTranscriptItselfIsNeverTouched() {
        let out = MeetingTags.applying(["client"], to: header)
        XCTAssertTrue(out.contains("**[10:00:00] You:** Hello."))
        XCTAssertTrue(out.contains("A summary of what happened."))
    }

    // MARK: - The automatic tag

    func testAWorkCalendarBecomesTheCompany() {
        // The owner's own name is identical on every calendar they own and so
        // divides nothing; the organisation is the useful half.
        XCTAssertEqual(MeetingTags.fromCalendarName("valentyn@wholecall.ai"), "wholecall")
    }

    func testAPersonalMailboxGetsNoTag() {
        // "valentyn-budanov" on every personal meeting is noise, and a term
        // that never divides anything earns the vocabulary nothing.
        XCTAssertNil(MeetingTags.fromCalendarName("valentyn.budanov@gmail.com"))
        XCTAssertNil(MeetingTags.fromCalendarName("someone@icloud.com"))
    }

    func testAPlainlyNamedCalendarIsUsedAsIs() {
        XCTAssertEqual(MeetingTags.fromCalendarName("Work"), "work")
        XCTAssertEqual(MeetingTags.fromCalendarName("Семейный"), "семейный")
    }
}

/// Tags ride in the search field rather than in a pane of their own, so the
/// splitting rule is part of the vocabulary's behaviour and gets tested with it.
final class TagQueryTests: XCTestCase {

    func testATagNarrowsAndWordsSearch() {
        let q = MeetingSearch.split(query: "#wholecall pricing")
        XCTAssertEqual(q.tags, ["wholecall"])
        XCTAssertEqual(q.text, "pricing")
    }

    func testTwoTagsMeanBoth() {
        // Someone adding a second tag is asking to narrow, not to widen.
        XCTAssertEqual(MeetingSearch.split(query: "#wholecall #product").tags,
                       ["wholecall", "product"])
    }

    func testTagsAreNormalisedInQueriesToo() {
        // Otherwise "#Acme Corp" would match nothing while "#acme-corp" does.
        XCTAssertEqual(MeetingSearch.split(query: "#Acme-Corp").tags, ["acme-corp"])
    }

    func testABareHashIsJustText() {
        XCTAssertEqual(MeetingSearch.split(query: "#").tags, [])
        XCTAssertEqual(MeetingSearch.split(query: "#").text, "#")
    }

    func testPlainSearchIsUnchanged() {
        let q = MeetingSearch.split(query: "pricing discussion")
        XCTAssertTrue(q.tags.isEmpty)
        XCTAssertEqual(q.text, "pricing discussion")
    }
}
