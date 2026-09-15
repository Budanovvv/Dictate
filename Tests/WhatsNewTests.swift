import XCTest

/// The What's new sheet is reachable from Settings and the corner menu at
/// any time, so the version being built must have notes — and the notes
/// must not promise what the app no longer does.
final class WhatsNewTests: XCTestCase {
    /// MARKETING_VERSION as project.yml states it — the version the build
    /// will call itself, read from the source of truth rather than from a
    /// test bundle that has no version of its own.
    private func marketingVersion() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let line = try XCTUnwrap(yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") })
        let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
        XCTAssert(parts.count >= 2, "MARKETING_VERSION line: \(line)")
        return String(parts[1])
    }

    func testTheVersionBeingBuiltHasNotes() throws {
        let version = try marketingVersion()
        let items = WhatsNew.items(for: version)
        XCTAssertFalse(items.isEmpty, "no What's new notes for \(version) — write them in WhatsNew.swift")
        XCTAssert((2...5).contains(items.count), "\(items.count) items for \(version): three or four is the shape")
        for item in items {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.line.isEmpty)
            XCTAssert(item.line.count >= 40, "a note says what changed and where: \(item.line)")
        }
    }

    /// Places and files that left the product must not be promised by any
    /// note still shown — the sheet shows the newest notes there are.
    func testNotesDoNotNameWhatIsGone() {
        let gone = ["PDF in Dictate Meetings", "Settings › Meetings › Write summaries", "Agent tab", "This Mac tab"]
        for version in ["3.3", "3.3.1"] {
            for item in WhatsNew.items(for: version) {
                for phrase in gone {
                    XCTAssertFalse(item.line.contains(phrase), "\(version): “\(phrase)” in “\(item.line)”")
                }
            }
        }
    }
}
