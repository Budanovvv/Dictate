import XCTest

/// Regression test for the "Recording pill doesn't appear on a rapid re-press"
/// bug. After a dictation finishes, showResult() schedules a hide; the hide's
/// fade runs an animation whose completion orders the panel off screen. If the
/// user presses again mid-fade, showRecording() brings a fresh pill up — but
/// the STALE completion from the previous hide used to order it right back out
/// (logs showed the Recording pill flashing for ~8 ms, then "hidden (ordered
/// out)"). The old guard read panel.alphaValue, which is unreliable and never
/// fired. The fix is the wantsVisible intent flag.
@MainActor
final class RecordingHUDTests: XCTestCase {

    /// Start a hide and re-press synchronously, before its fade completion can
    /// possibly have fired — deterministic (no timing window to hit, unlike the
    /// original version that raced two asyncAfter deadlines on a loaded machine).
    /// The stale completion then fires ~0.18 s later and must not order the
    /// freshly shown pill out.
    func testRapidRepressKeepsRecordingPillOnScreen() {
        let hud = RecordingHUD()

        hud.showRecording()
        hud.showTranscribing()
        hud.showResult(success: true)
        XCTAssertTrue(hud.pillIsOnScreen, "pill should be on screen while showing the result")

        // Force the hide now and re-press immediately: the fade (0.18 s) is in
        // flight, its completion is guaranteed still pending.
        hud.hide()
        hud.showRecording()

        // Let the stale hide completion fire, plus margin.
        let settled = expectation(description: "stale completion has fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(hud.pillIsOnScreen,
                      "a stale hide completion ordered the freshly shown Recording pill off screen")
    }

    /// The plain case still hides: with no re-press, the pill really does go away.
    func testHideActuallyHidesWhenNotRepressed() {
        let hud = RecordingHUD()
        hud.showRecording()
        XCTAssertTrue(hud.pillIsOnScreen)

        hud.hide()
        let settled = expectation(description: "fade completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertFalse(hud.pillIsOnScreen, "an un-interrupted hide must order the pill out")
    }
}
