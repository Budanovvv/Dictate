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
    static func appsRunningInput(excluding excludedPID: pid_t) -> [String] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &procs) == noErr else { return [] }

        var names: [String] = []
        var seen = Set<String>()
        for proc in procs {
            guard boolProperty(proc, kAudioProcessPropertyIsRunningInput) else { continue }
            let pid = pidProperty(proc)
            if pid == excludedPID { continue }
            guard let name = appName(pid: pid, bundleID: string(proc, kAudioProcessPropertyBundleID)) else { continue }
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    /// Best display name for a capturing process: the running app's localized
    /// name (handles helper processes — Chrome's audio runs in a helper whose
    /// parent bundle is Google Chrome), else the bundle's last component.
    private static func appName(pid: pid_t, bundleID: String?) -> String? {
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            return n
        }
        if let bundleID {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let n = app.localizedName {
                return n
            }
            return bundleID.split(separator: ".").last.map(String.init)
        }
        return nil
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
