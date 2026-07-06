import AppKit
import SwiftUI
import ServiceManagement

/// The Settings window.
struct SettingsView: View {
    let onHotkeyChanged: () -> Void

    @ObservedObject private var loc = Localization.shared
    @StateObject private var capture = KeyCapture()
    @State private var hotkeyName = Settings.shared.hotkeyName
    @State private var unsafeKey = !KeyNames.isSafeHotkey(Settings.shared.hotkeyKeyCode)
    @State private var language = Settings.shared.language
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hotkeyMode = Settings.shared.hotkeyMode
    @State private var insertMethod = Settings.shared.insertMethod
    @State private var promptText = Settings.shared.prompt
    @State private var modelReady = WhisperEngine.shared.isModelDownloaded(tier: Settings.shared.modelTier)
    @State private var downloadingModel = false
    @State private var modelProgress = 0.0

    private var languageOptions: [(code: String, name: String)] { LanguageList.options }

    var body: some View {
        Form {
            Section(L("Interface language")) {
                Picker(L("Language"), selection: Binding(
                    get: { loc.language },
                    set: { loc.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
            }

            Section(L("Recognition")) {
                if modelReady {
                    Label(L("Model ready"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if downloadingModel {
                    if modelProgress < 0.999 {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: modelProgress)
                            Text(Lf("Downloaded %d of %d MB", Int(modelProgress * 950), 950))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Preparing the model for the Neural Engine… A few minutes, one time."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button(L("Download model")) { downloadModel() }
                }
                Text(L("Network access: a one-time model download — nothing else. Don't take our word for it: turn off Wi-Fi and dictate."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker(L("Spoken language"), selection: $language) {
                    Text(L("Automatic (detect any language)")).tag("")
                    ForEach(languageOptions, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .onChange(of: language) { Settings.shared.language = $0 }
            }

            Section(L("Vocabulary hint")) {
                TextField("", text: $promptText, axis: .vertical)
                    .lineLimit(2...4)
                    .onChange(of: promptText) { Settings.shared.prompt = $0 }
                Text(L("Names, terms, jargon — comma-separated. Helps recognition spell them right."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Keys")) {
                HStack {
                    Text(L("Dictation")).foregroundStyle(.secondary)
                    Spacer()
                    KeyCap(name: KeyNames.displayName(hotkeyName))
                    Button(capture.capturing ? L("Press a key… (Esc to cancel)") : L("Change")) {
                        capture.begin()
                    }
                    .disabled(capture.capturing)
                }
                .onReceive(capture.$capturedKeyCode) { code in
                    guard let code, let name = capture.capturedName else { return }
                    Settings.shared.hotkeyKeyCode = code
                    Settings.shared.hotkeyName = name
                    hotkeyName = name
                    unsafeKey = !KeyNames.isSafeHotkey(code)
                    onHotkeyChanged()
                }
                if unsafeKey {
                    Label(L("This key types characters — they'll go into the text during dictation. A modifier or F-key is better."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Picker(L("Key mode"), selection: $hotkeyMode) {
                    Text(L("Hold to talk (push-to-talk)")).tag(HotkeyMode.pushToTalk)
                    Text(L("Tap to start, tap to stop")).tag(HotkeyMode.toggle)
                }
                .onChange(of: hotkeyMode) { Settings.shared.hotkeyMode = $0 }

                TranslateKeyPicker(onChanged: onHotkeyChanged, spokenLanguage: language)
            }

            Section(L("Text insertion")) {
                Picker(L("Text insertion"), selection: $insertMethod) {
                    Text(L("Paste (Cmd+V)")).tag(InsertMethod.paste)
                    Text(L("Type character by character")).tag(InsertMethod.type)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .onChange(of: insertMethod) { Settings.shared.insertMethod = $0 }
                Text(L("Paste is faster; typing works in fields that block paste."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Startup")) {
                Toggle(L("Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section(L("Permissions")) {
                PermissionStatusLine(title: L("Microphone"), status: Permissions.microphone)
                PermissionStatusLine(title: L("Accessibility"), status: Permissions.accessibility)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
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

private struct PermissionStatusLine: View {
    let title: String
    let status: Permissions.Status

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if status == .granted {
                Label(L("Granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label(L("No"), systemImage: "xmark.circle").foregroundStyle(.red)
            }
        }
    }
}
