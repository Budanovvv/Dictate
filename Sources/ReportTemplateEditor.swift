import AppKit
import SwiftUI

/// The template editor: a sheet on the Settings window. Left, the templates
/// and the dot for the automatic one; right, the chosen template — its name,
/// the Context, the field rows (name + instruction, drag to reorder, remove)
/// and Add field. Every keystroke is saved: the file is a few kilobytes and
/// a Save button would be the one control in Settings that lies about the
/// others (design: ReportTemplates › editor).
struct ReportTemplateEditor: View {
    @ObservedObject private var store = ReportTemplateStore.shared
    @ObservedObject private var reports = MeetingReports.shared
    @ObservedObject private var loc = Localization.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selection: UUID?
    @State private var draft: ReportTemplate?
    @State private var showStarters = false
    @State private var confirmRemove = false
    @State private var confirmArchive = false
    @State private var keepExisting = true
    @State private var archiveCount = 0
    @State private var archiveMeetings: [ArchivedMeeting] = []
    @State private var automatic = Settings.shared.reportAutomatic
    @FocusState private var focusedField: UUID?

    init(select: UUID? = nil) {
        _selection = State(initialValue: select)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 200)
                Divider()
                if let draft {
                    editor(draft)
                } else {
                    empty
                }
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .onAppear {
            if selection == nil { selection = store.automatic?.id ?? store.templates.first?.id }
            load()
            if store.templates.isEmpty { showStarters = true }
        }
        .onChange(of: selection) { load() }
        .onChange(of: draft) { _, now in
            guard let now, now.id == selection else { return }
            store.save(now)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            if automatic != Settings.shared.reportAutomatic { automatic = Settings.shared.reportAutomatic }
        }
        .sheet(isPresented: $showStarters) {
            StarterPicker { kind in
                let template = ReportTemplate.starter(kind)
                store.save(template)
                selection = template.id
                load()
            }
        }
        .confirmationDialog(Lf("Remove “%@”?", draft?.name ?? ""), isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button(L("Remove template"), role: .destructive) {
                if let id = draft?.id {
                    store.remove(id: id)
                    selection = store.templates.first?.id
                    load()
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Reports already written with it stay in their meetings."))
        }
        .confirmationDialog(archiveTitle, isPresented: $confirmArchive, titleVisibility: .visible) {
            Button(Lf("Report %d meetings", archiveCount)) {
                guard let draft else { return }
                reports.reportArchive(archiveMeetings, with: draft, keepExisting: keepExisting)
            }
            Button(keepExisting ? L("Replace the reports already written")
                                : L("Keep the reports already written")) {
                keepExisting.toggle()
                confirmArchive = true
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(archiveMessage)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Report templates"))
                .font(DS.windowTitle)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 4)
            Text(L("Field names become headings; the model writes under each."))
                .font(DS.helpText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(store.templates) { template in
                        templateRow(template)
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Button {
                showStarters = true
            } label: {
                Label(L("New template"), systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.accentText)
            .padding(16)
            .accessibilityLabel(L("New template"))
        }
        .background(SidebarMaterial())
    }

    private func templateRow(_ template: ReportTemplate) -> some View {
        let selected = template.id == selection
        let isAutomatic = template.id == Settings.shared.reportAutomaticTemplateID
        return Button {
            selection = template.id
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isAutomatic ? DS.accent : Color.clear)
                    .overlay(Circle().strokeBorder(isAutomatic ? Color.clear : Color.primary.opacity(0.2), lineWidth: 1))
                    .frame(width: 7, height: 7)
                    .opacity(isAutomatic && !automatic ? 0.35 : 1)
                Text(template.name.isEmpty ? L("New template") : template.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .background(
            HStack(spacing: 0) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5).fill(DS.accent).frame(width: DS.selectionEdge)
                }
                Rectangle().fill(selected ? DS.selectionTint : .clear)
            }
        )
        .hoverHighlight()
        .clipShape(DS.shape)
        .accessibilityLabel(template.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text(L("No templates yet."))
                .font(DS.windowTitle)
            Text(L("Start from one of these and change anything: four or five fields with instructions, and an example Context."))
                .font(DS.helpText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(L("New template…")) { showStarters = true }
                .buttonStyle(.dsPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor

    private func editor(_ template: ReportTemplate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("", text: binding(template, \.name), prompt: Text(L("Template name")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityLabel(L("Template name"))

                automaticRow(template)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(L("Context")).font(DS.sectionLabel)
                        Text(L("· optional, applies to the whole template"))
                            .font(DS.helpText).foregroundStyle(.secondary)
                    }
                    TextField("", text: binding(template, \.context),
                              prompt: Text(L("Who “we” are and what to look for")), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .accessibilityLabel(L("Context"))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Fields")).font(DS.sectionLabel)
                    fieldsList(template)
                    Button {
                        var updated = template
                        let field = ReportField(name: "")
                        updated.fields.append(field)
                        draft = updated
                        focusedField = field.id
                    } label: {
                        Label(L("Add field"), systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accentText)
                    .padding(.top, 2)
                    Text(L("A field with no instruction goes by its name alone. A field the call did not cover reads “Not discussed”."))
                        .font(DS.helpText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
    }

    private func automaticRow(_ template: ReportTemplate) -> some View {
        let marked = template.id == Settings.shared.reportAutomaticTemplateID
        return VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(
                get: { marked },
                set: { on in store.setAutomatic(id: on ? template.id : nil) }
            )) {
                Text(L("Runs after every call"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!automatic)
            if !automatic {
                Text(L("Automatic reports are off in Settings."))
                    .font(DS.helpText)
                    .foregroundStyle(.secondary)
            } else if marked {
                Text(L("The one template that runs after every call. Marking another moves the dot."))
                    .font(DS.helpText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fieldsList(_ template: ReportTemplate) -> some View {
        List {
            ForEach(template.fields) { field in
                fieldRow(field, template: template)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
            }
            .onMove { from, to in
                var updated = template
                updated.fields.move(fromOffsets: from, toOffset: to)
                draft = updated
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: CGFloat(max(template.fields.count, 1)) * 34 + 8)
    }

    private func fieldRow(_ field: ReportField, template: ReportTemplate) -> some View {
        let index = template.fields.firstIndex { $0.id == field.id } ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("", text: fieldBinding(index, \.name), prompt: Text(L("Field name")))
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .focused($focusedField, equals: field.id)
                .accessibilityLabel(L("Field name"))
            TextField("", text: fieldBinding(index, \.instruction), prompt: Text(L("Instruction (optional)")))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L("Instruction (optional)"))
            Button {
                var updated = template
                updated.fields.removeAll { $0.id == field.id }
                draft = updated
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Remove field"))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Lf("Reports are written in %@ (Settings › Agent). Field names stay exactly as typed.",
                        (Settings.shared.reportLanguage ?? Localization.shared.effective).label))
                    .font(DS.helpText)
                    .foregroundStyle(.secondary)
                if let run = reports.archiveRun {
                    Text(Lf("Writing “%@” reports: %d of %d.", run.templateName, run.done, run.total))
                        .font(DS.helpText)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let draft, draft.isUsable {
                if reports.archiveRun != nil {
                    Button(L("Cancel · keeps the written")) { reports.cancelArchiveRun() }
                        .buttonStyle(.dsSmall).controlSize(.small)
                } else {
                    Button(L("Report past meetings…")) { prepareArchiveRun(draft) }
                        .buttonStyle(.dsSmall).controlSize(.small)
                        .disabled(Settings.shared.askProvider == nil)
                    Button(L("Export reports…")) { ReportExport.exportAll(template: draft) }
                        .buttonStyle(.dsSmall).controlSize(.small)
                }
                Button(L("Remove template…")) { confirmRemove = true }
                    .buttonStyle(.dsSmall).controlSize(.small)
            }
            Button(L("Done")) { dismiss() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var archiveTitle: String {
        guard let draft else { return "" }
        return Lf("Report %d past meetings with “%@”?", archiveCount, draft.name)
    }

    private var archiveMessage: String {
        let vendor = (Settings.shared.askProvider ?? .anthropic).vendorName
        var text = Lf("Sends %d whole transcripts to %@ on your key. Runs in the background; you can keep working.",
                      archiveCount, vendor)
        let already = archiveMeetings.filter { $0.report?.templateID == draft?.id }.count
        if already > 0 {
            text += "\n\n" + (keepExisting
                ? Lf("Keeping the %d already written with this template.", already)
                : Lf("Replacing the %d already written with this template.", already))
        }
        return text
    }

    private func prepareArchiveRun(_ template: ReportTemplate) {
        let youLabel = L("You")
        DispatchQueue.global(qos: .userInitiated).async {
            let meetings = MeetingArchive.list(youLabel: youLabel).filter { !$0.entries.isEmpty }
            DispatchQueue.main.async {
                archiveMeetings = meetings
                archiveCount = meetings.count
                keepExisting = true
                confirmArchive = !meetings.isEmpty
            }
        }
    }

    // MARK: - Bindings

    private func load() {
        draft = selection.flatMap { store.template(id: $0) }
    }

    private func binding<T>(_ template: ReportTemplate,
                            _ path: WritableKeyPath<ReportTemplate, T>) -> Binding<T> {
        Binding(
            get: { draft?[keyPath: path] ?? template[keyPath: path] },
            set: { value in draft?[keyPath: path] = value }
        )
    }

    private func fieldBinding(_ index: Int, _ path: WritableKeyPath<ReportField, String>) -> Binding<String> {
        Binding(
            get: {
                guard let draft, draft.fields.indices.contains(index) else { return "" }
                return draft.fields[index][keyPath: path]
            },
            set: { value in
                guard var updated = draft, updated.fields.indices.contains(index) else { return }
                updated.fields[index][keyPath: path] = value
                draft = updated
            }
        )
    }
}

/// "New template": four starters, each a name, its fields and an example
/// Context. Blank is the fourth.
private struct StarterPicker: View {
    let choose: (ReportTemplate.StarterKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: ReportTemplate.StarterKind = .sales

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("New template")).font(DS.windowTitle)
            Text(L("Start from one of these and change anything: four or five fields with instructions, and an example Context."))
                .font(DS.helpText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ForEach(ReportTemplate.StarterKind.allCases, id: \.self) { kind in
                    let template = ReportTemplate.starter(kind)
                    Button {
                        picked = kind
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: picked == kind ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(picked == kind ? DS.accent : .secondary)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name).fontWeight(.medium)
                                if kind == .blank {
                                    Text(L("One empty field. You name it."))
                                        .font(DS.helpText).foregroundStyle(.secondary)
                                } else {
                                    Text(template.fields.map(\.name).joined(separator: " · "))
                                        .font(DS.helpText).foregroundStyle(.secondary)
                                    Text(Lf("Context: %@", template.context))
                                        .font(DS.helpText).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(8)
                    }
                    .buttonStyle(.plain)
                    .background(picked == kind ? DS.selectionTint : .clear)
                    .clipShape(DS.shape)
                }
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .buttonStyle(.dsRegular)
                    .keyboardShortcut(.cancelAction)
                Button(L("Create")) {
                    choose(picked)
                    dismiss()
                }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// The ask-first moment before macOS's own permission dialog: shown once,
/// when automatic reports are first turned on. Not now means macOS is never
/// asked (design: Notices › permission).
struct ReportNotificationAskCard: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .font(.system(size: 26))
                .foregroundStyle(DS.accent)
            Text(L("Dictate will tell you when a report is written while you're away."))
                .font(.system(size: 14.5, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(L("Reports are written after a call ends, sometimes hours later if this Mac was offline. A notification says when one lands or could not be written. macOS asks next."))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                Button(L("Not now")) {
                    MeetingReports.shared.allowNotifications(false)
                    dismiss()
                }
                .buttonStyle(.dsWide)
                .keyboardShortcut(.cancelAction)
                Button(L("Allow notifications")) {
                    MeetingReports.shared.allowNotifications(true)
                    dismiss()
                }
                .buttonStyle(.dsWidePrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(22)
        .frame(width: 404)
    }
}
