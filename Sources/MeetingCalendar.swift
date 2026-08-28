import EventKit
import Foundation

/// The calendar half of naming a meeting: asks EventKit what was scheduled
/// around the moment recording began, reduces each event to plain facts, and
/// lets `MeetingCalendarPolicy` decide which one — if any — this call is.
///
/// Reading only, and locally. EventKit serves whatever accounts the Mac's own
/// Calendar app is signed into, so a Google calendar added there is visible
/// here with no API key, no OAuth and no network call of ours — which is what
/// lets this feature exist without touching "everything stays on this Mac".
enum MeetingCalendar {

    /// Off until the owner turns it on, and turning it on is what asks macOS
    /// for permission. Deliberately NOT part of onboarding: this app already
    /// asks for the microphone, for accessibility and for system audio, and a
    /// fourth prompt in the first five minutes is how an app gets abandoned.
    /// It earns its prompt at the moment somebody wants the feature.
    static var isEnabled: Bool { Settings.shared.nameMeetingsFromCalendar }

    static var authorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    static var hasAccess: Bool { authorization == .fullAccess }

    /// Full access, not write-only: this feature only ever READS, and write-only
    /// is the permission for apps that create events. There is no read-only
    /// tier in EventKit — full access is the smallest one that can see a title.
    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            Log.d("calendar: access \(granted ? "granted" : "refused")")
            return granted
        } catch {
            Log.d("calendar: access request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The name this meeting already has, or nil to let the model invent one.
    ///
    /// Called at session START, which is the point of doing this at all: the
    /// transcript can carry its real name from the first line, the file is
    /// created under that name instead of being renamed at the end, and the
    /// window shows it while the call is still running.
    static func scheduledTitle(at start: Date) -> (title: String, calendar: String, platform: String?)? {
        // Access is the only hard gate. The naming SETTING gates the title
        // alone: the platform (the sidebar's Sources group) is harmless
        // metadata, and losing "Google Meet" because auto-naming is off was
        // exactly the owner's "why is Meet never detected" (2026-08-28).
        guard hasAccess else { return nil }
        let store = EKEventStore()
        // A window wide enough to hold every event the rule might accept, and
        // no wider — the rule does the judging, this only feeds it.
        let from = start.addingTimeInterval(-MeetingCalendarPolicy.lateGrace - 3600)
        let to = start.addingTimeInterval(MeetingCalendarPolicy.earlyGrace + 3600)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let raw = store.events(matching: predicate)
        let events = raw.map(fact(from:))
        guard let match = MeetingCalendarPolicy.match(events: events, startedAt: start) else {
            Log.d("calendar: no scheduled meeting matched (\(events.count) event(s) nearby)")
            return nil
        }
        Log.d("calendar: named from \"\(match.calendarName)\" — \(match.title)")
        // The event's conference link also names the PLATFORM — the sidebar's
        // Sources group. Best-effort: nil when the link names nothing known.
        let platform = raw.first { ($0.title ?? "") == match.title }.flatMap(platform(of:))
        return (match.title, match.calendarName, platform)
    }

    /// "Google Meet" / "Zoom" / "Microsoft Teams"… from the event's own link.
    private static func platform(of event: EKEvent) -> String? {
        let haystack = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        guard !haystack.isEmpty else { return nil }
        let map: [(String, String)] = [
            ("meet.google.com", "Google Meet"), ("zoom.us", "Zoom"),
            ("teams.microsoft.com", "Microsoft Teams"), ("teams.live.com", "Microsoft Teams"),
            ("webex.com", "Webex"), ("whereby.com", "Whereby"), ("discord.gg", "Discord"),
            ("slack.com/call", "Slack"),
        ]
        return map.first { haystack.contains($0.0) }?.1
    }

    /// One EKEvent, reduced to what the rule is allowed to reason about.
    private static func fact(from event: EKEvent) -> MeetingCalendarPolicy.Event {
        MeetingCalendarPolicy.Event(
            title: event.title ?? "",
            start: event.startDate ?? .distantPast,
            end: event.endDate ?? .distantPast,
            isAllDay: event.isAllDay,
            // The organiser is an attendee too, so a real invitation always has
            // more than one; a self-made block usually has none at all.
            hasAttendees: (event.attendees?.count ?? 0) > 1,
            hasConferenceLink: conferenceLink(in: event),
            declined: declined(event),
            calendarName: event.calendar?.title ?? "")
    }

    /// Does this event have somewhere to call in to? The industry's strongest
    /// "this is a call" signal, and cheap: the URL field, the location and the
    /// notes are where every platform puts it.
    private static func conferenceLink(in event: EKEvent) -> Bool {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                     "webex.com", "whereby.com", "meet.jit.si", "around.co", "bluejeans.com",
                     "gotomeeting.com", "chime.aws", "discord.gg", "slack.com/call"]
        let haystack = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return false }
        return hosts.contains { haystack.contains($0) }
    }

    /// Did the user decline? EventKit reports the status of each participant,
    /// and the one that matters is the current user's.
    private static func declined(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return true }
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }
}
