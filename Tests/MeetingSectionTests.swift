import XCTest

/// Cutting a finished meeting into sections, and keeping the result in the
/// user's own Markdown file without breaking anything already in it.
///
/// The cut rule is pure and lives in MeetingPolicy, so everything here is
/// fixed numbers rather than a transcript — the point of putting it there was
/// that "where does a section start" can be argued about in a test instead of
/// by staring at a fifty-minute call.
final class MeetingSectionTests: XCTestCase {

    // MARK: - Fixtures

    private func mark(_ start: Double, _ speaker: String = "A", words: Int = 20,
                      ends: Bool = false, starts: Bool = false) -> MeetingPolicy.SectionMark {
        MeetingPolicy.SectionMark(start: start, speaker: speaker, words: words,
                                  endsSentence: ends, startsSentence: starts)
    }

    /// A meeting of `minutes` minutes with an entry every 8 seconds — the
    /// cadence a real transcript actually has (windows are cut at pauses or at
    /// the 15 s cap, and the median gap across the owner's archive is 5–9 s).
    private func meeting(minutes: Double, every: Double = 8) -> [MeetingPolicy.SectionMark] {
        stride(from: 0.0, to: minutes * 60, by: every).map { mark($0) }
    }

    private func entry(_ time: String, _ speaker: String = "A", _ text: String = "hello there")
        -> TranscriptEntry {
        TranscriptEntry(time: time, speaker: speaker, text: text, isYou: false)
    }

    // MARK: - When a meeting is sectioned at all

    /// One section is the meeting's own summary written a second time. A
    /// meeting too short for two gets none, and the contents block never
    /// appears in its file.
    func testTooShortForTwoSectionsGetsNone() {
        XCTAssertTrue(MeetingPolicy.sectionStarts(meeting(minutes: 3)).isEmpty)
        XCTAssertTrue(MeetingPolicy.sectionStarts(meeting(minutes: 4.9)).isEmpty)
        XCTAssertTrue(MeetingPolicy.sectionStarts([]).isEmpty)
        XCTAssertTrue(MeetingPolicy.sectionStarts([mark(0)]).isEmpty)
    }

    /// The first section always starts at the first entry — nothing of the
    /// meeting is left outside the contents.
    func testFirstSectionStartsAtTheBeginning() {
        XCTAssertEqual(MeetingPolicy.sectionStarts(meeting(minutes: 20)).first, 0)
    }

    /// The shape the owner asked for: 8–12 lines for a meeting of an hour,
    /// not one and not fifty.
    func testAnHourLongMeetingGetsAboutADozenSections() {
        let starts = MeetingPolicy.sectionStarts(meeting(minutes: 51))
        XCTAssertGreaterThanOrEqual(starts.count, 8)
        XCTAssertLessThanOrEqual(starts.count, 14)
    }

    /// Every section is inside the admissible range, and the sections
    /// partition the meeting — no gaps, no overlap, nothing dropped.
    func testSectionsPartitionTheMeetingWithinTheBudget() {
        let marks = meeting(minutes: 51)
        let starts = MeetingPolicy.sectionStarts(marks)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertEqual(Set(starts).count, starts.count)
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? marks[starts[i + 1]].start : marks[marks.count - 1].start
            let length = end - marks[start].start
            XCTAssertGreaterThanOrEqual(length, MeetingPolicy.sectionMinimum * 0.6)
            XCTAssertLessThanOrEqual(length, MeetingPolicy.sectionMaximum)
        }
    }

    // MARK: - Which candidate wins

    /// The budget decides WHICH entries may end a section; the text signals
    /// decide which of those it is. Here two candidates are equally far from
    /// the target and only one of them is a seam.
    func testASeamWinsAmongEquallyGoodLengths() {
        var marks = meeting(minutes: 20)
        let early = Int(210 / 8), late = Int(270 / 8)   // 30 s either side of target
        marks[early] = mark(marks[early].start, "A")
        marks[late - 1] = mark(marks[late - 1].start, "A", ends: true)
        marks[late] = mark(marks[late].start, "B", starts: true)
        XCTAssertEqual(MeetingPolicy.sectionStarts(marks)[1], late)
    }

    /// …and a seam cannot drag a section outside the budget. A perfect seam
    /// one minute in is still one minute in.
    func testAPerfectSeamTooEarlyIsIgnored() {
        var marks = meeting(minutes: 20)
        let tooEarly = Int(60 / 8)
        marks[tooEarly - 1] = mark(marks[tooEarly - 1].start, "A", ends: true)
        marks[tooEarly] = mark(marks[tooEarly].start, "B", starts: true)
        let cut = MeetingPolicy.sectionStarts(marks)[1]
        XCTAssertGreaterThanOrEqual(marks[cut].start, MeetingPolicy.sectionMinimum)
    }

    /// The signal that earned its place: without it most sections opened
    /// mid-sentence. A candidate whose text begins with a capital beats an
    /// otherwise identical one that does not.
    func testACapitalStartBeatsAMidSentenceStart() {
        var marks = meeting(minutes: 20)
        let a = Int(232 / 8), b = Int(248 / 8)          // both within 8 s of target
        marks[a] = mark(marks[a].start, "A", starts: false)
        marks[b] = mark(marks[b].start, "A", starts: true)
        XCTAssertEqual(MeetingPolicy.sectionStarts(marks)[1], b)
    }

    /// A stub at the end is not a section. When what is left after a cut has
    /// nothing to say, the cut is not made and the tail joins the section
    /// before it.
    func testNoStubSectionAtTheEnd() {
        let marks = meeting(minutes: 9)
        let starts = MeetingPolicy.sectionStarts(marks)
        let last = marks[marks.count - 1].start - marks[starts[starts.count - 1]].start
        XCTAssertGreaterThanOrEqual(last, MeetingPolicy.sectionMinimum * 0.6)
    }

    // MARK: - From entries to ranges

    func testSectionRangesCoverEveryEntryInOrder() {
        let entries = (0..<400).map { i -> TranscriptEntry in
            let t = 36000 + i * 8
            return entry(String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60))
        }
        let ranges = MeetingArchive.sectionRanges(of: entries)
        XCTAssertGreaterThanOrEqual(ranges.count, 8)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, entries.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound)
        }
    }

    func testAShortMeetingHasNoRanges() {
        let entries = (0..<10).map { entry(String(format: "10:00:%02d", $0 * 10)) }
        XCTAssertTrue(MeetingArchive.sectionRanges(of: entries).isEmpty)
    }

    // MARK: - The contents block in the file

    private let named = """
        # Release planning
        _August 10, 2026 at 9:17 AM_

        2.4 slipped a week — notarization still fails on the CI box

        **[09:17:52] You:** Let's start.
        **[09:20:11] Ruslan:** The notary rejects get-task-allow.
        **[09:24:03] You:** Then we strip it.
        """

    private let sections = [
        TranscriptSection(time: "09:17:52", line: "Opening the release call"),
        TranscriptSection(time: "09:20:11", line: "Notarization rejects get-task-allow"),
    ]

    /// The claim the whole storage decision rests on, proven rather than
    /// argued: writing the block changes nothing about the transcript the
    /// parser reads back — not the entries, not the title, not the summary.
    func testContentsBlockSurvivesARoundTripAndChangesNothingElse() {
        // Compared on what an entry SAYS, not on its identity: ids are freshly
        // minted by each parse and are not part of the transcript.
        func said(_ entries: [TranscriptEntry]) -> [String] {
            entries.map { "\($0.time)|\($0.speaker)|\($0.isYou)|\($0.text)" }
        }
        let before = said(MeetingArchive.parse(markdown: named))
        let written = MeetingArchive.applying(sections: sections, heading: "Contents", to: named)
        XCTAssertEqual(MeetingArchive.parseSections(markdown: written), sections)
        XCTAssertEqual(said(MeetingArchive.parse(markdown: written)), before)
        XCTAssertEqual(MeetingArchive.parseTitle(markdown: written), "Release planning")
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: written),
                       "2.4 slipped a week — notarization still fails on the CI box")
    }

    /// The block goes under everything that describes the meeting as a whole
    /// and above the first thing anybody said — where a reader opening the
    /// file in any Markdown app expects a table of contents.
    func testContentsBlockSitsBetweenTheSummaryAndTheFirstEntry() {
        let written = MeetingArchive.applying(sections: sections, heading: "Contents", to: named)
        let lines = written.components(separatedBy: .newlines)
        let heading = lines.firstIndex { $0.hasPrefix("## ") }
        let summary = lines.firstIndex { $0.hasPrefix("2.4 slipped") }
        let firstEntry = lines.firstIndex { $0.hasPrefix("**[") }
        XCTAssertNotNil(heading)
        XCTAssertLessThan(summary!, heading!)
        XCTAssertLessThan(heading!, firstEntry!)
    }

    /// A meeting that never got a summary still gets a contents block, and a
    /// summary arriving afterwards still finds its place above it.
    func testSummaryAndContentsDoNotFightOverTheSameLine() {
        let bare = """
            # Release planning
            _August 10, 2026 at 9:17 AM_

            **[09:17:52] You:** Let's start.
            """
        let withContents = MeetingArchive.applying(sections: sections, heading: "Contents", to: bare)
        XCTAssertNil(MeetingArchive.parseSummary(markdown: withContents))
        let withBoth = MeetingArchive.applying(summary: "Notarization still fails", to: withContents)
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: withBoth), "Notarization still fails")
        XCTAssertEqual(MeetingArchive.parseSections(markdown: withBoth), sections)
        XCTAssertEqual(MeetingArchive.parse(markdown: withBoth).count, 1)
    }

    /// Renaming a speaker rewrites the transcript; it must not take the
    /// contents with it. (The rename matches `] Name:**`, and a bullet has no
    /// such shape — this is the test that keeps it that way.)
    func testRenamingASpeakerLeavesTheContentsAlone() {
        let written = MeetingArchive.applying(sections: sections, heading: "Contents", to: named)
        let renamed = MeetingArchive.renaming(markdown: written, from: "Ruslan", to: "Руслан")
        XCTAssertEqual(MeetingArchive.parseSections(markdown: renamed), sections)
        XCTAssertTrue(renamed.contains("] Руслан:**"))
    }

    /// …and so must retitling, which rewrites the two lines above the block.
    func testRetitlingLeavesTheContentsAlone() {
        let written = MeetingArchive.applying(sections: sections, heading: "Contents", to: named)
        let retitled = MeetingArchive.applying(title: "Notarization", dateLine: "August 10, 2026",
                                               to: written)
        XCTAssertEqual(MeetingArchive.parseSections(markdown: retitled), sections)
        XCTAssertEqual(MeetingArchive.parseTitle(markdown: retitled), "Notarization")
        XCTAssertEqual(MeetingArchive.parseSummary(markdown: retitled),
                       "2.4 slipped a week — notarization still fails on the CI box")
    }

    /// Regenerating replaces the block instead of stacking a second one on top
    /// of it — including when the heading was written in another interface
    /// language, which is why the block is found by its bullets and not by its
    /// heading.
    func testRegeneratingReplacesTheBlockWhateverLanguageItsHeadingIsIn() {
        let russian = MeetingArchive.applying(sections: sections, heading: "Содержание", to: named)
        let fresh = [TranscriptSection(time: "09:24:03", line: "Stripping the entitlement")]
        let again = MeetingArchive.applying(sections: fresh, heading: "Contents", to: russian)
        XCTAssertEqual(MeetingArchive.parseSections(markdown: again), fresh)
        XCTAssertFalse(again.contains("Содержание"))
        XCTAssertEqual(again.components(separatedBy: "## ").count - 1, 1)
        XCTAssertEqual(MeetingArchive.parse(markdown: again).count, 3)
    }

    /// Nothing to say, nothing written: an empty result must never blank a
    /// block that is already there.
    func testEmptySectionsLeaveTheFileAlone() {
        let written = MeetingArchive.applying(sections: sections, heading: "Contents", to: named)
        XCTAssertEqual(MeetingArchive.applying(sections: [], heading: "Contents", to: written),
                       written)
    }

    /// Only the block at the TOP is contents. A line further down that happens
    /// to look like a bullet is part of what somebody said.
    func testABulletInsideTheTranscriptIsNotASection() {
        let written = MeetingArchive.applying(sections: sections, heading: "Contents", to: named)
            + "\n- **[09:30:00]** not a section, this is below the transcript\n"
        XCTAssertEqual(MeetingArchive.parseSections(markdown: written), sections)
    }

    // MARK: - What the model is shown, and what it may write

    /// The owner's turns are labelled "You" in the file, and a model reading
    /// that writes sentences about a pronoun — "Shannon and You decide to
    /// focus on developing the system". Every prompt here builds its text
    /// through `excerpt`, so the substitution happens once and the title, the
    /// summary and the sections all get it.
    func testTheOwnerIsANamedParticipantInTheExcerpt() {
        let entries = [TranscriptEntry(time: "10:00:00", speaker: "You",
                                       text: "Let's start", isYou: true),
                       TranscriptEntry(time: "10:00:09", speaker: "Вы",
                                       text: "Готово", isYou: true),
                       TranscriptEntry(time: "10:00:18", speaker: "Shannon",
                                       text: "Fine by me", isYou: false)]
        let text = MeetingTitler.excerpt(from: entries)
        XCTAssertFalse(text.contains("You:"))
        XCTAssertFalse(text.contains("Вы:"))
        XCTAssertTrue(text.contains("\(MeetingTitler.ownerLabel): Let's start"))
        XCTAssertTrue(text.contains("Shannon: Fine by me"))
    }

    /// A second answer that is still too long ends where a reader would end
    /// it, not mid-phrase. This exact line reached the owner's file with an
    /// ellipsis in it (2026-08-14).
    func testALongLineEndsAtAClauseBoundaryRatherThanMidPhrase() {
        let long = """
            Shannon and Yuri discuss the AI onboarding process, with Shannon expressing             concerns about the non-deterministic nature of the agent
            """
        XCTAssertEqual(MeetingSectioner.shortened(long),
                       "Shannon and Yuri discuss the AI onboarding process")
        // A full stop beats a comma…
        XCTAssertEqual(MeetingSectioner.shortened(
            "Shannon fixes the name, again. Then Yury reviews the onboarding flow", to: 60),
                       "Shannon fixes the name, again")
        // …and a comma is used when there is no full stop.
        XCTAssertEqual(MeetingSectioner.shortened(
            "Shannon fixes the agent name, then Yury reviews the onboarding flow", to: 60),
                       "Shannon fixes the agent name")
        // …and a line with no boundary at all still says it was cut.
        XCTAssertTrue(MeetingSectioner.shortened(String(repeating: "word ", count: 60)).hasSuffix("…"))
        // Short enough already: untouched, and no ellipsis invented.
        XCTAssertEqual(MeetingSectioner.shortened("Pricing for the pilot"), "Pricing for the pilot")
    }

    // MARK: - Rejecting what the model writes when it has no thread to pull

    /// Every string here is verbatim from the first run against the owner's
    /// archive (2026-08-14). They are the reason this check exists at all: no
    /// wording of the prompt stops a model producing a pile of nouns when it
    /// cannot find one subject, so the shape is caught after the fact and the
    /// passage is asked again.
    func testAPileOfNounsIsRejected() {
        for line in [
            "Slavery; kidneys; security; legal; responsibility; TECHO; yuzkis; Rails; agent; AI",
            "Valik; Austin; STO; service station; deterministic system; agent",
            "demo with Yura; demo with Preoperation; demo with chatbot",
            "AI onboarding; agent experience; onboarding issues",
            "Quality of demo; trust in demo; use case; system; conversation",
            "agent onboarding; conversation 3",
            "Valentine's weekend cancelled; system onboarding; Geruslan's request",
        ] {
            XCTAssertTrue(MeetingSectioner.readsAsAList(line), line)
        }
    }

    /// …and a real line survives it, including one that names two subjects.
    /// A rule that also deleted these would have cost more than it saved.
    func testARealLineIsNotMistakenForAList() {
        for line in [
            "Change assistant status to active; set up onboarding",
            "Yury wants to expedite the agent's development; Shannon wants the transcripts",
            "Shannon needs to fix the name misunderstanding before the demo",
            "Pricing for the pharmacy pilot, agreed at 4500 euro",
            "Jerry is afraid that Shannon does not understand the demo",
        ] {
            XCTAssertFalse(MeetingSectioner.readsAsAList(line), line)
        }
    }

    /// Given a passage it cannot summarize, the model hands a piece of it
    /// back. Both strings below are verbatim from a real run, next to the
    /// passage they were lifted from.
    func testAQuoteFromThePassageIsRejected() {
        let passage = """
            You: We have no options. Speaker 2: guys, let's do it for tomorrow.             maybe it will come out, and then we'll see where we are.
            """
        XCTAssertTrue(MeetingSectioner.quotesThePassage(
            "We have no options. Speaker 2: guys, let's do it for tomorrow. maybe it will come out",
            passage: passage))
        // The same words, described rather than copied.
        XCTAssertFalse(MeetingSectioner.quotesThePassage(
            "The team decides to try again tomorrow rather than give up",
            passage: passage))
        // Short lines cannot be judged this way and are never rejected by it.
        XCTAssertFalse(MeetingSectioner.quotesThePassage("We have no options", passage: passage))
        // …and neither is a real description that happens to reuse a phrase.
        // At a six-word window this one was refused, and the meeting it came
        // from lost its whole block for it.
        XCTAssertFalse(MeetingSectioner.quotesThePassage(
            "Ruslan says it is all going to plan for tomorrow",
            passage: passage + " Speaker 1: it is all going to plan, Ruslan says."))
    }

    /// Punctuation and case are not a disguise.
    func testAQuoteIsCaughtThroughPunctuationAndCase() {
        XCTAssertTrue(MeetingSectioner.quotesThePassage(
            "RUSLAN — you were flooding us with something! What did we talk about?",
            passage: "Speaker 1: Ruslan, you were flooding us with something... What did we talk about?"))
    }

    /// The model spells the name its own way: the transcript says "Shanon"
    /// because that is what Whisper heard, and the model writes "Shannon".
    /// One edit of slack covers that and nothing else.
    func testASpeakerNameIsRecognizedThroughOneMisspelling() {
        XCTAssertTrue(MeetingSectioner.nearlyTheSameName("Shanon", "Shannon"))
        XCTAssertTrue(MeetingSectioner.nearlyTheSameName("Ruslan", "ruslan"))
        XCTAssertFalse(MeetingSectioner.nearlyTheSameName("Shanon", "Pricing"))
        XCTAssertFalse(MeetingSectioner.nearlyTheSameName("You", "Yura"))
    }

    /// The model sometimes answers in the shape of the transcript it was
    /// shown — "Shanon: we're not doing onboarding". The speaker's own name is
    /// dropped; a colon that is not a speaker is left alone.
    func testALeadingSpeakerNameIsDropped() {
        let slice = [entry("10:00:00", "Shanon"), entry("10:00:12", "You")]
        XCTAssertEqual(MeetingSectioner.withoutSpeakerPrefix("Shanon: no onboarding needed",
                                                             spokenBy: slice),
                       "no onboarding needed")
        // …and through the model's own spelling of it, which is the case that
        // actually reached the owner's file.
        XCTAssertEqual(MeetingSectioner.withoutSpeakerPrefix("Shannon: no onboarding needed",
                                                             spokenBy: slice),
                       "no onboarding needed")
        XCTAssertEqual(MeetingSectioner.withoutSpeakerPrefix("Pricing: the pharmacy pilot",
                                                             spokenBy: slice),
                       "Pricing: the pharmacy pilot")
        XCTAssertEqual(MeetingSectioner.withoutSpeakerPrefix("no colon here", spokenBy: slice),
                       "no colon here")
    }

    /// A model answer arriving as a Markdown bullet must not produce two
    /// bullets on one line when it is written into the file.
    func testSanitizerStripsALeadingBullet() {
        XCTAssertEqual(MeetingTitler.sanitizeSummary("- Pricing for the pharmacy pilot",
                                                     minCharacters: MeetingSectioner.minimumCharacters),
                       "Pricing for the pharmacy pilot")
        XCTAssertEqual(MeetingTitler.sanitizeSummary("• Notarization fails on CI",
                                                     minCharacters: MeetingSectioner.minimumCharacters),
                       "Notarization fails on CI")
    }
}
