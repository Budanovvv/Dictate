import XCTest
// MeetingPolicy compiles directly into the test target (see project.yml),
// same as DictationPolicy.

/// Window cutting: whole utterances at natural pauses, bounded latency for
/// monologues, and no hour-long buffers on a silent channel.
final class MeetingWindowVerdictTests: XCTestCase {

    func testShortWindowKeepsAccumulating() {
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 1.0, hadSpeech: true, sinceLoud: 1.0),
                       .keep)
    }

    func testPauseAfterSpeechCuts() {
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 5.0, hadSpeech: true, sinceLoud: 0.9),
                       .cutTranscribe)
    }

    func testOngoingSpeechKeeps() {
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 5.0, hadSpeech: true, sinceLoud: 0.2),
                       .keep)
    }

    func testMonologueHitsHardCap() {
        // 15 s cap: even when pause detection fails entirely (the no-AEC
        // busy-mic path once read the room as nonstop speech), the live
        // window shows progress at least this often.
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 15.0, hadSpeech: true, sinceLoud: 0.1),
                       .cutTranscribe)
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 14.0, hadSpeech: true, sinceLoud: 0.1),
                       .keep)
    }

    func testSilentChannelDropsPeriodically() {
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 10.0, hadSpeech: false, sinceLoud: .infinity),
                       .dropSilence)
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 9.0, hadSpeech: false, sinceLoud: .infinity),
                       .keep)
    }
}

/// GRABLI: fixed level thresholds don't survive a second audio path. The
/// no-AEC busy-mic capture has a raw noise floor ABOVE the old fixed 0.08 —
/// the room read as nonstop speech and windows never cut (field test
/// 2026-08-09 15:48). The floor adapts; loudness needs a clear margin over it.
final class AdaptiveLoudnessTests: XCTestCase {

    func testQuietRoomKeepsFixedThreshold() {
        // Floor near zero: the classic 0.08 threshold applies.
        XCTAssertFalse(MeetingPolicy.isLoud(level: 0.05, floor: 0.01))
        XCTAssertTrue(MeetingPolicy.isLoud(level: 0.09, floor: 0.01))
    }

    func testNoisyCapturePathRaisesThreshold() {
        // The live failure: floor ~0.14 (no-AEC room noise). 0.14 must NOT
        // count as speech; a real voice well above the floor must.
        XCTAssertFalse(MeetingPolicy.isLoud(level: 0.14, floor: 0.14))
        XCTAssertTrue(MeetingPolicy.isLoud(level: 0.30, floor: 0.14))
    }

    func testFloorDropsInstantlyAndRisesSlowly() {
        // A quiet buffer pulls the floor straight down…
        XCTAssertEqual(MeetingPolicy.updatedNoiseFloor(1.0, level: 0.12), 0.12, accuracy: 0.001)
        // …speech only nudges it up a few percent per buffer.
        let crept = MeetingPolicy.updatedNoiseFloor(0.12, level: 0.9)
        XCTAssertLessThan(crept, 0.13)
    }
}

/// Speaker attribution of one utterance window: the dominant voice wins,
/// ties break deterministically, an empty window has no speaker.
final class DominantSpeakerTests: XCTestCase {

    func testDominantVoiceWins() {
        XCTAssertEqual(MeetingPolicy.dominantSpeakerId(durations: ["a": 1.2, "b": 4.5]), "b")
    }

    func testTieBreaksBySmallerId() {
        XCTAssertEqual(MeetingPolicy.dominantSpeakerId(durations: ["b": 2.0, "a": 2.0]), "a")
    }

    func testEmptyWindowHasNoSpeaker() {
        XCTAssertNil(MeetingPolicy.dominantSpeakerId(durations: [:]))
    }
}

/// Entry flushing: dialogue order must survive recognitions finishing out of
/// order — a slow early chunk holds back fast later ones, never the reverse.
final class MeetingFlushTests: XCTestCase {

    func testEntriesBeforeAllFrontiersFlush() {
        XCTAssertEqual(MeetingPolicy.flushableCount(sortedStarts: [1.0, 5.0, 12.0],
                                                    channelFrontiers: [10.0, 11.0],
                                                    inflightStarts: []),
                       2)
    }

    func testInflightEarlyWindowHoldsLaterEntries() {
        // A recognition still running for the window that started at 3 s must
        // hold back the already-finished entries from 5 s and 12 s.
        XCTAssertEqual(MeetingPolicy.flushableCount(sortedStarts: [5.0, 12.0],
                                                    channelFrontiers: [20.0, 20.0],
                                                    inflightStarts: [3.0]),
                       0)
    }

    func testNoFrontiersMeansEverythingFlushes() {
        // Session stopped, nothing in flight: all pending entries go out.
        XCTAssertEqual(MeetingPolicy.flushableCount(sortedStarts: [5.0, 12.0],
                                                    channelFrontiers: [],
                                                    inflightStarts: []),
                       2)
    }
}
