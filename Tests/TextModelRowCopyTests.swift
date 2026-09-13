import XCTest

/// The sentences under the meeting model's rows, one per state. The tests
/// pin the facts each sentence must carry — the size, the memory numbers,
/// what still works — rather than the exact wording, which is the
/// designer's to change.
final class TextModelRowCopyTests: XCTestCase {
    // The copy is localized; the assertions read it in English. The
    // picker's language is real app state — saved and put back.
    private var savedLanguage: AppLanguage = .system

    override func setUp() {
        super.setUp()
        savedLanguage = Localization.shared.language
        Localization.shared.setLanguage(.en)
    }

    override func tearDown() {
        Localization.shared.setLanguage(savedLanguage)
        super.tearDown()
    }

    private func hint(_ state: TextModelRowCopy.RowState, gb: Int = 8,
                      apple: AppleIntelligenceState = .on, reading: Bool = true,
                      paused: TextModelRowCopy.Pause? = nil) -> String {
        TextModelRowCopy.rowHint(state: state, memoryGB: gb, appleIntelligence: apple,
                                 readMeetings: reading, sizeText: "2.5 GB", paused: paused)
    }

    func testInstalledStatesCarryTheSize() {
        XCTAssertEqual(hint(.ready), "Installed · 2.5 GB")
        XCTAssertEqual(hint(.ready, reading: false), "Installed, not in use · 2.5 GB")
        XCTAssertTrue(hint(.absent).contains("2.5 GB"))
    }

    func testNotRunnableNamesBothNumbersAndWhatStillWorks() {
        let withApple = hint(.installedNotRunnable, gb: 8, apple: .on)
        XCTAssertTrue(withApple.contains("8 GB"), withApple)
        XCTAssertTrue(withApple.contains("16"), withApple)
        XCTAssertTrue(withApple.contains("Apple Intelligence"), withApple)

        let withoutApple = hint(.installedNotRunnable, gb: 8, apple: .notEnabled)
        XCTAssertTrue(withoutApple.contains("Nothing on this Mac reads meetings"), withoutApple)

        let readingOff = hint(.installedNotRunnable, gb: 8, reading: false)
        XCTAssertTrue(readingOff.contains("16"), readingOff)
        XCTAssertFalse(readingOff.contains("Apple Intelligence"), readingOff)
    }

    func testAPauseOutranksInstalledOnlyWhileReading() {
        XCTAssertTrue(hint(.ready, paused: .memory).contains("Paused"))
        XCTAssertTrue(hint(.ready, paused: .call).contains("call"))
        XCTAssertEqual(hint(.ready, reading: false, paused: .memory), "Installed, not in use · 2.5 GB")
    }

    func testEngineLineNamesTheReaderOrTheWayOut() {
        XCTAssertEqual(TextModelRowCopy.engineLine(status: .downloadedModel, canDownload: false),
                       "Reads with the downloaded model.")
        XCTAssertEqual(TextModelRowCopy.engineLine(status: .appleIntelligence, canDownload: false),
                       "Reads with Apple Intelligence.")
        let offered = TextModelRowCopy.engineLine(status: .none(.notEnabled), canDownload: true)
        XCTAssertTrue(offered.contains("download"), offered)
        XCTAssertTrue(offered.contains("Apple Intelligence"), offered)
        let small = TextModelRowCopy.engineLine(status: .none(.notEnabled), canDownload: false)
        XCTAssertFalse(small.contains("download"), small)
        XCTAssertTrue(small.contains("agent"), small)
        let waiting = TextModelRowCopy.engineLine(status: .none(.notReady), canDownload: false)
        XCTAssertTrue(waiting.contains("still setting up"), waiting)
    }

    func testReadingLinesExplainAnAbsence() {
        let verdict = HardwareVerdict.unavailable(reason: "needs 16, has 8", instead: "Apple reads")
        let lines = TextModelRowCopy.readingLines(status: .none(.on), verdict: verdict, sizeText: "2.5 GB")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], "needs 16, has 8")
        XCTAssertEqual(lines[2], "Apple reads")
        XCTAssertEqual(TextModelRowCopy.readingLines(status: .appleIntelligence, verdict: .available,
                                                     sizeText: "2.5 GB"),
                       ["Meeting reading: Apple Intelligence."])
        let tight = TextModelRowCopy.readingLines(status: .downloadedModel,
                                                  verdict: .availableWithCost("holds 3.9 GB"),
                                                  sizeText: "2.5 GB")
        XCTAssertEqual(tight.count, 2)
        XCTAssertEqual(tight[1], "holds 3.9 GB")
    }

    func testRemovalBodySaysWhatHappensNext() {
        XCTAssertTrue(TextModelRowCopy.removalBody(appleIntelligence: .on, readMeetings: true, sizeText: "2.5 GB")
                        .contains("Apple Intelligence"))
        XCTAssertTrue(TextModelRowCopy.removalBody(appleIntelligence: .notEnabled, readMeetings: true, sizeText: "2.5 GB")
                        .contains("date names"))
        XCTAssertTrue(TextModelRowCopy.removalBody(appleIntelligence: .on, readMeetings: false, sizeText: "2.5 GB")
                        .contains("off"))
    }

    func testRecognitionLine() {
        XCTAssertTrue(TextModelRowCopy.recognitionLine(appleSilicon: true).contains("Neural Engine"))
        XCTAssertTrue(TextModelRowCopy.recognitionLine(appleSilicon: false).contains("processor"))
    }
}
