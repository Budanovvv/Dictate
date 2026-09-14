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
    /// The Keychain refused the key — say so instead of pretending.
    @State private var keychainSaveFailed = false

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

    /// The build's full identity, stamped by build.sh: commit count · short
    /// SHA · dirty marker ("205·fed7def·dirty"). The marketing version alone
    /// cannot tell two builds of one cycle apart — this can, at a glance.
    static var buildStamp: String {
        Bundle.main.object(forInfoDictionaryKey: "DictateBuildStamp") as? String ?? ""
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
    // This Mac is the fifth: what the machine is, what that lets the app do
    // and why, and what the app keeps on its disk — the read-only rows that
    // used to sit under General, plus the ones the 8 GB MacBook taught us
    // to write (2026-09-13). Its own row so the meeting model is findable by
    // NAME in the sidebar, which is the shortest path to removing it.
    // Agent is the sixth (2026-09-14): everything that leaves this Mac on
    // the person's key — the provider, the key, what is sent, and reports —
    // in the one place the app already calls "Agent". Meetings is purely
    // local again: calendar names, reading, the meeting model.
    // Templates is the seventh (2026-09-14): a report is a thing a person
    // goes looking for by name, and would not find under Agent.
    private enum Tab: CaseIterable { case keys, languages, meetings, agent, templates, general, thisMac }
    @State private var tab: Tab = .keys
    /// The Templates tab: which template is showing, and its working copy.
    /// Every edit goes to the store at once (the list in memory) and to
    /// disk a moment later — see ReportTemplateStore.save.
    @State private var templateID: UUID?
    @State private var templateDraft: ReportTemplate?
    @State private var templateChooserOpen = false
    @State private var starterChooserOpen = false
    @State private var confirmRemoveTemplate = false
    @State private var reportLanguage = Settings.shared.reportLanguage
    @FocusState private var focusedTemplateField: UUID?
    @ObservedObject private var templateStore = ReportTemplateStore.shared
    /// The removal dialog for the meeting model.
    @State private var confirmRemoveModel = false
    /// The removal dialog for the debug audio dumps.
    @State private var confirmRemoveDumps = false
    /// What the app keeps on disk, measured off the main thread when This
    /// Mac is shown (the archive may be in iCloud).
    @State private var storage: MachineStorage?
    /// "Copied" for a moment after the diagnostics button.
    @State private var diagnosticsCopied = false
    /// Which engine reads meetings right now — recomputed when the model
    /// row changes, not on every redraw (it asks the disk).
    @State private var engineStatus = MeetingTextEngines.status

    private func tabTitle(_ tab: Tab) -> String {
        switch tab {
        case .keys: return L("Keys")
        case .languages: return L("Languages")
        case .meetings: return L("Meetings")
        case .agent: return L("Agent")
        case .templates: return L("Templates")
        case .general: return L("General")
        case .thisMac: return L("This Mac")
        }
    }

    private func tabIcon(_ tab: Tab) -> String {
        switch tab {
        case .keys: return "keyboard"
        case .languages: return "globe"
        case .meetings: return "video"
        case .agent: return "sparkles"
        case .templates: return "doc.text"
        case .general: return "gearshape"
        case .thisMac: return "desktopcomputer"
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
        .onChange(of: textModel.state) { engineStatus = MeetingTextEngines.status }
        .onChange(of: tab) { _, now in if now == .thisMac { measureStorage() } }
        // The meeting model's removal, confirmed: destructive, and not
        // undoable short of downloading 2.5 GB again — the one place in this
        // window where a switch would have been the wrong control (a switch
        // that pops a dialog and snaps back is the calendar-banner problem
        // all over again).
        .confirmationDialog(L("Remove the meeting model?"), isPresented: $confirmRemoveModel,
                            titleVisibility: .visible) {
            Button(L("Remove"), role: .destructive) {
                textModel.remove()
                engineStatus = MeetingTextEngines.status
                measureStorage()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(TextModelRowCopy.removalBody(appleIntelligence: MeetingTextEngines.appleIntelligence,
                                              readMeetings: readMeetings,
                                              sizeText: LocalTextModelFile.sizeText))
        }
        .confirmationDialog(L("Remove the debug audio dumps?"), isPresented: $confirmRemoveDumps,
                            titleVisibility: .visible) {
            Button(L("Remove"), role: .destructive) {
                try? FileManager.default.removeItem(at: MachineStorage.replayDirectory)
                measureStorage()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("These are recordings kept only for debugging. Nothing else is affected."))
        }
        // The corner menu can ask for a tab while this window already
        // exists (it is cached for the app's lifetime) — onAppear alone
        // only serves the first opening. Reopening also re-checks the
        // permissions: the panel is non-activating now, so the old
        // didBecomeActive refresh rarely fires for it.
        .onReceive(NotificationCenter.default.publisher(
            for: .init("dictate.openSettings")).receive(on: RunLoop.main)) { _ in
            applyRequestedTab()
            textModel.refresh()
            refreshStatuses()
        }
        // The capability switches are flipped from many surfaces (the
        // first-run rows, the absence strips, the offer card) while this
        // window sits cached with one-shot @State — mirror every outside
        // write back in, or the pane shows OFF for switches that are on
        // (review find, 2026-08-31).
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            if noticeCalls != Settings.shared.noticeCalls { noticeCalls = Settings.shared.noticeCalls }
            if recordCallAudio != Settings.shared.recordCallAudio { recordCallAudio = Settings.shared.recordCallAudio }
            if separateVoices != Settings.shared.separateVoices { separateVoices = Settings.shared.separateVoices }
            if readMeetings != Settings.shared.readMeetings { readMeetings = Settings.shared.readMeetings }
            if nameFromCalendar != Settings.shared.nameMeetingsFromCalendar {
                nameFromCalendar = Settings.shared.nameMeetingsFromCalendar
            }
            if askProvider != Settings.shared.askProvider { askProvider = Settings.shared.askProvider }
        }
        // The Templates tab's working copy: loaded when the tab opens or the
        // chosen template changes, saved as it is typed.
        .onChange(of: tab) { _, now in if now == .templates { loadTemplate() } }
        .onChange(of: templateID) { loadTemplate() }
        .onChange(of: templateDraft) { _, now in
            guard let now, now.id == templateID else { return }
            templateStore.save(now)
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
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    // The hit shape AFTER the padding: the clickable area is
                    // the whole row the hover wash paints. Before, the top
                    // and bottom 5 pt of every row — a third of it — lit up
                    // on hover and swallowed the click; clicked at speed
                    // that was one tab in three, in 3.2.6 exactly as in
                    // 3.2.7 (traced 2026-09-14: every miss within 5 pt of a
                    // row edge, every hit in the middle band).
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tabTitle(candidate))
                .accessibilityAddTraits(tab == candidate ? .isSelected : [])
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
        case .agent: Form { agentSection }.formStyle(.grouped)
        case .templates: Form { templatesSection }.formStyle(.grouped)
        case .general: Form { generalSection }.formStyle(.grouped)
        case .thisMac: Form { thisMacSection; storageSection; statusSection }.formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var languagesSection: some View {
            // — Language: what you speak, what it turns into, and only then
            // the language of this window itself —
            Section {
                // Same searchable picker as onboarding — a flat 100-row Picker
                // fails every large-list UX guideline (see LanguagePicker).
                LabeledContent(L("Spoken language")) {
                    LanguagePicker(selection: $language)
                }
                .onChange(of: language) { _, v in
                    Settings.shared.language = v
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
                    .onChange(of: translateTarget) { _, v in Settings.shared.translateTargetCode = v }

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
                    .onChange(of: insertByTyping) { _, v in Settings.shared.insertByTyping = v }
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
                            MeetingCapability.turnAllOnByHand()
                            noticeCalls = true; recordCallAudio = true
                            separateVoices = true; readMeetings = true
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
                        .onChange(of: noticeCalls) { _, v in
                            Settings.shared.noticeCalls = v
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
                        .onChange(of: recordCallAudio) { _, v in
                            Settings.shared.recordCallAudio = v
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
                        .onChange(of: separateVoices) { _, v in
                            Settings.shared.separateVoices = v
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
                        .onChange(of: readMeetings) { _, v in
                            Settings.shared.readMeetings = v
                            OfferLedger.decided(.readMeetings)
                        }
                } label: {
                    // The switch is shown on every Mac, engine or none: the
                    // agent depends on it too, and a Mac with no engine
                    // still has the agent. What it says underneath is WHICH
                    // engine reads — or why none can (design lens, 2026-09-13).
                    rowLabel(MeetingCapability.readMeetings.name,
                             MeetingCapability.readMeetings.adds,
                             note: TextModelRowCopy.engineLine(
                                status: engineStatus,
                                canDownload: textModel.state == .absent || textModel.state.isFailed))
                }
                // The reader's language for what the models write ABOUT a
                // meeting — the summary line and every report — as opposed
                // to the title, which keeps the meeting's own. One setting
                // for both, here with the reading it belongs to (owner,
                // 2026-09-14: a Polish call summarised in Polish).
                if readMeetings {
                    LabeledContent {
                        ReportLanguagePicker(selection: $reportLanguage)
                            .onChange(of: reportLanguage) { _, v in Settings.shared.reportLanguage = v }
                    } label: {
                        rowLabel(L("Write summaries and reports in"),
                                 L("The title keeps the meeting’s language; the summary and every report are written in this one. Field names in a report stay exactly as typed."))
                    }
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
                        .onChange(of: nameFromCalendar) { _, on in
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

                // The downloadable meeting model. Named by what the user
                // gets, not by what it is — nobody has ever wanted a "text
                // model"; they want their meetings to have names.
                //
                // The row is absent on a Mac that has nothing to offer AND
                // nothing on disk (`unsupported`: no helper, or too little
                // memory) — the why lives on This Mac. But a model that IS on
                // disk is shown whatever the switch above says: the row used
                // to vanish with reading off, and 2.5 GB vanished with it,
                // with no way left to remove them (owner, 2026-09-13).
                if textModel.state != .unsupported, readMeetings || textModel.state != .absent {
                    LabeledContent {
                        textModelControl
                    } label: {
                        rowLabel(L("Meeting titles & summaries"), textModelHint)
                    }
                }

            } header: { Text(L("Meetings")) } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // The privacy line answers for the whole section: the
                    // calendar and the local model read and write here only.
                    // The agent, which does send, has its own tab and its
                    // own footer.
                    Text(L("Everything here runs on this Mac and nothing leaves it. What the agent sends, on your key, is on the Agent tab."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The hardware caveats used to repeat here; they live on
                    // This Mac now, once, next to the machine they describe,
                    // and in the offer at the moment of the decision.
                }
            }
    }

    // MARK: - Agent

    /// The agent and what it does: the connection, then reports. Reports sit
    /// under the connection because they cannot exist without it, and the
    /// off state points one row up instead of to another tab.
    @ViewBuilder
    private var agentSection: some View {
        Section {
            // One control answers both questions — is this on, and with
            // whom. A toggle that then revealed a provider choice would
            // make the person say "yes" before they know to whom; a
            // chooser whose first option is Off keeps consent and choice
            // as the single decision they actually are. Deliberately NOT
            // gated by the local model: this runs on the user's API key in
            // the vendor's cloud, so a Mac too small for a local 4B model
            // can still turn on the one capability that does not need it.
            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    AskProviderPicker(selection: $askProvider)
                        .onChange(of: askProvider) { _, v in
                            Settings.shared.askProvider = v
                            // A half-typed key for one vendor is not a draft
                            // for the other.
                            keyDraft = ""
                        }
                    if askProvider == nil {
                        Text(L("Off: transcripts, summaries and search work as before. The agent answers questions across your meetings and writes reports; it runs in the cloud on your own API key."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } label: {
                rowLabel(L("Answers with"), L("Questions across your meetings, and reports."))
            }
            // The key row belongs to the chosen provider — it appears
            // with the choice, labelled with the vendor's name, because a
            // field for a credential nobody can use yet is a question
            // with no reason behind it.
            let storedKey = storedKey
            if let provider = askProvider {
                LabeledContent {
                    apiKeyControl(for: provider, stored: storedKey)
                } label: {
                    rowLabel(provider.keyLabel, L("Your account, your usage"))
                }
            }
            // Whole-width rows, like This Mac's verdicts: a name and the
            // sentences under it, nothing to put in a control column.
            let gate = reportsGateLine(hasKey: storedKey != nil)
            rowLabel(L("Reports"),
                     L("A structured write-up of a call under fields you define once, such as Objections or Next steps, written from any meeting’s card. A field the call did not cover reads “Not discussed”."),
                     note: gate ?? L("The templates have their own tab, next to this one."))
            if let provider = askProvider, storedKey != nil {
                rowLabel(L("What is sent"),
                         Lf("Each report sends the whole transcript to %@ on your key — about 12,000 words for an hour of talk. The recording never leaves this Mac.", provider.vendorName))
            }
        } header: { Text(L("Agent")) } footer: {
            Text(askFooter)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One Keychain read per render of the section, not one per row: the
    /// query is not free, and the window redraws on every keystroke.
    private var storedKey: String? {
        _ = keyRevision
        guard let provider = askProvider else { return nil }
        return APIKey.current(provider)
    }

    /// Why reports cannot run right now, when they cannot.
    private func reportsGateLine(hasKey: Bool) -> String? {
        guard let provider = askProvider else {
            return L("Reports need the agent, which is off. Choose Claude or ChatGPT above to turn them on; the templates keep until then.")
        }
        guard hasKey else {
            return Lf("%@ is chosen but has no key. Add one above; reports start with the next call.", provider.productName)
        }
        return nil
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
                        .onChange(of: appearance) { _, choice in
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
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Toggle(L("Show in Dock"), isOn: $showInDock)
                    .onChange(of: showInDock) { _, v in Settings.shared.showInDock = v }
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
                        if !Self.buildStamp.isEmpty {
                            Text("(\(Self.buildStamp))")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text("·").foregroundStyle(.tertiary)
                        Button(L("Check for updates")) { onCheckForUpdates() }
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
    /// its place: before the download it states the price (once, this many
    /// gigabytes), after a failure it says what happened, installed it says
    /// so WITH the size, and on a Mac that may not run it, why not.
    private var textModelHint: String {
        TextModelRowCopy.rowHint(state: textModelRowState,
                                 memoryGB: MachineProfile.current.memoryGB,
                                 appleIntelligence: MeetingTextEngines.appleIntelligence,
                                 readMeetings: readMeetings,
                                 sizeText: LocalTextModelFile.sizeText,
                                 paused: textModel.paused)
    }

    private var textModelRowState: TextModelRowCopy.RowState {
        switch textModel.state {
        case .unsupported, .absent: return .absent
        case .downloading: return .downloading
        case .verifying: return .verifying
        case .ready: return .ready
        case .installedNotRunnable: return .installedNotRunnable
        case .failed: return .failed
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
        // Honest about the agent loop: it OPENS whole transcripts when it
        // decides to read them, and those go to the provider too. The old
        // line ("whole meetings never do") predated the tool loop and had
        // become a false privacy claim (review find, 2026-08-31).
        return Lf("Asking is the one thing that leaves this Mac: your question, the search hits, and the transcripts the agent opens to answer go to %@ on your key. Nothing is sent until you ask.",
                  provider.vendorName)
    }

    // MARK: - Templates

    /// A template is a form the agent fills in from a transcript. Rows like
    /// every other tab: which template, its name, its Context, its fields.
    /// With the agent off the tab stays and says so in one line — a tab
    /// that comes and goes is a control nobody can find twice.
    @ViewBuilder
    private var templatesSection: some View {
        Section {
            // The templates as a visible list (design: Settings › Agent,
            // turn 3), not a popup: which forms exist is the first thing a
            // person looks for here. The chosen one is tinted the way the
            // sidebar tints its row, and its editor opens below.
            VStack(alignment: .leading, spacing: 10) {
                // The section header already says "Templates"; the row
                // needs only the sentence.
                Text(L("A form the agent fills in from a transcript: field names become headings, the model writes under each."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !templateStore.templates.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(templateStore.templates.enumerated()), id: \.element.id) { index, template in
                            templateListRow(template, selected: template.id == templateID)
                            if index < templateStore.templates.count - 1 {
                                Divider().padding(.leading, 10)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .dsFieldChrome(radius: 8, onCard: true)
                    .frame(maxWidth: 420)
                }
                Button(L("New template…")) { starterChooserOpen.toggle() }
                    .buttonStyle(.dsSmall)
                    .controlSize(.small)
                    .popover(isPresented: $starterChooserOpen, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(ReportTemplate.StarterKind.allCases, id: \.self) { kind in
                                let starter = ReportTemplate.starter(kind)
                                PopupRow(title: starter.name,
                                         subtitle: kind == .blank ? L("One empty field. You name it.")
                                            : starter.fields.map(\.name).joined(separator: " · "),
                                         selected: false) {
                                    templateStore.save(starter)
                                    templateID = starter.id
                                    starterChooserOpen = false
                                }
                            }
                        }
                        .padding(6)
                        .frame(width: 300)
                    }
                if askProvider == nil {
                    Text(L("Reports need the agent, which is off. Choose Claude or ChatGPT on the Agent tab to turn them on; the templates keep until then."))
                        .font(.caption).foregroundStyle(DS.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: { Text(L("Templates")) }

        if let draft = templateDraft {
            Section {
                LabeledContent {
                    TextField("", text: templateBinding(draft, \.name), prompt: Text(L("Template name")))
                        .labelsHidden()
                        .templateField()
                        .frame(width: 260, alignment: .leading)
                        .accessibilityLabel(L("Template name"))
                } label: {
                    rowLabel(L("Name"), nil)
                }
                // Context and the fields take the whole row: a paragraph and
                // a list have no business in a control column.
                VStack(alignment: .leading, spacing: 8) {
                    rowLabel(L("Context"), L("Optional. One paragraph for the whole template, such as “We are a sales agency; the client is always the other party.”"))
                    TextField("", text: templateBinding(draft, \.context),
                              prompt: Text(L("Who “we” are and what to look for")), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...4)
                        .templateField()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(L("Context"))
                }
                // The grouped form hands a row its ideal width and aligns
                // its text trailing; a list of fields wants the whole row
                // and its text at the left, so both are said explicitly.
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                VStack(alignment: .leading, spacing: 8) {
                    rowLabel(L("Fields"),
                             L("A field with no instruction goes by its name alone. A field the call did not cover reads “Not discussed”."))
                    templateFields(draft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            } header: { Text(draft.name.isEmpty ? L("New template") : draft.name) }

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        Button(L("Export reports…")) { ReportExport.exportAll(template: draft) }
                            .buttonStyle(.dsSmall).controlSize(.small)
                        Button(L("Remove template…")) { confirmRemoveTemplate = true }
                            .buttonStyle(.dsSmall).controlSize(.small)
                    }
                    .confirmationDialog(Lf("Remove “%@”?", draft.name), isPresented: $confirmRemoveTemplate,
                                        titleVisibility: .visible) {
                        Button(L("Remove template"), role: .destructive) {
                            templateStore.remove(id: draft.id)
                            templateID = templateStore.templates.first?.id
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
    }

    /// One template in the list: its name, how many fields, and the
    /// sidebar's own selection — an accent edge and a tint, never a filled
    /// row — with the hover wash every row in this app has.
    private func templateListRow(_ template: ReportTemplate, selected: Bool) -> some View {
        Button {
            templateID = template.id
        } label: {
            HStack(spacing: 8) {
                Text(template.name.isEmpty ? L("New template") : template.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Lf("%d fields", template.usableFields.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
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
        .hoverHighlight(radius: 0)
        .accessibilityLabel(template.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func templateFields(_ template: ReportTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(template.fields.enumerated()), id: \.element.id) { index, field in
                HStack(spacing: 6) {
                    TextField("", text: fieldBinding(field.id, \.name), prompt: Text(L("Field name")))
                        .labelsHidden()
                        .templateField()
                        .frame(width: 190)
                        .focused($focusedTemplateField, equals: field.id)
                        .accessibilityLabel(L("Field name"))
                    TextField("", text: fieldBinding(field.id, \.instruction),
                              prompt: Text(L("Instruction (optional)")))
                        .labelsHidden()
                        .templateField()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(L("Instruction (optional)"))
                    HStack(spacing: 2) {
                        Button { moveTemplateField(field.id, by: -1) } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(index == 0)
                        .accessibilityLabel(L("Move up"))
                        Button { moveTemplateField(field.id, by: 1) } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(index == template.fields.count - 1)
                        .accessibilityLabel(L("Move down"))
                        Button {
                            var updated = template
                            updated.fields.removeAll { $0.id == field.id }
                            templateDraft = updated
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 13))
                                .frame(width: 20, height: 18)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(L("Remove field"))
                    }
                    .padding(.leading, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                var updated = template
                let field = ReportField(name: "")
                updated.fields.append(field)
                templateDraft = updated
                focusedTemplateField = field.id
            } label: {
                Label(L("Add field"), systemImage: "plus")
            }
            .buttonStyle(.dsSmall)
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func loadTemplate() {
        if templateID == nil || !templateStore.templates.contains(where: { $0.id == templateID }) {
            templateID = templateStore.templates.first?.id
        }
        templateDraft = templateID.flatMap { templateStore.template(id: $0) }
    }

    private func moveTemplateField(_ id: UUID, by offset: Int) {
        guard var updated = templateDraft,
              let index = updated.fields.firstIndex(where: { $0.id == id }),
              updated.fields.indices.contains(index + offset) else { return }
        // The focused field commits through AppKit's field editor when it
        // loses focus; taking the focus away BEFORE the rows move keeps that
        // commit on the row it belongs to.
        focusedTemplateField = nil
        updated.fields.swapAt(index, index + offset)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { templateDraft = updated }
    }

    private func templateBinding<T>(_ template: ReportTemplate,
                                    _ path: WritableKeyPath<ReportTemplate, T>) -> Binding<T> {
        Binding(
            get: { templateDraft?[keyPath: path] ?? template[keyPath: path] },
            set: { value in templateDraft?[keyPath: path] = value }
        )
    }

    /// By the field's id, not its index: a text field keeps writing through
    /// the binding it was given, and after a ▲/▼ move an index binding
    /// wrote into whichever field had moved into that slot (owner,
    /// 2026-09-14: "the arrows are chaos").
    private func fieldBinding(_ id: UUID, _ path: WritableKeyPath<ReportField, String>) -> Binding<String> {
        Binding(
            get: {
                templateDraft?.fields.first { $0.id == id }?[keyPath: path] ?? ""
            },
            set: { value in
                guard var updated = templateDraft,
                      let index = updated.fields.firstIndex(where: { $0.id == id }) else { return }
                updated.fields[index][keyPath: path] = value
                templateDraft = updated
            }
        )
    }

    // MARK: - This Mac

    /// The machine, and the three verdicts it yields: what recognition runs
    /// on, what reads meetings (or why nothing does), and whether the agent
    /// is on. The one place where every "why" is answered together.
    @ViewBuilder
    private var thisMacSection: some View {
        let profile = MachineProfile.current
        let verdict = LocalTextModelFile.verdict(on: profile,
                                                 appleIntelligence: MeetingTextEngines.appleIntelligence)
        Section {
            LabeledContent(L("Mac")) {
                Text(profile.headline)
                    .foregroundStyle(.secondary)
            }
            // The three verdicts are whole sentences that name their subject
            // ("Recognition runs on…", "Meeting reading: …", "Agent: …"), so
            // they stand as rows of their own — a label beside them repeated
            // the first word of every line.
            Text(TextModelRowCopy.recognitionLine(appleSilicon: profile.isAppleSilicon))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(TextModelRowCopy.readingLines(status: engineStatus, verdict: verdict,
                                                            sizeText: LocalTextModelFile.sizeText)
                                .enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 0 ? .body : .caption)
                        .foregroundStyle(index == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(TextModelRowCopy.agentLine(productName: askProvider?.productName))
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent {
                Button(diagnosticsCopied ? L("Copied") : L("Copy diagnostics")) { copyDiagnostics() }
                    .buttonStyle(.dsSmall)
                    .controlSize(.small)
            } label: {
                rowLabel(L("Diagnostics"),
                         L("Mac, macOS, version and which features are on. No transcripts, no keys."))
            }
        } header: { Text(L("This Mac")) }
    }

    /// What the app keeps on disk, each with its size and — where removing
    /// it is a sane thing to do — a button. The speech model is required;
    /// the meeting model is the one people come here to remove.
    @ViewBuilder
    private var storageSection: some View {
        Section {
            LabeledContent {
                // The nominal size the onboarding quoted (626 MB), not the
                // allocated bytes on disk (629.5 with the tokenizer): one
                // number for one thing, wherever it is named.
                Text(MachineProfile.fileSizeText(Int64(ModelTier.fast.sizeMB) * 1_000_000))
                    .foregroundStyle(.secondary).monospacedDigit()
            } label: {
                rowLabel(L("Speech model"), L("Required for dictation."))
            }
            LabeledContent {
                meetingModelStorageControl
            } label: {
                rowLabel(L("Meeting model"), meetingModelStorageHint)
            }
            if let storage, storage.speakerModelBytes > 0 {
                LabeledContent {
                    Text(MachineProfile.fileSizeText(storage.speakerModelBytes))
                        .foregroundStyle(.secondary).monospacedDigit()
                } label: {
                    rowLabel(L("Speaker models"), L("Tell the voices on a call apart."))
                }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Text(storage.map { MachineProfile.fileSizeText($0.meetingArchiveBytes) } ?? "…")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Button(L("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([MeetingArchive.directory])
                    }
                    .buttonStyle(.dsSmall)
                    .controlSize(.small)
                }
            } label: {
                rowLabel(L("Meeting archive"), L("Your transcripts, as Markdown files you own."))
            }
            // Only while the hidden debug default is on and there is
            // something to show — a row for an instrument nobody turned on
            // would legalize it under a name nobody understands.
            if UserDefaults.standard.bool(forKey: MeetingReplayDefaults.dumpKey),
               let storage, storage.debugDumpBytes > 0 {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(MachineProfile.fileSizeText(storage.debugDumpBytes))
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button(L("Remove…")) { confirmRemoveDumps = true }
                            .buttonStyle(.dsSmall)
                            .controlSize(.small)
                    }
                } label: {
                    rowLabel(L("Debug audio dumps"), L("Raw call audio kept for debugging only."))
                }
            }
        } header: { Text(L("Storage")) }
    }

    private var meetingModelStorageHint: String {
        switch textModel.state {
        case .ready, .installedNotRunnable:
            return TextModelRowCopy.rowHint(state: textModelRowState,
                                            memoryGB: MachineProfile.current.memoryGB,
                                            appleIntelligence: MeetingTextEngines.appleIntelligence,
                                            readMeetings: readMeetings,
                                            sizeText: LocalTextModelFile.sizeText,
                                            paused: nil)
        case .downloading, .verifying:
            return L("Downloading…")
        case .absent, .failed:
            return Lf("Not installed. A one-time %@ download writes titles, summaries and a table of contents.",
                      LocalTextModelFile.sizeText)
        case .unsupported:
            let verdict = LocalTextModelFile.verdict(on: MachineProfile.current,
                                                     appleIntelligence: MeetingTextEngines.appleIntelligence)
            if case .unavailable(let reason, _) = verdict { return reason }
            return L("Not available on this Mac.")
        }
    }

    @ViewBuilder
    private var meetingModelStorageControl: some View {
        switch textModel.state {
        case .ready, .installedNotRunnable:
            HStack(spacing: 8) {
                Text(storage.map { MachineProfile.fileSizeText($0.meetingModelBytes) } ?? LocalTextModelFile.sizeText)
                    .foregroundStyle(.secondary).monospacedDigit()
                Button(L("Remove…")) { confirmRemoveModel = true }
                    .buttonStyle(.dsSmall)
                    .controlSize(.small)
            }
        case .absent, .failed:
            Button(Lf("Download %@", LocalTextModelFile.sizeText)) { textModel.start() }
                .buttonStyle(.dsSmall)
                .controlSize(.small)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 70)
                Text("\(Int(fraction * 100))%")
                    .font(DS.timestamp).foregroundStyle(.secondary)
            }
        case .verifying:
            ProgressView().controlSize(.small)
        case .unsupported:
            Text("—").foregroundStyle(.tertiary)
        }
    }

    /// Off the main thread: the archive may be in iCloud, and even an
    /// enumerator that opens nothing lists slowly there.
    private func measureStorage() {
        let archive = MeetingArchive.directory
        DispatchQueue.global(qos: .utility).async {
            let measured = MachineStorage.measure(archive: archive)
            DispatchQueue.main.async { storage = measured }
        }
    }

    /// The facts a support conversation needs and nothing it does not: the
    /// Mac, the OS, the build, and which features are on. No transcripts, no
    /// keys — the hint under the button promises that, and this is the
    /// promise kept.
    private func copyDiagnostics() {
        let profile = MachineProfile.current
        let verdict = LocalTextModelFile.verdict(on: profile,
                                                 appleIntelligence: MeetingTextEngines.appleIntelligence)
        var lines = [
            "Dictate \(Self.appVersion) (\(Self.buildStamp))",
            profile.logLine,
            "memory headroom now: \(MachineProfile.memoryText(MachineProfile.memoryHeadroom())), pressure level \(MachineProfile.memoryPressureLevel())",
            "recognition: \(profile.hasNeuralEngine ? "Neural Engine" : "CPU")",
            "meeting model: \(textModel.state), verdict \(verdict)",
            "apple intelligence: \(MeetingTextEngines.appleIntelligence)",
            "helper plan: \(LocalTextModelFile.currentPlan)",
            "reads meetings: \(readMeetings), notices calls: \(noticeCalls), records audio: \(recordCallAudio), separates voices: \(separateVoices)",
            "agent: \(askProvider?.productName ?? "off")",
            "microphone: \(micGranted), accessibility: \(axGranted)",
            "log: ~/Library/Logs/Dictate/dictate.log",
        ]
        if let storage {
            lines.append("storage: speech \(MachineProfile.fileSizeText(storage.speechModelBytes)), meeting model \(MachineProfile.fileSizeText(storage.meetingModelBytes)), archive \(MachineProfile.fileSizeText(storage.meetingArchiveBytes))")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        diagnosticsCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { diagnosticsCopied = false }
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
    private func apiKeyControl(for provider: AIProvider, stored: String?) -> some View {
        if let stored, keyDraft.isEmpty {
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
                        .onChange(of: keyDraft) { keychainSaveFailed = false }
                    Button(L("Save")) {
                        // A failed Keychain write keeps the draft on screen —
                        // clearing the field on failure would eat the pasted
                        // key with a success face (review find, 2026-08-31).
                        if APIKey.store(keyDraft, for: provider) {
                            keyDraft = ""
                        } else {
                            keychainSaveFailed = true
                        }
                        keyRevision += 1
                    }
                    .controlSize(.small)
                    .disabled(!APIKey.looksValid(keyDraft, for: provider))
                    if keychainSaveFailed {
                        Text(L("The Keychain refused to save the key — it stays in the field. Try again after unlocking the keychain."))
                            .font(DS.helpText)
                            .foregroundStyle(DS.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Link(L("Get a key…"), destination: provider.keysURL)
                    .font(.caption)
            }
        }
    }

    /// The right-hand side of the model row. Buttons, not a switch — and that
    /// is a reversal. The switch made the row look like every other decision
    /// in this window, but "off" DELETED 2.5 GB, silently: a switch is for
    /// "use it or not", a button with an ellipsis is for "keep it on disk or
    /// not". The download itself is the one transient state that shows
    /// machinery, because a multi-gigabyte fetch behind a quiet control is
    /// indistinguishable from a hang.
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
        case .absent:
            Button(Lf("Download %@", LocalTextModelFile.sizeText)) { textModel.start() }
                .buttonStyle(.dsSmall)
                .controlSize(.small)
        case .failed:
            Button(L("Retry")) { textModel.start() }
                .buttonStyle(.dsSmall)
                .controlSize(.small)
        case .ready:
            // Managing the file — its size, removing it — is This Mac's job;
            // this row only points there.
            Button(L("Manage…")) { tab = .thisMac }
                .buttonStyle(.dsSmall)
                .controlSize(.small)
        case .installedNotRunnable:
            Button(L("Remove…")) { confirmRemoveModel = true }
                .buttonStyle(.dsSmall)
                .controlSize(.small)
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
        case "agent": tab = .agent
        case "templates": tab = askProvider != nil ? .templates : .agent
        case "general": tab = .general
        case "thismac": tab = .thisMac
        default: tab = .keys
        }
        Log.d("corner: settings landed on tab \(wanted)")
    }

    /// A row's name, and under it the one line that explains it — when there is
    /// one. `nil` leaves the row a single line rather than an empty second one.
    private func rowLabel(_ title: String, _ hint: String?,
                          warn: Bool = false, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let hint {
                Text(hint).font(.caption)
                    .foregroundStyle(warn ? AnyShapeStyle(DS.warn)
                                          : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A second caption, set apart: a fact about THIS Mac under the
            // general explanation (which engine reads meetings here).
            if let note {
                Text(note).font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
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
                .accessibilityLabel(L("Remove"))
                .help(L("Remove"))
            }
        }
    }
}


private extension View {
    /// A template's text field in the agent composer's own chrome (design
    /// t14): plain field, quiet fill, hairline — not the stock rounded
    /// border, which is a different species of control in this window.
    func templateField() -> some View {
        self.textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .dsFieldChrome(radius: 8, onCard: true)
    }
}
