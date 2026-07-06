import AVFoundation

/// Microphone recording: any input format → 16 kHz mono Int16.
/// Hard duration limit — 300 seconds.
final class AudioRecorder {
    static let sampleRate = 16000
    static let maxDurationSec = 300

    private let engine = AVAudioEngine()
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
    /// Device switch could not be recovered — the recording has to be cancelled.
    var onDeviceChanged: (() -> Void)?
    /// Voice level 0…1, delivered on the main thread.
    var onLevel: ((Double) -> Void)?
    private var configObserver: NSObjectProtocol?
    private var isRecording = false
    private var rebuilding = false

    func start() throws {
        lock.lock()
        samples.removeAll()
        truncated = false
        lock.unlock()

        try attachInput()
        isRecording = true
        rebuilding = false

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigChange()
        }
    }

    /// Installs the tap and starts the engine for the current input device.
    private func attachInput() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw NSError(domain: "Dictate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("Microphone unavailable (no input audio format)")
            ])
        }
        let conv = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        setConverter(conv)
    }

    /// The engine stops itself when the input device changes (AirPods connect,
    /// headphones unplug…). Rebuild the input chain for the new device and keep
    /// appending to the same buffer — the user shouldn't lose the recording.
    /// The new device may take a moment to report a valid format, so retry
    /// briefly; cancel via onDeviceChanged only if recovery fails.
    private func handleConfigChange(attempt: Int = 0) {
        guard isRecording else { return }
        if attempt == 0 {
            guard !rebuilding else { return }   // coalesce repeated notifications
            rebuilding = true
        }

        setConverter(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        if (try? attachInput()) != nil {
            rebuilding = false
            return
        }

        guard attempt < 10 else {
            rebuilding = false
            isRecording = false
            onDeviceChanged?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.handleConfigChange(attempt: attempt + 1)
        }
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
