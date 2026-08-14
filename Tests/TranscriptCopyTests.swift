import XCTest

/// What leaves the meetings window on the clipboard, and when the live list is
/// allowed to move under the user's hands. Both were reported from a real
/// call — there was no way to copy one turn, and selecting text was torn away
/// by the auto-scroll — so the rules are pinned here rather than trusted.
final class TranscriptCopyTests: XCTestCase {

    private func turn(_ speaker: String, _ time: String, _ texts: [String],
                      isYou: Bool = false) -> TranscriptTurn {
        let entries = texts.map {
            TranscriptEntry(time: time, speaker: speaker, text: $0, isYou: isYou)
        }
        return TranscriptTurn(id: entries[0].id, speaker: speaker, isYou: isYou,
                              time: time, entries: entries)
    }

    // MARK: - Copying a turn

    func testCopyTextIsTheWordsOnly() {
        let t = turn("Speaker 1", "09:18:26", ["Yes, I'm ready.", "Go on."])
        XCTAssertEqual(TranscriptCopy.text(of: t), "Yes, I'm ready. Go on.")
    }

    func testCopyTextTrimsTheEdges() {
        let t = turn("You", "09:17:52", ["  Let's start.  "], isYou: true)
        XCTAssertEqual(TranscriptCopy.text(of: t), "Let's start.")
    }

    /// The attributed form is the same shape as a line in the .md file, so a
    /// quoted turn stays attributable wherever it is pasted.
    func testCopyWithSpeakerAndTimeMatchesTheArchiveFormat() {
        let t = turn("Speaker 1", "09:18:26", ["Yes, I'm ready."])
        XCTAssertEqual(TranscriptCopy.attributed(t), "[09:18:26] Speaker 1: Yes, I'm ready.")
    }

    /// A turn merges several recognition windows; the copied line must read as
    /// one utterance with the time it started at, not as three telegrams.
    func testAttributedTurnKeepsTheStartTimeAndJoinsTheWindows() {
        let t = turn("Speaker 2", "10:01:03", ["One.", "Two.", "Three."])
        XCTAssertEqual(TranscriptCopy.attributed(t), "[10:01:03] Speaker 2: One. Two. Three.")
    }

    // MARK: - Copying a transcript

    func testTranscriptIsOneLinePerEntry() {
        let entries = [
            TranscriptEntry(time: "09:17:52", speaker: "You", text: "Let's start.", isYou: true),
            TranscriptEntry(time: "09:18:26", speaker: "Speaker 1", text: "Ready.", isYou: false),
        ]
        XCTAssertEqual(TranscriptCopy.transcript(entries),
                       "[09:17:52] You: Let's start.\n[09:18:26] Speaker 1: Ready.")
    }

    /// An empty transcript must not wipe the clipboard the user is carrying
    /// something else in.
    func testEmptyTextIsNeverPutOnThePasteboard() {
        XCTAssertEqual(TranscriptCopy.transcript([]), "")
        XCTAssertFalse(TranscriptCopy.put(""))
    }

    // MARK: - The copy control's geometry

    /// The first build put an 11pt glyph inline after the timestamp and it was
    /// reported as unclickable. A target smaller than 28pt is that bug again.
    func testCopyTargetIsBigEnoughToHit() {
        XCTAssertGreaterThanOrEqual(TurnCopy.targetSize, 28)
        // The drawn chip is deliberately smaller than the target: the ring
        // around it is invisible padding that still takes the click.
        XCTAssertLessThan(TurnCopy.chipSize, TurnCopy.targetSize)
    }

    /// The reserved column is what keeps the copy button and the speaker's
    /// name-button from ever sharing a pixel — at any window width, with any
    /// length of name. If the gutter is ever narrowed below the target, they
    /// can touch again.
    func testCopyTargetNeverOverlapsTheTurnsContent() {
        XCTAssertGreaterThanOrEqual(TurnCopy.gutter, TurnCopy.targetSize)
        for width in [320.0, 360.0, 420.0, 780.0, 2000.0] as [CGFloat] {
            XCTAssertTrue(TurnCopy.targetIsClear(ofTurnWidth: width), "width \(width)")
            XCTAssertLessThanOrEqual(TurnCopy.contentWidth(inTurnWidth: width),
                                     width - TurnCopy.targetSize)
        }
    }

    /// A control at opacity 0 is still clickable in SwiftUI — an invisible
    /// thing that swallows clicks. The chip fades to a hint, never to nothing.
    func testCopyChipIsNeverInvisible() {
        for dark in [true, false] {
            XCTAssertGreaterThan(TurnCopy.restingAlpha(dark: dark), 0, "dark=\(dark)")
            XCTAssertLessThan(TurnCopy.restingAlpha(dark: dark), 1, "dark=\(dark)")
        }
    }

    /// Dark ink on a bright page loses more to the eye than bright ink on a
    /// dark one, so the resting chip has to be HEAVIER in the light appearance
    /// to read the same. One shared number is what made it invisible on white.
    func testRestingChipIsHeavierInTheLightAppearance() {
        XCTAssertGreaterThan(TurnCopy.restingAlpha(dark: false),
                             TurnCopy.restingAlpha(dark: true))
    }

    // MARK: - Pinned to the bottom

    func testShortTranscriptIsAlwaysPinned() {
        XCTAssertTrue(TranscriptScroll.isPinned(contentOffsetY: 0, containerHeight: 500,
                                                contentHeight: 120))
        // A bounce can report an offset outside the content entirely.
        XCTAssertTrue(TranscriptScroll.isPinned(contentOffsetY: -30, containerHeight: 500,
                                                contentHeight: 120))
    }

    func testBottomOfALongTranscriptIsPinned() {
        XCTAssertTrue(TranscriptScroll.isPinned(contentOffsetY: 4500, containerHeight: 500,
                                                contentHeight: 5000))
    }

    /// Half a line of slack is still "at the bottom" — a rendering wobble must
    /// not read as a decision to stop following the call.
    func testASmallGapStillCountsAsPinned() {
        XCTAssertTrue(TranscriptScroll.isPinned(contentOffsetY: 4480, containerHeight: 500,
                                                contentHeight: 5000))
    }

    /// One deliberate scroll up must disarm auto-scroll: this is the whole fix
    /// for "the line I was selecting jumped away".
    func testScrolledUpIsNotPinned() {
        XCTAssertFalse(TranscriptScroll.isPinned(contentOffsetY: 4300, containerHeight: 500,
                                                 contentHeight: 5000))
        XCTAssertFalse(TranscriptScroll.isPinned(contentOffsetY: 0, containerHeight: 500,
                                                 contentHeight: 5000))
    }

    /// The bottom inset (the list's own padding) is part of the content the
    /// user has to reach — forgetting it would leave the list permanently
    /// "scrolled up" and auto-scroll permanently off.
    func testBottomInsetIsPartOfTheDistance() {
        XCTAssertTrue(TranscriptScroll.isPinned(contentOffsetY: 4520, containerHeight: 500,
                                                contentHeight: 5000, bottomInset: 40))
        XCTAssertFalse(TranscriptScroll.isPinned(contentOffsetY: 4400, containerHeight: 500,
                                                 contentHeight: 5000, bottomInset: 40))
    }

    /// Long transcripts jump without animation — see TranscriptScroll.
    func testAnimationIsDroppedOnLongTranscripts() {
        XCTAssertTrue(TranscriptScroll.animates(entryCount: 10))
        XCTAssertTrue(TranscriptScroll.animates(entryCount: TranscriptScroll.animationLimit))
        XCTAssertFalse(TranscriptScroll.animates(entryCount: 348))   // a real meeting
    }
}
