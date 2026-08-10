import Foundation

/// Pure decision rules of the meeting transcript, extracted for direct unit
/// testing (same pattern as DictationPolicy). Two decisions live here: when a
/// channel's accumulating audio window is cut for transcription, and when
/// transcript entries are safe to write out in speaker order.
enum MeetingPolicy {

    enum WindowVerdict {
        /// Keep accumulating.
        case keep
        /// Cut the window and transcribe it (it contains speech).
        case cutTranscribe
        /// Reset the window without transcribing (nothing but silence).
        case dropSilence
    }

    /// A window is cut at a natural pause — trailing silence after speech —
    /// so Whisper gets whole utterances; a hard cap bounds the recognition
    /// latency of an uninterrupted monologue; pure silence is dropped
    /// periodically so a quiet channel never grows an hour-long buffer.
    // silenceCut 1.1 s: 0.8 s cut mid-thought on the owner's reflective
    // pauses ("Но оно, конечно, не нравится." / "как-то не дослушивает" —
    // one sentence split in two, field test 2026-08-09 16:25). +0.3 s of
    // latency buys whole thoughts.
    static func windowVerdict(accumulated: Double, hadSpeech: Bool, sinceLoud: Double,
                              minChunk: Double = 2.0, silenceCut: Double = 1.1,
                              hardCap: Double = 15, silentReset: Double = 10) -> WindowVerdict {
        if !hadSpeech {
            return accumulated >= silentReset ? .dropSilence : .keep
        }
        guard accumulated >= minChunk else { return .keep }
        if accumulated >= hardCap { return .cutTranscribe }
        return sinceLoud >= silenceCut ? .cutTranscribe : .keep
    }

    // NOTE: there is deliberately NO call-end auto-stop rule here. It was
    // built, field-tested and REMOVED (owner's call, 2026-08-10): the
    // mic-holder enumeration counts always-listening system daemons
    // (corespeechd), so "mic free" never held and the rule was inert — and
    // an inert rule that can only misfire mid-call is worse than the honest
    // model "stopping is manual, the red menu-bar dot reminds you". The
    // return design (a daemon-free userAppsRunningInput) lives in GRABLI.

    // NOTE: pause detection deliberately has NO energy-threshold helpers
    // here. Fixed 0.08 failed on the no-AEC busy-mic path, and an adaptive
    // noise floor failed the same afternoon (the owner out-talked it) —
    // windows are cut by Silero VAD verdicts over the window tail instead
    // (see MeetingSession.scheduleTailChecks and GRABLI).

    /// The voice that talked most within one utterance window labels the
    /// whole window — windows are cut at pauses, so mixtures are rare and
    /// short. Deterministic tie-break (smaller id) keeps tests stable.
    static func dominantSpeakerId(durations: [String: Double]) -> String? {
        durations.min { a, b in
            a.value > b.value || (a.value == b.value && a.key < b.key)
        }?.key
    }

    /// Whether a cut window holds enough ACTUAL speech to be worth waking
    /// Whisper. The dictation gate's "any voiced chunk" bar is wrong for a
    /// continuous channel: a 10 s remote window with one breath-like blip
    /// (1 voiced chunk of 39) passed to Whisper, which explained the
    /// near-silence with its favorite phantom — three "Thank you." entries
    /// in the first real meeting (2026-08-10 09:19). Two voiced chunks
    /// (~0.5 s of speech) keep a curt real "Да." while dropping breaths;
    /// the fix is at the INPUT — no output blocklists.
    static func windowWorthTranscribing(voicedChunks: Int) -> Bool {
        voicedChunks >= 2
    }

    /// What a channel contributes to the flush frontier. A window WITH
    /// speech pins it at the first speech moment — that is the start its
    /// eventual entry will carry. A silent window must NOT pin anything to
    /// its (possibly ancient) window start: entries were held hostage for up
    /// to the 10 s silent-reset and then dumped in a batch (field feedback
    /// 2026-08-09 17:25 — "накапливает и вываливает кучей"). It only vouches
    /// for the recent past: speech the VAD hasn't noticed yet can be at most
    /// vadLag old, so anything older is safe to flush.
    static func channelFrontier(windowStart: TimeInterval, firstSpeechAt: TimeInterval?,
                                now: TimeInterval, vadLag: TimeInterval = 2.5) -> TimeInterval {
        if let first = firstSpeechAt, first >= windowStart { return first }
        return now - vadLag
    }

    /// How many of the pending entries (sorted by window start) may be
    /// written out now. An entry is final only when no channel can still
    /// produce an EARLIER entry: both channels' current windows started after
    /// it, and no in-flight recognition covers an earlier window. Without
    /// this, a slow recognition of an early chunk would appear after a fast
    /// later one and the dialogue order would scramble.
    static func flushableCount(sortedStarts: [Double],
                               channelFrontiers: [Double],
                               inflightStarts: [Double]) -> Int {
        let frontier = min(channelFrontiers.min() ?? .infinity,
                           inflightStarts.min() ?? .infinity)
        var count = 0
        for start in sortedStarts {
            guard start < frontier else { break }
            count += 1
        }
        return count
    }
}
