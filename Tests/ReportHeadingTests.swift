import XCTest

/// A field's heading in the report's language survives the file: the
/// heading is what the block shows, the template's own name rides along
/// so the CSV column and "already written" still find the field.
final class ReportHeadingTests: XCTestCase {
    func testHeadingRoundTripsAndFieldStays() {
        let report = MeetingReport(templateID: nil, templateName: "Sales call", writer: "Claude", written: nil,
                                   answers: [.init(field: "Decisions", text: "Ship it.", heading: "Решения"),
                                             .init(field: "Next steps", text: "Call Friday.")])
        let lines = MeetingArchive.reportBlock(report, heading: "Report")
        XCTAssert(lines.contains("### Решения <!-- field: Decisions -->"), "\(lines)")
        XCTAssert(lines.contains("### Next steps"))
        let parsed = MeetingArchive.parseReports(markdown: lines.joined(separator: "\n")).first
        XCTAssertEqual(parsed?.answers.map(\.field), ["Decisions", "Next steps"])
        XCTAssertEqual(parsed?.answers.map(\.title), ["Решения", "Next steps"])
        XCTAssertEqual(parsed?.answers.first?.heading, "Решения")
        XCTAssertNil(parsed?.answers.last?.heading)
    }

    func testAHeadingEqualToTheFieldIsNotWrittenTwice() {
        let request = ReportRequest(instructions: "", transcript: "", fields: [ReportField(name: "Decisions")],
                                    language: "Russian")
        XCTAssertEqual(request.headings(from: ["heading_1": "  "]), ["Decisions"])
        XCTAssertEqual(request.headings(from: ["heading_1": "Решения"]), ["Решения"])
        XCTAssert((request.schema(strict: true)["required"] as? [String])?.contains("heading_1") == true)
    }
}
