import XCTest

/// GRABLI: naming the app that holds the mic. Helper processes buried inside
/// an app bundle (ChatGPT voice runs in "Codex (Service)") aren't
/// NSRunningApplications and expose no bundle ID through the HAL — the
/// executable path is the only lead, and it must resolve to the OUTER,
/// user-facing bundle, never to the nested helper.
final class HelperAppNameTests: XCTestCase {

    func testChatGPTHelperResolvesToChatGPT() {
        let path = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/"
            + "Versions/150.0.7871.182/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)"
        XCTAssertEqual(AudioInputDevices.appBundleName(fromPath: path), "ChatGPT")
    }

    func testChromeHelperResolvesToGoogleChrome() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/"
            + "Google Chrome Framework.framework/Versions/150.0.7871.187/Helpers/"
            + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        XCTAssertEqual(AudioInputDevices.appBundleName(fromPath: path), "Google Chrome")
    }

    /// System daemons (corespeechd listens for "Hey Siri") must stay unnamed —
    /// "Microphone busy: corespeechd" would be noise, not help.
    func testSystemDaemonHasNoAppName() {
        let path = "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd"
        XCTAssertNil(AudioInputDevices.appBundleName(fromPath: path))
    }

    func testFrameworkXPCServiceHasNoAppName() {
        let path = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
            + "com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        XCTAssertNil(AudioInputDevices.appBundleName(fromPath: path))
    }
}

/// GRABLI: App Translocation — launched straight from the DMG/Downloads, the
/// process runs from a random read-only path and TCC grants never stick; the
/// onboarding warns up front. The marker must catch the translocated path and
/// must NOT fire for normal installs or dev builds (a false positive would put
/// a scary warning on every launch).
final class TranslocationDetectionTests: XCTestCase {

    func testTranslocatedPathDetected() {
        let path = "/private/var/folders/yr/wgjnrg153mx/T/AppTranslocation/"
            + "8B0C2A5E-3F71-4B6A-9E2D-1C4A5B6D7E8F/d/Dictate.app"
        XCTAssertTrue(DictationPolicy.isTranslocatedPath(path))
    }

    func testApplicationsInstallIsClean() {
        XCTAssertFalse(DictationPolicy.isTranslocatedPath("/Applications/Dictate.app"))
    }

    func testDevBuildIsClean() {
        let path = NSHomeDirectory()
            + "/Library/Caches/DictateBuild/Build/Products/Release/Dictate.app"
        XCTAssertFalse(DictationPolicy.isTranslocatedPath(path))
    }
}
