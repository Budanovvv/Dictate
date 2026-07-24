import XCTest

/// LocalAgreement-2 over sequences of hypotheses: what may be typed into a
/// foreign document, and what must wait. Every expectation here is also a
/// promise that nothing already typed is ever taken back.
///
/// The rule the numbers follow: two consecutive hypotheses agree on a prefix,
/// and that prefix MINUS ITS LAST WORD (the one-word seam) is committed.
final class CommitEngineTests: XCTestCase {
    private func engine(_ phrases: [String] = []) -> CommitEngine {
        CommitEngine(holdBackPhrases: phrases)
    }

    // MARK: - Basic agreement

    func testWordsCommitOnSecondAgreementMinusTheSeam() {
        let e = engine()
        // First hypothesis has nothing to agree with
        XCTAssertEqual(e.ingest(hypothesis: "мама мыла раму"),
                       CommitEngine.Update(newlyCommitted: "", volatileTail: "мама мыла раму"))
        // Three words agree, the last of them is the seam → two go out
        XCTAssertEqual(e.ingest(hypothesis: "мама мыла раму хорошо"),
                       CommitEngine.Update(newlyCommitted: "мама мыла", volatileTail: "раму хорошо"))
        XCTAssertEqual(e.committedText, "мама мыла")
        // …and every later commit brings its own separator
        XCTAssertEqual(e.ingest(hypothesis: "мама мыла раму хорошо очень").newlyCommitted, " раму")
        XCTAssertEqual(e.committedText, "мама мыла раму")
    }

    func testUnstableTailIsNeverCommitted() {
        let e = engine()
        e.ingest(hypothesis: "привет как дела")
        // The tail was rewritten: only "привет как" agree, and the seam holds
        // the boundary word back
        XCTAssertEqual(e.ingest(hypothesis: "привет как жизнь").newlyCommitted, "привет")
        XCTAssertEqual(e.ingest(hypothesis: "привет как жизнь идёт").newlyCommitted, " как")
        XCTAssertEqual(e.committedText, "привет как")
        // The word only one pass ever heard never reached the document
        XCTAssertFalse(e.committedText.contains("дела"))
    }

    func testAlreadyCommittedWordsAreNeverTypedTwice() {
        let e = engine()
        e.ingest(hypothesis: "один два три")
        e.ingest(hypothesis: "один два три четыре")
        XCTAssertEqual(e.committedText, "один два")
        e.ingest(hypothesis: "один два три четыре пять")
        XCTAssertEqual(e.committedText, "один два три")
        // The whole buffer comes back every tick: the repeat is a second
        // agreeing pass, so exactly one more word moves and nothing repeats
        XCTAssertEqual(e.ingest(hypothesis: "один два три четыре пять").newlyCommitted, " четыре")
        XCTAssertEqual(e.committedText, "один два три четыре")
    }

    func testRepeatedWordsAreComparedByPositionNotByValue() {
        let e = engine()
        e.ingest(hypothesis: "мама мыла раму раму")
        XCTAssertEqual(e.ingest(hypothesis: "мама мыла раму раму раму").newlyCommitted,
                       "мама мыла раму")
        XCTAssertEqual(e.ingest(hypothesis: "мама мыла раму раму раму раму").newlyCommitted, " раму")
        // The tail still carries every repetition — none of them collapsed
        XCTAssertEqual(e.forceCommit().newlyCommitted, " раму раму")
        XCTAssertEqual(e.committedText, "мама мыла раму раму раму раму")
    }

    func testPunctuationAndCaseFlickerStillAgrees() {
        let e = engine()
        e.ingest(hypothesis: "привет, мир как дела")
        // Same words, different case and commas — agreement holds, and what
        // gets typed is the form from the freshest hypothesis
        XCTAssertEqual(e.ingest(hypothesis: "Привет мир, как дела").newlyCommitted, "Привет мир, как")
    }

    func testEmptyHypothesisKeepsTheAgreementState() {
        let e = engine()
        e.ingest(hypothesis: "привет как дела")
        let update = e.ingest(hypothesis: "   ")
        XCTAssertEqual(update.newlyCommitted, "")
        XCTAssertEqual(update.volatileTail, "привет как дела")
        // The empty tick was not evidence — the next hypothesis still agrees
        XCTAssertEqual(e.ingest(hypothesis: "привет как дела ещё").newlyCommitted, "привет как")
    }

    // MARK: - Silence

    func testForceCommitFlushesSeamAndTail() {
        let e = engine()
        e.ingest(hypothesis: "мама мыла раму")
        e.ingest(hypothesis: "мама мыла раму хорошо")
        XCTAssertEqual(e.committedText, "мама мыла")
        XCTAssertEqual(e.forceCommit(),
                       CommitEngine.Update(newlyCommitted: " раму хорошо", volatileTail: ""))
        XCTAssertEqual(e.committedText, "мама мыла раму хорошо")
    }

    func testForceCommitOnEmptyTailIsSilent() {
        let e = engine()
        XCTAssertEqual(e.forceCommit(),
                       CommitEngine.Update(newlyCommitted: "", volatileTail: ""))
        XCTAssertEqual(e.committedText, "")
    }

    func testHypothesisAfterForceCommitDoesNotRetype() {
        let e = engine()
        e.ingest(hypothesis: "мама мыла раму")
        e.forceCommit()
        XCTAssertEqual(e.ingest(hypothesis: "мама мыла раму хорошо").newlyCommitted, "")
        XCTAssertEqual(e.committedText, "мама мыла раму")
    }

    func testTrimmedBufferIsNotTypedAgain() {
        let e = engine()
        e.ingest(hypothesis: "один два три")
        e.ingest(hypothesis: "один два три четыре")
        XCTAssertEqual(e.committedText, "один два")
        // The caller trimmed the audio behind the committed words: the
        // hypothesis now starts where "один два" ended
        e.ingest(hypothesis: "три четыре пять")
        XCTAssertEqual(e.committedText, "один два три")
        XCTAssertEqual(e.ingest(hypothesis: "три четыре пять шесть").newlyCommitted, " четыре")
        XCTAssertEqual(e.committedText, "один два три четыре")
    }

    // MARK: - Hold-back of command / replacement phrases

    /// Dictates "пиши" plus the opening word of the command: leaves the engine
    /// with "пиши" committed and the phrase held back.
    private func upToHeldPhrase(_ e: CommitEngine) {
        e.ingest(hypothesis: "пиши с")
        XCTAssertEqual(e.ingest(hypothesis: "пиши с новой").newlyCommitted, "пиши")
        XCTAssertEqual(e.ingest(hypothesis: "пиши с новой строки").newlyCommitted, "")
    }

    func testPartiallySpokenCommandIsHeldBack() {
        let e = engine(["с новой строки"])
        upToHeldPhrase(e)
        // "с" is confirmed, but it may still grow into the command — holding it
        // is the only way the caller's Replacements pass can ever see the whole
        // phrase in one chunk
        let update = e.ingest(hypothesis: "пиши с новой строки текст")
        XCTAssertEqual(update.newlyCommitted, "")
        XCTAssertEqual(update.volatileTail, "с новой строки текст")
        XCTAssertEqual(e.committedText, "пиши")
        // …and a completed phrase keeps waiting too, so it never leaks literally
        XCTAssertEqual(e.ingest(hypothesis: "пиши с новой строки текст дальше").newlyCommitted, "")
        XCTAssertEqual(e.committedText, "пиши")
    }

    func testHeldPhraseLeavesAsOneChunkOnceItIsOver() {
        let e = engine(["с новой строки"])
        upToHeldPhrase(e)
        e.ingest(hypothesis: "пиши с новой строки текст")
        e.ingest(hypothesis: "пиши с новой строки текст дальше")
        // The word after the phrase proves it is finished: everything held goes
        // out together, so Replacements sees "с новой строки" intact
        XCTAssertEqual(e.ingest(hypothesis: "пиши с новой строки текст дальше ещё").newlyCommitted,
                       " с новой строки текст")
    }

    func testDivergingPhraseIsReleasedImmediately() {
        let e = engine(["с новой строки"])
        e.ingest(hypothesis: "пиши с")
        XCTAssertEqual(e.ingest(hypothesis: "пиши с самолётом").newlyCommitted, "пиши")
        // "с самолётом" can never become the command — no reason to hold "с"
        XCTAssertEqual(e.ingest(hypothesis: "пиши с самолётом дальше").newlyCommitted, " с")
    }

    func testForceCommitReleasesAHeldPhrase() {
        let e = engine(["с новой строки"])
        upToHeldPhrase(e)
        e.ingest(hypothesis: "пиши с новой строки текст")
        // Half a second of silence in the middle of a phrase means it was not a
        // command, just words
        XCTAssertEqual(e.forceCommit().newlyCommitted, " с новой строки текст")
        XCTAssertEqual(e.committedText, "пиши с новой строки текст")
    }

    func testSingleWordReplacementIsHeldUntilItHasCompany() {
        let e = engine(["сиквел"])
        e.ingest(hypothesis: "готовь сиквел")
        XCTAssertEqual(e.ingest(hypothesis: "готовь сиквел запрос").newlyCommitted, "готовь")
        // "сиквел" alone would be typed literally before Replacements could
        // turn it into SQL — it waits for the word that ends it
        XCTAssertEqual(e.ingest(hypothesis: "готовь сиквел запрос сейчас").newlyCommitted, "")
        XCTAssertEqual(e.ingest(hypothesis: "готовь сиквел запрос сейчас же").newlyCommitted,
                       " сиквел запрос")
    }

    func testPhrasesAreMatchedCaseAndPunctuationInsensitively() {
        let e = engine(["С Новой Строки"])
        e.ingest(hypothesis: "пиши с,")
        XCTAssertEqual(e.ingest(hypothesis: "пиши с, новой").newlyCommitted, "пиши")
        XCTAssertEqual(e.ingest(hypothesis: "пиши с, новой строки").newlyCommitted, "")
    }

    // MARK: - Final reconciliation

    func testFinishAppendsOnlyTheSuffix() {
        let e = engine()
        e.ingest(hypothesis: "мама мыла раму")
        e.ingest(hypothesis: "мама мыла раму хорошо")
        e.ingest(hypothesis: "мама мыла раму хорошо очень")
        XCTAssertEqual(e.committedText, "мама мыла раму")
        XCTAssertEqual(e.finish(finalText: "Мама мыла раму хорошо очень"), " хорошо очень")
        XCTAssertEqual(e.committedText, "мама мыла раму хорошо очень")
    }

    func testFinishIsIdempotent() {
        let e = engine()
        e.ingest(hypothesis: "мама мыла раму")
        e.forceCommit()
        XCTAssertEqual(e.finish(finalText: "мама мыла раму, хорошо"), ", хорошо")
        XCTAssertEqual(e.finish(finalText: "мама мыла раму, хорошо"), "")
    }

    func testFinishTypesPunctuationOnlyTheFullPassHeard() {
        let e = engine()
        e.ingest(hypothesis: "привет мир")
        e.forceCommit()
        XCTAssertEqual(e.committedText, "привет мир")
        XCTAssertEqual(e.finish(finalText: "Привет, мир."), ".")
        XCTAssertEqual(e.committedText, "привет мир.")
        // and it is not typed a second time
        XCTAssertEqual(e.finish(finalText: "Привет, мир."), "")
    }

    func testFinishNeverFixesADivergentPast() {
        let e = engine()
        e.ingest(hypothesis: "мама мыла раму")
        e.ingest(hypothesis: "мама мыла раму хорошо")
        XCTAssertEqual(e.committedText, "мама мыла")
        // The full pass heard "мыло": the typed word stays wrong, we only add
        // what comes after it — no backspaces, ever
        XCTAssertEqual(e.finish(finalText: "мама мыло раму хорошо"), " раму хорошо")
        XCTAssertEqual(e.committedText, "мама мыла раму хорошо")
    }

    func testFinishWithAShorterFinalPassAddsNothing() {
        let e = engine()
        e.ingest(hypothesis: "мама мыла раму")
        e.forceCommit()
        XCTAssertEqual(e.finish(finalText: "мама"), "")
        XCTAssertEqual(e.finish(finalText: ""), "")
        XCTAssertEqual(e.committedText, "мама мыла раму")
    }

    func testFinishWithNothingCommittedReturnsEverything() {
        let e = engine()
        XCTAssertEqual(e.finish(finalText: "привет мир"), "привет мир")
        XCTAssertEqual(e.committedText, "привет мир")
    }

    func testFinishKeepsLineBreaksFromTheFullPass() {
        let e = engine()
        e.ingest(hypothesis: "первая")
        e.forceCommit()
        // The command became a real line break in the full pass — the suffix
        // must carry it (this is the path that recovers what live typing drops)
        XCTAssertEqual(e.finish(finalText: "первая\nвторая"), "\nвторая")
    }

    func testFinishAnchorsOnTheNearestRepetition() {
        let e = engine()
        e.ingest(hypothesis: "раму раму раму")
        e.forceCommit()
        XCTAssertEqual(e.committedText, "раму раму раму")
        // Three typed, four in the final text — exactly one more must be typed
        XCTAssertEqual(e.finish(finalText: "раму раму раму раму"), " раму")
    }

    func testFinishAfterHeldPhraseAddsTheReplacementResult() {
        let e = engine(["с новой строки"])
        upToHeldPhrase(e)
        e.ingest(hypothesis: "пиши с новой строки текст")
        XCTAssertEqual(e.committedText, "пиши")
        // The full pass has already turned the command into a break; nothing of
        // the phrase was typed, so the whole rest still is
        XCTAssertEqual(e.finish(finalText: "Пиши\nтекст"), "\nтекст")
    }

    // MARK: - Separators

    func testFirstCommitHasNoLeadingSpaceAndLaterOnesDo() {
        let e = engine()
        e.ingest(hypothesis: "раз два три")
        let first = e.forceCommit().newlyCommitted
        XCTAssertEqual(first, "раз два три")
        XCTAssertFalse(first.hasPrefix(" "))
        e.ingest(hypothesis: "раз два три четыре пять")
        XCTAssertEqual(e.forceCommit().newlyCommitted, " четыре пять")
        XCTAssertEqual(e.committedText, "раз два три четыре пять")
    }

    func testTokenizerNormalization() {
        XCTAssertEqual(CommitEngine.normalize("«Привет»,"), "привет")
        XCTAssertEqual(CommitEngine.normalize("don’t"), "don't")
        XCTAssertEqual(CommitEngine.tokenize("  раз  два\nтри ").map(\.raw), ["раз", "два", "три"])
    }
}
