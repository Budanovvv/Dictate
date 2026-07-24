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
    /// Per-model state for the Models section. The downloads are fully
    /// independent — one row, one decision, one progress line — so they're
    /// keyed by row id (a ModelTier raw value, or `polishRow`) instead of the
    /// old single "is everything this configuration needs there?" flag.
    private static let polishRow = "polish"
    @State private var modelDownloading: Set<String> = []
    @State private var modelProgress: [String: Double] = [:]
    @State private var fastReady = WhisperEngine.shared.isModelDownloaded(tier: .fast)
    @State private var downloadError: String?
    @State private var livePreview = Settings.shared.livePreview
    @State private var translateTarget = Settings.shared.translateTargetCode
    /// State of the chosen pair's translation data (reported by
    /// TranslatePrepareView): ready / missing / fetching.
    @State private var translateDataState: TranslateDataState = .ready
    /// Target codes whose English-hub pack is on the Mac (drives the
    /// "Translation languages" list in the Models section).
    @State private var installedTranslateTargets: Set<String> = []
    @State private var polishEnabled = Settings.shared.polishEnabled
    @State private var polishStyle = Settings.shared.polishStyle
    @State private var polishReady = PolishEngine.isModelDownloaded

    /// Curated translate targets (Apple Translation's supported set, common
    /// ones). English first — the default. Shared with onboarding.
    static let translateTargets = [
        "en", "es", "pt", "fr", "de", "it", "nl", "pl", "tr", "uk", "ru",
        "ar", "hi", "id", "th", "vi", "zh", "ja", "ko",
    ]
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

                // Target of the translate key. Every target — English included
                // — is a transcription plus Apple's on-device Translation.
                if language != "en" || translateSet {
                    Picker(L("Translate to"), selection: $translateTarget) {
                        ForEach(Self.translateTargets, id: \.self) { code in
                            Text(code == "en" ? "English" : LanguageList.endonym(for: code)).tag(code)
                        }
                    }
                    .onChange(of: translateTarget) { Settings.shared.translateTargetCode = $0 }

                    // macOS keeps each language pair's data on demand; picking
                    // a language above pops the system's own download sheet —
                    // the one flow for fetching it (a duplicate Download button
                    // here only confused). The row appears only while something
                    // is wrong or in flight — a green "Ready" line for the
                    // normal case is noise. Re-picking the language re-offers
                    // the sheet.
                    if translateDataState != .ready {
                        LabeledContent(L("Translation data")) {
                            if translateDataState == .fetching {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(L("Not downloaded"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: { Text(L("Language")) } footer: {
                if language != "en" || translateSet {
                    Text(L("The translate key transcribes your speech, then macOS translates it on this Mac. Picking a language may download its translation data once."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

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

                Toggle(L("Live text while recording"), isOn: $livePreview)
                    .onChange(of: livePreview) { Settings.shared.livePreview = $0 }

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
                        rowLabel(L("Translate key"), translateKeyHint)
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

            // — AI polish (opt-in: costs disk and per-dictation latency) —
            Section {
                Toggle(L("Polish results with on-device AI"), isOn: $polishEnabled)
                    .onChange(of: polishEnabled) { on in
                        Settings.shared.polishEnabled = on
                        // Deliberately NO silent download here: a toggle must not
                        // start a ~1.9 GB transfer behind the user's back. The
                        // Models section owns that decision; until the model is
                        // there the pipeline simply skips the polish pass, and the
                        // footer below says so.
                        if on, polishReady {
                            Task { try? await PolishEngine.shared.prepare { _ in } }
                        }
                        if !on {
                            Task { await PolishEngine.shared.unload() }   // free ~2 GB of RAM
                        }
                    }
                if polishEnabled {
                    Picker(L("Style"), selection: $polishStyle) {
                        Text(L("Clean up")).tag("clean")
                        Text(L("Formal")).tag("formal")
                        Text(L("Friendly")).tag("friendly")
                    }
                    .onChange(of: polishStyle) { Settings.shared.polishStyle = $0 }
                }
            } header: { Text(L("AI polish")) } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // Turning the switch on without the model used to trigger a
                    // silent download; now it just does nothing until the model
                    // is fetched, so the state has to be visible.
                    if polishEnabled, !polishReady {
                        Label(L("Model not downloaded — see the Models section below."),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                    Text(L("Fixes grammar and removes filler words with a small language model running entirely on your Mac. Adds a couple of seconds per dictation and ~1.9 GB on disk."))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
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
                    Text(L("Tip: a rule can insert a whole snippet — say “my signature” and get your full sign-off."))
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

            // — Models: every download in one place, one row each. Nothing here
            // starts on its own; the user sees the size before committing.
            Section {
                modelRow(L("Dictation (turbo)"), id: ModelTier.fast.rawValue,
                         sizeMB: ModelTier.fast.sizeMB, ready: fastReady) {
                    downloadWhisper(.fast)
                }
                modelRow(L("AI polish"), id: Self.polishRow,
                         sizeMB: PolishEngine.sizeMB, ready: polishReady) {
                    downloadPolishModel()
                }
                // The macOS translation packs, one status line per language.
                // Read-only by necessity: the packs belong to the system —
                // deleting them is only possible in System Settings, so the
                // button leads there instead of pretending we can.
                DisclosureGroup(L("Translation languages")) {
                    ForEach(Self.translateTargets.filter { $0 != "en" }, id: \.self) { code in
                        LabeledContent(LanguageList.endonym(for: code)) {
                            if installedTranslateTargets.contains(code) {
                                statusBadge(ok: true, text: L("Downloaded"))
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Button(L("Manage in System Settings…")) {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                    }
                    .controlSize(.small)
                }
            } header: { Text(L("Models")) } footer: {
                if downloadError != nil {
                    // A ~1 GB download can genuinely break mid-way — never fail
                    // silently back to the Download button.
                    Label(L("Download failed. Check your connection and retry."),
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange).font(.caption)
                }
            }

            // — Status (read-only) —
            Section {
                LabeledContent(L("Microphone")) {
                    statusBadge(ok: micGranted, text: micGranted ? L("Granted") : L("No"))
                }
                LabeledContent(L("Accessibility")) {
                    statusBadge(ok: axGranted, text: axGranted ? L("Granted") : L("No"))
                }
            } header: { Text(L("Status")) } footer: {
                Text(L("Network access: a one-time model download — nothing else. Don't take our word for it: turn off Wi-Fi and dictate."))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 580)
        // Deliberately hung off the root view instead of sitting in the Form:
        // a Form row is rebuilt on every redraw of the form — including the
        // redraw the picker itself causes — and the rebuild killed the
        // translation session together with the macOS download dialog it had
        // just opened. Here the position in the hierarchy never changes, so
        // the view keeps its identity and its session (see TranslatePrepareView).
        .background {
            TranslatePrepareView(targetCode: translateTarget,
                                 sourceCode: language.isEmpty ? nil : language,
                                 reload: 0,
                                 onState: {
                                     translateDataState = $0
                                     // A finished pack changes the languages list below.
                                     if $0 == .ready { refreshModelStatuses() }
                                 })
        }
        // The window is cached and lives for the whole session: statuses read
        // once at creation would show stale permissions and miss new mics.
        // Re-read whenever the user comes back to the app.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            micDevices = AudioInputDevices.all()
            micGranted = Permissions.microphone == .granted
            axGranted = Permissions.accessibility == .granted
            launchAtLogin = SMAppService.mainApp.status == .enabled
            refreshModelStatuses()
        }
        .onAppear { refreshModelStatuses() }
        .onDisappear {
            captureMain.cancel()
            captureTranslate.cancel()
        }
    }

    /// The English wording is worth its own string — "in English" is the case
    /// that needs no language name and reads best without one.
    private var translateKeyHint: String {
        translateTarget == "en"
            ? L("Hold to talk in your language, release to insert it in English.")
            : Lf("Hold to talk in your language, release to insert it in %@.",
                 LanguageList.endonym(for: translateTarget))
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

    /// One row of the Models section: Ready badge, live megabytes while it
    /// downloads, or a Download button that states the size up front.
    @ViewBuilder
    private func modelRow(_ title: String, id: String, sizeMB: Int, ready: Bool,
                          download: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if ready {
                statusBadge(ok: true, text: L("Ready"))
            } else if modelDownloading.contains(id) {
                let p = modelProgress[id] ?? 0
                if p < 0.999 {
                    Text(Lf("Downloaded %d of %d MB", Int(p * Double(sizeMB)), sizeMB))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    // Downloaded; the model is being loaded and compiled for the
                    // Neural Engine — no progress callback exists for that phase.
                    ProgressView().controlSize(.small)
                }
            } else {
                Button(Lf("Download (%d MB)", sizeMB), action: download).controlSize(.small)
            }
        }
    }

    private func refreshModelStatuses() {
        fastReady = WhisperEngine.shared.isModelDownloaded(tier: .fast)
        polishReady = PolishEngine.isModelDownloaded
        Task {
            var installed: Set<String> = []
            for code in Self.translateTargets where code != "en" {
                if await AppleTranslator.isInstalled(from: "en", to: code) {
                    installed.insert(code)
                }
            }
            let done = installed
            await MainActor.run { installedTranslateTargets = done }
        }
    }

    private func downloadPolishModel() {
        let id = Self.polishRow
        guard !modelDownloading.contains(id) else { return }
        modelDownloading.insert(id)
        modelProgress[id] = 0
        downloadError = nil
        Task {
            do {
                try await PolishEngine.shared.prepare { p in
                    DispatchQueue.main.async { modelProgress[id] = p }
                }
            } catch {
                Log.d("polish: download failed: \(error.localizedDescription)")
                await MainActor.run { downloadError = error.localizedDescription }
            }
            await MainActor.run {
                modelDownloading.remove(id)
                polishReady = PolishEngine.isModelDownloaded
            }
        }
    }

    /// Downloads one Whisper tier on demand. prepare() also loads it into
    /// memory afterwards, so the first dictation doesn't pay for the compile.
    private func downloadWhisper(_ tier: ModelTier) {
        let id = tier.rawValue
        guard !modelDownloading.contains(id) else { return }
        modelDownloading.insert(id)
        modelProgress[id] = 0
        downloadError = nil
        Task {
            do {
                try await WhisperEngine.shared.prepare(tier: tier) { p in
                    DispatchQueue.main.async { modelProgress[id] = p }
                }
            } catch {
                Log.d("model: \(tier.rawValue) download failed: \(error.localizedDescription)")
                await MainActor.run { downloadError = error.localizedDescription }
            }
            await MainActor.run {
                modelDownloading.remove(id)
                refreshModelStatuses()
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
