import XCTest

/// The polish model must EDIT, never TRANSLATE: a Russian dictation that came
/// back in English has to be rejected so the raw text is inserted instead
/// (this happened live on 2026-07-25 — three dictations in a row).
final class PolishGuardTests: XCTestCase {

    func testRussianTranslatedToEnglishIsFlagged() {
        XCTAssertTrue(PolishGuard.scriptFlipped(
            from: "Окей, я только что удалил этот текст и передиктовал его заново.",
            to: "Okay, I just deleted this text and redictated it anew."))
    }

    func testRussianEditedInPlaceIsAccepted() {
        XCTAssertFalse(PolishGuard.scriptFlipped(
            from: "Ну, я думаю, что нам надо, э-э, надо перенести встречу.",
            to: "Я думаю, нам надо перенести встречу."))
    }

    func testEnglishStaysEnglish() {
        XCTAssertFalse(PolishGuard.scriptFlipped(
            from: "so basically we should, um, move the meeting to Thursday",
            to: "We should move the meeting to Thursday."))
    }

    /// Latin technical terms inside Russian speech must not weaken the guard.
    func testMixedRussianWithLatinTermsStillFlagged() {
        XCTAssertTrue(PolishGuard.scriptFlipped(
            from: "Там в настройках AI polish включён, модель qwen скачана, но что-то не так.",
            to: "The AI polish setting is on and the qwen model is downloaded, but something is off."))
    }

    /// Vietnamese is Latin-script with heavy diacritics — never "non-Latin".
    func testVietnameseIsNotMistakenForNonLatin() {
        XCTAssertFalse(PolishGuard.scriptFlipped(
            from: "Chúng ta nên dời cuộc họp sang thứ Năm nhé.",
            to: "Chúng ta nên dời cuộc họp sang thứ Năm."))
    }

    func testChineseTranslatedToEnglishIsFlagged() {
        XCTAssertTrue(PolishGuard.scriptFlipped(
            from: "我们把会议改到星期四吧,星期五我没有时间。",
            to: "Let's move the meeting to Thursday; I have no time on Friday."))
    }

    func testEmptyStringsAreAccepted() {
        XCTAssertFalse(PolishGuard.scriptFlipped(from: "", to: ""))
    }
}
