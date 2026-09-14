import XCTest

/// The report block: written into the meeting's file, read back, and left
/// alone by every other parser the file has.
final class MeetingReportTests: XCTestCase {

    private let sample = """
    # Northwind — renewal call
    _14 September 2026 at 14:02_
    <!-- source: Zoom -->

    Northwind will renew if the per-seat price holds.

    ## Contents

    - **[10:26:17]** Where the renewal stands
    - **[10:38:40]** The CRM export

    **[10:26:17] Priya:** the renewal is fine if the per-seat price holds
    **[10:38:40] You:** let me walk you through the export
    """

    private func report(_ answers: [(String, String)]) -> MeetingReport {
        MeetingReport(templateID: UUID(uuidString: "3F2B4C6D-0000-4000-8000-000000000001"),
                      templateName: "Sales call", writer: "Claude",
                      written: Date(timeIntervalSince1970: 1_800_000_000),
                      answers: answers.map { .init(field: $0.0, text: $0.1) })
    }

    func testRoundTrip() {
        let written = report([("Client profile", "Priya Nair, Head of Operations."),
                              ("Objections", ""),
                              ("Next steps", "Dana sends the quote Friday.\n\nYou confirm the timeline.")])
        let text = MeetingArchive.applying(report: written, heading: "Report", to: sample)
        let read = MeetingArchive.parseReport(markdown: text)
        XCTAssertEqual(read, written)
        XCTAssertTrue(read?.answers[1].isEmpty ?? false, "an empty answer is 'not discussed'")
    }

    func testBlockSitsBetweenSummaryAndContents() {
        let text = MeetingArchive.applying(report: report([("Objections", "None.")]),
                                           heading: "Report", to: sample)
        let summary = text.range(of: "Northwind will renew")!.lowerBound
        let block = text.range(of: MeetingArchive.reportMarkerPrefix)!.lowerBound
        let contents = text.range(of: "## Contents")!.lowerBound
        XCTAssertLessThan(summary, block)
        XCTAssertLessThan(block, contents)
    }

    func testOtherParsersIgnoreTheBlock() {
        let text = MeetingArchive.applying(
            report: report([("Client profile", "Priya Nair."), ("Next steps", "Friday.")]),
            heading: "Report", to: sample)
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: text),
                       "Northwind will renew if the per-seat price holds.")
        XCTAssertEqual(MeetingArchive.parseSections(markdown: text).count, 2)
        XCTAssertEqual(MeetingArchive.parse(markdown: text, youLabel: "You").count, 2)
        XCTAssertEqual(MeetingArchive.parseTitle(markdown: text), "Northwind — renewal call")
    }

    func testReplacingKeepsOneBlock() {
        let first = MeetingArchive.applying(report: report([("A", "one")]), heading: "Report", to: sample)
        let second = MeetingArchive.applying(report: report([("B", "two")]), heading: "Report", to: first)
        XCTAssertEqual(second.components(separatedBy: MeetingArchive.reportMarkerPrefix).count - 1, 1)
        XCTAssertEqual(MeetingArchive.parseReport(markdown: second)?.answers.first?.field, "B")
    }

    func testRemoving() {
        let with = MeetingArchive.applying(report: report([("A", "one")]), heading: "Report", to: sample)
        let without = MeetingArchive.removingReport(from: with)
        XCTAssertNil(MeetingArchive.parseReport(markdown: without))
        XCTAssertEqual(MeetingArchive.parseSections(markdown: without).count, 2)
        XCTAssertFalse(without.contains("\n\n\n"), "no triple blank left behind")
    }

    func testContentsWrittenAfterReportStaysBelowIt() {
        // A report on a meeting that has no contents block yet; the
        // sections backfill then writes one — it must land after the report,
        // not inside it.
        let bare = sample.replacingOccurrences(
            of: "## Contents\n\n- **[10:26:17]** Where the renewal stands\n- **[10:38:40]** The CRM export\n\n",
            with: "")
        let reported = MeetingArchive.applying(report: report([("A", "one")]), heading: "Report", to: bare)
        let sections = [TranscriptSection(time: "10:26:17", line: "Where the renewal stands")]
        let both = MeetingArchive.applying(sections: sections, heading: "Contents", to: reported)
        let block = both.range(of: MeetingArchive.reportMarkerPrefix)!.lowerBound
        let contents = both.range(of: "## Contents")!.lowerBound
        XCTAssertLessThan(block, contents)
        XCTAssertEqual(MeetingArchive.parseReport(markdown: both)?.answers.first?.text, "one")
    }

    func testOneReportPerTemplateCoexist() {
        let summary = MeetingReport(templateID: UUID(), templateName: "Meeting summary", writer: "Claude",
                                    written: nil, answers: [.init(field: "Purpose", text: "why")])
        let actions = MeetingReport(templateID: UUID(), templateName: "Decisions & actions", writer: "ChatGPT",
                                    written: nil, answers: [.init(field: "Decisions", text: "yes")])
        let one = MeetingArchive.applying(report: summary, heading: "Report", to: sample)
        let two = MeetingArchive.applying(report: actions, heading: "Report", to: one)
        let read = MeetingArchive.parseReports(markdown: two)
        XCTAssertEqual(read.map(\.templateName), ["Meeting summary", "Decisions & actions"])
        XCTAssertEqual(read.map(\.answers.first?.text), ["why", "yes"])
        // The other parsers still see one summary, two sections, two entries.
        XCTAssertEqual(MeetingArchive.parseSections(markdown: two).count, 2)
        XCTAssertEqual(MeetingArchive.parse(markdown: two, youLabel: "You").count, 2)
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: two), "Northwind will renew if the per-seat price holds.")
        // Both sit before the contents block.
        let contents = two.range(of: "## Contents")!.lowerBound
        XCTAssertLessThan(two.range(of: "Decisions & actions")!.lowerBound, contents)
    }

    func testSameTemplateReplacesOnlyItself() {
        let id = UUID()
        let first = MeetingReport(templateID: id, templateName: "Meeting summary", writer: "Claude",
                                  written: nil, answers: [.init(field: "Purpose", text: "old")])
        let other = MeetingReport(templateID: UUID(), templateName: "Decisions & actions", writer: "Claude",
                                  written: nil, answers: [.init(field: "Decisions", text: "keep")])
        let again = MeetingReport(templateID: id, templateName: "Meeting summary", writer: "ChatGPT",
                                  written: nil, answers: [.init(field: "Purpose", text: "new")])
        var text = MeetingArchive.applying(report: first, heading: "Report", to: sample)
        text = MeetingArchive.applying(report: other, heading: "Report", to: text)
        text = MeetingArchive.applying(report: again, heading: "Report", to: text)
        let read = MeetingArchive.parseReports(markdown: text)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.first { $0.templateID == id }?.answers.first?.text, "new")
        XCTAssertEqual(read.first { $0.templateName == "Decisions & actions" }?.answers.first?.text, "keep")
        XCTAssertEqual(text.components(separatedBy: MeetingArchive.reportMarkerPrefix).count - 1, 2)
    }

    func testRemovingOneTemplateKeepsTheOther() {
        let id = UUID()
        let a = MeetingReport(templateID: id, templateName: "A", writer: "Claude", written: nil,
                              answers: [.init(field: "F", text: "a")])
        let b = MeetingReport(templateID: UUID(), templateName: "B", writer: "Claude", written: nil,
                              answers: [.init(field: "F", text: "b")])
        let both = MeetingArchive.applying(report: b, heading: "Report",
                                           to: MeetingArchive.applying(report: a, heading: "Report", to: sample))
        let without = MeetingArchive.removingReport(from: both, templateID: id)
        XCTAssertEqual(MeetingArchive.parseReports(markdown: without).map(\.templateName), ["B"])
        XCTAssertTrue(MeetingArchive.parseReports(markdown: MeetingArchive.removingReport(from: both)).isEmpty)
    }

    func testModelTextIsMadeSafe() {
        let cleaned = MeetingArchive.cleanReportText("## Heading\n\n\n**[10:00:00] Bob:** said\n- **[10:01:00]** bullet")
        XCTAssertFalse(cleaned.contains("#"))
        XCTAssertFalse(cleaned.contains("**["))
        XCTAssertFalse(cleaned.contains("\n\n\n"))
    }

    func testMarkerSurvivesAnOddTemplateName() {
        let odd = MeetingReport(templateID: nil, templateName: "A | B --> C", writer: "ChatGPT",
                                written: nil, answers: [.init(field: "F", text: "t")])
        let text = MeetingArchive.applying(report: odd, heading: "Report", to: sample)
        let read = MeetingArchive.parseReport(markdown: text)
        XCTAssertEqual(read?.templateName, "A | B —> C")
        XCTAssertNil(read?.templateID)
        XCTAssertEqual(read?.writer, "ChatGPT")
    }
}

/// The form the model fills: positional keys, every field required, the
/// answers back in field order.
final class ReportRequestTests: XCTestCase {

    private var request: ReportRequest {
        ReportRequest(instructions: "i", transcript: "t", fields: [
            ReportField(name: "Client profile", instruction: "Who they are"),
            ReportField(name: "Objections"),
        ])
    }

    func testSchemaKeysArePositional() {
        let schema = request.schema(strict: true)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertEqual(Set(properties?.keys.map { $0 } ?? []), ["field_1", "field_2"])
        XCTAssertEqual(schema["required"] as? [String], ["field_1", "field_2"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertNil(request.schema(strict: false)["additionalProperties"])
        let first = properties?["field_1"] as? [String: Any]
        XCTAssertTrue((first?["description"] as? String)?.contains("Who they are") ?? false)
    }

    func testAnswersComeBackInOrderAndMissingIsEmpty() {
        let answers = request.answers(from: ["field_2": "  none  ", "field_9": "x"])
        XCTAssertEqual(answers, ["", "none"])
    }

    func testUsableFields() {
        let template = ReportTemplate(name: "T", fields: [ReportField(name: " "), ReportField(name: "A")])
        XCTAssertEqual(template.usableFields.map(\.name), ["A"])
        XCTAssertTrue(template.isUsable)
        XCTAssertFalse(ReportTemplate(name: "T", fields: [ReportField(name: "")]).isUsable)
    }
}
