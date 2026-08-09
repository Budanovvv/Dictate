import Foundation
import AppKit
import Combine

/// One recorded meeting: two audio channels — You (the microphone, through
/// the same battle-tested AudioRecorder the dictation uses, so a mic held by
/// the meeting app in voice processing still records) and Them (everyone
/// else, through the global process tap) — cut into utterance windows at
/// natural pauses, transcribed locally, and appended to a live Markdown file
/// the user can watch grow. Everything stays on this Mac.
final class MeetingSession: ObservableObject {

    private(set) var isActive = false
    /// The transcript file of the running (or last) session.
    private(set) var fileURL: URL?
    /// Fired on main when the session has fully finished (tail transcribed,
    /// file closed).
    var onFinished: ((URL) -> Void)?

    /// Mirror of the transcript for the live window, in the exact order the
    /// file gets the lines. Capped so an hours-long session can't grow an
    /// unbounded array — the file remains the full record.
    struct DisplayEntry: Identifiable {
        let id = UUID()
        let time: String
        let speaker: String
        let text: String
        let isYou: Bool
    }
    @Published private(set) var displayEntries: [DisplayEntry] = []
    /// Windows currently being recognized — the window shows a subtle
    /// "Recognizing…" row while any are in flight.
    @Published private(set) var inflightCount = 0
    /// Seconds of speech accumulating in a not-yet-cut window (nil = nothing
    /// heard right now). Drives the "Listening…" row — without it, the quiet
    /// stretch between speaking and the first cut read as "not working"
    /// (owner's own field feedback, 2026-08-09 15:55).
    @Published private(set) var listeningFor: Int?
    /// Volatile decode of the utterance still being spoken — the transcript
    /// window's gray "current line", superseded by the final entry at the
    /// cut. Same idea as the dictation pill's live text.
    @Published private(set) var livePreview: String?
    /// Whisper is still loading into memory — the window says so instead of
    /// sitting silent (cold-start field complaint: "не видно ни хрена…
    /// потом разогрелось", 2026-08-09 16:25).
    @Published private(set) var modelWarming = false
    /// The meeting app released the mic — the call is ending; the window
    /// says so while the auto-stop confirmation window runs.
    @Published private(set) var callEnding = false
    /// Combined mic+tap audio level 0…1 for the window's equalizer — the
    /// "you are being heard" signal, same philosophy as the HUD's dancing
    /// bars meaning "sound is really being captured".
    @Published private(set) var audioLevel: Double = 0
    private var previewBusy = false
    private var previewTicks = 0
    var startedAt: Date { sessionStart }

    private let tap = MeetingTap()
    private let mic = AudioRecorder()
    private let diarizer = MeetingDiarizer()
    private var tick: Timer?
    private var sessionStart = Date()
    private var fileHandle: FileHandle?
    private var stopping = false
    private let cancelled = CancelToken()

    // Them: accumulated 16k Int16 PCM of the current window.
    private var themPCM = Data()
    private var themWindowStart: TimeInterval = 0
    // You: audio lives in the recorder (hot rollover cuts it); we track time.
    private var youWindowStart: TimeInterval = 0
    // Pause detection is Silero VAD on the last second of each accumulating
    // window — energy thresholds failed twice in one day (fixed 0.08 on the
    // no-AEC path, then the adaptive floor the owner still out-talked). The
    // neural gate already decides "was this speech" before Whisper; now it
    // also decides "has the speech stopped". lastSpeechAt is when a tail
    // check last HEARD speech; a check finding silence leaves it stale, and
    // a stale value ≥ silenceCut cuts the window.
    private var youLastSpeechAt: TimeInterval?
    private var themLastSpeechAt: TimeInterval?
    /// When speech FIRST appeared in the current window — the entry's honest
    /// timestamp (a window can start with seconds of silence) and the
    /// channel's flush-frontier pin. Estimated as the VAD hit time minus the
    /// tail length it inspected.
    private var youFirstSpeechAt: TimeInterval?
    private var themFirstSpeechAt: TimeInterval?
    private var youTailBusy = false
    private var themTailBusy = false
    // Tap health: the tap delivers buffers CONTINUOUSLY (zeros when the
    // system is silent), so a stalled buffer flow means the tap died (e.g.
    // an output-device change mid-meeting) — never mere silence.
    private var lastTapBufferAt = Date()
    private var lastTapRestartAt = Date.distantPast
    // Diagnostics for the field test: windows cut / entries written.
    private var statWindows = 0
    private var statEntries = 0
    private var ticksSinceHeartbeat = 0

    private struct Entry {
        let start: TimeInterval
        let speaker: String
        let text: String
        let you: Bool
    }

    /// Keeps the Mac awake while a session runs: the browser usually holds
    /// its own assertion during a call, but the recording must survive the
    /// call tab closing early or a meeting happening outside the browser —
    /// system sleep would silently kill both capture chains (the sleep
    /// grabla, meeting edition).
    private var powerActivity: NSObjectProtocol?
    /// Recognition backpressure: with this many windows already in the
    /// Whisper queue, speech cuts are held (windows keep accumulating and
    /// merge) — the dictation pipeline's maxQueuedJobs lesson. Unbounded
    /// growth here would eat memory and make Stop "drain" for minutes.
    private static let maxInflightWindows = 4
    private var backpressureLogged = false

    // Auto-stop when the call ends: while a call runs, the meeting app holds
    // the mic (the busy-mic detector's own machinery says who); when it
    // releases AND the remote channel stays speechless, the call is over —
    // keeping the room recording after that is a privacy failure.
    private var sawForeignMicHold = false
    private var lastOtherMicUserAt: TimeInterval = 0
    private var micPollTicks = 0
    private var pending: [Entry] = []
    private var inflight: [String: TimeInterval] = [:]   // key → window start
    private var inflightSeq = 0

    private var now: TimeInterval { Date().timeIntervalSince(sessionStart) }

    // MARK: - Lifecycle

    func start() throws {
        guard !isActive else { return }
        sessionStart = Date()
        themPCM = Data()
        pending = []
        inflight = [:]
        stopping = false
        themWindowStart = 0; themLastSpeechAt = nil; themFirstSpeechAt = nil; themTailBusy = false
        youWindowStart = 0; youLastSpeechAt = nil; youFirstSpeechAt = nil; youTailBusy = false

        displayEntries = []
        inflightCount = 0
        listeningFor = nil
        livePreview = nil
        previewBusy = false
        previewTicks = 0
        try openTranscriptFile()
        // Voice separation warms up in parallel (first ever run downloads its
        // CoreML models); until it's ready Them-entries just stay collective.
        Task { await diarizer.startSession(); await diarizer.prepare() }
        // Whisper warms up too: a meeting started right after app launch
        // would otherwise lose its first windows to a not-yet-loaded model
        // (the "warm-up fired once and died silently" onboarding grabla).
        // The window shows the warming state honestly meanwhile.
        modelWarming = true
        Task {
            if await WhisperEngine.shared.isReady(for: .fast) {
                await MainActor.run { self.modelWarming = false }
                return
            }
            do { try await WhisperEngine.shared.prepare(tier: .fast) { _ in } }
            catch { Log.d("meeting: whisper prepare failed: \(error.localizedDescription)") }
            await MainActor.run { self.modelWarming = false }
        }
        powerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Meeting transcript recording")
        backpressureLogged = false
        try tap.start()   // first run triggers the system-audio TCC prompt
        tap.onBuffer = { [weak self] pcm, peak in
            DispatchQueue.main.async { self?.appendThem(pcm, peak: peak) }
        }
        // The recorder retries a failing input for ~4.5 s on its own; this
        // fires only when it truly gave up (device vanished). One delayed
        // restart attempt — a meeting must not lose its You channel to a
        // transient device hiccup, and must not spin on a permanent one.
        mic.onRecoveryFailed = { [weak self] _ in
            guard let self, self.isActive else { return }
            Log.d("meeting: mic channel failed — retrying in 3s")
            _ = self.mic.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.isActive else { return }
                self.youWindowStart = self.now
                self.mic.start()
            }
        }
        lastTapBufferAt = Date()
        lastTapRestartAt = .distantPast
        statWindows = 0
        statEntries = 0
        ticksSinceHeartbeat = 0
        sawForeignMicHold = false
        lastOtherMicUserAt = 0
        micPollTicks = 0
        // The window's equalizer: mic level drives it directly (delivered on
        // main by AudioRecorder); the tap side feeds it from appendThem.
        mic.onLevel = { [weak self] level in
            guard let self, self.isActive else { return }
            self.audioLevel = max(level, self.audioLevel * 0.7)
        }
        mic.start()
        isActive = true
        // 0.5 s cadence is the window-cut resolution — half the shortest
        // silence gap we cut on.
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.evaluateWindows()
        }
        Log.d("meeting: session started -> \(fileURL?.lastPathComponent ?? "?")")
    }

    /// Stops capture; the file is finalized asynchronously once the last
    /// windows finish recognizing (onFinished fires then).
    func stop() {
        guard isActive, !stopping else { return }
        stopping = true
        tick?.invalidate()
        tick = nil
        // Final cut of both channels — whatever was mid-utterance still lands.
        // The Silero gate inside transcribeWindow re-checks anyway, so err on
        // transcribing (a tail VAD check may simply not have run yet).
        cutYouWindow(transcribe: (youLastSpeechAt ?? youWindowStart) >= youWindowStart)
        cutThemWindow(transcribe: (themLastSpeechAt ?? -1) >= themWindowStart)
        _ = mic.stop()
        tap.stop()
        isActive = false
        listeningFor = nil
        livePreview = nil
        modelWarming = false
        callEnding = false
        audioLevel = 0
        if let activity = powerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            powerActivity = nil
        }
        Log.d("meeting: session stopping, \(inflight.count) window(s) still recognizing")
        finalizeIfDrained()
    }

    // MARK: - Channels

    private func appendThem(_ pcm: Data, peak: Double) {
        guard isActive, !stopping else { return }
        lastTapBufferAt = Date()
        themPCM.append(pcm)
        // Their voices move the equalizer too — "hearing the call" is as
        // important a signal as "hearing you".
        let level = min(1.0, peak * 3)
        if level > audioLevel { audioLevel = level }
    }

    private func evaluateWindows() {
        guard isActive, !stopping else { return }
        let t = now

        // Dead-tap self-healing: no buffers at all for 5 s = the tap is gone
        // (an output-device change can kill the aggregate). Restart it, at
        // most once per 30 s so a permanently broken tap doesn't thrash.
        if Date().timeIntervalSince(lastTapBufferAt) > 5,
           Date().timeIntervalSince(lastTapRestartAt) > 30 {
            lastTapRestartAt = Date()
            Log.d("meeting: tap buffer flow stalled — recreating the tap")
            tap.stop()
            do { try tap.start() } catch {
                Log.d("meeting: tap restart failed: \(error.localizedDescription)")
            }
            lastTapBufferAt = Date()   // fresh grace for the restarted tap
        }

        // Call-end detection, every ~5 s: does any OTHER app still hold the
        // mic? (Our own recorder is excluded.) The enumeration is the same
        // Core Audio process walk the busy-mic culprit naming uses.
        micPollTicks += 1
        if micPollTicks >= 10 {
            micPollTicks = 0
            let ourPID = ProcessInfo.processInfo.processIdentifier
            if !AudioInputDevices.appsRunningInput(excluding: ourPID).isEmpty {
                if !sawForeignMicHold {
                    sawForeignMicHold = true
                    Log.d("meeting: call detected (another app holds the mic)")
                }
                lastOtherMicUserAt = t
                if callEnding { callEnding = false }   // the call came back
            } else if sawForeignMicHold, !callEnding {
                // Mic released after a detected call: announce the pending
                // auto-stop instead of looking like it didn't notice.
                callEnding = true
                Log.d("meeting: mic released — call ending")
            }
            let remoteQuietFor = t - (themLastSpeechAt ?? 0)
            if MeetingPolicy.callLikelyOver(sawForeignHold: sawForeignMicHold,
                                            micFreeFor: t - lastOtherMicUserAt,
                                            remoteQuietFor: remoteQuietFor) {
                Log.d(String(format: "meeting: call over (mic free %.0fs, remote quiet %.0fs) — auto-stopping",
                             t - lastOtherMicUserAt, remoteQuietFor))
                stop()
                return
            }
        }

        // Once a minute: a heartbeat for the field-test log.
        ticksSinceHeartbeat += 1
        if ticksSinceHeartbeat >= 120 {
            ticksSinceHeartbeat = 0
            Log.d(String(format: "meeting: %.0f min, windows=%d entries=%d pending=%d inflight=%d",
                         t / 60, statWindows, statEntries, pending.count, inflight.count))
        }

        // Neural pause detection: Silero over the last second of each
        // accumulating window. Energy thresholds failed twice in one field
        // day; the VAD hears "speech stopped" regardless of the capture
        // path's noise floor.
        scheduleTailChecks(t)

        // "Listening…" feedback: some window holds speech that hasn't been
        // cut yet — show for how long, so accumulation never looks dead.
        var oldestSpeech: TimeInterval?
        if (youLastSpeechAt ?? -1) >= youWindowStart { oldestSpeech = youWindowStart }
        if (themLastSpeechAt ?? -1) >= themWindowStart {
            oldestSpeech = min(oldestSpeech ?? themWindowStart, themWindowStart)
        }
        let newListening = oldestSpeech.map { Int(t - $0) }
        if newListening != listeningFor { listeningFor = newListening }

        // Backpressure: a saturated recognition queue holds speech cuts —
        // the windows keep accumulating and merge into one bigger utterance
        // instead of growing an unbounded backlog. Silence drops still run
        // (they cost no recognition).
        let saturated = inflight.count >= Self.maxInflightWindows
        if saturated != backpressureLogged {
            backpressureLogged = saturated
            Log.d(saturated
                ? "meeting: recognition backlog (\(inflight.count)) — holding window cuts"
                : "meeting: recognition backlog cleared")
        }

        let youVerdict = MeetingPolicy.windowVerdict(
            accumulated: t - youWindowStart,
            hadSpeech: (youLastSpeechAt ?? -1) >= youWindowStart,
            sinceLoud: t - (youLastSpeechAt ?? -.infinity))
        switch youVerdict {
        case .keep: break
        case .cutTranscribe: if !saturated { cutYouWindow(transcribe: true) }
        case .dropSilence: cutYouWindow(transcribe: false)
        }

        let themVerdict = MeetingPolicy.windowVerdict(
            accumulated: t - themWindowStart,
            hadSpeech: (themLastSpeechAt ?? -1) >= themWindowStart,
            sinceLoud: t - (themLastSpeechAt ?? -.infinity))
        switch themVerdict {
        case .keep: break
        case .cutTranscribe: if !saturated { cutThemWindow(transcribe: true) }
        case .dropSilence: cutThemWindow(transcribe: false)
        }

        // Live current-line preview, the same idea as the dictation pill's
        // live text: every ~1 s the active window's audio gets a quick
        // decode and the volatile text shows at the bottom of the transcript
        // window. The re-decode architecture caps how live this can feel
        // (~2 s lag, the live-typing ceiling of 5н) — the fast cadence at
        // least lets short phrases occasionally make it to the screen.
        previewTicks += 1
        if previewTicks >= 2 {
            previewTicks = 0
            updateLivePreview(t)
        }
    }

    /// Runs the Silero gate over the trailing second of each channel that has
    /// enough audio; a check that HEARS speech refreshes lastSpeechAt, one
    /// that hears silence leaves it stale — staleness is what cuts windows.
    private func scheduleTailChecks(_ t: TimeInterval) {
        let tailBytes = AudioRecorder.sampleRate * 2   // 1 s of Int16 mono
        if !youTailBusy, t - youWindowStart >= 1.0 {
            youTailBusy = true
            let tail = Data(mic.currentPCM().suffix(tailBytes))
            Task {
                let speech = await SpeechGate.shared.hasSpeech(
                    AudioRecorder.floatSamples(fromPCM: tail)) ?? true
                await MainActor.run {
                    self.youTailBusy = false
                    guard speech, t >= self.youWindowStart else { return }
                    self.youLastSpeechAt = t
                    if (self.youFirstSpeechAt ?? -1) < self.youWindowStart {
                        self.youFirstSpeechAt = max(self.youWindowStart, t - 1.5)
                    }
                }
            }
        }
        if !themTailBusy, themPCM.count >= tailBytes {
            themTailBusy = true
            let tail = Data(themPCM.suffix(tailBytes))
            Task {
                let speech = await SpeechGate.shared.hasSpeech(
                    AudioRecorder.floatSamples(fromPCM: tail)) ?? true
                await MainActor.run {
                    self.themTailBusy = false
                    guard speech, t >= self.themWindowStart else { return }
                    self.themLastSpeechAt = t
                    if (self.themFirstSpeechAt ?? -1) < self.themWindowStart {
                        self.themFirstSpeechAt = max(self.themWindowStart, t - 1.5)
                    }
                }
            }
        }
    }

    /// One quick decode of the most recently active window; the result shows
    /// as the gray volatile line. Skips itself while a previous pass (or the
    /// recognition queue) is busy — the preview must never delay a final.
    private func updateLivePreview(_ t: TimeInterval) {
        guard !previewBusy else { return }
        // Yield to finals — the dictation preview's lesson, relearned here in
        // the field: previews and final recognitions share one Whisper actor,
        // and at a 1 s cadence during nonstop speech the previews queued the
        // finals into visible lag (passes degraded 1.2s → 5.8s, run
        // 2026-08-09 17:16). The transcript IS the finals; the live line
        // gets the leftover cycles.
        guard inflightCount == 0 else { return }
        let youActive = (youLastSpeechAt ?? -1) >= youWindowStart
        let themActive = (themLastSpeechAt ?? -1) >= themWindowStart
        guard youActive || themActive else {
            if livePreview != nil { livePreview = nil }
            return
        }
        let useYou = youActive && (!themActive || (youLastSpeechAt ?? 0) >= (themLastSpeechAt ?? 0))
        let pcm = useYou ? mic.currentPCM() : themPCM
        // 0.7 s of audio is enough for a first hypothesis — a 3-second
        // phrase deserves at least one shot at the live line.
        guard pcm.count >= Int(Double(AudioRecorder.sampleRate) * 1.4) else { return }
        let windowStart = useYou ? youWindowStart : themWindowStart
        previewBusy = true
        Task {
            defer { DispatchQueue.main.async { self.previewBusy = false } }
            guard await WhisperEngine.shared.isReady(for: .fast) else { return }
            let floats = AudioRecorder.floatSamples(fromPCM: pcm)
            let window = Array(floats.suffix(15 * AudioRecorder.sampleRate))
            let started = Date()
            guard let (text, _) = try? await WhisperEngine.shared.transcribe(
                floats: window, tier: .fast, language: "", prompt: "",
                isCancelled: { [weak self] in self?.isActive != true }) else { return }
            Log.d(String(format: "meeting: preview %.2fs over %.1fs audio (%@)",
                         Date().timeIntervalSince(started),
                         Double(window.count) / Double(AudioRecorder.sampleRate),
                         useYou ? "you" : "them"))
            await MainActor.run {
                // The window may have been cut while we decoded — the final
                // entry supersedes this hypothesis.
                let stillCurrent = useYou ? self.youWindowStart == windowStart
                                         : self.themWindowStart == windowStart
                guard self.isActive, stillCurrent, !text.isEmpty else { return }
                self.livePreview = text
            }
        }
    }

    private enum Channel { case you, them }

    private func cutYouWindow(transcribe shouldTranscribe: Bool) {
        // The entry carries the moment speech STARTED, not the window's
        // (possibly silence-padded) start — honest timestamps, free-flowing
        // flush frontier.
        let start = youFirstSpeechAt ?? youWindowStart
        // Hot rollover: hands back the window and keeps recording — the same
        // no-teardown path the dictation key rollover uses.
        let (pcm, duration) = mic.rollover()
        youWindowStart = now
        youFirstSpeechAt = nil
        livePreview = nil   // the final entry supersedes the hypothesis
        Log.d(String(format: "meeting: cut you %.1fs %@", duration,
                     shouldTranscribe ? "speech" : "silence"))
        guard shouldTranscribe, duration >= 0.5 else { return }
        transcribeWindow(pcm: pcm, start: start, channel: .you)
    }

    private func cutThemWindow(transcribe shouldTranscribe: Bool) {
        let start = themFirstSpeechAt ?? themWindowStart
        let pcm = themPCM
        themPCM = Data()
        themWindowStart = now
        themFirstSpeechAt = nil
        livePreview = nil   // the final entry supersedes the hypothesis
        let duration = Double(pcm.count) / Double(AudioRecorder.sampleRate * 2)
        Log.d(String(format: "meeting: cut them %.1fs %@", duration,
                     shouldTranscribe ? "speech" : "silence"))
        guard shouldTranscribe, pcm.count >= AudioRecorder.sampleRate else { return } // ≥0.5s
        transcribeWindow(pcm: pcm, start: start, channel: .them)
    }

    // MARK: - Recognition

    private func transcribeWindow(pcm: Data, start: TimeInterval, channel: Channel) {
        inflightSeq += 1
        statWindows += 1
        let key = "\(channel)#\(inflightSeq)"
        inflight[key] = start
        inflightCount = inflight.count
        // Meetings auto-detect the language PER UTTERANCE, ignoring the
        // dictation language setting: a meeting is often not in the user's
        // dictation language (English standup, mixed-language calls), and a
        // pinned wrong language makes Whisper mangle the text.
        let language = ""
        Task {
            let floats = AudioRecorder.floatSamples(fromPCM: pcm)
            // Silero gate: a window can pass the level heuristic on a cough
            // or keyboard noise — don't wake Whisper for it (it hallucinates
            // on non-speech).
            let speech = await SpeechGate.shared.hasSpeech(floats) ?? true
            var text = ""
            var ordinal: Int?
            if speech, !self.cancelled.isCancelled {
                // Who is talking (Them only): the diarizer numbers the mixed
                // stream's voices — "Speaker 1/2…". You needs no ML: the mic
                // channel IS the attribution.
                if channel == .them {
                    ordinal = await self.diarizer.speakerOrdinal(floats: floats, atTime: start)
                }
                // Late-start safety: if the model still isn't loaded (meeting
                // started seconds after app launch), load it now instead of
                // silently losing this window.
                if !(await WhisperEngine.shared.isReady(for: .fast)) {
                    try? await WhisperEngine.shared.prepare(tier: .fast) { _ in }
                }
                // Edge silence is trimmed exactly like a dictation's (edge
                // hallucinations, speed); the VAD gate above saw the FULL
                // window, and the diarizer did too (its offsets stay honest).
                let speechFloats = AudioRecorder.trimSilence(floats)
                // No user prompt and no replacements: a meeting transcript is
                // a verbatim record, not a dictation being typed.
                text = (try? await WhisperEngine.shared.transcribe(
                    floats: speechFloats, tier: .fast, language: language, prompt: "",
                    isCancelled: { self.cancelled.isCancelled }))?.0 ?? ""
            }
            await MainActor.run {
                self.inflight.removeValue(forKey: key)
                self.inflightCount = self.inflight.count
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let speaker: String
                    switch channel {
                    case .you: speaker = L("You")
                    case .them: speaker = ordinal.map { Lf("Speaker %d", $0) } ?? L("Them")
                    }
                    self.pending.append(Entry(start: start, speaker: speaker,
                                              text: trimmed, you: channel == .you))
                }
                self.flushReadyEntries()
                self.finalizeIfDrained()
            }
        }
    }

    // MARK: - Ordered writing

    private func flushReadyEntries() {
        pending.sort { $0.start < $1.start }
        // While stopping there are no live windows — only in-flight
        // recognitions gate the flush. Live frontiers pin only where speech
        // actually is; a silent channel vouches for all but the last ~2.5 s
        // (see MeetingPolicy.channelFrontier — the batched-dump fix).
        let t = now
        let frontiers = stopping ? [] : [
            MeetingPolicy.channelFrontier(windowStart: youWindowStart,
                                          firstSpeechAt: youFirstSpeechAt, now: t),
            MeetingPolicy.channelFrontier(windowStart: themWindowStart,
                                          firstSpeechAt: themFirstSpeechAt, now: t),
        ]
        let n = MeetingPolicy.flushableCount(sortedStarts: pending.map(\.start),
                                             channelFrontiers: frontiers,
                                             inflightStarts: Array(inflight.values))
        guard n > 0 else { return }
        for entry in pending.prefix(n) {
            write("**[\(clock(entry.start))] \(entry.speaker):** \(entry.text)\n\n")
            displayEntries.append(DisplayEntry(time: clock(entry.start),
                                               speaker: entry.speaker,
                                               text: entry.text,
                                               isYou: entry.you))
        }
        if displayEntries.count > 500 {
            displayEntries.removeFirst(displayEntries.count - 500)
        }
        statEntries += n
        pending.removeFirst(n)
    }

    private func finalizeIfDrained() {
        guard stopping, inflight.isEmpty, let url = fileURL else { return }
        flushReadyEntries()   // frontiers are gone; everything pending goes out
        stopping = false
        try? fileHandle?.close()
        fileHandle = nil
        Log.d("meeting: transcript finished -> \(url.lastPathComponent)")
        onFinished?(url)
    }

    // MARK: - File

    private func openTranscriptFile() throws {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let url = dir.appendingPathComponent("Meeting \(stamp.string(from: Date())).md")
        let header = "# \(L("Meeting transcript")) — \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))\n\n"
        try header.data(using: .utf8)!.write(to: url)
        fileHandle = try FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        fileURL = url
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    private func clock(_ offset: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: sessionStart.addingTimeInterval(offset))
    }
}
