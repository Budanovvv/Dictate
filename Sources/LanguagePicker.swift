import SwiftUI

// MARK: - The app's one dropdown

/// Every chooser in Dictate is built from this pair — one trigger button, one
/// list row — so a dropdown looks and behaves identically on every surface.
///
/// SwiftUI's own `Picker` was the alternative and it renders a DIFFERENT
/// control depending on where it lands: inside a grouped Form it collapses to
/// plain text plus a hairline indicator, outside one it is a bordered pop-up.
/// That is how the three language rows in Settings ended up looking like three
/// unrelated widgets. One control, one look, no context surprises.
struct PopupTrigger: View {
    let label: String
    var icon: String?
    let action: () -> Void

    init(label: String, icon: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(Color.accentColor)
                }
                Text(label).fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }
}

/// One row of a dropdown's list: same padding, checkmark and selected-row
/// highlight everywhere.
struct PopupRow: View {
    let title: String
    /// Quiet secondary line (the English exonym next to a native name).
    /// Skipped when it merely repeats the title.
    var subtitle: String = ""
    var icon: String?
    /// Keep the icon's width even without an icon, so rows in a list that has
    /// icons stay aligned.
    var reservesIcon = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 18)
                } else if reservesIcon {
                    Spacer().frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if !subtitle.isEmpty, subtitle.lowercased() != title.lowercased() {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5).padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Choosers

/// Dictation-language chooser for ~112 Whisper languages. A flat 112-row list
/// fails every large-list UX guideline, so this one popover has search.
/// Research-backed choices (NN/g, Smashing, flagsarenotlanguages):
///   • endonyms (native names) as the primary label — users scan for their own script;
///   • "Automatic (any language)" pinned at the very top, never buried under "A";
///   • the system language surfaced under "Suggested", then the full A→Z list;
///   • search matches native name, English name and code; no flags anywhere.
/// `selection` is the language code; "" means Automatic.
struct LanguagePicker: View {
    @Binding var selection: String

    @State private var open = false

    private var label: String {
        selection.isEmpty ? L("Automatic (any language)") : LanguageList.endonym(for: selection)
    }

    var body: some View {
        PopupTrigger(label: label, icon: selection.isEmpty ? "globe" : nil) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                LanguagePopover(selection: $selection) { open = false }
                    .frame(width: 300, height: 380)
            }
    }
}

/// Translate-target chooser for the ~19 curated Apple Translation targets
/// (no search — the list fits on one screen).
struct TranslateTargetPicker: View {
    @Binding var selection: String

    @State private var open = false

    private func label(_ code: String) -> String {
        code == "en" ? "English" : LanguageList.endonym(for: code)
    }

    var body: some View {
        PopupTrigger(label: label(selection)) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(SettingsView.translateTargets, id: \.self) { code in
                            PopupRow(title: label(code), selected: code == selection) {
                                selection = code
                                open = false
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 220, height: 340)
            }
    }
}

/// Interface-language chooser. Same control as the two above — it used to be a
/// bare `Picker` in Settings and a borderless globe menu in onboarding, i.e.
/// two more looks for the same job.
struct InterfaceLanguagePicker: View {
    /// Onboarding shows it as a quiet globe in the corner; Settings as a plain
    /// labelled row control.
    var showsGlobe = false

    @ObservedObject private var loc = Localization.shared
    @State private var open = false

    var body: some View {
        PopupTrigger(label: loc.language.label, icon: showsGlobe ? "globe" : nil) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(AppLanguage.allCases) { lang in
                            PopupRow(title: lang.label, selected: lang == loc.language) {
                                loc.setLanguage(lang)
                                open = false
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 220, height: 340)
            }
    }
}

private struct LanguagePopover: View {
    @Binding var selection: String
    var dismiss: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// System language as a suggestion (skip if it's English — that's already
    /// obvious and would just duplicate a top row for most users).
    private var suggested: [String] {
        let sys = LanguageList.systemDefaultCode
        return (sys.isEmpty || sys == "en") ? [] : [sys]
    }

    private var filtered: [(code: String, native: String, english: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return LanguageList.display }
        return LanguageList.display.filter {
            $0.native.lowercased().contains(q)
                || $0.english.lowercased().contains(q)
                || $0.code.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search language…"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        row(code: "", native: L("Automatic (any language)"),
                            english: L("detect while you speak"), icon: "globe")
                        divider()
                        if !suggested.isEmpty {
                            sectionLabel(L("Suggested"))
                            ForEach(suggested, id: \.self) { c in
                                row(code: c, native: LanguageList.endonym(for: c),
                                    english: LanguageList.name(for: c))
                            }
                            divider()
                        }
                    }
                    ForEach(filtered, id: \.code) { item in
                        row(code: item.code, native: item.native, english: item.english)
                    }
                    if filtered.isEmpty && !query.isEmpty {
                        Text(L("No language matches your search."))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
                .padding(6)
            }
        }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private func row(code: String, native: String, english: String, icon: String? = nil) -> some View {
        PopupRow(title: native, subtitle: english, icon: icon, reservesIcon: true,
                 selected: code == selection) {
            selection = code
            dismiss()
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
    }

    private func divider() -> some View {
        Divider().padding(.vertical, 4)
    }
}
