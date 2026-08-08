import Foundation

/// Pure decision logic extracted from the controllers so the regression tests
/// can exercise it directly — no audio hardware, TCC or UI involved. Every
/// rule here traces back to a documented pitfall (internal/GRABLI.md); keep
/// the wrappers in DictationController/Permissions paper-thin.
enum DictationPolicy {

    /// What to tell the user when a held key produced no recognizable speech.
    enum EmptyCaptureVerdict {
        case micBusy, tooLoud, tooQuiet, nothingHeard
    }

    /// Order matters: a dead recording under a foreign mic hold is "busy",
    /// never "too quiet" — a quiet-but-alive voice must stay "too quiet"
    /// (energy thresholds already failed one real user; see GRABLI).
    static func emptyCaptureVerdict(peak: Double, clip: Double,
                                    foreignHeld: Bool) -> EmptyCaptureVerdict {
        if foreignHeld, peak < 0.001 { return .micBusy }
        if clip > 0.02 { return .tooLoud }
        if peak < 0.02 { return .tooQuiet }
        return .nothingHeard
    }

    /// App Translocation: launched from the quarantined DMG/Downloads copy,
    /// the process runs from a random read-only path and TCC grants can never
    /// stick. The marker is precise — dev builds and normal installs never
    /// contain it.
    static func isTranslocatedPath(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }
}
