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

    /// Drive a full dictation to its hide, re-press during the fade, and assert
    /// the freshly shown Recording pill survives the stale hide completion.
    func testRapidRepressKeepsRecordingPillOnScreen() {
        let hud = RecordingHUD()

        // Dictation 1 runs to a successful result. showResult() with mode
        // == .transcribing schedules a hide 0.55 s out; the fade (0.18 s)
        // therefore completes at roughly t = 0.73 s.
        hud.showRecording()
        hud.showTranscribing()
        hud.showResult(success: true)
        XCTAssertTrue(hud.pillIsOnScreen, "pill should be on screen while showing the result")

        // Re-press mid-fade (t ≈ 0.60 s): the hide has begun but its completion
        // hasn't fired yet. showRecording() must claim the pill.
        let repressed = expectation(description: "re-press during fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) {
            hud.showRecording()
            repressed.fulfill()
        }
        wait(for: [repressed], timeout: 2)

        // Let the stale hide completion (t ≈ 0.73 s) fire, plus margin.
        let settled = expectation(description: "stale completion has fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { settled.fulfill() }
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
