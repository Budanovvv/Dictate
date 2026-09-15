import XCTest

/// A report field read as blocks: the model's "- " items, the markers
/// vendors improvise, and plain paragraphs — the same reading on the card,
/// in the exports and in the PDF.
final class ReportTextTests: XCTestCase {
    func testDashItemsBecomeOneList() {
        let blocks = ReportText.blocks("- Ship the export before March\n- Dana sends the quote Friday")
        XCTAssertEqual(blocks, [.list(["Ship the export before March", "Dana sends the quote Friday"])])
    }

    func testImprovisedMarkersAreItemsToo() {
        let blocks = ReportText.blocks("• first\n* second\n– third\n1. fourth\n2) fifth")
        XCTAssertEqual(blocks, [.list(["first", "second", "third", "fourth", "fifth"])])
    }

    func testParagraphsStayParagraphsAndBreakLists() {
        let blocks = ReportText.blocks("Renewal is a yes.\n\n- one\n- two\nThe quote follows Friday.")
        XCTAssertEqual(blocks, [.paragraph("Renewal is a yes."),
                                .list(["one", "two"]),
                                .paragraph("The quote follows Friday.")])
    }

    func testADashInsideASentenceIsNotAMarker() {
        XCTAssertEqual(ReportText.blocks("Tom asked — twice — about the price."),
                       [.paragraph("Tom asked — twice — about the price.")])
        XCTAssertNil(ReportText.listItem("2024 was the year"))
        XCTAssertNil(ReportText.listItem("- "))
    }

    func testExportsNormalizeMarkers() {
        let text = "• one\n* two"
        XCTAssertEqual(ReportText.markdown(text), "- one\n- two")
        XCTAssertEqual(ReportText.plain(text), "• one\n• two")
        XCTAssertEqual(ReportText.markdown("Just prose."), "Just prose.")
    }
}
