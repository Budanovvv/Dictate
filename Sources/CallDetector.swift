import AppKit

/// Watches for a call starting — the signal is another application taking
/// the microphone AND being recognisable as a call (a known call app, or a
/// browser whose window title names a platform). That second half is what
/// keeps this quiet: a voice memo or a chat assistant holding the mic is
/// somebody's business, not a call, and never prompts.
///
/// One card per call, and a call is identified by the window title that
/// named it — not by the microphone episode it happens to sit in. The
/// episode was the original answer and it is not a boundary: on 2026-09-18 a
/// browser held the mic unbroken from one meeting into the next 24 minutes
/// later, and the second meeting was never announced. Answering "not this
/// one" had the same effect, silencing every call that followed it.
///
/// So the detector remembers what it already ASKED about. A call whose title
/// differs from that one, seen after a stretch with no call visible at all,
/// is a new call and earns its own card. A different title with no such
/// break is the same call being retitled — Meet swaps the room code for the
/// meeting's name the moment you are let in — and is absorbed silently.
///
/// The latch is still HELD by the loose test — any call-shaped process on
/// the mic, whatever tab is frontmost — so switching to a document tab
/// mid-call neither unlatches nor re-prompts. What the strict, title-
/// verified test adds is only the question of WHICH call this is.
@MainActor
final class CallDetector {
    /// A call was recognised; the platform's display name, or nil when a
    /// browser is on a call whose tab is not frontmost (the title names the
    /// platform, and a background tab has no visible title).
    var onCallDetected: ((String?) -> Void)?
    /// The latched call's microphone episode ended — whoever shows UI for
    /// the call takes it down.
    var onCallOver: (() -> Void)?
    /// Answers whether a meeting session is already running — detection
    /// pauses itself around one.
    var isRecording: () -> Bool = { false }

    private var timer: Timer?
    /// One probe in flight at a time — a stalled AX call must not stack.
    private var probing = false
    private var inCall = false
    /// The call the owner has already answered for — a card shown for it, or
    /// a recording started over it. `MeetingPolicy.isASecondCall` is the rule
    /// that reads it.
    private var answered = MeetingPolicy.AnsweredCall.nothing
    /// Consecutive ticks with no call visible while still latched. A different
    /// title only counts as a NEW call on the far side of such a gap.
    private var unseenTicks = 0
    private var quietTicks = 0
    /// Ticks the mic has been held by something that is not yet a call for
    /// sure: a browser with no title naming the call, or a messenger that
    /// records voice notes with the same microphone.
    private var patienceTicks = 0
    /// When the prompt last fired. A short belt against an episode that
    /// flaps straight through the 20 s patience — NOT a rate limit on real
    /// calls: five minutes here suppressed the owner's genuinely new call
    /// two minutes after the last one (log, 2026-08-29 15:28).
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
        patienceTicks = 0
        answered = .nothing
        unseenTicks = 0
    }

    private func fire(_ platform: String?) {
        if let lastFiredAt, Date().timeIntervalSince(lastFiredAt) < 60 {
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
        if isRecording() { recording(); return }
        // The probe walks HAL mic holders and browser AX titles —
        // synchronous IPC a beachballing browser can stall for seconds. Off
        // the main thread (review, 2026-08-31), one probe in flight at a
        // time; the verdict hops back here.
        guard !probing else { return }
        probing = true
        let latched = inCall
        Task.detached(priority: .utility) { [weak self] in
            let holder = MeetingSession.callHolderPresent()
            // The strict, title-verified probe now runs while latched too —
            // that is what tells a second call apart from the first one. The
            // debug walk stays rare: only an unidentified holder nobody has
            // asked about yet.
            let call = holder ? MeetingSession.detectCall() : nil
            let holders = (holder && !latched && call == nil)
                ? MeetingSession.debugCallHolders() : ""
            // Fresh weak capture: the outer `self` is the detached closure's
            // mutable box and may not cross into this one.
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.probing = false
                self.apply(holder: holder, call: call, holders: holders)
            }
        }
    }

    /// A recording is running: whatever is on the microphone is the call the
    /// owner answered for, so nothing here may ever fire. The gap counter is
    /// held at zero so that the first tick AFTER the recording sees "no break"
    /// — stopping a recording without leaving the call must not bring the card
    /// back four seconds later.
    private func recording() {
        inCall = true
        quietTicks = 0
        patienceTicks = 0
        unseenTicks = 0
    }

    /// The tick's verdict, applied with the detector's state — main-actor,
    /// after the background probe.
    private func apply(holder: Bool, call: (platform: String, identity: String)?, holders: String) {
        if isRecording() { recording(); return }
        if holder {
            if quietTicks > 0 { Log.d("call: holder back after \(quietTicks * 4)s") }
            quietTicks = 0
            guard !inCall else { stillTheSameCall(call); return }
            let voiceNotes = call.map { MeetingPolicy.callApp(named: $0.platform)?.voiceNotes ?? false } ?? false
            if let call, !voiceNotes {
                inCall = true
                patienceTicks = 0
                unseenTicks = 0
                answered = .named(call.identity)
                fire(call.platform)
                return
            }
            // Not a sure call yet. Either a browser is on the mic but no
            // window title names the call — the Meet tab is in the
            // background (a window's AX title is its ACTIVE tab's, owner's
            // live repro 2026-08-29) — or a messenger holds it, which is
            // just as likely a voice note being recorded. Twelve seconds of
            // either is a call in all but name: prompt (namelessly for the
            // browser) rather than stay silent through the meeting. A voice
            // note shorter than that releases the mic and resets the count.
            patienceTicks += 1
            if patienceTicks == 1 {
                if let call {
                    Log.d("call: \(call.platform) on mic — waiting out a possible voice note")
                } else {
                    Log.d("call: unidentified holder — \(holders)")
                }
            }
            if patienceTicks >= 3 {
                inCall = true
                patienceTicks = 0
                unseenTicks = 0
                answered = call.map { MeetingPolicy.AnsweredCall.named($0.identity) } ?? .unnamed
                fire(call?.platform)
            }
        } else {
            patienceTicks = 0
            if inCall {
                unseenTicks += 1
                quietTicks += 1
                if quietTicks == 1 { Log.d("call: holder quiet") }
                // Five ticks (~20 s), not two: a live Meet releases the mic
                // for ~10 s stretches around its lobby and permission
                // screens, and an 8 s patience read each one as the call
                // ending — three prompts in one meeting.
                if quietTicks >= 5 {
                    inCall = false
                    quietTicks = 0
                    answered = .nothing
                    unseenTicks = 0
                    Log.d("call: over (quiet \(5 * 4)s)")
                    onCallOver?()
                }
            }
        }
    }

    /// Latched, and something still holds the microphone. The only question
    /// left is whether this is still the call already answered for — a second
    /// meeting can begin without the mic ever going quiet between them, and
    /// that is precisely what used to go unannounced.
    private func stillTheSameCall(_ call: (platform: String, identity: String)?) {
        guard let call else { unseenTicks += 1; return }
        if MeetingPolicy.isASecondCall(identity: call.identity,
                                       answered: answered,
                                       unseenTicks: unseenTicks) {
            Log.d("call: a second call inside the same microphone episode")
            fire(call.platform)
        }
        // Either way this is now the call we have answered for: absorbing the
        // title keeps a call that gets RETITLED mid-way from reading as new.
        answered = .named(call.identity)
        unseenTicks = 0
    }
}
