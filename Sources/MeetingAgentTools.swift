import Foundation

/// The archive, as tools the asking agent can call.
///
/// Three verbs — list, search, read — and nothing else. The agent gets no
/// file paths, no folder access and no way to write: every call goes through
/// the same parser the library itself reads with, and what comes back is
/// text. The passages the local search pre-supplies remain the starting
/// point; these tools exist for the question they cannot answer — "read the
/// whole call", "what else did we say about X" — which used to end at eight
/// lines of excerpt.
///
/// Vendor-neutral on purpose: one name, one description, one JSON schema,
/// consumed by both oracles so Claude and ChatGPT hold the same tools and the
/// same contract.
enum MeetingAgentTool: String, CaseIterable {
    case listMeetings = "list_meetings"
    case searchMeetings = "search_meetings"
    case readMeeting = "read_meeting"

    var summary: String {
        switch self {
        case .listMeetings:
            return "List every recorded meeting: file name, date, duration, title and one-line summary. Use it to orient before searching or reading."
        case .searchMeetings:
            return "Search every transcript, title, summary and outline line for the given words (case-insensitive substring). Query in the language the meetings are in; try a few different words if the first search comes back empty. Returns matching meetings with their file names."
        case .readMeeting:
            return "Read one meeting's transcript in full, speaker-attributed with timestamps. Identify the meeting by the exact file name that list_meetings or search_meetings returned."
        }
    }

    /// JSON Schema of the arguments, shared verbatim by both vendors.
    var schema: [String: Any] {
        switch self {
        case .listMeetings:
            return ["type": "object", "properties": [String: Any]()]
        case .searchMeetings:
            return ["type": "object",
                    "properties": ["query": ["type": "string",
                                             "description": "Words to look for, in the meetings' own language."]],
                    "required": ["query"]]
        case .readMeeting:
            return ["type": "object",
                    "properties": ["file": ["type": "string",
                                            "description": "The meeting's file name, exactly as another tool returned it."]],
                    "required": ["file"]]
        }
    }

    /// A transcript that no longer fits is cut, not refused: the head of a
    /// meeting carries its agenda and its decisions more often than the tail,
    /// and an agent told "too big" has nowhere to go from there.
    static let readCap = 120_000

    /// A tool round in progress, worded for the reader — the answer pane
    /// shows it where "Reading…" sits, so the silence between tool rounds
    /// says what the model is actually doing with the archive.
    static let progressNotification = Notification.Name("dictate.askProgress")

    @MainActor private static func progress(_ text: String) {
        NotificationCenter.default.post(name: progressNotification, object: text)
    }

    /// Runs one call and returns what the model will read.
    ///
    /// Never throws: a tool error the model can read ("no such meeting") is a
    /// recoverable step in its plan, an exception is a dead answer.
    static func run(name: String, arguments: [String: Any]) async -> String {
        guard let tool = MeetingAgentTool(rawValue: name) else {
            return "Unknown tool: \(name)"
        }
        // The disk read stays off the main thread (an iCloud-evicted file
        // blocks on the network — the 16-second hang of 2026-08-17); the
        // semantic index is main-actor state, so scoring hops there.
        let youLabel = await MainActor.run { L("You") }
        let meetings = await Task.detached(priority: .userInitiated) {
            MeetingArchive.list(youLabel: youLabel)
        }.value
        guard !meetings.isEmpty else { return "The archive is empty." }

        switch tool {
        case .listMeetings:
            await progress(Lf("Looking through %d meetings…", meetings.count))
            return meetings.map(Self.line(for:)).joined(separator: "\n")

        case .searchMeetings:
            guard let query = arguments["query"] as? String,
                  !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "search_meetings needs a query."
            }
            await progress(L("Searching your meetings…"))
            // Literal only — the semantic ranking was retired with the
            // library's (MeetingSearch's header tells the story). The model
            // compensates the way a person does: by trying another word.
            let literal = MeetingSearch.literal(meetings, query: query)
            guard !literal.isEmpty else {
                return "Nothing in the archive matches that. Try different words, or list_meetings to orient."
            }
            return literal.prefix(10).map(Self.line(for:)).joined(separator: "\n")

        case .readMeeting:
            guard let file = arguments["file"] as? String, !file.isEmpty else {
                return "read_meeting needs a file name."
            }
            if let meeting = meetings.first(where: { $0.url.lastPathComponent == file }) {
                let name = meeting.title ?? meeting.url.deletingPathExtension().lastPathComponent
                await progress(Lf("Reading “%@”…", name))
            }
            guard let meeting = meetings.first(where: { $0.url.lastPathComponent == file }) else {
                let names = meetings.map(\.url.lastPathComponent).joined(separator: "\n")
                return "No meeting named \"\(file)\". The archive has:\n\(names)"
            }
            var text = Self.line(for: meeting) + "\n\n"
                + meeting.entries.map { "[\($0.time)] \($0.speaker): \($0.text)" }
                    .joined(separator: "\n")
            if text.count > readCap {
                let dropped = text.count - readCap
                text = String(text.prefix(readCap))
                    + "\n[Transcript truncated here — \(dropped) more characters. The beginning is above; ask the person to open the meeting if the tail matters.]"
            }
            return text
        }
    }

    /// One meeting, one line — the same facts everywhere a tool names one.
    private static func line(for meeting: ArchivedMeeting) -> String {
        var parts = [meeting.url.lastPathComponent]
        parts.append(DateFormatter.localizedString(from: meeting.started,
                                                   dateStyle: .medium, timeStyle: .short))
        if let title = meeting.title { parts.append(title) }
        if let summary = meeting.summary { parts.append(summary) }
        return parts.joined(separator: " — ")
    }
}
