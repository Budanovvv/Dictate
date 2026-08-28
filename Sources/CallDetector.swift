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
    /// A call was recognised; the platform's display name, or nil when a
    /// browser is on a call whose tab is not frontmost (the title names the
    /// platform, and a background tab has no visible title).
    var onCallDetected: ((String?) -> Void)?
    /// Answers whether a meeting session is already running — detection
    /// pauses itself around one.
    var isRecording: () -> Bool = { false }

    private var timer: Timer?
    private var inCall = false
    private var quietTicks = 0
    /// Ticks a browser has held the mic without a title naming the call.
    private var unidentifiedTicks = 0
    /// When the prompt last fired. However the episodes flap, the card never
    /// asks more than once per five minutes — a declined call must not keep
    /// asking (three prompts in one meeting, owner's log 2026-08-29).
    private var lastFiredAt: Date?

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
        unidentifiedTicks = 0
    }

    private func fire(_ platform: String?) {
        if let lastFiredAt, Date().timeIntervalSince(lastFiredAt) < 300 {
            Log.d("call: detected — \(platform ?? "unnamed"), prompt cooling down")
            return
        }
        lastFiredAt = Date()
        Log.d("call: detected — \(platform ?? "unnamed browser call")")
        onCallDetected?(platform)
    }

    private func tick() {
        // While we record, the platform is "in a call" by definition —
        // stay latched so the end of the recording is not a fresh call.
        if isRecording() { inCall = true; quietTicks = 0; unidentifiedTicks = 0; return }
        if MeetingSession.callHolderPresent() {
            if quietTicks > 0 { Log.d("call: holder back after \(quietTicks * 4)s") }
            quietTicks = 0
            guard !inCall else { return }
            if let platform = MeetingSession.detectCallApp() {
                inCall = true
                unidentifiedTicks = 0
                fire(platform)
                return
            }
            // A browser is on the mic but no window title names the call —
            // the Meet tab is in the background (a window's AX title is its
            // ACTIVE tab's, owner's live repro 2026-08-29). Twelve seconds
            // of that is a call in all but name: prompt namelessly rather
            // than stay silent through the meeting.
            unidentifiedTicks += 1
            if unidentifiedTicks == 1 {
                Log.d("call: unidentified holder — \(MeetingSession.debugCallHolders())")
            }
            if unidentifiedTicks >= 3 {
                inCall = true
                unidentifiedTicks = 0
                fire(nil)
            }
        } else {
            unidentifiedTicks = 0
            if inCall {
                quietTicks += 1
                if quietTicks == 1 { Log.d("call: holder quiet") }
                // Five ticks (~20 s), not two: a live Meet releases the mic
                // for ~10 s stretches around its lobby and permission
                // screens, and an 8 s patience read each one as the call
                // ending — three prompts in one meeting.
                if quietTicks >= 5 {
                    inCall = false
                    quietTicks = 0
                    Log.d("call: over (quiet \(5 * 4)s)")
                }
            }
        }
    }
}
