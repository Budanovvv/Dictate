import XCTest

/// The engine-side gate and the helper's pre-flight — the two places where
/// a model on disk is NOT run. `LlamaServer.refusal` is asked with the real
/// kernel numbers, so the tests only pin the shape of its answers: a call in
/// progress refuses with `.call`, and a plan is refused when the headroom
/// falls short.
final class LocalTextModelGateTests: XCTestCase {

    override func tearDown() {
        LlamaServer.callInProgress.set(false)
        super.tearDown()
    }

    func testACallInProgressRefusesTheHelper() {
        LlamaServer.callInProgress.set(true)
        let plan = LocalTextModelFile.helperPlan(for: MachineProfile.current)
        guard let (why, detail) = LlamaServer.refusal(for: plan) else {
            return XCTFail("the helper must not start under a live call")
        }
        XCTAssertEqual(why, .call)
        XCTAssertTrue(detail.contains("recorded"), detail)
    }

    func testAnImpossibleHeadroomRefusesWithMemory() {
        LlamaServer.callInProgress.set(false)
        // A plan no Mac can satisfy: a context so large the cache alone is
        // terabytes.
        let plan = LocalTextModelFile.HelperPlan(contextSize: 1 << 30, kvCache: .f16,
                                                 flashAttention: false, idleTimeout: 60,
                                                 briefLimit: 1)
        guard let (why, detail) = LlamaServer.refusal(for: plan) else {
            return XCTFail("a terabyte of cache does not fit")
        }
        // Either the kernel already reports pressure or the headroom is
        // short — both are the memory answer.
        XCTAssertEqual(why, .memory)
        XCTAssertFalse(detail.isEmpty)
    }

    func testTheDeferredFailureIsTheOnlyDeferredOne() {
        XCTAssertTrue(GenerationFailure.deferred("later").isDeferred)
        XCTAssertFalse(GenerationFailure.failed("never").isDeferred)
        XCTAssertFalse(GenerationFailure.unavailable.isDeferred)
        XCTAssertFalse(GenerationFailure.tooLong.isDeferred)
    }

    func testHalvingKeepsEveryOtherLineAcrossTheWholeText() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let halved = LocalTextEngine.halved(text)
        XCTAssertEqual(halved, "line 1\nline 3\nline 5\nline 7\nline 9")
    }

    func testTheDownloadIsOfferedOnlyWhereItCanRun() {
        // The same predicate the offer, the row and the engine share.
        XCTAssertEqual(LocalTextModelFile.isRunnable(memory: 8 << 30, supported: true), false)
        XCTAssertEqual(LocalTextModelFile.isRunnable(memory: 16 << 30, supported: true), true)
        XCTAssertEqual(LocalTextModelFile.isRunnable(memory: 64 << 30, supported: false), false)
    }
}
