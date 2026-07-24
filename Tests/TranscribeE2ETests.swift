import XCTest

/// End-to-end recognition without a microphone: `say` synthesis → afconvert → WhisperKit.
/// Heavy (loads the model), so it is opt-in: DICTATE_E2E=1 or the flag file /tmp/dictate-e2e.
final class TranscribeE2ETests: XCTestCase {
    private var e2eEnabled: Bool {
        ProcessInfo.processInfo.environment["DICTATE_E2E"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/dictate-e2e")
    }

    /// Synthesized English speech round-trips through the full recognition pipeline.
    func testSynthesizedEnglishIsRecognized() async throws {
        try XCTSkipUnless(e2eEnabled, "E2E disabled (DICTATE_E2E=1 or touch /tmp/dictate-e2e)")
        try XCTSkipUnless(WhisperEngine.shared.isModelDownloaded(tier: .fast),
                          "model not downloaded — complete the onboarding")

        let phrase = "The quick brown fox jumps over the lazy dog"
        let floats = try synthesize(phrase)
        XCTAssertGreaterThan(floats.count, 16000, "less than a second of audio — synthesis failed")

        try await WhisperEngine.shared.prepare(tier: .fast) { _ in }
        let text = try await WhisperEngine.shared.transcribe(
            floats: floats, tier: .fast, language: "en", prompt: ""
        ).text.lowercased()

        XCTAssertTrue(text.contains("quick brown fox"),
                      "recognized: \"\(text)\"")
        XCTAssertTrue(text.contains("lazy dog"),
                      "recognized: \"\(text)\"")
    }

    // MARK: - synthesis: say → afconvert → 16 kHz mono float

    private func synthesize(_ phrase: String, voice: String? = nil) throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory
        let aiff = dir.appendingPathComponent("dictate-e2e-\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: aiff)
                try? FileManager.default.removeItem(at: wav) }

        var sayArgs = ["-o", aiff.path, phrase]
        if let voice { sayArgs = ["-v", voice] + sayArgs }
        try run("/usr/bin/say", sayArgs)
        try run("/usr/bin/afconvert",
                ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])

        let data = try Data(contentsOf: wav)
        guard data.count > 44 else { throw XCTSkip("afconvert produced an empty file") }
        return AudioRecorder.floatSamples(fromPCM: data.dropFirst(44))  // 44 = canonical WAV header
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "e2e", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) exited with \(p.terminationStatus)"])
        }
    }
}
