import Foundation

/// Contents blocks already generated, so choosing a granularity a second time
/// costs nothing.
///
/// Cutting a meeting again takes about half a minute of model work — fine as a
/// deliberate act, absurd as the price of going back to what you had a moment
/// ago. So every cut is kept, and switching between levels you have already
/// seen is instant.
///
/// NOT in the transcript. The .md file holds exactly one contents block because
/// it has to stay a document somebody can read in any Markdown app, and three
/// alternative tables of contents stacked in the header would wreck that for a
/// convenience only this app can use. The file keeps the chosen one; this keeps
/// the others.
///
/// Kept lazily rather than generated up front: three levels for every meeting
/// would triple the background model work on a machine that is also recording
/// calls, to fill in levels most people will never open. What somebody has
/// asked for once, they get free forever after.
enum SectionCache {

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate/section-cuts.json")
    }

    /// What makes a cut valid for a transcript.
    ///
    /// The entry count and the last stamp together: a meeting that grew has
    /// passages the cached cut never saw, and offering it would point
    /// timestamps at a shape the file no longer has. Cheap to compute and
    /// wrong only in ways that make us regenerate, never in ways that make us
    /// show something stale.
    private static func key(_ url: URL, _ entries: [TranscriptEntry],
                            _ detail: MeetingPolicy.SectionDetail) -> String {
        "\(url.lastPathComponent)|\(entries.count)|\(entries.last?.time ?? "")|\(detail.rawValue)"
    }

    private struct Stored: Codable {
        var time: String
        var line: String
    }

    private static func load() -> [String: [Stored]] {
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONDecoder().decode([String: [Stored]].self, from: data)
        else { return [:] }
        return map
    }

    static func cut(_ url: URL, _ entries: [TranscriptEntry],
                    _ detail: MeetingPolicy.SectionDetail) -> [TranscriptSection]? {
        load()[key(url, entries, detail)]?
            .map { TranscriptSection(time: $0.time, line: $0.line) }
    }

    static func remember(_ sections: [TranscriptSection], for url: URL,
                         _ entries: [TranscriptEntry],
                         _ detail: MeetingPolicy.SectionDetail) {
        guard !sections.isEmpty else { return }
        var map = load()
        map[key(url, entries, detail)] = sections.map { Stored(time: $0.time, line: $0.line) }
        // Bounded, and by count rather than by age: this is a convenience
        // cache, and the cost of losing an entry is one regeneration somebody
        // asked for anyway. 600 is roughly two hundred meetings at three cuts
        // each — far past any archive this app has seen.
        if map.count > 600 { map = [:] }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(map).write(to: file, options: .atomic)
    }
}
