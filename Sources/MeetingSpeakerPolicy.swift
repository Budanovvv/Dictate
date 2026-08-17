import Foundation

/// The diarizer's judgement in plain numbers: the clustering threshold a
/// session runs at, and the end-of-session decision about voices that barely
/// spoke.
///
/// Dependency-free ON PURPOSE, the `DictationPolicy` pattern: `MeetingDiarizer`
/// cannot be compiled into the test target (it imports FluidAudio), so the
/// judgement is lifted out of it into plain numbers and the diarizer keeps only
/// the thin adapter that measures the live voice database and applies the
/// result. That matters more here than usual: **we keep no meeting audio**, so
/// this rule can never be re-run over a past meeting. A unit test with
/// hand-written measurements is the only proof of its behaviour that exists.
///
/// The problem it solves (ground truth from the owner, 2026-08-11/12): three
/// meetings with three people each — two voices on the tap channel — came out
/// as four, four and three labels, and twice the extra label held a SINGLE
/// entry in a whole meeting. A voice that says one thing in fifty minutes is
/// almost never a person; it is a fragment shed by somebody else at a moment
/// when their cluster had not yet settled. The rule finds those fragments by
/// their measurements and hands them back to the voice they are acoustically
/// nearest — but only when the acoustics agree, never on the count alone.
enum MeetingSpeakerPolicy {

    /// One voice as the finished transcript actually shows it.
    struct Voice: Equatable, Sendable {
        /// The session-local number ("Speaker 3" → 3).
        let ordinal: Int
        /// Entries this voice has IN THE FILE — rejected phantoms and skipped
        /// turns are not here, which is what makes this the transcript's own
        /// account rather than the diarizer's.
        let entries: Int
        /// Seconds of audio those entries were decoded from.
        let seconds: Double
        /// The owner renamed this voice by hand during the session. A name is
        /// the strongest statement available that this is a real person, and
        /// it is never overruled by acoustics.
        var renamed: Bool = false

        init(ordinal: Int, entries: Int, seconds: Double, renamed: Bool = false) {
            self.ordinal = ordinal
            self.entries = entries
            self.seconds = seconds
            self.renamed = renamed
        }
    }

    /// What was decided for one micro-cluster. Every case except `.merge`
    /// leaves the transcript exactly as it was — the default is always to keep
    /// the extra label, which the owner can rename in one click.
    enum Outcome: Equatable, Sendable {
        /// Merge into that voice; the distance is the measured one.
        case merge(into: Int, distance: Double)
        /// Nothing to merge into: every voice in the session is a
        /// micro-cluster, or there is only one voice at all. Merging two
        /// fragments into each other would create a voice nobody has ever
        /// verified, so this case does nothing by design.
        case keepNoHost
        /// The voice database could not give an embedding for one of the two
        /// sides, so no distance exists. Never guess in that case.
        case keepUnmeasured
        /// The nearest real voice is further away than the ceiling — this may
        /// well be a genuinely distinct person who only spoke once, and those
        /// must survive. Logged with the distance: these refusals are the data
        /// that says whether the ceiling sits right.
        case keepTooFar(nearest: Int, distance: Double)
    }

    struct Verdict: Equatable, Sendable {
        let voice: Voice
        let outcome: Outcome
    }

    /// Entries a voice may have and still count as a fragment.
    ///
    /// Two, not one: the observed phantoms held one entry, and a torn sentence
    /// produces exactly one fragment per tear, so a voice that appeared twice
    /// is already the second-most likely thing to be an artefact. Three would
    /// start covering real people — a participant who joins late and says two
    /// sentences plus a goodbye is a normal meeting, not an artefact.
    static let maxEntries = 2

    /// Total speech a voice may hold and still count as a fragment.
    ///
    /// A Them window is capped at 15 s (MeetingPolicy.windowVerdict) and a turn
    /// slice is a piece of one window, so 10 s means "everything this voice
    /// ever said would fit inside a single window with room to spare" — it
    /// never sustained a turn. Two entries of eight seconds each (16 s) is a
    /// person making two short remarks; that survives.
    static let maxSeconds: Double = 10

    /// Is this voice small enough to be *considered* for a merge? Smallness
    /// alone never merges anything — it only limits the blast radius of the
    /// acoustic test that follows.
    static func isMicro(_ voice: Voice) -> Bool {
        !voice.renamed && voice.entries > 0
            && voice.entries <= maxEntries && voice.seconds <= maxSeconds
    }

    /// Decides, for every micro-cluster, whether it goes back into a real
    /// voice. Voices that are not micro-clusters get no verdict — they are
    /// untouched, and their numbering does not change (see the note below).
    ///
    /// - Parameters:
    ///   - voices: every numbered voice of the session, as the file shows it.
    ///   - ceiling: the largest embedding distance that still counts as "the
    ///     same voice" (MeetingDiarizer.mergeCeiling).
    ///   - distance: measured embedding distance between two ordinals; nil
    ///     when the voice database cannot answer.
    ///
    /// Two properties this function guarantees, both of them safety rules:
    /// a micro-cluster can only ever merge INTO a non-micro voice (so two
    /// fragments cannot merge into each other and no chain can form), and all
    /// verdicts are computed against the ORIGINAL set of voices, so the result
    /// does not depend on the order they are processed in.
    static func verdicts(voices: [Voice], ceiling: Double,
                         distance: (Int, Int) -> Double?) -> [Verdict] {
        // A voice with no entries at all hosts nothing: it has no words in the
        // file to lend its name to, and no evidence behind it.
        let hosts = voices
            .filter { !isMicro($0) && $0.entries > 0 }
            .sorted { $0.ordinal < $1.ordinal }
        return voices
            .filter(isMicro)
            .sorted { $0.ordinal < $1.ordinal }
            .map { small in
                guard !hosts.isEmpty else {
                    return Verdict(voice: small, outcome: .keepNoHost)
                }
                let measured = hosts.compactMap { host -> (Int, Double)? in
                    guard host.ordinal != small.ordinal,
                          let d = distance(small.ordinal, host.ordinal),
                          d.isFinite else { return nil }
                    return (host.ordinal, d)
                }
                guard let best = measured.min(by: { $0.1 < $1.1 }) else {
                    return Verdict(voice: small, outcome: .keepUnmeasured)
                }
                return Verdict(voice: small,
                               outcome: best.1 <= ceiling
                                   ? .merge(into: best.0, distance: best.1)
                                   : .keepTooFar(nearest: best.0, distance: best.1))
            }
    }

    // MARK: - Lexical label inheritance

    /// The words themselves overrule the embeddings: when one voice stops
    /// mid-sentence and the "other" voice finishes that very sentence, they
    /// are one person the diarizer tore in two.
    ///
    /// Measured on the live meeting of 2026-08-17 (owner's ground truth:
    /// two people on the tap channel, the diarizer wrote four): the split
    /// pair sat at cosine distance 0.847 while the two REAL people sat at
    /// 0.844 — acoustics cannot tell these cases apart even in hindsight,
    /// so no threshold and no re-clustering can fix it. The transcript
    /// could: ten of the torn fragments opened in lower case, most of the
    /// rest continued a line that had stopped without a full stop.
    ///
    /// The evidence read here is exactly `TranscriptCleanup.isCapSplit`'s —
    /// the rule behind 144 correct joins and zero wrong ones — applied
    /// across a label boundary instead of within one. All three signals are
    /// required, because a wrong inheritance steals words from a real
    /// person: an unfinished line followed by a CAPITAL is somebody being
    /// interrupted, and that is a genuine speaker change.
    ///
    /// - Parameters:
    ///   - previousText/previousOrdinal: the last entry written on the tap
    ///     channel. A collective entry (nil ordinal) inherits nothing and
    ///     breaks the chain — there is no voice to hand over.
    ///   - nextText/nextOrdinal: the entry about to be written.
    ///   - secondsApart: start-to-start, the same clock `isCapSplit` reads.
    /// - Returns: the ordinal the next entry should be written under, or
    ///   nil to leave it exactly as the diarizer said.
    static func inheritedOrdinal(previousText: String, previousOrdinal: Int?,
                                 nextText: String, nextOrdinal: Int?,
                                 secondsApart: TimeInterval) -> Int? {
        guard let host = previousOrdinal, nextOrdinal != host,
              secondsApart >= 0, secondsApart <= TranscriptCleanup.capSplitWindow,
              !TranscriptCleanup.endsSentence(previousText),
              TranscriptCleanup.startsLowercase(nextText) else { return nil }
        return host
    }

    // MARK: - The clustering threshold (hidden calibration knob)

    /// The compiled clustering threshold — FluidAudio's own default.
    ///
    /// It is a HYPOTHESIS, not a measurement, and that is precisely why the
    /// override below exists. Every ground truth we have says the diarizer
    /// over-segments: three meetings with confirmed head counts (11.08 "AI
    /// system onboarding", 12.08 "Agent Discussion", 12.08 "Pharmaceutical
    /// Diet Presentation" — three people each, so exactly two voices on the
    /// tap channel) came out with too many labels, and a controlled bench on
    /// 2026-08-14 — 8.6 minutes of a two-person podcast played through
    /// headphones into the app, 36 diarized windows — produced THREE voices
    /// (265 s / 132 s / 114 s) with one sentence visibly torn across a
    /// "speaker change". Lowering it to 0.62 in August made things worse, so
    /// the right value is somewhere ABOVE 0.7 and nobody knows where.
    ///
    /// Micro-cluster merging cannot rescue this: a second of the podcast bench
    /// held 132 seconds of speech, which is half a person, not a fragment.
    /// The number has to be MEASURED, and measuring means trying several
    /// values against the bench — hence a runtime knob instead of a rebuild
    /// per attempt. This constant stays 0.7 until the bench says otherwise.
    static let defaultClusteringThreshold: Float = 0.7

    /// The hidden default that overrides it, the `liveTyping` precedent
    /// (CONTEXT item 5н): experiments that must not reach the UI live in
    /// `defaults`. `defaults write com.valentynbudanov.Dictate diarThreshold
    /// -float 0.8`, read ONCE per process.
    static let thresholdKey = "diarThreshold"

    /// Values the knob will actually honour.
    ///
    /// The threshold is a COSINE DISTANCE between speaker embeddings (0 = the
    /// same recording, 2 = the theoretical opposite), so the raw type happily
    /// accepts numbers that destroy diarization outright. Both ends are hard
    /// failure modes, not matters of taste:
    ///
    /// * below 0.3 every window drifts into a fresh label — the 0.62 run
    ///   already over-segmented badly, and 0 would make each utterance its own
    ///   "speaker";
    /// * above 0.95 everyone collapses into one voice — FluidAudio derives its
    ///   runtime bar as `speakerThreshold = clusteringThreshold * 1.2`, so 0.95
    ///   already means "1.14 apart still counts as the same person", and it is
    ///   also our `mergeCeiling`, i.e. a fat value would let the end-of-session
    ///   merge swallow real people wholesale.
    ///
    /// Anything outside is treated as a typo and REFUSED — the compiled
    /// default runs instead, and the refusal is logged. Silently clamping a
    /// stray `2.0` to 0.95 would be worse than useless: the log would then
    /// claim a value the owner never asked for, and a calibration bench whose
    /// records lie is not a bench.
    static let thresholdRange: ClosedRange<Float> = 0.3...0.95

    /// Where the threshold in force came from — carried into the logs so a
    /// transcript can always be traced back to the value that produced it.
    enum ThresholdSource: Equatable, Sendable {
        /// No usable override: the compiled default is in force.
        case compiled
        /// The hidden default was set, and accepted.
        case override(Double)
        /// The hidden default was set to something unusable (out of range, or
        /// not a number at all — a key written as text reads back as 0). The
        /// compiled default is in force and the log says so.
        case rejected(Double)
    }

    struct Threshold: Equatable, Sendable {
        let value: Float
        let source: ThresholdSource
    }

    /// Resolves the threshold a session will run at.
    ///
    /// Pure on purpose (the `verdicts` reasoning): `MeetingDiarizer` imports
    /// FluidAudio and cannot be compiled into the test target, so the guard
    /// that keeps a stray `defaults write` from breaking diarization is tested
    /// here on plain numbers.
    ///
    /// - Parameter override: the raw value of `thresholdKey`, or nil when the
    ///   key is absent.
    static func threshold(override raw: Double?) -> Threshold {
        guard let raw else {
            return Threshold(value: defaultClusteringThreshold, source: .compiled)
        }
        let value = Float(raw)
        guard raw.isFinite, value.isFinite, thresholdRange.contains(value) else {
            return Threshold(value: defaultClusteringThreshold, source: .rejected(raw))
        }
        return Threshold(value: value, source: .override(raw))
    }

    /// How the threshold is written in the log — short enough to sit inside the
    /// end-of-session summary line, explicit enough that a refused override is
    /// impossible to miss.
    static func describe(_ threshold: Threshold) -> String {
        switch threshold.source {
        case .compiled:
            return String(format: "%.2f", threshold.value)
        case .override:
            return String(format: "%.2f (%@ override)", threshold.value, thresholdKey)
        case .rejected(let raw):
            return String(format: "%.2f (%@=%g REFUSED, outside %g…%g)",
                          threshold.value, thresholdKey, raw,
                          thresholdRange.lowerBound, thresholdRange.upperBound)
        }
    }

    // NUMBERING AFTER A MERGE: the survivors keep the numbers they have, and a
    // merged-away number simply disappears (1, 2, 4 is a possible result).
    // Renumbering would mean a second sweep of renames across a transcript that
    // is already written and possibly already open in front of the owner, it
    // would collide with any voice he renamed by hand mid-session, and it would
    // buy nothing: the numbers are arbitrary ordinals meaning "distinct voices
    // in order of appearance", not a count of people. The merge log names both
    // labels, so a gap is always explained.
}
