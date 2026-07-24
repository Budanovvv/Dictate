import AppKit
import SwiftUI
import ServiceManagement

/// The Settings window. Native grouped form: configuration up top,
/// read-only status at the bottom (Apple HIG).
struct SettingsView: View {
    let onHotkeyChanged: () -> Void

    @ObservedObject private var loc = Localization.shared
    @StateObject private var captureMain = KeyCapture()
    @StateObject private var captureTranslate = KeyCapture()
    @State private var hotkeyName = Settings.shared.hotkeyName
    @State private var unsafeKey = !KeyNames.isSafeHotkey(Settings.shared.hotkeyKeyCode)
    @State private var translateName = Settings.shared.translateKeyName
    @State private var translateSet = Settings.shared.translateKeyCode != nil
    @State private var language = Settings.shared.language
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var promptText = Settings.shared.prompt
    @State private var modelReady = WhisperEngine.shared.isModelDownloaded(tier: Settings.shared.modelTier)
    @State private var downloadingModel = false
    @State private var modelProgress = 0.0
    @State private var downloadError: String?
    @State private var micUID = Settings.shared.micUID
    @State private var micDevices = AudioInputDevices.all()
    @State private var micGranted = Permissions.microphone == .granted
    @State private var axGranted = Permissions.accessibility == .granted
    @State private var replacements = Settings.shared.replacements
    @State private var removeFillers = Settings.shared.removeFillers
    @State private var autoStopOnSilence = Settings.shared.autoStopOnSilence
    @State private var prerollEnabled = Settings.shared.prerollEnabled

    private var languageOptions: [(code: String, name: String)] { LanguageList.options }

    /// Language whose command phrases the showcase lists: the spoken language
    /// when set and supported; auto-detect → interface language; else English.
    private var commandsLanguageCode: String {
        if !language.isEmpty {
            return Replacements.commandsByLanguage[language] != nil ? language : "en"
        }
        let ui = loc.effective.rawValue
        return Replacements.commandsByLanguage[ui] != nil ? ui : "en"
    }

    private var commandsLanguageName: String {
        languageOptions.first(where: { $0.code == commandsLanguageCode })?.name ?? "English"
    }

    private func replacementBinding(_ i: Int, _ j: Int) -> Binding<String> {
        Binding(
            get: { i < replacements.count ? replacements[i][j] : "" },
            set: {
                guard i < replacements.count else { return }
                replacements[i][j] = $0
                Settings.shared.replacements = replacements
            }
        )
    }

    var body: some View {
        Form {
            // — Languages: spoken and interface, side by side —
            Section {
                // Same searchable picker as onboarding — a flat 112-row Picker
                // fails every large-list UX guideline (see LanguagePicker).
                LabeledContent(L("Spoken language")) {
                    LanguagePicker(selection: $language)
                }
                .onChange(of: language) { Settings.shared.language = $0 }

                Picker(L("Interface language"), selection: Binding(
                    get: { loc.language }, set: { loc.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { lang in Text(lang.label).tag(lang) }
                }
            } header: { Text(L("Language")) }

            // — Dictation config —
            Section {
                Picker(L("Microphone"), selection: $micUID) {
                    Text(L("Built-in (recommended)")).tag("")
                    Text(L("System default")).tag("system")
                    ForEach(micDevices.filter { !$0.isBuiltIn }, id: \.uid) { dev in
                        Text(dev.isBluetooth ? "⚠️ " + dev.name : dev.name).tag(dev.uid)
                    }
                }
                .onChange(of: micUID) { Settings.shared.micUID = $0 }

                Toggle(L("Remove filler words"), isOn: $removeFillers)
                    .onChange(of: removeFillers) { Settings.shared.removeFillers = $0 }

                Toggle(L("Stop automatically after a pause"), isOn: $autoStopOnSilence)
                    .onChange(of: autoStopOnSilence) { Settings.shared.autoStopOnSilence = $0 }

                Toggle(L("Catch the start of speech (keeps the mic on)"), isOn: $prerollEnabled)
                    .onChange(of: prerollEnabled) {
                        Settings.shared.prerollEnabled = $0
                        PrerollBuffer.shared.refresh()
                    }
            } header: { Text(L("Dictation")) } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if micUID != "" {
                        Text(L("Bluetooth mics take seconds to start and record in phone-call quality — the built-in mic is faster and more accurate."))
                    }
                    if autoStopOnSilence {
                        Text(L("Instead of holding the key the whole time, the recording ends on its own after a short silence."))
                    }
                    if prerollEnabled {
                        Text(L("Keeps a moment of audio buffered so a word begun just before you press isn't lost. The microphone stays on, so the macOS privacy dot stays lit."))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            // — Shortcuts —
            Section {
                LabeledContent {
                    KeyRecorder(keyName: KeyNames.displayName(hotkeyName), capture: captureMain)
                } label: {
                    rowLabel(L("Dictation key"), L("Hold to talk, release to insert what you said."))
                }
                .onReceive(captureMain.$capturedKeyCode) { code in
                    guard let code, let name = captureMain.capturedName,
                          code != Settings.shared.translateKeyCode else { return }
                    Settings.shared.hotkeyKeyCode = code
                    Settings.shared.hotkeyName = name
                    hotkeyName = name
                    unsafeKey = !KeyNames.isSafeHotkey(code)
                    onHotkeyChanged()
                }

                // Visible also when language == "en" but a key is still bound:
                // the binding keeps working regardless of language, so the UI
                // to remove it must not disappear.
                if language != "en" || translateSet {
                    LabeledContent {
                        KeyRecorder(keyName: translateSet ? KeyNames.displayName(translateName) : "",
                                    placeholder: L("Not set"),
                                    capture: captureTranslate,
                                    onClear: translateSet ? {
                                        Settings.shared.translateKeyCode = nil
                                        Settings.shared.translateKeyName = ""
                                        translateSet = false
                                        onHotkeyChanged()
                                    } : nil)
                    } label: {
                        rowLabel(L("Translate key"),
                                 L("Hold to talk in your language, release to insert it in English."))
                    }
                    .onReceive(captureTranslate.$capturedKeyCode) { code in
                        guard let code, let name = captureTranslate.capturedName,
                              code != Settings.shared.hotkeyKeyCode else { return }
                        Settings.shared.translateKeyCode = code
                        Settings.shared.translateKeyName = name
                        translateName = name
                        translateSet = true
                        onHotkeyChanged()
                    }
                }
            } header: { Text(L("Shortcuts")) } footer: {
                if unsafeKey {
                    Label(L("This key types characters — they'll go into the text during dictation. A modifier or F-key is better."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
            }

            // — Vocabulary —
            Section {
                TextEditor(text: $promptText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 52, maxHeight: 96)
                    .onChange(of: promptText) { Settings.shared.prompt = $0 }
            } header: { Text(L("Vocabulary hint")) } footer: {
                Text(L("Names, terms, jargon — comma-separated. Helps recognition spell them right."))
            }

            // — Replacements —
            Section {
                ForEach(replacements.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        LeadingTextField(placeholder: L("Heard"), text: replacementBinding(i, 0))
                        Image(systemName: "arrow.right")
                            .font(.caption).foregroundStyle(.secondary)
                        LeadingTextField(placeholder: L("Insert"), text: replacementBinding(i, 1))
                        Button {
                            replacements.remove(at: i)
                            Settings.shared.replacements = replacements
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    replacements.append(["", ""])
                    Settings.shared.replacements = replacements
                } label: {
                    Label(L("Add replacement"), systemImage: "plus")
                }
                .buttonStyle(.plain)
            } header: { Text(L("Replacements")) } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Exact fixes applied to the recognized text: names, brands, acronyms."))
                    // A typo in a "re:" pattern otherwise fails silently — the
                    // rule just "doesn't work" with no hint why.
                    if let bad = invalidRegexRules.first {
                        Label(Lf("Invalid “re:” pattern — the rule is ignored: %@", bad),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
            }

            // — Voice commands (read-only showcase). You SPEAK the commands,
            // so they follow the spoken language; auto-detect falls back to
            // the interface language, unsupported languages to English.
            Section {
                ForEach(Replacements.commands(for: commandsLanguageCode), id: \.phrase) { cmd in
                    LabeledContent {
                        Text(cmd.output.replacingOccurrences(of: "\n", with: "⏎"))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("«\(cmd.phrase)»")
                    }
                }
            } header: {
                Text(L("Voice commands"))
            } footer: {
                Text(Lf("Commands for: %@. ", commandsLanguageName)
                     + L("Built in and always on — just say the phrase while dictating. A replacement above with the same phrase overrides it."))
            }

            // — General —
            Section {
                Toggle(L("Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            } header: { Text(L("General")) }

            // — Status (read-only) —
            Section {
                LabeledContent(L("Recognition model")) {
                    if modelReady {
                        statusBadge(ok: true, text: L("Ready"))
                    } else if downloadingModel {
                        if modelProgress < 0.999 {
                            let total = Settings.shared.modelTier.sizeMB
                            Text(Lf("Downloaded %d of %d MB", Int(modelProgress * Double(total)), total))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        Button(L("Download model")) { downloadModel() }.controlSize(.small)
                    }
                }
                LabeledContent(L("Microphone")) {
                    statusBadge(ok: micGranted, text: micGranted ? L("Granted") : L("No"))
                }
                LabeledContent(L("Accessibility")) {
                    statusBadge(ok: axGranted, text: axGranted ? L("Granted") : L("No"))
                }
            } header: { Text(L("Status")) } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if downloadError != nil {
                        Label(L("Download failed. Check your connection and retry."),
                              systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.orange).font(.caption)
                    }
                    Text(L("Network access: a one-time model download — nothing else. Don't take our word for it: turn off Wi-Fi and dictate."))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 580)
        // The window is cached and lives for the whole session: statuses read
        // once at creation would show stale permissions and miss new mics.
        // Re-read whenever the user comes back to the app.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            micDevices = AudioInputDevices.all()
            micGranted = Permissions.microphone == .granted
            axGranted = Permissions.accessibility == .granted
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if !downloadingModel {
                modelReady = WhisperEngine.shared.isModelDownloaded(tier: Settings.shared.modelTier)
            }
        }
        .onDisappear {
            captureMain.cancel()
            captureTranslate.cancel()
        }
    }

    /// User "re:" rules whose pattern doesn't compile (surfaced in the footer).
    private var invalidRegexRules: [String] {
        replacements.compactMap { rule in
            guard rule.count == 2 else { return nil }
            let phrase = rule[0].trimmingCharacters(in: .whitespaces)
            guard phrase.hasPrefix("re:") else { return nil }
            let pattern = String(phrase.dropFirst(3))
            let compiles = (try? NSRegularExpression(pattern: pattern,
                                                     options: [.caseInsensitive])) != nil
            return compiles ? nil : phrase
        }
    }

    @ViewBuilder
    private func rowLabel(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusBadge(ok: Bool, text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? .green : .secondary)
            .font(.callout)
    }

    private func downloadModel() {
        downloadingModel = true
        downloadError = nil
        let tier = Settings.shared.modelTier
        Task {
            do {
                try await WhisperEngine.shared.prepare(tier: tier) { p in
                    DispatchQueue.main.async { modelProgress = p }
                }
            } catch {
                // A ~1 GB download can genuinely break mid-way — never fail
                // silently back to the "Download model" button.
                await MainActor.run { downloadError = error.localizedDescription }
            }
            await MainActor.run {
                downloadingModel = false
                modelReady = WhisperEngine.shared.isModelDownloaded(tier: tier)
            }
        }
    }
}

/// Native-style keyboard-shortcut recorder: a bordered token showing the
/// current key; click to record, ⓧ to clear. Pattern from macOS System
/// Settings › Keyboard and Sindre Sorhus's KeyboardShortcuts.
private struct KeyRecorder: View {
    let keyName: String
    var placeholder: String = ""
    @ObservedObject var capture: KeyCapture
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Button {
                capture.begin()
            } label: {
                Text(capture.capturing ? L("Type a key…")
                        : (keyName.isEmpty ? placeholder : keyName))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(keyName.isEmpty && !capture.capturing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(minWidth: 118)
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(capture.capturing ? Color.accentColor.opacity(0.15)
                                                : Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(capture.capturing ? Color.accentColor : .secondary.opacity(0.35),
                                      lineWidth: 1))
            }
            .buttonStyle(.plain)

            if let onClear, !keyName.isEmpty, !capture.capturing {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Remove"))
            }
        }
    }
}

/// Borderless single-line field that types left-to-right. SwiftUI's TextField
/// inside `.formStyle(.grouped)` force-aligns its text to the trailing edge and
/// ignores `.multilineTextAlignment`, so we drop to AppKit for the replacement
/// rows. Transparent + no border → visually matches the surrounding form.
private struct LeadingTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .left
        field.placeholderString = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
