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
    /// record several minutes in. Tight on the early side — a recording that
    /// starts twenty minutes before an event is far more likely to be the
    /// PREVIOUS conversation than an eager start on the next one.
    static let earlyGrace: TimeInterval = 5 * 60
    static let lateGrace: TimeInterval = 20 * 60

    /// The event this recording belongs to, or nil to let the model name it.
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

    static func isPlausible(_ event: Event, startedAt: Date) -> Bool {
        guard !event.isAllDay, !event.declined else { return false }
        // An event nobody else was invited to and with nowhere to call in to is
        // not a meeting this app is recording. Either signal is enough: a
        // walk-in with one colleague has attendees and no link; a webinar link
        // may carry no attendee list at all.
        guard event.hasAttendees || event.hasConferenceLink else { return false }
        guard isUsefulTitle(event.title) else { return false }
        let offset = startedAt.timeIntervalSince(event.start)
        guard offset >= -earlyGrace, offset <= lateGrace else { return false }
        // Recording that begins after the event was over belongs to whatever
        // came next, even if the clock is still inside the grace window.
        return startedAt < event.end.addingTimeInterval(earlyGrace)
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
