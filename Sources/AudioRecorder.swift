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
        // Fresh engine per recording — sleep between recordings leaves a
        // stale HAL connection. But ONLY here: recreating the engine during
        // a recording closes and reopens the Bluetooth input, restarting the
        // HFP negotiation, which fires another config change — the device
        // never settles (AirPods regression of 2026-07-09).
        swapEngine()
        rebuildInputChain()
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
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.rebuildInputChain()
        }
    }

    /// Installs the tap and starts the engine for the current input device.
    private func attachInput() throws {
        let input = engine.inputNode
        // Pin the input per the mic setting (default: built-in). Bluetooth
        // mics take seconds of HFP negotiation and record phone-call quality;
        // with the built-in mic pinned the headphones stay in music mode.
        if var deviceID = AudioInputDevices.resolveForRecording(setting: Settings.shared.micUID),
           let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.d("audio: pin device id=\(deviceID) status=\(status)")
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
            onRecoveryFailed?(nothingRecorded)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuildInputChain(attempt: attempt + 1)
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
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        isRecording = false
        rebuilding = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        setConverter(nil)
        lock.lock()
        let pcm = samples
        samples = Data()
        lock.unlock()
        let duration = Double(pcm.count) / Double(AudioRecorder.sampleRate * 2)
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
            let level = min(1.0, (sum / Double(n)).squareRoot() * 6)
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
