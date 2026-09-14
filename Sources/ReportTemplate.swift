import Foundation

/// One field of a report template: a name that becomes the heading, and an
/// optional instruction telling the model what belongs under it. A field
/// with no instruction goes by its name alone.
struct ReportField: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var instruction: String

    init(id: UUID = UUID(), name: String, instruction: String = "") {
        self.id = id
        self.name = name
        self.instruction = instruction
    }

    /// A field the model can be asked about: it has a name. Empty rows in
    /// the editor are tolerated while typing and dropped when the report is
    /// written.
    var isUsable: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A report template: what a person wants written up after every call of a
/// kind — a sales call, an interview, a support case. The structure is a
/// list of fields, not free text, so the report cannot be malformed and every
/// field maps to exactly one heading.
struct ReportTemplate: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// One paragraph for the whole template telling the model who "we" are
    /// and what to look for. Optional.
    var context: String
    var fields: [ReportField]

    init(id: UUID = UUID(), name: String, context: String = "", fields: [ReportField]) {
        self.id = id
        self.name = name
        self.context = context
        self.fields = fields
    }

    /// The fields the model is actually asked about, in order.
    var usableFields: [ReportField] { fields.filter(\.isUsable) }

    /// Whether a report can be written from this template at all.
    var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !usableFields.isEmpty
    }

    // MARK: - Starters

    /// The templates a new one starts from: the two most recordings need
    /// — a structured account of a meeting, and the short minutes of
    /// decisions and tasks — and a blank. Field names and instructions are
    /// shown in the interface language; the report language is a separate
    /// setting and applies to the bodies.
    static func starter(_ kind: StarterKind) -> ReportTemplate {
        switch kind {
        case .summary:
            return ReportTemplate(
                name: L("Meeting summary"),
                context: L("We are the team on this call; the reader took part in it."),
                fields: [
                    ReportField(name: L("Purpose"),
                                instruction: L("Why we met and what we set out to settle")),
                    ReportField(name: L("Key points"),
                                instruction: L("The main arguments and facts, with the numbers, names and dates that were said")),
                    ReportField(name: L("Decisions"),
                                instruction: L("What was decided, by whom, and what it replaces")),
                    ReportField(name: L("Action items"),
                                instruction: L("Who does what, by when — one line per task")),
                    ReportField(name: L("Open questions"),
                                instruction: L("What was raised and not settled, and who owns it")),
                    ReportField(name: L("Risks and concerns"),
                                instruction: L("What could go wrong, who raised it, how serious it sounded")),
                    ReportField(name: L("Next step"),
                                instruction: L("The next meeting or checkpoint, if one was agreed")),
                ])
        case .actions:
            return ReportTemplate(
                name: L("Decisions & actions"),
                context: L("We are the team on this call; the reader took part in it."),
                fields: [
                    ReportField(name: L("Decisions"),
                                instruction: L("What was decided, by whom, and what it replaces")),
                    ReportField(name: L("Action items"),
                                instruction: L("Who does what, by when — one line per task")),
                    ReportField(name: L("Dates and deadlines"),
                                instruction: L("Every date, deadline or time window that was mentioned, and what it is for")),
                    ReportField(name: L("Waiting on"),
                                instruction: L("What each side is waiting for from the other")),
                ])
        case .blank:
            return ReportTemplate(name: L("New template"), fields: [ReportField(name: "")])
        }
    }

    enum StarterKind: CaseIterable {
        case summary, actions, blank
    }
}

/// The templates on disk: one JSON file in Application Support, read once
/// and rewritten whole on every change. NOT in the meeting archive, whose
/// reader treats every file there as a transcript.
///
/// @MainActor: every caller is the Templates tab or a meeting's card, and
/// the file is a few kilobytes.
@MainActor
final class ReportTemplateStore: ObservableObject {
    static let shared = ReportTemplateStore()

    @Published private(set) var templates: [ReportTemplate] = []

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
            .appendingPathComponent("report-templates.json")
        load()
    }

    func template(id: UUID) -> ReportTemplate? {
        templates.first { $0.id == id }
    }

    /// Adds or replaces. Called on every keystroke of the editor: the list
    /// in memory changes at once, the file follows a moment later.
    func save(_ template: ReportTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            guard templates[index] != template else { return }
            templates[index] = template
        } else {
            templates.append(template)
        }
        persistSoon()
    }

    func remove(id: UUID) {
        templates.removeAll { $0.id == id }
        persist()
    }

    /// One write for a burst of typing: the file is rewritten whole, and a
    /// name typed letter by letter is not twelve files.
    private var pendingWrite: Task<Void, Never>?

    private func persistSoon() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([ReportTemplate].self, from: data)
        else { return }
        templates = list
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(templates) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
