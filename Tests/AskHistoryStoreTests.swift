import XCTest

final class AskHistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: AskHistoryStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-history-tests-\(UUID().uuidString)")
        store = AskHistoryStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func conversation(title: String, lastActive: Date = Date()) -> AskConversation {
        AskConversation(
            id: UUID(), title: title, createdAt: lastActive, lastActiveAt: lastActive,
            turns: [.init(question: title, prompt: "p: \(title)", text: "answer")])
    }

    func testSaveLoadRoundTrip() {
        let saved = conversation(title: "What did Priya promise?")
        store.save(saved)
        let loaded = store.load(saved.id)
        XCTAssertEqual(loaded?.title, saved.title)
        XCTAssertEqual(loaded?.turns.count, 1)
        XCTAssertEqual(loaded?.turns.first?.text, "answer")
    }

    func testListNewestFirst() {
        store.save(conversation(title: "old", lastActive: Date(timeIntervalSinceNow: -100)))
        store.save(conversation(title: "new", lastActive: Date()))
        XCTAssertEqual(store.list().map(\.title), ["new", "old"])
    }

    func testRename() {
        let saved = conversation(title: "first question")
        store.save(saved)
        store.rename(saved.id, to: "Priya's promises")
        XCTAssertEqual(store.load(saved.id)?.title, "Priya's promises")
        // Whitespace-only rename is ignored, not applied.
        store.rename(saved.id, to: "   ")
        XCTAssertEqual(store.load(saved.id)?.title, "Priya's promises")
    }

    func testDeleteIsImmediateAndIdempotent() {
        let saved = conversation(title: "gone")
        store.save(saved)
        store.delete(saved.id)
        XCTAssertNil(store.load(saved.id))
        store.delete(saved.id)   // second delete must not blow up
        XCTAssertTrue(store.list().isEmpty)
    }

    func testCapAgesOutOldest() {
        for i in 0..<(AskHistoryStore.cap + 3) {
            store.save(conversation(title: "q\(i)",
                                    lastActive: Date(timeIntervalSinceNow: Double(i))))
        }
        let titles = store.list().map(\.title)
        XCTAssertEqual(titles.count, AskHistoryStore.cap)
        // The newest survived, the three oldest aged out.
        XCTAssertEqual(titles.first, "q\(AskHistoryStore.cap + 2)")
        XCTAssertFalse(titles.contains("q0"))
        XCTAssertFalse(titles.contains("q2"))
    }

    func testUndeleteRestoresTheLastDeleted() {
        let saved = conversation(title: "regret")
        store.save(saved)
        store.delete(saved.id)
        XCTAssertNil(store.load(saved.id))
        XCTAssertEqual(store.undelete()?.title, "regret")
        XCTAssertEqual(store.load(saved.id)?.title, "regret")
        // The slot is one-shot.
        XCTAssertNil(store.undelete())
    }
}
