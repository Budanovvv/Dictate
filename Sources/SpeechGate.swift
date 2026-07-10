import CoreML
import FluidAudio
import Foundation

/// "Was there any speech?" gate in front of Whisper, backed by Silero VAD
/// (CoreML, ~1 MB, bundled in the app — no runtime downloads).
///
/// Replaces the hand-rolled energy threshold: a fixed loudness constant is
/// deaf to quiet voices (calibrated on one person, fails the next), while
/// Silero detects speech-ness rather than loudness. Whisper hallucinates
/// confident phrases on speech-free audio ("Thank you for watching…"), so
/// recordings failing this gate show "didn't catch that" and never reach
/// the model.
actor SpeechGate {
    static let shared = SpeechGate()

    private var manager: VadManager?
    private var loadFailed = false

    /// true — speech present, false — no speech, nil — VAD unavailable
    /// (caller falls back to the energy heuristic).
    func hasSpeech(_ floats: [Float]) async -> Bool? {
        guard let manager = loadManager() else { return nil }
        do {
            let results = try await manager.process(floats)
            let voiced = results.filter(\.isVoiceActive).count
            let maxProb = results.map(\.probability).max() ?? 0
            Log.d("vad: chunks=\(results.count) voiced=\(voiced) maxProb=\(String(format: "%.2f", maxProb))")
            return voiced > 0
        } catch {
            Log.d("vad: process failed (\(error.localizedDescription)) — falling back")
            return nil
        }
    }

    /// Loads the model off the critical path (first dictation stays fast).
    func prewarm() {
        _ = loadManager()
    }

    private func loadManager() -> VadManager? {
        if let manager { return manager }
        guard !loadFailed else { return nil }
        guard let url = Bundle.main.url(forResource: "silero-vad-unified-256ms-v6.2.1",
                                        withExtension: "mlmodelc") else {
            loadFailed = true
            Log.d("vad: bundled model missing")
            return nil
        }
        do {
            let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
            let m = VadManager(config: VadConfig(defaultThreshold: 0.7), vadModel: model)
            manager = m
            Log.d("vad: silero loaded")
            return m
        } catch {
            loadFailed = true
            Log.d("vad: load failed (\(error.localizedDescription))")
            return nil
        }
    }
}
