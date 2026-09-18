import Foundation

/// Which calendar event, if any, is the call being recorded — decided on plain
/// values so the rule can be tested without a calendar (the DictationPolicy
/// pattern; `MeetingCalendar` keeps the EventKit half).
///
/// A calendar title beats a generated one because it is not a guess: it is what
/// the person called this meeting when they arranged it, and it is what they
/// will look for months later. The model has to read a transcript and infer;
/// this reads an answer that already exists. (It has inferred badly, too — a
/// Russian work call once came back "Valentine's Day Plans".)
///
/// The whole risk of the feature is on THIS side: naming a private conversation
/// after whatever happened to be in the calendar at that hour would be worse
/// than leaving it undated. So the rule is deliberately reluctant — it would
/// rather return nothing than a plausible wrong answer.
enum MeetingCalendarPolicy {

    /// One event as the rule needs to see it. Everything EventKit-shaped has
    /// already been reduced to a fact.
    struct Event: Equatable, Sendable {
        let title: String
        let start: Date
        let end: Date
        /// Birthdays, holidays, "PTO" — these span the day and say nothing
        /// about a call happening inside it.
        let isAllDay: Bool
        /// Somebody else is expected to be there. A solo block ("focus time",
        /// "write the deck") is a plan, not a meeting.
        let hasAttendees: Bool
        /// A Zoom/Meet/Teams link in the location or the notes. The industry's
        /// strongest signal that an event IS a call, and ours too.
        let hasConferenceLink: Bool
        /// The user declined it. They are not in this meeting, whatever else is
        /// happening at that hour.
        let declined: Bool
        /// Which calendar it came from ("Work", "Clients") — carried for the
        /// tag idea that follows this one, and useful in the log meanwhile.
        let calendarName: String
    }

    /// How far from an event's start a recording may begin and still be that
    /// event.
    ///
    /// Generous on the late side because that is how meetings actually run:
    /// people join, wait for the last person, and somebody remembers to hit
    /// record several minutes in. Still tight on the early side — a recording
    /// that starts twenty minutes before an event is far more likely to be the
    /// PREVIOUS conversation than an eager start on the next one.
    ///
    /// Ten minutes, not five: joining early is ordinary, and five minutes lost
    /// the owner a real meeting by TWENTY-FIVE SECONDS (2026-09-18, recording
    /// begun 09:54:35 for an event at 10:00). Widening this is safe because
    /// `match` takes the closest start, so a previous meeting still running
    /// wins over the next one whenever it is nearer.
    static let earlyGrace: TimeInterval = 10 * 60
    static let lateGrace: TimeInterval = 20 * 60

    /// How long after an event ENDED a recording may still belong to it.
    ///
    /// Its own constant, and deliberately not `earlyGrace`: the two answer
    /// different questions, and sharing them means widening the early side
    /// silently lets a finished meeting lend its name for longer too. Five
    /// minutes — a call that runs a little over is ordinary, a recording that
    /// starts ten minutes after one ended belongs to whatever came next.
    static let endedGrace: TimeInterval = 5 * 60

    /// The event this recording belongs to, or nil when nothing scheduled fits.
    ///
    /// Whether that event's TITLE is usable is a separate question — `name(of:)`
    /// answers it. This one only decides which meeting is on the microphone.
    ///
    /// - Parameters:
    ///   - events: everything the calendar holds near the recording's start.
    ///   - startedAt: when the recording began.
    static func match(events: [Event], startedAt: Date) -> Event? {
        let plausible = events.filter { isPlausible($0, startedAt: startedAt) }
        // Closest start wins. With back-to-back meetings two events can both be
        // plausible for a recording begun in the seam between them, and the one
        // that just started is the one being recorded.
        return plausible.min { a, b in
            abs(a.start.timeIntervalSince(startedAt)) < abs(b.start.timeIntervalSince(startedAt))
        }
    }

    /// The NAME this event may lend a transcript, or nil when its title only
    /// names the genre.
    ///
    /// Deliberately NOT part of `match`: "is this recording that event" and "is
    /// that event's title worth borrowing" are different questions, and
    /// answering them together cost a real meeting (owner, 2026-09-18). A daily
    /// standup with eight guests and a Meet link matched on every count and was
    /// thrown away whole because it was called "Daily" — and the platform and
    /// the calendar's tag went down with the title, though neither is a name.
    static func name(of event: Event) -> String? {
        isUsefulTitle(event.title) ? event.title : nil
    }

    static func isPlausible(_ event: Event, startedAt: Date) -> Bool {
        rejection(event, startedAt: startedAt) == nil
    }

    /// Why this event is not the meeting being recorded — nil when it is.
    ///
    /// One source of truth for the rule and for the log. A miss used to print
    /// only how many events were nearby, which said nothing about WHICH guard
    /// refused them: diagnosing the owner's 2026-09-18 misses needed a separate
    /// EventKit probe, because a five-minute overshoot and a declined invite
    /// looked identical in the log. Titles are never returned here — the reason
    /// is enough, and a private calendar should not end up in a log file.
    static func rejection(_ event: Event, startedAt: Date) -> String? {
        if event.isAllDay { return "all-day" }
        if event.declined { return "declined" }
        // An event nobody else was invited to and with nowhere to call in to is
        // not a meeting this app is recording. Either signal is enough: a
        // walk-in with one colleague has attendees and no link; a webinar link
        // may carry no attendee list at all.
        if !(event.hasAttendees || event.hasConferenceLink) { return "no guests, no link" }
        let offset = startedAt.timeIntervalSince(event.start)
        if offset < -earlyGrace { return "starts in \(Int((-offset / 60).rounded())) min" }
        if offset > lateGrace { return "\(Int((offset / 60).rounded())) min past its start" }
        // Recording that begins after the event was over belongs to whatever
        // came next, even if the clock is still inside the grace window.
        if startedAt >= event.end.addingTimeInterval(endedGrace) { return "already over" }
        return nil
    }

    /// Placeholder titles a calendar is full of. "Meeting", "Call", "1:1",
    /// "Sync" name the genre, not the meeting, and the model's guess — which
    /// at least read what was said — is more use than any of them.
    ///
    /// Matched on the whole title after stripping punctuation, so "Weekly Sync
    /// with Chuck" survives and "sync." does not.
    static let placeholders: Set<String> = [
        "meeting", "call", "sync", "standup", "stand-up", "1:1", "11", "one on one",
        "catch up", "catchup", "chat", "check in", "checkin", "check-in",
        "weekly", "daily", "monthly", "review", "discussion", "zoom", "google meet",
        "встреча", "созвон", "звонок", "синк", "планёрка", "планерка",
    ]

    static func isUsefulTitle(_ title: String) -> Bool {
        let clean = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isPunctuation && !$0.isSymbol }
            .trimmingCharacters(in: .whitespaces)
        guard clean.count >= 3 else { return false }
        return !placeholders.contains(clean)
    }
}
