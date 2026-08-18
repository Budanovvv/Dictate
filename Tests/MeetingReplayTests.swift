import XCTest

/// The WAV plumbing under the dump/replay debug instruments. The one property
/// that matters: a file the dump wrote is a file the replay reads back to the
/// same bytes — the bench replays exactly what the live pipeline saw.
final class MeetingReplayTests: XCTestCase {

    private func samples(_ values: [Int16]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testDumpedBytesReplayIdentically() {
        let pcm = samples([0, 1000, -1000, 32767, -32768, 42])
        let wav = MeetingWAV.header(dataBytes: pcm.count) + pcm
        XCTAssertEqual(MeetingWAV.pcm(fromWAV: wav), pcm)
    }

    func testHeaderIsTheCanonicalFortyFourBytes() {
        let header = MeetingWAV.header(dataBytes: 320)
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(header.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(header.subdata(in: 8..<12), Data("WAVE".utf8))
        // The two size fields the dump patches on close: whole-file minus 8
        // (320 + 36 = 356 = 0x0164), and the payload itself (320 = 0x0140).
        XCTAssertEqual(header.subdata(in: 4..<8), Data([0x64, 0x01, 0, 0]))
        XCTAssertEqual(header.suffix(4), Data([0x40, 0x01, 0, 0]))
    }

    func testForeignFormatsAreRefusedNotResampled() {
        // A 48 kHz file is a file the pipeline never saw — replaying it would
        // bench an input the product cannot receive.
        var header = MeetingWAV.header(dataBytes: 4)
        var rate = UInt32(48000).littleEndian
        withUnsafeBytes(of: &rate) { header.replaceSubrange(24..<28, with: $0) }
        XCTAssertNil(MeetingWAV.pcm(fromWAV: header + samples([1, 2])))
        // Stereo: same refusal.
        var stereo = MeetingWAV.header(dataBytes: 4)
        stereo[22] = 2
        XCTAssertNil(MeetingWAV.pcm(fromWAV: stereo + samples([1, 2])))
        // Not a WAV at all.
        XCTAssertNil(MeetingWAV.pcm(fromWAV: Data("not audio".utf8)))
        XCTAssertNil(MeetingWAV.pcm(fromWAV: Data()))
    }

    func testExtraChunksBeforeDataAreWalkedOver() {
        // Editors drop LIST/INFO chunks between fmt and data; the reader must
        // find the payload anyway (chunk walking, not fixed offsets).
        let pcm = samples([7, -7])
        var wav = MeetingWAV.header(dataBytes: 0).prefix(36)   // up to "data"
        wav.append(Data("LIST".utf8))
        wav.append(Data([4, 0, 0, 0]))
        wav.append(Data("INFO".utf8))
        wav.append(Data("data".utf8))
        wav.append(Data([4, 0, 0, 0]))
        wav.append(pcm)
        XCTAssertEqual(MeetingWAV.pcm(fromWAV: wav), pcm)
    }

    func testAFalseStartDoesNotSpendTheOneShot() {
        // The dump is armed, not switched on, so the shot must land on a real
        // meeting. A session opened and closed in seconds — one happened
        // during the first replay test — leaves it armed.
        let second = MeetingWAV.bytesPerSecond
        XCTAssertFalse(MeetingAudioDump.spendsTheShot(youBytes: 4 * second, themBytes: 0))
        XCTAssertFalse(MeetingAudioDump.spendsTheShot(youBytes: 0, themBytes: 0))
        XCTAssertFalse(MeetingAudioDump.spendsTheShot(youBytes: 59 * second, themBytes: 59 * second))
    }

    func testTheLongerChannelDecides() {
        // A call the owner mostly listened to still yields material, and so
        // does one where the tap never came up.
        let minimum = Int(MeetingAudioDump.minimumUsefulSeconds) * MeetingWAV.bytesPerSecond
        XCTAssertTrue(MeetingAudioDump.spendsTheShot(youBytes: 0, themBytes: minimum))
        XCTAssertTrue(MeetingAudioDump.spendsTheShot(youBytes: minimum, themBytes: 0))
    }

    func testPeakMatchesTheLiveTapsScale() {
        // The live tap reports max |sample| / 32768 — the replay must move
        // the same equalizer the same way.
        XCTAssertEqual(MeetingReplay.peak(of: samples([0, 0])), 0)
        XCTAssertEqual(MeetingReplay.peak(of: samples([16384, -100])), 0.5, accuracy: 0.001)
        XCTAssertEqual(MeetingReplay.peak(of: samples([5, -32768])), 1.0, accuracy: 0.001)
    }
}
