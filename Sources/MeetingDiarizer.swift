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

    /// clusteringThreshold 0.7 → 0.62: the first three-person meeting came
    /// out as ONE dominant speaker plus scraps (2026-08-10) — two real
    /// voices merged. Call audio is compressed, which pulls voice embeddings
    /// closer together, so the default bar under-segments. Lower = more
    /// eager to split. Over-splitting is the opposite risk, hence the
    /// per-window diagnostics below: the logs of the next meetings decide
    /// the final value.
    private let manager = DiarizerManager(
        config: DiarizerConfig(clusteringThreshold: 0.62))
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

    /// End-of-session calibration data. The clustering threshold stays at
    /// 0.62 until the owner supplies ground-truth participant counts; these
    /// counters are what the NEXT meetings must produce so that call can
    /// finally be made on numbers instead of a hunch.
    struct SessionStats: Sendable {
        var windows = 0
        var failures = 0
        /// Windows where the diarizer ran but heard no voice at all — the
        /// entry then stays collective ("Them"). This is the counter that
        /// showed 93 hits in the 2026-08-12 log.
        var noVoice = 0
        /// speaker-turns-per-window → how many windows had that many.
        var turnHistogram: [Int: Int] = [:]
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
}
