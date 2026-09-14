import Foundation
import Network
import UserNotifications

/// Writes reports: the queue, the call to the agent, the file, the notices.
///
/// One job at a time, in order. A job is a meeting and a template; it comes
/// from the end of a call (the automatic template), from a meeting's ⋯ menu
/// (any template, no threshold), or from the editor's "Report N past
/// meetings". The queue is on disk, so a call that ended while this Mac was
/// offline is still reported after a relaunch — and it waits, rather than
/// failing, until the connection returns.
///
/// Nothing here touches the on-device model: a report is the agent's work,
/// on the person's own key, and it needs nothing but the transcript and a
/// connection.
@MainActor
final class MeetingReports: ObservableObject {
    static let shared = MeetingReports()

    /// Why a job exists — it decides who gets told when it lands.
    enum Reason: String, Codable, Sendable {
        case automatic, onDemand, archive
    }

    /// Where one meeting's report stands, for the pane and the list row.
    enum Phase: Equatable, Sendable {
        case queued
        case writing
        case waitingForConnection
        case failed(AskFailureKind)
    }

    struct Job: Codable, Equatable, Sendable {
        let path: String
        let templateID: UUID
        let reason: Reason
        let keepExisting: Bool
        var url: URL { URL(fileURLWithPath: path) }
    }

    /// An archive-wide run, for the progress line in the list column.
    struct ArchiveRun: Equatable, Sendable {
        let templateName: String
        let total: Int
        var done: Int
    }

    /// Posted on the main queue whenever a meeting's report lands, fails or
    /// starts waiting; `userInfo["url"]` names the meeting, `["title"]` its
    /// name, `["phase"]` one of "written", "waiting", "failed".
    static let changed = Notification.Name("dictate.reportChanged")
    /// Posted when a macOS notification about a report is clicked.
    static let open = Notification.Name("dictate.openMeeting")

    /// Calls shorter than this get no automatic report: a shorter one has
    /// no room for four fields, and the summary already covers it. On
    /// demand has no threshold.
    static let automaticMinimum: TimeInterval = 5 * 60

    /// Longer than this and the transcript is cut, with a note, before it
    /// goes out — the same ceiling the agent's own reading tool has.
    static let transcriptCap = 120_000

    @Published private(set) var phases: [URL: Phase] = [:]
    /// Bumped each time a report lands on disk — the library's cue to reload.
    @Published private(set) var written = 0
    @Published private(set) var archiveRun: ArchiveRun?

    private var queue: [Job] = [] { didSet { persist() } }
    private var pumping = false
    private var monitor: NWPathMonitor?
    private let queueURL: URL
    private let notifier = ReportNotifier()

    init(queueURL: URL? = nil) {
        self.queueURL = queueURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
            .appendingPathComponent("report-queue.json")
        load()
        for job in queue { phases[job.url] = .queued }
    }

    // MARK: - Entry points

    /// The automatic report, if there is to be one. Called once the call's
    /// finishing touches — title, summary — are on disk.
    func callEnded(url: URL) {
        guard Settings.shared.reportAutomatic, Settings.shared.askProvider != nil,
              let template = ReportTemplateStore.shared.automatic, template.isUsable
        else { return }
        guard !Settings.shared.reportsPausedForBilling else {
            Log.d("report: automatic skipped — paused after a billing refusal")
            return
        }
        guard let meeting = MeetingArchive.meeting(at: url, youLabel: L("You")) else { return }
        guard (meeting.duration ?? 0) >= Self.automaticMinimum else {
            Log.d("report: automatic skipped — under \(Int(Self.automaticMinimum / 60)) minutes")
            return
        }
        enqueue(Job(path: url.path, templateID: template.id, reason: .automatic, keepExisting: false))
    }

    /// One report now, from the ⋯ menu. Goes to the front of the queue —
    /// the person is looking at this meeting.
    func write(_ url: URL, with template: ReportTemplate) {
        queue.removeAll { $0.path == url.path }
        queue.insert(Job(path: url.path, templateID: template.id, reason: .onDemand, keepExisting: false), at: 0)
        phases[url] = .queued
        pump()
    }

    /// Every meeting given, in order — the editor's archive run.
    func reportArchive(_ meetings: [ArchivedMeeting], with template: ReportTemplate, keepExisting: Bool) {
        let jobs = meetings
            .filter { !$0.entries.isEmpty }
            .filter { !(keepExisting && $0.report?.templateID == template.id) }
            .map { Job(path: $0.url.path, templateID: template.id, reason: .archive, keepExisting: keepExisting) }
        guard !jobs.isEmpty else { return }
        archiveRun = ArchiveRun(templateName: template.name, total: jobs.count, done: 0)
        for job in jobs {
            queue.removeAll { $0.path == job.path }
            phases[job.url] = .queued
        }
        queue.append(contentsOf: jobs)
        pump()
    }

    /// Stops the archive run; what is already written stays.
    func cancelArchiveRun() {
        let dropped = queue.filter { $0.reason == .archive }
        queue.removeAll { $0.reason == .archive }
        for job in dropped where phases[job.url] == .queued { phases[job.url] = nil }
        archiveRun = nil
    }

    /// Whether something is queued or being written for this meeting.
    func isBusy(_ url: URL) -> Bool {
        switch phases[url] {
        case .queued, .writing, .waitingForConnection: return true
        default: return false
        }
    }

    /// The ask-first card was answered: ask macOS, or don't.
    func allowNotifications(_ allow: Bool) {
        Settings.shared.reportNotificationsAsked = true
        guard allow else { return }
        notifier.requestAuthorization()
    }

    // MARK: - The queue

    private func enqueue(_ job: Job) {
        guard !queue.contains(where: { $0.path == job.path }) else { return }
        queue.append(job)
        phases[job.url] = .queued
        pump()
    }

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
        let provider = Settings.shared.askProvider ?? .anthropic
        let oracle: MeetingOracle = provider == .openai ? OpenAIAPIOracle() : ClaudeAPIOracle()
        guard let template = ReportTemplateStore.shared.template(id: job.templateID), template.isUsable else {
            finish(job, phase: nil)
            return
        }
        guard let meeting = MeetingArchive.meeting(at: url, youLabel: L("You")) else {
            Log.d("report: \(url.lastPathComponent) is gone, dropped")
            finish(job, phase: nil)
            return
        }
        if job.keepExisting, meeting.report?.templateID == template.id {
            finish(job, phase: nil)
            return
        }
        guard oracle.isAvailable else {
            finish(job, phase: .failed(.badKey), meeting: meeting)
            return
        }
        phases[url] = .writing
        let request = Self.request(for: meeting, template: template,
                                   language: Settings.shared.reportLanguage ?? Localization.shared.effective)
        Log.d("report: writing “\(template.name)” for \(url.lastPathComponent) with \(provider.productName)")
        do {
            let answers = try await oracle.report(request)
            let fields = template.usableFields
            let report = MeetingReport(
                templateID: template.id, templateName: template.name,
                writer: provider.productName, written: Date(),
                answers: zip(fields, answers).map { .init(field: $0.name, text: $1) })
            guard MeetingArchive.setReport(report, heading: L("Report"), in: url) else {
                finish(job, phase: .failed(.other), meeting: meeting)
                return
            }
            Settings.shared.reportsPausedForBilling = false
            written += 1
            Log.d("report: written for \(url.lastPathComponent)")
            finish(job, phase: nil, meeting: meeting, landed: true)
        } catch {
            let kind = AskFailureKind.classify(error)
            Log.d("report: failed for \(url.lastPathComponent): \(kind) — \(error.localizedDescription)")
            switch kind {
            case .offline:
                // Not failed: waiting. The job stays at the head of the
                // queue and the network monitor restarts the pump.
                phases[url] = .waitingForConnection
                announce(url, meeting: meeting, phase: "waiting")
                if job.reason == .automatic {
                    TopNotice.show(Lf("Report for “%@” is waiting for a connection.", Self.name(of: meeting)))
                }
                waitForConnection()
            case .outOfCredit:
                Settings.shared.reportsPausedForBilling = true
                finish(job, phase: .failed(kind), meeting: meeting)
            case .badKey:
                // As the answer pane does: a key the vendor rejects is
                // removed, undoably, so nothing is retried with it.
                _ = APIKey.store(nil, for: provider)
                finish(job, phase: .failed(kind), meeting: meeting)
            case .rateLimited, .other:
                finish(job, phase: .failed(kind), meeting: meeting)
            }
        }
    }

    /// Takes the job off the queue and records how it ended. `phase` nil
    /// means the report is there (or the job was moot) and the row shows
    /// the file, not a state.
    private func finish(_ job: Job, phase: Phase?, meeting: ArchivedMeeting? = nil, landed: Bool = false) {
        queue.removeAll { $0 == job }
        phases[job.url] = phase
        if job.reason == .archive, var run = archiveRun {
            run.done += 1
            archiveRun = queue.contains { $0.reason == .archive } ? run : nil
        }
        guard let meeting else { return }
        if landed {
            announce(job.url, meeting: meeting, phase: "written")
            if job.reason == .automatic {
                notifier.notify(title: L("Report written"), body: Self.name(of: meeting), url: job.url)
            }
        } else if case .failed(let kind) = phase ?? .queued, job.reason == .automatic {
            announce(job.url, meeting: meeting, phase: "failed")
            notifier.notify(title: L("Report not written"),
                            body: Self.failureLine(kind, provider: Settings.shared.askProvider ?? .anthropic),
                            url: job.url)
        } else if phase != nil {
            announce(job.url, meeting: meeting, phase: "failed")
        }
    }

    private func announce(_ url: URL, meeting: ArchivedMeeting, phase: String) {
        NotificationCenter.default.post(name: Self.changed, object: nil,
                                        userInfo: ["url": url, "title": Self.name(of: meeting), "phase": phase])
    }

    /// One line for a failure, provider-neutral apart from the vendor's
    /// name, shared by the pane and the notification.
    static func failureLine(_ kind: AskFailureKind, provider: AIProvider) -> String {
        switch kind {
        case .outOfCredit:
            return Lf("Your %@ account refused the request for billing reasons.", provider.vendorName)
        case .badKey:
            return L("The saved key no longer works. It has been removed from the Keychain.")
        case .rateLimited:
            return Lf("%@ is rate limiting. Nothing was lost — write it from the ⋯ menu in a minute.", provider.vendorName)
        case .offline:
            return L("This Mac was offline when the call ended.")
        case .other:
            return L("The model stopped before the report was finished.")
        }
    }

    static func name(of meeting: ArchivedMeeting) -> String {
        meeting.title ?? meeting.url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Waiting for the network

    private func waitForConnection() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.monitor?.cancel()
                    self.monitor = nil
                    Log.d("report: connection is back, resuming")
                    for job in self.queue where self.phases[job.url] == .waitingForConnection {
                        self.phases[job.url] = .queued
                    }
                    self.pump()
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.monitor = monitor
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

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: queueURL),
              let jobs = try? JSONDecoder().decode([Job].self, from: data) else { return }
        queue = jobs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: queueURL)
        } else if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: queueURL, options: .atomic)
        }
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

/// The macOS notification for a report that landed, or did not, while
/// nobody was at the screen. The app's first system notification: it is
/// asked for only after the app's own card has explained why (design:
/// Notices › permission), and never for anything else.
@MainActor
final class ReportNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        // A bundle identity is what the notification center keys on; a bare
        // test binary has none and the framework traps rather than errors.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.d("report: notifications \(granted ? "allowed" : "not allowed")\(error.map { " — \($0.localizedDescription)" } ?? "")")
        }
    }

    func notify(title: String, body: String, url: URL) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["path": url.path]
        let request = UNNotificationRequest(identifier: "report-" + url.lastPathComponent,
                                            content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.d("report: notification not shown — \(error.localizedDescription)") }
        }
    }

    // Shown even while the app is frontmost: the meetings window may be
    // on another Space, and the notification is the only line that says it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        let url = URL(fileURLWithPath: path)
        await MainActor.run {
            NotificationCenter.default.post(name: MeetingReports.open, object: nil, userInfo: ["url": url])
        }
    }
}
