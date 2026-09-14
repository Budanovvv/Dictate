import AppKit
import SwiftUI

/// The Templates tab of Settings — its own tab, shown once the agent is on,
/// because "reports" is a thing a person goes looking for by name and would
/// not find under Agent. Grouped-form rows like every other tab: which
/// template, then its name, its Context, its fields; every keystroke is
/// saved, as every change in this window takes effect immediately.
struct ReportTemplatesSection: View {
    @ObservedObject private var store = ReportTemplateStore.shared
    @ObservedObject private var loc = Localization.shared

    @State private var selection: UUID?
    @State private var draft: ReportTemplate?
    @State private var chooserOpen = false
    @State private var startersOpen = false
    @State private var confirmRemove = false
    @State private var reportLanguage = Settings.shared.reportLanguage
    @FocusState private var focusedField: UUID?

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    if !store.templates.isEmpty {
                        PopupTrigger(label: draft?.name ?? L("Choose a template")) { chooserOpen.toggle() }
                            .popover(isPresented: $chooserOpen, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(store.templates) { template in
                                        PopupRow(title: template.name,
                                                 subtitle: Lf("%d fields", template.usableFields.count),
                                                 selected: template.id == selection) {
                                            selection = template.id
                                            chooserOpen = false
                                        }
                                    }
                                }
                                .padding(6)
                                .frame(width: 240)
                            }
                    }
                    Button(L("New template…")) { startersOpen.toggle() }
                        .buttonStyle(.dsSmall)
                        .controlSize(.small)
                        .popover(isPresented: $startersOpen, arrowEdge: .bottom) {
                            StarterPicker { kind in
                                let template = ReportTemplate.starter(kind)
                                store.save(template)
                                selection = template.id
                                load()
                                startersOpen = false
                            }
                        }
                }
            } label: {
                rowLabel(L("Template"),
                         L("A form the agent fills in from a transcript: field names become headings, the model writes under each."))
            }
        } header: { Text(L("Templates")) }

        if let draft {
            Section {
                LabeledContent {
                    TextField("", text: binding(draft, \.name), prompt: Text(L("Template name")))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .accessibilityLabel(L("Template name"))
                } label: {
                    rowLabel(L("Name"), nil)
                }
                LabeledContent {
                    TextField("", text: binding(draft, \.context),
                              prompt: Text(L("Who “we” are and what to look for")), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .frame(maxWidth: 420)
                        .accessibilityLabel(L("Context"))
                } label: {
                    rowLabel(L("Context"), L("Optional. One paragraph for the whole template, such as “We are a sales agency; the client is always the other party.”"))
                }
                LabeledContent {
                    fieldsControl(draft)
                } label: {
                    rowLabel(L("Fields"),
                             L("A field with no instruction goes by its name alone. A field the call did not cover reads “Not discussed”."))
                }
            } header: { Text(draft.name.isEmpty ? L("New template") : draft.name) }

            Section {
                LabeledContent {
                    ReportLanguagePicker(selection: $reportLanguage)
                        .onChange(of: reportLanguage) { _, v in Settings.shared.reportLanguage = v }
                } label: {
                    rowLabel(L("Write reports in"),
                             L("Field names stay exactly as typed; only the text under them is written in this language."))
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Button(L("Export reports…")) { ReportExport.exportAll(template: draft) }
                            .buttonStyle(.dsSmall).controlSize(.small)
                        Button(L("Remove template…")) { confirmRemove = true }
                            .buttonStyle(.dsSmall).controlSize(.small)
                    }
                    .confirmationDialog(Lf("Remove “%@”?", draft.name), isPresented: $confirmRemove,
                                        titleVisibility: .visible) {
                        Button(L("Remove template"), role: .destructive) {
                            store.remove(id: draft.id)
                            selection = store.templates.first?.id
                            load()
                        }
                        Button(L("Cancel"), role: .cancel) {}
                    } message: {
                        Text(L("Reports already written with it stay in their meetings."))
                    }
                } label: {
                    rowLabel(L("Written reports"),
                             L("Every report written with this template, one file per meeting: Markdown, plain text or PDF, plus a CSV table."))
                }
            }
        }
        // Invisible plumbing: which template is showing, and saving as you type.
        Color.clear.frame(height: 0)
            .onAppear {
                if selection == nil { selection = store.templates.first?.id }
                load()
            }
            .onChange(of: selection) { load() }
            .onChange(of: store.templates.count) {
                if draft == nil || !store.templates.contains(where: { $0.id == selection }) {
                    selection = store.templates.first?.id
                    load()
                }
            }
            .onChange(of: draft) { _, now in
                guard let now, now.id == selection, store.template(id: now.id) != now else { return }
                store.save(now)
            }
    }

    // MARK: - Fields

    private func fieldsControl(_ template: ReportTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(template.fields.enumerated()), id: \.element.id) { index, field in
                HStack(spacing: 6) {
                    TextField("", text: fieldBinding(index, \.name), prompt: Text(L("Field name")))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .focused($focusedField, equals: field.id)
                        .accessibilityLabel(L("Field name"))
                    TextField("", text: fieldBinding(index, \.instruction),
                              prompt: Text(L("Instruction (optional)")))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                        .accessibilityLabel(L("Instruction (optional)"))
                    Button { move(index, by: -1) } label: {
                        Image(systemName: "chevron.up").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(index == 0)
                    .accessibilityLabel(L("Move up"))
                    Button { move(index, by: 1) } label: {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(index == template.fields.count - 1)
                    .accessibilityLabel(L("Move down"))
                    Button {
                        var updated = template
                        updated.fields.removeAll { $0.id == field.id }
                        draft = updated
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Remove field"))
                }
            }
            Button {
                var updated = template
                let field = ReportField(name: "")
                updated.fields.append(field)
                draft = updated
                focusedField = field.id
            } label: {
                Label(L("Add field"), systemImage: "plus")
            }
            .buttonStyle(.dsSmall)
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        guard var updated = draft, updated.fields.indices.contains(index),
              updated.fields.indices.contains(index + offset) else { return }
        updated.fields.swapAt(index, index + offset)
        draft = updated
    }

    // MARK: - Plumbing

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

    /// The same row label as the rest of the Settings window.
    private func rowLabel(_ title: String, _ hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let hint {
                Text(hint).font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "New template": four starters in the app's own popup vocabulary — a
/// name, its fields and an example Context. Blank is the fourth.
private struct StarterPicker: View {
    let choose: (ReportTemplate.StarterKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ReportTemplate.StarterKind.allCases, id: \.self) { kind in
                let template = ReportTemplate.starter(kind)
                PopupRow(title: template.name,
                         subtitle: kind == .blank ? L("One empty field. You name it.")
                                                  : template.fields.map(\.name).joined(separator: " · "),
                         selected: false) {
                    choose(kind)
                }
            }
        }
        .padding(6)
        .frame(width: 300)
    }
}
