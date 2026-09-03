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
    /// The longest Them window we will hand to the diarizer — and it is the
    /// segmentation model's own input length, not a taste.
    ///
    /// `pyannote_segmentation.mlmodelc` takes a FIXED `[1, 1, 160000]` input
    /// with `hasShapeFlexibility = 0`: exactly 10.000 s at 16 kHz. Anything
    /// longer is chunked internally by FluidAudio (`chunkDuration` 10 s,
    /// `chunkOverlap` 0 by default), and the LAST chunk is zero-padded to
    /// length. A padded chunk shorter than ~7 s yields an embedding computed
    /// mostly over silence, which clusters as a DIFFERENT PERSON — one voice
    /// torn into two, over and over.
    ///
    /// The old cap of 15 s left a 5 s tail, which is the worst end of that
    /// range. Measured on a dumped 40-minute meeting (bench:
    /// a local diarization bench; ground truth from the owner —
    /// one participant did 80–90% of the talking):
    ///
    ///   15 s cap: 857 / 539 / 141 s per voice (56/35/9%), 70% of windows
    ///             split — two near-equal speakers who did not exist;
    ///   10 s cap: 1281 / 212 / 22 s (85/14/1%), 6% split — the meeting as
    ///             it actually happened.
    ///
    /// 10 s rather than something safely smaller: at 5 s windows the embedder
    /// found ONE voice in ten minutes — too little audio to tell people
    /// apart. This is the largest window that still fits in one chunk, so a
    /// zero-padded tail cannot exist at any real window length.
    ///
    /// Only Them is capped this way. The You channel never reaches the
    /// diarizer (the mic IS one known voice), so cutting it more often would
    /// buy nothing and only shorten its entries.
    static let themWindowCap: Double = 10

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

    // NOTE on auto-stop history: a call-end rule keyed on "the microphone is
    // free" was built, field-tested and REMOVED (owner's call, 2026-08-10) —
    // the mic-holder enumeration counts always-listening system daemons
    // (corespeechd), so "mic free" never held and the rule was inert. The
    // rule that exists today (shouldAutoStop below, owner's ask 2026-08-29)
    // uses a DIFFERENT signal immune to that failure: recognized speech on
    // the call channel going silent — daemons do not talk.

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

    /// Whether a transcription said anything at all. Whisper occasionally
    /// exhales bare punctuation — "-", ".", "…" — as a whole result; the
    /// audio was real speech-like sound, so the phantom gate above rightly
    /// keeps it, and the transcript gets an entry that says nothing (two in
    /// the meeting of 2026-08-27). No letter, no digit → not an entry.
    static func saidAnything(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: - Cutting a finished meeting into sections

    /// Everything the section rule is allowed to look at about one transcript
    /// line. Plain values, like SpeakerSpan above: the rule is a pure decision
    /// and must be testable without a transcript, a file or a model.
    struct SectionMark: Equatable {
        /// Seconds since midnight — the stamp the entry carries in the file.
        let start: Double
        let speaker: String
        /// Words in the entry, the only thing standing in for its duration.
        let words: Int
        /// The text ends on `.`, `!`, `?` or `…` — a thought that finished.
        let endsSentence: Bool
        /// The text's first letter is a capital — a thought that begins.
        let startsSentence: Bool
    }

    /// How long a section wants to be. Four minutes is what the owner asked
    /// for ("~3–5 min"), and it is also what makes the excerpt of a section
    /// fit the model's window whole: the densest meeting in the archive runs
    /// at 140 words a minute, so four minutes is ~560 words — about 3.4 KB,
    /// where a whole meeting is 45–55 KB and cannot be read at all.
    static let sectionTarget: Double = 240
    /// Shorter than this and a section is a paragraph, not a subject; the
    /// meeting's own summary already covers that ground.
    static let sectionMinimum: Double = 150
    /// Longer than this and one line cannot honestly describe it.
    static let sectionMaximum: Double = 390

    /// How finely a meeting is cut, as the reader asked for it.
    ///
    /// This exists because of what the segmentation literature actually
    /// measures: getting the NUMBER of sections right dominates getting their
    /// positions right — evenly spacing the correct count scores close to a
    /// tuned model, and the boundary metrics turn out to be driven mostly by
    /// granularity rather than by detection quality. So the highest-value
    /// control is not a better seam-finder, it is letting the person say how
    /// many they want. Descript reached the same conclusion and asks outright.
    ///
    /// `standard` is the middle on purpose: two independent YouTube-scale
    /// corpora put the human habit at a chapter every 2–2.5 minutes, which is
    /// where this already sat. The other two bracket it rather than replacing
    /// it — one for a long call you want a map of, one for a short one you
    /// want to walk through.
    enum SectionDetail: Int, CaseIterable {
        case coarse = 0, standard = 1, fine = 2

        /// The floor a section has to clear, in seconds.
        var minimum: Double {
            switch self {
            case .coarse: return 300
            case .standard: return sectionMinimum
            case .fine: return 90
            }
        }

        /// And what it aims for, so the target moves with the floor instead of
        /// fighting it: a 90-second floor under a 240-second target would just
        /// produce 240-second sections with a lower bar nobody reaches.
        var target: Double {
            switch self {
            case .coarse: return 420
            case .standard: return sectionTarget
            case .fine: return 150
            }
        }

        var maximum: Double {
            switch self {
            case .coarse: return 660
            case .standard: return sectionMaximum
            case .fine: return 240
            }
        }
    }

    /// Where the sections of a finished meeting start — indices into `marks`,
    /// the first of which is always 0.
    ///
    /// A note on what this rule does NOT use, because the obvious design does
    /// not survive contact with our own transcripts. Entry timestamps are
    /// WINDOW starts, and a window is cut either at a VAD pause or at the 15 s
    /// hard cap, so the interval between two entries is mostly the length of
    /// the first one rather than a silence. Measured across the archive
    /// (2026-08-14): median gap 5–9 s, p95 15–16 s — which is the cap — and
    /// exactly three gaps in eighteen transcripts exceed 20 s. The biggest
    /// "silences" that do exist are artifacts: a one-word phantom ("Thank
    /// you.", "Merci.") alone in a 15 s window. Speaker turnover is no better:
    /// 56–79% of adjacent entries already change speaker in a live call.
    ///
    /// So the BUDGET is load-bearing and the text signals only choose between
    /// the candidates it allows. Among the entries that would make a section
    /// of an acceptable length, the one with the best seam wins — and the seam
    /// that earned its keep is "the next entry starts with a capital": adding
    /// it removed most of the sections that used to open mid-sentence.
    ///
    /// Returns [] when the meeting cannot yield at least two sections. One
    /// section is the whole-meeting summary again, written twice.
    static func sectionStarts(_ marks: [SectionMark],
                              target: Double = sectionTarget,
                              minimum: Double = sectionMinimum,
                              maximum: Double = sectionMaximum) -> [Int] {
        guard marks.count >= 2, let first = marks.first, let last = marks.last,
              last.start - first.start >= 2 * minimum else { return [] }
        var starts = [0]
        var current = 0
        while true {
            let from = marks[current].start
            var best: Int?
            var bestScore = -Double.infinity
            var index = current + 1
            while index < marks.count {
                let length = marks[index].start - from
                if length > maximum { break }
                if length >= minimum {
                    let score = seam(marks, at: index)
                        - deviationWeight * abs(length - target) / target
                    if score > bestScore { bestScore = score; best = index }
                }
                index += 1
            }
            guard let cut = best else { break }
            // Never leave a stub behind: what follows the cut has to be worth
            // a line of its own, or the cut is not worth making.
            guard last.start - marks[cut].start >= minimum * tailShare else { break }
            starts.append(cut)
            current = cut
        }
        return starts.count >= 2 ? starts : []
    }

    /// How hard the budget pulls the cut back towards `target`. High enough
    /// that a perfect seam cannot drag a section to either extreme of the
    /// admissible range on its own (the seam is worth at most 2.5).
    private static let deviationWeight = 1.5
    /// The last section may be shorter than `minimum` — but not by much, or
    /// it is a stub with nothing to say.
    private static let tailShare = 0.6

    /// How good a place this is to start a new section, 0 to 2.5. Every term
    /// is something the transcript already carries; none of it is a guess the
    /// model makes.
    private static func seam(_ marks: [SectionMark], at index: Int) -> Double {
        let previous = marks[index - 1], next = marks[index]
        var score = 0.0
        // Whatever silence can be inferred: the interval minus the speech the
        // previous entry plausibly holds. Weak evidence (see above), so it is
        // worth at most as much as the two punctuation signals together.
        let gap = next.start - previous.start
        let spoken = min(windowCap, Double(previous.words) / wordsPerSecond)
        score += min(1, max(0, (gap - spoken) / silenceSpread))
        // A quarter, not a half. Ablated on spoken content (arXiv:2602.08979,
        // YTSeg): adding pause information to a text baseline is worth +2.87
        // F1, adding speaker features +0.67 — pause carries about four times
        // the weight, where this used to give it two. The comment above
        // already suspected as much from our own data (56–79% of adjacent
        // entries change speaker anyway, so the signal barely discriminates);
        // this is the outside number that agrees.
        //
        // The same ablation is why there is no pitch term here and never will
        // be: prosodic F0 was the one feature that made results WORSE (−0.53).
        if previous.speaker != next.speaker { score += 0.25 }
        if previous.endsSentence { score += 0.5 }
        if next.startsSentence { score += 0.5 }
        return score
    }

    /// Ordinary speech, for turning a word count back into seconds.
    private static let wordsPerSecond = 2.6
    /// No entry can hold more speech than the window cap that produced it.
    private static let windowCap: Double = 15
    /// The inferred silence at which the term is worth its full point.
    private static let silenceSpread: Double = 8

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

    // MARK: - The forgotten recording

    /// What the auto-stop check decided, and why — the reason goes into the
    /// log and the transcript's closing marker, so every stop can be audited
    /// against the call it ended.
    enum AutoStopVerdict: Equatable {
        case keep
        /// The call's process released the microphone and stayed away.
        case callEnded
        /// Nothing recognisable as a call around, and nobody has spoken.
        case deadAir
    }

    /// How long a vanished call process must STAY vanished (and the air stay
    /// quiet) before the recording ends itself. Bench-measured on the HAL
    /// (2026-08-29, standalone probes): a released or crashed holder leaves
    /// the process list within one second and the signal never flaps — so
    /// ninety seconds is pure reconnect insurance, not measurement slack.
    static let callEndGrace: TimeInterval = 90

    /// The backstop for sessions with no recognisable call around them
    /// (unknown VoIP apps, phone on speaker, room recordings): this long
    /// without a single voiced window on ANY channel ends the recording. Ten
    /// minutes is deliberately conservative — the market's silence backstops
    /// run up to an hour, and a silence-only signal must never beat a person
    /// to the button.
    static let deadAirStop: TimeInterval = 10 * 60

    /// The forgotten-recording rule, hardened after the weak-case review
    /// (2026-08-29). The INVARIANT does the safety work: while any call
    /// process is holding the microphone the recording never stops itself —
    /// a hold, a silent co-working call and a document-reading pause are all
    /// legitimate silence. Everything below the invariant only runs once no
    /// call is in sight.
    ///
    /// - platformAliveNow: a call app — or a browser, REGARDLESS of which
    ///   tab is frontmost — is holding the microphone right now. Loose on
    ///   purpose: the browser's window title names a platform once, at
    ///   detection; aliveness must not depend on the user never switching
    ///   tabs mid-call.
    /// - platformEverSeen / lastAliveAt: a title-verified call was observed
    ///   during THIS session, and when a call holder was last present.
    /// - lastVoicedAt: the last VAD-voiced window on either channel — raw
    ///   voice, not recognized text, so a rejected phantom still counts as
    ///   somebody speaking.
    static func autoStopVerdict(platformEverSeen: Bool,
                                platformAliveNow: Bool,
                                lastAliveAt: Date?,
                                lastVoicedAt: Date,
                                now: Date) -> AutoStopVerdict {
        if platformAliveNow { return .keep }
        if platformEverSeen, let lastAliveAt,
           now.timeIntervalSince(lastAliveAt) > callEndGrace,
           now.timeIntervalSince(lastVoicedAt) > callEndGrace {
            return .callEnded
        }
        if now.timeIntervalSince(lastVoicedAt) > deadAirStop {
            return .deadAir
        }
        return .keep
    }

    // MARK: - Call platform from a browser window title

    /// A native app whose hold on the microphone reads as a call.
    struct CallApp: Equatable {
        /// The platform's display name — the detection card, the transcript's
        /// source line and the sidebar's Sources group all show it.
        let name: String
        /// Messengers take the mic for a VOICE NOTE too — a few seconds that
        /// are nobody's call. The detector waits those out (owner's choice,
        /// 2026-09-03: a delayed card over no card, since a Telegram call is
        /// as much a call as a Meet one).
        let voiceNotes: Bool
    }

    /// The one list of native call apps — the detector's map, the aliveness
    /// test and the source line all read it, so they can never drift apart.
    /// Matched as a fragment of the mic holder's display name ("zoom.us",
    /// "Microsoft Teams"), lowercased.
    private static let callApps: [(fragment: String, app: CallApp)] = [
        ("zoom", CallApp(name: "Zoom", voiceNotes: false)),
        ("teams", CallApp(name: "Microsoft Teams", voiceNotes: false)),
        ("facetime", CallApp(name: "FaceTime", voiceNotes: false)),
        ("webex", CallApp(name: "Webex", voiceNotes: false)),
        ("discord", CallApp(name: "Discord", voiceNotes: false)),
        ("slack", CallApp(name: "Slack", voiceNotes: false)),
        // Messengers: the owner's calls run on Telegram, and every one of
        // them read as "other" (2026-09-03) — the mic holder is plainly
        // named, it just was not on the list.
        ("telegram", CallApp(name: "Telegram", voiceNotes: true)),
        ("whatsapp", CallApp(name: "WhatsApp", voiceNotes: true)),
        ("signal", CallApp(name: "Signal", voiceNotes: true)),
        ("viber", CallApp(name: "Viber", voiceNotes: true)),
    ]

    /// The call app behind a microphone holder's display name, if any. A
    /// platform's own display name resolves to itself ("Telegram" contains
    /// "telegram"), so the detector can ask about a name it was handed.
    static func callApp(named appName: String) -> CallApp? {
        let lower = appName.lowercased()
        return callApps.first { lower.contains($0.fragment) }?.app
    }

    /// Names the platform a browser call is running on from the browser's own
    /// window title — the only place a web call announces itself (owner's
    /// report 2026-08-29: every Meet call read as "other", because Meet is a
    /// tab, not an app, and the mic is held by "Google Chrome").
    ///
    /// Deliberately narrow: each rule matches something only a live call tab
    /// carries. The trap is the word "meet" — "Meeting notes — Notion" must
    /// never become Google Meet, so Meet is recognised by its room-code shape
    /// ("Meet – abc-defg-hij") or the full product name, never the bare word.
    static func callPlatform(inWindowTitle title: String) -> String? {
        let lower = title.lowercased()
        if lower.contains("google meet") { return "Google Meet" }
        if lower.range(of: #"meet(\s+|\s*[-–—]\s*)[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z-])"#,
                       options: .regularExpression) != nil { return "Google Meet" }
        // Meet titles an active call's tab with the MEETING NAME, not the
        // room code ("Meet - Product Daily - …", owner's live call
        // 2026-08-29). The prefix-plus-separator shape keeps "Meeting
        // notes" out: "Meeting" has no break after "meet".
        if lower.range(of: #"^meet\s*[-–—]\s"#,
                       options: .regularExpression) != nil { return "Google Meet" }
        if lower.contains("zoom meeting") || lower.contains("zoom.us") { return "Zoom" }
        if lower.contains("microsoft teams") { return "Microsoft Teams" }
        if lower.contains("webex") { return "Webex" }
        if lower.contains("whereby") { return "Whereby" }
        if lower.contains("jitsi") { return "Jitsi" }
        return nil
    }

    /// Is this the display name of a browser — an app whose window titles are
    /// worth reading for a call? (A native call app is matched by its own
    /// name long before this.)
    static func isBrowser(appNamed name: String) -> Bool {
        let lower = name.lowercased()
        return ["chrome", "safari", "arc", "edge", "firefox", "brave",
                "opera", "vivaldi", "dia"].contains { lower.contains($0) }
    }
}
