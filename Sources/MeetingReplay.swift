import Foundation

/// A recorded meeting as test material: dump the two capture channels once,
/// replay them through the whole pipeline forever after.
///
/// Every earlier bench was a workaround for not having this — a podcast
/// played through headphones into the live app (2026-08-14), thresholds that
/// could only be tried at the cost of one real meeting each. Both knobs are
/// hidden defaults, the `diarThreshold` precedent: development instruments,
/// never UI.
///
///     defaults write com.valentynbudanov.Dictate meetingAudioDump -bool YES
///     defaults write com.valentynbudanov.Dictate meetingReplayDir \
///         ~/Library/"Application Support"/Dictate/replay
///
/// The dump writes what the pipeline SEES — 16 kHz mono Int16, each channel
/// its own WAV — so a replay is the same bytes in the same order; the only
/// thing it cannot reproduce is the wall-clock jitter of the original call.
/// Replay paces those files in real time: the session's window cutting, VAD
/// and flush frontiers all run on the wall clock, so faster-than-real-time
/// would need a virtualized clock through the whole session first.
enum MeetingReplayDefaults {
    static let dumpKey = "meetingAudioDump"
    static let replayDirKey = "meetingReplayDir"
}

// MARK: - WAV plumbing

/// The 44-byte canonical PCM WAV header, and its reverse. Pure and testable;
/// both the dump and the replay go through these, so a dumped file is
/// replayable by construction.
enum MeetingWAV {
    static let sampleRate = 16000
    static let bytesPerSecond = sampleRate * 2   // mono Int16

    static func header(dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1)                    // PCM, mono
        u32(sampleRate); u32(bytesPerSecond)
        u16(2); u16(16)                   // block align, bits
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// The PCM payload of a WAV this dump could have written. Anything else —
    /// wrong rate, stereo, float — is refused, not resampled: the replay's
    /// whole point is bytes identical to a live capture, and a silently
    /// converted file would bench something the product never plays.
    static func pcm(fromWAV data: Data) -> Data? {
        func u32(_ at: Int) -> Int { data.subdata(in: at..<at + 4).withUnsafeBytes { Int($0.load(as: UInt32.self).littleEndian) } }
        func u16(_ at: Int) -> Int { data.subdata(in: at..<at + 2).withUnsafeBytes { Int($0.load(as: UInt16.self).littleEndian) } }
        guard data.count > 44,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }
        // Walk the chunks: some writers put extras between fmt and data.
        var at = 12
        var format: (ok: Bool, seen: Bool) = (false, false)
        while at + 8 <= data.count {
            let id = data.subdata(in: at..<at + 4)
            let size = u32(at + 4)
            let body = at + 8
            guard body + size <= data.count || id == Data("data".utf8) else { return nil }
            if id == Data("fmt ".utf8), size >= 16 {
                format = (u16(body) == 1 && u16(body + 2) == 1
                          && u32(body + 4) == sampleRate && u16(body + 14) == 16, true)
            }
            if id == Data("data".utf8) {
                guard format.seen, format.ok else { return nil }
                return data.subdata(in: body..<min(body + size, data.count))
            }
            at = body + size + (size % 2)   // chunks are word-aligned
        }
        return nil
    }
}

// MARK: - Dump

/// Writes both channels of a live session to disk as they happen. All file
/// I/O sits on its own serial queue — the tap delivers many small buffers,
/// and a meeting's main thread has been wedged by disk before.
final class MeetingAudioDump {
    private let queue = DispatchQueue(label: "dictate.meeting.dump", qos: .utility)
    private let you: FileHandle
    private let them: FileHandle
    private var youBytes = 0
    private var themBytes = 0
    let youURL: URL
    let themURL: URL

    /// nil unless the hidden default asks for a dump. Files live in
    /// App Support (NOT in Documents — iCloud has no business syncing debug
    /// audio), named after the transcript so they find each other later.
    static func ifRequested(stem: String) -> MeetingAudioDump? {
        guard UserDefaults.standard.bool(forKey: MeetingReplayDefaults.dumpKey) else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate/replay", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try MeetingAudioDump(
                you: dir.appendingPathComponent("\(stem).you.wav"),
                them: dir.appendingPathComponent("\(stem).them.wav"))
        } catch {
            Log.d("dump: could not open files: \(error.localizedDescription)")
            return nil
        }
    }

    private init(you youURL: URL, them themURL: URL) throws {
        for url in [youURL, themURL] {
            try MeetingWAV.header(dataBytes: 0).write(to: url)
        }
        self.youURL = youURL
        self.themURL = themURL
        you = try FileHandle(forWritingTo: youURL)
        them = try FileHandle(forWritingTo: themURL)
        you.seekToEndOfFile()
        them.seekToEndOfFile()
        Log.d("dump: recording channels -> \(youURL.lastPathComponent), \(themURL.lastPathComponent)")
    }

    func appendYou(_ pcm: Data) {
        queue.async { self.you.write(pcm); self.youBytes += pcm.count }
    }

    func appendThem(_ pcm: Data) {
        queue.async { self.them.write(pcm); self.themBytes += pcm.count }
    }

    /// Patches the header sizes and closes. After this the files are ordinary
    /// WAVs — playable in QuickTime, replayable here.
    func close() {
        queue.async {
            for (handle, bytes) in [(self.you, self.youBytes), (self.them, self.themBytes)] {
                handle.seek(toFileOffset: 0)
                handle.write(MeetingWAV.header(dataBytes: bytes))
                try? handle.close()
            }
            Log.d(String(format: "dump: closed — you %.1fs, them %.1fs",
                         Double(self.youBytes) / Double(MeetingWAV.bytesPerSecond),
                         Double(self.themBytes) / Double(MeetingWAV.bytesPerSecond)))
        }
    }
}

// MARK: - Replay

/// Feeds a dumped pair of channel files back into a session, paced in real
/// time — half-second pushes, the same order of magnitude the live capture
/// paths deliver in. The session neither knows nor cares that the audio is
/// canned; that is the whole design.
final class MeetingReplay {
    var onYou: ((Data, Double) -> Void)?
    var onThem: ((Data, Double) -> Void)?
    /// Both files ran dry. The session stays up — stopping is the owner's
    /// call, exactly as in a live meeting.
    var onFinished: (() -> Void)?

    private var youPCM: Data
    private var themPCM: Data
    private var offset = 0
    private var timer: DispatchSourceTimer?
    private static let step = MeetingWAV.bytesPerSecond / 2   // 0.5 s per push

    /// nil unless the hidden default names a directory holding exactly one
    /// dumped pair. A directory with several dumps is refused by name — the
    /// bench must never quietly pick a file the owner didn't mean.
    static func ifRequested() -> MeetingReplay? {
        guard let raw = UserDefaults.standard.string(forKey: MeetingReplayDefaults.replayDirKey),
              !raw.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        let wavs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        let youFiles = wavs.filter { $0.lastPathComponent.hasSuffix(".you.wav") }
        let themFiles = wavs.filter { $0.lastPathComponent.hasSuffix(".them.wav") }
        guard youFiles.count == 1, themFiles.count == 1 else {
            Log.d("replay: \(dir.path) must hold exactly one *.you.wav + *.them.wav pair "
                  + "(found \(youFiles.count)/\(themFiles.count)) — running live instead")
            return nil
        }
        guard let youData = try? Data(contentsOf: youFiles[0]),
              let themData = try? Data(contentsOf: themFiles[0]),
              let you = MeetingWAV.pcm(fromWAV: youData),
              let them = MeetingWAV.pcm(fromWAV: themData) else {
            Log.d("replay: could not read the pair as 16k mono PCM WAVs — running live instead")
            return nil
        }
        Log.d(String(format: "replay: %@ — you %.1fs, them %.1fs",
                     youFiles[0].deletingPathExtension().deletingPathExtension().lastPathComponent,
                     Double(you.count) / Double(MeetingWAV.bytesPerSecond),
                     Double(them.count) / Double(MeetingWAV.bytesPerSecond)))
        return MeetingReplay(you: you, them: them)
    }

    private init(you: Data, them: Data) {
        youPCM = you
        themPCM = them
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.push() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func push() {
        guard offset < youPCM.count || offset < themPCM.count else {
            stop()
            Log.d("replay: files drained — stop the session when ready")
            onFinished?()
            return
        }
        for (pcm, deliver) in [(youPCM, onYou), (themPCM, onThem)] {
            guard offset < pcm.count, let deliver else { continue }
            let chunk = pcm.subdata(in: offset..<min(offset + Self.step, pcm.count))
            deliver(chunk, Self.peak(of: chunk))
        }
        offset += Self.step
    }

    /// The same 0…1 peak the live tap reports alongside its buffers.
    static func peak(of pcm: Data) -> Double {
        pcm.withUnsafeBytes { raw -> Double in
            let samples = raw.bindMemory(to: Int16.self)
            var top: Int32 = 0
            for s in samples { top = max(top, abs(Int32(s))) }
            return Double(top) / 32768.0
        }
    }
}
