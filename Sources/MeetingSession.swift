import Foundation
import AppKit

/// One recorded meeting: two audio channels — You (the microphone, through
/// the same battle-tested AudioRecorder the dictation uses, so a mic held by
/// the meeting app in voice processing still records) and Them (everyone
/// else, through the global process tap) — cut into utterance windows at
/// natural pauses, transcribed locally, and appended to a live Markdown file
/// the user can watch grow. Everything stays on this Mac.
final class MeetingSession {

    private(set) var isActive = false
    /// The transcript file of the running (or last) session.
    private(set) var fileURL: URL?
    /// Fired on main when the session has fully finished (tail transcribed,
    /// file closed).
    var onFinished: ((URL) -> Void)?

    private let tap = MeetingTap()
    private let mic = AudioRecorder()
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

    private struct Entry { let start: TimeInterval; let speaker: String; let text: String }
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

        try openTranscriptFile()
        try tap.start()   // first run triggers the system-audio TCC prompt
        tap.onBuffer = { [weak self] pcm, peak in
            DispatchQueue.main.async { self?.appendThem(pcm, peak: peak) }
        }
        mic.onLevel = { [weak self] level in
            guard let self, level >= 0.08 else { return }
            self.youLastLoud = self.now
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
        themPCM.append(pcm)
        if peak >= 0.02 { themLastLoud = now }
    }

    private func evaluateWindows() {
        guard isActive, !stopping else { return }
        let t = now

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

    private func cutYouWindow(transcribe shouldTranscribe: Bool) {
        let start = youWindowStart
        // Hot rollover: hands back the window and keeps recording — the same
        // no-teardown path the dictation key rollover uses.
        let (pcm, duration) = mic.rollover()
        youWindowStart = now
        guard shouldTranscribe, duration >= 0.5 else { return }
        transcribeWindow(pcm: pcm, start: start, speaker: L("You"))
    }

    private func cutThemWindow(transcribe shouldTranscribe: Bool) {
        let start = themWindowStart
        let pcm = themPCM
        themPCM = Data()
        themWindowStart = now
        guard shouldTranscribe, pcm.count >= AudioRecorder.sampleRate else { return } // ≥0.5s
        transcribeWindow(pcm: pcm, start: start, speaker: L("Them"))
    }

    // MARK: - Recognition

    private func transcribeWindow(pcm: Data, start: TimeInterval, speaker: String) {
        inflightSeq += 1
        let key = "\(speaker)#\(inflightSeq)"
        inflight[key] = start
        let language = Settings.shared.language
        Task {
            let floats = AudioRecorder.floatSamples(fromPCM: pcm)
            // Silero gate: a window can pass the level heuristic on a cough
            // or keyboard noise — don't wake Whisper for it (it hallucinates
            // on non-speech).
            let speech = await SpeechGate.shared.hasSpeech(floats) ?? true
            var text = ""
            if speech, !self.cancelled.isCancelled {
                // No user prompt and no replacements: a meeting transcript is
                // a verbatim record, not a dictation being typed.
                text = (try? await WhisperEngine.shared.transcribe(
                    floats: floats, tier: .fast, language: language, prompt: "",
                    isCancelled: { self.cancelled.isCancelled }))?.0 ?? ""
            }
            await MainActor.run {
                self.inflight.removeValue(forKey: key)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self.pending.append(Entry(start: start, speaker: speaker, text: trimmed))
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
        }
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
