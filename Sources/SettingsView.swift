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
    @State private var askProvider = Settings.shared.askProvider
    @State private var keyDraft = ""
    @State private var keyRevision = 0

    @State private var hotkeyName = Settings.shared.hotkeyName
    @State private var unsafeKey = !KeyNames.isSafeHotkey(Settings.shared.hotkeyKeyCode)
    @State private var fKeyChosen = KeyNames.isFunctionKey(Settings.shared.hotkeyKeyCode)
        || KeyNames.isFunctionKey(Settings.shared.translateKeyCode ?? -1)
    @State private var insertByTyping = Settings.shared.insertByTyping
    @State private var appearance = Settings.shared.appearance
    /// macOS said no to the calendar — the switch alone can't explain why it
    /// snapped back off, so a banner does (design: calendarDenied).
    @State private var calendarDenied = false
    @State private var translateName = Settings.shared.translateKeyName
    @State private var translateSet = Settings.shared.translateKeyCode != nil
    @State private var language = Settings.shared.language
    @State private var nameFromCalendar = Settings.shared.nameMeetingsFromCalendar
    @State private var noticeCalls = Settings.shared.noticeCalls
    /// macOS said no to the microphone — the capabilities below can only
    /// WAIT, and must say so rather than pretend to work (design section 9:
    /// blocked-by-macOS is its own kind of off).
    @State private var micDenied = Permissions.microphone == .denied
    @State private var recordCallAudio = Settings.shared.recordCallAudio
    @State private var separateVoices = Settings.shared.separateVoices
    @State private var readMeetings = Settings.shared.readMeetings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showInDock = Settings.shared.showInDock
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

    private var languageOptions: [(code: String, name: String)] { LanguageList.options }

    private var appearanceHelp: String {
        switch appearance {
        case "light":
            return L("Dictate stays light even when macOS switches. Every surface follows: the window, the dictation overlay, the recording pill and the menu.")
        case "dark":
            return L("Dictate stays dark even when macOS switches. Every surface follows: the window, the dictation overlay, the recording pill and the menu.")
        default:
            return L("Follows the macOS setting, switching with it at sunset. Choose Light or Dark to hold Dictate to one appearance regardless of the system.")
        }
    }

    /// The same string the About panel shows — both read
    /// CFBundleShortVersionString, so the two can never disagree.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Sparkle's own record of the last automatic check, formatted for a
    /// sentence. nil until the first check has ever run.
    static var lastUpdateCheck: String? {
        guard let date = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date
        else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    /// The design's four destinations (t6): a source list, not one long form —
    /// a sidebar row just gets wider when a locale runs long, where a tab
    /// label is the first thing long translations break.
    private enum Tab: CaseIterable { case keys, languages, meetings, general }
    @State private var tab: Tab = .keys

    private func tabTitle(_ tab: Tab) -> String {
        switch tab {
        case .keys: return L("Keys")
        case .languages: return L("Languages")
        case .meetings: return L("Meetings")
        case .general: return L("General")
        }
    }

    private func tabIcon(_ tab: Tab) -> String {
        switch tab {
        case .keys: return "keyboard"
        case .languages: return "globe"
        case .meetings: return "video"
        case .general: return "gearshape"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar.frame(width: 196)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(tabTitle(tab)).font(DS.windowTitle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .frame(height: 46)
                Divider()
                sectionForm
            }
        }
        .frame(width: 760, height: 588)

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
            applyRequestedTab()
        }
        // The corner menu can ask for a tab while this window already
        // exists (it is cached for the app's lifetime) — onAppear alone
        // only serves the first opening.
        .onReceive(NotificationCenter.default.publisher(
            for: .init("dictate.openSettings")).receive(on: RunLoop.main)) { _ in
            applyRequestedTab()
        }
        .onDisappear {
            captureMain.cancel()
            captureTranslate.cancel()
        }    }

    /// The sidebar: four rows and the one sentence that replaces an Apply
    /// button. Selection is the tint-plus-edge, never a filled row (13a).
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            Color.clear.frame(height: 40)   // the traffic lights' band
            ForEach(Tab.allCases, id: \.self) { candidate in
                Button {
                    tab = candidate
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tabIcon(candidate))
                            .font(.system(size: 12))
                            .frame(width: 16)
                            .foregroundStyle(tab == candidate ? DS.accentText : .secondary)
                        Text(tabTitle(candidate)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .background(
                    HStack(spacing: 0) {
                        if tab == candidate {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(DS.accent)
                                .frame(width: DS.selectionEdge)
                        }
                        Rectangle().fill(tab == candidate ? DS.selectionTint : .clear)
                    }
                )
                .hoverHighlight()
                .clipShape(DS.shape)
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            Text(L("Every change takes effect immediately."))
                .font(DS.helpText)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
        .background(SidebarMaterial())
    }

    @ViewBuilder
    private var sectionForm: some View {
        switch tab {
        case .keys: Form { keysSection }.formStyle(.grouped)
        case .languages: Form { languagesSection }.formStyle(.grouped)
        case .meetings: Form { meetingsSection }.formStyle(.grouped)
        case .general: Form { generalSection; statusSection }.formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var languagesSection: some View {
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
                    .buttonStyle(.dsSmall)
                    .controlSize(.small)
                }
            } header: { Text(L("Language")) } footer: {
                if language != "en" || translateSet {
                    Text(L("The translate key transcribes your speech, then macOS translates it on this Mac. Picking a language may download its translation data once."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
    }

    @ViewBuilder
    private var keysSection: some View {
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
                    fKeyChosen = KeyNames.isFunctionKey(code)
                        || KeyNames.isFunctionKey(Settings.shared.translateKeyCode ?? -1)
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
                        fKeyChosen = KeyNames.isFunctionKey(code)
                            || KeyNames.isFunctionKey(Settings.shared.hotkeyKeyCode)
                        onHotkeyChanged()
                    }
                }

                // How the recognized text lands (design: "Insert text by").
                // Two honest trade-offs, so a radio pair rather than a toggle
                // that would hide one of them.
                LabeledContent {
                    Picker("", selection: $insertByTyping) {
                        Text(L("Pasting it at once")).tag(false)
                        Text(L("Typing it out character by character")).tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: insertByTyping) { Settings.shared.insertByTyping = $0 }
                } label: {
                    rowLabel(L("Insert text by"),
                             L("Pasting is instant but replaces your clipboard for a moment. Typing works in apps that block paste, such as some terminals and remote desktops."))
                }
            } header: { Text(L("Shortcuts")) } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if unsafeKey {
                        Label(L("This key types characters — they'll go into the text during dictation. A modifier or F-key is better."),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.warn).font(.caption)
                    }
                    // An F-key works, but on most keyboards it is a media key
                    // first — macOS will do both (design: keysWarning).
                    if fKeyChosen {
                        Label(L("F-keys can also trigger a system control (brightness, media) — macOS will do both. To use one as a plain key, turn on “Use F1, F2, etc. as standard function keys” in Keyboard settings."),
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Gone from this window, deliberately (owner's call, 2026-08-27):
            // the vocabulary prompt (a proven footgun — foreign text in it
            // silently empties recognitions, and it even caught a live
            // dictation once), the user replacement rules and the filler-word
            // toggle. Filler cleanup and the built-in voice commands still
            // run — they are how dictation behaves, not something to
            // configure. Other knobs that live only in `defaults`,
            // deliberately: livePreview (the live text in the HUD — always
            // on) and liveTyping (typing at the cursor — a hidden
            // experiment); micUID stays "" (built-in) because Bluetooth mics
            // take seconds to start and record in phone-call quality.
    }

    @ViewBuilder
    private var meetingsSection: some View {
        let _ = refreshMicDenied()
            // — Meetings — ONE section for everything the app can do with a
            // meeting, a row per capability in the order they touch it: name
            // it, understand it, ask about it. They used to be three sections
            // with three headers and three footers — reading as scattered
            // features instead of one; the shared footer now carries the one
            // privacy story all three answer to.
            Section {
                // Everything off is a state worth a sentence, not four silent
                // switches (design MeetingsOff): the banner says what the
                // silence costs and offers the one-click way out.
                if !noticeCalls && !recordCallAudio && !separateVoices && !readMeetings {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("Everything here is off, so calls pass unnoticed"))
                                .font(.system(size: 12.5, weight: .medium))
                            Text(L("Dictation still works. Each switch below says what it adds; you can turn on one and leave the rest alone."))
                                .font(DS.helpText)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(L("Turn all on")) {
                            noticeCalls = true; recordCallAudio = true
                            separateVoices = true; readMeetings = true
                            MeetingCapability.allCases.forEach { OfferLedger.decided($0) }
                        }
                        .buttonStyle(.dsSmall)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
                }
                // Blocked by macOS is drawn as BROKEN, not as off (design
                // section 9): the warning colour, the way out, and switches
                // that say they are waiting instead of pretending to work.
                if micDenied {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(DS.warn)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("macOS denied microphone access"))
                                .font(.system(size: 12.5, weight: .medium))
                            Text(L("Nothing here can hear a call until it is granted in System Settings › Privacy & Security › Microphone."))
                                .font(DS.helpText)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(L("Open Settings")) {
                            Permissions.openSettingsPane("Privacy_Microphone")
                        }
                        .buttonStyle(.dsSmall)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.warn.opacity(0.08)))
                }
                // The meeting capabilities, granular and in the order they
                // touch a call: notice it, record it, tell voices apart, read
                // it (design MeetingsOff). Each why-text says what the switch
                // ADDS, because "on" is a decision about this Mac's ears.
                // Names and why-texts come from the one canonical set
                // (MeetingCapability) — this pane renders them, it does not
                // write them. A hand-flipped switch is a DECISION, which is
                // what retires the capability from ever being offered.
                LabeledContent {
                    Toggle("", isOn: $noticeCalls).labelsHidden().toggleStyle(.switch)
                        .onChange(of: noticeCalls) {
                            Settings.shared.noticeCalls = $0
                            OfferLedger.decided(.noticeCalls)
                        }
                } label: {
                    rowLabel(MeetingCapability.noticeCalls.name,
                             micDenied ? L("Waiting on microphone access.")
                                       : MeetingCapability.noticeCalls.adds,
                             warn: micDenied)
                }
                LabeledContent {
                    Toggle("", isOn: $recordCallAudio).labelsHidden().toggleStyle(.switch)
                        .onChange(of: recordCallAudio) {
                            Settings.shared.recordCallAudio = $0
                            OfferLedger.decided(.recordCallAudio)
                        }
                } label: {
                    rowLabel(MeetingCapability.recordCallAudio.name,
                             micDenied ? L("Waiting on microphone access.")
                                       : MeetingCapability.recordCallAudio.adds,
                             warn: micDenied)
                }
                LabeledContent {
                    Toggle("", isOn: $separateVoices).labelsHidden().toggleStyle(.switch)
                        .disabled(!recordCallAudio)
                        .onChange(of: separateVoices) {
                            Settings.shared.separateVoices = $0
                            OfferLedger.decided(.separateVoices)
                        }
                } label: {
                    rowLabel(MeetingCapability.separateVoices.name,
                             recordCallAudio
                                ? MeetingCapability.separateVoices.adds
                                : Lf("Waits for “%@” above — there is no call audio to separate yet.",
                                     MeetingCapability.recordCallAudio.name))
                        .padding(.leading, 16)
                }
                .opacity(recordCallAudio ? 1 : 0.5)
                LabeledContent {
                    Toggle("", isOn: $readMeetings).labelsHidden().toggleStyle(.switch)
                        .onChange(of: readMeetings) {
                            Settings.shared.readMeetings = $0
                            OfferLedger.decided(.readMeetings)
                        }
                } label: {
                    rowLabel(MeetingCapability.readMeetings.name,
                             MeetingCapability.readMeetings.adds)
                }

                // The calendar row carries its own permission. Turning it on is
                // what asks macOS for the calendar, which is why the switch
                // snaps back when the request is refused: a switch that stays
                // on while the feature cannot work is a lie the user only
                // discovers at the next meeting.
                LabeledContent {
                    Toggle("", isOn: $nameFromCalendar)
                        .labelsHidden()
                        // Inside LabeledContent a toggle defaults to a
                        // checkbox; every other switch in this window is a
                        // switch.
                        .toggleStyle(.switch)
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
                                calendarDenied = !granted
                            }
                        }
                } label: {
                    rowLabel(L("Read meeting names from Calendar"),
                             L("Recordings arrive already titled instead of as “Zoom call, 14:02”. Only titles overlapping a recording are read."))
                }
                // The switch snapping back off is macOS saying no — a banner
                // says so and points at the only place that can change it
                // (design: calendarDenied).
                if calendarDenied {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .foregroundStyle(DS.warn)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("macOS denied calendar access"))
                                .font(.system(size: 12.5, weight: .medium))
                            Text(L("The switch stays off until it is granted in System Settings › Privacy & Security › Calendars. Only event titles that overlap a recording are ever read."))
                                .font(DS.helpText)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(L("Open Settings")) {
                            Permissions.openSettingsPane("Privacy_Calendars")
                        }
                        .buttonStyle(.dsSmall)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.warn.opacity(0.08)))
                }

                // The downloadable text model. The row is absent entirely on a
                // Mac that cannot run it (see LocalTextModelFile.isSupported):
                // a greyed-out row invites the question "why not?", and the
                // honest answer is a hardware fact the user cannot change.
                // Named by what the user gets, not by what it is — nobody has
                // ever wanted a "text model"; they want their meetings to have
                // names.
                // The download row is the machinery of the switch above —
                // with reading off it answers a question nobody asked, so it
                // appears only once the decision is made.
                if textModel.state != .unsupported, readMeetings {
                    LabeledContent {
                        textModelControl
                    } label: {
                        rowLabel(L("Meeting titles & summaries"), textModelHint)
                    }
                }

                // The AI agent — deliberately NOT inside the local-model test
                // above: this runs on the user's API key in the vendor's
                // cloud, so a Mac too small for a local 4B model can still
                // turn on the one capability that does not need it.
                //
                // One control answers both questions — is this on, and with
                // whom. A toggle that then revealed a provider choice would
                // make the person say "yes" before they know to whom; a
                // chooser whose first option is Off keeps consent and choice
                // as the single decision they actually are. The same
                // PopupTrigger as the language rows — a bare Picker rendered
                // as a different species of control here (see LanguagePicker).
                LabeledContent {
                    AskProviderPicker(selection: $askProvider)
                        .onChange(of: askProvider) {
                            Settings.shared.askProvider = $0
                            // A half-typed key for one vendor is not a draft
                            // for the other.
                            keyDraft = ""
                        }
                } label: {
                    rowLabel(L("The agent uses"),
                             L("Connect one to analyze your meetings."))
                }
                // The key row belongs to the chosen provider — it appears
                // with the choice, labelled with the vendor's name, because a
                // field for a credential nobody can use yet is a question
                // with no reason behind it.
                if let provider = askProvider {
                    LabeledContent {
                        apiKeyControl(for: provider)
                    } label: {
                        rowLabel(provider.keyLabel, L("Your account, your usage"))
                    }
                }
            } header: { Text(L("Meetings")) } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // The privacy line answers for the whole section: with
                    // asking off, "nothing leaves this Mac" covers the calendar
                    // and the local model too — both read and write here only.
                    Text(askFooter)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Hardware honesty, only on the Macs it concerns.
                    ForEach(meetingsCaveats, id: \.self) { caveat in
                        Text(caveat)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
    }

    @ViewBuilder
    private var generalSection: some View {
            // — General — after the two feature clusters, before the read-only
            // status: one app-level switch does not outrank the features, and
            // wedged between the meeting sections (where it used to sit) it
            // was breaking that cluster in half.
            // The appearance row leads General (design): the one choice that
            // repaints every surface, applied the moment it is clicked.
            Section {
                LabeledContent {
                    VStack(alignment: .leading, spacing: 8) {
                        DSSegmented(options: [
                            ("system", L("Match system")),
                            ("light", L("Light")),
                            ("dark", L("Dark")),
                        ], selection: $appearance)
                        .onChange(of: appearance) { choice in
                            Settings.shared.appearance = choice
                            switch choice {
                            case "light": NSApp.appearance = NSAppearance(named: .aqua)
                            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                            default: NSApp.appearance = nil
                            }
                        }
                        Text(appearanceHelp)
                            .font(DS.helpText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Text(L("Appearance"))
                }
            }

            Section {
                Toggle(L("Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Toggle(L("Show in Dock"), isOn: $showInDock)
                    .onChange(of: showInDock) { Settings.shared.showInDock = $0 }
            } header: { Text(L("General")) } footer: {
                Text(L("With this off, Dictate is menu-bar only. Clicking the Dock icon opens Meetings; the menu bar item is always there either way."))
            }
    }

    @ViewBuilder
    private var statusSection: some View {
            // — Status (read-only) —
            Section {
                LabeledContent(L("Microphone")) {
                    HStack(spacing: 6) {
                        statusBadge(ok: micGranted, text: micGranted ? L("Granted") : L("No"))
                        if !micGranted {
                            Button(L("Fix…")) { Permissions.openSettingsPane("Privacy_Microphone") }
                            .buttonStyle(.dsSmall)
                                .controlSize(.small)
                        }
                    }
                }
                LabeledContent(L("Accessibility")) {
                    HStack(spacing: 6) {
                        statusBadge(ok: axGranted, text: axGranted ? L("Granted") : L("No"))
                        if !axGranted {
                            // The pane, not a fresh prompt: an old Deny
                            // suppresses prompts, the switch always works
                            // (GRABLI — the hanging-dialog trap).
                            Button(L("Fix…")) { Permissions.openSettingsPane("Privacy_Accessibility") }
                            .buttonStyle(.dsSmall)
                                .controlSize(.small)
                        }
                    }
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
                            .buttonStyle(.dsSmall)
                    }
                }
                // When the daily silent check last ran — the proof the
                // automatic machinery is alive, next to the number it keeps
                // current. Sparkle's own record, read, not duplicated.
                if let lastCheck = Self.lastUpdateCheck {
                    LabeledContent(L("Updates")) {
                        Text(Lf("Checked automatically · last %@", lastCheck))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L("Links")) {
                    HStack(spacing: 12) {
                        Link(L("Source code"),
                             destination: URL(string: "https://github.com/Budanovvv/Dictate")!)
                        Link(L("Report an issue"),
                             destination: URL(string: "https://github.com/Budanovvv/Dictate/issues")!)
                    }
                    .font(.callout)
                }
            } header: { Text(L("Status")) } footer: {
                Text(L("Network access: a one-time model download — nothing else. Don't take our word for it: turn off Wi-Fi and dictate."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }

    /// The line under the model row's name. Every row in the section carries
    /// one — a row without it broke the section's rhythm — and this one earns
    /// its place: before the download it states the price of switching on
    /// (once, this many gigabytes), after a failure it says what happened,
    /// and otherwise it says what the thing writes and where.
    private var textModelHint: String {
        switch textModel.state {
        case .absent:
            return Lf("One-time %@ download, then everything runs on this Mac.",
                      LocalTextModelFile.sizeText)
        case .failed:
            return L("Download failed. Check your connection and retry.")
        default:
            return L("Names, a one-line summary and a table of contents, written on this Mac.")
        }
    }

    /// What the asking section promises. Its own paragraph because it makes a
    /// different promise from the local model's, and one paragraph making both
    /// is exactly how "nothing is sent anywhere" quietly acquired an exception.
    private var askFooter: String {
        guard let provider = askProvider else {
            return L("Asking questions is off, so nothing about your meetings leaves this Mac.")
        }
        // Named vendor, not product: the footer says whose servers the
        // passages reach, and that is Anthropic or OpenAI, not Claude.
        return Lf("Asking is the one thing that leaves: your question and the few passages the search found go to %@ on your key. Whole meetings never do, and nothing goes anywhere until you click.",
                  provider.vendorName)
    }

    /// The hardware caveats under the Meetings section — the same honesty the
    /// offer in the meetings window gives, shown only on the Macs they concern
    /// (no Metal path: 13.9 s per passage measured against 1.1 s; tight
    /// memory: the model's working set is felt system-wide).
    private var meetingsCaveats: [String] {
        guard textModel.state != .unsupported else { return [] }
        var out: [String] = []
        if LocalTextModelFile.runsOnCPU {
            out.append(L("On this Mac it runs on the CPU: about three minutes of background work for a 50-minute meeting."))
        }
        if LocalTextModelFile.isMemoryTight {
            out.append(L("It holds about 4.7 GB of memory while it writes, which this Mac will feel."))
        }
        return out
    }

    /// The user's own key for the chosen provider.
    ///
    /// A field rather than a sign-in button, and that is not a shortcut: a
    /// third-party app is not permitted to offer a Claude or ChatGPT account
    /// login or to spend somebody's subscription on their behalf. A key is the
    /// sanctioned route, and it has the better property anyway — the person can
    /// see what they are spending and revoke it in one click, on a page we do
    /// not own. The link under the field leads to exactly that page: getting a
    /// key is the one step of this feature that happens outside the app, and
    /// the old UI left the person to go and find it.
    @ViewBuilder
    private func apiKeyControl(for provider: AIProvider) -> some View {
        if let stored = APIKey.current(provider), keyDraft.isEmpty {
            HStack(spacing: 8) {
                statusBadge(ok: true, text: APIKey.masked(stored))
                Button(L("Remove")) {
                    APIKey.store(nil, for: provider)
                    keyRevision += 1
                }
                .buttonStyle(.dsSmall)
                .controlSize(.small)
            }
        } else if APIKey.canUndoRemove(for: provider), keyDraft.isEmpty {
            // The help promises "⌘Z puts it back" — this is that promise
            // kept: the removed key is held in memory for the process's
            // life, and one keystroke (or click) restores it.
            Button(L("Undo remove")) {
                _ = APIKey.undoRemove(for: provider)
                keyRevision += 1
            }
            .buttonStyle(.dsSmall)
            .controlSize(.small)
            .keyboardShortcut("z", modifiers: .command)
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    // Empty title + explicit prompt: in a grouped Form the
                    // title renders as a label BESIDE the field, not inside it.
                    SecureField("", text: $keyDraft, prompt: Text(provider.keyPlaceholder))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 190)
                    Button(L("Save")) {
                        APIKey.store(keyDraft, for: provider)
                        keyDraft = ""
                        keyRevision += 1
                    }
                    .controlSize(.small)
                    .disabled(!APIKey.looksValid(keyDraft, for: provider))
                }
                Link(L("Get a key…"), destination: provider.keysURL)
                    .font(.caption)
            }
        }
    }

    /// The right-hand side of the text-model row: a switch, like every other
    /// on/off decision in this window. The badge-plus-button pair it replaced
    /// made the row a management console among switches — three rows, three
    /// species of control, and the section read as a jumble. On → download
    /// (the subtitle has already named the price), off → remove; the download
    /// itself is the one transient state that shows machinery, because a
    /// multi-gigabyte fetch behind a silent switch is indistinguishable from
    /// a hang.
    @ViewBuilder
    private var textModelControl: some View {
        switch textModel.state {
        case .unsupported:
            EmptyView()
        case .downloading(let fraction):
            HStack(spacing: 8) {
                // A determinate bar, because we know the total to the byte.
                ProgressView(value: fraction).frame(width: 70)
                Text("\(Int(fraction * 100))%")
                    .font(DS.timestamp).foregroundStyle(.secondary)
                Button(L("Cancel")) { textModel.cancel() }
                    .controlSize(.small)
            }
        case .verifying:
            ProgressView().controlSize(.small)
        case .absent, .failed, .ready:
            Toggle("", isOn: Binding(
                get: { textModel.state == .ready },
                set: { $0 ? textModel.start() : textModel.remove() }))
                .labelsHidden()
                .toggleStyle(.switch)
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

    @ViewBuilder
    /// A row's name, and under it the one line that explains it — when there is
    /// one. `nil` leaves the row a single line rather than an empty second one.
    /// Lands on the tab a caller requested (the corner menu's rows, the
    /// screenshot harness) — the request rides UserDefaults and is consumed
    /// exactly once.
    private func applyRequestedTab() {
        guard let wanted = UserDefaults.standard.string(forKey: "debugShotTab")
            ?? UserDefaults.standard.string(forKey: "settingsOpenTab") else { return }
        UserDefaults.standard.removeObject(forKey: "debugShotTab")
        UserDefaults.standard.removeObject(forKey: "settingsOpenTab")
        switch wanted {
        case "languages": tab = .languages
        case "meetings": tab = .meetings
        case "general": tab = .general
        default: tab = .keys
        }
        Log.d("corner: settings landed on tab \(wanted)")
    }

    private func rowLabel(_ title: String, _ hint: String?,
                          warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let hint {
                Text(hint).font(.caption)
                    .foregroundStyle(warn ? AnyShapeStyle(DS.warn)
                                          : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Cheap enough to run on every render of the meetings section — the
    /// person flips the permission in System Settings and comes back, and
    /// the pane must not keep claiming it is broken (or working).
    private func refreshMicDenied() {
        let denied = Permissions.microphone == .denied
        if denied != micDenied {
            DispatchQueue.main.async { micDenied = denied }
        }
    }

    @ViewBuilder
    private func statusBadge(ok: Bool, text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? AnyShapeStyle(DS.good) : AnyShapeStyle(.secondary))
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
                        .fill(capture.capturing ? DS.accent.opacity(0.15)
                                                : Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(capture.capturing ? DS.accent : .secondary.opacity(0.35),
                                      lineWidth: 1))
            }
            .buttonStyle(.plain)
            .hoverHighlight(radius: 6)
            .pointerStyle(.link)

            if let onClear, !keyName.isEmpty, !capture.capturing {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .padding(2)
                }
                .buttonStyle(.plain)
                .hoverHighlight(radius: 6)
                .padding(-2)
                .help(L("Remove"))
            }
        }
    }
}
