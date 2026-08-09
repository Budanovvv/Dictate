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
    private var themLastLoud: TimeInterval?
    // You: audio lives in the recorder (hot rollover cuts it); we track time.
    private var youWindowStart: TimeInterval = 0
    private var youLastLoud: TimeInterval?
    /// Rolling mic noise floor for the adaptive loudness threshold. Starts
    /// high so the first quiet buffers pull it straight down to the room.
    private var youLevelFloor: Double = 1.0
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
        themWindowStart = 0; themLastLoud = nil
        youWindowStart = 0; youLastLoud = nil
        youLevelFloor = 1.0

        displayEntries = []
        inflightCount = 0
        try openTranscriptFile()
        // Voice separation warms up in parallel (first ever run downloads its
        // CoreML models); until it's ready Them-entries just stay collective.
        Task { await diarizer.startSession(); await diarizer.prepare() }
        try tap.start()   // first run triggers the system-audio TCC prompt
        tap.onBuffer = { [weak self] pcm, peak in
            DispatchQueue.main.async { self?.appendThem(pcm, peak: peak) }
        }
        mic.onLevel = { [weak self] level in
            guard let self else { return }
            // Adaptive threshold: the busy-mic capture path has no AEC and a
            // high raw noise floor — a fixed 0.08 read the room as nonstop
            // speech and windows never cut (field test 2026-08-09 15:48).
            self.youLevelFloor = MeetingPolicy.updatedNoiseFloor(self.youLevelFloor, level: level)
            if MeetingPolicy.isLoud(level: level, floor: self.youLevelFloor) {
                self.youLastLoud = self.now
            }
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
        cutYouWindow(transcribe: youLastLoud != nil)
        cutThemWindow(transcribe: themLastLoud != nil)
        _ = mic.stop()
        tap.stop()
        isActive = false
        Log.d("meeting: session stopping, \(inflight.count) window(s) still recognizing")
        finalizeIfDrained()
    }

    // MARK: - Channels

    private func appendThem(_ pcm: Data, peak: Double) {
        guard isActive, !stopping else { return }
        lastTapBufferAt = Date()
        themPCM.append(pcm)
        if peak >= 0.02 { themLastLoud = now }
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

        // Once a minute: a heartbeat for the field-test log.
        ticksSinceHeartbeat += 1
        if ticksSinceHeartbeat >= 120 {
            ticksSinceHeartbeat = 0
            Log.d(String(format: "meeting: %.0f min, windows=%d entries=%d pending=%d inflight=%d",
                         t / 60, statWindows, statEntries, pending.count, inflight.count))
        }

        let youVerdict = MeetingPolicy.windowVerdict(
            accumulated: t - youWindowStart,
            hadSpeech: (youLastLoud ?? -1) >= youWindowStart,
            sinceLoud: t - (youLastLoud ?? -.infinity))
        switch youVerdict {
        case .keep: break
        case .cutTranscribe: cutYouWindow(transcribe: true)
        case .dropSilence: cutYouWindow(transcribe: false)
        }

        let themVerdict = MeetingPolicy.windowVerdict(
            accumulated: t - themWindowStart,
            hadSpeech: (themLastLoud ?? -1) >= themWindowStart,
            sinceLoud: t - (themLastLoud ?? -.infinity))
        switch themVerdict {
        case .keep: break
        case .cutTranscribe: cutThemWindow(transcribe: true)
        case .dropSilence: cutThemWindow(transcribe: false)
        }
    }

    private enum Channel { case you, them }

    private func cutYouWindow(transcribe shouldTranscribe: Bool) {
        let start = youWindowStart
        // Hot rollover: hands back the window and keeps recording — the same
        // no-teardown path the dictation key rollover uses.
        let (pcm, duration) = mic.rollover()
        youWindowStart = now
        Log.d(String(format: "meeting: cut you %.1fs %@", duration,
                     shouldTranscribe ? "speech" : "silence"))
        guard shouldTranscribe, duration >= 0.5 else { return }
        transcribeWindow(pcm: pcm, start: start, channel: .you)
    }

    private func cutThemWindow(transcribe shouldTranscribe: Bool) {
        let start = themWindowStart
        let pcm = themPCM
        themPCM = Data()
        themWindowStart = now
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
                // No user prompt and no replacements: a meeting transcript is
                // a verbatim record, not a dictation being typed.
                text = (try? await WhisperEngine.shared.transcribe(
                    floats: floats, tier: .fast, language: language, prompt: "",
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
        // recognitions gate the flush.
        let frontiers = stopping ? [] : [youWindowStart, themWindowStart]
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
