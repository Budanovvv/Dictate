import XCTest

final class MeetingBriefPolicyTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2  // Monday, fixed — the rule must not float with the test machine
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // Wednesday 2026-08-26 12:00 UTC — mid-week, so "this week" has room on
    // both sides.
    private let now = Date(timeIntervalSince1970: 1_787_745_600)

    private func item(_ name: String, daysAgo: Double, minutes: Double = 30,
                      tags: [String] = []) -> MeetingBriefPolicy.Item {
        MeetingBriefPolicy.Item(url: URL(fileURLWithPath: "/m/\(name).md"),
                                started: now.addingTimeInterval(-daysAgo * 86_400),
                                seconds: minutes * 60, tags: tags)
    }

    func testEmptyArchiveMakesAnEmptyBrief() {
        let brief = MeetingBriefPolicy.brief([], now: now, calendar: calendar)
        XCTAssertNil(brief.latest)
        XCTAssertEqual(brief.weekCalls, 0)
        XCTAssertNil(brief.topTag)
    }

    func testLatestIsNewestByStart() {
        let brief = MeetingBriefPolicy.brief(
            [item("old", daysAgo: 10), item("new", daysAgo: 0.1), item("mid", daysAgo: 3)],
            now: now, calendar: calendar)
        XCTAssertEqual(brief.latest?.lastPathComponent, "new.md")
    }

    func testWeekCountsOnlyThisCalendarWeek() {
        // Wednesday: 0.1 and 2 days ago are this week (Mon–), 5 days ago is last week.
        let brief = MeetingBriefPolicy.brief(
            [item("a", daysAgo: 0.1, minutes: 60), item("b", daysAgo: 2, minutes: 30),
             item("last-week", daysAgo: 5)],
            now: now, calendar: calendar)
        XCTAssertEqual(brief.weekCalls, 2)
        XCTAssertEqual(brief.weekSeconds, 90 * 60)
    }

    func testTopTagIsTheWeeksMostUsedAndTiesBreakAlphabetically() {
        let brief = MeetingBriefPolicy.brief(
            [item("a", daysAgo: 0.1, tags: ["investors", "billing"]),
             item("b", daysAgo: 1, tags: ["investors"]),
             item("c", daysAgo: 2, tags: ["billing"]),
             // Last week's tags must not vote.
             item("d", daysAgo: 6, tags: ["billing", "billing2"])],
            now: now, calendar: calendar)
        // investors 2, billing 2 → alphabetical tie-break: "billing".
        XCTAssertEqual(brief.topTag, "billing")
        XCTAssertEqual(brief.topTagCount, 2)
    }
}
