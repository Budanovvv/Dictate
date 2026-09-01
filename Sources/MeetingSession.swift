import Foundation
import AppKit
import Combine
import CoreAudio

/// Lock-guarded mirror of `MeetingSession.isActive` for the one reader that
/// lives off the main actor: Whisper's decode callback polls it mid-window
/// (the preview's early-stop) from the decode thread. Same shape as the
/// house CancelToken (DictationController.swift), but settable — a session
/// starts and stops many times per app run.
private final class ActiveMirror: @unchecked Sendable {   // NSLock guards flag
    private let lock = NSLock()
    private var flag = false
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ value: Bool) { lock.lock(); flag = value; lock.unlock() }
}

/// One recorded meeting: two audio channels — You (the microphone, through
/// the same battle-tested AudioRecorder the dictation uses, so a mic held by
/// the meeting app in voice processing still records) and Them (everyone
/// else, through the global process tap) — cut into utterance windows at
/// natural pauses, transcribed locally, and appended to a live Markdown file
/// the user can watch grow. Everything stays on this Mac.
///
/// Main-actor confined: the control surface (start/stop/rename), the timers
/// and every @Published property already lived on the main thread by
/// convention — the annotation makes the compiler hold the line. The heavy
/// decode work stays off main in `nonisolated` async members
/// (processWindow/recognize/previewPass), exactly where it ran before; the
/// static call-app probes are `nonisolated` because the detector's
/// background probe calls them from off main by design.
@MainActor
final class MeetingSession: ObservableObject {

    private(set) var isActive = false {
        didSet { activeMirror.set(isActive) }
    }
    /// See ActiveMirror above — the decode callback's off-main read.
    private let activeMirror = ActiveMirror()
    /// The transcript file of the running (or last) session.
    private(set) var fileURL: URL?
    /// Fired on main when the session has fully finished (tail transcribed,
    /// file closed).
    var onFinished: ((URL) -> Void)?

    /// Mirror of the transcript for the live window, in the exact order the
    /// file gets the lines. Capped so an hours-long session can't grow an
    /// unbounded array — the file remains the full record.
    @Published private(set) var displayEntries: [TranscriptEntry] = []
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
    /// Combined mic+tap audio level 0…1 for the window's equalizer — the
    /// "you are being heard" signal, same philosophy as the HUD's dancing
    /// bars meaning "sound is really being captured".
    @Published private(set) var audioLevel: Double = 0
    /// The two streams metered separately — what tells "You" from "Call
    /// audio" in the live window's channel meters. `audioLevel` above
    /// stays the combined meter for the surfaces that show one.
    @Published private(set) var youLevel: Double = 0
    @Published private(set) var themLevel: Double = 0
    /// Between "Stop" and the transcript landing in the library: the last
    /// windows are still recognizing. The pill shows it so the stop click
    /// visibly did something instead of the pill just lingering.
    @Published private(set) var finishing = false
    /// The disk is running out under a live recording (checked every 30 s).
    /// A warning the surfaces show; below the hard floor the session stops
    /// itself and KEEPS the transcript rather than lose the file.
    @Published private(set) var lowDisk = false
    /// The default input changed mid-recording ("Switched to AirPods Pro") —
    /// one quiet line on the pill for a few seconds, recording uninterrupted
    /// (design: interrupted). nil = nothing to say.
    @Published private(set) var deviceNotice: String?
    private var previewBusy = false
    private var previewTicks = 0
    var startedAt: Date { sessionStart }
    /// Voices the user renamed during this session ("Speaker 2" → "Anna").
    private var speakerNames: [String: String] = [:]

    /// Renames a voice in the running session: the lines already written to
    /// the file, everything on screen, and every entry this voice produces
    /// from here on. The file handle is reopened at the end because the
    /// rewrite replaces the whole file underneath it.
    @MainActor
    func renameSpeaker(from old: String, to new: String) {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != old else { return }
        speakerNames[old] = clean
        // Anything already mapped INTO the old name follows it along.
        for (source, current) in speakerNames where current == old { speakerNames[source] = clean }
        // The rename may have collapsed the call side into one person — then
        // the collective Them lines are that person too, the written ones and
        // every one still to come (MeetingSpeakerPolicy.collectiveFoldTarget).
        var relabel = [old]
        let them = L("Them")
        if old != them, old != L("You"), speakerNames[them] != clean,
           MeetingSpeakerPolicy.collectiveFoldTarget(
               renamedTo: clean,
               voiceNames: statOrdinalEntries.keys.map { currentLabel($0) }) != nil {
            speakerNames[them] = clean
            relabel.append(them)
            Log.d("meeting: collective \"\(them)\" follows \"\(clean)\" — the call side has one name")
        }
        displayEntries = displayEntries.map {
            relabel.contains($0.speaker)
                ? TranscriptEntry(id: $0.id, time: $0.time, speaker: clean,
                                  text: $0.text, isYou: $0.isYou, absorbed: $0.absorbed)
                : $0
        }
        guard let url = fileURL else { return }
        try? fileHandle?.close()
        fileHandle = nil
        for label in relabel { MeetingArchive.rename(speaker: label, to: clean, in: url) }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    private let tap = MeetingTap()
    private let mic = AudioRecorder()
    private let diarizer = MeetingDiarizer()
    private var tick: Timer?
    /// 30 s disk-space check while recording (see lowDisk).
    private var diskTimer: Timer?
    /// Re-asks "where is this call running" while the answer is still nil —
    /// the start-of-session check misses a call joined late and a Meet tab
    /// that was not frontmost. Found late, the platform is prepended to the
    /// file when the transcript finishes (parseSource reads the head only).
    private var sourceProbeTimer: Timer?
    private var sourceProbesLeft = 0
    /// The platform the detection card verified and showed ("Google Meet"),
    /// handed in at start. Outranks every re-detection: the session-side
    /// checks run mid-call (main-thread AX under a busy browser, titles
    /// only from active tabs) and measurably never won — 0 sources written
    /// across the first 21 recorded calls.
    private var promptPlatform: String?
    private var lateSource: String?
    private var headerHadSource = false
    /// Core Audio listener on the default input device while recording.
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceNoticeClear: DispatchWorkItem?
    /// The Mac is going to sleep: the recording stops cleanly and the
    /// transcript is marked where it ended (design: interrupted). Idle sleep
    /// is already prevented (powerActivity); this catches a closed lid or an
    /// explicit Sleep, which no assertion can refuse.
    private var sleepObserver: NSObjectProtocol?
    private var endedBySleep = false
    /// Why the recording ended itself, for the transcript's closing marker.
    private var autoStopReason: MeetingPolicy.AutoStopVerdict?
    /// A title-verified call was observed during this session.
    private var platformEverSeen = false
    /// When something call-shaped last held the microphone.
    /// One aliveness probe in flight at a time — a stalled AX call must
    /// not queue up behind itself tick after tick.
    private var probingCall = false
    private var lastPlatformAliveAt: Date?
    /// The last VAD-voiced window on EITHER channel (raw voice, not text).
    private var lastVoicedAt = Date()
    // Per-channel language pinning (owner report 2026-08-28: per-window
    // auto-detect flip-flopped a bilingual caller pt→uk→ru). Votes until one
    // language clearly leads (≥80% of ≥5 windows), then pins; every 8th
    // window still runs in auto as a probe, and two probes disagreeing in a
    // row drop the pin — a caller who really switches languages gets auto
    // back within a minute.
    private var langVotes: [Channel: [String: Int]] = [:]
    private var langPinned: [Channel: String] = [:]
    private var langProbe: [Channel: Int] = [:]
    private var langProbeMisses: [Channel: Int] = [:]
    private var sessionStart = Date()
    private var fileHandle: FileHandle?
    private var stopping = false
    private let cancelled = CancelToken()

    /// Quit-path only: aborts the decode loops mid-window so the process can
    /// exit instead of finishing a long transcription into a dying app. The
    /// token was checked in three places and never tripped — wired up on the
    /// 2026-08-31 review.
    func cancelDecodes() { cancelled.cancel() }

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
    // End-of-session calibration data: how the transcript actually came out
    // per voice. The clustering threshold moved back to 0.7 on three meetings
    // with ground-truth head counts — these tallies plus the diarizer's own are
    // what makes the NEXT such call possible from the log instead of from a
    // hunch. Keyed by the label as WRITTEN (a mid-session rename therefore
    // splits a voice in two here — the tally follows the file, which is the
    // record), and rewritten after an end-of-session merge so the log and the
    // file never disagree.
    private var statSpeakerEntries: [String: Int] = [:]
    private var statSpeakerSeconds: [String: Double] = [:]
    // The same tallies keyed by the diarizer's ordinal instead of the label —
    // the input the micro-cluster rule is fed with. Kept separately because a
    // renamed voice loses its number in the label-keyed tallies, and the rule
    // has to know which number it is judging.
    private var statOrdinalEntries: [Int: Int] = [:]
    private var statOrdinalSeconds: [Int: Double] = [:]
    private var statPhantomsRejected = 0
    private var statLabelsInherited = 0

    /// The last entry written on the tap channel, in file order — what the
    /// lexical inheritance rule reads. You-entries pass it by untouched: the
    /// channels are separate audio, and a remark of the owner's does not
    /// interrupt a sentence arriving from the call.
    private var lastThem: (text: String, ordinal: Int?, start: TimeInterval)?

    /// The name this meeting already had in the calendar, if it was a
    /// scheduled call. Read once at session start — the whole point is that the
    /// transcript carries its real name from the first line rather than being
    /// renamed at the end.
    private(set) var scheduledTitle: String?

    // Debug instruments (hidden defaults, see MeetingReplay.swift): a live
    // session may dump both channels to disk; a replay session takes both
    // channels FROM disk and never touches the mic or the tap. The pipeline
    // between those edges is identical on purpose.
    private var dump: MeetingAudioDump?
    private var replay: MeetingReplay?
    /// The replay's stand-in for the recorder's rolling buffer — the You
    /// channel's audio lives in AudioRecorder during a live session, and the
    /// session cannot inject bytes into it (nor should it: that capture path
    /// is the most grabla-laden code in the project).
    private var replayYouPCM = Data()

    private func currentYouPCM() -> Data {
        replay != nil ? replayYouPCM : mic.currentPCM()
    }

    private func rolloverYou() -> (pcm: Data, duration: Double) {
        guard replay != nil else { return mic.rollover() }
        let pcm = replayYouPCM
        replayYouPCM = Data()
        return (pcm, Double(pcm.count) / Double(AudioRecorder.sampleRate * 2))
    }

    private struct Entry {
        let start: TimeInterval
        let speaker: String
        let text: String
        let you: Bool
        /// Seconds of audio this entry was decoded from — only feeds the
        /// end-of-session per-speaker diagnostics.
        let seconds: Double
        /// Which numbered voice produced it (Them only) — the link between an
        /// entry in the file and a cluster in the voice database.
        let ordinal: Int?
    }

    /// The label a numbered voice writes under, before any renaming.
    /// "Call · voice N", not "Speaker N" (12h): a voice is an acoustic
    /// cluster from the call side, and the old wording claimed a person the
    /// diarizer never identified. Uniform for every count — renaming to a
    /// real name removes it anyway.
    private static func speakerLabel(_ ordinal: Int) -> String {
        Lf("Call · voice %d", ordinal)
    }

    /// The label that voice actually appears under in the file right now.
    private func currentLabel(_ ordinal: Int) -> String {
        let base = Self.speakerLabel(ordinal)
        return speakerNames[base] ?? base
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

    private var pending: [Entry] = []
    private var inflight: [String: TimeInterval] = [:]   // key → window start
    private var inflightSeq = 0

    private var now: TimeInterval { Date().timeIntervalSince(sessionStart) }

    // MARK: - Lifecycle

    /// `fromCallPrompt` marks a session born from the detection card: that
    /// IS a sighted call, whatever the tab titles show later — without it, a
    /// background-tab call never sets platformEverSeen and the forgotten-
    /// recording rule falls back to the slow dead-air path (weak-case
    /// review, 2026-08-29).
    func start(fromCallPrompt: Bool = false, platform: String? = nil) throws {
        guard !isActive else { return }
        sessionStart = Date()
        promptPlatform = platform
        themPCM = Data()
        pending = []
        inflight = [:]
        stopping = false
        themWindowStart = 0; themLastSpeechAt = nil; themFirstSpeechAt = nil; themTailBusy = false
        youWindowStart = 0; youLastSpeechAt = nil; youFirstSpeechAt = nil; youTailBusy = false

        displayEntries = []
        speakerNames = [:]
        inflightCount = 0
        listeningFor = nil
        livePreview = nil
        previewBusy = false
        previewTicks = 0
        try openTranscriptFile()
        // Voice separation warms up in parallel (first ever run downloads its
        // CoreML models); until it's ready Them-entries just stay collective.
        if Settings.shared.separateVoices {
            Task { await diarizer.startSession(); await diarizer.prepare() }
        }
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
        replayYouPCM = Data()
        replay = MeetingReplay.ifRequested()
        if let replay {
            // Canned channels: the mic and the tap are never started, so a
            // replay run needs no devices, no TCC and no meeting actually
            // happening. Everything downstream of the append paths is the
            // real pipeline.
            replay.onYou = { [weak self] pcm, peak in
                guard let self, self.isActive, !self.stopping else { return }
                self.replayYouPCM.append(pcm)
                let level = min(1.0, peak * 3)
                if level > self.audioLevel { self.audioLevel = level }
            }
            replay.onThem = { [weak self] pcm, peak in
                self?.appendThem(pcm, peak: peak)
            }
            replay.start()
        } else if Settings.shared.recordCallAudio {
            // The sink is set BEFORE start(): the CoreAudio IO thread reads
            // onBuffer as soon as the tap runs, and an assignment racing it
            // from the main thread could drop the first buffers (review
            // find, 2026-08-31).
            tap.onBuffer = { @Sendable [weak self] pcm, peak in
                guard let self else { return }
                DispatchQueue.main.async {
                    // Hopped from the tap's IO thread via the main queue —
                    // FIFO, so buffer order survives the crossing.
                    MainActor.assumeIsolated { self.appendThem(pcm, peak: peak) }
                }
            }
            do {
                try tap.start()   // first run triggers the system-audio TCC prompt
            } catch {
                // The throw above this point would leak the started state:
                // the sleep-blocking activity stays on (the Mac never idles
                // again until the next successful start) and the transcript
                // file handle stays open. Undo both before rethrowing.
                if let activity = powerActivity {
                    ProcessInfo.processInfo.endActivity(activity)
                    powerActivity = nil
                }
                try? fileHandle?.close()
                fileHandle = nil
                throw error
            }
            // The recorder retries a failing input for ~4.5 s on its own; this
            // fires only when it truly gave up (device vanished). One delayed
            // restart attempt — a meeting must not lose its You channel to a
            // transient device hiccup, and must not spin on a permanent one.
            mic.onRecoveryFailed = { @Sendable [weak self] _ in
                guard let self else { return }
                // Fired via DispatchQueue.main.async in AudioRecorder's
                // rebuildInputChain — already the main thread.
                MainActor.assumeIsolated {
                    guard self.isActive else { return }
                    Log.d("meeting: mic channel failed — retrying in 3s")
                    _ = self.mic.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self else { return }
                        // asyncAfter on the main queue — still the main actor.
                        MainActor.assumeIsolated {
                            guard self.isActive else { return }
                            self.youWindowStart = self.now
                            self.mic.start()
                        }
                    }
                }
            }
            // A dump only ever records a LIVE meeting — dumping a replay
            // would copy the source files at worse fidelity.
            dump = MeetingAudioDump.ifRequested(
                stem: fileURL?.deletingPathExtension().lastPathComponent ?? "meeting")
        }
        lastTapBufferAt = Date()
        lastTapRestartAt = .distantPast
        statWindows = 0
        statEntries = 0
        ticksSinceHeartbeat = 0
        statSpeakerEntries = [:]
        statSpeakerSeconds = [:]
        statOrdinalEntries = [:]
        statOrdinalSeconds = [:]
        statPhantomsRejected = 0
        statLabelsInherited = 0
        lastThem = nil
        // The window's equalizer: mic level drives it directly (delivered on
        // main by AudioRecorder); the tap side feeds it from appendThem.
        if replay == nil {
            mic.onLevel = { @Sendable [weak self] level in
                guard let self else { return }
                // AudioRecorder documents onLevel as delivered on main.
                MainActor.assumeIsolated {
                    guard self.isActive else { return }
                    self.audioLevel = max(level, self.audioLevel * 0.7)
                    self.youLevel = max(level, self.youLevel * 0.7)
                }
            }
            mic.start()
        }
        isActive = true
        // 0.5 s cadence is the window-cut resolution — half the shortest
        // silence gap we cut on.
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Scheduled from the main actor, so the timer fires on the main runloop.
            MainActor.assumeIsolated { self.evaluateWindows() }
        }
        Log.d("meeting: session started -> \(fileURL?.lastPathComponent ?? "?")")
        // A recording that fills the disk loses the FILE, not just the tail —
        // watch the volume and stop early enough to keep everything written.
        diskTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Scheduled from the main actor, so the timer fires on the main runloop.
            MainActor.assumeIsolated { self.checkDiskSpace() }
        }
        autoStopReason = nil
        lastVoicedAt = Date()
        platformEverSeen = fromCallPrompt
        lastPlatformAliveAt = fromCallPrompt ? Date() : nil
        langVotes = [:]
        langPinned = [:]
        langProbe = [:]
        langProbeMisses = [:]
        installDeviceListener()
        // Sleep the assertion cannot refuse (lid closed, explicit Sleep):
        // stop cleanly NOW, while the file can still be finalized — and mark
        // the transcript where it ended so nothing after it is guessed.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Delivered on OperationQueue.main (the queue: .main above).
            MainActor.assumeIsolated {
                guard self.isActive else { return }
                Log.d("meeting: Mac going to sleep — stopping to keep the transcript")
                self.endedBySleep = true
                self.stop()
            }
        }
    }

    /// Watches the system default input while recording. A device change does
    /// NOT interrupt the capture; the pill just says what happened, because a
    /// couple of seconds around the switch can be thin on the mic side.
    private func installDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // Hopped onto the main queue — the main actor.
                MainActor.assumeIsolated { self.noteDeviceChange() }
            }
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    private func removeDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        deviceListenerBlock = nil
        deviceNoticeClear?.cancel()
        deviceNoticeClear = nil
        deviceNotice = nil
    }

    private func noteDeviceChange() {
        guard isActive else { return }
        let name = AudioInputDevices.defaultInputName()
        deviceNotice = name.map { Lf("Switched to %@", $0) }
            ?? L("Input device changed")
        Log.d("meeting: default input changed -> \(name ?? "?")")
        deviceNoticeClear?.cancel()
        let work = DispatchWorkItem { @Sendable [weak self] in
            guard let self else { return }
            // Scheduled on the main queue below — the main actor.
            MainActor.assumeIsolated { self.deviceNotice = nil }
        }
        deviceNoticeClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    /// Stops capture; the file is finalized asynchronously once the last
    /// windows finish recognizing (onFinished fires then).
    func stop() {
        guard isActive, !stopping else { return }
        stopping = true
        finishing = true
        diskTimer?.invalidate()
        diskTimer = nil
        sourceProbeTimer?.invalidate()
        sourceProbeTimer = nil
        removeDeviceListener()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        tick?.invalidate()
        tick = nil
        // Final cut of both channels — whatever was mid-utterance still lands.
        // The Silero gate inside transcribeWindow re-checks anyway, so err on
        // transcribing (a tail VAD check may simply not have run yet).
        cutYouWindow(transcribe: (youLastSpeechAt ?? youWindowStart) >= youWindowStart)
        cutThemWindow(transcribe: (themLastSpeechAt ?? -1) >= themWindowStart)
        if let replay {
            replay.stop()
            self.replay = nil
        } else {
            _ = mic.stop()
            tap.stop()
        }
        dump?.close()
        dump = nil
        isActive = false
        listeningFor = nil
        livePreview = nil
        modelWarming = false
        audioLevel = 0
        youLevel = 0
        themLevel = 0
        if let activity = powerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            powerActivity = nil
        }
        Log.d("meeting: session stopping, \(inflight.count) window(s) still recognizing")
        finalizeIfDrained()
    }

    /// Which known call app holds the microphone right now — "Zoom",
    /// "FaceTime"… Browsers hold it for every web call alike, so they name no
    /// platform (nil → the library's "other" bucket). Best-effort by design.
    /// The one list of call apps — the detector's map and the aliveness
    /// test read the same names, so they can never drift apart.
    /// The probe family below is `nonisolated`: CallDetector and the
    /// forgotten-recording check call it from Task.detached — the AX walks
    /// are synchronous IPC that must never run on (or require) the main
    /// actor.
    private nonisolated static let callApps: [(fragment: String, name: String)] = [
        ("zoom", "Zoom"), ("teams", "Microsoft Teams"), ("facetime", "FaceTime"),
        ("webex", "Webex"), ("discord", "Discord"), ("slack", "Slack"),
    ]

    nonisolated static func detectCallApp() -> String? {
        let names = AudioInputDevices.appsRunningInput(excluding: ProcessInfo.processInfo.processIdentifier)
        for name in names {
            let lower = name.lowercased()
            if let hit = callApps.first(where: { lower.contains($0.fragment) }) { return hit.name }
        }
        // A browser holding the mic is a web call — Meet above all, which
        // never appears as an app. The browser's window titles name the
        // platform (MeetingPolicy.callPlatform), read through the same
        // Accessibility permission dictation already types with. Only the
        // active tab titles a window, so a miss here is retried by the
        // session's source probe.
        for name in names where MeetingPolicy.isBrowser(appNamed: name) {
            if let hit = browserCallPlatform(appNamed: name) { return hit }
        }
        return nil
    }

    /// One diagnostic line for the detector's log: who holds the mic, and
    /// what the browsers' window titles actually say — the evidence when a
    /// call was there and the title check could not name it.
    nonisolated static func debugCallHolders() -> String {
        let names = AudioInputDevices.appsRunningInput(excluding: ProcessInfo.processInfo.processIdentifier)
        var parts = ["holders: " + names.joined(separator: ", ")]
        for name in names where MeetingPolicy.isBrowser(appNamed: name) {
            let titles = browserWindowTitles(appNamed: name).map { String($0.prefix(40)) }
            parts.append("\(name) windows: " + titles.joined(separator: " | "))
        }
        return parts.joined(separator: "; ")
    }

    /// Is anything call-shaped holding the microphone RIGHT NOW — a known
    /// call app, or a browser regardless of which tab is frontmost? This is
    /// the auto-stop invariant's loose aliveness test: the strict, title-
    /// verified detector above says a call was SEEN; this one only says the
    /// call has not ended (a Meet user reading a doc in another tab must not
    /// read as "call over").
    nonisolated static func callHolderPresent() -> Bool {
        let names = AudioInputDevices.appsRunningInput(excluding: ProcessInfo.processInfo.processIdentifier)
        return names.contains { name in
            let lower = name.lowercased()
            return callApps.contains { lower.contains($0.fragment) }
                || MeetingPolicy.isBrowser(appNamed: name)
        }
    }

    /// Every window title of the named app, through Accessibility. Best-effort
    /// at every step: no running app, no AX consent, no windows — all mean an
    /// empty list, never an error. One walk, shared by the platform check and
    /// the diagnostic dump.
    private nonisolated static func browserWindowTitles(appNamed name: String) -> [String] {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == name }) else { return [] }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // These calls are synchronous IPC on the MAIN thread, on a 4 s timer
        // — the default AX messaging timeout is ~6 s, so one beachballing
        // browser would freeze dictation and all UI with it (review find,
        // 2026-08-31). Half a second is plenty for a title.
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t) == .success,
                  let title = t as? String, !title.isEmpty else { return nil }
            return title
        }
    }

    private nonisolated static func browserCallPlatform(appNamed name: String) -> String? {
        for title in browserWindowTitles(appNamed: name) {
            if let hit = MeetingPolicy.callPlatform(inWindowTitle: title) { return hit }
        }
        return nil
    }

    /// The late source probe: once a minute for ten minutes, until something
    /// answers. Cheap — a handful of AX title reads — and it stops itself the
    /// moment it learns anything.
    private func startSourceProbe() {
        sourceProbesLeft = 10
        sourceProbeTimer?.invalidate()
        sourceProbeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Scheduled from the main actor, so the timer fires on the main runloop.
            MainActor.assumeIsolated {
                guard self.isActive, self.sourceProbesLeft > 0 else {
                    self.sourceProbeTimer?.invalidate()
                    self.sourceProbeTimer = nil
                    return
                }
                self.sourceProbesLeft -= 1
                if let hit = Self.detectCallApp() {
                    Log.d("meeting: call source found late — \(hit)")
                    self.lateSource = hit
                    self.sourceProbeTimer?.invalidate()
                    self.sourceProbeTimer = nil
                } else if self.sourceProbesLeft == 0 {
                    // Silence here cost a diagnosis once (2026-09-01): ten
                    // misses looked identical to the probe never running.
                    Log.d("meeting: call source never found (10 probes)")
                    self.sourceProbeTimer?.invalidate()
                    self.sourceProbeTimer = nil
                }
            }
        }
    }

    /// Warning under 500 MB free, self-stop under 150 — stopping keeps the
    /// transcript; running on until the write fails would not.
    private func checkDiskSpace() {
        guard isActive, let url = fileURL else { return }
        // The forgotten recording (hardened 2026-08-29, HAL bench-verified):
        // while a call process holds the mic we never stop ourselves; a call
        // that released it and stayed away — or dead air with no call in
        // sight — ends the session, and the file says which one it was.
        //
        // The probe itself runs OFF the main thread: it walks HAL device
        // holders and browser AX titles — synchronous IPC that a wedged
        // browser can stall — and the recorder's main thread must not hang
        // on it (review, 2026-08-31). The verdict hops back to main.
        if !probingCall {
            probingCall = true
            let everSeen = platformEverSeen
            Task.detached(priority: .utility) { [weak self] in
                let aliveNow = MeetingSession.callHolderPresent()
                let platformNow = aliveNow && !everSeen ? MeetingSession.detectCallApp() != nil : false
                // Fresh weak capture: the outer `self` is the detached
                // closure's mutable box and may not cross into this one.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.probingCall = false
                    guard self.isActive else { return }
                    if aliveNow { self.lastPlatformAliveAt = Date() }
                    if platformNow { self.platformEverSeen = true }
                    let verdict = MeetingPolicy.autoStopVerdict(
                        platformEverSeen: self.platformEverSeen,
                        platformAliveNow: aliveNow,
                        lastAliveAt: self.lastPlatformAliveAt,
                        lastVoicedAt: self.lastVoicedAt,
                        now: Date())
                    if verdict != .keep {
                        Log.d("meeting: auto-stop (\(verdict)) — platformSeen=\(self.platformEverSeen), quiet for \(Int(Date().timeIntervalSince(self.lastVoicedAt)))s")
                        self.autoStopReason = verdict
                        self.stop()
                    }
                }
            }
        }
        let free = (try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        let freeMB = Int(free / 1_048_576)
        if freeMB < 150 {
            Log.d("meeting: disk critically low (\(freeMB) MB) — stopping to keep the transcript")
            lowDisk = true
            stop()
        } else if freeMB < 500 {
            if !lowDisk { Log.d("meeting: disk low (\(freeMB) MB free)") }
            lowDisk = true
        } else if lowDisk {
            lowDisk = false
        }
    }

    // MARK: - Channels

    private func appendThem(_ pcm: Data, peak: Double) {
        guard isActive, !stopping else { return }
        lastTapBufferAt = Date()
        themPCM.append(pcm)
        dump?.appendThem(pcm)
        // Their voices move the equalizer too — "hearing the call" is as
        // important a signal as "hearing you".
        let level = min(1.0, peak * 3)
        if level > audioLevel { audioLevel = level }
        themLevel = max(level, themLevel * 0.7)
    }

    private func evaluateWindows() {
        guard isActive, !stopping else { return }
        let t = now

        // Dead-tap self-healing: no buffers at all for 5 s = the tap is gone
        // (an output-device change can kill the aggregate). Restart it, at
        // most once per 30 s so a permanently broken tap doesn't thrash.
        // Not while replaying: there is no tap, and a drained file pair would
        // otherwise "heal" its way into a live capture mid-bench.
        if replay == nil,
           Date().timeIntervalSince(lastTapBufferAt) > 5,
           Date().timeIntervalSince(lastTapRestartAt) > 30 {
            lastTapRestartAt = Date()
            Log.d("meeting: tap buffer flow stalled — recreating the tap")
            tap.stop()
            do { try tap.start() } catch {
                Log.d("meeting: tap restart failed: \(error.localizedDescription)")
            }
            lastTapBufferAt = Date()   // fresh grace for the restarted tap
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
            sinceLoud: t - (themLastSpeechAt ?? -.infinity),
            // This channel is the one the diarizer sees, and its cap is the
            // segmentation model's input length — see MeetingPolicy.
            hardCap: MeetingPolicy.themWindowCap)
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
            let tail = Data(currentYouPCM().suffix(tailBytes))
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
        let pcm = useYou ? currentYouPCM() : themPCM
        // 0.7 s of audio is enough for a first hypothesis — a 3-second
        // phrase deserves at least one shot at the live line.
        guard pcm.count >= Int(Double(AudioRecorder.sampleRate) * 1.4) else { return }
        let windowStart = useYou ? youWindowStart : themWindowStart
        previewBusy = true
        Task { await previewPass(pcm: pcm, useYou: useYou, windowStart: windowStart) }
    }

    /// The decode itself, `nonisolated` so the float conversion and the wait
    /// in Whisper's queue stay off the main actor (the DictationController
    /// previewPass pattern).
    private nonisolated func previewPass(pcm: Data, useYou: Bool,
                                         windowStart: TimeInterval) async {
        defer { Task { @MainActor in self.previewBusy = false } }
        guard await WhisperEngine.shared.isReady(for: .fast) else { return }
        let floats = AudioRecorder.floatSamples(fromPCM: pcm)
        let window = Array(floats.suffix(15 * AudioRecorder.sampleRate))
        let started = Date()
        guard let (text, _) = try? await WhisperEngine.shared.transcribe(
            floats: window, tier: .fast, language: "",
            // THE named race of the earlier review: this callback runs on
            // Whisper's decode thread, so it reads the lock-guarded mirror,
            // never the main-confined isActive.
            isCancelled: { [weak self] in self?.activeMirror.isActive != true }) else { return }
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

    private enum Channel { case you, them }

    private func cutYouWindow(transcribe shouldTranscribe: Bool) {
        // The entry carries the moment speech STARTED, not the window's
        // (possibly silence-padded) start — honest timestamps, free-flowing
        // flush frontier.
        let start = youFirstSpeechAt ?? youWindowStart
        let pcmStart = youWindowStart
        // Hot rollover: hands back the window and keeps recording — the same
        // no-teardown path the dictation key rollover uses.
        let (pcm, duration) = rolloverYou()
        dump?.appendYou(pcm)
        youWindowStart = now
        youFirstSpeechAt = nil
        livePreview = nil   // the final entry supersedes the hypothesis
        Log.d(String(format: "meeting: cut you %.1fs %@", duration,
                     shouldTranscribe ? "speech" : "silence"))
        guard shouldTranscribe, duration >= 0.5 else { return }
        transcribeWindow(pcm: pcm, pcmStart: pcmStart, start: start, channel: .you)
    }

    private func cutThemWindow(transcribe shouldTranscribe: Bool) {
        let start = themFirstSpeechAt ?? themWindowStart
        let pcmStart = themWindowStart
        let pcm = themPCM
        themPCM = Data()
        themWindowStart = now
        themFirstSpeechAt = nil
        livePreview = nil   // the final entry supersedes the hypothesis
        let duration = Double(pcm.count) / Double(AudioRecorder.sampleRate * 2)
        Log.d(String(format: "meeting: cut them %.1fs %@", duration,
                     shouldTranscribe ? "speech" : "silence"))
        guard shouldTranscribe, pcm.count >= AudioRecorder.sampleRate else { return } // ≥0.5s
        transcribeWindow(pcm: pcm, pcmStart: pcmStart, start: start, channel: .them)
    }

    // MARK: - Recognition

    /// One decoded piece of audio on its way to becoming an entry.
    private struct Recognized: Sendable {
        let start: TimeInterval
        let ordinal: Int?
        let text: String
        let seconds: Double
    }

    /// Recognizes one cut window. A Them window is first split into the turns
    /// of the voices inside it and each turn is decoded separately, so a
    /// window that held two people becomes two entries with the right labels
    /// and the right start times.
    ///
    /// ORDERING INVARIANT: however many entries a window produces, the
    /// channel keeps exactly ONE in-flight record, pinned at `start` — the
    /// earliest moment anything from this window can carry. It is removed
    /// only when every piece is done, and the pieces are appended to
    /// `pending` together, so a window can never interleave with a later one
    /// (see MeetingPolicy.flushableCount). Backpressure likewise still counts
    /// WINDOWS, not pieces.
    private func transcribeWindow(pcm: Data, pcmStart: TimeInterval,
                                  start: TimeInterval, channel: Channel) {
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
        Task { await processWindow(pcm: pcm, pcmStart: pcmStart, start: start,
                                   channel: channel, key: key, language: language) }
    }

    /// The recognition body, `nonisolated` so the float conversion, the VAD
    /// gate and the waits in the Whisper/diarizer queues run on the global
    /// executor — exactly where the old unstructured Task ran them.
    private nonisolated func processWindow(pcm: Data, pcmStart: TimeInterval,
                                           start: TimeInterval, channel: Channel,
                                           key: String, language: String) async {
            let floats = AudioRecorder.floatSamples(fromPCM: pcm)
            let rate = Double(AudioRecorder.sampleRate)
            // Substantive-speech gate: a continuous channel's window needs
            // ENOUGH voiced audio, not just any speech-like blip — one breath
            // in ten silent seconds made Whisper hallucinate "Thank you."
            // three times in the first real meeting. Checked here, before the
            // diarizer, so a window of pure noise costs no ML at all. VAD
            // unavailable → let it through (Whisper still sees trimmed audio).
            let windowStats = await SpeechGate.shared.speechStats(floats)
            let worth = windowStats.map {
                MeetingPolicy.windowWorthTranscribing(voicedChunks: $0.voiced)
            } ?? true
            if let windowStats, !worth {
                Log.d("meeting: window skipped (voiced \(windowStats.voiced)/\(windowStats.chunks) — not enough speech)")
            }
            var produced: [Recognized] = []
            if worth, !self.cancelled.isCancelled {
                // Late-start safety: if the model still isn't loaded (meeting
                // started seconds after app launch), load it now instead of
                // silently losing this window.
                if !(await WhisperEngine.shared.isReady(for: .fast)) {
                    try? await WhisperEngine.shared.prepare(tier: .fast) { _ in }
                }
                // Who is talking (Them only): the diarizer numbers the mixed
                // stream's voices — "Speaker 1/2…". You needs no ML and must
                // NOT go through this: the mic channel IS one known voice,
                // and diarizing it could only invent second speakers.
                let turns = channel == .them && Settings.shared.separateVoices
                    ? await self.diarizer.speakerTurns(floats: floats, windowStart: pcmStart)
                    : []
                if turns.count > 1 {
                    // The interesting case: a lively call has no pauses, so
                    // this window was cut by the 15 s cap, not by a speaker
                    // change — decode each voice's turn on its own.
                    for turn in turns {
                        guard !self.cancelled.isCancelled else { break }
                        let from = max(0, Int((turn.start - pcmStart) * rate))
                        let to = min(floats.count, Int((turn.end - pcmStart) * rate))
                        // A turn too short to hold a word is not worth a
                        // decode; speakerSlices already merged the blips, so
                        // this only guards arithmetic at the window edges.
                        guard to - from >= AudioRecorder.sampleRate / 2 else { continue }
                        let piece = Array(floats[from..<to])
                        let stats = await SpeechGate.shared.speechStats(piece)
                        guard let text = await self.recognize(
                            piece, stats: stats, language: language, channel: channel,
                            tag: "turn spk\(turn.ordinal)") else { continue }
                        // The turn's own start is the honest timestamp, but it
                        // may never precede the window's flush pin.
                        produced.append(Recognized(start: max(turn.start, start),
                                                   ordinal: turn.ordinal, text: text,
                                                   seconds: Double(piece.count) / rate))
                    }
                } else if let text = await self.recognize(
                    floats, stats: windowStats, language: language, channel: channel,
                    tag: "window") {
                    produced.append(Recognized(start: start, ordinal: turns.first?.ordinal,
                                               text: text,
                                               seconds: Double(floats.count) / rate))
                }
            }
            let results = produced   // immutable copy for the @Sendable hop
            await MainActor.run {
                self.inflight.removeValue(forKey: key)
                self.inflightCount = self.inflight.count
                for item in results {
                    let speaker: String
                    switch channel {
                    case .you: speaker = L("You")
                    case .them: speaker = item.ordinal.map { Self.speakerLabel($0) } ?? L("Them")
                    }
                    self.pending.append(Entry(start: item.start, speaker: speaker,
                                              text: item.text, you: channel == .you,
                                              seconds: item.seconds, ordinal: item.ordinal))
                }
                self.flushReadyEntries()
                self.finalizeIfDrained()
            }
    }

    /// One recognition of one contiguous piece of audio: gate, trim, decode,
    /// then let the pure rule decide whether the model just invented the
    /// text. Returns nil when nothing should be written.
    ///
    /// The rejection is deliberately NOT a phrase blocklist (owner's call): it
    /// reads the model's own confidence signals — no-speech probability,
    /// average log-probability, compression ratio — together with what Silero
    /// heard in the same audio. Every rejection AND every kept short result
    /// goes to the log with its numbers, so the next real meeting is the
    /// calibration set for the thresholds.
    /// `nonisolated` — always called from processWindow's executor; every
    /// state touch inside already hops via MainActor.run.
    private nonisolated func recognize(_ floats: [Float], stats: (chunks: Int, voiced: Int)?,
                                       language: String, channel: Channel,
                                       tag: String) async -> String? {
        // Raw VAD evidence, before recognition can reject anything: a voiced
        // window on any channel means somebody is speaking (auto-stop clock).
        if let stats, stats.voiced > 0 {
            await MainActor.run { self.lastVoicedAt = Date() }
        }
        if let stats, !MeetingPolicy.windowWorthTranscribing(voicedChunks: stats.voiced) {
            Log.d("meeting: \(tag) skipped (voiced \(stats.voiced)/\(stats.chunks) — not enough speech)")
            return nil
        }
        // Edge silence is trimmed exactly like a dictation's (edge
        // hallucinations, speed); the VAD gate above saw the FULL piece, and
        // the diarizer saw the full window (its offsets stay honest).
        let speechFloats = AudioRecorder.trimSilence(floats)
        // No replacements here: a meeting transcript is a verbatim record,
        // not a dictation being typed.
        // The pin, when one exists — with a periodic auto probe so a real
        // language switch is noticed rather than steamrolled.
        let effectiveLanguage: String = await MainActor.run {
            guard language.isEmpty, let pin = langPinned[channel] else { return language }
            langProbe[channel, default: 0] += 1
            return langProbe[channel]! % 8 == 0 ? "" : pin
        }
        guard let result = try? await WhisperEngine.shared.transcribeScored(
            floats: speechFloats, tier: .fast, language: effectiveLanguage,
            isCancelled: { self.cancelled.isCancelled }) else { return nil }
        await MainActor.run {
            let det = result.detectedLanguage
            guard !det.isEmpty else { return }
            if langPinned[channel] == nil {
                langVotes[channel, default: [:]][det, default: 0] += 1
                let votes = langVotes[channel] ?? [:]
                let total = votes.values.reduce(0, +)
                if total >= 5, let top = votes.max(by: { $0.value < $1.value }),
                   top.value * 5 >= total * 4 {
                    langPinned[channel] = top.key
                    Log.d("meeting: language pinned \(channel)=\(top.key) (\(top.value)/\(total))")
                }
            } else if effectiveLanguage.isEmpty {
                if det != langPinned[channel] {
                    langProbeMisses[channel, default: 0] += 1
                    if langProbeMisses[channel]! >= 2 {
                        Log.d("meeting: language pin dropped for \(channel) (probe said \(det))")
                        langPinned[channel] = nil
                        langVotes[channel] = [:]
                        langProbeMisses[channel] = 0
                    }
                } else {
                    langProbeMisses[channel] = 0
                }
            }
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard MeetingPolicy.saidAnything(text) else {
            Log.d("meeting: \(tag) punctuation-only result dropped — \(text)")
            return nil
        }
        let seconds = Double(speechFloats.count) / Double(AudioRecorder.sampleRate)
        let words = text.split(whereSeparator: \.isWhitespace).count
        let evidence = MeetingPolicy.SpeechEvidence(
            noSpeechProb: result.quality.noSpeechProb,
            avgLogprob: result.quality.avgLogprob,
            compressionRatio: result.quality.compressionRatio,
            words: words, audioSeconds: seconds, voicedChunks: stats?.voiced)
        let numbers = String(
            format: "noSpeech %.2f logprob %.2f compression %.2f temp %.1f voiced %@ %.1fs %d word(s)",
            evidence.noSpeechProb, evidence.avgLogprob, evidence.compressionRatio,
            result.quality.temperature,
            stats.map { "\($0.voiced)/\($0.chunks)" } ?? "n/a", seconds, words)
        if case .reject(let reason) = MeetingPolicy.phantomVerdict(evidence) {
            await MainActor.run { self.statPhantomsRejected += 1 }
            Log.d("meeting: \(tag) rejected [\(reason)] (\(numbers)) — \(text)")
            return nil
        }
        // Both sides of the boundary go to the log: the short results we KEEP
        // are what tells the next calibration whether the bars sit right.
        if words <= 3 {
            Log.d("meeting: \(tag) short result kept (\(numbers)) — \(text)")
        }
        return text
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
        for var entry in pending.prefix(n) {
            // The words overrule the embeddings: a tap-channel entry that
            // finishes the previous voice's unfinished sentence belongs to
            // that voice, whatever the diarizer measured (the 2026-08-17
            // ground truth: a split voice sits at the same distance as two
            // real people, so this is the only signal that can heal it).
            if !entry.you {
                if let last = lastThem,
                   let host = MeetingSpeakerPolicy.inheritedOrdinal(
                       previousText: last.text, previousOrdinal: last.ordinal,
                       nextText: entry.text, nextOrdinal: entry.ordinal,
                       secondsApart: entry.start - last.start) {
                    statLabelsInherited += 1
                    Log.d("diar: label inherited — spk\(entry.ordinal.map(String.init) ?? "?") "
                          + "finishes spk\(host)'s sentence at \(clock(entry.start))")
                    entry = Entry(start: entry.start, speaker: Self.speakerLabel(host),
                                  text: entry.text, you: false,
                                  seconds: entry.seconds, ordinal: host)
                }
                lastThem = (entry.text, entry.ordinal, entry.start)
            }
            // A voice the user has already named keeps that name for the rest
            // of the session — including in the file.
            let speaker = speakerNames[entry.speaker] ?? entry.speaker
            statSpeakerEntries[speaker, default: 0] += 1
            statSpeakerSeconds[speaker, default: 0] += entry.seconds
            if let ordinal = entry.ordinal {
                statOrdinalEntries[ordinal, default: 0] += 1
                statOrdinalSeconds[ordinal, default: 0] += entry.seconds
            }
            write("**[\(clock(entry.start))] \(speaker):** \(entry.text)\n\n")
            displayEntries.append(TranscriptEntry(time: clock(entry.start),
                                                  speaker: speaker,
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
        finishing = false
        lowDisk = false
        // The sleep marker goes in AFTER the last recognized words: the
        // transcript is complete up to the moment of sleep and says so where
        // it ended — nothing after it was captured, so nothing is guessed.
        if endedBySleep {
            endedBySleep = false
            try? fileHandle?.write(contentsOf: Data(("\n_" + L("Recording ended here — this Mac went to sleep.") + "_\n").utf8))
        }
        if let reason = autoStopReason {
            autoStopReason = nil
            let line = reason == .callEnded
                ? L("Recording stopped by itself — the call ended.")
                : L("Recording stopped by itself — ten minutes of silence.")
            try? fileHandle?.write(contentsOf: Data(("\n_" + line + "_\n").utf8))
        }
        try? fileHandle?.close()
        fileHandle = nil
        let stamp = sessionStart
        Task { @MainActor in
            // Voices that turned out to be fragments go back into the voice
            // they came from BEFORE anything else looks at the file: the
            // window, the diagnostics and the titler must all see the same
            // transcript. This is also the last moment the diarizer's voice
            // database exists, which is where the distances come from.
            if Settings.shared.separateVoices {
                await self.mergeMicroSpeakers(in: url)
            }
            // A platform the probe found after the header was written goes in
            // now, at the top — parseSource reads only the file's head, and
            // the handle is closed, so this is the one safe moment.
            if !self.headerHadSource, let late = self.lateSource,
               let text = try? String(contentsOf: url, encoding: .utf8) {
                try? ("<!-- source: \(late) -->\n" + text)
                    .data(using: .utf8)?.write(to: url)
            }
            await self.logSessionDiagnostics()
            Log.d("meeting: transcript finished -> \(url.lastPathComponent)")
            // The transcript is safe on disk before the model is asked for a
            // name: titling is a finishing touch, never a step the recording
            // depends on. The window is told twice — once now, once if a title
            // lands — so the meeting appears in the library immediately.
            self.onFinished?(url)
            let entries = self.displayEntries
            // Name and summary in ONE model call: the excerpt and the session
            // (and, for a Russian meeting, the translation hop) are paid for
            // once and answer both questions.
            if Settings.shared.readMeetings,
               let brief = await MeetingTitler.brief(for: entries) {
                // A name the owner wrote themselves outranks a name a model read
                // out of the words. When the calendar supplied one, the model's
                // title is dropped on the floor and only its summary is kept.
                let title = self.scheduledTitle ?? brief.title
                MeetingArchive.setTitle(title, dateLine: Self.dateLine(stamp),
                                        summary: brief.summary, in: url)
                // The file follows its title so the folder reads in Finder too;
                // the transcript's content stays the source of truth, so a failed
                // rename costs nothing but a plainer name.
                let renamed = MeetingArchive.renameFile(at: url, stamp: Self.fileStamp(stamp),
                                                        title: title)
                if self.fileURL == url { self.fileURL = renamed }
                self.onFinished?(renamed)
            }
            // The call is over, its finishing touches are on disk, and the
            // model is still warm: the moment for the archive's missing
            // summaries and contents blocks — this meeting's first of all.
            // This used to wait for the next opening of the library, which in
            // practice meant a Mac that had just become free did nothing while
            // the owner waited for exactly this work (2026-08-27). The race
            // the library still avoids on session end (backfilling a meeting
            // that is mid-titling) cannot happen here: the titling above has
            // already run.
            self.kickBackfills()
        }
    }

    /// Loads the archive off the main thread (an iCloud-evicted transcript
    /// blocks on a network read — the 16-second main-thread hang of
    /// 2026-08-17) and starts both backfills, which re-ask permission before
    /// every model call in case a new meeting begins.
    @MainActor
    private func kickBackfills() {
        let youLabel = L("You")
        DispatchQueue.global(qos: .utility).async {
            let meetings = MeetingArchive.list(youLabel: youLabel)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Back on the main queue — the main actor.
                MainActor.assumeIsolated {
                    guard !self.isActive else { return }
                    if Settings.shared.readMeetings {
                        MeetingSummaries.shared.backfill(meetings) { [weak self] in self?.isActive != true }
                    }
                    MeetingSections.shared.backfill(meetings) { [weak self] in self?.isActive != true }
                }
            }
        }
    }

    /// Hands the finished transcript's per-voice measurements to the diarizer,
    /// which decides (through the pure `MeetingSpeakerPolicy` rule) which
    /// voices were fragments, and then rewrites those labels in the file, on
    /// screen and in the tallies — the three views of one meeting must not
    /// drift apart.
    ///
    /// Why here and not at the moment the fragment appeared: a voice can only
    /// be judged tiny once the meeting is over. One entry after five minutes
    /// means nothing; one entry in fifty-one is the signature the owner's
    /// ground truth showed us.
    @MainActor
    private func mergeMicroSpeakers(in url: URL) async {
        let voices = statOrdinalEntries.keys.sorted().map { ordinal in
            MeetingSpeakerPolicy.Voice(
                ordinal: ordinal,
                entries: statOrdinalEntries[ordinal] ?? 0,
                seconds: statOrdinalSeconds[ordinal] ?? 0,
                renamed: speakerNames[Self.speakerLabel(ordinal)] != nil)
        }
        guard !voices.isEmpty else { return }
        for merge in await diarizer.mergeMicroClusters(voices: voices) {
            let from = currentLabel(merge.source)
            let into = currentLabel(merge.target)
            guard from != into else { continue }
            // The file first — it is the record; everything else follows it.
            MeetingArchive.rename(speaker: from, to: into, in: url)
            displayEntries = displayEntries.map {
                $0.speaker == from
                    ? TranscriptEntry(id: $0.id, time: $0.time, speaker: into,
                                      text: $0.text, isYou: $0.isYou)
                    : $0
            }
            speakerNames[Self.speakerLabel(merge.source)] = into
            statSpeakerEntries[into, default: 0] += statSpeakerEntries.removeValue(forKey: from) ?? 0
            statSpeakerSeconds[into, default: 0] += statSpeakerSeconds.removeValue(forKey: from) ?? 0
            statOrdinalEntries[merge.target, default: 0] += statOrdinalEntries.removeValue(forKey: merge.source) ?? 0
            statOrdinalSeconds[merge.target, default: 0] += statOrdinalSeconds.removeValue(forKey: merge.source) ?? 0
        }
    }

    /// The calibration dump, written once per session — AFTER the micro-cluster
    /// merges, so every number here is what the file actually says. The
    /// clustering threshold is back at the library's 0.7 on the strength of
    /// three meetings with confirmed head counts, and that value is still a
    /// hypothesis, so what the next meetings must leave behind is the EVIDENCE
    /// for the call after it: how the entries and the speech seconds actually
    /// distributed across the voices, how often the diarizer heard nothing, and
    /// how many turns it found per window. A single voice split in two shows up
    /// here as two speakers with similar profiles; two people merged shows up as
    /// one speaker holding most of the seconds while the turn histogram stays
    /// at 1.
    private func logSessionDiagnostics() async {
        Log.d(String(format: "meeting: summary — %.1f min, %d window(s), %d entries, %d phantom(s) rejected",
                     Date().timeIntervalSince(sessionStart) / 60,
                     statWindows, statEntries, statPhantomsRejected))
        for (speaker, count) in statSpeakerEntries.sorted(by: { $0.value > $1.value }) {
            Log.d(String(format: "meeting: %@ — %d entries, %.0fs of speech",
                         speaker, count, statSpeakerSeconds[speaker] ?? 0))
        }
        // How far apart the clusters actually ended up, measured on the live
        // voice database while it still exists. Purely a reading — see
        // MeetingDiarizer.logSpeakerDistances for what the numbers decide. The
        // voices are the POST-merge ones, so the matrix describes the speakers
        // the finished file actually shows.
        await diarizer.logSpeakerDistances(voices: statOrdinalEntries.keys.sorted().map {
            MeetingSpeakerPolicy.Voice(ordinal: $0,
                                       entries: statOrdinalEntries[$0] ?? 0,
                                       seconds: statOrdinalSeconds[$0] ?? 0)
        })
        let s = await diarizer.sessionStats()
        let histogram = s.turnHistogram.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        Log.d("diar: summary — threshold \(s.thresholdNote), \(s.windows) window(s) diarized, no voice \(s.noVoice), failed \(s.failures), merged \(s.merged) micro-cluster(s), \(statLabelsInherited) label(s) inherited, turns-per-window [\(histogram)]")
    }

    static func dateLine(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .short)
    }

    /// Sortable file-name stamp — the part that keeps the folder in
    /// chronological order once titles are appended.
    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: date)
    }

    // MARK: - File

    private func openTranscriptFile() throws {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A scheduled call already has a name, and it is a better one than any
        // summary of what gets said: it is what the owner called this meeting
        // when they arranged it, and therefore what they will look for later.
        // Read here, before the file exists, so the name is on the first line
        // and in the file name — no end-of-session rename, which is its own
        // source of bugs (a window left pointing at the old path, 2026-08-19).
        let scheduled = MeetingCalendar.scheduledTitle(at: sessionStart)
        // The TITLE respects the naming setting; the platform below does not
        // (harmless metadata for the Sources group).
        scheduledTitle = MeetingCalendar.isEnabled ? scheduled?.title : nil
        let url = dir.appendingPathComponent(
            MeetingArchive.fileName(stamp: Self.fileStamp(sessionStart), title: scheduledTitle))
        // Which platform the call ran on — the sidebar's Sources group. The
        // detection card's verified name wins outright; then the calendar's
        // conference link; then whichever known call app holds the microphone
        // right now. Written ONLY at creation, as a markdown-invisible
        // comment: existing transcripts are never rewritten for this (they
        // read back as "other").
        let source = promptPlatform ?? scheduled?.platform ?? Self.detectCallApp()
        headerHadSource = source != nil
        lateSource = nil
        if source == nil { startSourceProbe() }
        let sourceLine = source.map { "<!-- source: \($0) -->\n" } ?? ""
        let header: String
        if let scheduledTitle {
            // The calendar a meeting came from is a classification its owner
            // already made — "work", "clients" — so it becomes a tag without
            // anyone being asked to think. Free vocabulary is the only kind
            // that survives, since the tags people must remember to apply are
            // the ones they stop applying in week three.
            let tag = scheduled.flatMap { MeetingTags.fromCalendarName($0.calendar) }
            let tagLine = tag.map { "\(MeetingTags.tagLine([$0]))\n" } ?? ""
            header = "# \(scheduledTitle)\n_\(Self.dateLine(sessionStart))_\n\(sourceLine)\(tagLine)\n"
        } else {
            header = "# \(L("Meeting transcript")) — \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))\n\(sourceLine)\n"
        }
        try header.data(using: .utf8)!.write(to: url)
        fileHandle = try FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
        fileURL = url
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            // The legacy write(_:) raised an ObjC exception here — a full
            // disk or a yanked volume crashed the whole recorder. Losing a
            // line with a log entry is strictly better; the 30 s disk check
            // stops the session for the persistent case.
            Log.d("meeting: transcript write failed — \(error.localizedDescription)")
        }
    }

    private func clock(_ offset: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: sessionStart.addingTimeInterval(offset))
    }
}
