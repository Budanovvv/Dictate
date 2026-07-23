import SwiftUI

/// Dictation-language chooser for ~112 Whisper languages. A flat 112-row Picker
/// fails every large-list UX guideline, so this is a bordered button that opens a
/// searchable popover. Research-backed choices (NN/g, Smashing, flagsarenotlanguages):
///   • endonyms (native names) as the primary label — users scan for their own script;
///   • "Automatic (any language)" pinned at the very top, never buried under "A";
///   • the system language surfaced under "Suggested", then the full A→Z list;
///   • search matches native name, English name and code; no flags anywhere.
/// `selection` is the language code; "" means Automatic.
struct LanguagePicker: View {
    @Binding var selection: String
    var tint: Color = .accentColor

    @State private var open = false

    private var label: String {
        selection.isEmpty ? L("Automatic (any language)") : LanguageList.endonym(for: selection)
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if selection.isEmpty {
                    Image(systemName: "globe").foregroundStyle(tint)
                }
                Text(label).fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LanguagePopover(selection: $selection, tint: tint) { open = false }
                .frame(width: 300, height: 380)
        }
    }
}

private struct LanguagePopover: View {
    @Binding var selection: String
    var tint: Color
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
        let selected = code == selection
        Button {
            selection = code
            dismiss()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
                } else {
                    Spacer().frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(native)
                    // Show the English exonym only when it differs from the native
                    // name — a quiet aid without doubling every Latin-script row.
                    if !english.isEmpty && english.lowercased() != native.lowercased() {
                        Text(english).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(tint)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5).padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .background(selected ? tint.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
