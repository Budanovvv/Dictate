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

/// Lexical label inheritance: a tap-channel entry that finishes the previous
/// voice's unfinished sentence is written under that voice.
///
/// The strings are real fragments from the 2026-08-17 meeting (ground truth:
/// two people on the tap channel, four labels written) — the meeting that
/// proved acoustics cannot heal a split voice: the split pair's distance
/// (0.847) matched the two real people's (0.844). The refusal cases matter
/// more than the joins, because a wrong inheritance steals words from a real
/// person.
final class LabelInheritanceTests: XCTestCase {

    func testTornSentenceInheritsTheVoice() {
        // "And I have like a hundred thousand / debit in my checking account…"
        // — one monologue the diarizer wrote under two labels.
        XCTAssertEqual(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "And I have like a hundred thousand", previousOrdinal: 2,
            nextText: "debit in my in my checking account or whatever but I'm fine",
            nextOrdinal: 1, secondsApart: 6), 2)
    }

    func testFinishedSentenceHandsOverNothing() {
        // The previous line closed with a full stop: whoever speaks next —
        // even in lower case — is not finishing it.
        XCTAssertNil(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "It's all together.", previousOrdinal: 2,
            nextText: "like $8,000 to get from my account", nextOrdinal: 1,
            secondsApart: 6))
    }

    func testCapitalStartIsARealSpeakerChange() {
        // An unfinished line followed by a capital is somebody being
        // interrupted — the diarizer's label stands.
        XCTAssertNil(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "and we start looking for those", previousOrdinal: 2,
            nextText: "Okay, next week I have a playbook.", nextOrdinal: 1,
            secondsApart: 6))
    }

    func testCollectiveEntryHandsOverNothing() {
        // "Them" (no ordinal) is not a voice — there is nothing to inherit,
        // and the chain breaks there by design.
        XCTAssertNil(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "and I have like a hundred thousand", previousOrdinal: nil,
            nextText: "debit in my checking account", nextOrdinal: 1,
            secondsApart: 6))
    }

    func testCollectiveNextEntryCanInherit() {
        // The reverse is allowed: a window where the diarizer heard no voice
        // still carries words, and the words say whose they are.
        XCTAssertEqual(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "we can get the number of us, look,", previousOrdinal: 3,
            nextText: "local DIT, blah, blah, blah", nextOrdinal: nil,
            secondsApart: 7), 3)
    }

    func testSameVoiceNeedsNoInheritance() {
        XCTAssertNil(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "and I have like a hundred thousand", previousOrdinal: 2,
            nextText: "debit in my checking account", nextOrdinal: 2,
            secondsApart: 6))
    }

    func testFarApartEntriesStayApart() {
        // Beyond the cap-split window the "continuation" is coincidence; and
        // a negative gap means the order is not what the rule assumes.
        XCTAssertNil(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "and I have like a hundred thousand", previousOrdinal: 2,
            nextText: "debit in my checking account", nextOrdinal: 1,
            secondsApart: TranscriptCleanup.capSplitWindow + 1))
        XCTAssertNil(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "and I have like a hundred thousand", previousOrdinal: 2,
            nextText: "debit in my checking account", nextOrdinal: 1,
            secondsApart: -1))
    }

    func testCaselessScriptGivesNoEvidence() {
        // No lower case exists in the script — no signal, no join (the
        // conservative answer, same as TranscriptCleanup's).
        XCTAssertNil(MeetingSpeakerPolicy.inheritedOrdinal(
            previousText: "それで私たちは", previousOrdinal: 2,
            nextText: "続けました", nextOrdinal: 1,
            secondsApart: 6))
    }
}

// The duet minor merge — the 1:1 call whose second remote label is a dwarf
// of the first. Every number here is a measured session from the owner's
// logs, not an invented example.
final class DuetVerdictTests: XCTestCase {

    private func voice(_ ordinal: Int, entries: Int, seconds: Double,
                       renamed: Bool = false) -> MeetingSpeakerPolicy.Voice {
        MeetingSpeakerPolicy.Voice(ordinal: ordinal, entries: entries,
                                   seconds: seconds, renamed: renamed)
    }

    func testTheObservedCaseMerges() {
        // 2026-08-28 09:48, 15.6 min 1:1: voice 1 = 70 entries / 711 s,
        // voice 2 = 5 entries / 24 s, distance 0.837 — inside the 1.2× bar.
        let verdict = MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 70, seconds: 711),
                     voice(2, entries: 5, seconds: 24)],
            ceiling: 0.70) { _, _ in 0.837 }
        XCTAssertEqual(verdict?.outcome, .merge(into: 1, distance: 0.837))
    }

    func testComparableSharesAreTwoPeople() {
        // 2026-08-28 09:12: 274 s vs 113 s (41%) — possibly two real people,
        // whatever the distance says.
        XCTAssertNil(MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 13, seconds: 113),
                     voice(2, entries: 28, seconds: 274)],
            ceiling: 0.70) { _, _ in 0.60 })
    }

    func testDistantMinorStaysItself() {
        // 2026-08-24 shape at the measured 0.957 — outside even the 1.2× bar,
        // with the shares forced duet-shaped so ONLY the distance decides.
        let verdict = MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 40, seconds: 400),
                     voice(2, entries: 5, seconds: 29)],
            ceiling: 0.70) { _, _ in 0.957 }
        XCTAssertEqual(verdict?.outcome, .keepTooFar(nearest: 1, distance: 0.957))
    }

    func testAbsoluteCapProtectsLongCalls() {
        // An hour-long dominant makes 10% of it six minutes — a real person.
        // The 60 s absolute cap refuses regardless of share.
        XCTAssertNil(MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 300, seconds: 3600),
                     voice(2, entries: 12, seconds: 120)],
            ceiling: 0.70) { _, _ in 0.75 })
    }

    func testThreeVoicesAreAGroupCall() {
        XCTAssertNil(MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 70, seconds: 711),
                     voice(2, entries: 5, seconds: 24),
                     voice(3, entries: 8, seconds: 80)],
            ceiling: 0.70) { _, _ in 0.60 })
    }

    func testRenamedVoiceIsNeverJudged() {
        // A name is the strongest statement that this is a real person.
        XCTAssertNil(MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 70, seconds: 711),
                     voice(2, entries: 5, seconds: 24, renamed: true)],
            ceiling: 0.70) { _, _ in 0.60 })
    }

    func testRenamedDominantStillHosts() {
        // 2026-09-01 13:33, the Anya call: the owner named the DOMINANT voice
        // mid-call and the old both-unrenamed guard silently disarmed the
        // whole rule. A name on the dominant says nothing about the minor —
        // the 08-28 merge shape must still merge when only the host is named.
        let verdict = MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 70, seconds: 711, renamed: true),
                     voice(2, entries: 5, seconds: 24)],
            ceiling: 0.70) { _, _ in 0.837 }
        XCTAssertEqual(verdict?.outcome, .merge(into: 1, distance: 0.837))
    }

    func testMicroMinorIsTheOtherRulesCase() {
        // ≤2 entries and ≤10 s belongs to the micro rule; the duet rule
        // stands down so no voice is ever judged twice.
        XCTAssertNil(MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 70, seconds: 711),
                     voice(2, entries: 2, seconds: 8)],
            ceiling: 0.70) { _, _ in 0.60 })
    }

    func testUnmeasurableDistanceNeverGuesses() {
        let verdict = MeetingSpeakerPolicy.duetVerdict(
            voices: [voice(1, entries: 70, seconds: 711),
                     voice(2, entries: 5, seconds: 24)],
            ceiling: 0.70) { _, _ in nil }
        XCTAssertEqual(verdict?.outcome, .keepUnmeasured)
    }
}

// The collective fold — after a manual rename leaves the whole call side
// answering to one name, the "Them" lines follow it. Shapes are the owner's
// 2026-09-01 sessions, where the fold was performed by hand twice in a day.
final class CollectiveFoldTests: XCTestCase {

    func testOneNameFolds() {
        // The Anya call after both voices were renamed into her.
        XCTAssertEqual(MeetingSpeakerPolicy.collectiveFoldTarget(
            renamedTo: "Anya", voiceNames: ["Anya", "Anya"]), "Anya")
    }

    func testSingleVoiceCallFolds() {
        // A 1:1 where the diarizer produced one cluster: naming it is the
        // owner declaring the call side, and Them can only be that person.
        XCTAssertEqual(MeetingSpeakerPolicy.collectiveFoldTarget(
            renamedTo: "Steve", voiceNames: ["Steve"]), "Steve")
    }

    func testSecondNameBlocks() {
        // The morning call mid-cleanup: voice 1 is Steve, voice 2 still
        // numbered — the call side has not collapsed yet.
        XCTAssertNil(MeetingSpeakerPolicy.collectiveFoldTarget(
            renamedTo: "Steve", voiceNames: ["Steve", "Call · voice 2"]))
    }

    func testNoVoicesNothingToFold() {
        // Only collective lines exist: renaming Them itself is the ordinary
        // rename, not a fold — there is nobody to have collapsed into.
        XCTAssertNil(MeetingSpeakerPolicy.collectiveFoldTarget(
            renamedTo: "Anya", voiceNames: []))
    }

    func testEmptyNameNeverFolds() {
        XCTAssertNil(MeetingSpeakerPolicy.collectiveFoldTarget(
            renamedTo: "", voiceNames: [""]))
    }
}
