import XCTest

/// When the onboarding may start the one-time Neural Engine compile: never
/// before the permissions are granted (it ran under the microphone dialog
/// and froze an 8 GB Mac, 2026-09-13), always on the try-it step.
final class OnboardingPolicyTests: XCTestCase {

    func testNothingBeforeThePermissionsStep() {
        for step in 0...2 {
            XCTAssertFalse(OnboardingPolicy.shouldPreload(step: step, allGranted: false), "step \(step)")
            // Even with the permissions somehow already granted (a re-run):
            // the compile waits for the step that would show the dialogs.
            XCTAssertFalse(OnboardingPolicy.shouldPreload(step: step, allGranted: true), "step \(step)")
        }
    }

    func testThePermissionsStepWaitsForTheGrants() {
        XCTAssertFalse(OnboardingPolicy.shouldPreload(step: 3, allGranted: false))
        XCTAssertTrue(OnboardingPolicy.shouldPreload(step: 3, allGranted: true))
    }

    func testTheTryItStepAlwaysPreloads() {
        XCTAssertTrue(OnboardingPolicy.shouldPreload(step: 4, allGranted: false))
        XCTAssertTrue(OnboardingPolicy.shouldPreload(step: 4, allGranted: true))
    }
}
