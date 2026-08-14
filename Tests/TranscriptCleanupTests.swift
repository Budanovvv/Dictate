import XCTest

/// The rules that turn fifteen-second audio windows back into a conversation.
///
/// Every one of them is mechanical on purpose: this project removed an LLM
/// polish pass because a model rewrites what was said (CONTEXT 5п, GRABLI), and
/// a transcript is other people's words. So the tests are not "does it read
/// better" — they are "is a word ever changed, is a real short reply ever lost,
/// does a section still find its moment". The numbers in the comments were
/// measured on the owner's own archive (18 transcripts, 1204 entries).
final class TranscriptCleanupTests: XCTestCase {

    private func entry(_ time: String, _ speaker: String, _ text: String,
                       isYou: Bool = false) -> TranscriptEntry {
        TranscriptEntry(time: time, speaker: speaker, text: text, isYou: isYou)
    }

    // MARK: - Re-joining what the 15 s cap cut in half

    /// The signature case, verbatim from 2026-08-11 10:44: a window ends on
    /// "you" with no full stop and the next opens in lower case. One sentence,
    /// one paragraph, the EARLIER timestamp.
    func testCapSplitSentenceIsRejoined() {
        let out = TranscriptCleanup.clean([
            entry("10:44:40", "You", "we build our prototype, you start using it, you"),
            entry("10:44:55", "You", "give me feedback based on this feedback"),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].time, "10:44:40")
        XCTAssertEqual(out[0].text,
                       "we build our prototype, you start using it, you "
                       + "give me feedback based on this feedback")
    }

    /// Nothing is rephrased, recased or repunctuated — a join is one space and
    /// nothing else, so the paragraph is still literally what the file says.
    func testJoiningOnlyEverInsertsASpace() {
        let texts = ["Первая часть без точки", "вторая часть."]
        let out = TranscriptCleanup.clean([
            entry("09:00:00", "Speaker 1", texts[0]),
            entry("09:00:12", "Speaker 1", texts[1]),
        ])
        XCTAssertEqual(out[0].text, texts.joined(separator: " "))
    }

    /// Both signals are required. An unfinished line followed by a CAPITAL is
    /// somebody being interrupted, not a cap-split — it still merges into the
    /// speaker's paragraph, but it is not counted or treated as one sentence.
    func testCapitalNextLineIsNotACapSplit() {
        let report = TranscriptCleanup.cleaning([
            entry("09:00:00", "You", "и вот тогда мы"),
            entry("09:00:12", "You", "Ладно, проехали."),
        ]).report
        XCTAssertEqual(report.merged, 1)
        XCTAssertEqual(report.capSplits, 0)
    }

    func testFinishedSentenceFollowedByLowercaseIsNotACapSplit() {
        let report = TranscriptCleanup.cleaning([
            entry("09:00:00", "You", "Это всё."),
            entry("09:00:12", "You", "и ещё кое-что"),
        ]).report
        XCTAssertEqual(report.capSplits, 0)
    }

    /// A closing quote after the full stop must not read as "no full stop".
    func testAQuotedSentenceStillEndsASentence() {
        XCTAssertTrue(TranscriptCleanup.endsSentence("он сказал «всё готово»."))
        XCTAssertTrue(TranscriptCleanup.endsSentence("he said \"done.\""))
        XCTAssertFalse(TranscriptCleanup.endsSentence("he said \"done\" and then"))
    }

    /// Two entries far apart in time are not one sentence, whatever the
    /// punctuation says: the window cap is 15 s, so a real cap-split is
    /// adjacent. (They still merge into the speaker's paragraph — the window
    /// has always done that — they are simply not COUNTED as a repaired
    /// sentence.)
    func testDistantEntriesAreNotCountedAsACapSplit() {
        let report = TranscriptCleanup.cleaning([
            entry("09:00:00", "You", "и вот тогда мы"),
            entry("09:05:00", "You", "поехали дальше"),
        ]).report
        XCTAssertEqual(report.capSplits, 0)
    }

    /// Different voices are never joined — that is how two people ended up in
    /// one entry before the diarizer cut the windows per speaker, and it is the
    /// one mistake this must not reintroduce.
    func testDifferentSpeakersAreNeverJoined() {
        let out = TranscriptCleanup.clean([
            entry("09:00:00", "You", "и вот тогда мы", isYou: true),
            entry("09:00:12", "Speaker 1", "поехали дальше"),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].speaker, "You")
        XCTAssertEqual(out[1].speaker, "Speaker 1")
    }

    // MARK: - Paragraphs

    func testConsecutiveEntriesOfOneVoiceBecomeOneParagraph() {
        let out = TranscriptCleanup.clean([
            entry("09:17:45", "Speaker 2", "Раз."),
            entry("09:17:52", "Speaker 2", "Два."),
            entry("09:18:01", "Speaker 2", "Три."),
            entry("09:18:05", "You", "Понял.", isYou: true),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "Раз. Два. Три.")
        XCTAssertEqual(out[0].time, "09:17:45")
        XCTAssertEqual(out[1].text, "Понял.")
    }

    /// Everything the file said is still there, in the same order, word for
    /// word. This is the guard against the whole class of failure this project
    /// removed a feature over: the view may re-group words, never change them.
    func testNoWordIsEverChangedOrReordered() {
        let words = { (list: [TranscriptEntry]) in
            list.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        }
        for entries in [Self.sample, Self.longMeeting] {
            // Every word that comes out is a word that went in, spelled the
            // same, in the same order — the cleaned text is a SUBSEQUENCE of
            // the file's. Whole entries may be dropped; a word may never be
            // rewritten, recased, repunctuated or moved.
            let before = words(entries), after = words(TranscriptCleanup.clean(entries))
            var i = before.startIndex
            for word in after {
                while i < before.endIndex, before[i] != word { i = before.index(after: i) }
                XCTAssertLessThan(i, before.endIndex, "\(word) is not in the transcript")
                guard i < before.endIndex else { break }
                i = before.index(after: i)
            }
        }
    }

    /// And each speaker keeps every word that was ever attributed to them —
    /// nothing crosses from one voice into another, which is the failure that
    /// merging paragraphs could in principle introduce.
    func testNoWordCrossesFromOneVoiceToAnother() {
        var expected: [String: String] = [:]
        for e in Self.sample where !TranscriptCleanup.clean([e]).isEmpty {
            expected[e.speaker, default: ""] += " " + e.text
        }
        var actual: [String: String] = [:]
        for e in TranscriptCleanup.clean(Self.sample) {
            actual[e.speaker, default: ""] += " " + e.text
        }
        for (speaker, text) in actual {
            for word in text.split(whereSeparator: \.isWhitespace) {
                XCTAssertTrue(expected[speaker, default: ""].contains(word),
                              "\(speaker) never said \(word)")
            }
        }
    }

    // MARK: - The phantom class

    /// A line with no letter and no digit in it. Real in the archive: "." ×9,
    /// "-" ×3, "..." ×2. There is no word in it to lose, whatever produced it.
    func testPunctuationOnlyEntriesAreDropped() {
        for text in [".", "-", "...", "…", " ! ", "?!"] {
            XCTAssertFalse(TranscriptCleanup.hasContent(text), text)
        }
        let out = TranscriptCleanup.clean([
            entry("09:00:00", "You", "Начали.", isYou: true),
            entry("09:00:09", "Speaker 1", "."),
            entry("09:00:18", "You", "Продолжаем.", isYou: true),
        ])
        XCTAssertEqual(out.count, 1)          // and the two halves closed up
        XCTAssertEqual(out[0].text, "Начали. Продолжаем.")
    }

    /// Whisper's own stage direction for a NON-speech sound: by the model's
    /// account nobody said it.
    func testBracketedAnnotationsAreDropped() {
        for text in ["*scoffs*", "[laughter]", "(music)", "*sniffs*"] {
            XCTAssertTrue(TranscriptCleanup.isAnnotation(text), text)
        }
        // A spoken sentence that merely happens to sit inside brackets is not
        // an annotation, and neither is anything of a real length.
        for text in ["(да, конечно, именно так мы и сделаем)", "*", "()",
                     "Он сказал (тихо): всё."] {
            XCTAssertFalse(TranscriptCleanup.isAnnotation(text), text)
        }
    }

    /// Non-lexical vocalizations: hums, not words. 23 in the archive, of which
    /// "Mm-hmm." is 14.
    func testHumsAreFoldedAway() {
        for text in ["Mm-hmm.", "Mm-hmm", "Mm.", "Uh...", "Um.", "Hmm.", "ah",
                     "uh", "Uh-huh.", "Ага.", "Угу.", "Э-э", "Хм."] {
            XCTAssertTrue(TranscriptCleanup.isBackchannel(text), text)
        }
    }

    /// A hum between two entries of one voice is what "fold into the
    /// surrounding paragraph" means here: it cannot be appended to that
    /// paragraph (it is a different person's sound), so removing it is what
    /// lets the paragraph close over it. Measured: 11 further paragraphs.
    func testAHumDoesNotBreakTheParagraphAroundIt() {
        let out = TranscriptCleanup.clean([
            entry("09:00:00", "You", "Смотри, идея такая.", isYou: true),
            entry("09:00:09", "Speaker 1", "Mm-hmm."),
            entry("09:00:18", "You", "Мы берём и делаем.", isYou: true),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].speaker, "You")
        XCTAssertEqual(out[0].text, "Смотри, идея такая. Мы берём и делаем.")
    }

    /// The line the backchannel rule must NOT cross. These are words: they
    /// assent, they answer a question, and a reader can quote them. Dropping
    /// them would be the phrase blocklist this project rejected twice.
    func testRealShortRepliesSurvive() {
        for text in ["Yes.", "No.", "Okay.", "Yeah.", "Да.", "Нет.", "Спасибо.",
                     "Понятно.", "Ладно.", "Thanks.", "Merci.", "Gracias.",
                     "Thank you.", "42.", "VPN", "では"] {
            XCTAssertFalse(TranscriptCleanup.isBackchannel(text), text)
            XCTAssertFalse(TranscriptCleanup.isOrphanFragment(text), text)
            XCTAssertTrue(TranscriptCleanup.hasContent(text), text)
            XCTAssertEqual(TranscriptCleanup.clean([entry("09:00:00", "Speaker 1", text)]).count,
                           1, text)
        }
    }

    /// A lone lowercase unpunctuated token — the recognizer's residue on a
    /// near-silent window. "you" ×4 in the archive; also "and", "that",
    /// "thanks", "yeah".
    func testOrphanFragmentsAreDropped() {
        for text in ["you", "and", "that", "thanks", "yeah", "blockchain"] {
            XCTAssertTrue(TranscriptCleanup.isOrphanFragment(text), text)
        }
        // Two words is not a stray token; a capital or a full stop means the
        // recognizer rendered an utterance; a caseless script has no signal to
        // read, so it is left alone.
        for text in ["you know", "You", "you.", "Да", "では", "42"] {
            XCTAssertFalse(TranscriptCleanup.isOrphanFragment(text), text)
        }
    }

    /// The guard that makes the rule safe: a fragment that could be the tail of
    /// the sentence right before it — same voice, still mid-sentence, seconds
    /// ago — is kept and joined, not dropped.
    func testALowercaseFragmentOfItsOwnSentenceIsKept() {
        let out = TranscriptCleanup.clean([
            entry("09:00:00", "You", "и потом мы решили что", isYou: true),
            entry("09:00:12", "You", "хватит", isYou: true),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.hasSuffix("хватит"))
    }

    /// …and the same fragment under a FINISHED sentence is continuing nothing.
    /// Verbatim from 2026-08-12 09:45:44 — the recognizer's "Thank you." on a
    /// silent window, and then its tail on the next one.
    func testAFragmentUnderAFinishedSentenceIsDropped() {
        let out = TranscriptCleanup.clean([
            entry("09:45:44", "Them", "Thank you."),
            entry("09:45:50", "Them", "you"),
        ])
        XCTAssertEqual(out.map(\.text), ["Thank you."])
    }

    /// Dropping an orphan can leave one voice on both sides of it — and then
    /// that voice is one paragraph, which is the whole point of the second
    /// merge pass.
    func testAParagraphClosesOverADroppedOrphan() {
        let out = TranscriptCleanup.clean([
            entry("09:45:44", "You", "Ну то есть я в неё верю.", isYou: true),
            entry("09:45:50", "Them", "you"),
            entry("09:45:54", "You", "Я ничего не понимаю.", isYou: true),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Ну то есть я в неё верю. Я ничего не понимаю.")
    }

    // MARK: - A section still finds its moment

    /// THE regression this whole change is one edit away from: the contents
    /// block points at the stamp the FILE carries, and after cleanup that stamp
    /// is usually somewhere in the middle of a paragraph. The paragraph has to
    /// answer for it.
    func testAMergedParagraphAnswersForEveryStampItSwallowed() {
        let out = TranscriptCleanup.clean([
            entry("10:26:04", "Speaker 1", "Значит, по базе."),
            entry("10:26:17", "Speaker 1", "Юрий хочет простую базу для демо."),
            entry("10:26:31", "Speaker 1", "Без всяких сложностей."),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].time, "10:26:04")
        XCTAssertEqual(out[0].covers, ["10:26:04", "10:26:17", "10:26:31"])
        for stamp in ["10:26:04", "10:26:17", "10:26:31"] {
            XCTAssertTrue(out[0].speaks(for: stamp), stamp)
        }
        XCTAssertFalse(out[0].speaks(for: "10:26:18"))
    }

    /// And the same question asked of a turn, which is what the window actually
    /// scrolls to.
    func testATurnAnswersForEveryStampInIt() {
        let turns = MeetingArchive.readable([
            entry("10:00:00", "You", "Начали.", isYou: true),
            entry("10:00:14", "Speaker 1", "Первое."),
            entry("10:00:29", "Speaker 1", "Второе."),
        ])
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns[1].speaks(for: "10:00:29"))
        XCTAssertFalse(turns[0].speaks(for: "10:00:29"))
    }

    /// A meeting cut into sections from the FILE and then read as paragraphs:
    /// every section timestamp must still resolve, and it must resolve to a
    /// place a reader would accept. Measured across the whole archive (25
    /// sections in 18 transcripts): 25 of 25 land, 23 of them exactly on the
    /// paragraph that begins at the section's own stamp, the other two 6 s and
    /// 16 s early.
    func testEverySectionOfARealisticMeetingStillResolves() {
        let entries = Self.longMeeting
        let ranges = MeetingArchive.sectionRanges(of: entries)
        XCTAssertGreaterThanOrEqual(ranges.count, 2)
        let turns = MeetingArchive.readable(entries)
        for range in ranges {
            let stamp = entries[range.lowerBound].time
            guard let landed = MeetingArchive.turn(at: stamp, in: turns) else {
                return XCTFail("section at \(stamp) lands nowhere")
            }
            // Early is the only direction it may err in, and never by more than
            // the paragraph it landed at the top of.
            let want = MeetingArchive.seconds(fromClock: stamp) ?? 0
            let got = MeetingArchive.seconds(fromClock: landed.time) ?? 0
            XCTAssertLessThanOrEqual(got, want, "section at \(stamp) landed late")
            XCTAssertTrue(landed.speaks(for: stamp),
                          "section at \(stamp) landed outside the paragraph that holds it")
        }
    }

    /// The moment lands on the paragraph that swallowed it — not on the
    /// paragraph's own start time, which is the thing that is no longer equal
    /// to it.
    func testAMomentInsideAParagraphResolvesToThatParagraph() {
        let turns = MeetingArchive.readable([
            entry("10:26:04", "Speaker 1", "Значит, по базе."),
            entry("10:26:17", "Speaker 1", "простую базу для демо."),
            entry("10:26:31", "You", "Понял.", isYou: true),
        ])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(MeetingArchive.turn(at: "10:26:17", in: turns)?.time, "10:26:04")
        XCTAssertEqual(MeetingArchive.turn(at: "10:26:31", in: turns)?.time, "10:26:31")
    }

    /// A moment whose entry the cleanup dropped has nothing to speak for it —
    /// the next paragraph takes it, so the jump still moves.
    func testAMomentOnADroppedEntryFallsForwardToTheNextParagraph() {
        let turns = MeetingArchive.readable([
            entry("10:00:00", "You", "Начали.", isYou: true),
            entry("10:00:14", "Them", "."),
            entry("10:00:29", "Speaker 1", "Продолжаем."),
        ])
        XCTAssertEqual(MeetingArchive.turn(at: "10:00:14", in: turns)?.time, "10:00:29")
    }

    func testAMomentAfterTheLastWordLandsNowhereRatherThanWrong() {
        let turns = MeetingArchive.readable([entry("10:00:00", "You", "Всё.", isYou: true)])
        XCTAssertNil(MeetingArchive.turn(at: "23:59:59", in: turns))
        XCTAssertNil(MeetingArchive.turn(at: "not a clock", in: turns))
    }

    // MARK: - Whole-archive shape

    /// The cleanup is idempotent: reading an already-clean transcript changes
    /// nothing. (It has to be — the pane re-derives it on every refresh.)
    func testCleaningTwiceChangesNothing() {
        let once = TranscriptCleanup.clean(Self.sample)
        let twice = TranscriptCleanup.clean(once)
        XCTAssertEqual(once.map(\.text), twice.map(\.text))
        XCTAssertEqual(once.map(\.covers), twice.map(\.covers))
    }

    func testEmptyTranscriptStaysEmpty() {
        XCTAssertTrue(TranscriptCleanup.clean([]).isEmpty)
        XCTAssertEqual(TranscriptCleanup.cleaning([]).report.entriesOut, 0)
    }

    /// The report is what the log and this suite count by, so it has to add up.
    func testTheReportAccountsForEveryEntry() {
        let (out, report) = TranscriptCleanup.cleaning(Self.sample)
        XCTAssertEqual(report.entriesIn, Self.sample.count)
        XCTAssertEqual(report.entriesOut, out.count)
        XCTAssertEqual(report.entriesIn - report.dropped - report.merged, out.count)
        XCTAssertGreaterThan(report.dropped, 0)
        XCTAssertGreaterThan(report.capSplits, 0)
    }

    // MARK: - Fixtures

    /// A short passage carrying one of everything, shaped like the real files.
    private static let sample: [TranscriptEntry] = [
        TranscriptEntry(time: "09:17:45", speaker: "You", text: "*scoffs*", isYou: true),
        TranscriptEntry(time: "09:17:46", speaker: "Speaker 1", text: "Mm-hmm.", isYou: false),
        TranscriptEntry(time: "09:17:49", speaker: "You",
                        text: "У меня сейчас будет к вам обоим интересный вопрос.", isYou: true),
        TranscriptEntry(time: "09:17:56", speaker: "You", text: "Вопрос из серии.", isYou: true),
        TranscriptEntry(time: "09:18:01", speaker: "You",
                        text: "Что же делать с Шеннон?", isYou: true),
        TranscriptEntry(time: "09:18:05", speaker: "Speaker 2",
                        text: "Ты вчера там тоже жаловался.", isYou: false),
        TranscriptEntry(time: "09:18:11", speaker: "You",
                        text: "Ты понимаешь, она... У меня с ней", isYou: true),
        TranscriptEntry(time: "09:18:20", speaker: "You",
                        text: "настало полное взаимопонимание", isYou: true),
        TranscriptEntry(time: "09:18:25", speaker: "Them", text: ".", isYou: false),
        TranscriptEntry(time: "09:18:29", speaker: "You",
                        text: "После того, как я понял.", isYou: true),
        TranscriptEntry(time: "09:18:38", speaker: "Them", text: "you", isYou: false),
        TranscriptEntry(time: "09:18:45", speaker: "Speaker 1", text: "Да.", isYou: false),
    ]

    /// Long enough for the section rule to cut it into pieces — the same shape
    /// a real meeting has: alternating voices, 6–15 s windows, sentences the
    /// cap chopped in half every few lines.
    private static let longMeeting: [TranscriptEntry] = {
        var entries: [TranscriptEntry] = []
        var clock = 10 * 3600
        for i in 0..<180 {
            let speaker = i % 3 == 0 ? "You" : "Speaker \(i % 3)"
            let text: String
            switch i % 5 {
            case 0: text = "Сначала надо понять, что именно мы показываем на демо."
            case 1: text = "и потом уже решать, что с этим делать дальше"
            case 2: text = "Хорошо, давай так и сделаем, я всё запишу."
            case 3: text = "Тогда остаётся вопрос по срокам, потому что мы"
            default: text = "не успеваем закрыть всё до пятницы."
            }
            entries.append(TranscriptEntry(time: String(format: "%02d:%02d:%02d",
                                                        clock / 3600, (clock / 60) % 60, clock % 60),
                                           speaker: speaker, text: text, isYou: speaker == "You"))
            clock += 8 + i % 8
        }
        return entries
    }()
}
