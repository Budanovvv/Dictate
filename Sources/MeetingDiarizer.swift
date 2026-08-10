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
    }

    /// The session-local number of the voice dominating this utterance
    /// window, or nil when the diarizer can't tell (not ready, no clear
    /// voice). Windows are cut at pauses, so one window is almost always one
    /// speaker; the dominant-voice rule handles brief overlaps.
    func speakerOrdinal(floats: [Float], atTime offset: TimeInterval) -> Int? {
        guard ready else { return nil }
        let windowSeconds = Double(floats.count) / Double(AudioRecorder.sampleRate)
        guard let result = try? manager.performCompleteDiarization(
            floats, sampleRate: AudioRecorder.sampleRate, atTime: offset) else {
            Log.d(String(format: "diar: failed on %.1fs window", windowSeconds))
            return nil
        }
        let durations = result.segments.reduce(into: [String: Double]()) {
            $0[$1.speakerId, default: 0] += Double($1.durationSeconds)
        }
        // Per-window diagnostics for threshold calibration: how much of the
        // window each voice got, and the quality the embedder reported. Two
        // real voices merging into one id shows up here as a single id
        // covering a window that clearly held a dialogue.
        let quality = result.segments.map(\.qualityScore).max() ?? 0
        let shares = durations
            .sorted { $0.value > $1.value }
            .map { String(format: "%@=%.1fs", $0.key, $0.value) }
            .joined(separator: " ")
        Log.d(String(format: "diar: %.1fs window, %d segment(s), quality %.2f [%@]",
                     windowSeconds, result.segments.count, quality, shares))
        guard let dominant = MeetingPolicy.dominantSpeakerId(durations: durations) else {
            Log.d("diar: no dominant voice — entry stays collective")
            return nil
        }
        if let known = ordinals[dominant] { return known }
        let next = ordinals.count + 1
        ordinals[dominant] = next
        Log.d("meeting: new voice -> speaker \(next) (id \(dominant))")
        return next
    }
}
