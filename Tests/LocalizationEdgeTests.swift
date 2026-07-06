import XCTest

/// Regression tests for localization bugs we actually hit during development.
final class LocalizationEdgeTests: XCTestCase {
    private static let translated: [AppLanguage] = [.ru, .uk, .es, .pt, .fr, .de, .zh, .ja, .ko, .vi, .tl]

    /// Bug (2026-07-06): the "Follow system" option was translated into the
    /// *current app* language, so an English system with a Russian UI showed it
    /// in Russian. It must render in the *system* language and stay stable no
    /// matter what UI language is selected.
    func testFollowSystemLabelUsesSystemLanguageAndIsStable() {
        let saved = Localization.shared.language
        defer { Localization.shared.setLanguage(saved) }

        let expected = Localization.shared.string("Follow system", in: Localization.systemLanguage)
        for lang in AppLanguage.allCases {
            Localization.shared.setLanguage(lang)
            XCTAssertEqual(AppLanguage.system.label, expected,
                "Follow-system label shifted when UI language = \(lang.rawValue)")
        }
    }

    /// systemLanguage must resolve to a concrete language, never back to .system.
    func testSystemLanguageIsConcrete() {
        XCTAssertNotEqual(Localization.systemLanguage, .system)
        XCTAssertTrue(AppLanguage.allCases.contains(Localization.systemLanguage))
    }

    /// string(_:in:) returns the right table and falls back to the key.
    func testStringInSpecificLanguage() {
        XCTAssertEqual(Localization.shared.string("Back", in: .ru), "Назад")
        XCTAssertEqual(Localization.shared.string("Back", in: .en), "Back")
        XCTAssertEqual(Localization.shared.string("__nope__", in: .ru), "__nope__")
    }

    /// Catches the real rake: a language added to the enum but not wired into
    /// the string(_:in:) switch — it would silently fall through to the key.
    /// Every translated language must actually return a translation.
    func testEveryLanguageIsWiredIn() {
        for lang in Self.translated {
            XCTAssertNotEqual(Localization.shared.string("Back", in: lang), "Back",
                "\(lang.rawValue) is not wired into string(_:in:) or is missing \"Back\"")
        }
    }

    /// No empty translation values (a blank slot ships as invisible UI).
    func testNoEmptyValues() {
        for (name, table) in LocalizationTests.allTablesForEdgeTests {
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(name): empty value for \"\(key)\"")
            }
        }
    }

    /// Interface-picker labels are non-empty and distinct (a copy-paste slip in
    /// the endonym list would make two languages indistinguishable).
    func testLanguageLabelsAreUniqueAndNonEmpty() {
        let labels = AppLanguage.allCases.map(\.label)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(labels.count, Set(labels).count, "duplicate language labels")
    }
}
