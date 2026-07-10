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
    @State private var micUID = Settings.shared.micUID
    @State private var micDevices = AudioInputDevices.all()
    @State private var replacements = Settings.shared.replacements
    @State private var removeFillers = Settings.shared.removeFillers

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
                Picker(L("Spoken language"), selection: $language) {
                    Text(L("Automatic (detect any language)")).tag("")
                    ForEach(languageOptions, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
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
            } header: { Text(L("Dictation")) } footer: {
                if micUID != "" {
                    Text(L("Bluetooth mics take seconds to start and record in phone-call quality — the built-in mic is faster and more accurate."))
                        .font(.caption).foregroundStyle(.secondary)
                }
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

                if language != "en" {
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
                        rowLabel(L("Translation key"),
                                 L("Hold this instead of the dictation key — your speech comes out in English."))
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
                TextField("", text: $promptText, axis: .vertical)
                    .lineLimit(2...4)
                    .onChange(of: promptText) { Settings.shared.prompt = $0 }
            } header: { Text(L("Vocabulary hint")) } footer: {
                Text(L("Names, terms, jargon — comma-separated. Helps recognition spell them right."))
            }

            // — Replacements —
            Section {
                ForEach(replacements.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        TextField(L("Heard"), text: replacementBinding(i, 0))
                        Image(systemName: "arrow.right")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField(L("Insert"), text: replacementBinding(i, 1))
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
                Text(L("Exact fixes applied to the recognized text: names, brands, acronyms."))
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
                            Text(Lf("Downloaded %d of %d MB", Int(modelProgress * 950), 950))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        Button(L("Download model")) { downloadModel() }.controlSize(.small)
                    }
                }
                LabeledContent(L("Microphone")) {
                    statusBadge(ok: Permissions.microphone == .granted,
                                text: Permissions.microphone == .granted ? L("Granted") : L("No"))
                }
                LabeledContent(L("Accessibility")) {
                    statusBadge(ok: Permissions.accessibility == .granted,
                                text: Permissions.accessibility == .granted ? L("Granted") : L("No"))
                }
            } header: { Text(L("Status")) } footer: {
                Text(L("Network access: a one-time model download — nothing else. Don't take our word for it: turn off Wi-Fi and dictate."))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 580)
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
        let tier = Settings.shared.modelTier
        Task {
            try? await WhisperEngine.shared.prepare(tier: tier) { p in
                DispatchQueue.main.async { modelProgress = p }
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
