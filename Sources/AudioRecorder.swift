import AudioToolbox
import AVFoundation

/// Microphone recording: any input format → 16 kHz mono Int16.
/// Hard duration limit — 300 seconds.
final class AudioRecorder {
    static let sampleRate = 16000
    static let maxDurationSec = 300

    private var engine = AVAudioEngine()
    /// Serial queue for all engine work. Bringing the input up (installTap,
    /// engine.start) can block for seconds on a cold or Bluetooth mic; keeping
    /// it off the main thread is what stops the UI from freezing on press.
    /// Every access to `engine` happens here so the object is never touched
    /// from two threads at once.
    private let ioQueue = DispatchQueue(label: "com.valentynbudanov.Dictate.audioIO")
    private let maxBytes = sampleRate * maxDurationSec * 2

    /// One lock guards every field shared between main, ioQueue and the tap
    /// thread (the `_`-prefixed vars plus samples/converter/counters below).
    /// Bool flags racing are mostly benign, but `_busyAppName` is a String —
    /// an unsynchronized ARC write/read is real UB, so everything goes under
    /// the same lock rather than picking case by case. NSLock is not
    /// recursive: never touch a locked property from inside withLock.
    private let lock = NSLock()
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private var samples = Data()
    private var converter: AVAudioConverter?
    /// Generation of the current recording: bumped by every start() and stop().
    /// Deferred blocks (mic-busy watchdog, rebuild retries, config-change hops)
    /// capture the value they were scheduled under and bail if it moved — so a
    /// leftover timer from one recording can never touch the next one's chain.
    private var generation = 0
    private var currentGeneration: Int { withLock { generation } }

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
    private var _isRecording = false
    private var isRecording: Bool {
        get { withLock { _isRecording } }
        set { withLock { _isRecording = newValue } }
    }
    private var _rebuilding = false
    private var rebuilding: Bool {
        get { withLock { _rebuilding } }
        set { withLock { _rebuilding = newValue } }
    }
    /// True when the input device reported a rate other than its nominal —
    /// the fingerprint of another app holding the mic in voice-processing mode
    /// (Google Meet, Zoom, FaceTime…). Read after stop() to tell a genuine
    /// silence apart from "the mic is busy elsewhere".
    private var _sawForeignFormat = false
    private(set) var sawForeignFormat: Bool {
        get { withLock { _sawForeignFormat } }
        set { withLock { _sawForeignFormat = newValue } }
    }
    /// Name of the app holding the mic when a foreign format was seen (Google
    /// Meet, Zoom…), best-effort. nil when unknown. Read after stop()/onMicBusy
    /// to name the culprit in the "mic busy" message.
    private var _busyAppName: String?
    private(set) var busyAppName: String? {
        get { withLock { _busyAppName } }
        set { withLock { _busyAppName = newValue } }
    }
    /// The device we pinned for this recording — the one to avoid when falling
    /// back to another mic because this one is held elsewhere.
    private var _pinnedDeviceID: AudioDeviceID?
    private var pinnedDeviceID: AudioDeviceID? {
        get { withLock { _pinnedDeviceID } }
        set { withLock { _pinnedDeviceID = newValue } }
    }
    /// One automatic fallback to a separate input device per recording (a busy
    /// built-in mic + a USB mic present). Guards against a switch loop.
    private var _triedFallback = false
    private var triedFallback: Bool {
        get { withLock { _triedFallback } }
        set { withLock { _triedFallback = newValue } }
    }
    /// Loudest normalized sample seen this recording (0…1) and the fraction of
    /// samples at the Int16 ceiling — surfaced as "too quiet"/"too loud" hints
    /// when nothing usable was recognized.
    private var _peakLevel: Double = 0
    var peakLevel: Double { withLock { _peakLevel } }
    private var clippedSamples = 0
    private var totalSamples = 0
    /// Fraction of captured samples pinned near the Int16 ceiling (0…1).
    var clippedFraction: Double {
        withLock { totalSamples > 0 ? Double(clippedSamples) / Double(totalSamples) : 0 }
    }
    /// Fired (on the main thread) when the mic is held by another app and even
    /// voice processing couldn't get audio — so the pill can say "mic busy"
    /// the moment it's clear, instead of after the user finishes speaking.
    var onMicBusyDetected: (() -> Void)?
    private var _micBusyReported = false
    private var micBusyReported: Bool {
        get { withLock { _micBusyReported } }
        set { withLock { _micBusyReported = newValue } }
    }

    /// Starts recording. Never throws: if the input device isn't ready
    /// (typical right after wake from sleep, or while Bluetooth negotiates),
    /// the retry loop keeps trying and reports via onRecoveryFailed only when
    /// recovery is impossible.
    func start() {
        let gen: Int = withLock {
            samples.removeAll()
            _isRecording = true
            _rebuilding = false
            _sawForeignFormat = false
            _micBusyReported = false
            _busyAppName = nil
            _pinnedDeviceID = nil
            _triedFallback = false
            _peakLevel = 0
            clippedSamples = 0
            totalSamples = 0
            generation += 1
            return generation
        }
        // Bring the input up off the main thread — engine.start()/installTap
        // block for seconds on a cold/Bluetooth mic and used to freeze the UI.
        // State and HUD stay on main; only the blocking HAL work runs here.
        // Fresh engine per recording — sleep between recordings leaves a stale
        // HAL connection. But ONLY at start: recreating the engine during a
        // recording closes and reopens the Bluetooth input, restarting the HFP
        // negotiation, which fires another config change — the device never
        // settles (AirPods regression of 2026-07-09).
        ioQueue.async { [weak self] in
            self?.swapEngine(generation: gen)
            self?.rebuildInputChain(generation: gen)
        }
    }

    /// Replaces the engine with a fresh instance (recording start only — see
    /// start()). A long-lived engine keeps a stale HAL connection across
    /// sleep and then reports garbage input formats (sampleRate 0, or a dead
    /// format that makes installTap throw).
    private func swapEngine(generation gen: Int) {
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
                guard let self, gen == self.currentGeneration, self.isRecording else { return }
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
                self.rebuildInputChain(generation: gen)
            }
        }
    }

    private var hasConverter: Bool {
        withLock { converter != nil }
    }

    /// Installs the tap and starts the engine for the current input device.
    /// `override` forces a specific device (used by the busy-mic fallback);
    /// otherwise the device follows the mic setting.
    private func attachInput(override: AudioDeviceID? = nil) throws {
        let input = engine.inputNode
        // Pin the input per the mic setting (default: built-in). Bluetooth
        // mics take seconds of HFP negotiation and record phone-call quality;
        // with the built-in mic pinned the headphones stay in music mode.
        var pinnedID: AudioDeviceID?
        if var deviceID = override ?? AudioInputDevices.resolveForRecording(setting: Settings.shared.micUID),
           let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.d("audio: pin device id=\(deviceID) status=\(status)")
            pinnedID = deviceID
        }
        pinnedDeviceID = pinnedID

        // Forcing a different device mid-recording (the busy-mic fallback) swaps
        // the HAL device out from under an engine that still holds the previous
        // device's cached input format — installTap with the new device's format
        // then throws "Failed to create tap due to format mismatch" (seen live
        // falling back off a Chrome voice-processing session, while the very same
        // 24 kHz format attached cleanly on the initial, un-cached device). The
        // engine is already stopped here (rebuildInputChain), so a reset after
        // the switch is cheap and makes the input node re-pull the new device's
        // format before the tap. Only the override path re-pins a *different*
        // device; the normal path matches what the fresh engine already saw.
        if override != nil {
            engine.reset()
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
                    // Name the culprit for the "mic busy" message (best-effort).
                    let ourPID = ProcessInfo.processInfo.processIdentifier
                    busyAppName = AudioInputDevices.appsRunningInput(excluding: ourPID).first
                    Log.d("audio: mic mode=BUSY (\(Int(reported))Hz ≠ nominal \(Int(nominal))Hz — another app holds the mic, voice-processing)\(busyAppName.map { " app=\($0)" } ?? "")")
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
    private func rebuildInputChain(attempt: Int = 0, generation gen: Int, override: AudioDeviceID? = nil) {
        // The generation check kills retries that outlived their recording:
        // without it a pending 0.3 s retry could survive a stop()+start() and
        // tear down (or re-pin, with a stale override) the NEXT recording's
        // freshly built chain.
        guard gen == currentGeneration, isRecording else { return }
        if attempt == 0 {
            guard !rebuilding else { return }   // coalesce repeated notifications
            rebuilding = true
        }

        setConverter(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        do {
            try attachInput(override: override)
            rebuilding = false
            Log.d("audio: input attached (attempt \(attempt))")
            scheduleMicBusyWatchdog(generation: gen)
            return
        } catch {
            Log.d("audio: attach failed (attempt \(attempt)): \(error.localizedDescription)")
        }

        guard attempt < 15 else {
            rebuilding = false
            isRecording = false
            let nothingRecorded = withLock { samples.isEmpty }
            Log.d("audio: recovery FAILED, cancelling (nothingRecorded=\(nothingRecorded))")
            DispatchQueue.main.async { [weak self] in self?.onRecoveryFailed?(nothingRecorded) }
            return
        }
        ioQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuildInputChain(attempt: attempt + 1, generation: gen, override: override)
        }
    }

    /// When another app owns the mic (foreign format detected), voice
    /// processing gets a brief chance to deliver audio; if nothing has arrived
    /// shortly after, report "mic busy" right away rather than making the user
    /// speak a whole sentence into the void first. Only for the foreign-format
    /// case — a normal mic waking from sleep legitimately takes a second or two,
    /// and its empty result is still handled at release.
    private func scheduleMicBusyWatchdog(generation gen: Int) {
        guard sawForeignFormat, !micBusyReported else { return }
        // Short grace in case the device recovers to its real rate and audio
        // starts flowing; if it's still empty, the mic really is held elsewhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            // Generation check: this block can outlive its recording (short
            // busy tap → immediate re-press). Without it, a leftover watchdog
            // would see the NEXT recording — empty because its engine is still
            // coming up — and wrongly declare that one's mic busy.
            guard let self, gen == self.currentGeneration,
                  self.isRecording, !self.micBusyReported else { return }
            let empty = self.withLock { self.samples.isEmpty }
            guard empty else { return }   // audio arrived — the mic is ours
            // Before declaring the mic busy, try one switch to a separate
            // physical input (e.g. a USB mic) — the call app may hold only the
            // built-in device while another mic is free. Only if one exists;
            // otherwise keep the honest "busy" message.
            if !self.triedFallback, let avoid = self.pinnedDeviceID,
               let alt = AudioInputDevices.fallbackInput(avoiding: avoid) {
                self.triedFallback = true
                Log.d("audio: mic busy -> falling back to input id=\(alt)")
                self.rebuilding = false   // let the fallback rebuild proceed
                self.ioQueue.async { [weak self] in
                    self?.rebuildInputChain(generation: gen, override: alt)
                }
                return
            }
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
        withLock { converter = c }
    }

    /// Stops recording. Returns (raw Int16 PCM, duration in seconds).
    func stop() -> (pcm: Data, duration: Double) {
        // Stop capturing and hand back the audio immediately (the caller needs
        // it now). isRecording = false halts any in-flight retry on ioQueue;
        // the generation bump kills deferred blocks even before the next start.
        let pcm: Data = withLock {
            _isRecording = false
            _rebuilding = false
            generation += 1
            let p = samples
            samples = Data()
            converter = nil          // ignore any late tap callbacks after this
            return p
        }
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
        guard let converter = withLock({ converter }) else { return }

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

        // Single pass over the buffer: RMS for the indicator, plus peak and
        // clipping tally for the "too quiet"/"too loud" hints. Samples within
        // ~0.3 dBFS of the Int16 ceiling count as clipped.
        let n = Int(out.frameLength)
        var sum: Double = 0
        var peak = 0
        var clipped = 0
        for i in 0..<n {
            let s = Int(ch[0][i])
            let a = abs(s)
            if a > peak { peak = a }
            if a >= 32760 { clipped += 1 }
            let v = Double(s) / 32768.0
            sum += v * v
        }
        withLock {
            _peakLevel = max(_peakLevel, Double(peak) / 32768.0)
            clippedSamples += clipped
            totalSamples += n
        }
        if let onLevel {
            let level = min(1.0, (sum / Double(n)).squareRoot() * 24)
            DispatchQueue.main.async { onLevel(level) }
        }

        let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        let didTruncate: Bool = withLock {
            guard samples.count < maxBytes else { return false }
            samples.append(bytes.prefix(maxBytes - samples.count))
            return samples.count >= maxBytes
        }
        if didTruncate {
            DispatchQueue.main.async { self.onTruncated?() }
        }
    }

    /// Drops pure-silence windows from the head and tail, keeping a margin so a
    /// quiet onset/offset survives. `energies` is the per-`window` RMS in
    /// temporal order; `p90` its 90th percentile. Returns the original array
    /// unchanged when there's no clear silence to cut (or nothing voiced at all).
    static func trimSilence(_ floats: [Float], energies: [Double],
                            window: Int, p90: Double) -> [Float] {
        guard p90 > 0, !energies.isEmpty, floats.count > window * 4 else { return floats }
        let threshold = p90 * 0.08
        guard let firstVoiced = energies.firstIndex(where: { $0 > threshold }),
              let lastVoiced = energies.lastIndex(where: { $0 > threshold }) else { return floats }
        let margin = 2   // windows (~200 ms) of padding on each side
        let startWin = max(0, firstVoiced - margin)
        let endWin = min(energies.count - 1, lastVoiced + margin)
        let start = startWin * window
        let end = min(floats.count, (endWin + 1) * window)
        guard start < end, end - start < floats.count else { return floats }
        return Array(floats[start..<end])
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
}
