import XCTest

// Tests compile in the same module as the sources (see project.yml) — no @testable import needed.

final class LocalizationTests: XCTestCase {
    private static let allTables: [(String, [String: String])] = [
        ("ru", Localization.ru), ("uk", Localization.uk),
        ("es", Localization.es), ("pt", Localization.pt),
        ("fr", Localization.fr), ("de", Localization.de),
        ("zh", Localization.zh), ("ja", Localization.ja),
        ("ko", Localization.ko), ("vi", Localization.vi),
        ("tl", Localization.tl),
    ]

    /// Every table has the same key set — no language lags behind.
    func testAllTablesShareTheSameKeys() {
        let reference = Set(Localization.ru.keys)
        for (name, table) in Self.allTables {
            let keys = Set(table.keys)
            XCTAssertEqual(keys, reference,
                "Table \(name): extra \(keys.subtracting(reference)), missing \(reference.subtracting(keys))")
        }
    }

    /// Placeholders in each translation match the key — a mismatch crashes String(format:).
    func testPlaceholdersMatch() throws {
        let pattern = try NSRegularExpression(pattern: "%[0-9.]*[d@fs]")
        func placeholders(_ s: String) -> [String] {
            pattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .compactMap { Range($0.range, in: s).map { String(s[$0]) } }
                .sorted()
        }
        for (name, table) in Self.allTables {
            for (key, value) in table {
                XCTAssertEqual(placeholders(key), placeholders(value),
                    "\(name): placeholders diverged in \"\(key.prefix(60))\"")
            }
        }
    }

    /// No legacy OpenAI mentions in the strings — the app is fully local.
    func testNoLegacyOpenAIStrings() {
        for (name, table) in Self.allTables {
            for (key, value) in table {
                XCTAssertFalse(key.lowercased().contains("openai"),
                               "\(name): key with OpenAI: \(key)")
                XCTAssertFalse(value.lowercased().contains("openai"),
                               "\(name): translation with OpenAI: \(value)")
            }
        }
    }

    /// Switching the language changes the strings; an unknown key falls back to itself (English).
    func testTranslateAndFallback() {
        let saved = Localization.shared.language
        defer { Localization.shared.setLanguage(saved) }

        Localization.shared.setLanguage(.ru)
        XCTAssertEqual(L("Back"), "Назад")
        XCTAssertEqual(L("__unknown_key__"), "__unknown_key__")

        Localization.shared.setLanguage(.uk)
        XCTAssertEqual(L("Back"), "Назад")  // uk: "Назад" as well

        Localization.shared.setLanguage(.en)
        XCTAssertEqual(L("Back"), "Back")
    }

    /// Every language in the enum has a human-readable name in the list.
    func testEveryLanguageHasLabel() {
        for lang in AppLanguage.allCases {
            XCTAssertFalse(lang.label.isEmpty, "no label for \(lang.rawValue)")
        }
    }

    /// Lf substitutes format arguments in every language without crashing.
    func testFormattedStringsDoNotCrash() {
        let saved = Localization.shared.language
        defer { Localization.shared.setLanguage(saved) }
        for lang in AppLanguage.allCases where lang != .system {
            Localization.shared.setLanguage(lang)
            let s = Lf("Words: %d · %.1f s", 14, 2.8)
            XCTAssertTrue(s.contains("14"), "\(lang.rawValue): \(s)")
            let mb = Lf("Downloaded %d of %d MB", 480, 950)
            XCTAssertTrue(mb.contains("480") && mb.contains("950"), "\(lang.rawValue): \(mb)")
        }
    }
}
