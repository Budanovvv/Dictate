import Foundation

/// Pure decision logic extracted from the controllers so the regression tests
/// can exercise it directly — no audio hardware, TCC or UI involved. Every
/// rule here traces back to a documented pitfall; keep
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

    /// What to tell the user when the recording captured ZERO usable audio
    /// (chain never came up before the release). nil = stay silent: a tap
    /// under 0.5 s is an accidental touch, not a failed dictation. CRITICAL:
    /// `held` must be the press→release span measured AT release — a Date()
    /// taken after blocking calls once inflated a 0.24 s tap into a "1.0 s
    /// hold" and showed a spurious "nothing heard" (live log 2026-08-06).
    static func zeroCaptureVerdict(held: Double,
                                   foreignHeld: Bool) -> EmptyCaptureVerdict? {
        guard held >= 0.5 else { return nil }
        return foreignHeld ? .micBusy : .nothingHeard
    }

    /// Whether a new push-to-talk capture may begin. The dictation pipeline
    /// exists so that "recognizing" is NOT a blocker: a press during
    /// recognition used to be silently swallowed, and the user's natural
    /// rhythm hit that window several times an hour. Only three things block:
    /// a capture already running (one key, one mic), live typing still
    /// delivering into the document (a second writer would interleave), and
    /// a full job queue (runaway-hold protection).
    static func mayBeginCapture(capturing: Bool, liveDelivering: Bool,
                                queuedJobs: Int, maxQueued: Int) -> Bool {
        !capturing && !liveDelivering && queuedJobs < maxQueued
    }

    /// Whether CGEventSource.flagsState can be trusted as PHYSICAL modifier
    /// state. The paster's synthetic ⌘V carries flags=Command only, and
    /// posting it rewrites the session flags state — a physically held
    /// push-to-talk modifier vanishes from flagsState until the next real
    /// flagsChanged event repairs it. Harmless until the dictation pipeline
    /// made mid-recording pastes normal: the lost-release watchdog then read
    /// the clobbered state as "key up" and cut a live recording at 2 s
    /// (log 2026-08-09 11:44). Trust returns with the first real flags event
    /// after the paste.
    static func modifierStateTrustworthy(lastRealFlagsEvent: Date,
                                         lastSyntheticPaste: Date?) -> Bool {
        guard let paste = lastSyntheticPaste else { return true }
        return lastRealFlagsEvent > paste
    }

    /// App Translocation: launched from the quarantined DMG/Downloads copy,
    /// the process runs from a random read-only path and TCC grants can never
    /// stick. The marker is precise — dev builds and normal installs never
    /// contain it.
    static func isTranslocatedPath(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }
}
