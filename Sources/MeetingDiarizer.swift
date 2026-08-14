import Foundation
import FluidAudio

/// Tells the meeting's Them-channel voices apart: "Speaker 1", "Speaker 2"…
/// Wraps FluidAudio's diarizer (pyannote segmentation + speaker embeddings,
/// CoreML — the same package our Silero VAD ships in). The system audio of a
/// call is one MIXED stream, so names are impossible by construction (only
/// the meeting platform has per-participant streams); voices are told apart
/// acoustically and numbered in order of first appearance.
///
/// An actor: the underlying manager keeps a running speaker database (that's
/// what makes labels consistent across utterance windows), so calls must be
/// serialized.
actor MeetingDiarizer {

    /// The threshold this process runs at: the compiled default unless the
    /// hidden `diarThreshold` default overrides it (see
    /// `MeetingSpeakerPolicy.threshold`, where the range and the refusal rule
    /// live and are unit tested).
    ///
    /// A `static let`, so it is read from `UserDefaults` ONCE, at first touch,
    /// and every session of that process runs at the value that was in force
    /// when it started — a threshold that changed halfway through a meeting
    /// would produce a transcript no calibration run could interpret. It is
    /// also the value `manager` is built with, and the manager is built once.
    static let threshold: MeetingSpeakerPolicy.Threshold = {
        let d = UserDefaults.standard
        // `double(forKey:)` cannot tell "absent" from "written as 0", and 0 is
        // a value that would break diarization, so absence is checked first.
        // The knob is deliberately NOT in `Settings`: that type is the surface
        // the UI binds to, this is a lab instrument with no UI and no future.
        let raw = d.object(forKey: MeetingSpeakerPolicy.thresholdKey) == nil
            ? nil : d.double(forKey: MeetingSpeakerPolicy.thresholdKey)
        return MeetingSpeakerPolicy.threshold(override: raw)
    }()

    /// Back to the library default 0.7 (2026-08-14), reverting the 0.62 of
    /// 2026-08-10. The history, because the number keeps moving: 0.62 was set
    /// on ONE meeting that looked under-segmented (two real voices in one
    /// label) and was written down as a hypothesis, not a finding. The owner
    /// has since supplied ground truth for THREE meetings — 11.08 "AI system
    /// onboarding", 12.08 "Agent Discussion", 12.08 "Pharmaceutical Diet
    /// Presentation", three people each, so exactly TWO voices on the tap
    /// channel — and at 0.62 they came out as four, four and three labels,
    /// two of those with a single entry in a whole meeting. Three meetings
    /// over-segmenting outweighs one that under-segmented, and the tearing
    /// the owner noticed (one sentence split mid-phrase across two
    /// "speakers") is the same symptom seen from the transcript side.
    ///
    /// 0.7 is STILL A HYPOTHESIS: it has never been observed live either, and
    /// nothing here can be re-tested afterwards because we keep no meeting
    /// audio. The end-of-session diagnostics are what decides the next move —
    /// and since 2026-08-14 the value itself can be moved without a rebuild,
    /// which is what makes "measure it" a plan rather than a wish. The
    /// compiled default and the knob's guard rails live in
    /// `MeetingSpeakerPolicy`; this is only "what are we running at".
    static var clusteringThreshold: Float { threshold.value }

    /// The bar a micro-cluster must clear to be merged back into a real one
    /// (see `MeetingSpeakerPolicy`). Deliberately the CLUSTERING bar, while the
    /// library's own runtime bar for "this embedding belongs to that known
    /// voice" is 1.2× it (DiarizerManager derives speakerThreshold =
    /// clusteringThreshold * 1.2 = 0.84). So we merge only well inside the
    /// distance at which the diarizer itself would already have called the
    /// two one voice — a 0.14 safety margin, chosen because a wrong merge
    /// silently puts one person's words in another's mouth, while a surplus
    /// label costs the owner one rename. Every refusal is logged with its
    /// measured distance: if the next meetings show refusals bunched between
    /// 0.70 and 0.84, that is the evidence for widening this to the runtime
    /// bar, and we will have it in numbers instead of by argument.
    static var mergeCeiling: Double { Double(clusteringThreshold) }

    private let manager = DiarizerManager(
        config: DiarizerConfig(clusteringThreshold: MeetingDiarizer.clusteringThreshold))
    private var ready = false
    private var preparing = false
    /// Session-local numbering: first distinct voice → 1, next → 2…
    private var ordinals: [String: Int] = [:]

    /// One voice's turn inside a window, ready to become its own transcript
    /// entry. Times are session-absolute seconds.
    struct SpeakerTurn: Sendable {
        let ordinal: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    /// End-of-session calibration data. The threshold moved to 0.7 on three
    /// meetings with confirmed head counts; these counters are what the NEXT
    /// meetings must produce so the value after that is decided on numbers
    /// again and not on a hunch.
    struct SessionStats: Sendable {
        var windows = 0
        var failures = 0
        /// Micro-clusters folded back into a real voice at session end.
        var merged = 0
        /// Windows where the diarizer ran but heard no voice at all — the
        /// entry then stays collective ("Them"). This is the counter that
        /// showed 93 hits in the 2026-08-12 log.
        var noVoice = 0
        /// speaker-turns-per-window → how many windows had that many.
        var turnHistogram: [Int: Int] = [:]
        /// The clustering threshold this session ran at, ready for the log.
        /// It rides along with the counters ON PURPOSE: the summary line is
        /// where all the outcome numbers already sit, and a threshold printed
        /// only at session start is one grep away from being lost in a log
        /// that also holds every dictation of the day. Reading a transcript
        /// days later, "this threshold produced these voices" must be one line.
        let thresholdNote = MeetingSpeakerPolicy.describe(MeetingDiarizer.threshold)
    }
    private var stats = SessionStats()

    func sessionStats() -> SessionStats { stats }

    /// Loads (and on the very first run downloads) the CoreML models. Safe to
    /// call repeatedly; failures are logged and leave the diarizer disabled —
    /// the transcript then simply keeps the collective "Them" label.
    func prepare() async {
        guard !ready, !preparing else { return }
        preparing = true
        defer { preparing = false }
        do {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
                .appendingPathComponent("Dictate", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("diarizer", isDirectory: true)
            // Incomplete-download marker, the Whisper-model lesson: a crash
            // mid-download must not leave half-models that fail every later
            // prepare. Marker present = last attempt never finished — wipe
            // and re-download cleanly.
            let fm = FileManager.default
            let marker = dir.appendingPathComponent(".incomplete")
            if fm.fileExists(atPath: marker.path) {
                Log.d("meeting: diarizer models incomplete — clean re-download")
                try? fm.removeItem(at: dir)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: marker.path, contents: nil)
            let models = try await DiarizerModels.downloadIfNeeded(to: dir)
            try? fm.removeItem(at: marker)
            manager.initialize(models: models)
            ready = true
            Log.d("meeting: diarizer ready")
        } catch {
            Log.d("meeting: diarizer unavailable: \(error.localizedDescription)")
        }
    }

    /// New session: numbering restarts at 1. The manager's voice database is
    /// deliberately kept — a voice it already knows just gets a fresh number.
    func startSession() {
        ordinals.removeAll()
        stats = SessionStats()
        // Said out loud at the start as well as in the summary: a session that
        // crashes or is still running has no summary line, and a calibration
        // run whose threshold is unknown is a wasted meeting.
        Log.d("diar: session start — clustering threshold \(stats.thresholdNote)")
    }

    /// Splits one Them window into the turns of the voices heard in it, in
    /// time order — one entry per turn is what keeps two people from being
    /// merged into a single line and chopped mid-sentence by the window cap.
    ///
    /// `windowStart` is the session time of the FIRST PCM sample handed in
    /// (not the window's first-speech estimate): the returned times must map
    /// back to sample offsets, so the diarizer is anchored to the buffer.
    /// Returns [] when the diarizer can't say anything (not ready, failed, no
    /// voice) — the caller then transcribes the window whole under the
    /// collective label, exactly as before.
    func speakerTurns(floats: [Float], windowStart: TimeInterval) -> [SpeakerTurn] {
        guard ready else { return [] }
        let windowSeconds = Double(floats.count) / Double(AudioRecorder.sampleRate)
        stats.windows += 1
        guard let result = try? manager.performCompleteDiarization(
            floats, sampleRate: AudioRecorder.sampleRate, atTime: windowStart) else {
            stats.failures += 1
            Log.d(String(format: "diar: failed on %.1fs window", windowSeconds))
            return []
        }
        // Per-window diagnostics for threshold calibration: how much of the
        // window each voice got, and the quality the embedder reported. Two
        // real voices merging into one id shows up here as a single id
        // covering a window that clearly held a dialogue; ONE voice splitting
        // (the opposite risk of the lowered threshold) shows up as ping-pong
        // between two ids across the seams.
        let durations = result.segments.reduce(into: [String: Double]()) {
            $0[$1.speakerId, default: 0] += Double($1.durationSeconds)
        }
        let quality = result.segments.map(\.qualityScore).max() ?? 0
        let shares = durations
            .sorted { $0.value > $1.value }
            .map { String(format: "%@=%.1fs", $0.key, $0.value) }
            .joined(separator: " ")
        Log.d(String(format: "diar: %.1fs window, %d segment(s), quality %.2f [%@]",
                     windowSeconds, result.segments.count, quality, shares))

        let slices = MeetingPolicy.speakerSlices(
            spans: result.segments.map {
                MeetingPolicy.SpeakerSpan(id: $0.speakerId,
                                          start: Double($0.startTimeSeconds),
                                          end: Double($0.endTimeSeconds))
            },
            windowStart: windowStart, windowEnd: windowStart + windowSeconds)
        guard !slices.isEmpty else {
            stats.noVoice += 1
            stats.turnHistogram[0, default: 0] += 1
            Log.d("diar: no voice in window — entry stays collective")
            return []
        }
        stats.turnHistogram[slices.count, default: 0] += 1
        let turns = slices.map { slice -> SpeakerTurn in
            let ordinal: Int
            if let known = ordinals[slice.id] {
                ordinal = known
            } else {
                ordinal = ordinals.count + 1
                ordinals[slice.id] = ordinal
                Log.d("meeting: new voice -> speaker \(ordinal) (id \(slice.id))")
            }
            return SpeakerTurn(ordinal: ordinal, start: slice.start, end: slice.end)
        }
        if turns.count > 1 {
            let plan = turns
                .map { String(format: "spk%d %.1f-%.1f", $0.ordinal,
                              $0.start - windowStart, $0.end - windowStart) }
                .joined(separator: " | ")
            Log.d("diar: window split into \(turns.count) turn(s) [\(plan)]")
        }
        return turns
    }

    // MARK: - End of session: micro-clusters

    /// One label to rewrite in the finished transcript.
    struct Merge: Sendable {
        let source: Int
        let target: Int
    }

    /// Looks at the finished transcript's per-voice measurements while the
    /// voice database is STILL ALIVE — this is the only moment both exist at
    /// once — and folds voices that turned out to be fragments back into the
    /// voice they are acoustically nearest.
    ///
    /// All judgement lives in `MeetingSpeakerPolicy.verdicts` (pure, unit
    /// tested); this method only measures, logs and reports. The caller does
    /// the actual relabelling in the file, because the file is its business.
    func mergeMicroClusters(voices: [MeetingSpeakerPolicy.Voice]) -> [Merge] {
        // Ordinal → the diarizer's own speaker id, so an ordinal can be turned
        // back into an embedding.
        var ids: [Int: String] = [:]
        for (id, ordinal) in ordinals where ids[ordinal] == nil { ids[ordinal] = id }
        let db = manager.speakerManager
        func embedding(_ ordinal: Int) -> [Float]? {
            guard let id = ids[ordinal],
                  let speaker = db.getSpeaker(for: id) else { return nil }
            let vector = speaker.currentEmbedding
            return vector.isEmpty ? nil : vector
        }
        // Voices the diarizer numbered that never reached the file (every turn
        // of theirs was rejected as a phantom or was too short to decode). They
        // have nothing to relabel, so they take no part — but they are worth a
        // line, because "the diarizer invented a voice that never said a word"
        // is itself over-segmentation showing.
        let present = Set(voices.map(\.ordinal))
        for ordinal in ids.keys.sorted() where !present.contains(ordinal) {
            Log.d("diar: speaker \(ordinal) produced no entries in the file")
        }
        let micro = voices.filter(MeetingSpeakerPolicy.isMicro)
        guard !micro.isEmpty else {
            Log.d("diar: micro-cluster check — \(voices.count) voice(s), none micro")
            return []
        }
        Log.d(String(format: "diar: micro-cluster check — %d voice(s), %d micro (bar: ≤%d entries and ≤%.0fs), ceiling %.2f",
                     voices.count, micro.count, MeetingSpeakerPolicy.maxEntries,
                     MeetingSpeakerPolicy.maxSeconds, Self.mergeCeiling))
        let verdicts = MeetingSpeakerPolicy.verdicts(
            voices: voices, ceiling: Self.mergeCeiling) { a, b in
                guard let ea = embedding(a), let eb = embedding(b) else { return nil }
                let d = SpeakerUtilities.cosineDistance(ea, eb)
                return d.isFinite ? Double(d) : nil
            }
        let byOrdinal = Dictionary(voices.map { ($0.ordinal, $0) },
                                   uniquingKeysWith: { a, _ in a })
        var merges: [Merge] = []
        for verdict in verdicts {
            let v = verdict.voice
            let who = String(format: "speaker %d (%d entr%@, %.0fs)",
                             v.ordinal, v.entries, v.entries == 1 ? "y" : "ies", v.seconds)
            switch verdict.outcome {
            case .merge(let into, let distance):
                let host = byOrdinal[into]
                Log.d(String(format: "diar: merging %@ into speaker %d (%d entries, %.0fs) — distance %.3f ≤ ceiling %.2f",
                             who, into, host?.entries ?? 0, host?.seconds ?? 0,
                             distance, Self.mergeCeiling))
                merges.append(Merge(source: v.ordinal, target: into))
                stats.merged += 1
                // Keep the database's view consistent with the file's: the
                // fragment's id now answers to the host's number.
                if let id = ids[v.ordinal] { ordinals[id] = into }
            case .keepTooFar(let nearest, let distance):
                Log.d(String(format: "diar: keeping %@ — nearest is speaker %d at distance %.3f > ceiling %.2f",
                             who, nearest, distance, Self.mergeCeiling))
            case .keepUnmeasured:
                Log.d("diar: keeping \(who) — no embedding in the voice database")
            case .keepNoHost:
                Log.d("diar: keeping \(who) — no larger voice to merge into")
            }
        }
        return merges
    }

    // MARK: - End of session: how far apart the clusters actually are

    /// Logs the full pairwise distance matrix between the session's speaker
    /// clusters — the one number about this diarizer we have never measured,
    /// and the one that decides what gets built next.
    ///
    /// The question behind it. Raising `clusteringThreshold` is not the lever:
    /// on the same 6–10 minute two-speaker podcast, 0.70 gave three voices with
    /// 26% of entry junctions being a sentence continuing across a "speaker
    /// change", and 0.80 gave three voices with 38%. The errors bunch in the
    /// first minutes (at 0.80 the per-minute split rate ran 0, 4/8, 6/10, 7/8,
    /// 3/9, 1/9, 0/4, and the spurious third voice was born at 1:10), which is
    /// exactly what the online-diarization literature describes: an online
    /// system cannot re-cluster the past, so an early mistake persists to the
    /// end. The standard remedy is a second, OFFLINE pass once every embedding
    /// exists — and whether that pass can be a cheap end-of-session merge is
    /// decided by this matrix:
    ///
    /// * if the two clusters holding ONE person end up CLOSE once the voice
    ///   database has matured (under the ceiling, or between it and the
    ///   library's own 1.2× same-voice bar), the embeddings agree by the end
    ///   and a merge fixes this properly;
    /// * if they stay FAR apart, the embeddings genuinely differ, no merge can
    ///   be justified, and the fix has to be lexical instead (sentence
    ///   continuity across the seam).
    ///
    /// MEASUREMENT ONLY, by construction. `SpeakerManager` is a struct, so the
    /// `let db` below is a private copy that cannot write back into the live
    /// database; the distance is the same `SpeakerUtilities.cosineDistance` the
    /// micro-merge already uses on the same embeddings; nothing merges, nothing
    /// is relabelled, no file is touched. Cost is a handful of dot products
    /// over 256-float vectors — a meeting has a handful of clusters.
    func logSpeakerDistances(voices: [MeetingSpeakerPolicy.Voice]) {
        // Ordinal → the diarizer's own speaker id. The lowest id wins when a
        // merge has already pointed two ids at one ordinal, so the same meeting
        // always prints the same matrix instead of one per dictionary order.
        var ids: [Int: String] = [:]
        for (id, ordinal) in ordinals {
            if let seen = ids[ordinal], seen <= id { continue }
            ids[ordinal] = id
        }
        // Clusters the diarizer numbered but that never reached the file are
        // included: a voice invented at 1:10 that said nothing is precisely the
        // over-segmentation this matrix is meant to explain.
        let all = Set(ids.keys).union(voices.map(\.ordinal)).sorted()
        guard all.count > 1 else {
            Log.d("diar: distance matrix — \(all.count) cluster(s), nothing to compare")
            return
        }
        let db = manager.speakerManager   // struct — a read-only copy
        var vectors: [Int: [Float]] = [:]
        for (ordinal, id) in ids {
            let vector = db.getSpeaker(for: id)?.currentEmbedding ?? []
            if !vector.isEmpty { vectors[ordinal] = vector }
        }
        let byOrdinal = Dictionary(voices.map { ($0.ordinal, $0) },
                                   uniquingKeysWith: { a, _ in a })
        // The library's own runtime bar for "this embedding is that known
        // voice": DiarizerManager derives speakerThreshold = clustering × 1.2.
        // Printed next to our ceiling because a pair that sits between the two
        // is one the diarizer itself would have called a single voice at
        // runtime — the most interesting band on the whole matrix.
        let sameVoiceBar = Double(Self.clusteringThreshold) * 1.2
        Log.d(String(format: "diar: distance matrix — %d cluster(s), threshold %@, merge ceiling %.2f, same-voice bar %.2f",
                     all.count, stats.thresholdNote, Self.mergeCeiling, sameVoiceBar))
        func profile(_ ordinal: Int) -> String {
            let voice = byOrdinal[ordinal]
            return String(format: "spk%d: %d entries, %.0fs",
                          ordinal, voice?.entries ?? 0, voice?.seconds ?? 0)
        }
        for (index, a) in all.enumerated() {
            for b in all.dropFirst(index + 1) {
                let context = "\(profile(a)); \(profile(b))"
                guard let ea = vectors[a], let eb = vectors[b] else {
                    let missing = vectors[a] == nil
                        ? (vectors[b] == nil ? "both" : "spk\(a)") : "spk\(b)"
                    Log.d("diar: distance spk\(a) vs spk\(b) = n/a (no embedding for \(missing)) — \(context)")
                    continue
                }
                let d = Double(SpeakerUtilities.cosineDistance(ea, eb))
                guard d.isFinite else {
                    Log.d("diar: distance spk\(a) vs spk\(b) = n/a (not measurable) — \(context)")
                    continue
                }
                let band = d <= Self.mergeCeiling
                    ? "below ceiling"
                    : (d <= sameVoiceBar ? "above ceiling, below same-voice bar" : "above both")
                Log.d(String(format: "diar: distance spk%d vs spk%d = %.3f (%@) — %@",
                             a, b, d, band, context))
            }
        }
    }
}
