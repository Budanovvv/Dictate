import AppKit

/// Watches for a call starting — the signal is another application taking
/// the microphone AND being recognisable as a call (a known call app, or a
/// browser whose window title names a platform). That second half is what
/// keeps this quiet: a voice memo or a chat assistant holding the mic is
/// somebody's business, not a call, and never prompts.
///
/// One shot per call, where a call is a microphone EPISODE: the detector
/// latches when a call appears and unlatches once nothing call-shaped has
/// held the mic for two ticks (~8 s). Back-to-back calls need that short
/// gap between them to be told apart — a deliberate simplicity (owner's
/// call, 2026-08-29: no exotic identity tracking).
///
/// The latch is HELD by the loose test — any call-shaped process on the
/// mic, whatever tab is frontmost — so switching to a document tab mid-call
/// neither unlatches nor re-prompts. Only the initial firing needs the
/// strict, title-verified detection.
@MainActor
final class CallDetector {
    /// A call was recognised; the string is the platform's display name.
    var onCallDetected: ((String) -> Void)?
    /// Answers whether a meeting session is already running — detection
    /// pauses itself around one.
    var isRecording: () -> Bool = { false }

    private var timer: Timer?
    private var inCall = false
    private var quietTicks = 0

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inCall = false
        quietTicks = 0
    }

    private func tick() {
        // While we record, the platform is "in a call" by definition —
        // stay latched so the end of the recording is not a fresh call.
        if isRecording() { inCall = true; quietTicks = 0; return }
        if MeetingSession.callHolderPresent() {
            quietTicks = 0
            guard !inCall else { return }
            guard let platform = MeetingSession.detectCallApp() else { return }
            inCall = true
            Log.d("call: detected — \(platform)")
            onCallDetected?(platform)
        } else if inCall {
            quietTicks += 1
            if quietTicks >= 2 {
                inCall = false
                quietTicks = 0
                Log.d("call: over")
            }
        }
    }
}
