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

    /// Whether the call this session was recording has most likely ended —
    /// the auto-stop rule. Two independent signals must BOTH hold for the
    /// threshold: no other app has held the mic (the meeting app releases it
    /// when the call ends) and the remote channel has heard no speech. The
    /// sawForeignHold gate keeps a room recording (no browser call — the mic
    /// was never held by anyone else) on manual stop only: for it, "mic
    /// free" proves nothing. Privacy rationale: silently recording the room
    /// AFTER a call is the worst failure mode; a false stop costs one click.
    static func callLikelyOver(sawForeignHold: Bool,
                               micFreeFor: TimeInterval,
                               remoteQuietFor: TimeInterval,
                               threshold: TimeInterval = 60) -> Bool {
        sawForeignHold && micFreeFor >= threshold && remoteQuietFor >= threshold
    }

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
