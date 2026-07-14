import XCTest

final class SettingsTests: XCTestCase {
    /// The only model is full large-v3: turbo ignores task=translate, so a fallback to it would silently break translation.
    func testSingleModelIsFullLargeV3() {
        XCTAssertEqual(Settings.shared.modelTier, .ultra)
        XCTAssertEqual(ModelTier.allCases, [.ultra])
        XCTAssertEqual(ModelTier.ultra.variant, "openai_whisper-large-v3_947MB")
        XCTAssertFalse(ModelTier.ultra.variant.contains("turbo"),
                       "turbo does not translate — do not fall back to it")
        XCTAssertEqual(ModelTier.ultra.sizeHint, "~950 MB")
    }

    /// Shipping default hotkey is the right Option key (runner has clean UserDefaults).
    func testDefaults() {
        XCTAssertEqual(Settings.shared.hotkeyKeyCode, 61)
    }
}

final class KeyNamesTests: XCTestCase {
    /// Modifiers are safe as a hotkey, typing keys are not.
    func testSafeHotkeys() {
        for code in [58, 61, 54, 55, 56, 60, 59, 62] {   // Option/Cmd/Shift/Ctrl
            XCTAssertTrue(KeyNames.isSafeHotkey(code), "modifier \(code) must be safe")
        }
        XCTAssertFalse(KeyNames.isSafeHotkey(0), "the A key types characters")
        XCTAssertFalse(KeyNames.isSafeHotkey(49), "the space key types characters")
    }
}

final class AudioConversionTests: XCTestCase {
    /// Int16 PCM → Float conversion preserves range, sign and zero.
    func testFloatSamplesConversion() {
        var samples: [Int16] = [0, Int16.max, Int16.min, 16384, -16384]
        let data = Data(bytes: &samples, count: samples.count * 2)
        let floats = AudioRecorder.floatSamples(fromPCM: data)

        XCTAssertEqual(floats.count, samples.count)
        XCTAssertEqual(floats[0], 0, accuracy: 0.0001)
        XCTAssertEqual(floats[1], 1.0, accuracy: 0.001)
        XCTAssertEqual(floats[2], -1.0, accuracy: 0.001)
        XCTAssertEqual(floats[3], 0.5, accuracy: 0.001)
        XCTAssertEqual(floats[4], -0.5, accuracy: 0.001)
    }

    /// Buffer pre-allocation and error text both rely on this constant.
    func testRecordingLimit() {
        XCTAssertEqual(AudioRecorder.maxDurationSec, 300)
    }
}

final class LanguageListTests: XCTestCase {
    /// Whisper language list is complete and free of duplicates.
    func testWhisperLanguages() {
        let codes = LanguageList.options.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count, "duplicate language codes")
        XCTAssertGreaterThanOrEqual(codes.count, 100)
        XCTAssertTrue(codes.contains("uk"))
        XCTAssertTrue(codes.contains("ru"))
        XCTAssertTrue(codes.contains("en"))
    }
}

final class ReplacementsTests: XCTestCase {
    /// Plain literal rules: case-insensitive, whole-word only.
    func testLiteralRule() {
        let rules = [["сиквел", "SQL"]]
        XCTAssertEqual(Replacements.process("я знаю Сиквел", rules: rules, fillerLanguage: nil),
                       "я знаю SQL")
        // whole-word: must not fire inside another word
        XCTAssertEqual(Replacements.process("сиквелы", rules: rules, fillerLanguage: nil),
                       "сиквелы")
    }

    /// A single "re:" rule stands in for a swarm of spellings and Russian
    /// case endings that no list of literals could keep pace with.
    func testRegexRuleCoversInflections() {
        let rules = [["re:(?:хо|уо)(?:л{1,2}|у)?\\s*-?\\s*кол{1,2}(?:ом|ами|ах|ов|ей|а|у|е|ы|ю)?",
                      "WholeCall"]]
        for input in ["хоу кол", "холл коллу", "хол-кол", "холлколл", "по холл коллу мы работаем"] {
            XCTAssertTrue(Replacements.process(input, rules: rules, fillerLanguage: nil).contains("WholeCall"),
                          "regex rule should catch \(input)")
        }
    }

    /// Latin spellings collapse to the same brand.
    func testRegexRuleLatin() {
        let rules = [["re:(?:whole|hol{1,2}|hall)\\s*-?\\s*(?:call|kol{1,2}|kow|cow|coll?)", "WholeCall"]]
        for input in ["holkow", "holkol", "whole call", "wholecall", "hall call"] {
            XCTAssertEqual(Replacements.process(input, rules: rules, fillerLanguage: nil), "WholeCall",
                           "regex rule should catch \(input)")
        }
    }
}
