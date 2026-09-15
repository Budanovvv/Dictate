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
    // Six panes (design turn 32/33, 2026-09-15): one pane per thing the
    // person HAS — you press it (Dictation), it records (Meetings), it
    // writes for you (Summaries & reports), it is a form (Templates), it is
    // the app (General), or it is a report about this Mac (About, which
    // sets nothing). The seven-tab model divided by where a feature came
    // from, which is why "where do I turn off the thing that writes
    // summaries" had three plausible answers.
    private enum Tab: String, CaseIterable {
        case dictation, meetings, writing, templates, general, about
        /// A hairline above these rows in the sidebar: the three groups
        /// the design draws (press · write · the app / the Mac).
        var startsGroup: Bool { self == .writing || self == .general || self == .about }
        /// ⌘, and the menu bar row reopen the pane you were on (design
        /// turn 33, behaviour B); every deep link overrides it.
        static var lastUsed: Tab {
            Tab(rawValue: UserDefaults.standard.string(forKey: "settingsLastTab") ?? "") ?? .dictation
        }
    }
    @State private var tab: Tab = Tab.lastUsed
    /// The row a deep link asked to be shown — scrolled to and tinted for a
    /// moment, the way System Settings reveals a row its search found.
    @State private var revealRow: String?
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
    /// Meetings with a report per template, for the Written reports row.
    /// nil until counted, so the row never claims zero before it has looked.
    @State private var reportCounts: [UUID: Int] = [:]
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
        case .dictation: return L("Dictation")
        case .meetings: return L("Meetings")
        case .writing: return L("Summaries & reports")
        case .templates: return L("Templates")
        case .general: return L("General")
        case .about: return L("About")
        }
    }

    private func tabIcon(_ tab: Tab) -> String {
        switch tab {
        case .dictation: return "keyboard"
        case .meetings: return "video"
        case .writing: return "text.alignleft"
        case .templates: return "doc.text"
        case .general: return "gearshape"
        case .about: return "desktopcomputer"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar.frame(width: 212)
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
            countReports()
        }
        .onChange(of: textModel.state) { engineStatus = MeetingTextEngines.status }
        .onChange(of: tab) { _, now in
            UserDefaults.standard.set(now.rawValue, forKey: "settingsLastTab")
            if now == .about { measureStorage() }
            if now == .templates { countReports() }
        }
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
                if candidate.startsGroup {
                    Divider().padding(.horizontal, 20).padding(.vertical, 6)
                }
                Button {
                    tab = candidate
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tabIcon(candidate))
                            .font(.system(size: 12))
                            .frame(width: 16)
                            .foregroundStyle(tab == candidate ? DS.accentText : .secondary)
                        Text(tabTitle(candidate)).lineLimit(1)
                        if candidate == .templates, WhatsNew.pending { NewBadge() }
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
        case .dictation: Form { keysSection; languagesSection }.formStyle(.grouped)
        case .meetings: Form { meetingsSection }.formStyle(.grouped)
        case .writing: Form { readingSection; agentSection }.formStyle(.grouped)
        case .templates: Form { templatesSection }.formStyle(.grouped)
        case .general: Form { generalSection }.formStyle(.grouped)
        case .about: Form { thisMacSection; storageSection; statusSection }.formStyle(.grouped)
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
                    .modifier(revealed("translateInto"))
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

                // Interface language lives in General now (design 9.2): it
                // is about the app, not about speech.
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
                .modifier(revealed("packs"))
            } header: { Text(L("Languages")) } footer: {
                if language != "en" || translateSet {
                    Text(L("The translate key transcribes your speech, then macOS translates it on this Mac. Picking a language may download its translation data once."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
    }

    @ViewBuilder
    private var keysSection: some View {
            // The one fact that makes every row below useless, said where
            // the person comes to look when the key does nothing (audit 3.3,
            // P4). Same words and the same way out as General and the menu
            // bar — one fact, identical everywhere.
            if !axGranted {
                Section {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(DS.warn)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("Accessibility access is turned off"))
                                .font(.system(size: 12.5, weight: .medium))
                            // The onboarding's honest second sentence, here
                            // too (design 9.2): the switch is reset by macOS,
                            // not declined by the person.
                            Text(L("Dictation can hear you but cannot type. Re-enable it to continue.") + " "
                                 + L("macOS resets this switch after some updates and never asks a second time."))
                                .font(DS.helpText)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(L("Fix…")) { Permissions.openSettingsPane("Privacy_Accessibility") }
                            .buttonStyle(.dsSmall)
                            .controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.warn.opacity(0.08)))
                    .modifier(revealed("accessibility"))
                }
            }
            // — Keys (design 9.2: Keys and Languages are two headings in
            // one pane; nobody separates the key from the language it
            // speaks) —
            Section {
                LabeledContent {
                    KeyRecorder(keyName: KeyNames.displayName(hotkeyName), capture: captureMain)
                } label: {
                    rowLabel(L("Dictation key"), L("Hold to talk, release to insert what you said."))
                }
                .modifier(revealed("dictationKey"))
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
                    .modifier(revealed("translateKey"))
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
                // The speech model, named where dictation is configured
                // (design 9.2) — a sentence, not a storage row: it is
                // required and cannot be removed, so there is nothing to
                // manage, only something to know.
                rowLabel(L("Speech model"),
                         Lf("%@ · required for dictation, cannot be removed.",
                            MachineProfile.fileSizeText(Int64(ModelTier.fast.sizeMB) * 1_000_000)))
            } header: { Text(L("Keys")) } footer: {
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
                if !noticeCalls && !recordCallAudio && !separateVoices {
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
                                       : MeetingCapability.noticeCalls.addsShort,
                             warn: micDenied)
                }
                .modifier(revealed("calls"))
                LabeledContent {
                    Toggle("", isOn: $recordCallAudio).labelsHidden().toggleStyle(.switch)
                        .onChange(of: recordCallAudio) { _, v in
                            Settings.shared.recordCallAudio = v
                            OfferLedger.decided(.recordCallAudio)
                        }
                } label: {
                    rowLabel(MeetingCapability.recordCallAudio.name,
                             micDenied ? L("Waiting on microphone access.")
                                       : MeetingCapability.recordCallAudio.addsShort,
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
                    // The speaker models' size, as its own line (design 9.2):
                    // the storage row that named it is gone from About's
                    // controls, so the fact lives with the switch that uses it.
                    rowLabel(MeetingCapability.separateVoices.name,
                             recordCallAudio
                                ? MeetingCapability.separateVoices.addsShort
                                : Lf("Waits for “%@” above — there is no call audio to separate yet.",
                                     MeetingCapability.recordCallAudio.name),
                             note: L("Uses 41 MB of speaker models."))
                        .padding(.leading, 16)
                }
                .opacity(recordCallAudio ? 1 : 0.5)
                .modifier(revealed("separateVoices"))
            } header: { Text(L("Calls")) }
            Section {
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
                .modifier(revealed("calendar"))
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

                // Reading left this pane (design 9.2): everything that
                // reads a recording — summaries, outlines, reports, the
                // agent — is configured together under Summaries & reports,
                // and this pane ends by saying so.
                rowLabel(L("Summaries"),
                         L("Whether anything reads these recordings — summaries, outlines, reports and the agent — is under Summaries & reports. This pane is only about what gets recorded on this Mac."))
                Button(L("Summaries & reports")) { tab = .writing; reveal("reading") }
                    .buttonStyle(.link)
                    .controlSize(.small)
            } header: { Text(L("Meeting names")) }
    }

    // MARK: - Summaries & reports

    /// The chain, in the order it runs (design 9.2): the reading switch and
    /// its verdict, the meeting model in every state with the one Remove,
    /// the output language — then the agent, its key, and the one paragraph
    /// about what leaves this Mac. These five things fail together and are
    /// configured together; they used to be spread over four panes.
    @ViewBuilder
    private var readingSection: some View {
        Section {
            LabeledContent {
                Toggle("", isOn: $readMeetings).labelsHidden().toggleStyle(.switch)
                    .onChange(of: readMeetings) { _, v in
                        Settings.shared.readMeetings = v
                        OfferLedger.decided(.readMeetings)
                    }
            } label: {
                // The switch is shown on every Mac, engine or none: the
                // agent depends on it too, and a Mac with no engine still
                // has the agent. Under it, WHICH engine reads — or why none
                // can (design lens, 2026-09-13).
                rowLabel(MeetingCapability.readMeetings.name,
                         MeetingCapability.readMeetings.addsShort,
                         note: readingVerdict)
            }
            .modifier(revealed("reading"))
            // The downloadable meeting model — the only place it is
            // downloaded, paused, or removed. Absent on a Mac that has
            // nothing to offer AND nothing on disk (`unsupported`); a model
            // that IS on disk is shown whatever the switch says, or 2.5 GB
            // vanish with no way left to remove them (owner, 2026-09-13).
            if textModel.state != .unsupported {
                LabeledContent {
                    meetingModelControl
                } label: {
                    rowLabel(L("Meeting model"), meetingModelHelp, note: meetingModelNotice)
                }
                .modifier(revealed("meetingModel"))
            }
            // The reader's language for what the models write ABOUT a
            // meeting — the summary line and every report — as opposed to
            // the title, which keeps the meeting's own (owner, 2026-09-14).
            LabeledContent {
                ReportLanguagePicker(selection: $reportLanguage)
                    .onChange(of: reportLanguage) { _, v in Settings.shared.reportLanguage = v }
            } label: {
                rowLabel(L("Written in"),
                         L("The title keeps the meeting’s language; the summary and every report are written in this one. Field names in a report stay exactly as typed."))
            }
        } header: { Text(L("On this Mac")) }
    }

    /// What reads meetings right now, in one sentence under the switch.
    /// The shipped verdicts are reused; only downloading, paused and the
    /// too-old macOS have sentences of their own (design turn 33).
    private var readingVerdict: String {
        switch engineStatus {
        case .downloadedModel:
            return textModel.paused == .memory
                ? L("Reads with the downloaded model — paused until there is free memory.")
                : L("Reads with the downloaded model.")
        case .appleIntelligence:
            if case .downloading = textModel.state {
                return L("Reads with Apple Intelligence until the download finishes.")
            }
            return L("Reads with Apple Intelligence.")
        case .none(let apple):
            if apple == .unavailableOS {
                return L("Nothing on this Mac can read yet: Apple Intelligence needs a newer macOS. The agent with your own key still works.")
            }
            return TextModelRowCopy.engineLine(status: engineStatus,
                                               canDownload: textModel.state == .absent || textModel.state.isFailed)
        }
    }

    /// The line under "Meeting model": the price before the download, the
    /// mechanism while it runs, the fact once it is there, and why it is
    /// worth having on a Mac with nothing else to read (design 9.2).
    private var meetingModelHelp: String {
        switch textModel.state {
        case .absent, .failed:
            if case .none(let apple) = engineStatus, apple != .on {
                return L("The download is the way to get summaries on this Mac without Apple Intelligence. The transcript and search work either way.")
            }
            return Lf("One-time %@ download, then titles, summaries and outlines run entirely on this Mac. It needs 16 GB of memory to run and holds about %@ while it writes.",
                      LocalTextModelFile.sizeText, LocalTextModelFile.expectedResidentText)
        case .downloading:
            return L("One resumable file. Closing Dictate pauses it; it picks up where it stopped.")
        case .verifying:
            return L("Names, a one-line summary and a table of contents, written on this Mac.")
        case .ready:
            return MeetingTextEngines.appleIntelligence.isOn
                ? L("Runs entirely on this Mac. Without it, titles and summaries come from Apple Intelligence.")
                : textModelHint
        case .installedNotRunnable:
            return textModelHint
        case .unsupported:
            return ""
        }
    }

    /// The second caption under the model row, when the state needs one:
    /// a pause, a removal that costs nothing, or why Apple Intelligence
    /// cannot stand in.
    private var meetingModelNotice: String? {
        switch textModel.state {
        case .ready where textModel.paused == .memory:
            return L("Paused right now: not enough free memory. It resumes on its own, and the meetings waiting for a summary keep their transcripts.")
        case .installedNotRunnable:
            return L("Nothing is lost by removing it: the transcript, search and the agent do not depend on it.")
        case .absent, .failed:
            guard case .none(let apple) = engineStatus else { return nil }
            switch apple {
            case .notEligible: return L("Apple Intelligence isn’t available on this Mac, so there is nothing to fall back on.")
            case .unavailableOS: return L("Apple Intelligence needs a newer macOS than this Mac is running, so there is nothing to fall back on.")
            case .notReady: return L("macOS is still setting up Apple Intelligence. It may take a while and cannot be hurried from here.")
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The right-hand side of the model row: the value and its one action.
    @ViewBuilder
    private var meetingModelControl: some View {
        switch textModel.state {
        case .absent, .failed:
            VStack(alignment: .trailing, spacing: 6) {
                Text(L("Not downloaded")).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if case .none(.notEnabled) = engineStatus {
                        Button(L("Open System Settings…")) { Permissions.openSettingsPane("AppleIntelligence") }
                            .buttonStyle(.dsSmall).controlSize(.small)
                    }
                    textModelControl
                }
            }
        case .ready, .installedNotRunnable:
            HStack(spacing: 8) {
                Text(Lf("Installed · %@", LocalTextModelFile.sizeText))
                    .foregroundStyle(.secondary).monospacedDigit()
                Button(L("Remove…")) { confirmRemoveModel = true }
                    .buttonStyle(.dsSmall).controlSize(.small)
            }
        default:
            textModelControl
        }
    }

    // MARK: - Agent

    /// The agent, on the person's key: the connection, and the one paragraph
    /// about what leaves this Mac (design 9.2, "Your agent, on your key").
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
                        Text(L("Off: transcripts, summaries, outlines and search work as before. The agent answers questions across your meetings and writes reports from your templates; it runs in the cloud on your own API key."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if storedKey == nil {
                        // Chosen, but not connected: the one state where the
                        // pane must say the agent is still off (design 9.2).
                        Text(Lf("%@ is chosen, but there is no key yet. The agent and reports stay off until one is added.", askProvider?.productName ?? ""))
                            .font(.caption).foregroundStyle(DS.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } label: {
                rowLabel(L("Answers with"), L("Questions across your meetings, and reports."))
            }
            .modifier(revealed("answersWith"))
            // The key row belongs to the chosen provider — it appears
            // with the choice, labelled with the vendor's name, because a
            // field for a credential nobody can use yet is a question
            // with no reason behind it.
            if let provider = askProvider {
                LabeledContent {
                    apiKeyControl(for: provider, stored: storedKey)
                } label: {
                    rowLabel(provider.keyLabel,
                             storedKey == nil
                                ? Lf("A key from your own %@ account. Stored in your Keychain, never in a settings file.", provider.vendorName)
                                : L("Stored in your Keychain, never in a settings file. The agent answers questions across your meetings and writes reports from your templates."))
                }
                // The single sentence about what leaves this Mac — it used
                // to be written in three panes in three wordings. Named
                // vendor, not product: that is whose servers it reaches.
                rowLabel(L("What is sent"),
                         Lf("A question sends the question and the passages the search found. A report sends that meeting’s whole transcript — about 12,000 words for an hour of talk. Both go to %@ on your key, and only when you ask. The recordings never leave this Mac.", provider.vendorName),
                         note: L("Report templates are under Templates; written reports are in the library, under Reports."))
                Button(L("Templates")) { tab = .templates }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        } header: { Text(L("Your agent, on your key")) }
    }

    /// One Keychain read per render of the section, not one per row: the
    /// query is not free, and the window redraws on every keystroke.
    private var storedKey: String? {
        _ = keyRevision
        guard let provider = askProvider else { return nil }
        return APIKey.current(provider)
    }

    /// Why reports cannot run right now, when they cannot — pointing at the
    /// Agent tab, which is where the fix is.
    private func reportsGateLine(hasKey: Bool) -> String? {
        guard let provider = askProvider else {
            return L("Reports need the agent, which is off. Choose Claude or ChatGPT under Summaries & reports; the templates keep until then.")
        }
        guard hasKey else {
            return Lf("%@ is chosen, but there is no key yet. The agent and reports stay off until one is added.", provider.productName)
        }
        return nil
    }

    @ViewBuilder
    private var generalSection: some View {
            // — General (design 9.2): the app about the app. Appearance
            // leads — the one choice that repaints every surface, applied
            // the moment it is clicked — then the interface language (about
            // the app, not about speech), startup, and updates.
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
                        Text(L("Applies to this window, the meetings window and the panels over your other apps."))
                            .font(DS.helpText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Text(L("Appearance"))
                }
                .modifier(revealed("appearance"))
                LabeledContent {
                    InterfaceLanguagePicker()
                } label: {
                    rowLabel(L("Interface language"),
                             L("12 languages. Applies to this window and the menu bar right away. What you speak is set under Dictation."))
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
            } header: { Text(L("Startup")) } footer: {
                Text(L("With this off, Dictate is menu-bar only. Clicking the Dock icon opens Meetings; the menu bar item is always there either way."))
            }

            // The version and "am I current?" on ONE line, because they are
            // one question; the release notes and the two links under it.
            // Updates are checked daily and installed silently, so a manual
            // check is a rare, impatient act — a row here, not a menu item.
            Section {
                LabeledContent(L("Updates")) {
                    VStack(alignment: .trailing, spacing: 6) {
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
                        if let lastCheck = Self.lastUpdateCheck {
                            Text(Lf("Checked automatically · last %@", lastCheck))
                                .font(DS.helpText)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button(Lf("What’s new in %@", Self.appVersion)) {
                                NotificationCenter.default.post(name: .init("dictate.showWhatsNew"), object: nil)
                            }
                            .buttonStyle(.link)
                            Link(L("Source code"),
                                 destination: URL(string: "https://github.com/Budanovvv/Dictate")!)
                            Link(L("Report an issue"),
                                 destination: URL(string: "https://github.com/Budanovvv/Dictate/issues")!)
                        }
                        .font(.callout)
                    }
                }
                .modifier(revealed("updates"))
            }
    }

    @ViewBuilder
    private var statusSection: some View {
            // — Permissions (design 9.2 About): reported, with the way out.
            // Calendar joins the two the app cannot work without, because
            // it is the third thing macOS is asked for.
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
                    if axGranted {
                        statusBadge(ok: true, text: L("Granted"))
                    } else {
                        // The line points at the Dictation pane, whose
                        // warning explains the switch and opens the right
                        // System Settings pane (design 9.2 About; turn 33).
                        Button { tab = .dictation; reveal("accessibility") } label: {
                            statusBadge(ok: false, text: L("Off — dictation cannot type"))
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                    }
                }
                LabeledContent(L("Calendar")) {
                    statusBadge(ok: MeetingCalendar.hasAccess,
                                text: MeetingCalendar.hasAccess ? L("Granted") : L("No"))
                }
            } header: { Text(L("Permissions")) }
            // Diagnostics last (design 9.2 About): the one action on the
            // pane, and it sets nothing either.
            Section {
                LabeledContent {
                    Button(diagnosticsCopied ? L("Copied") : L("Copy diagnostics")) { copyDiagnostics() }
                        .buttonStyle(.dsSmall)
                        .controlSize(.small)
                } label: {
                    rowLabel(L("Diagnostics"),
                             L("Mac, macOS, version and which features are on. No transcripts, no keys."))
                }
            } header: { Text(L("Diagnostics")) } footer: {
                // The pane's contract, at its foot (design 9.2).
                Text(L("Nothing is set here. Every line above either reports what this Mac can do or points at the pane that owns it."))
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
                // needs only the sentence — and with no templates at all,
                // what one is and where a report comes from.
                Text(templateStore.templates.isEmpty
                     ? L("No templates yet. A template is a name, an optional Context and a few fields; a report is written from it on demand from a meeting’s card, one per template per meeting.")
                     : L("A template is a name, an optional Context and a few fields. A report is written from it on demand, one per template per meeting."))
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
                // Why nothing can be written right now, pointing at the pane
                // that owns the fix (design 9.2).
                if let gate = reportsGateLine(hasKey: storedKey != nil) {
                    // The sentence is the link: Summaries & reports ›
                    // Answers with, revealed (design turn 33).
                    Button { tab = .writing; reveal("answersWith") } label: {
                        Text(gate)
                            .font(.caption).foregroundStyle(DS.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
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
                    rowLabel(L("Context"), L("Optional. One paragraph for the whole template. Sent with every report."))
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
                        Button(L("Remove template…")) { confirmRemoveTemplate = true }
                            .buttonStyle(.dsSmall).controlSize(.small)
                        // Export leaves for the library's Reports collection
                        // in the next pass; until then the function stays
                        // reachable here (deviation from 9.2, recorded).
                        Button(L("Export reports…")) { ReportExport.exportAll(template: draft) }
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
                    // The count as a fact beside Remove (design 9.2): what
                    // stays if this template goes.
                    let count = reportCounts[draft.id]
                    rowLabel(L("Remove template"),
                             count.map { Lf("%d meetings have a %@ report. They stay if this template goes.", $0, draft.name) })
                }
            }
        }
    }

    /// Meetings per template that carry a report from it. Read through the
    /// archive index on a background queue — the archive may be in iCloud,
    /// and a listing on main is how the app once hung for 16 s (GRABLI).
    private func countReports() {
        let youLabel = L("You")
        DispatchQueue.global(qos: .utility).async {
            var counts: [UUID: Int] = [:]
            for meeting in MeetingArchive.list(youLabel: youLabel) {
                for id in Set(meeting.reports.compactMap(\.templateID)) {
                    counts[id, default: 0] += 1
                }
            }
            DispatchQueue.main.async {
                // Every template known now gets a number, zero included —
                // a template outside the map has simply not been counted.
                var filled = counts
                for template in templateStore.templates { filled[template.id, default: 0] += 0 }
                reportCounts = filled
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
                rowLabel(L("Speech model"),
                         Lf("%@ · required for dictation, cannot be removed.",
                            MachineProfile.fileSizeText(Int64(ModelTier.fast.sizeMB) * 1_000_000)))
            }
            // About only reports (design 9.2): the one Remove lives under
            // Summaries & reports, and this row points there.
            LabeledContent {
                HStack(spacing: 8) {
                    Text(storage.map { MachineProfile.fileSizeText($0.meetingModelBytes) } ?? LocalTextModelFile.sizeText)
                        .foregroundStyle(.secondary).monospacedDigit()
                    Button(L("Summaries & reports")) { tab = .writing; reveal("meetingModel") }
                        .buttonStyle(.link).controlSize(.small)
                }
            } label: {
                rowLabel(L("Meeting model"), meetingModelStorageHint)
            }
            if let storage, storage.speakerModelBytes > 0 {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(MachineProfile.fileSizeText(storage.speakerModelBytes))
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button(L("Meetings")) { tab = .meetings; reveal("separateVoices") }
                            .buttonStyle(.link).controlSize(.small)
                    }
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
                rowLabel(L("Meeting archive"),
                         storage.map { Lf("%d meetings, reports included", $0.meetingCount) }
                             ?? L("Your transcripts, as Markdown files you own."))
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
        .modifier(revealed("storage"))
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
            Button(L("Remove…")) { confirmRemoveModel = true }
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
        // "pane" or "pane/row" — the row is revealed (design turn 33, the
        // deep-link table). Old pane names still land somewhere sensible.
        let parts = wanted.split(separator: "/", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "dictation", "keys", "languages": tab = .dictation
        case "meetings": tab = .meetings
        case "writing", "agent": tab = .writing
        case "templates": tab = .templates
        case "general": tab = .general
        case "about", "thismac": tab = .about
        default: tab = .dictation
        }
        if parts.count > 1 { reveal(parts[1]) }
        Log.d("corner: settings landed on \(wanted)")
    }

    /// Tint the named row for a moment — the deep link's "revealed".
    private func reveal(_ row: String) {
        revealRow = row
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if revealRow == row { withAnimation(.easeOut(duration: DS.reveal)) { revealRow = nil } }
        }
    }

    /// The tint a revealed row carries, applied to the row's content.
    private func revealed(_ row: String) -> some ViewModifier {
        RevealTint(on: revealRow == row)
    }
}

/// The deep link's landing: the row tinted the sidebar's selection colour
/// for a moment, then back to nothing.
private struct RevealTint: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? DS.selectionTint : .clear))
            .padding(.horizontal, -6)
            .padding(.vertical, -3)
            .animation(.easeOut(duration: DS.reveal), value: on)
    }
}

extension SettingsView {

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
