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

    /// The templates a new one starts from. Field names and instructions
    /// are written in English on purpose: they are the person's to edit,
    /// and a starter that arrived translated would be harder to recognise
    /// against the documentation than one that reads the same everywhere.
    /// The report language is a separate setting and applies to the bodies.
    static func starter(_ kind: StarterKind) -> ReportTemplate {
        switch kind {
        case .sales:
            return ReportTemplate(
                name: L("Sales call"),
                context: L("We are a sales agency; the client is always the other party."),
                fields: [
                    ReportField(name: L("Client profile"),
                                instruction: L("Who the client is: company, role, how they found us")),
                    ReportField(name: L("What they need"),
                                instruction: L("The problem in their words, and how urgent it is")),
                    ReportField(name: L("Objections")),
                    ReportField(name: L("Next steps"),
                                instruction: L("Who does what, by when")),
                ])
        case .hiring:
            return ReportTemplate(
                name: L("Hiring interview"),
                context: L("We are hiring; the candidate is the other party."),
                fields: [
                    ReportField(name: L("Background"),
                                instruction: L("Current role, years of experience, what they built")),
                    ReportField(name: L("Evidence for the role"),
                                instruction: L("Concrete examples that show they can do this job")),
                    ReportField(name: L("Concerns")),
                    ReportField(name: L("Recommendation"),
                                instruction: L("Proceed, hold or pass, and why")),
                ])
        case .support:
            return ReportTemplate(
                name: L("Support call"),
                context: L("We are the support team; the customer is the other party."),
                fields: [
                    ReportField(name: L("The problem"),
                                instruction: L("What is broken, since when, and what it blocks")),
                    ReportField(name: L("What we tried")),
                    ReportField(name: L("Resolved or open")),
                    ReportField(name: L("Follow-up owed"),
                                instruction: L("What we promised, to whom, by when")),
                ])
        case .blank:
            return ReportTemplate(name: L("New template"), fields: [ReportField(name: "")])
        }
    }

    enum StarterKind: CaseIterable {
        case sales, hiring, support, blank
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
