import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Captures the SYSTEM's audio output — everyone else in a call — through a
/// global Core Audio process tap (macOS 14.4+), excluding our own process.
/// Proven by the 2026-08-09 spike: a browser (Meet/Zoom in Chrome) is
/// captured cleanly and transcribes verbatim; no drivers, no virtual
/// devices, and the TCC grant is "System Audio Recording Only" — far
/// friendlier than Screen Recording. Known limit: VoIP apps that render
/// through their own voice-processing output (FaceTime) bypass the tap;
/// browser meetings are the v1 target.
///
/// Delivers 16 kHz mono Int16 buffers via onBuffer (arbitrary queue) plus a
/// cheap peak level for the caller's silence windowing.
final class MeetingTap {

    /// (pcm16k, peak 0…1). Called on the tap's IO thread — keep it light.
    var onBuffer: ((Data, Double) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private static let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                 sampleRate: 16000, channels: 1,
                                                 interleaved: true)!

    enum TapError: Error, LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            if case let .coreAudio(what, st) = self {
                return "\(what) failed (\(st))"
            }
            return nil
        }
    }

    private func require(_ st: OSStatus, _ what: String) throws {
        guard st == noErr else {
            Log.d("meeting: \(what) failed status=\(st)")
            throw TapError.coreAudio(what, st)
        }
    }

    /// Brings the tap up. Throws on any Core Audio refusal (the first call
    /// also triggers the system-audio-recording TCC prompt for the app).
    func start() throws {
        stop()   // idempotent re-entry

        // Exclude our own process: Dictate's sounds (start/stop cues) must
        // not end up in the meeting transcript.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var selfObj = AudioObjectID(kAudioObjectUnknown)
        var pid = ProcessInfo.processInfo.processIdentifier
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), &pid, &size, &selfObj)
        let excluded: [AudioObjectID] = selfObj != kAudioObjectUnknown ? [selfObj] : []

        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Dictate meeting tap"
        desc.isPrivate = true
        try require(AudioHardwareCreateProcessTap(desc, &tapID), "create process tap")

        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try require(AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &asbd),
                    "read tap format")
        guard let inFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.coreAudio("tap format", -1)
        }
        tapFormat = inFormat
        converter = AVAudioConverter(from: inFormat, to: Self.outFormat)
        Log.d("meeting: tap up, format \(Int(asbd.mSampleRate))Hz/\(asbd.mChannelsPerFrame)ch")

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dictate meeting capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        try require(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID),
                    "create aggregate device")
        try require(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) {
            [weak self] _, inData, _, _, _ in
            self?.handle(inData)
        }, "create io proc")
        try require(AudioDeviceStart(aggregateID, ioProc), "start aggregate device")
    }

    func stop() {
        if let ioProc, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        tapFormat = nil
    }

    private func handle(_ inData: UnsafePointer<AudioBufferList>) {
        guard let converter, let tapFormat else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count > 0, let src = abl[0].mData else { return }
        let frames = AVAudioFrameCount(Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
                                       / max(1, Int(tapFormat.channelCount)))
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        // The tap is a mono mixdown — one buffer; copy it into the AVAudio
        // world for the converter.
        if let dst = inBuf.floatChannelData?[0] {
            dst.update(from: src.bindMemory(to: Float.self, capacity: Int(frames)),
                       count: Int(frames))
        }
        let ratio = Self.outFormat.sampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        var peak = 0
        for i in 0..<n {
            let a = abs(Int(ch[0][i]))
            if a > peak { peak = a }
        }
        let data = Data(bytes: ch[0], count: n * 2)
        onBuffer?(data, Double(peak) / 32768.0)
    }
}
