import XCTest

/// Which calendar event a recording belongs to.
///
/// The refusals matter more than the matches, and that is the whole reason
/// this rule is a separate testable thing: naming a private conversation after
/// whatever happened to sit in the calendar at that hour would be worse than
/// leaving it named by its date. Every test below that asserts nil is guarding
/// against a confident wrong name.
final class MeetingCalendarPolicyTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_756_000_000)

    private func event(_ title: String = "Release planning",
                       startOffset: TimeInterval = 0,
                       minutes: TimeInterval = 60,
                       allDay: Bool = false,
                       attendees: Bool = true,
                       link: Bool = false,
                       declined: Bool = false,
                       calendar: String = "Work") -> MeetingCalendarPolicy.Event {
        let start = noon.addingTimeInterval(startOffset)
        return .init(title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                     isAllDay: allDay, hasAttendees: attendees, hasConferenceLink: link,
                     declined: declined, calendarName: calendar)
    }

    func testTheMeetingStartingNowIsTheMatch() {
        XCTAssertEqual(MeetingCalendarPolicy.match(events: [event()], startedAt: noon)?.title,
                       "Release planning")
    }

    func testRecordingStartedLateStillMatches() {
        // Nobody hits record at the top of the hour: people join, wait for the
        // last person, and then somebody remembers.
        XCTAssertNotNil(MeetingCalendarPolicy.match(
            events: [event()], startedAt: noon.addingTimeInterval(12 * 60)))
    }

    func testRecordingStartedLongAfterDoesNotMatch() {
        // Half an hour into a booked hour is more likely to be something else
        // entirely than a very late start.
        XCTAssertNil(MeetingCalendarPolicy.match(
            events: [event()], startedAt: noon.addingTimeInterval(35 * 60)))
    }

    func testJoiningAFewMinutesEarlyStillMatches() {
        // The 2026-09-18 miss: recording begun 5 min 25 s before a 10:00
        // meeting fell outside a five-minute grace by twenty-five seconds.
        XCTAssertNotNil(MeetingCalendarPolicy.match(
            events: [event()], startedAt: noon.addingTimeInterval(-6 * 60)))
    }

    func testRecordingLongBeforeDoesNotMatch() {
        // A conversation twenty minutes before a booked meeting is the previous
        // conversation, not an eager start on the next one.
        XCTAssertNil(MeetingCalendarPolicy.match(
            events: [event()], startedAt: noon.addingTimeInterval(-20 * 60)))
    }

    func testAllDayEventsAreNeverAMeeting() {
        // "Anna's birthday", "PTO", a public holiday — these span the day and
        // say nothing about a call inside it.
        XCTAssertNil(MeetingCalendarPolicy.match(
            events: [event("Anna's birthday", allDay: true)], startedAt: noon))
    }

    func testADeclinedInviteIsNotYourMeeting() {
        XCTAssertNil(MeetingCalendarPolicy.match(
            events: [event(declined: true)], startedAt: noon))
    }

    func testSoloBlocksAreNotMeetings() {
        // "Write the deck" with nobody invited and nowhere to dial in is a plan
        // for an hour, not a call happening in it.
        XCTAssertNil(MeetingCalendarPolicy.match(
            events: [event("Write the deck", attendees: false)], startedAt: noon))
    }

    func testAConferenceLinkIsEnoughOnItsOwn() {
        // A webinar invitation often carries no attendee list at all, and the
        // link is the industry's strongest "this is a call" signal.
        XCTAssertNotNil(MeetingCalendarPolicy.match(
            events: [event("Immigration webinar", attendees: false, link: true)],
            startedAt: noon))
    }

    func testPlaceholderTitlesAreRefusedSoTheModelCanTry() {
        // "Meeting" names the genre, not the meeting. A summary of what was
        // actually said beats it, so the rule declines to lend the name.
        for junk in ["Meeting", "call", "1:1", "Sync", "Weekly", "созвон", "Встреча."] {
            XCTAssertNil(MeetingCalendarPolicy.name(of: event(junk)),
                         "\(junk) should not name a transcript")
        }
    }

    func testARealTitleContainingAPlaceholderWordSurvives() {
        for good in ["Weekly sync with Chuck", "Call with the ISO auditor", "Product review: pricing"] {
            XCTAssertEqual(MeetingCalendarPolicy.name(of: event(good)), good)
        }
    }

    func testAGenericTitleStillIdentifiesTheMeeting() {
        // The owner's 2026-09-18 standup: eight guests, a Meet link, started a
        // minute before recording — and called "Daily". Refusing its NAME is
        // right; refusing the match threw away the platform and the calendar's
        // tag with it, which are facts and not names.
        let daily = event("Daily", attendees: true, link: true, calendar: "valentyn@wholecall.ai")
        let match = MeetingCalendarPolicy.match(events: [daily], startedAt: noon)
        XCTAssertEqual(match?.calendarName, "valentyn@wholecall.ai")
        XCTAssertNil(MeetingCalendarPolicy.name(of: daily))
    }

    func testARefusalSaysWhichGuardRefused() {
        // A bare count of nearby events is undiagnosable — telling a narrow
        // overshoot from a declined invite cost a separate EventKit probe.
        XCTAssertEqual(MeetingCalendarPolicy.rejection(event(), startedAt: noon), nil)
        XCTAssertEqual(MeetingCalendarPolicy.rejection(event(declined: true), startedAt: noon),
                       "declined")
        XCTAssertEqual(MeetingCalendarPolicy.rejection(event(allDay: true), startedAt: noon),
                       "all-day")
        XCTAssertEqual(MeetingCalendarPolicy.rejection(event(attendees: false), startedAt: noon),
                       "no guests, no link")
        // Twelve minutes early: outside the ten-minute grace, and the reason
        // has to say so rather than leaving it to be guessed.
        XCTAssertEqual(MeetingCalendarPolicy.rejection(event(), startedAt: noon.addingTimeInterval(-12 * 60)),
                       "starts in 12 min")
        XCTAssertEqual(MeetingCalendarPolicy.rejection(event(), startedAt: noon.addingTimeInterval(25 * 60)),
                       "25 min past its start")
        // Still inside the twenty-minute late grace, but the event itself
        // finished ten minutes ago: that name belongs to whatever came next.
        XCTAssertEqual(MeetingCalendarPolicy.rejection(event(startOffset: -20 * 60, minutes: 5),
                                                      startedAt: noon),
                       "already over")
    }

    func testBackToBackMeetingsPickTheOneThatJustStarted() {
        // The seam between two meetings is the case this rule exists for: both
        // are plausible for a recording begun there, and the one starting now
        // is the one being recorded.
        let earlier = event("Standup with the team", startOffset: -55 * 60, minutes: 60)
        let now = event("Release planning", startOffset: 0)
        XCTAssertEqual(
            MeetingCalendarPolicy.match(events: [earlier, now], startedAt: noon)?.title,
            "Release planning")
    }

    func testNothingScheduledMeansNothingClaimed() {
        XCTAssertNil(MeetingCalendarPolicy.match(events: [], startedAt: noon))
    }

    func testRecordingAfterTheEventEndedBelongsToWhateverCameNext() {
        // A ten-minute event that finished before recording began must not
        // lend its name to the next conversation.
        let short = event("Release planning", startOffset: -30 * 60, minutes: 10)
        XCTAssertNil(MeetingCalendarPolicy.match(events: [short], startedAt: noon))
    }
}
