import AudioToolbox
import AVFoundation

/// Microphone recording: any input format → 16 kHz mono Int16.
/// Hard duration limit — 300 seconds.
final class AudioRecorder {
    static let sampleRate = 16000
    static let maxDurationSec = 300

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples = Data()
    private let lock = NSLock()
    /// Serial queue for all engine work. Bringing the input up (installTap,
    /// engine.start) can block for seconds on a cold or Bluetooth mic; keeping
    /// it off the main thread is what stops the UI from freezing on press.
    /// Every access to `engine` happens here so the object is never touched
    /// from two threads at once.
    private let ioQueue = DispatchQueue(label: "com.valentynbudanov.Dictate.audioIO")
    private var truncated = false
    private let maxBytes = sampleRate * maxDurationSec * 2

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioRecorder.sampleRate),
        channels: 1,
        interleaved: true
    )!

    var onTruncated: (() -> Void)?
    /// The input chain could not be (re)built — the recording has to be
    /// cancelled. The flag is true when no audio was captured at all
    /// (failed start) as opposed to a device change mid-recording.
    var onRecoveryFailed: ((_ nothingRecorded: Bool) -> Void)?
    /// Voice level 0…1, delivered on the main thread.
    var onLevel: ((Double) -> Void)?
    private var configObserver: NSObjectProtocol?
    private var isRecording = false
    private var rebuilding = false
    /// True when the input device reported a rate other than its nominal —
    /// the fingerprint of another app holding the mic in voice-processing mode
    /// (Google Meet, Zoom, FaceTime…). Read after stop() to tell a genuine
    /// silence apart from "the mic is busy elsewhere".
    private(set) var sawForeignFormat = false
    /// Fired (on the main thread) when the mic is held by another app and even
    /// voice processing couldn't get audio — so the pill can say "mic busy"
    /// the moment it's clear, instead of after the user finishes speaking.
    var onMicBusyDetected: (() -> Void)?
    private var micBusyReported = false

    /// Starts recording. Never throws: if the input device isn't ready
    /// (typical right after wake from sleep, or while Bluetooth negotiates),
    /// the retry loop keeps trying and reports via onRecoveryFailed only when
    /// recovery is impossible.
    func start() {
        lock.lock()
        samples.removeAll()
        truncated = false
        lock.unlock()

        isRecording = true
        rebuilding = false
        sawForeignFormat = false
        micBusyReported = false
        // Bring the input up off the main thread — engine.start()/installTap
        // block for seconds on a cold/Bluetooth mic and used to freeze the UI.
        // State and HUD stay on main; only the blocking HAL work runs here.
        // Fresh engine per recording — sleep between recordings leaves a stale
        // HAL connection. But ONLY at start: recreating the engine during a
        // recording closes and reopens the Bluetooth input, restarting the HFP
        // negotiation, which fires another config change — the device never
        // settles (AirPods regression of 2026-07-09).
        ioQueue.async { [weak self] in
            self?.swapEngine()
            self?.rebuildInputChain()
        }
    }

    /// Replaces the engine with a fresh instance (recording start only — see
    /// start()). A long-lived engine keeps a stale HAL connection across
    /// sleep and then reports garbage input formats (sampleRate 0, or a dead
    /// format that makes installTap throw).
    private func swapEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        // queue: nil → the block runs on whatever thread posts the change;
        // hop onto ioQueue so it's serialized with the rest of the engine work.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            self?.ioQueue.async {
                guard let self, self.isRecording else { return }
                // A real device change (AirPods connect, unplug…) STOPS the
                // engine — that needs a rebuild. But pinning the input at start
                // also fires this notification without stopping the engine;
                // rebuilding then just tears down a healthy chain and reattaches
                // (the old redundant double-attach). Skip while we're still
                // running fine — this can only match the spurious case, since a
                // genuine change leaves the engine stopped.
                if self.engine.isRunning, self.hasConverter {
                    Log.d("audio: config change ignored (engine still running)")
                    return
                }
                Log.d("audio: config change -> rebuild")
                self.rebuildInputChain()
            }
        }
    }

    private var hasConverter: Bool {
        lock.lock(); defer { lock.unlock() }
        return converter != nil
    }

    /// Installs the tap and starts the engine for the current input device.
    private func attachInput() throws {
        let input = engine.inputNode
        // Pin the input per the mic setting (default: built-in). Bluetooth
        // mics take seconds of HFP negotiation and record phone-call quality;
        // with the built-in mic pinned the headphones stay in music mode.
        var pinnedID: AudioDeviceID?
        if var deviceID = AudioInputDevices.resolveForRecording(setting: Settings.shared.micUID),
           let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.d("audio: pin device id=\(deviceID) status=\(status)")
            pinnedID = deviceID
        }

        // Another app holding the mic in voice-processing mode (Google Meet,
        // Zoom, FaceTime…) switches the shared device to a reduced rate and
        // starves a plain tap — the recording comes back empty. A rate that
        // isn't the device's nominal is that fingerprint; flag it so an empty
        // result surfaces fast as "mic busy" instead of silent nothing.
        // (We tried setVoiceProcessingEnabled to join the session and capture
        // anyway — measured live in Google Meet it cost ~1.1 s and STILL
        // delivered no audio, so it only delayed the message. Dropped: detect
        // and tell the user quickly instead.)
        if let pinnedID {
            let reported = input.outputFormat(forBus: 0).sampleRate
            let nominal = AudioInputDevices.nominalSampleRate(pinnedID)
            if reported > 0, nominal > 0 {
                if abs(reported - nominal) > 1 {
                    sawForeignFormat = true
                    Log.d("audio: mic mode=BUSY (\(Int(reported))Hz ≠ nominal \(Int(nominal))Hz — another app holds the mic, voice-processing)")
                } else {
                    Log.d("audio: mic mode=shared (\(Int(reported))Hz = nominal — free to record)")
                }
            }
        }

        let inFormat = input.outputFormat(forBus: 0)
        Log.d("audio: input format \(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch")
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Dictate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("Microphone unavailable (no input audio format)")
            ])
        }
        let conv = AVAudioConverter(from: inFormat, to: targetFormat)

        // installTap and engine.start raise NSException on a stale/invalid
        // format (Swift try can't catch those) — route them through the ObjC
        // catcher so they become recoverable errors for the retry loop.
        try catchingObjCException {
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
                self?.append(buffer)
            }
            engine.prepare()
        }
        var startError: Error?
        try catchingObjCException {
            do { try engine.start() } catch { startError = error }
        }
        if let startError { throw startError }
        setConverter(conv)
    }

    /// (Re)builds the input chain on the CURRENT engine, retrying briefly:
    /// used for the initial start and when the engine stops itself on a
    /// device change (AirPods connect, headphones unplug…). The recorded
    /// buffer is kept — the user shouldn't lose the recording. The engine is
    /// reset, never recreated: mid-recording recreation restarts Bluetooth
    /// HFP negotiation and the device never settles (this exact reset-based
    /// rewiring was live-tested with AirPods on 2026-07-06). The device may
    /// need seconds to report a valid format (Bluetooth negotiation, wake
    /// from sleep) — retry ~4.5 s; cancel via onRecoveryFailed only if
    /// recovery fails.
    private func rebuildInputChain(attempt: Int = 0) {
        guard isRecording else { return }
        if attempt == 0 {
            guard !rebuilding else { return }   // coalesce repeated notifications
            rebuilding = true
        }

        setConverter(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        do {
            try attachInput()
            rebuilding = false
            Log.d("audio: input attached (attempt \(attempt))")
            scheduleMicBusyWatchdog()
            return
        } catch {
            Log.d("audio: attach failed (attempt \(attempt)): \(error.localizedDescription)")
        }

        guard attempt < 15 else {
            rebuilding = false
            isRecording = false
            lock.lock()
            let nothingRecorded = samples.isEmpty
            lock.unlock()
            Log.d("audio: recovery FAILED, cancelling (nothingRecorded=\(nothingRecorded))")
            DispatchQueue.main.async { [weak self] in self?.onRecoveryFailed?(nothingRecorded) }
            return
        }
        ioQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuildInputChain(attempt: attempt + 1)
        }
    }

    /// When another app owns the mic (foreign format detected), voice
    /// processing gets a brief chance to deliver audio; if nothing has arrived
    /// shortly after, report "mic busy" right away rather than making the user
    /// speak a whole sentence into the void first. Only for the foreign-format
    /// case — a normal mic waking from sleep legitimately takes a second or two,
    /// and its empty result is still handled at release.
    private func scheduleMicBusyWatchdog() {
        guard sawForeignFormat, !micBusyReported else { return }
        // Short grace in case the device recovers to its real rate and audio
        // starts flowing; if it's still empty, the mic really is held elsewhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isRecording, !self.micBusyReported else { return }
            self.lock.lock()
            let empty = self.samples.isEmpty
            self.lock.unlock()
            guard empty else { return }   // audio arrived — the mic is ours
            self.micBusyReported = true
            Log.d("audio: foreign format + no audio after 0.4s -> mic busy (early)")
            self.onMicBusyDetected?()
        }
    }

    /// Runs body, converting a raised NSException into a thrown Swift error.
    private func catchingObjCException(_ body: () -> Void) throws {
        var nsError: NSError?
        DictateCatchObjCException(body, &nsError)
        if let nsError { throw nsError }
    }

    private func setConverter(_ c: AVAudioConverter?) {
        lock.lock()
        converter = c
        lock.unlock()
    }

    /// Stops recording. Returns (raw Int16 PCM, duration in seconds).
    func stop() -> (pcm: Data, duration: Double) {
        // Stop capturing and hand back the audio immediately (the caller needs
        // it now). isRecording = false halts any in-flight retry on ioQueue.
        isRecording = false
        rebuilding = false
        lock.lock()
        let pcm = samples
        samples = Data()
        converter = nil          // ignore any late tap callbacks after this
        lock.unlock()
        let duration = Double(pcm.count) / Double(AudioRecorder.sampleRate * 2)
        Log.d("audio: stop captured=\(pcm.count)B (\(String(format: "%.2f", duration))s) foreign=\(sawForeignFormat)")
        // Tear the engine down off the main thread — engine.stop() can block,
        // and it must run on the same queue as every other engine access.
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let o = self.configObserver {
                NotificationCenter.default.removeObserver(o)
                self.configObserver = nil
            }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
        }
        return (pcm, duration)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let conv = converter
        lock.unlock()
        guard let converter = conv else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }

        // RMS level for the indicator (slight gain so normal speech is visible)
        if let onLevel {
            var sum: Double = 0
            let n = Int(out.frameLength)
            for i in 0..<n {
                let v = Double(ch[0][i]) / 32768.0
                sum += v * v
            }
            let level = min(1.0, (sum / Double(n)).squareRoot() * 24)
            DispatchQueue.main.async { onLevel(level) }
        }

        let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        lock.lock()
        var didTruncate = false
        if samples.count < maxBytes {
            samples.append(bytes.prefix(maxBytes - samples.count))
            if samples.count >= maxBytes { didTruncate = true; truncated = true }
        }
        lock.unlock()
        if didTruncate {
            DispatchQueue.main.async { self.onTruncated?() }
        }
    }

    /// Converts raw Int16 PCM to normalized Float [-1…1] for WhisperKit.
    static func floatSamples(fromPCM pcm: Data) -> [Float] {
        let count = pcm.count / 2
        var out = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                out[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
            }
        }
        return out
    }

    static func wavData(fromPCM pcm: Data) -> Data {
        var d = Data()
        let byteRate = UInt32(sampleRate * 2)
        func put(_ s: String) { d.append(s.data(using: .ascii)!) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        put("RIFF"); put32(UInt32(36 + pcm.count)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(byteRate); put16(2); put16(16)
        put("data"); put32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
