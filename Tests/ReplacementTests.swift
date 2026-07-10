import XCTest

final class ReplacementTests: XCTestCase {
    func testUserRuleWholeWordCaseInsensitive() {
        let rules = [["сиквел", "SQL"]]
        XCTAssertEqual(Replacements.apply(to: "Сиквел запрос готов", rules: rules), "SQL запрос готов")
        // no replacement inside a longer word
        XCTAssertEqual(Replacements.apply(to: "сиквелчик", rules: rules), "сиквелчик")
    }

    func testNewLineSwallowsDanglingPunctuation() {
        // Whisper often wraps the spoken command in punctuation
        XCTAssertEqual(Replacements.apply(to: "первая. С новой строки, вторая", rules: []),
                       "первая.\nвторая")
    }

    func testMarksAttachToWords() {
        XCTAssertEqual(Replacements.apply(to: "ура восклицательный знак", rules: []), "ура!")
        XCTAssertEqual(Replacements.apply(to: "really question mark", rules: []), "really?")
    }

    func testCommandMarkBeatsWhisperPunctuation() {
        // Whisper hears a sentence end and dots both sides of the command
        XCTAssertEqual(Replacements.apply(to: "Первый знак. Восклицательный знак.", rules: []),
                       "Первый знак!")
        XCTAssertEqual(Replacements.apply(to: "Вопрос есть. Вопросительный знак. Дальше текст", rules: []),
                       "Вопрос есть? Дальше текст")
        XCTAssertEqual(Replacements.apply(to: "Список. Двоеточие. Раз", rules: []),
                       "Список: Раз")
    }

    func testDroppedCommandsStayPlainText() {
        // "запятая" и "точка" — не команды: Whisper ставит их сам, а слова
        // слишком обиходны для замены
        XCTAssertEqual(Replacements.apply(to: "поставь запятая и точка тут", rules: []),
                       "поставь запятая и точка тут")
    }

    func testCJKWithoutWordBoundaries() {
        XCTAssertEqual(Replacements.apply(to: "你好感叹号", rules: []), "你好！")
    }

    func testUserRuleOverridesBuiltIn() {
        let rules = [["с новой строки", " | "]]
        XCTAssertEqual(Replacements.apply(to: "раз с новой строки два", rules: rules), "раз | два")
    }

    func testFillerRemovalLanguageScoped() {
        // ru fillers removed with their trailing commas, sentence intact
        XCTAssertEqual(Replacements.process("Я, э-э, думаю, что, эм, готово",
                                            rules: [], fillerLanguage: "ru"),
                       "Я, думаю, что, готово")
        // "um" is a German preposition — untouched unless the language is en
        XCTAssertEqual(Replacements.process("Ich bitte um Antwort",
                                            rules: [], fillerLanguage: "de"),
                       "Ich bitte um Antwort")
        XCTAssertEqual(Replacements.process("So, um, I think",
                                            rules: [], fillerLanguage: "en"),
                       "So, I think")
        // filler inside a longer word never matches
        XCTAssertEqual(Replacements.process("эмоции важны", rules: [], fillerLanguage: "ru"),
                       "эмоции важны")
        // nil language → no cleanup at all
        XCTAssertEqual(Replacements.process("э-э тест", rules: [], fillerLanguage: nil),
                       "э-э тест")
    }

    func testEmptyAndMalformedRulesIgnored() {
        let rules: [[String]] = [["", "X"], ["один"], []]
        XCTAssertEqual(Replacements.apply(to: "текст один два", rules: rules), "текст один два")
    }
}
