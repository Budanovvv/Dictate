import Foundation

/// Finding a meeting again.
///
/// ONE search, and it is literal: which meeting contains these characters —
/// in a spoken turn, a speaker's name, the title, the summary, or an outline
/// line. Honest and predictable, which is the property the semantic ranking
/// this file used to carry could not keep: it scored with Apple's
/// English-only sentence embedding, and once summaries went back to the
/// meeting's own language (owner's call, 2026-08-28) its vectors were an
/// English model reading Russian — noise wearing a ranking. Removed whole
/// (owner's call, 2026-08-29); what remains is the search that never lied.
///
/// The summaries and outline lines still matter — they are what makes a
/// topical query land without embeddings, because the local model already
/// wrote the topic words into every meeting.
enum MeetingSearch {

    // MARK: - Literal

    /// The search that has always been here: does any turn, or any speaker's
    /// name, contain what was typed — plus tag filtering, which rides in the
    /// same field rather than in a pane of its own.
    ///
    /// A query may mix the two: `#wholecall pricing` means "tagged wholecall
    /// AND mentioning pricing". Tags narrow, words search — which is what each
    /// is good at, and it needs no new interface to say so.
    static func literal(_ meetings: [ArchivedMeeting], query: String) -> [ArchivedMeeting] {
        let (tags, text) = split(query: query)
        var found = meetings
        // Every named tag must be present: two tags mean the intersection,
        // because that is what a person adding a second tag is asking for.
        for tag in tags {
            found = found.filter { $0.tags.contains(tag) }
        }
        guard !text.isEmpty else { return found }
        return found.filter { meeting in
            if let title = meeting.title, title.lowercased().contains(text) { return true }
            if let summary = meeting.summary, summary.lowercased().contains(text) { return true }
            if meeting.sections.contains(where: { $0.line.lowercased().contains(text) }) { return true }
            return meeting.entries.contains {
                $0.text.lowercased().contains(text) || $0.speaker.lowercased().contains(text)
            }
        }
    }

    /// Splits "#wholecall pricing" into the tags to filter by and the words to
    /// search for. Pure, so the rule is testable without an archive.
    static func split(query: String) -> (tags: [String], text: String) {
        var tags: [String] = []
        var words: [String] = []
        for token in query.split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("#"), token.count > 1,
               let tag = MeetingTags.normalize(String(token.dropFirst())) {
                tags.append(tag)
            } else {
                words.append(String(token))
            }
        }
        return (tags, words.joined(separator: " ").lowercased())
    }
}
