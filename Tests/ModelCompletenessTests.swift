import XCTest

/// GRABLI/WhisperKit: the completeness verdict decides between the offline
/// load and a network re-sync — and a wrong verdict is expensive in both
/// directions. "Complete" on a half-downloaded model loads garbage; "partial"
/// on a good model triggers a Hugging Face re-verification that can invalidate
/// a working ~1 GB download (seen when interrupted mid-preload). These tests
/// pin the exact on-disk contract.
final class ModelCompletenessTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-model-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func createRequiredFiles(except missing: String? = nil) throws {
        for file in ["AudioEncoder.mlmodelc/weights/weight.bin",
                     "TextDecoder.mlmodelc/weights/weight.bin",
                     "MelSpectrogram.mlmodelc/coremldata.bin",
                     "config.json"] where file != missing {
            let url = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    func testCompleteModelIsComplete() throws {
        try createRequiredFiles()
        XCTAssertTrue(WhisperEngine.isModelComplete(inDirectory: dir))
    }

    func testMissingDecoderWeightsIsIncomplete() throws {
        try createRequiredFiles(except: "TextDecoder.mlmodelc/weights/weight.bin")
        XCTAssertFalse(WhisperEngine.isModelComplete(inDirectory: dir))
    }

    func testMissingConfigIsIncomplete() throws {
        try createRequiredFiles(except: "config.json")
        XCTAssertFalse(WhisperEngine.isModelComplete(inDirectory: dir))
    }

    /// Leftover *.incomplete markers are the fingerprint of an interrupted
    /// download — all required files can exist and the model still be broken.
    func testLeftoverIncompleteMarkerIsIncomplete() throws {
        try createRequiredFiles()
        try Data().write(to: dir.appendingPathComponent(
            "AudioEncoder.mlmodelc/weights/chunk0.incomplete"))
        XCTAssertFalse(WhisperEngine.isModelComplete(inDirectory: dir))
    }

    func testEmptyDirectoryIsIncomplete() {
        XCTAssertFalse(WhisperEngine.isModelComplete(inDirectory: dir))
    }
}
