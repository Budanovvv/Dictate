import AppKit
import ServiceManagement
import SwiftUI

/// First-launch wizard: welcome → model → key → permissions → try-out.
struct OnboardingView: View {
    let finish: () -> Void
    let dictation: DictationController

    @ObservedObject private var loc = Localization.shared
    /// A user who already finished onboarding lands here for one reason only —
    /// a permission stopped working (seen live: an app update left a stale
    /// Accessibility entry). Don't march them through welcome/model/keys
    /// again; open straight on the permissions step.
    @State private var step = Settings.shared.onboardingDone ? 3 : 0
    @State private var allGranted = Permissions.allGranted

    enum ModelState: Equatable { case notReady, downloading(Double), ready }

    /// Models needed at onboarding — one, since translation moved to macOS.
    static var onboardingTiers: [ModelTier] { [.fast] }

    @State private var modelState: ModelState =
        OnboardingView.onboardingTiers.allSatisfy { WhisperEngine.shared.isModelDownloaded(tier: $0) }
            ? .ready : .notReady
    @State private var downloadFailed = false
    @State private var downloadTotalMB = OnboardingView.onboardingTiers.map(\.sizeMB).reduce(0, +)
    /// At least one try-out task completed — only then Return triggers Finish,
    /// so the aha-moment can't be skipped by a reflexive Enter (the button
    /// itself stays clickable always: no hard gate).
    @State private var tryTaskDone = false
    /// Spoken language and translate target live here, not in HotkeyStep: the
    /// step view is recreated on every `step` change (`.id(step)`), and the
    /// translation-data fetch below has to survive that.
    @State private var obLanguage = Settings.shared.language
    @State private var obTranslateTarget = Settings.shared.translateTargetCode
    /// Bumped on entering the keys step so TranslatePrepareView actually
    /// fetches (its first pass only reports status — see arm()).
    @State private var obPrepareReload = 0

    private let totalSteps = 5
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            StepDots(current: step, total: totalSteps)
                .padding(.top, 18)
            content
                .id(step)   // new step = new view → triggers the transition
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 14)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 540)
        .tint(Brand.indigo)
        .animation(.easeInOut(duration: 0.28), value: step)
        // Only the permissions step's Next button needs the poll (the step
        // view itself has its own timer for the badges).
        .onReceive(timer) { _ in if step == 3 { allGranted = Permissions.allGranted } }
        .onChange(of: step) { s in
            if s == 3 { allGranted = Permissions.allGranted }
            // Once past the model step, load it into memory in the background
            // so the "try it" dictation is instant — no visible warm-up.
            if s >= 2 { dictation.preloadModel() }
            // Fetch the translation data while a real window is on screen:
            // macOS attaches its consent sheet to it. At the first dictation
            // there is no such window and the download can't be asked for.
            if s == 2 { obPrepareReload += 1 }
        }
        // Hung off the ROOT, not off the step content: that content is rebuilt
        // from scratch on every step change (`.id(step)`), which would tear the
        // session down together with the system dialog it just opened.
        .background {
            TranslatePrepareView(targetCode: obTranslateTarget,
                                 sourceCode: obLanguage.isEmpty ? nil : obLanguage,
                                 reload: obPrepareReload,
                                 onState: { _ in })
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: ModelStep(state: $modelState, failed: downloadFailed, totalMB: downloadTotalMB)
        case 2: HotkeyStep(language: $obLanguage, translateTarget: $obTranslateTarget)
        case 3: PermissionsStep()
        default: TryItStep(dictation: dictation, taskDone: $tryTaskDone)
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 && !isDownloading {
                Button(L("Back")) { step -= 1 }
            }
            Spacer()
            footerPrimary
        }
    }

    private var isDownloading: Bool {
        if case .downloading = modelState { return true }
        return false
    }

    @ViewBuilder
    private var footerPrimary: some View {
        switch step {
        case 1:
            switch modelState {
            case .ready:
                Button(L("Next")) { step += 1 }.keyboardShortcut(.defaultAction)
            case .downloading:
                ProgressView().controlSize(.small)
            case .notReady:
                Button(L("Download & continue")) { startDownload() }
                    .keyboardShortcut(.defaultAction)
            }
        case 3:
            Button(L("Next")) { step += 1 }
                .keyboardShortcut(.defaultAction)
                .disabled(!allGranted)
        case totalSteps - 1:
            if tryTaskDone {
                Button(L("Finish")) { finish() }.keyboardShortcut(.defaultAction)
            } else {
                Button(L("Finish")) { finish() }
            }
        default:
            Button(L("Next")) { step += 1 }.keyboardShortcut(.defaultAction)
        }
    }

    private func startDownload() {
        // Both models in one visible download with a weighted combined bar —
        // so the translate try-out later is instant, not a surprise download.
        // download() only fetches; loading into the Neural Engine happens in
        // the background (preloadModel on step ≥2) so the bar never freezes.
        let tiers = Self.onboardingTiers.filter { !WhisperEngine.shared.isModelDownloaded(tier: $0) }
        let totalMB = Double(tiers.map(\.sizeMB).reduce(0, +))
        downloadTotalMB = Int(totalMB)
        modelState = .downloading(0)
        downloadFailed = false
        Task {
            do {
                var doneMB = 0.0
                for tier in tiers {
                    try await WhisperEngine.shared.download(tier: tier) { p in
                        let overall = (doneMB + p * Double(tier.sizeMB)) / totalMB
                        DispatchQueue.main.async { modelState = .downloading(overall) }
                    }
                    doneMB += Double(tier.sizeMB)
                }
                await MainActor.run {
                    modelState = .ready
                    dictation.preloadModel()   // start the ANE compile now, in the background
                    step += 1
                }
            } catch {
                // Say WHY the button is suddenly back — a ~1 GB download
                // failing without a word looks like the app is broken.
                await MainActor.run { modelState = .notReady; downloadFailed = true }
            }
        }
    }
}

// MARK: - Progress indicator

private struct StepDots: View {
    let current: Int
    let total: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? AnyShapeStyle(Brand.gradientDiagonal)
                                       : AnyShapeStyle(Color.secondary.opacity(0.25)))
                    .frame(width: i == current ? 22 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: current)
            }
        }
    }
}

// MARK: - Interface language picker

struct LanguageMenu: View {
    @ObservedObject private var loc = Localization.shared
    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { lang in
                Button(lang.label) { loc.setLanguage(lang) }
            }
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Step 1: welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            HStack { Spacer(); LanguageMenu() }
            WaveMark(height: 62)
                .padding(.top, 6)
            Text("Dictate")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.gradientDiagonal)
            Text(L("Voice dictation in any app"))
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Hold the chosen key — recording starts"), systemImage: "hand.point.down.fill")
                Label(L("Speak while holding it"), systemImage: "waveform")
                Label(L("Release — the text is typed where your cursor is"), systemImage: "text.cursor")
                // The second half of the product, named on the very first
                // screen: without it the mental model locks onto "one key,
                // plain dictation" and the translate card on the keys step
                // reads as a setting, not a feature (seen in a live user test).
                // Cyan = the translate color throughout the app.
                Label {
                    Text(L("And there's a second key: speak your own language — it types English."))
                } icon: {
                    Image(systemName: "globe").foregroundStyle(Brand.cyan)
                }
                .padding(.top, 2)
            }
            .padding(.top, 8)
            Text(L("Everything runs on your Mac — no cloud, no account, no subscription. Turn Wi-Fi off: it still works."))
                .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
        }
    }
}

// MARK: - Step 2: model download

private struct ModelStep: View {
    @Binding var state: OnboardingView.ModelState
    var failed = false
    var totalMB = ModelTier.fast.sizeMB

    private var sizeHint: String {
        totalMB >= 1000 ? String(format: "~%.1f GB", Double(totalMB) / 1000) : "~\(totalMB) MB"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("On-device recognition")).font(.title.bold())
            Text(L("Recognition runs on your Mac's Neural Engine — Whisper large-v3-turbo: 112 languages, great with accents, fast enough for live text. Translation runs on this Mac too. Your voice never leaves this computer."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if case .downloading(let p) = state {
                VStack(alignment: .leading, spacing: 10) {
                    if p < 0.999 {
                        Text(L("Downloading model…")).font(.headline)
                        ProgressView(value: p).frame(maxWidth: 360)
                        Text(Lf("Downloaded %d of %d MB", Int(p * Double(totalMB)), totalMB))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Lf("About %@ — downloaded once. This is the only time Dictate needs the internet.", sizeHint))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Preparing the model for the Neural Engine… A few minutes, one time."))
                                .font(.headline)
                        }
                    }
                }
                .padding(.top, 6)
            } else if state == .ready {
                Label(L("Model ready"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).padding(.top, 4)
            } else {
                Text(Lf("About %@ — downloaded once. This is the only time Dictate needs the internet.", sizeHint))
                    .font(.headline)
                if failed {
                    Label(L("Download failed. Check your connection and retry."),
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Step 3: hotkey + translate key

private struct HotkeyStep: View {
    private enum Target { case dictation, translate }

    /// Owned by OnboardingView — the translation-data fetch hangs off the root
    /// and has to see these change (this view is recreated on every step).
    @Binding var language: String
    @Binding var translateTarget: String

    @StateObject private var capture = KeyCapture()
    @State private var mainCode = Settings.shared.hotkeyKeyCode
    @State private var mainName = Settings.shared.hotkeyName
    @State private var translateCode = Settings.shared.translateKeyCode
    @State private var translateName = Settings.shared.translateKeyName
    @State private var translateSet = Settings.shared.translateKeyCode != nil
    @State private var unsafeKey = !KeyNames.isSafeHotkey(Settings.shared.hotkeyKeyCode)
    @State private var armed = Target.dictation
    /// One-shot cyan ring on the Translate card when it first appears — the
    /// card materializes while the user's eyes are on the language picker,
    /// so its arrival needs a beat of motion to be seen at all.
    @State private var translateCardPulsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Two keys, two results")).font(.title.bold())
            Text(L("Hold a key and speak. The key you hold decides what gets typed."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(L("You'll dictate in:")).foregroundStyle(.secondary)
                LanguagePicker(selection: $language, tint: Brand.indigo)
                    .onChange(of: language) { code in
                        Settings.shared.language = code
                        assignDefaultTranslateKeyIfNeeded()
                        if code == "en" { armed = .dictation }
                    }
            }

            // The translate key's target, decided here rather than buried in
            // settings: a non-English speaker who wants, say, German has no
            // reason to discover it later. Hidden for English speakers — the
            // translate key itself doesn't exist for them.
            if language != "en" {
                HStack(spacing: 8) {
                    Text(L("Translate to") + ":").foregroundStyle(.secondary)
                    Picker("", selection: $translateTarget) {
                        ForEach(SettingsView.translateTargets, id: \.self) { code in
                            Text(code == "en" ? "English" : LanguageList.endonym(for: code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: translateTarget) { Settings.shared.translateTargetCode = $0 }
                }
            }

            // Pick which key you're assigning; each chip shows its current binding.
            HStack(spacing: 10) {
                TargetChip(title: L("Dictation"),
                           caption: L("Types exactly what you say"),
                           keyName: KeyNames.displayName(mainName),
                           tint: Brand.indigo,
                           armed: armed == .dictation) { armed = .dictation }
                if language != "en" {
                    TargetChip(title: translateChipTitle,
                               caption: translateChipCaption,
                               keyName: translateSet ? KeyNames.displayName(translateName) : L("Not set"),
                               tint: Brand.cyan,
                               armed: armed == .translate) { armed = .translate }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Brand.cyan.opacity(translateCardPulsed ? 0 : 0.8), lineWidth: 2.5)
                            .scaleEffect(translateCardPulsed ? 1.07 : 1)
                            .allowsHitTesting(false))
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.1).delay(0.35)) {
                                translateCardPulsed = true
                            }
                        }
                }
            }
            .animation(.spring(duration: 0.35), value: language == "en")

            // Safe-key schematic — click a key to bind it to the armed target.
            HotkeyKeyboard(
                dictationCode: mainCode,
                translateCode: language == "en" ? nil : translateCode,
                dictationTint: Brand.indigo,
                translateTint: Brand.cyan
            ) { code, name in assign(code, name) }

            HStack(spacing: 8) {
                Text(armed == .dictation
                     ? L("Setting the Dictation key — click one above, or press a key.")
                     : L("Setting the Translate key — click one above, or press a key."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(capture.capturing ? L("Press a key… (Esc)") : L("Press a key…")) {
                    capture.begin()
                }
                .controlSize(.small).disabled(capture.capturing)
            }

            if unsafeKey {
                Label(L("This key types characters — they'll end up in your text while you hold it. A modifier (Option, Cmd, Shift, Ctrl) or an F-key is safer."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .onAppear { assignDefaultTranslateKeyIfNeeded() }
        .onDisappear { capture.cancel() }   // don't leave a live key monitor behind
        .onReceive(capture.$capturedKeyCode) { code in
            guard let code, let name = capture.capturedName else { return }
            assign(code, name)
        }
    }

    /// English gets its own wording — "typed in English" reads better than the
    /// generic "translated to X" the other targets need.
    private var translateChipTitle: String {
        translateTarget == "en"
            ? L("Translate → English")
            : Lf("Translate → %@", LanguageList.endonym(for: translateTarget))
    }

    private var translateChipCaption: String {
        translateTarget == "en"
            ? L("Same speech — typed in English")
            : Lf("Same speech — translated to %@", LanguageList.endonym(for: translateTarget))
    }

    /// Assign a key (from a schematic click or a physical press) to whichever
    /// target is armed. Guards against binding the same physical key to both.
    private func assign(_ code: Int, _ name: String) {
        switch armed {
        case .dictation:
            guard code != translateCode else { return }
            Settings.shared.hotkeyKeyCode = code
            Settings.shared.hotkeyName = name
            mainCode = code
            mainName = name
            unsafeKey = !KeyNames.isSafeHotkey(code)
        case .translate:
            guard code != mainCode else { return }
            Settings.shared.translateKeyCode = code
            Settings.shared.translateKeyName = name
            translateCode = code
            translateName = name
            translateSet = true
        }
    }

    /// The translate key comes pre-assigned (right ⌘) for non-English speakers:
    /// a default they can change beats an optional they never notice.
    private func assignDefaultTranslateKeyIfNeeded() {
        guard !Settings.shared.onboardingDone,
              Settings.shared.translateKeyCode == nil,
              Settings.shared.language != "en",
              Settings.shared.hotkeyKeyCode != 54 else { return }
        Settings.shared.translateKeyCode = 54
        Settings.shared.translateKeyName = "Right Command (⌘)"
        translateCode = 54
        translateName = "Right Command (⌘)"
        translateSet = true
    }
}

/// A chip for one dictation role: its title and the key currently bound to it,
/// with an armed ring marking it as the target a schematic click or a press will
/// assign. Tapping arms it.
private struct TargetChip: View {
    let title: String
    let caption: String
    let keyName: String
    let tint: Color
    let armed: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(keyName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(armed ? 0.14 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(armed ? 0.9 : 0.0), lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(armed ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Step 4: permissions

private struct PermissionsStep: View {
    @State private var mic = Permissions.microphone
    @State private var ax = Permissions.accessibility
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("macOS permissions")).font(.title.bold())
            Text(L("Two permissions, granted once — each does exactly one job. Dictate doesn't read your screen, doesn't log your typing, and doesn't send anything anywhere: recognition is fully on this Mac. When both turn green, you're ready."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            PermissionRow(icon: "mic.fill", tint: Brand.indigo,
                          title: L("Microphone"),
                          explain: L("listens only during a dictation you started — never in the background on its own"),
                          status: mic) {
                Permissions.requestMicrophoneIfNeeded { _ in refresh() }
            }
            PermissionRow(icon: "accessibility", tint: .purple,
                          title: L("Accessibility"),
                          explain: L("for exactly two things: to hear your dictation key and to type the text for you. Nothing else."),
                          status: ax) {
                Permissions.promptAccessibilityIfNeeded()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("In the macOS window, click “Open System Settings” and turn on the switch next to Dictate. (If you accidentally hit “Deny”, no harm done — the “No window appeared?” link below opens the same settings.)"))
                // The stale-entry dead end (seen live after an app update): the
                // switch in System Settings is already ON, yet macOS reports
                // "not trusted", the prompt won't reappear — and without this
                // hint there is NOTHING the user can click to move forward.
                if Settings.shared.onboardingDone, ax != .granted {
                    Label(L("Already ON in System Settings but not green here? Turn the Dictate switch off and back on — after an app update macOS sometimes keeps a stale entry."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button(L("No window appeared? Open settings manually")) {
                    Permissions.openSettingsPane("Privacy_Accessibility")
                }
                .buttonStyle(.link).font(.caption)
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .onReceive(timer) { _ in refresh() }
        .onAppear { Permissions.registerAccessibilityQuietly(); refresh() }
    }

    private func refresh() {
        mic = Permissions.microphone
        ax = Permissions.accessibility
    }
}

private struct PermissionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let explain: String
    let status: Permissions.Status
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(explain).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(.green)
            } else {
                Button(L("Allow"), action: action)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - Step 5: try it out

private struct TryItStep: View {
    let dictation: DictationController
    @Binding var taskDone: Bool
    @State private var text = ""
    @State private var stats: (words: Int, seconds: Double)?
    @State private var didPlain = false
    @State private var didTranslate = false
    /// One short spring on the translate task right after the plain task
    /// succeeds — steers the eye to "same phrase, other key" at the exact
    /// moment of the first success.
    @State private var nudgeTranslate = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// The first Neural Engine compile can outlast walking the steps. The
    /// try-out must SAY it's still preparing — a silent "Warming up" pill only
    /// after a keypress reads as a hang (the warm-up rake, round two).
    @State private var engineReady = false
    private let readyTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var mainKey: String { KeyNames.displayName(Settings.shared.hotkeyName) }
    private var translateKey: String? {
        Settings.shared.translateKeyCode != nil && Settings.shared.language != "en"
            ? KeyNames.displayName(Settings.shared.translateKeyName) : nil
    }

    /// English keeps its shorter phrasing; other targets name the language.
    private func translateTaskText(key: String) -> String {
        let target = Settings.shared.translateTargetCode
        return target == "en"
            ? Lf("Hold %@ and say it again — this time it's typed in English.", key)
            : Lf("Hold %@ and say it again — this time it comes out in %@.",
                 key, LanguageList.endonym(for: target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Try it out")).font(.title.bold())
            // Honest state while the one-time Neural Engine compile is still
            // running: the tasks stay visible but dimmed, and the banner says
            // what the wait is — without it the first keypress just shows a
            // "Warming up" pill and reads as a hang.
            if !engineReady {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Preparing the model for the Neural Engine… A few minutes, one time."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Group {
                TryTask(done: didPlain,
                        text: Lf("Hold %@ and say something — the recognized text shows up below.", mainKey))
                if let tk = translateKey {
                    TryTask(done: didTranslate, text: translateTaskText(key: tk))
                        .scaleEffect(nudgeTranslate ? 1.05 : 1, anchor: .leading)
                        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: nudgeTranslate)
                }
            }
            .opacity(engineReady ? 1 : 0.45)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                if text.isEmpty {
                    Text(L("Recognized text appears here…"))
                        .foregroundStyle(.tertiary).padding(12)
                }
                ScrollView {
                    Text(text).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            .frame(height: 150)

            if let stats {
                Label(Lf("Words: %d · %.1f s", stats.words, stats.seconds),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.monospacedDigit())
            } else {
                Text(L("Changed your mind? Esc cancels the recording."))
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Toggle(L("Launch at login"), isOn: $launchAtLogin)
                .toggleStyle(.switch).controlSize(.small)
                .onChange(of: launchAtLogin) { on in
                    if on { try? SMAppService.mainApp.register() }
                    else { try? SMAppService.mainApp.unregister() }
                }

            Spacer()
        }
        .onReceive(readyTimer) { _ in
            guard !engineReady else { return }
            Task {
                let ready = await WhisperEngine.shared.isReady(for: .fast)
                await MainActor.run { engineReady = ready }
            }
        }
        .onAppear {
            Task {
                let ready = await WhisperEngine.shared.isReady(for: .fast)
                await MainActor.run { engineReady = ready }
            }
            dictation.suppressInsertion = true
            dictation.onResultText = { [weak dictation] t in
                DispatchQueue.main.async {
                    if !t.isEmpty {
                        text = t
                        stats = dictation?.lastStats
                        if dictation?.lastWasTranslate == true {
                            didTranslate = true
                        } else {
                            let firstPlain = !didPlain
                            didPlain = true
                            // First success + translate untried → nudge task 2.
                            if firstPlain, !didTranslate, translateKey != nil {
                                nudgeTranslate = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    nudgeTranslate = false
                                }
                            }
                        }
                        taskDone = true
                    }
                }
            }
            dictation.restart()          // restart key capture with the current keys
        }
        .onDisappear {
            dictation.suppressInsertion = false
            dictation.onResultText = nil
        }
    }
}

/// A try-it task with a checkmark that fills once completed.
private struct TryTask: View {
    let done: Bool
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            Text(text)
                .foregroundStyle(done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.2), value: done)
    }
}
