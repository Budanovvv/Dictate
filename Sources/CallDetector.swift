import AppKit

/// Watches for a call starting — the signal is another application taking
/// the microphone AND being recognisable as a call (a known call app, or a
/// browser whose window title names a platform). That second half is what
/// keeps this quiet: a voice memo or a chat assistant holding the mic is
/// somebody's business, not a call, and never prompts.
///
/// One shot per call: the detector latches when a platform appears and does
/// not fire again until the platform has been gone for two ticks (~8 s), so
/// declining a prompt stays declined for that call and a network hiccup in
/// the middle does not re-ask.
///
/// A poll, not a CoreAudio listener, on purpose: four seconds of latency is
/// invisible next to the seconds a call takes to join, and the process-list
/// read is microseconds.
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
        let platform = MeetingSession.detectCallApp()
        if let platform {
            quietTicks = 0
            guard !inCall else { return }
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
