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

/// Speaker attribution of one Them window. The dominant-voice rule that used
/// to live here labelled a whole window with ONE voice; four real meetings
/// showed a lively call has no pauses, so the window is cut by the 15 s cap
/// and holds several people (2026-08-12 10:01:17 — two speakers in one entry,
/// chopped mid-sentence). The window is now cut at the diarizer's own
/// boundaries instead.
final class SpeakerSlicesTests: XCTestCase {

    private func span(_ id: String, _ start: Double, _ end: Double) -> MeetingPolicy.SpeakerSpan {
        MeetingPolicy.SpeakerSpan(id: id, start: start, end: end)
    }

    func testNoVoiceMeansNoSlices() {
        XCTAssertTrue(MeetingPolicy.speakerSlices(spans: [], windowStart: 0, windowEnd: 15).isEmpty)
    }

    func testSingleVoiceCoversTheWholeWindow() {
        // The common case must stay a single recognition of the whole window:
        // one slice, window edges, no extra Whisper passes.
        let slices = MeetingPolicy.speakerSlices(spans: [span("a", 1.0, 8.0)],
                                                 windowStart: 0, windowEnd: 10)
        XCTAssertEqual(slices, [MeetingPolicy.SpeakerSlice(id: "a", start: 0, end: 10)])
    }

    func testTwoVoicesSplitAtTheGapMidpoint() {
        // The 2026-08-12 case: 15 s of nonstop call holding two people. The
        // seam lands in the middle of the gap; the partition is exact — no
        // audio lost, none duplicated.
        let slices = MeetingPolicy.speakerSlices(spans: [span("a", 0.5, 7.0), span("b", 8.0, 14.5)],
                                                 windowStart: 0, windowEnd: 15)
        XCTAssertEqual(slices, [MeetingPolicy.SpeakerSlice(id: "a", start: 0, end: 7.5),
                                MeetingPolicy.SpeakerSlice(id: "b", start: 7.5, end: 15)])
    }

    func testConsecutiveSpansOfOneVoiceMerge() {
        // pyannote emits a span per chunk; three of the same voice in a row
        // must not become three entries.
        let slices = MeetingPolicy.speakerSlices(
            spans: [span("a", 0, 4), span("a", 4, 8), span("a", 8, 12)],
            windowStart: 0, windowEnd: 12)
        XCTAssertEqual(slices, [MeetingPolicy.SpeakerSlice(id: "a", start: 0, end: 12)])
    }

    func testShortBlipIsAbsorbedByTheLongerNeighbour() {
        // A 0.4 s back-channel ("ага") between two long stretches is not an
        // entry — and the longer stretch, the better-founded attribution,
        // takes it. Both neighbours are the same voice here, so the result is
        // ONE slice: the classic "someone hummed mid-sentence" window.
        let slices = MeetingPolicy.speakerSlices(
            spans: [span("a", 0, 6), span("b", 6, 6.4), span("a", 6.4, 12)],
            windowStart: 0, windowEnd: 12)
        XCTAssertEqual(slices, [MeetingPolicy.SpeakerSlice(id: "a", start: 0, end: 12)])
    }

    func testBlipBetweenTwoDifferentVoicesGoesToTheLongerOne() {
        // The 0.5 s "c" is swallowed by "b" (9.5 s) rather than "a" (2 s);
        // two entries come out, not three.
        let slices = MeetingPolicy.speakerSlices(
            spans: [span("a", 0, 2), span("c", 2, 2.5), span("b", 2.5, 12)],
            windowStart: 0, windowEnd: 12)
        XCTAssertEqual(slices, [MeetingPolicy.SpeakerSlice(id: "a", start: 0, end: 2),
                                MeetingPolicy.SpeakerSlice(id: "b", start: 2, end: 12)])
    }

    func testSlicesPartitionTheWindowExactly() {
        // The invariant that protects the transcript: every sample belongs to
        // exactly one entry. A gap would drop half a word, an overlap would
        // print the same sentence under two speakers.
        let slices = MeetingPolicy.speakerSlices(
            spans: [span("a", 0.5, 4), span("b", 5, 9), span("a", 9.5, 14)],
            windowStart: 0, windowEnd: 15)
        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(slices.first?.start, 0)
        XCTAssertEqual(slices.last?.end, 15)
        for (a, b) in zip(slices, slices.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
        }
    }

    func testCrosstalkKeepsTheVoiceHoldingTheFloor() {
        // Two voices reported over the same seconds: the one already holding
        // the floor keeps it, and the interjection swallowed inside it never
        // becomes its own entry.
        let slices = MeetingPolicy.speakerSlices(
            spans: [span("a", 0, 10), span("b", 3, 5)],
            windowStart: 0, windowEnd: 10)
        XCTAssertEqual(slices, [MeetingPolicy.SpeakerSlice(id: "a", start: 0, end: 10)])
    }

    func testSpansAreClampedToTheWindow() {
        // The diarizer pads its last chunk; slice times must never point
        // outside the PCM buffer they will index into.
        let slices = MeetingPolicy.speakerSlices(spans: [span("a", -2, 20)],
                                                 windowStart: 0, windowEnd: 10)
        XCTAssertEqual(slices, [MeetingPolicy.SpeakerSlice(id: "a", start: 0, end: 10)])
    }
}

/// Phantom rejection by the MODEL's own confidence signals. The owner
/// explicitly rejected a phrase blocklist (it would also delete the real
/// "Thank you" a participant says), so the rule reads no-speech probability,
/// average log-probability and compression ratio — the very numbers
/// openai/whisper uses internally — plus Silero's voiced-chunk counts.
/// Conservative by design: losing a real short reply is worse than keeping a
/// phantom, so every rule is a conjunction.
final class PhantomVerdictTests: XCTestCase {

    private func evidence(noSpeech: Double = 0.05, logprob: Double = -0.3,
                          compression: Double = 1.4, words: Int = 5,
                          seconds: Double = 4, voiced: Int? = 10)
        -> MeetingPolicy.SpeechEvidence {
        MeetingPolicy.SpeechEvidence(noSpeechProb: noSpeech, avgLogprob: logprob,
                                     compressionRatio: compression, words: words,
                                     audioSeconds: seconds, voicedChunks: voiced)
    }

    func testConfidentRealSpeechIsKept() {
        XCTAssertEqual(MeetingPolicy.phantomVerdict(evidence()), .keep)
    }

    func testCurtRealReplyIsKept() {
        // "Да." — two words, short slice, the model heard it clearly. This is
        // the case the whole rule set is built not to break.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(noSpeech: 0.08, logprob: -0.5, words: 1, seconds: 1.2, voiced: 3)),
                       .keep)
    }

    func testWhispersOwnSilenceRuleRejects() {
        // no_speech_prob > 0.6 AND avg_logprob < −1.0: openai/whisper's own
        // defaults, the case where the model itself would drop the segment.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(noSpeech: 0.7, logprob: -1.4, words: 9)),
                       .reject("silence"))
    }

    func testUnsureButSpeechfulIsKept() {
        // Low no-speech probability: unsure decoding of real speech (accents,
        // compressed call audio) must survive.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(noSpeech: 0.2, logprob: -1.5, words: 9)),
                       .keep)
    }

    func testConfidentPhantomOnNoSpeechIsRejected() {
        // The class that actually reaches the transcripts: a fluent "Thank
        // you." the model is sure about, over audio it is 91% sure holds no
        // speech at all.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(noSpeech: 0.91, logprob: -0.25, words: 2, seconds: 2, voiced: 4)),
                       .reject("no speech"))
    }

    func testNoSpeechBarSitsWellAboveTheVendorDefault() {
        // 0.7 alone must NOT reject a short reply — only the far side of the
        // bar (0.85) does, because a real curt answer scores far below it.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(noSpeech: 0.7, logprob: -0.25, words: 2, seconds: 2, voiced: 4)),
                       .keep)
    }

    func testLongOutputSurvivesAHighNoSpeechScore() {
        // A whole sentence is never dropped by rule (2) — the blast radius is
        // capped at micro-entries.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(noSpeech: 0.95, logprob: -0.3, words: 12)),
                       .keep)
    }

    func testBreathSignatureIsRejected() {
        // The GRABLI case at the OUTPUT: seconds of audio, ~0.5 s of voice in
        // it, one word out. The input gate lets voiced==2 through on purpose;
        // this catches what it costs.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(noSpeech: 0.4, logprob: -0.6, words: 1, seconds: 6, voiced: 2)),
                       .reject("too little voice"))
    }

    func testShortSliceWithLittleVoiceIsKept() {
        // Same voiced count, but the audio is SHORT — that is a real curt
        // reply, not a breath in a long silence. The 3 s floor is what tells
        // them apart.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(noSpeech: 0.4, logprob: -0.6, words: 1, seconds: 1.5, voiced: 2)),
                       .keep)
    }

    func testRepetitionLoopIsRejected() {
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(compression: 3.4, words: 40)),
                       .reject("repetition"))
    }

    func testOrdinaryProseNearWhispersOwnBarIsKept() {
        // Whisper's own degenerate bar is 2.4; we keep a margin so a
        // repetitive but real passage ("да, да, да, конечно, да") survives.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(compression: 2.6, words: 40)),
                       .keep)
    }

    func testMissingVadDoesNotRejectOnItsOwn() {
        // VAD unavailable: only the model's numbers count, and they are fine
        // here — nothing may be thrown away for lack of evidence.
        XCTAssertEqual(MeetingPolicy.phantomVerdict(
            evidence(words: 1, seconds: 8, voiced: nil)),
                       .keep)
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

/// The Them window cap is the segmentation model's input length, and the
/// reason it is not a matter of taste: a window longer than the model's fixed
/// 10.0 s input gets chunked, the last chunk is zero-padded, and a short
/// padded chunk's embedding clusters as a different person. Measured on a
/// dumped meeting (bench: internal/claude-tooling/diar-bench): the old 15 s
/// cap split 70% of windows and invented a second near-equal speaker; 10 s
/// splits 6% and reproduces the meeting as it happened.
final class ThemWindowCapTests: XCTestCase {

    func testTheCapIsTheModelsInputLength() {
        // 160000 samples at 16 kHz. If this ever changes, the reason has to
        // change with it — the number is not tuning, it is the model.
        XCTAssertEqual(MeetingPolicy.themWindowCap, 10)
    }

    func testAMonologueIsCutAtTheCap() {
        // Continuous speech, no pause in sight: the cap is what cuts, and it
        // must cut before the diarizer would need a second chunk.
        XCTAssertEqual(
            MeetingPolicy.windowVerdict(accumulated: MeetingPolicy.themWindowCap,
                                        hadSpeech: true, sinceLoud: 0.1,
                                        hardCap: MeetingPolicy.themWindowCap),
            .cutTranscribe)
        XCTAssertEqual(
            MeetingPolicy.windowVerdict(accumulated: 9.5, hadSpeech: true, sinceLoud: 0.1,
                                        hardCap: MeetingPolicy.themWindowCap),
            .keep)
    }

    func testTheYouChannelKeepsTheLongerCap() {
        // You never reaches the diarizer, so it keeps the default: cutting it
        // at 10 s would only chop the owner's entries for no benefit.
        XCTAssertEqual(
            MeetingPolicy.windowVerdict(accumulated: 12.0, hadSpeech: true, sinceLoud: 0.1),
            .keep)
    }

    func testPausesStillWinOverTheCap() {
        // The cap is a ceiling, not the primary rule: a natural pause cuts
        // earlier, which is what keeps utterances whole.
        XCTAssertEqual(
            MeetingPolicy.windowVerdict(accumulated: 4.0, hadSpeech: true, sinceLoud: 1.2,
                                        hardCap: MeetingPolicy.themWindowCap),
            .cutTranscribe)
    }

    // MARK: - Punctuation-only results

    func testBarePunctuationIsNotAnEntry() {
        // The exact strings that reached a live transcript (2026-08-27):
        // whole results of "-" and ".", plus the shapes Whisper likes.
        for junk in ["-", ".", "…", "?!", "— —", "..."] {
            XCTAssertFalse(MeetingPolicy.saidAnything(junk), junk)
        }
    }

    func testCurtRealRepliesSurvive() {
        // The asymmetry phantomVerdict lives by holds here too: a real curt
        // reply must never be dropped, whatever language or script it is in.
        for real in ["Да.", "ok", "No!", "42", "第3", "Đúng."] {
            XCTAssertTrue(MeetingPolicy.saidAnything(real), real)
        }
    }
}

// The browser-title platform rule (owner's report 2026-08-29: every Meet
// call read as "other" — Meet is a tab, and the mic is held by "Chrome").
final class CallPlatformTitleTests: XCTestCase {

    func testMeetRoomCodeTitleIsMeet() {
        // Chrome titles a live call tab with the room code.
        XCTAssertEqual(MeetingPolicy.callPlatform(
            inWindowTitle: "Meet – abc-defg-hij"), "Google Meet")
        XCTAssertEqual(MeetingPolicy.callPlatform(
            inWindowTitle: "Meet - abc-defg-hij - Google Chrome"), "Google Meet")
        XCTAssertEqual(MeetingPolicy.callPlatform(
            inWindowTitle: "Weekly sync - Google Meet"), "Google Meet")
    }

    func testTheWordMeetingIsNotMeet() {
        // The trap the rule is shaped around: "meet" inside ordinary words
        // or documents must never become a platform.
        XCTAssertNil(MeetingPolicy.callPlatform(inWindowTitle: "Meeting notes — Notion"))
        XCTAssertNil(MeetingPolicy.callPlatform(inWindowTitle: "How to meet deadlines - Blog"))
        XCTAssertNil(MeetingPolicy.callPlatform(inWindowTitle: "Meet the team — Careers"))
    }

    func testLongerTokenIsNotARoomCode() {
        XCTAssertNil(MeetingPolicy.callPlatform(inWindowTitle: "Meet – abc-defg-hijklm"))
    }

    func testOtherPlatforms() {
        XCTAssertEqual(MeetingPolicy.callPlatform(
            inWindowTitle: "Zoom Meeting - Zoom"), "Zoom")
        XCTAssertEqual(MeetingPolicy.callPlatform(
            inWindowTitle: "Design review | Microsoft Teams"), "Microsoft Teams")
        XCTAssertEqual(MeetingPolicy.callPlatform(
            inWindowTitle: "Cisco Webex Meetings"), "Webex")
        XCTAssertNil(MeetingPolicy.callPlatform(inWindowTitle: "Inbox — Gmail"))
    }

    func testBrowserNames() {
        XCTAssertTrue(MeetingPolicy.isBrowser(appNamed: "Google Chrome"))
        XCTAssertTrue(MeetingPolicy.isBrowser(appNamed: "Safari"))
        XCTAssertTrue(MeetingPolicy.isBrowser(appNamed: "Arc"))
        XCTAssertFalse(MeetingPolicy.isBrowser(appNamed: "zoom.us"))
        XCTAssertFalse(MeetingPolicy.isBrowser(appNamed: "Notion"))
    }
}

// The forgotten recording, hardened: the invariant, the two rules, and the
// weak cases the review found — each one pinned as a test.
final class AutoStopTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLiveCallNeverStopsHoweverLongTheSilence() {
        // The hold, the silent co-working call, the document-reading pause:
        // a call process on the mic means every silence is legitimate.
        XCTAssertEqual(MeetingPolicy.autoStopVerdict(
            platformEverSeen: true, platformAliveNow: true,
            lastAliveAt: t0, lastVoicedAt: t0,
            now: t0.addingTimeInterval(3600 * 3)), .keep)
    }

    func testCallGoneAndQuietStops() {
        XCTAssertEqual(MeetingPolicy.autoStopVerdict(
            platformEverSeen: true, platformAliveNow: false,
            lastAliveAt: t0, lastVoicedAt: t0,
            now: t0.addingTimeInterval(MeetingPolicy.callEndGrace + 5)), .callEnded)
    }

    func testCallGoneButPeopleStillTalkingKeeps() {
        // The call moved to a phone on speaker: the platform is gone but the
        // room is speaking — the recording follows the voices, not the app.
        let now = t0.addingTimeInterval(MeetingPolicy.callEndGrace + 5)
        XCTAssertEqual(MeetingPolicy.autoStopVerdict(
            platformEverSeen: true, platformAliveNow: false,
            lastAliveAt: t0, lastVoicedAt: now.addingTimeInterval(-10),
            now: now), .keep)
    }

    func testReconnectInsideGraceKeeps() {
        XCTAssertEqual(MeetingPolicy.autoStopVerdict(
            platformEverSeen: true, platformAliveNow: false,
            lastAliveAt: t0, lastVoicedAt: t0,
            now: t0.addingTimeInterval(MeetingPolicy.callEndGrace - 10)), .keep)
    }

    func testDeadAirStopsAnUndetectableSession() {
        // No platform was ever seen (unknown VoIP app, a room recording):
        // only the long full-silence backstop may end it.
        XCTAssertEqual(MeetingPolicy.autoStopVerdict(
            platformEverSeen: false, platformAliveNow: false,
            lastAliveAt: nil, lastVoicedAt: t0,
            now: t0.addingTimeInterval(MeetingPolicy.deadAirStop + 1)), .deadAir)
    }

    func testFreshVoiceKeepsAnUndetectableSession() {
        let now = t0.addingTimeInterval(MeetingPolicy.deadAirStop + 100)
        XCTAssertEqual(MeetingPolicy.autoStopVerdict(
            platformEverSeen: false, platformAliveNow: false,
            lastAliveAt: nil, lastVoicedAt: now.addingTimeInterval(-60),
            now: now), .keep)
    }
}
