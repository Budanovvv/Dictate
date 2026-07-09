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

    // MARK: - HAL property plumbing

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
