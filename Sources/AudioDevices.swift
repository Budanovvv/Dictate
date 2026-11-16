import AppKit
import CoreAudio

/// Core Audio HAL input devices: enumeration and the recording-time pick.
enum AudioInputDevices {
    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32

        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        /// Bluetooth mics run over HFP/SCO: seconds to start, phone-call quality.
        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }

    /// All devices that have input channels.
    static func all() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name, transport: transport(id))
        }
    }

    /// Name of the CURRENT default input device ("AirPods Pro") — for the
    /// mid-recording device-change notice (design: interrupted).
    static func defaultInputName() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    /// One log fragment describing the audio situation around a slow mic
    /// attach: the default input (name, Bluetooth or not, running in some
    /// process) and whether the pinned device is running somewhere. A 3.00 s
    /// stall correlates with AirPods in call mode as the default input
    /// (2026-11-13), but a prepared chain later went slow again with no new
    /// call — this line is how the next slow attach explains itself.
    static func slowAttachContext(pinned: AudioDeviceID?) -> String {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var parts: [String] = []
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &addr, 0, nil, &size, &id) == noErr, id != 0 {
            let t = transport(id)
            let bt = t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
            parts.append("default=\"\(string(id, kAudioObjectPropertyName) ?? "?")\"")
            parts.append("bt=\(bt)")
            parts.append("defaultRunning=\(isRunningSomewhere(id))")
            parts.append("defaultRate=\(Int(nominalSampleRate(id)))")
        } else {
            parts.append("default=?")
        }
        if let pinned { parts.append("pinnedRunning=\(isRunningSomewhere(pinned))") }
        let others = appsRunningInput(excluding: ProcessInfo.processInfo.processIdentifier)
        parts.append("inputApps=[\(others.joined(separator: ","))]")
        return parts.joined(separator: " ")
    }

    /// Device to pin for recording per the mic setting; nil → engine default.
    /// "" (the default) — built-in mic: no Bluetooth negotiation delays, no
    /// HFP quality drop, headphones stay in music mode. Falls back to the
    /// system default when unavailable (clamshell mode, Mac mini).
    static func resolveForRecording(setting: String) -> AudioDeviceID? {
        switch setting {
        case "system": return nil
        case "": return all().first(where: { $0.isBuiltIn })?.id
        default: return all().first(where: { $0.uid == setting })?.id
        }
    }

    /// Display names of the apps currently running microphone input, excluding
    /// our own process. When another app holds the mic in voice-processing mode
    /// we can name the culprit ("Microphone busy: Google Meet") instead of a
    /// generic message. Backed by the Core Audio process objects API (macOS 14+):
    /// each process object exposes whether it's running input, its pid and its
    /// bundle ID — reading these needs no tap entitlement (that's only for
    /// actually capturing another process's audio). Returns [] if nothing else
    /// is capturing or the API is unavailable.
    /// Ordered user apps first: the name shown in "mic busy" is `.first`, and
    /// a system daemon that always listens (corespeechd — Siri) used to win
    /// it over the real holder. Live 2026-11-16: a Safari tab held the
    /// built-in mic in voice processing, and the message named "CoreSpeech".
    static func appsRunningInput(excluding excludedPID: pid_t) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for holder in inputHolders(excluding: excludedPID).sorted(by: { $0.isUserApp && !$1.isUserApp })
        where seen.insert(holder.name).inserted {
            names.append(holder.name)
        }
        return names
    }

    /// The user-facing app (never a system daemon) running input on this
    /// device right now, or nil. "Running input on our device" is what makes
    /// another app's voice-processing session muffle what we get from the
    /// same mic — without any format change to notice it by (2026-11-16:
    /// 48 kHz/1ch "free to record", ~28 dB down, until Safari was quit).
    static func userAppHolding(_ device: AudioDeviceID, excluding excludedPID: pid_t) -> String? {
        inputHolders(excluding: excludedPID).first { $0.isUserApp && $0.devices.contains(device) }?.name
    }

    /// One process running audio input, as the HAL reports it.
    struct InputHolder {
        let name: String
        /// Resolved through a running app or an .app path — a person can see
        /// and close it. False for system daemons named only by bundle ID.
        let isUserApp: Bool
        /// Input devices this process is running on.
        let devices: [AudioDeviceID]
    }

    static func inputHolders(excluding excludedPID: pid_t) -> [InputHolder] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &procs) == noErr else { return [] }

        var holders: [InputHolder] = []
        for proc in procs {
            guard boolProperty(proc, kAudioProcessPropertyIsRunningInput) else { continue }
            let pid = pidProperty(proc)
            if pid == excludedPID { continue }
            guard let (name, isUserApp) = appName(pid: pid, bundleID: string(proc, kAudioProcessPropertyBundleID))
            else { continue }
            holders.append(InputHolder(name: name, isUserApp: isUserApp, devices: inputDevices(ofProcess: proc)))
        }
        return holders
    }

    private static func inputDevices(ofProcess proc: AudioObjectID) -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(proc, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Best display name for a capturing process: the running app's localized
    /// name (handles helper processes — Chrome's audio runs in a helper whose
    /// parent bundle is Google Chrome), else the bundle's last component.
    /// The flag says whether a person can see the result as an app (see
    /// InputHolder.isUserApp).
    private static func appName(pid: pid_t, bundleID: String?) -> (String, Bool)? {
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            return (webKitOwnerName(n), true)
        }
        // Helper processes buried inside an app bundle (ChatGPT voice runs in
        // "Codex (Service)") aren't NSRunningApplications and expose no bundle
        // ID through the HAL — but their executable path still names the owning
        // .app. Skipped for system daemons (no ".app" in their paths).
        if pid > 0 {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
               let name = appBundleName(fromPath: String(cString: buf)) {
                return (name, true)
            }
        }
        if let bundleID {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let n = app.localizedName {
                return (webKitOwnerName(n), true)
            }
            return bundleID.split(separator: ".").last.map { (String($0), false) }
        }
        return nil
    }

    /// WebKit runs a page's microphone in a shared XPC service whose running
    /// name is its owner's plus a role — "Safari Graphics and Media" (seen
    /// live 2026-11-16). A person knows the app, not the role. Pure for
    /// testability; any other name passes through.
    static func webKitOwnerName(_ name: String) -> String {
        for suffix in [" Graphics and Media", " Web Content", " Networking"] where name.hasSuffix(suffix) {
            let owner = String(name.dropLast(suffix.count))
            if !owner.isEmpty { return owner }
        }
        return name
    }

    /// Owning app name from an executable path: the FIRST ".app" component
    /// from the root, so a helper nested inside another bundle ("Codex
    /// (Service).app" inside ChatGPT.app) resolves to the outer, user-facing
    /// app. nil for anything outside an app bundle (system daemons, XPC
    /// services in frameworks). Pure for testability.
    static func appBundleName(fromPath path: String) -> String? {
        guard let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") })
        else { return nil }
        return String(bundle.dropLast(4))
    }

    /// A different input device to fall back to when the current one (`avoid`)
    /// is held by another app in voice-processing mode. Prefers a truly separate
    /// physical device (USB mic, audio interface) — never Bluetooth (HFP is slow
    /// and phone-quality) and never a virtual/aggregate loopback. Returns nil
    /// when the only real mic is the one that's busy, so the caller keeps the
    /// honest "mic busy" message instead of switching to nothing.
    ///
    /// Also skips a candidate that another process is already running IO on: a
    /// voice-processing session drags the whole shared input path to its reduced
    /// rate, so a second device surfaced by that session reports the same 24 kHz
    /// and starves a plain tap just like the built-in did (measured live falling
    /// back off a Google Chrome session — the "fallback" was itself busy, so the
    /// switch only added a second of failed tap retries before "mic busy"). A
    /// running candidate is no escape; only a genuinely idle mic is.
    static func fallbackInput(avoiding avoid: AudioDeviceID) -> AudioDeviceID? {
        all().first { dev in
            dev.id != avoid && !dev.isBluetooth && dev.transport != kAudioDeviceTransportTypeVirtual
                && dev.transport != kAudioDeviceTransportTypeAggregate
                // Continuity (iPhone) mics count as input devices but silently
                // switching a dictation onto the user's phone would be baffling.
                && dev.transport != kAudioDeviceTransportTypeContinuityCaptureWired
                && dev.transport != kAudioDeviceTransportTypeContinuityCaptureWireless
                && !isRunningSomewhere(dev.id)
        }?.id
    }

    /// HAL device UID — the same string AVCaptureDevice uses as uniqueID, so
    /// the busy-mic fallback can open the very device we pinned through the
    /// CoreMedia capture path.
    static func uid(_ id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    /// Whether this device is the built-in microphone. Used to scope the
    /// raw-array busy fingerprint (built-in reporting >1 channel) — external
    /// multi-channel interfaces are legitimate and must not match it.
    static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        transport(id) == kAudioDeviceTransportTypeBuiltIn
    }

    /// Whether any process is currently running input/output on this device.
    /// Reads through the HAL (no VP session or attached engine needed), so it's
    /// how `fallbackInput` tells an idle mic from one already swept into another
    /// app's voice-processing session.
    static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        boolProperty(id, kAudioDevicePropertyDeviceIsRunningSomewhere)
    }

    // MARK: - HAL property plumbing

    private static func boolProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func pidProperty(_ id: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = -1
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return -1 }
        return value
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let value else { return nil }
        return value as String
    }

    /// The device's own nominal sample rate. When another app holds the mic
    /// in a voice-processing session (Google Meet, Zoom, FaceTime…), the shared
    /// built-in mic is switched to a reduced rate (typically 24 kHz) and a plain
    /// input tap on it is starved — no buffers arrive. Comparing the engine's
    /// reported input rate against this nominal is how we detect that state.
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var size = UInt32(MemoryLayout<Float64>.size)
        var value: Float64 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
