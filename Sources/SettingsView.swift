import AppKit
import SwiftUI
import ServiceManagement

/// The Settings window. Native grouped form: configuration up top,
/// read-only status at the bottom (Apple HIG).
struct SettingsView: View {
    let onHotkeyChanged: () -> Void
    /// Sparkle's manual check — the same call the status menu used to make.
    let onCheckForUpdates: () -> Void

    @ObservedObject private var loc = Localization.shared
    @StateObject private var captureMain = KeyCapture()
    @StateObject private var captureTranslate = KeyCapture()
    /// What is being typed into the key field, and a counter to redraw when the
    /// stored key changes — the Keychain is not observable, so the view needs
    /// telling.
    @State private var askArchive = Settings.shared.askArchive
    @State private var keyDraft = ""
    @State private var keyRevision = 0

    @State private var hotkeyName = Settings.shared.hotkeyName
    @State private var unsafeKey = !KeyNames.isSafeHotkey(Settings.shared.hotkeyKeyCode)
    @State private var translateName = Settings.shared.translateKeyName
    @State private var translateSet = Settings.shared.translateKeyCode != nil
    @State private var language = Settings.shared.language
    @State private var nameFromCalendar = Settings.shared.nameMeetingsFromCalendar
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var promptText = Settings.shared.prompt
    @State private var translateTarget = Settings.shared.translateTargetCode
    /// State of the chosen pair's translation data (reported by
    /// TranslatePrepareView): ready / missing / fetching.
    @State private var translateDataState: TranslateDataState = .ready
    /// Targets that can be translated into RIGHT NOW from the spoken language
    /// (all English-hub legs present) — drives the "Translation languages"
    /// list in Status. Depends on the spoken language, so it is recomputed
    /// whenever that changes.
    @State private var installedTranslateTargets: Set<String> = []

    /// Curated translate targets (Apple Translation's supported set, common
    /// ones). English first — the default. Shared with onboarding.
    static let translateTargets = [
        "en", "es", "pt", "fr", "de", "it", "nl", "pl", "tr", "uk", "ru",
        "ar", "hi", "id", "th", "vi", "zh", "ja", "ko",
    ]
    /// The downloadable text model behind meeting names and section lines.
    @ObservedObject private var textModel = LocalTextModelDownload.shared
    @State private var micGranted = Permissions.microphone == .granted
    @State private var axGranted = Permissions.accessibility == .granted
    @State private var replacements = Settings.shared.replacements
    @State private var removeFillers = Settings.shared.removeFillers

    private var languageOptions: [(code: String, name: String)] { LanguageList.options }

    /// The same string the About panel shows — both read
    /// CFBundleShortVersionString, so the two can never disagree.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

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
            // — Language: what you speak, what it turns into, and only then
            // the language of this window itself —
            Section {
                // Same searchable picker as onboarding — a flat 112-row Picker
                // fails every large-list UX guideline (see LanguagePicker).
                LabeledContent(L("Spoken language")) {
                    LanguagePicker(selection: $language)
                }
                .onChange(of: language) {
                    Settings.shared.language = $0
                    // Which targets are reachable depends on the source leg.
                    refreshStatuses()
                }

                // Target of the translate key. Every target — English included
                // — is a transcription plus Apple's on-device Translation.
                if language != "en" || translateSet {
                    // The same chooser onboarding uses, not a bare Picker: in
                    // this grouped Form a labelled Picker collapses to plain
                    // text plus a hairline indicator — a different species from
                    // the Spoken language row right above, and barely readable
                    // as something clickable.
                    LabeledContent(L("Translate to")) {
                        TranslateTargetPicker(selection: $translateTarget)
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

                // Last in the section on purpose: the spoken language and the
                // translate target get changed far more often than the UI's own
                // language, which is usually set once and forgotten.
                // Same control as the two rows above (see PopupTrigger).
                LabeledContent(L("Interface language")) {
                    InterfaceLanguagePicker()
                }
            } header: { Text(L("Language")) } footer: {
                if language != "en" || translateSet {
                    Text(L("The translate key transcribes your speech, then macOS translates it on this Mac. Picking a language may download its translation data once."))
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

            // — Replacements: everything that happens TO the recognized text,
            // the filler-word cleanup included (it used to sit in a section of
            // its own with nothing to keep it company).
            Section {
                Toggle(L("Remove filler words"), isOn: $removeFillers)
                    .onChange(of: removeFillers) { Settings.shared.removeFillers = $0 }

                // Two more knobs live only in `defaults`, deliberately:
                // livePreview (the live text in the HUD — always on; the
                // escape hatch is for the rare battery-sensitive case) and
                // liveTyping (typing at the cursor — a HIDDEN experiment: the
                // Whisper re-decode architecture bottoms out at ~2.5 s of lag
                // in bursts, honest but not the "it types as I speak" feel;
                // roadmap is a rebuild on SpeechAnalyzer, macOS 26+, whose
                // sub-second partials the CommitEngine/TypeInjector core can
                // consume unchanged). The microphone is not a choice either:
                // micUID stays "" (built-in) because Bluetooth mics take
                // seconds to start and record in phone-call quality.

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
            // Collapsed: this is a reference list you consult once, not a knob.
            // The explanation rides INSIDE the group (as a section footer it
            // would keep three lines on screen for a folded section).
            Section {
                DisclosureGroup(L("Voice commands")) {
                    ForEach(Replacements.commands(for: commandsLanguageCode), id: \.phrase) { cmd in
                        LabeledContent {
                            Text(cmd.output.replacingOccurrences(of: "\n", with: "⏎"))
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("«\(cmd.phrase)»")
                        }
                    }
                    Text(Lf("Commands for: %@. ", commandsLanguageName)
                         + L("Built in and always on — just say the phrase while dictating. A replacement above with the same phrase overrides it."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // — Meetings —
            //
            // One row, and it carries its own permission. Turning it on is what
            // asks macOS for the calendar, which is why the switch snaps back
            // when the request is refused: a switch that stays on while the
            // feature cannot work is a lie the user only discovers at the next
            // meeting.
            Section {
                Toggle(L("Name meetings from my calendar"), isOn: $nameFromCalendar)
                    .onChange(of: nameFromCalendar) { on in
                        guard on else {
                            Settings.shared.nameMeetingsFromCalendar = false
                            return
                        }
                        if MeetingCalendar.hasAccess {
                            Settings.shared.nameMeetingsFromCalendar = true
                            return
                        }
                        Task { @MainActor in
                            let granted = await MeetingCalendar.requestAccess()
                            Settings.shared.nameMeetingsFromCalendar = granted
                            nameFromCalendar = granted
                        }
                    }
                Text(L("A call that was in your calendar is saved under the name you gave it there. Anything unscheduled is still named from what was said. Events are read on this Mac."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text(L("Meetings")) }

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

            // — The downloadable text model —
            //
            // Absent entirely on a Mac that cannot run it (see
            // LocalTextModelFile.isSupported). That is the whole point
            // of hiding the section rather than disabling the button: a
            // greyed-out row invites the question "why not?", and the honest
            // answer is a hardware fact the user cannot change. What such a Mac
            // gets instead is unchanged — Apple's model where the OS provides
            // one, and otherwise meetings keep their date-and-time names.
            if textModel.state != .unsupported {
                Section {
                    // Named by what the user gets, not by what it is. "Text
                    // model" is the implementation: it says nothing about what
                    // the thing does, what it costs or where it runs, and
                    // nobody has ever wanted a text model — they want their
                    // meetings to have names.
                    LabeledContent {
                        textModelControl
                    } label: {
                        rowLabel(L("Meeting titles & summaries"), textModelHint)
                    }
                    // Asking the archive questions. Under the same heading as
                    // the local model on purpose: these are two answers to one
                    // question — how much thinking happens about your meetings
                    // — and the difference between them is where it happens and
                    // who pays. Putting them side by side is the honest way to
                    // present a feature that breaks the app's own rule.
                    LabeledContent {
                        Toggle("", isOn: $askArchive)
                            .labelsHidden()
                            .onChange(of: askArchive) { Settings.shared.askArchive = $0 }
                    } label: {
                        rowLabel(L("Ask about your meetings"),
                                 L("Answers questions across the archive"))
                    }
                    // The key only matters once the feature is on, and a field
                    // for a credential nobody can use yet is a question with no
                    // reason behind it.
                    if askArchive {
                        LabeledContent {
                            apiKeyControl
                        } label: {
                            rowLabel(L("Anthropic API key"), L("Your account, your usage"))
                        }
                    }
                } header: { Text(L("Meetings")) } footer: {
                    // Three facts in the order a person asks for them: what it
                    // does, where it runs (the whole positioning of this app),
                    // what it costs.
                    Text(meetingsFooter)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                // The macOS translation packs, one line per target. A row answers
                // exactly one question: would the translate key work into this
                // language RIGHT NOW, from the language you speak — so the check
                // is the composite, leg-by-leg one the runtime uses, not en→X
                // (for a Russian speaker the ru→en leg matters just as much).
                // Read-only by necessity: the packs belong to the system —
                // removing them is only possible in System Settings, so the
                // button leads there instead of pretending we can.
                DisclosureGroup(L("Translation languages")) {
                    ForEach(Self.translateTargets, id: \.self) { code in
                        LabeledContent(code == "en" ? "English" : LanguageList.endonym(for: code)) {
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
                // The version and "am I current?" on ONE line, because they are
                // one question. Updates are checked daily and installed
                // silently (the app even relaunches itself when idle to apply
                // one), so a manual check is a rare, impatient act — it did not
                // deserve a permanent row in the menu bar's menu, and it does
                // belong next to the number people come here to read.
                LabeledContent(L("Version")) {
                    HStack(spacing: 6) {
                        Text(Self.appVersion)
                        Text("·").foregroundStyle(.tertiary)
                        Button(L("Check for Updates")) { onCheckForUpdates() }
                            .buttonStyle(.link)
                    }
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
                                     if $0 == .ready { refreshStatuses() }
                                 })
        }
        // The window is cached and lives for the whole session: statuses read
        // once at creation would show stale permissions.
        // Re-read whenever the user comes back to the app.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            micGranted = Permissions.microphone == .granted
            axGranted = Permissions.accessibility == .granted
            launchAtLogin = SMAppService.mainApp.status == .enabled
            textModel.refresh()
            refreshStatuses()
        }
        .onAppear {
            textModel.refresh()
            refreshStatuses()
        }
        .onDisappear {
            captureMain.cancel()
            captureTranslate.cancel()
        }
    }

    /// The line under the row's name — only while there is something to gain by
    /// reading it. With nothing downloaded, what is being lost; once the model
    /// is there (or on its way) the state on the right says everything, and a
    /// permanent second line would just be a caption on a finished setting.
    ///
    /// Note the framing: this is an upgrade, not a repair. Meetings are still
    /// saved, still searchable, still transcribed — they are named by their
    /// date instead of their subject.
    private var textModelHint: String? {
        switch textModel.state {
        case .absent, .failed:
            return L("Without it, meetings are saved with the date as their name.")
        default:
            return nil
        }
    }

    /// What this section promises, assembled in one place because the compiler
    /// cannot type-check it inline and because the claim is worth reading whole.
    ///
    /// "Nothing is sent anywhere" was unconditionally true until this section
    /// grew a switch that sends something. Scoping the claim to the local model,
    /// and stating plainly what the switch sends, is the difference between a
    /// promise and a slogan.
    private var meetingsFooter: String {
        var text = Lf("Names your meetings, writes a one-line summary and a table of contents — all on this Mac. One-time download, %@.",
                      LocalTextModelFile.sizeText)
        text += " " + (askArchive
            ? L("Asking is the one thing that leaves: your question and the few passages the search found go to Anthropic on your key. Whole meetings never do, and nothing goes anywhere until you click.")
            : L("Asking questions is off, so nothing about your meetings leaves this Mac."))
        // The same honesty the offer in the meetings window gives: on a Mac
        // with no Metal path this runs on the CPU, measured 13.9 s per passage
        // against 1.1 s.
        if LocalTextModelFile.runsOnCPU {
            text += " " + L("On this Mac it runs on the CPU: about three minutes of background work for a 50-minute meeting.")
        }
        if LocalTextModelFile.isMemoryTight {
            text += " " + L("It holds about 4.7 GB of memory while it writes, which this Mac will feel.")
        }
        return text
    }

    /// The user's own Anthropic key.
    ///
    /// A field rather than a sign-in button, and that is not a shortcut: a
    /// third-party app is not permitted to offer a Claude account login or to
    /// spend somebody's subscription on their behalf. A key is the sanctioned
    /// route, and it has the better property anyway — the person can see what
    /// they are spending and revoke it in one click, on a page we do not own.
    @ViewBuilder
    private var apiKeyControl: some View {
        if let stored = AnthropicKey.current, keyDraft.isEmpty {
            HStack(spacing: 8) {
                statusBadge(ok: true, text: AnthropicKey.masked(stored))
                Button(L("Remove")) {
                    AnthropicKey.store(nil)
                    keyRevision += 1
                }
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                SecureField("sk-ant-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                Button(L("Save")) {
                    AnthropicKey.store(keyDraft)
                    keyDraft = ""
                    keyRevision += 1
                }
                .controlSize(.small)
                .disabled(!AnthropicKey.looksValid(keyDraft))
            }
        }
    }

    /// The right-hand side of the text-model row: one control per state, and
    /// every state says what it is rather than spinning anonymously.
    @ViewBuilder
    private var textModelControl: some View {
        switch textModel.state {
        case .unsupported:
            EmptyView()
        case .absent:
            Button(Lf("Download %@", LocalTextModelFile.sizeText)) { textModel.start() }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                // A determinate bar, because we know the total to the byte. A
                // 2.3 GB download behind a spinner is indistinguishable from a
                // hang, and this one takes minutes.
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(L("Cancel")) { textModel.cancel() }
                    .controlSize(.small)
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("Checking…")).font(.callout).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 8) {
                statusBadge(ok: true, text: L("Ready"))
                Button(L("Remove")) { textModel.remove() }
                    .controlSize(.small)
            }
        case .failed:
            HStack(spacing: 8) {
                Label(L("Download failed. Check your connection and retry."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Retry")) { textModel.start() }
                    .controlSize(.small)
            }
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
    /// A row's name, and under it the one line that explains it — when there is
    /// one. `nil` leaves the row a single line rather than an empty second one.
    private func rowLabel(_ title: String, _ hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(ok: Bool, text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? .green : .secondary)
            .font(.callout)
    }

    /// Re-reads what the window shows but doesn't own: the translation packs
    /// macOS may have gained (or lost) meanwhile.
    private func refreshStatuses() {
        let source = language.isEmpty ? nil : language
        Task {
            var installed: Set<String> = []
            for code in Self.translateTargets {
                if await AppleTranslator.isInstalled(target: code, source: source) {
                    installed.insert(code)
                }
            }
            let done = installed
            await MainActor.run { installedTranslateTargets = done }
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
