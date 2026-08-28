import Foundation

/// A persisted Ask conversation — everything needed to re-show an answer
/// without re-asking (no API call) and to continue it with a follow-up.
struct AskConversation: Codable, Identifiable {
    // Deliberately plain fields, no MeetingSource in sight: this file compiles
    // into the unit-test target, which builds a dependency-free subset of
    // Sources (see project.yml) — the MeetingSource conversions live with
    // MeetingAnswer in the app target.
    struct Source: Codable {
        var path: String
        var title: String
        var date: String
        var time: String?
        var text: String
    }

    struct Turn: Codable {
        var question: String
        var prompt: String
        var text: String
        var sources: [Source]
    }

    var id: UUID
    /// First question by default; the user can rename it.
    var title: String
    var createdAt: Date
    var lastActiveAt: Date
    var turns: [Turn]
    /// nil = a global conversation (the Ask view's list). A path = the
    /// transcript this thread is scoped to — "answers are kept with the
    /// meeting", shown from its header, not in the global list.
    var scopePath: String?

    /// How many distinct meetings the answers drew from — the list's
    /// "3 meetings" note, precomputed so listing never re-reads turns.
    var meetingsCount: Int {
        Set(turns.flatMap { $0.sources.map(\.path) }).count
    }
}

/// One JSON file per conversation in Application Support — app state, not user
/// documents (the meetings folder stays transcripts-only, and Application
/// Support is not on the iCloud-synced path that has stalled this app before).
///
/// Local by design: re-opening a stored answer costs no API call; only new
/// questions and follow-ups do. With Ask switched off nothing here is shown —
/// "off means absent" — but the files stay until the feature is used again.
final class AskHistoryStore {
    static let shared = AskHistoryStore()
    /// Old conversations beyond this quietly age out.
    static let cap = 50

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
            .appendingPathComponent("ask-history", isDirectory: true)
    }

    /// Newest first. Reads every file — they are small local JSONs and there
    /// are at most `cap` of them. `scope: nil` is the Ask view's global list;
    /// a path returns the threads kept with that one meeting.
    func list(scope: String? = nil) -> [AskConversation] {
        allConversations().filter { $0.scopePath == scope }
    }

    /// The newest thread kept with a meeting — what its scoped composer
    /// reopens.
    func latest(forScope path: String) -> AskConversation? {
        list(scope: path).first
    }

    private func allConversations() -> [AskConversation] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap {
                    try? JSONDecoder().decode(AskConversation.self, from: $0)
                }
            }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    func load(_ id: UUID) -> AskConversation? {
        (try? Data(contentsOf: fileURL(id))).flatMap {
            try? JSONDecoder().decode(AskConversation.self, from: $0)
        }
    }

    func save(_ conversation: AskConversation) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(conversation) else { return }
        try? data.write(to: fileURL(conversation.id), options: .atomic)
        enforceCap()
    }

    func rename(_ id: UUID, to title: String) {
        guard var conversation = load(id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversation.title = trimmed
        save(conversation)
    }

    /// Immediate — local data, no confirmation theater (owner's call). The
    /// replacement for confirmation is undo: the deleted conversation is held
    /// so ⌘Z (and the list's undo affordance) can bring it back.
    func delete(_ id: UUID) {
        lastDeleted = load(id)
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    /// The most recently deleted conversation, until the next delete or the
    /// end of the process. In-memory on purpose: undo is a moment's regret,
    /// not a trash can.
    private(set) var lastDeleted: AskConversation?

    /// Brings the last deleted conversation back. Returns it so the caller
    /// can reselect it in the list.
    @discardableResult
    func undelete() -> AskConversation? {
        guard let conversation = lastDeleted else { return nil }
        lastDeleted = nil
        save(conversation)
        return conversation
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }

    private func enforceCap() {
        let all = allConversations()
        guard all.count > Self.cap else { return }
        // Aging out is not a user delete — it must not clobber the undo slot.
        for old in all.dropFirst(Self.cap) {
            try? FileManager.default.removeItem(at: fileURL(old.id))
        }
    }
}
