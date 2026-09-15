import SwiftUI
import AppKit

/// Library › Reports (design 9.1 collection): one template's reports, full
/// width — what is written, then the meetings that could have one — with
/// writing for a selection. The collection replaces the list and the
/// reading pane while a Reports row is chosen; opening a written row
/// brings the three columns back at that meeting with the report open.
///
/// A view over facts the library owns: the meetings, the templates, the
/// phases of reports in flight. Every action is handed back up, because
/// the library is what writes, exports and navigates.
struct ReportsCollection: View {
    /// nil: "All reports" — nothing chosen yet, the collection names what
    /// it is for and offers the templates.
    let templateName: String?
    /// The template as it stands in Settings; nil when the name only lives
    /// in the archive (the template was removed — its reports stay).
    let template: ReportTemplate?
    /// Every template a chip can offer: the store's, plus names present in
    /// the archive only, with their counts.
    let kinds: [(name: String, count: Int)]
    let meetings: [ArchivedMeeting]
    let phases: [URL: MeetingReports.Phase]
    /// Whether the agent can write at all (a provider with a key).
    let canWrite: Bool
    @Binding var selected: Set<URL>
    let onPickTemplate: (String) -> Void
    let onOpen: (ArchivedMeeting) -> Void
    /// The meetings to write for — the library asks its question (the
    /// batch dialog) and then writes.
    let onWrite: ([ArchivedMeeting]) -> Void
    let onExport: () -> Void
    let onEditTemplate: () -> Void

    /// The row last clicked without ⌘/⇧ — the anchor of a ⇧-range.
    @State private var anchor: URL?
    /// "No report yet" arrives collapsed (design turn 33, Collapse): one
    /// line with its count and Write all; the arrow reveals the meetings.
    @State private var missingOpen = false

    // MARK: - Facts

    private var written: [ArchivedMeeting] {
        guard let templateName else { return [] }
        return meetings.filter { $0.reports.contains { $0.templateName == templateName } }
    }

    /// Meetings without this report, the ones in flight excluded — they
    /// are shown among the written rows while they write.
    private var missing: [ArchivedMeeting] {
        guard let templateName else { return [] }
        return meetings.filter { meeting in
            !meeting.reports.contains { $0.templateName == templateName }
                && !isInFlight(meeting.url)
        }
    }

    private func phase(_ url: URL) -> MeetingReports.Phase? {
        guard let phase = phases[url], phase.templateName == templateName else { return nil }
        return phase
    }

    private func isInFlight(_ url: URL) -> Bool {
        switch phase(url) {
        case .queued, .writing: return true
        default: return false
        }
    }

    private var inFlight: [ArchivedMeeting] { meetings.filter { isInFlight($0.url) } }
    private var failed: [ArchivedMeeting] {
        meetings.filter { if case .failed = phase($0.url) { return true } else { return false } }
    }
    private var batchRunning: Bool { !inFlight.isEmpty }

    /// The rows in the order they are shown — what a ⇧-click ranges over.
    private var rowOrder: [URL] { (inFlight + written + missing).map(\.url) }

    var body: some View {
        VStack(spacing: 0) {
            if templateName == nil {
                pickHeader
                Divider()
                pickBody
            } else if written.isEmpty, !batchRunning, failed.isEmpty {
                emptyHeader
                Divider()
                emptyBody
            } else {
                listHeader
                Divider()
                listBody
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: templateName) { selected = []; anchor = nil; missingOpen = false }
    }

    // MARK: - No template chosen (collectionNone)

    private var pickHeader: some View {
        header(title: L("All reports"),
               subtitle: Lf("%d written across %d templates",
                            kinds.reduce(0) { $0 + $1.count }, kinds.filter { $0.count > 0 }.count))
    }

    private var pickBody: some View {
        VStack(spacing: 12) {
            Text(L("Pick a template"))
                .font(.system(size: 15, weight: .semibold))
            Text(L("Each template keeps its own reports: what is written, and the meetings that could have one. Templates themselves are edited in Settings › Templates."))
                .modifier(Blurb())
            HStack(spacing: 8) {
                ForEach(kinds, id: \.name) { kind in
                    Button("\(kind.name) · \(kind.count)") { onPickTemplate(kind.name) }
                        .buttonStyle(.dsSmall)
                }
            }
        }
        .padding(EdgeInsets(top: 40, leading: 60, bottom: 40, trailing: 60))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Nothing written yet (collectionEmpty)

    private var emptyHeader: some View {
        header(title: templateName ?? "",
               subtitle: Lf("None written · %d fields", template?.usableFields.count ?? 0)) {
            if template != nil {
                Button(L("Edit template…")) { onEditTemplate() }.buttonStyle(.dsSmall)
            }
        }
    }

    private var emptyBody: some View {
        VStack(spacing: 12) {
            Text(L("Nothing written from this template yet"))
                .font(.system(size: 15, weight: .semibold))
            Text(Lf("A report is written on demand — from a meeting’s card, or for a selection here. Each one sends that meeting’s transcript to %@ on your key and is kept inside the meeting’s file.",
                    (Settings.shared.askProvider ?? .anthropic).vendorName))
                .modifier(Blurb())
            if template != nil, canWrite {
                Button(L("Write for a selection…")) { onWrite(selectedMeetings(fallback: missing)) }
                    .buttonStyle(.dsPrimary)
            }
        }
        .padding(EdgeInsets(top: 40, leading: 60, bottom: 40, trailing: 60))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The list (collection · collectionSelection · collectionWriting)

    private var listHeader: some View {
        let subtitle: String
        if !selected.isEmpty {
            subtitle = Lf("%d of %d selected · %d meetings without one",
                          selected.count, rowOrder.count, missing.count)
        } else if batchRunning {
            subtitle = Lf("%d written · writing %d · %d not written",
                          written.count, inFlight.count, failed.count)
        } else {
            subtitle = Lf("%d written · %d meetings without one · %d fields",
                          written.count, missing.count, template?.usableFields.count ?? 0)
        }
        return header(title: templateName ?? "", subtitle: subtitle) {
            if template != nil, canWrite {
                if selected.isEmpty {
                    Button(L("Write for a selection…")) { onWrite(selectedMeetings(fallback: missing)) }
                        .buttonStyle(.dsSmall)
                } else {
                    Button(Lf("Write %d reports…", selected.count)) { onWrite(selectedMeetings(fallback: [])) }
                        .buttonStyle(.dsPrimary)
                }
            }
            if !written.isEmpty {
                Button(L("Export reports…")) { onExport() }.buttonStyle(.dsSmall)
            }
            if template != nil {
                Button(L("Edit template…")) { onEditTemplate() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accentText)
                    .pointerStyle(.link)
            }
        }
    }

    private var listBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                groupLabel(L("Written"))
                ForEach(inFlight, id: \.url) { meeting in
                    row(meeting, snippet: nil, trailing: .writing)
                }
                ForEach(written, id: \.url) { meeting in
                    row(meeting, snippet: snippet(for: meeting), trailing: .date)
                }
                if !batchRunning, !missing.isEmpty || !failed.isEmpty {
                    HStack(spacing: 8) {
                        Button { missingOpen.toggle() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: missingOpen ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                                Text(Lf("No report yet · %d meetings", missing.count))
                                    .font(DS.sectionLabel)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if template != nil, canWrite, missing.count > 1 {
                            Button(Lf("Write all %d…", missing.count)) { onWrite(missing) }
                                .buttonStyle(.dsSmall).controlSize(.small)
                        }
                    }
                    .padding(EdgeInsets(top: 14, leading: 18, bottom: 6, trailing: 18))
                    .overlay(alignment: .top) { Divider() }
                    if missingOpen {
                        ForEach(missing, id: \.url) { meeting in
                            thinRow(meeting)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var footer: some View {
        Text(batchRunning
             ? L("A refusal stops that meeting only; the rest continue.")
             : L("Every report is kept inside its meeting’s file."))
            .font(.system(size: 11))
            .lineSpacing(2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
    }

    // MARK: - Rows

    private enum Trailing { case date, writing }

    /// A written (or writing) row: title, the first field as a two-line
    /// snippet, the date. Plain click opens the meeting; ⌘ and ⇧ select.
    private func row(_ meeting: ArchivedMeeting, snippet: String?, trailing: Trailing) -> some View {
        let isSelected = selected.contains(meeting.url)
        let failure: String? = {
            if case .failed = phase(meeting.url) {
                return L("Report not written — the request was refused. The meeting has the detail.")
            }
            return nil
        }()
        return Button {
            click(meeting.url) { onOpen(meeting) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(of: meeting))
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let failure {
                        Text(failure)
                            .font(.system(size: 11.5)).lineSpacing(2)
                            .foregroundStyle(DS.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if trailing == .writing {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(width: 220, height: 9)
                            .shimmering()
                    } else if let snippet {
                        Text(snippet)
                            .font(.system(size: 11.5)).lineSpacing(2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if failure != nil {
                    Button(L("Write again")) { onWrite([meeting]) }
                        .buttonStyle(.dsSmall).controlSize(.small)
                } else if trailing == .writing {
                    Text(L("Writing…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .shimmering()
                } else {
                    Text(dayLabel(meeting.started))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(selected: isSelected))
        .padding(.horizontal, 8)
    }

    /// A meeting without the report: the title, the date, and Write —
    /// or, after a refusal, the fact and Write again.
    private func thinRow(_ meeting: ArchivedMeeting) -> some View {
        let isSelected = selected.contains(meeting.url)
        let refused: Bool = { if case .failed = phase(meeting.url) { return true } else { return false } }()
        return Button {
            click(meeting.url) { selected = [meeting.url]; anchor = meeting.url }
        } label: {
            HStack(spacing: 12) {
                Text(refused ? Lf("%@ · report not written", title(of: meeting)) : title(of: meeting))
                    .font(.system(size: 13))
                    .foregroundStyle(refused ? DS.warn : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(dayLabel(meeting.started))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if template != nil, canWrite {
                    Button(refused ? L("Write again") : L("Write")) { onWrite([meeting]) }
                        .buttonStyle(.dsSmall).controlSize(.small)
                }
            }
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(selected: isSelected))
        .padding(.horizontal, 8)
    }

    /// The selected row wears the library's own mark: the tint and the
    /// accent edge (design 13a), never a filled row.
    private func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? DS.selectionTint : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DS.accent)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.sectionLabel)
            .foregroundStyle(.secondary)
            .padding(EdgeInsets(top: 11, leading: 18, bottom: 6, trailing: 18))
    }

    private func header(title: String, subtitle: String,
                        @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            // Tight rows (design turn 33): the title is the only flexible
            // item; every control keeps its width and never wraps.
            HStack(spacing: 10) { actions() }.fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    // MARK: - Selection

    /// ⌘ toggles, ⇧ ranges from the anchor, a plain click does what the
    /// row does on its own.
    private func click(_ url: URL, plain: () -> Void) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
            anchor = url
        } else if flags.contains(.shift), let anchor,
                  let a = rowOrder.firstIndex(of: anchor), let b = rowOrder.firstIndex(of: url) {
            for u in rowOrder[min(a, b)...max(a, b)] { selected.insert(u) }
        } else {
            plain()
        }
    }

    private func selectedMeetings(fallback: [ArchivedMeeting]) -> [ArchivedMeeting] {
        let chosen = meetings.filter { selected.contains($0.url) }
        return chosen.isEmpty ? fallback : chosen
    }

    // MARK: - Words

    private func title(of meeting: ArchivedMeeting) -> String {
        meeting.title ?? DateFormatter.localizedString(from: meeting.started,
                                                       dateStyle: .medium, timeStyle: .short)
    }

    private func snippet(for meeting: ArchivedMeeting) -> String? {
        guard let report = meeting.reports.first(where: { $0.templateName == templateName }) else { return nil }
        return report.answers.first { !$0.isEmpty }?.text
    }

    /// "Today", "Yesterday", else the short date — the library's list
    /// speaks the same way.
    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private struct Blurb: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Writing for a selection (design 9.1 batchOff / batchOn)

/// The one question before a batch: how many transcripts leave, to whom,
/// and whether the reports already written are replaced — off by default,
/// because replacing cannot be undone.
struct ReportBatchDialog: View {
    let template: ReportTemplate
    let meetings: [ArchivedMeeting]
    let onWrite: ([ArchivedMeeting]) -> Void
    let onCancel: () -> Void

    @State private var replace = false

    private var haveOne: [ArchivedMeeting] {
        meetings.filter { $0.reports.contains { $0.templateID == template.id || $0.templateName == template.name } }
    }
    private var toWrite: [ArchivedMeeting] {
        replace ? meetings : meetings.filter { m in !haveOne.contains { $0.url == m.url } }
    }
    private var words: Int {
        toWrite.reduce(0) { total, meeting in
            total + meeting.entries.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
        }
    }

    var body: some View {
        let vendor = (Settings.shared.askProvider ?? .anthropic).vendorName
        VStack(spacing: 12) {
            Text(meetings.count == 1
                 ? Lf("Write a “%@” report for “%@”?", template.name,
                      meetings[0].title ?? DateFormatter.localizedString(from: meetings[0].started, dateStyle: .medium, timeStyle: .short))
                 : Lf("Write a “%@” report for %d meetings?", template.name, meetings.count))
                .font(.system(size: 14.5, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(Lf("Sends %d transcripts to %@ on your key — about %@ words. Each report is kept inside its own meeting’s file. The recordings never leave this Mac.",
                    toWrite.count, vendor, words.formatted(.number)))
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !haveOne.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle(Lf("Replace the %d that already have one", haveOne.count), isOn: $replace)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                    Text(replace
                         ? Lf("The %d existing reports are overwritten. This cannot be undone.", haveOne.count)
                         : Lf("Off, those %d are skipped and %d reports are written. Replacing cannot be undone.",
                              haveOne.count, toWrite.count))
                        .font(.system(size: 11))
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 22)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
            HStack(spacing: 9) {
                Button(L("Cancel")) { onCancel() }
                    .buttonStyle(.dsWide)
                    .keyboardShortcut(.cancelAction)
                Button(Lf("Write %d", toWrite.count)) { onWrite(toWrite) }
                    .buttonStyle(.dsWidePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(toWrite.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 18, trailing: 24))
        .frame(width: 440)
    }
}
