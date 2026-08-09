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
    static func windowVerdict(accumulated: Double, hadSpeech: Bool, sinceLoud: Double,
                              minChunk: Double = 2.0, silenceCut: Double = 0.8,
                              hardCap: Double = 15, silentReset: Double = 10) -> WindowVerdict {
        if !hadSpeech {
            return accumulated >= silentReset ? .dropSilence : .keep
        }
        guard accumulated >= minChunk else { return .keep }
        if accumulated >= hardCap { return .cutTranscribe }
        return sinceLoud >= silenceCut ? .cutTranscribe : .keep
    }

    /// Adaptive "is this speech or just the room" for the mic channel. A
    /// fixed level threshold broke on the FIRST field test: a mic held by
    /// the meeting app goes through the no-AEC AVCaptureSession path, whose
    /// raw noise floor sits ABOVE the fixed threshold — pauses never
    /// registered and windows only cut at the hard cap (live log 2026-08-09
    /// 15:48). Track the floor (drops instantly, rises slowly) and demand a
    /// clear margin over it.
    static func updatedNoiseFloor(_ floor: Double, level: Double) -> Double {
        min(max(level, 0.001), floor * 1.05 + 0.0005)
    }

    static func isLoud(level: Double, floor: Double) -> Bool {
        level >= max(0.08, floor * 1.7)
    }

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
