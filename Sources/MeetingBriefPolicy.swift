import Foundation

/// What the portal's home surface says — computed, never asked of a model.
///
/// The category's one commercially proven AI-first home (Gong) builds its
/// "what matters now" out of deterministic rules over metadata and lets
/// models write only the prose. This follows that finding to the letter: the
/// facts below are arithmetic over dates and tags, they cost nothing per
/// visit, they cannot hallucinate — and the prose on the home card is the
/// summary the local model already wrote into the newest transcript when it
/// closed. Nothing is generated on view.
///
/// Pure values in, pure values out, calendar injected — a rule, not a view,
/// so it is testable without an archive (the shape every policy in this
/// project takes).
enum MeetingBriefPolicy {

    /// One meeting, reduced to what the brief can use.
    struct Item: Equatable {
        let url: URL
        let started: Date
        let seconds: TimeInterval
        let tags: [String]
    }

    struct Brief: Equatable {
        /// The meeting the catch-up card shows — the newest one.
        let latest: URL?
        /// Calls since the start of the current week, and their total length.
        let weekCalls: Int
        let weekSeconds: TimeInterval
        /// The week's most-used tag, when there is one.
        let topTag: String?
        let topTagCount: Int
    }

    static func brief(_ items: [Item], now: Date, calendar: Calendar) -> Brief {
        let latest = items.max { $0.started < $1.started }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let week = items.filter { $0.started >= weekStart && $0.started <= now }
        var counts: [String: Int] = [:]
        for item in week {
            for tag in item.tags { counts[tag, default: 0] += 1 }
        }
        // Deterministic to the tie: equal counts resolve alphabetically, so
        // the brief never flickers between two answers on reload.
        let top = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }
        return Brief(latest: latest?.url,
                     weekCalls: week.count,
                     weekSeconds: week.reduce(0) { $0 + $1.seconds },
                     topTag: top?.key,
                     topTagCount: top?.value ?? 0)
    }
}
