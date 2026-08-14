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

    // NOTE: the dominant-voice rule that used to live here is GONE
    // (2026-08-12). It labelled a whole window with the ONE voice that talked
    // most in it, on the assumption "windows are cut at pauses, so mixtures
    // are rare". Four real meetings disproved the assumption: a lively call
    // has no pauses, so the Them window is cut by the 15 s hard cap instead,
    // and the cap falls wherever it falls. The transcripts show two people
    // merged into one entry and chopped mid-sentence, with the continuation
    // filed under a different speaker (2026-08-12 10:01:17 / 10:01:32), while
    // the log said "no dominant voice" 93 times. The diarizer HAD the
    // boundaries and we threw them away — now the window is cut at them
    // (speakerSlices below).

    /// One voice's stretch as the diarizer reported it, in session-absolute
    /// seconds. Plain values so the rule stays free of FluidAudio types.
    struct SpeakerSpan: Equatable {
        let id: String
        let start: Double
        let end: Double

        init(id: String, start: Double, end: Double) {
            self.id = id; self.start = start; self.end = end
        }
    }

    /// A piece of an audio window that becomes exactly ONE transcript entry:
    /// one voice, its own start time, its own recognition.
    struct SpeakerSlice: Equatable {
        let id: String
        let start: Double
        let end: Double
    }

    /// Cuts one Them window into per-speaker slices.
    ///
    /// The slices PARTITION the window: no audio is dropped (a lost half-word
    /// is a lost half-word) and none is duplicated (overlapping slices would
    /// print the same sentence under two speakers). Boundaries land in the
    /// middle of the gap between two voices — the diarizer's own edges are
    /// approximate and the midpoint is the least-bad place to breathe.
    ///
    /// Spans shorter than `minSlice` are absorbed into a neighbour instead of
    /// becoming entries: a 0.3 s blip is a back-channel "ага" or a
    /// mis-attribution, and an entry per blip would shred the dialogue. The
    /// LONGER neighbour wins it, because a long stretch is the better-founded
    /// attribution of the two.
    ///
    /// Returns [] when the diarizer found no voice at all — the caller then
    /// keeps today's behaviour (one entry, collective label).
    static func speakerSlices(spans: [SpeakerSpan],
                              windowStart: Double, windowEnd: Double,
                              minSlice: Double = 1.0) -> [SpeakerSlice] {
        guard windowEnd > windowStart else { return [] }
        // Clamp to the window (the diarizer pads its last chunk) and drop
        // anything that survives as empty.
        let clamped = spans
            .map { SpeakerSpan(id: $0.id,
                               start: min(max($0.start, windowStart), windowEnd),
                               end: min(max($0.end, windowStart), windowEnd)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !clamped.isEmpty else { return [] }

        var runs = coalesce(clamped)
        // Absorb the too-short runs, one per pass: every absorption changes
        // the neighbours' lengths, so the decision has to be re-taken.
        while runs.count > 1, let i = runs.firstIndex(where: { $0.end - $0.start < minSlice }) {
            let prev = i > 0 ? runs[i - 1] : nil
            let next = i < runs.count - 1 ? runs[i + 1] : nil
            let intoPrev: Bool
            if prev == nil { intoPrev = false }
            else if next == nil { intoPrev = true }
            else { intoPrev = (prev!.end - prev!.start) >= (next!.end - next!.start) }
            if intoPrev {
                runs[i - 1] = SpeakerSlice(id: prev!.id, start: prev!.start, end: runs[i].end)
            } else {
                runs[i + 1] = SpeakerSlice(id: next!.id, start: runs[i].start, end: next!.end)
            }
            runs.remove(at: i)
            // Absorbing can put two stretches of the same voice side by side.
            runs = coalesce(runs.map { SpeakerSpan(id: $0.id, start: $0.start, end: $0.end) })
        }

        // Snap the boundaries: the first slice starts where the window does,
        // the last ends where it ends, and every seam sits at the midpoint of
        // the gap — the same value for both neighbours, so the partition is
        // exact.
        return runs.enumerated().map { i, run in
            let start = i == 0 ? windowStart : (runs[i - 1].end + run.start) / 2
            let end = i == runs.count - 1 ? windowEnd : (run.end + runs[i + 1].start) / 2
            return SpeakerSlice(id: run.id, start: start, end: end)
        }.filter { $0.end > $0.start }
    }

    /// Merges consecutive spans of one voice; a span swallowed by the one
    /// before it (crosstalk — two voices reported over the same seconds) is
    /// dropped, the voice already holding the floor keeps it.
    private static func coalesce(_ spans: [SpeakerSpan]) -> [SpeakerSlice] {
        var runs: [SpeakerSlice] = []
        for span in spans {
            guard let last = runs.last else {
                runs.append(SpeakerSlice(id: span.id, start: span.start, end: span.end))
                continue
            }
            if last.id == span.id {
                runs[runs.count - 1] = SpeakerSlice(id: last.id, start: last.start,
                                                    end: max(last.end, span.end))
            } else if span.end <= last.end {
                continue
            } else {
                runs.append(SpeakerSlice(id: span.id,
                                         start: max(span.start, last.end), end: span.end))
            }
        }
        return runs
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

    /// Everything the phantom rule is allowed to look at: what the DECODER
    /// thought of its own output plus what Silero heard in the same audio.
    /// Deliberately no words and no phrases — the owner rejected a blocklist
    /// (2026-08-10) because it would also delete the real "Thank you" a
    /// participant says, and a blocklist is a per-language chore forever.
    struct SpeechEvidence: Equatable {
        /// Whisper's own P(this audio contains no speech), duration-weighted
        /// across the decoded segments.
        let noSpeechProb: Double
        /// Whisper's own mean token log-probability (0 = certain), likewise
        /// duration-weighted.
        let avgLogprob: Double
        /// gzip-style ratio of the produced text — Whisper's own detector for
        /// a decoder stuck in a loop.
        let compressionRatio: Double
        /// Words in the produced text.
        let words: Int
        /// Seconds of audio actually handed to the model.
        let audioSeconds: Double
        /// Silero's 256 ms chunk verdicts over the same audio; nil when the
        /// VAD was unavailable (then only the model's own signals count).
        let voicedChunks: Int?
    }

    enum PhantomVerdict: Equatable {
        case keep
        /// Rejected — the string is the reason, logged next to the numbers.
        case reject(String)
    }

    /// Whether a finished recognition is a phantom: a phrase Whisper invented
    /// to explain audio that held no speech. Real evidence from four meetings:
    /// 14–20 micro-entries each, "Thank you." ×11–15, bare "you", bare "." —
    /// and the 2026-08-12 10:00 transcript OPENS with two phantom "Thank you."
    /// lines before anyone had spoken.
    ///
    /// Every rule below is a conjunction of independent signals, because the
    /// asymmetry is not symmetric: dropping a real curt "Да." is worse than
    /// keeping one phantom. Whisper's own numbers alone are not enough — a
    /// phantom is often decoded CONFIDENTLY (that is what "hallucination"
    /// means here) — so the model's no-speech estimate is the load-bearing
    /// signal and the rest only guards it.
    static func phantomVerdict(_ e: SpeechEvidence) -> PhantomVerdict {
        // (1) Whisper's own reference rule, with its own default constants
        // (no_speech_threshold 0.6, logprob_threshold −1.0): the model says
        // "probably no speech" AND is unsure of what it wrote. openai/whisper
        // drops such segments outright; WhisperKit hands us the numbers and
        // leaves the call to us. Length-independent because the vendor's is:
        // a long unsure passage over non-speech is noise either way.
        if e.noSpeechProb >= 0.6, e.avgLogprob < -1.0 { return .reject("silence") }

        // (2) The confident phantom, the class that actually reaches the
        // owner's transcripts. The model itself puts ≥85% on "no speech
        // here" and still produced a micro-phrase. 0.85 is far above the
        // vendor's own 0.6 bar precisely so a real short reply — which the
        // model scores well BELOW 0.6 — cannot land here; ≤3 words keeps the
        // blast radius at one line.
        if e.words <= 3, e.noSpeechProb >= 0.85 { return .reject("no speech") }

        // (3) The breath signature, now caught at the OUTPUT. The input gate
        // (windowWorthTranscribing) already refuses windows with fewer than 2
        // voiced chunks; this catches the ones that squeak past with barely
        // more: ≥3 s of audio in which Silero heard at most ~0.5 s of voice,
        // and the model still produced one or two words. A genuine curt reply
        // occupies a SHORT slice, which is why the 3 s floor is what protects
        // it (and why this rule got safer once windows are cut per speaker).
        if e.words <= 2, e.audioSeconds >= 3, let voiced = e.voicedChunks, voiced <= 2 {
            return .reject("too little voice")
        }

        // (4) Decoder stuck in a loop ("okay okay okay…"). Whisper's own
        // degenerate bar is 2.4; we take 3.0 — a 25% margin — because here it
        // deletes a whole entry rather than triggering a re-decode, and
        // ordinary prose sits at 1.2–2.0. ≥6 words because the ratio is noise
        // on very short strings.
        if e.words >= 6, e.compressionRatio >= 3.0 { return .reject("repetition") }

        return .keep
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
