import XCTest

/// GRABLI, «Аудио»: another app holding the mic in a voice-processing session
/// starves our capture. Two fingerprints seen live: a non-nominal rate
/// (Meet/Zoom/Chrome — 24 kHz, zero frames, VP can't even start) and the
/// built-in mic exposing its raw multi-channel array at the nominal rate
/// (ChatGPT voice / Safari — VP join delivers audio). These tests pin the
/// detection matrix so neither variant regresses silently again.
final class BusyMicFingerprintTests: XCTestCase {

    func testMeet24kHoldIsRateForeign() {
        let fp = AudioRecorder.foreignFingerprint(reportedRate: 24000, nominalRate: 48000,
                                                  channelCount: 1, isBuiltIn: true)
        XCTAssertTrue(fp.rate)
        XCTAssertFalse(fp.rawArray)
    }

    func testRawArrayHoldAtNominalRate() {
        // The 2026-07-31 blind spot: nominal 48 kHz, but 3 raw channels.
        let fp = AudioRecorder.foreignFingerprint(reportedRate: 48000, nominalRate: 48000,
                                                  channelCount: 3, isBuiltIn: true)
        XCTAssertFalse(fp.rate)
        XCTAssertTrue(fp.rawArray)
    }

    /// Multi-channel external interfaces are legitimate — flagging them busy
    /// would break every USB audio interface user.
    func testMultichannelUSBInterfaceIsNotForeign() {
        let fp = AudioRecorder.foreignFingerprint(reportedRate: 48000, nominalRate: 48000,
                                                  channelCount: 4, isBuiltIn: false)
        XCTAssertFalse(fp.rate)
        XCTAssertFalse(fp.rawArray)
    }

    func testHealthyBuiltInMonoIsClean() {
        let fp = AudioRecorder.foreignFingerprint(reportedRate: 48000, nominalRate: 48000,
                                                  channelCount: 1, isBuiltIn: true)
        XCTAssertFalse(fp.rate)
        XCTAssertFalse(fp.rawArray)
    }

    /// A non-nominal rate must win over the channel signal: VP join was
    /// measured dead in that state (-10875), the session path must be taken.
    func testRawArrayAtForeignRateCountsAsRateForeign() {
        let fp = AudioRecorder.foreignFingerprint(reportedRate: 24000, nominalRate: 48000,
                                                  channelCount: 3, isBuiltIn: true)
        XCTAssertTrue(fp.rate)
        XCTAssertFalse(fp.rawArray)
    }

    func testUnknownRatesNeverFlagRateForeign() {
        let fp = AudioRecorder.foreignFingerprint(reportedRate: 48000, nominalRate: 0,
                                                  channelCount: 1, isBuiltIn: true)
        XCTAssertFalse(fp.rate)
        XCTAssertFalse(fp.rawArray)
    }
}

/// Review finding 2026-08-06: the first buffer of a freshly joined VP session
/// or capture session routinely lands after the 0.4 s check — acting on the
/// first look tears down a path that was about to work. The watchdog must
/// always grant exactly one recheck, for BOTH shapes of "no audio yet".
final class BusyWatchdogVerdictTests: XCTestCase {

    func testFirstCheckNeverActs() {
        XCTAssertEqual(AudioRecorder.busyWatchdogVerdict(samplesEmpty: true, peakLevel: 0,
                                                         isRecheck: false), .recheck)
        XCTAssertEqual(AudioRecorder.busyWatchdogVerdict(samplesEmpty: false, peakLevel: 0.0004,
                                                         isRecheck: false), .recheck)
    }

    func testRecheckActsWhenStillNoAudio() {
        XCTAssertEqual(AudioRecorder.busyWatchdogVerdict(samplesEmpty: true, peakLevel: 0,
                                                         isRecheck: true), .act)
        XCTAssertEqual(AudioRecorder.busyWatchdogVerdict(samplesEmpty: false, peakLevel: 0.0004,
                                                         isRecheck: true), .act)
    }

    /// Digital zeros from a starved tap measured at peak 0.0004; live ambient
    /// through VP measured ≥0.005 — the 0.001 threshold separates them.
    func testLiveAmbientPassesDeadZerosDoNot() {
        XCTAssertEqual(AudioRecorder.busyWatchdogVerdict(samplesEmpty: false, peakLevel: 0.005,
                                                         isRecheck: false), .audioFlowing)
        XCTAssertEqual(AudioRecorder.busyWatchdogVerdict(samplesEmpty: false, peakLevel: 0.005,
                                                         isRecheck: true), .audioFlowing)
        XCTAssertEqual(AudioRecorder.busyWatchdogVerdict(samplesEmpty: false, peakLevel: 0.0004,
                                                         isRecheck: true), .act)
    }
}

/// GRABLI: a silent drop reads as "the app is broken", but the wrong loud
/// message is as bad — a dead recording under a foreign hold must say "mic
/// busy", while a quiet-but-alive voice must stay "too quiet" (energy
/// thresholds already failed on a real user's quiet voice once).
final class EmptyCaptureVerdictTests: XCTestCase {

    func testDeadForeignRecordingIsMicBusy() {
        XCTAssertEqual(DictationPolicy.emptyCaptureVerdict(peak: 0, clip: 0, foreignHeld: true),
                       .micBusy)
    }

    func testQuietButAliveForeignVoiceIsTooQuiet() {
        XCTAssertEqual(DictationPolicy.emptyCaptureVerdict(peak: 0.01, clip: 0, foreignHeld: true),
                       .tooQuiet)
    }

    func testClippingReportsTooLoud() {
        XCTAssertEqual(DictationPolicy.emptyCaptureVerdict(peak: 0.9, clip: 0.05, foreignHeld: false),
                       .tooLoud)
    }

    func testQuietVoiceReportsTooQuiet() {
        XCTAssertEqual(DictationPolicy.emptyCaptureVerdict(peak: 0.01, clip: 0, foreignHeld: false),
                       .tooQuiet)
    }

    func testAudibleButUnrecognizedIsNothingHeard() {
        XCTAssertEqual(DictationPolicy.emptyCaptureVerdict(peak: 0.05, clip: 0, foreignHeld: false),
                       .nothingHeard)
    }
}

/// GRABLI: zero-byte captures (the audio chain never came up before the
/// release). The live bug 2026-08-06 12:24: a 0.24 s accidental tap was
/// judged with a Date() taken after ~0.8 s of blocking calls, crossed the
/// 0.5 s threshold and showed a spurious "nothing heard". The verdict itself
/// must keep short taps silent and name the mic holder when there is one.
final class ZeroCaptureVerdictTests: XCTestCase {

    func testAccidentalTapStaysSilent() {
        XCTAssertNil(DictationPolicy.zeroCaptureVerdict(held: 0.24, foreignHeld: false))
    }

    func testAccidentalTapUnderForeignHoldStaysSilent() {
        XCTAssertNil(DictationPolicy.zeroCaptureVerdict(held: 0.24, foreignHeld: true))
    }

    func testRealHoldWithNoAudioIsNothingHeard() {
        XCTAssertEqual(DictationPolicy.zeroCaptureVerdict(held: 1.0, foreignHeld: false),
                       .nothingHeard)
    }

    func testRealHoldUnderForeignHoldIsMicBusy() {
        XCTAssertEqual(DictationPolicy.zeroCaptureVerdict(held: 1.2, foreignHeld: true),
                       .micBusy)
    }

    func testThresholdBoundaryReports() {
        XCTAssertEqual(DictationPolicy.zeroCaptureVerdict(held: 0.5, foreignHeld: false),
                       .nothingHeard)
        XCTAssertNil(DictationPolicy.zeroCaptureVerdict(held: 0.49, foreignHeld: false))
    }
}

/// The dictation pipeline's admission rule. The load-bearing case is the
/// first one: a press while the previous dictation is still recognizing MUST
/// start recording — swallowing it was the UX gap the pipeline exists to
/// close (the owner hit it three times in two minutes of normal use).
final class PipelineAdmissionTests: XCTestCase {

    func testPressDuringRecognitionStartsRecording() {
        XCTAssertTrue(DictationPolicy.mayBeginCapture(capturing: false, liveDelivering: false,
                                                      queuedJobs: 1, maxQueued: 3))
    }

    func testPressWhileAlreadyCapturingIsIgnored() {
        XCTAssertFalse(DictationPolicy.mayBeginCapture(capturing: true, liveDelivering: false,
                                                       queuedJobs: 0, maxQueued: 3))
    }

    func testLiveTypingDeliveryBlocksOverlap() {
        XCTAssertFalse(DictationPolicy.mayBeginCapture(capturing: false, liveDelivering: true,
                                                       queuedJobs: 0, maxQueued: 3))
    }

    func testFullQueueBlocksNewCapture() {
        XCTAssertFalse(DictationPolicy.mayBeginCapture(capturing: false, liveDelivering: false,
                                                       queuedJobs: 3, maxQueued: 3))
    }
}

/// GRABLI: the synthetic ⌘V rewrites the session flags state, so flagsState
/// briefly lies about physically held modifiers. Live case 2026-08-09 11:44:
/// a pipelined paste landed mid-recording and the lost-release watchdog cut
/// the recording at 2 s while the key was still held. Trust must drop with a
/// paste and return with the first real flags event after it.
final class ModifierStateTrustTests: XCTestCase {

    func testNoPasteEverIsTrustworthy() {
        XCTAssertTrue(DictationPolicy.modifierStateTrustworthy(
            lastRealFlagsEvent: .distantPast, lastSyntheticPaste: nil))
    }

    func testPasteAfterLastFlagsEventBreaksTrust() {
        let flags = Date(timeIntervalSince1970: 100)
        let paste = Date(timeIntervalSince1970: 101)
        XCTAssertFalse(DictationPolicy.modifierStateTrustworthy(
            lastRealFlagsEvent: flags, lastSyntheticPaste: paste))
    }

    func testRealFlagsEventAfterPasteRestoresTrust() {
        let paste = Date(timeIntervalSince1970: 101)
        let flags = Date(timeIntervalSince1970: 102)
        XCTAssertTrue(DictationPolicy.modifierStateTrustworthy(
            lastRealFlagsEvent: flags, lastSyntheticPaste: paste))
    }
}
