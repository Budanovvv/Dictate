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

    /// Regression: a two-character punctuation output ("?!") used to get the
    /// sentinel mark, and the tidy sweep then ate its own second character
    /// ("?!" → "?"). Only single marks are sentinel-protected now.
    func testTwoCharPunctuationOutputSurvivesTidy() {
        let rules = [["вопрос-восклицание", "?!"]]
        XCTAssertEqual(Replacements.apply(to: "ну вопрос-восклицание", rules: rules), "ну?!")
    }

    /// An invalid "re:" pattern must be skipped without crashing or touching
    /// the text (and the settings footer warns about it separately).
    func testInvalidRegexRuleIsSkipped() {
        let rules = [["re:([", "X"]]
        XCTAssertEqual(Replacements.apply(to: "просто текст", rules: rules), "просто текст")
    }

    /// Same-length overlapping rules apply in a deterministic order (tie broken
    /// by the phrase), so results can't differ from run to run.
    func testSameLengthRulesAreDeterministic() {
        let rules = [["ab cd", "X"], ["cd ef", "Y"]]
        for _ in 0..<5 {
            XCTAssertEqual(Replacements.apply(to: "ab cd ef", rules: rules), "X ef")
        }
    }
}

final class TrimSilenceTests: XCTestCase {
    private let window = 1600   // 0.1 s at 16 kHz, same as production

    /// Build a signal from per-window amplitudes and its per-window RMS.
    private func signal(_ amps: [Double]) -> (floats: [Float], energies: [Double]) {
        var floats: [Float] = []
        for a in amps { floats.append(contentsOf: [Float](repeating: Float(a), count: window)) }
        return (floats, amps)
    }

    func testTrimsLeadingAndTrailingSilenceKeepingMargin() {
        // 6 silent windows, 4 voiced, 6 silent → keep voiced ± 2-window margin.
        let (floats, energies) = signal([0.001, 0.001, 0.001, 0.001, 0.001, 0.001,
                                         0.5, 0.5, 0.5, 0.5,
                                         0.001, 0.001, 0.001, 0.001, 0.001, 0.001])
        let out = AudioRecorder.trimSilence(floats, energies: energies, window: window, p90: 0.5)
        XCTAssertEqual(out.count, (4 + 2 + 2) * window)
    }

    func testNoClearSilenceReturnsUnchanged() {
        let (floats, energies) = signal([0.4, 0.5, 0.45, 0.5, 0.4, 0.5])
        let out = AudioRecorder.trimSilence(floats, energies: energies, window: window, p90: 0.5)
        XCTAssertEqual(out.count, floats.count)
    }

    func testAllSilenceReturnsUnchanged() {
        // Nothing voiced at all — nothing to anchor a cut, return as-is.
        let (floats, energies) = signal([0.0, 0.0, 0.0, 0.0, 0.0])
        let out = AudioRecorder.trimSilence(floats, energies: energies, window: window, p90: 0)
        XCTAssertEqual(out.count, floats.count)
    }

    func testShortRecordingUntouched() {
        let floats = [Float](repeating: 0, count: window * 2)   // below the 4-window minimum
        let out = AudioRecorder.trimSilence(floats, energies: [0, 0], window: window, p90: 0.5)
        XCTAssertEqual(out.count, floats.count)
    }
}
