import Foundation

/// Writes reports: one at a time, on demand, from a meeting's card.
///
/// A job is a meeting and a template. The agent is asked, the answer goes
/// into the meeting's file, and the library is told to reload. Nothing here
/// touches the on-device model: a report is the agent's work, on the
/// person's own key, and it needs nothing but the transcript and a
/// connection.
@MainActor
final class MeetingReports: ObservableObject {
    static let shared = MeetingReports()

    /// Where one meeting's report stands, for the card and the list row.
    enum Phase: Equatable, Sendable {
        case queued
        case writing
        case failed(AskFailureKind)
    }

    private struct Job: Equatable {
        let url: URL
        let template: ReportTemplate
    }

    /// Longer than this and the transcript is cut, with a note, before it
    /// goes out — the same ceiling the agent's own reading tool has.
    static let transcriptCap = 120_000

    @Published private(set) var phases: [URL: Phase] = [:]
    /// Bumped each time a report lands on disk — the library's cue to reload.
    @Published private(set) var written = 0

    private var queue: [Job] = []
    private var pumping = false

    private init() {}

    /// One report now. A meeting already in the queue is replaced, not
    /// queued twice.
    func write(_ url: URL, with template: ReportTemplate) {
        queue.removeAll { $0.url == url }
        queue.append(Job(url: url, template: template))
        phases[url] = .queued
        pump()
    }

    /// Whether something is queued or being written for this meeting.
    func isBusy(_ url: URL) -> Bool {
        switch phases[url] {
        case .queued, .writing: return true
        default: return false
        }
    }

    // MARK: - The queue

    private func pump() {
        guard !pumping, let job = queue.first else { return }
        pumping = true
        Task { @MainActor in
            defer { pumping = false }
            await run(job)
            pump()
        }
    }

    private func run(_ job: Job) async {
        let url = job.url
        defer { queue.removeAll { $0 == job } }
        let provider = Settings.shared.askProvider ?? .anthropic
        let oracle: MeetingOracle = provider == .openai ? OpenAIAPIOracle() : ClaudeAPIOracle()
        guard job.template.isUsable,
              let meeting = MeetingArchive.meeting(at: url, youLabel: L("You")) else {
            phases[url] = nil
            return
        }
        guard oracle.isAvailable else {
            phases[url] = .failed(.badKey)
            return
        }
        phases[url] = .writing
        let request = Self.request(for: meeting, template: job.template,
                                   language: Settings.shared.reportLanguage ?? Localization.shared.effective)
        Log.d("report: writing “\(job.template.name)” for \(url.lastPathComponent) with \(provider.productName)")
        do {
            let answers = try await oracle.report(request)
            let fields = job.template.usableFields
            let report = MeetingReport(
                templateID: job.template.id, templateName: job.template.name,
                writer: provider.productName, written: Date(),
                answers: zip(fields, answers).map { .init(field: $0.name, text: $1) })
            guard MeetingArchive.setReport(report, heading: L("Report"), in: url) else {
                phases[url] = .failed(.other)
                return
            }
            // And as a file of its own, in the archive's Reports folder —
            // what "Open" and "Show in Finder" on the card point at.
            var reported = meeting
            reported.report = report
            ReportExport.writeFile(for: reported, report: report)
            phases[url] = nil
            written += 1
            Log.d("report: written for \(url.lastPathComponent)")
        } catch {
            let kind = AskFailureKind.classify(error)
            Log.d("report: failed for \(url.lastPathComponent): \(kind) — \(error.localizedDescription)")
            // As the answer pane does: a key the vendor rejects is removed,
            // undoably, so nothing is retried with it.
            if kind == .badKey { _ = APIKey.store(nil, for: provider) }
            phases[url] = .failed(kind)
        }
    }

    /// One line for a failure, provider-neutral apart from the vendor's name.
    static func failureLine(_ kind: AskFailureKind, provider: AIProvider) -> String {
        switch kind {
        case .outOfCredit:
            return Lf("Your %@ account refused the request for billing reasons.", provider.vendorName)
        case .badKey:
            return L("The saved key no longer works. It has been removed from the Keychain.")
        case .rateLimited:
            return Lf("%@ is rate limiting. Nothing was lost — try again in a minute.", provider.vendorName)
        case .offline:
            return L("This Mac is offline. Nothing was sent — try again when the connection returns.")
        case .other:
            return L("The model stopped before the report was finished.")
        }
    }

    static func name(of meeting: ArchivedMeeting) -> String {
        meeting.title ?? meeting.url.deletingPathExtension().lastPathComponent
    }

    // MARK: - The request

    /// What the model is asked, in one place — so both vendors are asked
    /// the same thing, and the wording can be tuned against real reports.
    static func request(for meeting: ArchivedMeeting, template: ReportTemplate,
                        language: AppLanguage) -> ReportRequest {
        let context = template.context.trimmingCharacters(in: .whitespacesAndNewlines)
        var instructions = """
            You write a structured report of one recorded conversation, by \
            filling in a form whose fields the reader defined. The reader took \
            part in the conversation; their own turns are labelled "\(L("You"))".
            """
        if !context.isEmpty {
            instructions += "\n\nContext from the reader, which tells you who \"we\" are and what matters: \(context)"
        }
        instructions += """
            \n
            For each field, write only what the transcript supports, guided by \
            the field's instruction or, if it has none, by its name. Where the \
            wording matters, quote the speaker. The recognition is imperfect and \
            the people are real: do not move a constraint from one person's side \
            to another's, and where the text does not settle who owed what to \
            whom, say that instead of choosing.

            If the conversation did not cover a field, return an empty string \
            for it — never a sentence saying it was not discussed, and never \
            something invented to fill the space.

            Write in \(language.englishName). Plain prose, short paragraphs; a \
            list only where the content genuinely is a list. No headings, and \
            do not repeat the field's name inside its text.
            """

        let dateLine = meeting.started.formatted(date: .long, time: .shortened)
        var head = "Meeting: \(name(of: meeting))\nDate: \(dateLine)"
        if let duration = meeting.duration {
            head += "\nLength: \(Int(duration / 60)) minutes"
        }
        if let source = meeting.source { head += "\nPlatform: \(source)" }
        var transcript = head + "\n\nTranscript:\n"
            + meeting.entries.map { "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        if transcript.count > transcriptCap {
            let dropped = transcript.count - transcriptCap
            transcript = String(transcript.prefix(transcriptCap))
                + "\n[Transcript truncated here — \(dropped) more characters were recorded after this point.]"
        }
        return ReportRequest(instructions: instructions, transcript: transcript,
                             fields: template.usableFields)
    }
}

extension AppLanguage {
    /// The language's name in English — what a model is told to write in.
    var englishName: String {
        switch self {
        case .system: return Localization.systemLanguage.englishName
        case .en: return "English"
        case .ru: return "Russian"
        case .uk: return "Ukrainian"
        case .es: return "Spanish"
        case .pt: return "Portuguese"
        case .fr: return "French"
        case .de: return "German"
        case .zh: return "Chinese"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .vi: return "Vietnamese"
        case .tl: return "Filipino"
        }
    }
}

extension MeetingArchive {
    /// One transcript from disk, the same way `list` reads them all.
    static func meeting(at url: URL, youLabel: String) -> ArchivedMeeting? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let created = startedDate(fileName: url.lastPathComponent)
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? Date.distantPast
        return ArchivedMeeting(id: url, url: url, started: created,
                               entries: parse(markdown: text, youLabel: youLabel),
                               title: parseTitle(markdown: text),
                               summary: parseSummary(markdown: text),
                               sections: parseSections(markdown: text),
                               tags: MeetingTags.parse(markdown: text),
                               source: parseSource(markdown: text),
                               report: parseReport(markdown: text))
    }
}
