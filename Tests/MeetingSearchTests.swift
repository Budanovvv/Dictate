import XCTest

/// Searching the archive: one literal search — turns, speakers, titles,
/// summaries and outline lines — plus the #tag filter grammar.
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


    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).md") }

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

    // MARK: - The widened literal reach (the semantic ranking's replacement)

    func testLiteralFindsTitleWords() {
        let archive = [
            meeting("a", title: "Release planning", summary: nil),
            meeting("b", title: "Pharma diet", summary: nil),
        ]
        XCTAssertEqual(MeetingSearch.literal(archive, query: "planning").map(\.title),
                       ["Release planning"])
    }

    func testLiteralFindsSummaryWords() {
        let archive = [
            meeting("a", title: nil, summary: "Договорились о цене и сроках"),
            meeting("b", title: nil, summary: "Nothing was decided"),
        ]
        XCTAssertEqual(MeetingSearch.literal(archive, query: "сроках").count, 1)
    }

    func testLiteralFindsOutlineLines() {
        let archive = [
            meeting("a", title: nil, summary: nil,
                    sections: [TranscriptSection(time: "10:00:00",
                                                 line: "The freeze moves to September")]),
            meeting("b", title: nil, summary: nil),
        ]
        XCTAssertEqual(MeetingSearch.literal(archive, query: "freeze").count, 1)
    }
}
