import XCTest
// MeetingSpeakerPolicy compiles directly into the test target (see
// project.yml), the DictationPolicy pattern — MeetingDiarizer itself imports
// FluidAudio and stays out.

/// End-of-session micro-clusters: which barely-speaking voices go back into a
/// real one and, more importantly, which must not.
///
/// These tests are the ONLY proof this rule will ever have. We keep no meeting
/// audio, so nothing here can be checked against a recording afterwards and
/// every live calibration point costs one real meeting — hence the emphasis on
/// the refusals, which are what protects a real person who only spoke once.
final class MeetingSpeakerPolicyTests: XCTestCase {

    private let ceiling = 0.7

    /// Distances given as an unordered pair table, so a test reads the way the
    /// measurement does: "these two voices are this far apart".
    private func table(_ pairs: [(Int, Int, Double)]) -> (Int, Int) -> Double? {
        { a, b in
            pairs.first { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }?.2
        }
    }

    private func voice(_ ordinal: Int, entries: Int, seconds: Double,
                       renamed: Bool = false) -> MeetingSpeakerPolicy.Voice {
        MeetingSpeakerPolicy.Voice(ordinal: ordinal, entries: entries,
                                   seconds: seconds, renamed: renamed)
    }

    // MARK: - Smallness

    func testSmallnessNeedsBothFewEntriesAndLittleSpeech() {
        // The observed phantom: one entry in a whole meeting.
        XCTAssertTrue(MeetingSpeakerPolicy.isMicro(voice(4, entries: 1, seconds: 4)))
        XCTAssertTrue(MeetingSpeakerPolicy.isMicro(voice(4, entries: 2, seconds: 9.5)))
        // Two entries, but real ones: eight seconds each is a person making two
        // short remarks, not a shed fragment.
        XCTAssertFalse(MeetingSpeakerPolicy.isMicro(voice(4, entries: 2, seconds: 16)))
        // Few seconds spread over many entries is a backchannel speaker
        // ("yeah", "mhm") — a real participant, and out of scope on purpose.
        XCTAssertFalse(MeetingSpeakerPolicy.isMicro(voice(4, entries: 7, seconds: 8)))
        // Nothing in the file = nothing to relabel.
        XCTAssertFalse(MeetingSpeakerPolicy.isMicro(voice(4, entries: 0, seconds: 0)))
    }

    func testHandNamedVoiceIsNeverAMicroCluster() {
        // The owner typing a name is the strongest statement that this is a
        // real person; acoustics never overrule it.
        XCTAssertFalse(MeetingSpeakerPolicy.isMicro(
            voice(4, entries: 1, seconds: 3, renamed: true)))
    }

    // MARK: - The merge

    func testLoneFragmentGoesBackIntoItsNearestVoice() {
        let voices = [voice(1, entries: 40, seconds: 600),
                      voice(2, entries: 25, seconds: 380),
                      voice(3, entries: 1, seconds: 5)]
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: voices, ceiling: ceiling,
            distance: table([(3, 1, 0.66), (3, 2, 0.41), (1, 2, 0.95)]))
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts.first?.voice.ordinal, 3)
        XCTAssertEqual(verdicts.first?.outcome, .merge(into: 2, distance: 0.41))
    }

    func testDistanceExactlyAtTheCeilingStillMerges() {
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 30, seconds: 400), voice(2, entries: 1, seconds: 3)],
            ceiling: ceiling, distance: table([(1, 2, 0.7)]))
        XCTAssertEqual(verdicts.first?.outcome, .merge(into: 1, distance: 0.7))
    }

    // MARK: - The refusals (the important half)

    func testDistinctVoiceThatOnlySpokeOnceSurvives() {
        // One entry, but acoustically nothing like the others: a person who
        // said one sentence in an hour. A wrong merge here would put his words
        // in somebody else's mouth — far worse than a surplus label.
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 40, seconds: 600),
                     voice(2, entries: 20, seconds: 300),
                     voice(3, entries: 1, seconds: 6)],
            ceiling: ceiling,
            distance: table([(3, 1, 0.88), (3, 2, 0.92), (1, 2, 0.95)]))
        XCTAssertEqual(verdicts.first?.outcome, .keepTooFar(nearest: 1, distance: 0.88))
    }

    func testTwoFragmentsNeverMergeIntoEachOther() {
        // Both tiny and close to each other: still nothing happens, because a
        // merge of two unverified fragments would invent a voice.
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 1, seconds: 4), voice(2, entries: 2, seconds: 7)],
            ceiling: ceiling, distance: table([(1, 2, 0.10)]))
        XCTAssertEqual(verdicts.map(\.outcome), [.keepNoHost, .keepNoHost])
    }

    func testFragmentIsNeverMergedIntoAnotherFragmentEvenWhenNearer() {
        // The nearest voice of all is another micro-cluster; the rule must
        // reach past it to the real one, or refuse.
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 30, seconds: 450),
                     voice(2, entries: 1, seconds: 3),
                     voice(3, entries: 1, seconds: 4)],
            ceiling: ceiling,
            distance: table([(2, 3, 0.05), (2, 1, 0.60), (3, 1, 0.90)]))
        XCTAssertEqual(verdicts.count, 2)
        XCTAssertEqual(verdicts[0].outcome, .merge(into: 1, distance: 0.60))
        XCTAssertEqual(verdicts[1].outcome, .keepTooFar(nearest: 1, distance: 0.90))
    }

    func testUnmeasurableVoiceIsLeftAlone() {
        // The database lost (or never had) an embedding: never guess.
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 30, seconds: 450), voice(2, entries: 1, seconds: 3)],
            ceiling: ceiling, distance: { _, _ in nil })
        XCTAssertEqual(verdicts.first?.outcome, .keepUnmeasured)
    }

    func testInfiniteDistanceCountsAsUnmeasurable() {
        // FluidAudio's cosineDistance returns .infinity for a degenerate
        // embedding; that is "no answer", not "very far".
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 30, seconds: 450), voice(2, entries: 1, seconds: 3)],
            ceiling: ceiling, distance: table([(1, 2, .infinity)]))
        XCTAssertEqual(verdicts.first?.outcome, .keepUnmeasured)
    }

    func testSingleVoiceMeetingIsUntouched() {
        // A quiet call where the only voice said two words: there is nothing
        // to merge into, and the label stays.
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 1, seconds: 2)],
            ceiling: ceiling, distance: table([]))
        XCTAssertEqual(verdicts.first?.outcome, .keepNoHost)
    }

    func testHandNamedVoiceCanStillReceiveAFragment() {
        // "Anna" is a real person by the owner's word; a fragment of her voice
        // still belongs to her.
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 20, seconds: 300, renamed: true),
                     voice(2, entries: 1, seconds: 4)],
            ceiling: ceiling, distance: table([(1, 2, 0.5)]))
        XCTAssertEqual(verdicts.first?.outcome, .merge(into: 1, distance: 0.5))
    }

    func testVoiceWithNoEntriesHostsNothing() {
        // A number the diarizer handed out whose turns were all rejected as
        // phantoms: it has no words to lend its label to.
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 0, seconds: 0), voice(2, entries: 1, seconds: 3)],
            ceiling: ceiling, distance: table([(1, 2, 0.2)]))
        XCTAssertEqual(verdicts.first?.outcome, .keepNoHost)
    }

    // MARK: - Determinism

    func testResultDoesNotDependOnInputOrder() {
        let voices = [voice(3, entries: 1, seconds: 5),
                      voice(1, entries: 40, seconds: 600),
                      voice(4, entries: 2, seconds: 8),
                      voice(2, entries: 25, seconds: 380)]
        let distances = table([(3, 1, 0.66), (3, 2, 0.41),
                               (4, 1, 0.55), (4, 2, 0.58), (1, 2, 0.95)])
        let straight = MeetingSpeakerPolicy.verdicts(voices: voices, ceiling: ceiling,
                                                     distance: distances)
        let shuffled = MeetingSpeakerPolicy.verdicts(voices: voices.reversed(),
                                                     ceiling: ceiling, distance: distances)
        XCTAssertEqual(straight, shuffled)
        // …and the verdicts come out in ordinal order, so the log reads
        // predictably from one meeting to the next.
        XCTAssertEqual(straight.map(\.voice.ordinal), [3, 4])
        XCTAssertEqual(straight.map(\.outcome),
                       [.merge(into: 2, distance: 0.41), .merge(into: 1, distance: 0.55)])
    }

    func testEqualDistancesResolveToTheLowerOrdinal() {
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 20, seconds: 300),
                     voice(2, entries: 20, seconds: 300),
                     voice(3, entries: 1, seconds: 3)],
            ceiling: ceiling,
            distance: table([(3, 1, 0.5), (3, 2, 0.5), (1, 2, 0.9)]))
        XCTAssertEqual(verdicts.first?.outcome, .merge(into: 1, distance: 0.5))
    }

    // MARK: - The meetings this was built from

    func testTheThreeConfirmedMeetingsShape() {
        // 2026-08-11 "AI system onboarding": three people, so two voices on the
        // tap channel, but four labels — the fourth held ONE entry in 51
        // minutes. With the fourth close to Speaker 2 the transcript comes out
        // with the three labels the owner's ground truth says it should have
        // (Speaker 1/2/3 here are tap-channel voices; a surplus one is what we
        // are removing).
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 120, seconds: 1500),
                     voice(2, entries: 95, seconds: 1300),
                     voice(3, entries: 30, seconds: 400),
                     voice(4, entries: 1, seconds: 6)],
            ceiling: ceiling,
            distance: table([(4, 1, 0.81), (4, 2, 0.52), (4, 3, 0.77),
                             (1, 2, 0.95), (1, 3, 0.93), (2, 3, 0.90)]))
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts.first?.outcome, .merge(into: 2, distance: 0.52))
        // And the same shape with a distant fourth voice changes nothing —
        // which is the honest half: the rule only fires when the acoustics say
        // so, so it may well fire on no meeting at all until the ceiling is
        // calibrated against real refusal distances.
        let stubborn = MeetingSpeakerPolicy.verdicts(
            voices: [voice(1, entries: 120, seconds: 1500),
                     voice(2, entries: 95, seconds: 1300),
                     voice(4, entries: 1, seconds: 6)],
            ceiling: ceiling,
            distance: table([(4, 1, 0.81), (4, 2, 0.79), (1, 2, 0.95)]))
        XCTAssertEqual(stubborn.first?.outcome, .keepTooFar(nearest: 2, distance: 0.79))
    }

    // MARK: - The clustering threshold knob

    /// The knob exists so the threshold can be MEASURED against the podcast
    /// bench instead of guessed at, and the whole point of a bench is that a
    /// mistyped `defaults write` fails loudly rather than quietly producing a
    /// run nobody can interpret. These tests are that guarantee.

    func testAbsentKeyLeavesTheCompiledDefaultInForce() {
        let t = MeetingSpeakerPolicy.threshold(override: nil)
        XCTAssertEqual(t.value, MeetingSpeakerPolicy.defaultClusteringThreshold)
        XCTAssertEqual(t.source, .compiled)
        // The compiled default is 0.7 and stays there until the bench moves it:
        // this change adds a knob, it does not pick a new value.
        XCTAssertEqual(t.value, 0.7)
    }

    func testAnOverrideInsideTheRangeIsHonoured() {
        let t = MeetingSpeakerPolicy.threshold(override: 0.8)
        XCTAssertEqual(t.value, 0.8, accuracy: 0.0001)
        XCTAssertEqual(t.source, .override(0.8))
    }

    func testBothEndsOfTheRangeAreAccepted() {
        for raw in [0.3, 0.95] {
            let t = MeetingSpeakerPolicy.threshold(override: raw)
            XCTAssertEqual(Double(t.value), raw, accuracy: 0.0001)
            XCTAssertEqual(t.source, .override(raw))
        }
    }

    func testValuesThatWouldBreakDiarizationAreRefusedNotClamped() {
        // 0 = every utterance becomes its own speaker; 2.0 = one voice for the
        // whole meeting, and (since mergeCeiling follows the threshold) an
        // end-of-session merge that would swallow real people. Neither may
        // take effect, and neither may pass unnoticed.
        for raw in [0.0, 0.29, 2.0, 1.0, -0.5] {
            let t = MeetingSpeakerPolicy.threshold(override: raw)
            XCTAssertEqual(t.value, MeetingSpeakerPolicy.defaultClusteringThreshold,
                           "\(raw) must fall back to the compiled default")
            XCTAssertEqual(t.source, .rejected(raw))
        }
    }

    func testNonNumericKeyReadsAsZeroAndIsRefused() {
        // `defaults write … diarThreshold -string hello` reads back as 0.0
        // through UserDefaults — the same path as an out-of-range number, and
        // it must end the same way.
        XCTAssertEqual(MeetingSpeakerPolicy.threshold(override: 0).source, .rejected(0))
        XCTAssertEqual(MeetingSpeakerPolicy.threshold(override: .nan).value,
                       MeetingSpeakerPolicy.defaultClusteringThreshold)
        XCTAssertEqual(MeetingSpeakerPolicy.threshold(override: .infinity).value,
                       MeetingSpeakerPolicy.defaultClusteringThreshold)
    }

    func testTheLogLineNamesTheValueAndWhereItCameFrom() {
        // A calibration run is read after the fact: the log must answer "which
        // threshold produced this transcript" without the shell history.
        XCTAssertEqual(
            MeetingSpeakerPolicy.describe(.init(value: 0.7, source: .compiled)), "0.70")
        XCTAssertEqual(
            MeetingSpeakerPolicy.describe(MeetingSpeakerPolicy.threshold(override: 0.8)),
            "0.80 (diarThreshold override)")
        // A refused override must be impossible to mistake for a working one.
        let refused = MeetingSpeakerPolicy.describe(
            MeetingSpeakerPolicy.threshold(override: 2))
        XCTAssertTrue(refused.contains("0.70"), refused)
        XCTAssertTrue(refused.contains("REFUSED"), refused)
        XCTAssertTrue(refused.contains("2"), refused)
    }
}
