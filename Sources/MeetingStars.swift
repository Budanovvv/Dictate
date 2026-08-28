import Foundation

/// Starred meetings — the sidebar's own shortlist.
///
/// Keyed by the meeting's START time, not its URL: renaming a meeting renames
/// its file (the URL is the identity of the moment, not of the meeting), while
/// the start stamp lives in the file name and survives every retitle. Stored
/// in UserDefaults rather than in the file — a star is the reader's bookmark,
/// not part of the transcript, and writing it would rewrite a user document
/// for a toggle.
enum MeetingStars {
    private static let key = "starredMeetings"

    private static var stamps: Set<TimeInterval> {
        get { Set(UserDefaults.standard.array(forKey: key) as? [TimeInterval] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    static func isStarred(_ started: Date) -> Bool {
        stamps.contains(started.timeIntervalSinceReferenceDate.rounded())
    }

    static func toggle(_ started: Date) {
        let stamp = started.timeIntervalSinceReferenceDate.rounded()
        var set = stamps
        if !set.insert(stamp).inserted { set.remove(stamp) }
        stamps = set
    }
}
