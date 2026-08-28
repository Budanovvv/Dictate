import XCTest

final class AnswerSupportPolicyTests: XCTestCase {

    private func supportedSentences(_ answer: String, quotes: [String]) -> [String] {
        AnswerSupportPolicy.supportedRanges(in: answer, quotes: quotes)
            .map { String(answer[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func testSentenceBuiltFromAQuoteIsSupported() {
        let quote = "I'll take German and Japanese myself, and I'll flag anything that overflows the settings labels."
        let answer = "She will flag anything that overflows the settings labels. She also promised a cake soon."
        let supported = supportedSentences(answer, quotes: [quote])
        XCTAssertEqual(supported.count, 1)
        XCTAssertTrue(supported[0].hasPrefix("She will flag"))
    }

    func testLooseParaphraseIsNotMarked() {
        // Under-marking is the safe failure: a reworded claim ("took … review
        // herself") shares only a few words with the quote and must not
        // borrow its trust.
        let quote = "I'll take German and Japanese myself, and I'll flag anything that overflows the settings labels."
        let supported = supportedSentences("Priya took the German and Japanese review herself.",
                                           quotes: [quote])
        XCTAssertTrue(supported.isEmpty)
    }

    func testInventedSentenceIsNotSupported() {
        let supported = supportedSentences(
            "The committee unanimously approved the quarterly budget expansion.",
            quotes: ["Let's ship it as one file that can resume."])
        XCTAssertTrue(supported.isEmpty)
    }

    func testNoQuotesMeansNothingMarked() {
        XCTAssertTrue(AnswerSupportPolicy.supportedRanges(
            in: "Anything at all.", quotes: []).isEmpty)
    }

    func testShortSentencesAreNeverJudged() {
        // Two content words match half the archive — must not earn a mark.
        let supported = supportedSentences("The release moved.",
                                           quotes: ["The release moved to the fourteenth."])
        XCTAssertTrue(supported.isEmpty)
    }

    func testSupportIsPerQuoteNotAcrossThePool() {
        // Half the words in one quote, half in another: pooled matching would
        // mark it; per-quote matching must not.
        let answer = "The resumable download ships with the Accessibility permission copy tonight."
        let supported = supportedSentences(answer, quotes: [
            "The resumable download ships this week.",
            "The Accessibility permission copy is due tonight.",
        ])
        XCTAssertTrue(supported.isEmpty)
    }

    func testCyrillicContentWorks() {
        let quote = "Перенесём релиз на четырнадцатое и скажем бета-группе сегодня вечером."
        let answer = "Релиз перенесём на четырнадцатое, бета-группе скажем вечером. Кроме того, наступит зима."
        let supported = supportedSentences(answer, quotes: [quote])
        XCTAssertEqual(supported.count, 1)
        XCTAssertTrue(supported[0].hasPrefix("Релиз"))
    }
}
