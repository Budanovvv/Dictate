import AudioToolbox
import AVFoundation
import CoreMedia

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
    /// CoreMedia fallback capture for a mic held by another app's
    /// voice-processing session. The AUHAL tap starves in that state, but
    /// AVCaptureSession (the QuickTime capture path) is not subject to the
    /// starvation — measured live against Chrome's 24 kHz hold: the tap got
    /// ZERO frames while the session delivered full 48 kHz audio from the
    /// same built-in mic. Both fields are ioQueue-confined (created in
    /// attachInput, torn down in stop) — no lock needed.
    private var captureSession: AVCaptureSession?
    private var captureDelegate: SessionTapDelegate?
    /// Converter for session buffers (their format differs from the engine's);
    /// under `lock` — it's touched from the session delegate queue and stop().
    private var sessionConverter: AVAudioConverter?
    private let sessionQueue = DispatchQueue(label: "com.valentynbudanov.Dictate.audioSession")
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
        // A quick tap released before this queued block ran means the swap
        // belongs to a recording that is already over. Skipping it matters:
        // ioQueue is serial, and a stale swap's HAL teardown+creation (slow on
        // a waking mic) runs BEFORE the next press's own swap+attach — that
        // backlog once delayed a real recording's attach past its release, so
        // it captured 0 bytes ("stale attach" after a rapid tap→re-hold, live
        // log 2026-08-06 12:24). stop() queues its own teardown; nothing here
        // is needed for a dead recording.
        guard gen == currentGeneration else {
            Log.d("audio: skipped stale engine swap")
            return
        }
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
                // On the capture-session path the engine is deliberately not
                // running, so the guard above can never swallow the spurious
                // notification that pinning fires — without this check every
                // busy-mic recording would tear its session down and rebuild
                // it right after start (found by review, 2026-08-06). The
                // session rides CoreMedia and doesn't care about HAL config
                // wobbles; a genuinely dead session is the watchdog's job.
                if self.captureSession != nil {
                    Log.d("audio: config change ignored (capture session active)")
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
    private static let staleAttachError = NSError(domain: "Dictate", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "stale attach"])
    private static func isStaleAttach(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == staleAttachError.domain && e.code == staleAttachError.code
    }

    private func attachInput(generation gen: Int, override: AudioDeviceID? = nil) throws {
        // The blocking work below (HAL reads, VP enable, session start) can
        // outlive its recording during a rapid stop→start; a stale attach must
        // not write foreign/busy flags into the NEXT recording's fresh state.
        guard gen == currentGeneration else { throw Self.staleAttachError }
        var input = engine.inputNode
        // Pin the input per the mic setting (default: built-in). Bluetooth
        // mics take seconds of HFP negotiation and record phone-call quality;
        // with the built-in mic pinned the headphones stay in music mode.
        let pinnedID = override ?? AudioInputDevices.resolveForRecording(setting: Settings.shared.micUID)
        func pin(_ id: AudioDeviceID) {
            var deviceID = id
            guard let unit = input.audioUnit else { return }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.d("audio: pin device id=\(deviceID) status=\(status)")
        }
        if let pinnedID { pin(pinnedID) }
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

        // Another app holding the mic in a voice-processing session (Google
        // Meet, Zoom, FaceTime, ChatGPT voice, a Safari tab…) changes what the
        // shared device hands to a plain tap, which then starves — the recording
        // comes back empty. Two fingerprints, seen live:
        //   1) rate ≠ nominal (Meet/Chrome: 24 kHz instead of 48 kHz);
        //   2) rate nominal but the BUILT-IN mic reports its raw array
        //      (48 kHz/3ch of digital silence instead of the usual mono —
        //      ChatGPT voice + Safari, 2026-07-31). Scoped to the built-in
        //      device: multi-channel USB interfaces are legitimate.
        // For fingerprint 2, joining the session with setVoiceProcessingEnabled
        // delivers real audio (measured live: plain tap peak 0.0004, VP tap
        // 0.011 ambient) — so the user dictates right through the other app.
        // For fingerprint 1 we deliberately DON'T try VP: measured live in
        // Google Meet it cost ~1.1 s and still delivered nothing, so there it
        // only delays the fast "mic busy" message + fallback path.
        if let pinnedID {
            let format = input.outputFormat(forBus: 0)
            let reported = format.sampleRate
            let nominal = AudioInputDevices.nominalSampleRate(pinnedID)
            let fp = Self.foreignFingerprint(reportedRate: reported, nominalRate: nominal,
                                             channelCount: Int(format.channelCount),
                                             isBuiltIn: AudioInputDevices.isBuiltIn(pinnedID))
            let rateForeign = fp.rate
            let rawArrayForeign = fp.rawArray
            // Re-check after the HAL reads above — same stale-attach guard as
            // at entry, now protecting the flag writes below.
            guard gen == currentGeneration else { throw Self.staleAttachError }
            if rateForeign || rawArrayForeign {
                sawForeignFormat = true
                // Name the culprit for the "mic busy" message (best-effort).
                let ourPID = ProcessInfo.processInfo.processIdentifier
                busyAppName = AudioInputDevices.appsRunningInput(excluding: ourPID).first
                let detail = rateForeign
                    ? "\(Int(reported))Hz ≠ nominal \(Int(nominal))Hz"
                    : "raw \(format.channelCount)ch array at nominal rate"
                Log.d("audio: mic mode=BUSY (\(detail) — another app holds the mic, voice-processing)\(busyAppName.map { " app=\($0)" } ?? "")")
                var joinedVP = false
                if rawArrayForeign {
                    var vpError: Error?
                    do {
                        try catchingObjCException {
                            do { try input.setVoiceProcessingEnabled(true) } catch { vpError = error }
                        }
                    } catch { vpError = error }
                    if let vpError {
                        Log.d("audio: VP join failed: \(vpError.localizedDescription)")
                    } else {
                        // Enabling VP rebuilds the underlying IO unit — re-pin.
                        input = engine.inputNode
                        pin(pinnedID)
                        Log.d("audio: joined foreign voice-processing session")
                        joinedVP = true
                    }
                }
                // The 24 kHz class (and a failed VP join): the engine tap gets
                // nothing at all there — VP can't even start (-10875 measured
                // live). Capture through AVCaptureSession instead; it rides the
                // CoreMedia path and receives real audio from the held mic.
                if !joinedVP, startCaptureSession(device: pinnedID, generation: gen) {
                    Log.d("audio: capturing via AVCaptureSession (foreign-hold bypass)")
                    return   // no tap, no engine — the session feeds append()
                }
            } else if reported > 0 {
                Log.d("audio: mic mode=shared (\(Int(reported))Hz = nominal — free to record)")
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
        // The fallback capture session must die with the chain it belonged to:
        // left running, it would keep feeding samples alongside whatever this
        // rebuild brings up (USB fallback tap, recovered normal tap) — two
        // producers interleaving into one buffer (found by review, 2026-08-06).
        stopCaptureSession()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        do {
            try attachInput(generation: gen, override: override)
            rebuilding = false
            Log.d("audio: input attached (attempt \(attempt))")
            scheduleMicBusyWatchdog(generation: gen)
            return
        } catch {
            Log.d("audio: attach failed (attempt \(attempt)): \(error.localizedDescription)")
            // Stale = the recording this chain belonged to is already over.
            // No retry can ever succeed (the generation is gone) — don't
            // occupy the serial queue the next press is waiting on.
            if Self.isStaleAttach(error) { rebuilding = false; return }
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
    private func scheduleMicBusyWatchdog(generation gen: Int, recheck: Bool = false) {
        guard sawForeignFormat, !micBusyReported else { return }
        // Short grace in case the device recovers to its real rate and audio
        // starts flowing; if it's still empty, the mic really is held elsewhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + (recheck ? 0.5 : 0.4)) { [weak self] in
            // Generation check: this block can outlive its recording (short
            // busy tap → immediate re-press). Without it, a leftover watchdog
            // would see the NEXT recording — empty because its engine is still
            // coming up — and wrongly declare that one's mic busy.
            guard let self, gen == self.currentGeneration,
                  self.isRecording, !self.micBusyReported else { return }
            let empty = self.withLock { self.samples.isEmpty }
            switch Self.busyWatchdogVerdict(samplesEmpty: empty,
                                            peakLevel: self.peakLevel,
                                            isRecheck: recheck) {
            case .audioFlowing:
                return   // audio arrived — the mic is ours
            case .recheck:
                self.scheduleMicBusyWatchdog(generation: gen, recheck: true)
                return
            case .act:
                break
            }
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

    /// The two fingerprints of "another app holds this mic in voice
    /// processing", pure for testability. `rate`: the device runs off its
    /// nominal rate (Meet/Zoom/Chrome, typically 24 kHz — the tap starves,
    /// VP can't even start; capture goes through AVCaptureSession). `rawArray`:
    /// nominal rate but the BUILT-IN mic exposes its raw multi-mic array
    /// (ChatGPT voice / Safari — joining VP delivers audio). Scoped to the
    /// built-in device: multi-channel USB interfaces are legitimate. A
    /// non-nominal rate wins over the channel signal — VP was measured dead
    /// there, the session path must be taken instead.
    static func foreignFingerprint(reportedRate: Double, nominalRate: Double,
                                   channelCount: Int, isBuiltIn: Bool)
        -> (rate: Bool, rawArray: Bool) {
        let rate = reportedRate > 0 && nominalRate > 0 && abs(reportedRate - nominalRate) > 1
        let rawArray = !rate && channelCount > 1 && isBuiltIn
        return (rate, rawArray)
    }

    /// Busy-watchdog decision, pure for testability. "Dead" is a stream of
    /// digital zeros (starved tap measured at peak 0.0004; live ambient is
    /// ≥0.005). BOTH shapes of "no audio yet" get exactly one recheck before
    /// acting — the first buffer of a freshly joined VP session or capture
    /// session routinely lands after the 0.4 s mark.
    enum BusyWatchdogVerdict { case audioFlowing, recheck, act }
    static func busyWatchdogVerdict(samplesEmpty: Bool, peakLevel: Double,
                                    isRecheck: Bool) -> BusyWatchdogVerdict {
        let dead = !samplesEmpty && peakLevel < 0.001
        guard samplesEmpty || dead else { return .audioFlowing }
        return isRecheck ? .act : .recheck
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

    /// Snapshot of the audio captured so far (raw Int16 PCM) — feeds the live
    /// transcription preview without disturbing the recording.
    func currentPCM() -> Data {
        withLock { samples }
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
            self.stopCaptureSession()
        }
        return (pcm, duration)
    }

    /// Brings up the fallback AVCaptureSession on the given device. Called on
    /// ioQueue only. Returns false when the device can't be opened this way —
    /// the caller then falls through to the plain tap + busy watchdog.
    private func startCaptureSession(device id: AudioDeviceID, generation gen: Int) -> Bool {
        stopCaptureSession()
        guard let uid = AudioInputDevices.uid(id),
              let dev = AVCaptureDevice(uniqueID: uid),
              let input = try? AVCaptureDeviceInput(device: dev) else { return false }
        let session = AVCaptureSession()
        let out = AVCaptureAudioDataOutput()
        // Pin the delivery format to mono float LPCM at the device rate:
        // without it the output hands over the device-native format, and a
        // >2-channel ASBD (the raw mic array) has no channel layout, which
        // makes AVAudioFormat(streamDescription:) return nil and every buffer
        // silently drop (found by review, 2026-08-06).
        out.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        // The delegate carries the generation of the rebuild that created it —
        // NOT currentGeneration read at some later moment — so buffers from a
        // session that outlived its recording are always rejected.
        let delegate = SessionTapDelegate(recorder: self, generation: gen)
        out.setSampleBufferDelegate(delegate, queue: sessionQueue)
        // AVCaptureSession mutation on a device in a contested state is AV
        // plumbing like any other here — route NSExceptions through the shim
        // (project rule after four installTap crashes).
        var ok = false
        try? catchingObjCException {
            guard session.canAddInput(input) else { return }
            session.addInput(input)
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            session.startRunning()
            ok = true
        }
        guard ok else { return false }
        captureSession = session
        captureDelegate = delegate
        return true
    }

    /// Tears down the fallback session (ioQueue only). Every path that changes
    /// the capture topology must call this — a leftover session is a second
    /// producer feeding the same buffer.
    private func stopCaptureSession() {
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        withLock { sessionConverter = nil }
    }

    /// Session buffers arrive on sessionQueue; convert with a converter of
    /// their own (the format differs from the engine tap's) and feed the same
    /// accumulation path as the tap — levels, peaks and limits included.
    fileprivate func appendFromSession(_ sampleBuffer: CMSampleBuffer, generation gen: Int) {
        guard gen == currentGeneration, isRecording else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        let conv: AVAudioConverter? = withLock {
            if sessionConverter == nil || sessionConverter?.inputFormat != buffer.format {
                sessionConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            return sessionConverter
        }
        guard let conv else { return }
        append(buffer, via: conv)
    }

    /// CMSampleBuffer → AVAudioPCMBuffer in the buffer's native format.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var asbd = asbdPtr.pointee
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let format = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter = withLock({ converter }) else { return }
        append(buffer, via: converter)
    }

    private func append(_ buffer: AVAudioPCMBuffer, via converter: AVAudioConverter) {
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

    /// Delegate for the fallback AVCaptureSession — a tiny bridge that hands
    /// sample buffers back to the recorder with the generation they belong to,
    /// so buffers from a torn-down session can never leak into the next
    /// recording.
    private final class SessionTapDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        private weak var recorder: AudioRecorder?
        private let generation: Int

        init(recorder: AudioRecorder, generation: Int) {
            self.recorder = recorder
            self.generation = generation
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            recorder?.appendFromSession(sampleBuffer, generation: generation)
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
}
