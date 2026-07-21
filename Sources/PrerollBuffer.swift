import AVFoundation

/// Optional pre-roll: a small always-on ring of the most recent microphone
/// audio, so speech that starts a hair before the key is pressed isn't clipped.
///
/// This is deliberately SEPARATE from AudioRecorder. The recorder's input path
/// is finely tuned around sleep, Bluetooth negotiation and foreign-format
/// detection (see AudioRecorder + GRABLI); bolting an always-on tap into it
/// would risk those hard-won fixes. Instead this owns its own engine and just
/// keeps the last ~1s converted to the recorder's exact format (16 kHz mono
/// Int16), ready to prepend. If anything goes wrong it silently yields no
/// pre-roll — it must never crash the app or block a dictation.
///
/// OFF by default and gated behind Settings.prerollEnabled: keeping the mic
/// open continuously lights the macOS privacy indicator and costs a little
/// power. refresh() starts or stops it to match the setting and permission.
final class PrerollBuffer {
    static let shared = PrerollBuffer()

    /// How much recent audio to retain.
    private static let seconds = 1.0
    private static let maxBytes = Int(Double(AudioRecorder.sampleRate) * 2 * seconds)

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private let ioQueue = DispatchQueue(label: "com.valentynbudanov.Dictate.preroll")
    private let lock = NSLock()
    private var ring = Data()
    private var running = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioRecorder.sampleRate),
        channels: 1,
        interleaved: true
    )!

    private init() {}

    /// Bring the buffer up or down to match the setting. Safe to call anytime
    /// (launch, after the toggle changes, after permission is granted).
    func refresh() {
        let wanted = Settings.shared.prerollEnabled && Permissions.microphone == .granted
        ioQueue.async { [weak self] in
            guard let self else { return }
            if wanted, !self.running { self.startLocked() }
            else if !wanted, self.running { self.stopLocked() }
        }
    }

    /// The buffered recent audio (raw Int16 PCM), captured at key-press time.
    /// Empty when pre-roll is off or nothing has been captured yet.
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return ring
    }

    // MARK: - engine (all on ioQueue)

    private func startLocked() {
        let engine = AVAudioEngine()
        self.engine = engine
        // Pin the same device the recorder would use, so the pre-roll and the
        // recording come from one microphone and splice cleanly.
        let input = engine.inputNode
        if var deviceID = AudioInputDevices.resolveForRecording(setting: Settings.shared.micUID),
           let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &deviceID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            Log.d("preroll: input not ready, retry shortly")
            self.engine = nil
            ioQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
            return
        }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        var failed = false
        var nsError: NSError?
        DictateCatchObjCException({
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
                self?.append(buffer)
            }
            engine.prepare()
            do { try engine.start() } catch { failed = true; Log.d("preroll: start failed: \(error.localizedDescription)") }
        }, &nsError)
        if nsError != nil { failed = true; Log.d("preroll: tap raised \(nsError!.localizedDescription)") }
        if failed {
            teardownEngine()
            ioQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.refresh() }
            return
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.ioQueue.async { self?.rebuild() }
        }
        running = true
        Log.d("preroll: started (\(Int(inFormat.sampleRate))Hz)")
    }

    private func rebuild() {
        guard running else { return }
        Log.d("preroll: config change -> rebuild")
        stopLocked()
        startLocked()
    }

    private func stopLocked() {
        teardownEngine()
        running = false
        lock.lock(); ring.removeAll(keepingCapacity: true); lock.unlock()
        Log.d("preroll: stopped")
    }

    private func teardownEngine() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)

        lock.lock()
        ring.append(bytes)
        if ring.count > Self.maxBytes {
            ring.removeFirst(ring.count - Self.maxBytes)   // keep only the tail
        }
        lock.unlock()
    }
}
