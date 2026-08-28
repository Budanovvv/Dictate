import XCTest

// Tests compile in the same module as the sources (see project.yml) — no @testable import needed.

final class LocalizationTests: XCTestCase {
    static let allTablesForEdgeTests: [(String, [String: String])] = [
        ("ru", Localization.ru), ("uk", Localization.uk),
        ("es", Localization.es), ("pt", Localization.pt),
        ("fr", Localization.fr), ("de", Localization.de),
        ("zh", Localization.zh), ("ja", Localization.ja),
        ("ko", Localization.ko), ("vi", Localization.vi),
        ("tl", Localization.tl),
    ]
    private static var allTables: [(String, [String: String])] { allTablesForEdgeTests }

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

    /// OpenAI appears in the strings only where the ask-your-archive feature
    /// sanctions it. Dictation itself is still fully local — pinning the
    /// mentions to the credential strings keeps legacy cloud wording from
    /// creeping back under this feature's cover.
    func testOpenAIMentionsAreTheSanctionedOnes() {
        let sanctioned: Set<String> = [
            "OpenAI API key",
            "Add your OpenAI API key in Settings to ask questions",
        ]
        for (name, table) in Self.allTables {
            for (key, value) in table
            where key.lowercased().contains("openai") || value.lowercased().contains("openai") {
                XCTAssertTrue(sanctioned.contains(key),
                              "\(name): unexpected OpenAI mention in \(key)")
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
