import XCTest

/// The offers' two-mentions ceiling (design section 9; designer's Q3
/// answer): only ignored HUD cards count, an explicit decline retires
/// immediately, and a capability the person has decided about by hand is
/// never offered at all.
final class OfferLedgerTests: XCTestCase {
    var suite: UserDefaults!
    // The gate also reads the capability's own switches, which live in the
    // app's REAL defaults — saved here and restored after every test, so a
    // test run never rewires the machine it runs on.
    var savedRecord = false
    var savedNotice = false

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "OfferLedgerTests")!
        suite.removePersistentDomain(forName: "OfferLedgerTests")
        OfferLedger.defaults = suite
        savedRecord = Settings.shared.recordCallAudio
        savedNotice = Settings.shared.noticeCalls
        Settings.shared.recordCallAudio = false
    }

    override func tearDown() {
        Settings.shared.recordCallAudio = savedRecord
        Settings.shared.noticeCalls = savedNotice
        suite.removePersistentDomain(forName: "OfferLedgerTests")
        OfferLedger.defaults = .standard
        super.tearDown()
    }

    func testFreshCapabilityMayBeOffered() {
        XCTAssertTrue(OfferLedger.mayOffer(.recordCallAudio))
    }

    func testCapabilityAlreadyOnIsNeverOffered() {
        Settings.shared.recordCallAudio = true
        XCTAssertFalse(OfferLedger.mayOffer(.recordCallAudio))
    }

    func testTwoIgnoredCardsRetireTheOffer() {
        OfferLedger.shownIgnored(.recordCallAudio)
        XCTAssertTrue(OfferLedger.mayOffer(.recordCallAudio),
                      "one ignored card leaves one mention")
        OfferLedger.shownIgnored(.recordCallAudio)
        XCTAssertFalse(OfferLedger.mayOffer(.recordCallAudio),
                       "the second ignored card was the last mention")
    }

    func testDeclineRetiresImmediately() {
        OfferLedger.declined(.recordCallAudio)
        XCTAssertFalse(OfferLedger.mayOffer(.recordCallAudio))
    }

    func testHandFlippedSwitchIsDecidedEvenWhenOff() {
        // Turned off on purpose → absence only, never mentioned again.
        OfferLedger.decided(.recordCallAudio)
        XCTAssertFalse(OfferLedger.mayOffer(.recordCallAudio))
    }

    func testCapabilitiesAreLedgeredIndependently() {
        OfferLedger.declined(.recordCallAudio)
        Settings.shared.noticeCalls = false
        XCTAssertTrue(OfferLedger.mayOffer(.noticeCalls))
    }
}
