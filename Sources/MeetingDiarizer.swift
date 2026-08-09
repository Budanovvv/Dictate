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

    private let manager = DiarizerManager()
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
            let models = try await DiarizerModels.downloadIfNeeded(to: dir)
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
        guard let result = try? manager.performCompleteDiarization(
            floats, sampleRate: AudioRecorder.sampleRate, atTime: offset) else { return nil }
        let durations = result.segments.reduce(into: [String: Double]()) {
            $0[$1.speakerId, default: 0] += Double($1.durationSeconds)
        }
        guard let dominant = MeetingPolicy.dominantSpeakerId(durations: durations) else {
            return nil
        }
        if let known = ordinals[dominant] { return known }
        let next = ordinals.count + 1
        ordinals[dominant] = next
        Log.d("meeting: new voice -> speaker \(next)")
        return next
    }
}
