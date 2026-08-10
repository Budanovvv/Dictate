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
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 5.0, hadSpeech: true, sinceLoud: 1.2),
                       .cutTranscribe)
    }

    func testOngoingSpeechKeeps() {
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 5.0, hadSpeech: true, sinceLoud: 0.2),
                       .keep)
        // A reflective mid-thought pause (the 16:25 field complaint: 0.8 s
        // used to split one sentence in two) keeps accumulating.
        XCTAssertEqual(MeetingPolicy.windowVerdict(accumulated: 5.0, hadSpeech: true, sinceLoud: 0.9),
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

/// GRABLI: Whisper hallucinates on windows with no real content. The root
/// fix is at the input — a continuous channel's window must hold enough
/// voiced audio to be worth transcribing. The live case: 1 voiced chunk of
/// 39 produced "Thank you." three times in the first real meeting.
final class WindowWorthTranscribingTests: XCTestCase {

    func testSingleBreathBlipIsDropped() {
        XCTAssertFalse(MeetingPolicy.windowWorthTranscribing(voicedChunks: 1))
    }

    func testSilenceIsDropped() {
        XCTAssertFalse(MeetingPolicy.windowWorthTranscribing(voicedChunks: 0))
    }

    func testCurtRealUtterancePasses() {
        // ~0.5 s of voiced audio — a real short "Да." from a participant.
        XCTAssertTrue(MeetingPolicy.windowWorthTranscribing(voicedChunks: 2))
    }
}

/// The flush frontier per channel: speech pins it, silence must not — a
/// silent channel's ancient window start once held finished entries hostage
/// for up to 10 s and dumped them in a batch (field run 2026-08-09 17:25).
final class ChannelFrontierTests: XCTestCase {

    func testSpeechWindowPinsAtFirstSpeech() {
        XCTAssertEqual(MeetingPolicy.channelFrontier(windowStart: 10, firstSpeechAt: 14, now: 20),
                       14)
    }

    func testSilentWindowOnlyVouchesForTheRecentPast() {
        // Window started at 10, silent for 10 s: entries older than now−2.5
        // must flow — the frontier trails now, not the stale window start.
        XCTAssertEqual(MeetingPolicy.channelFrontier(windowStart: 10, firstSpeechAt: nil, now: 20),
                       17.5)
    }

    func testStaleFirstSpeechFromPreviousWindowIgnored() {
        // firstSpeech belongs to an already-cut window (before windowStart):
        // treat as silent.
        XCTAssertEqual(MeetingPolicy.channelFrontier(windowStart: 10, firstSpeechAt: 4, now: 20),
                       17.5)
    }
}

// NOTE: CallOverTests removed with the auto-stop feature itself
// (2026-08-10, owner's call) — see the note in MeetingPolicy.

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
