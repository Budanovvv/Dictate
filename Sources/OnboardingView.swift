import AppKit
import ServiceManagement
import SwiftUI

/// First-launch wizard: welcome → model → key → permissions → try-out.
struct OnboardingView: View {
    let finish: () -> Void
    let dictation: DictationController

    @ObservedObject private var loc = Localization.shared
    @State private var step = 0
    @State private var allGranted = Permissions.allGranted

    enum ModelState: Equatable { case notReady, downloading(Double), ready }
    @State private var modelState: ModelState =
        WhisperEngine.shared.isModelDownloaded(tier: Settings.shared.modelTier) ? .ready : .notReady

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
        .onReceive(timer) { _ in allGranted = Permissions.allGranted }
        .onChange(of: step) { s in
            // Once past the model step, load it into memory in the background
            // so the "try it" dictation is instant — no visible warm-up.
            if s >= 2 { dictation.preloadModel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: ModelStep(state: $modelState)
        case 2: HotkeyStep()
        case 3: PermissionsStep()
        default: TryItStep(dictation: dictation)
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
            Button(L("Finish")) { finish() }.keyboardShortcut(.defaultAction)
        default:
            Button(L("Next")) { step += 1 }.keyboardShortcut(.defaultAction)
        }
    }

    private func startDownload() {
        let tier = Settings.shared.modelTier
        modelState = .downloading(0)
        Task {
            do {
                try await WhisperEngine.shared.prepare(tier: tier) { p in
                    DispatchQueue.main.async { modelState = .downloading(p) }
                }
                await MainActor.run { modelState = .ready; step += 1 }
            } catch {
                await MainActor.run { modelState = .notReady }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("On-device recognition")).font(.title.bold())
            Text(L("Recognition runs on your Mac's Neural Engine — Whisper large-v3, the best open model there is, 112 languages. Your voice never leaves this computer."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if case .downloading(let p) = state {
                VStack(alignment: .leading, spacing: 10) {
                    if p < 0.999 {
                        Text(L("Downloading model…")).font(.headline)
                        ProgressView(value: p).frame(maxWidth: 360)
                        Text(Lf("Downloaded %d of %d MB", Int(p * 950), 950))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Lf("About %@ — downloaded once. This is the only time Dictate needs the internet.", L(Settings.shared.modelTier.sizeHint)))
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
                Text(Lf("About %@ — downloaded once. This is the only time Dictate needs the internet.", L(Settings.shared.modelTier.sizeHint)))
                    .font(.headline)
            }
            Spacer()
        }
    }
}

// MARK: - Step 3: hotkey + translate key

private struct HotkeyStep: View {
    @StateObject private var mainCapture = KeyCapture()
    @StateObject private var translateCapture = KeyCapture()
    @State private var mainName = Settings.shared.hotkeyName
    @State private var translateName = Settings.shared.translateKeyName
    @State private var translateSet = Settings.shared.translateKeyCode != nil
    @State private var unsafeKey = !KeyNames.isSafeHotkey(Settings.shared.hotkeyKeyCode)
    @State private var language = Settings.shared.language

    private var languageOptions: [(code: String, name: String)] {
        LanguageList.options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Two keys, two results")).font(.title.bold())
            Text(L("Hold a key and speak. The key you hold decides what gets typed."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(L("You'll dictate in:")).foregroundStyle(.secondary)
                Picker("", selection: $language) {
                    Text(L("Automatic (detect any language)")).tag("")
                    ForEach(languageOptions, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: language) { code in
                    Settings.shared.language = code
                    assignDefaultTranslateKeyIfNeeded()
                }
            }

            HStack(alignment: .top, spacing: 14) {
                KeyCard(
                    title: L("Dictation"),
                    caption: L("Types exactly what you say"),
                    keyName: KeyNames.displayName(mainName),
                    tint: Brand.indigo,
                    capture: mainCapture
                )
                if language != "en" {
                    KeyCard(
                        title: L("Translate to English"),
                        caption: L("Same speech — typed in English"),
                        keyName: translateSet ? KeyNames.displayName(translateName) : L("Not set"),
                        tint: Brand.cyan,
                        capture: translateCapture
                    )
                }
            }
            .onReceive(mainCapture.$capturedKeyCode) { code in
                guard let code, let capturedName = mainCapture.capturedName else { return }
                guard code != Settings.shared.translateKeyCode else { return }
                Settings.shared.hotkeyKeyCode = code
                Settings.shared.hotkeyName = capturedName
                mainName = capturedName
                unsafeKey = !KeyNames.isSafeHotkey(code)
            }
            .onReceive(translateCapture.$capturedKeyCode) { code in
                guard let code, let capturedName = translateCapture.capturedName else { return }
                guard code != Settings.shared.hotkeyKeyCode else { return }
                Settings.shared.translateKeyCode = code
                Settings.shared.translateKeyName = capturedName
                translateName = capturedName
                translateSet = true
            }

            if language == "en" {
                Text(L("Not needed — you already dictate in English."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if unsafeKey {
                Label(L("This key types characters — they'll end up in your text while you hold it. A modifier (Option, Cmd, Shift, Ctrl) or an F-key is safer."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L("Set to your system language — keep it or choose another."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear { assignDefaultTranslateKeyIfNeeded() }
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
        translateName = "Right Command (⌘)"
        translateSet = true
    }
}

/// A keycap-style card: the key drawn like a physical key (matching the app
/// icon), with what holding it produces. The onboarding "scheme" is live —
/// these are the real assigned keys.
private struct KeyCard: View {
    let title: String
    let caption: String
    let keyName: String
    let tint: Color
    @ObservedObject var capture: KeyCapture

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)

            // Keycap with a visible "side" below — pseudo-3D, like the app icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.45))
                    .offset(y: 4)
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), tint.opacity(0.10)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.5), lineWidth: 1))
                Text(keyName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(height: 52)

            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(capture.capturing ? L("Press a key… (Esc to cancel)") : L("Change")) {
                capture.begin()
            }
            .controlSize(.small)
            .disabled(capture.capturing)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.35)))
    }
}

struct KeyCap: View {
    let name: String
    var muted: Bool = false
    var body: some View {
        Text(name)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.vertical, 4).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(muted ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.accentColor.opacity(0.15))))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(muted ? AnyShapeStyle(.clear) : AnyShapeStyle(Color.accentColor.opacity(0.35)), lineWidth: 1))
    }
}

/// Optional translate-to-English key; hidden when the spoken language is English.
struct TranslateKeyPicker: View {
    var onChanged: (() -> Void)? = nil
    var spokenLanguage: String = Settings.shared.language
    @StateObject private var capture = KeyCapture()
    @State private var name = Settings.shared.translateKeyName
    @State private var isSet = Settings.shared.translateKeyCode != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Translate to English (optional)"), systemImage: "character.bubble")
                .font(.headline)
                .foregroundStyle(spokenLanguage == "en" ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            if spokenLanguage == "en" {
                Text(L("Not needed — you already dictate in English."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("Think in your language — send in English. Hold this second key, speak any of 112 languages, and English text is typed. Translated on your Mac, like everything else. The main key still types what you said."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    KeyCap(name: isSet ? KeyNames.displayName(name) : L("Not set"), muted: !isSet)
                    Spacer()
                    Button(capture.capturing ? L("Press a key… (Esc to cancel)") : L("Set key")) {
                        capture.begin()
                    }
                    .disabled(capture.capturing)
                    if isSet {
                        Button(L("Remove")) {
                            Settings.shared.translateKeyCode = nil
                            Settings.shared.translateKeyName = ""
                            isSet = false
                            onChanged?()
                        }
                    }
                }
                .onReceive(capture.$capturedKeyCode) { code in
                    guard let code, let capturedName = capture.capturedName else { return }
                    guard code != Settings.shared.hotkeyKeyCode else { return }
                    Settings.shared.translateKeyCode = code
                    Settings.shared.translateKeyName = capturedName
                    name = capturedName
                    isSet = true
                    onChanged?()
                }
            }
        }
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
    @State private var text = ""
    @State private var listening = false
    @State private var stats: (words: Int, seconds: Double)?
    @State private var didPlain = false
    @State private var didTranslate = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var mainKey: String { KeyNames.displayName(Settings.shared.hotkeyName) }
    private var translateKey: String? {
        Settings.shared.translateKeyCode != nil && Settings.shared.language != "en"
            ? KeyNames.displayName(Settings.shared.translateKeyName) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Try it out")).font(.title.bold())
            TryTask(done: didPlain,
                    text: Lf("Hold %@ and say something — the recognized text shows up below.", mainKey))
            if let tk = translateKey {
                TryTask(done: didTranslate,
                        text: Lf("Hold %@ instead to get it in English.", tk))
            }

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
        .onAppear {
            dictation.suppressInsertion = true
            dictation.onResultText = { [weak dictation] t in
                DispatchQueue.main.async {
                    if !t.isEmpty {
                        text = t
                        stats = dictation?.lastStats
                        if dictation?.lastWasTranslate == true { didTranslate = true }
                        else { didPlain = true }
                    }
                }
            }
            dictation.restart()          // restart key capture with the current keys
            listening = true
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
