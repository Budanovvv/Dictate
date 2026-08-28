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
    @State private var step: Int = {
        // Screenshot harness (design pass): open at a named step.
        if let wanted = UserDefaults.standard.string(forKey: "debugShotStep"),
           let n = Int(wanted) {
            UserDefaults.standard.removeObject(forKey: "debugShotStep")
            return min(max(n, 0), 4)
        }
        return Settings.shared.onboardingDone ? 3 : 0
    }()
    @State private var allGranted = Permissions.allGranted

    enum ModelState: Equatable { case notReady, downloading(Double), ready }

    /// Models needed at onboarding — one, since translation moved to macOS.
    static var onboardingTiers: [ModelTier] { [.fast] }

    @State private var modelState: ModelState =
        OnboardingView.onboardingTiers.allSatisfy { WhisperEngine.shared.isModelDownloaded(tier: $0) }
            ? .ready : .notReady
    @State private var downloadFailed = false
    /// "8.4 MB/s · about 30 sec left" while downloading (nil before the first
    /// stable reading).
    @State private var downloadRate: String?
    /// The download was refused before it began: not enough disk.
    @State private var diskShortfall: (needed: Int, free: Int)?
    @State private var downloadTotalMB = OnboardingView.onboardingTiers.map(\.sizeMB).reduce(0, +)
    /// How many MB had landed when a download stopped — the design's failed
    /// state names the number ("The download stopped at 412 MB").
    @State private var downloadedMB = 0
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
            // Design 12j: the title bar carries the progress — "Step N of 5",
            // small and right-aligned, where the eye checks "how much is left"
            // without a row of dots stealing a line of content. The window's
            // native title is hidden (fullSizeContentView); the traffic lights
            // overlay this strip on the left.
            HStack {
                Spacer()
                Text(Lf("Step %d of %d", step + 1, totalSteps))
                    .font(DS.helpText)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .overlay(alignment: .bottom) { Divider() }
            // Launched straight from the DMG / quarantined Downloads: TCC
            // grants would land on the translocated throwaway copy and the
            // permissions step could never go green — say so on every step,
            // before the user invests in walking them.
            if Permissions.isTranslocated {
                Label(L("Dictate is running from the downloaded image — drag it into Applications, eject the image, and launch it from there. Permissions granted to this temporary copy won't stick."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(DS.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 52)
                    .padding(.top, 16)
            }
            content
                .id(step)   // new step = new view → triggers the transition
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 52)
                .padding(.top, step == 0 ? 44 : 34)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
        }
        .frame(width: 760, height: 546)
        .tint(DS.accent)
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
        case 1: ModelStep(state: $modelState, failed: downloadFailed, totalMB: downloadTotalMB,
                          failedAtMB: downloadedMB,
                          rate: downloadRate, diskShortfall: diskShortfall)
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
        // The design's buttons on every footer control (owner sweep): the
        // white card as the base, the accent primary set per-case below.
        .buttonStyle(.dsRegular)
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
                Button(L("Next")) { step += 1 }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.dsPrimary)
            case .downloading:
                ProgressView().controlSize(.small)
            case .notReady:
                Button(downloadFailed ? L("Resume Download") : L("Download & continue")) {
                    startDownload()
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.dsPrimary)
            }
        case 3:
            Button(L("Next")) { step += 1 }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.dsPrimary)
                .disabled(!allGranted)
        case totalSteps - 1:
            if tryTaskDone {
                Button(L("Start Using Dictate")) { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.dsPrimary)
            } else {
                Button(L("Start Using Dictate")) { finish() }
                    .buttonStyle(.dsPrimary)
            }
        case 0:
            Button(L("Set Up Dictate")) { step += 1 }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.dsPrimary)
        default:
            Button(L("Next")) { step += 1 }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.dsPrimary)
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
        // Checked BEFORE the download starts: refusing up front beats failing
        // at 97% of a gigabyte. 1.5× covers the temporary + unpacked copies.
        let freeMB = Self.freeDiskMB()
        let neededMB = Int(totalMB * 1.5) + 200
        if freeMB < neededMB {
            downloadFailed = true
            diskShortfall = (needed: neededMB, free: freeMB)
            return
        }
        diskShortfall = nil
        modelState = .downloading(0)
        downloadFailed = false
        downloadRate = nil
        Task {
            do {
                var doneMB = 0.0
                // Smoothed transfer rate for the caption under the bar — a
                // 630 MB download with no speed and no ETA reads as stuck on
                // slow connections.
                var lastT = ProcessInfo.processInfo.systemUptime
                var lastMB = 0.0
                var ema = 0.0
                for tier in tiers {
                    try await WhisperEngine.shared.download(tier: tier) { p in
                        let overall = (doneMB + p * Double(tier.sizeMB)) / totalMB
                        let mbNow = overall * totalMB
                        let now = ProcessInfo.processInfo.systemUptime
                        var rate: String?
                        if now - lastT >= 1.0 {
                            let inst = (mbNow - lastMB) / (now - lastT)
                            ema = ema == 0 ? inst : ema * 0.7 + inst * 0.3
                            lastT = now
                            lastMB = mbNow
                        }
                        if ema > 0.05 {
                            let secondsLeft = Int((totalMB - mbNow) / ema)
                            let eta = secondsLeft >= 90
                                ? Lf("%d min", (secondsLeft + 30) / 60)
                                : Lf("%d sec", max(secondsLeft, 1))
                            rate = Lf("%@ MB/s · about %@ left",
                                      String(format: "%.1f", ema), eta)
                        }
                        DispatchQueue.main.async {
                            modelState = .downloading(overall)
                            downloadedMB = Int(overall * totalMB)
                            if let rate { downloadRate = rate }
                        }
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

    /// Free space where the models land (Application Support's volume).
    static func freeDiskMB() -> Int {
        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        let free = (try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        return Int(free / 1_048_576)
    }
}

// MARK: - Step 1: welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); InterfaceLanguagePicker(showsGlobe: true) }
            // Left-aligned column (design t5): the mark on its accent tile,
            // the name, one sentence of what happens, three bullets of what
            // matters. No gradient inside the glyph (identity rules) — the
            // tile is the one solid accent surface.
            VStack(alignment: .leading, spacing: 14) {
                GlyphMark(state: .idle, color: .white, width: 40)
                    .frame(width: 60, height: 60)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(DS.accent)
                        .shadow(color: DS.accent.opacity(0.28), radius: 9, y: 3))
                Text("Dictate")
                    .font(.system(size: 30, weight: .bold))
                    .kerning(-0.7)
                Text(L("Hold a key, speak, let go. What you said is typed where your cursor is, in any app on this Mac."))
                    .font(.system(size: 15))
                    .lineSpacing(15 * 0.35)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The four pillars (owner 2026-08-29): dictation offline,
                // translation offline, meetings structured, an agent over
                // them — the same story the README and the release tell.
                VStack(alignment: .leading, spacing: 9) {
                    bullet(L("Dictation that works offline — recognition runs entirely on this Mac."))
                    bullet(L("Translation that works offline — speak your language, another comes out."))
                    bullet(L("Meetings, recorded and structured: speakers, summary, outline, search."))
                    bullet(L("An optional agent that knows your meetings — answers quote the moment they came from."))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.top, -12)   // the language pill row shares the top edge
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("·").foregroundStyle(DS.accent)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 2: model download

private struct ModelStep: View {
    @Binding var state: OnboardingView.ModelState
    var failed = false
    var totalMB = ModelTier.fast.sizeMB
    /// MB on disk when the download stopped (design: failed state).
    var failedAtMB = 0
    /// Live transfer rate + ETA while downloading (nil until stable).
    var rate: String?
    /// Set when the download was refused up front for lack of disk space.
    var diskShortfall: (needed: Int, free: Int)?

    private var sizeHint: String {
        totalMB >= 1000 ? String(format: "~%.1f GB", Double(totalMB) / 1000) : "~\(totalMB) MB"
    }

    var body: some View {
        // The design centres every state of this step vertically — a single
        // paragraph and a bar float in the window's middle, not at its top.
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            if case .downloading(let p) = state {
                if p < 0.999 { downloading(p) } else { preparing }
            } else if state == .ready {
                // The model is already on disk (a re-run, or a fast return
                // through Back): the step still tells its story — a bare
                // checkmark floating in an empty window read as broken.
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("On-device recognition"))
                        .font(.system(size: 20, weight: .semibold)).kerning(-0.4)
                    Text(L("Recognition runs on your Mac's Neural Engine — Whisper large-v3-turbo: 112 languages, great with accents, fast enough for live text. Translation runs on this Mac too. Your voice never leaves this computer."))
                        .font(.system(size: 13.5)).lineSpacing(13.5 * 0.28)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(L("Model ready"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(DS.good)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.top, 6)
                }
                .frame(maxWidth: 560, alignment: .leading)
            } else if failed {
                stopped
            } else {
                intro
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Before anything was asked for: what the download is and why.
    @ViewBuilder
    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("On-device recognition"))
                .font(.system(size: 20, weight: .semibold)).kerning(-0.4)
            Text(L("Recognition runs on your Mac's Neural Engine — Whisper large-v3-turbo: 112 languages, great with accents, fast enough for live text. Translation runs on this Mac too. Your voice never leaves this computer."))
                .font(.system(size: 13.5)).lineSpacing(13.5 * 0.28)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Lf("About %@ — downloaded once. This is the only time Dictate needs the internet.", sizeHint))
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: 560, alignment: .leading)
        if let short = diskShortfall {
            // Refused before it began — failing at the end of a gigabyte
            // would be the worse version of this message.
            Label(Lf("Not enough disk space: the download needs about %d MB and %d MB is free. Free up space and try again.",
                     short.needed, short.free),
                  systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(DS.warn)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func downloading(_ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Downloading the speech model"))
                    .font(.system(size: 20, weight: .semibold)).kerning(-0.4)
                Text(L("This happens once. The model stays on your Mac and is the reason dictation works without an internet connection afterwards."))
                    .font(.system(size: 13.5)).lineSpacing(13.5 * 0.28)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                bar(p, tint: DS.accent)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Lf("%d MB of %d MB", Int(p * Double(totalMB)), totalMB))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let rate {
                        Text(rate)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// The design's stopped screen: what happened, at which megabyte, and
    /// the promise that resuming keeps what already landed.
    private var stopped: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 16))
                        .foregroundStyle(DS.warn)
                    Text(Lf("The download stopped at %d MB", failedAtMB))
                        .font(.system(size: 20, weight: .semibold)).kerning(-0.4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Lf("The connection was interrupted. Resuming continues from where it stopped — you will not download the whole %d MB again.", totalMB))
                    .font(.system(size: 13.5)).lineSpacing(13.5 * 0.28)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                bar(Double(failedAtMB) / Double(max(totalMB, 1)), tint: DS.warn)
                Text(Lf("Stopped · %d MB of %d MB kept on disk", failedAtMB, totalMB))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var preparing: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(L("Preparing the model for this Mac"))
                    .font(.system(size: 20, weight: .semibold)).kerning(-0.4)
            }
            Text(L("The model is being compiled for your chip so recognition is fast later. This takes a minute on first launch and never happens again."))
                .font(.system(size: 13.5)).lineSpacing(13.5 * 0.28)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// The design's 6 pt bar — one rounded track, one tinted fill.
    private func bar(_ fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(6, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Step 3: hotkey + translate key

private struct HotkeyStep: View {
    /// Owned by OnboardingView — the translation-data fetch hangs off the root
    /// and has to see these change (this view is recreated on every step).
    @Binding var language: String
    @Binding var translateTarget: String

    @StateObject private var captureMain = KeyCapture()
    @StateObject private var captureTranslate = KeyCapture()
    @State private var mainName = Settings.shared.hotkeyName
    @State private var translateName = Settings.shared.translateKeyName
    @State private var translateSet = Settings.shared.translateKeyCode != nil
    @State private var unsafeKey = !KeyNames.isSafeHotkey(Settings.shared.hotkeyKeyCode)
    @State private var fKey = KeyNames.isFunctionKey(Settings.shared.hotkeyKeyCode)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Choose your keys and languages"))
                    .font(.system(size: 20, weight: .semibold)).kerning(-0.4)
                Text(L("Hold the key while you speak. Anything can be changed later in Settings."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The design's form rows (t5/keys): a right-aligned label column,
            // the control beside it, a quiet hint under the control.
            VStack(alignment: .leading, spacing: 0) {
                formRow(label: L("Dictation key")) {
                    HStack(spacing: 9) {
                        captureWell(name: KeyNames.displayName(mainName),
                                    capture: captureMain)
                        Text(L("Click, then press a key"))
                            .font(DS.helpText)
                            .foregroundStyle(.tertiary)
                    }
                }
                Divider()
                formRow(label: L("Translate key")) {
                    captureWell(name: translateSet
                                ? KeyNames.displayName(translateName) : L("Not set"),
                                capture: captureTranslate)
                }
                Divider()
                formRow(label: L("I speak")) {
                    HStack(spacing: 9) {
                        LanguagePicker(selection: $language)
                            .onChange(of: language) { Settings.shared.language = $0 }
                        Text(L("112 languages · from your system settings"))
                            .font(DS.helpText)
                            .foregroundStyle(.tertiary)
                    }
                }
                if language != "en" {
                    Divider()
                    formRow(label: L("Translate into")) {
                        TranslateTargetPicker(selection: $translateTarget)
                            .onChange(of: translateTarget) {
                                Settings.shared.translateTargetCode = $0
                            }
                    }
                }
            }

            // The one lesson worth a box (design): why modifiers, and that
            // Esc always bails out.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                Text(L("Modifier keys work best: they never insert a character when you hold them. Esc always cancels a dictation in progress."))
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 13)
            .frame(maxWidth: 600, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.5)))

            if unsafeKey {
                Label(L("This key types characters — they'll end up in your text while you hold it. A modifier (Option, Cmd, Shift, Ctrl) or an F-key is safer."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.warn).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if fKey {
                Label(L("F-keys can also trigger a system control (brightness, media) — macOS will do both. To use one as a plain key, turn on “Use F1, F2, etc. as standard function keys” in Keyboard settings."),
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .onAppear { assignDefaultTranslateKeyIfNeeded() }
        .onDisappear { captureMain.cancel(); captureTranslate.cancel() }
        .onReceive(captureMain.$capturedKeyCode) { code in
            guard let code, let name = captureMain.capturedName,
                  code != Settings.shared.translateKeyCode else { return }
            Settings.shared.hotkeyKeyCode = code
            Settings.shared.hotkeyName = name
            mainName = name
            unsafeKey = !KeyNames.isSafeHotkey(code)
            fKey = KeyNames.isFunctionKey(code)
        }
        .onReceive(captureTranslate.$capturedKeyCode) { code in
            guard let code, let name = captureTranslate.capturedName,
                  code != Settings.shared.hotkeyKeyCode else { return }
            Settings.shared.translateKeyCode = code
            Settings.shared.translateKeyName = name
            translateName = name
            translateSet = true
        }
    }

    private func formRow<V: View>(label: String,
                                  @ViewBuilder control: () -> V) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            control()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }

    /// The key-capture well (design: capture): the current binding as a
    /// keycap-flavoured chip; click, then press any key or modifier.
    private func captureWell(name: String, capture: KeyCapture) -> some View {
        Button {
            capture.begin()
        } label: {
            Text(capture.capturing ? L("Type a key…") : name)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(capture.capturing ? AnyShapeStyle(DS.accent.opacity(0.15))
                                            : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(capture.capturing ? DS.accent : Color.primary.opacity(0.16),
                                  lineWidth: capture.capturing ? 1 : 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 7)
        .pointerStyle(.link)
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


// MARK: - Step 4: permissions

private struct PermissionsStep: View {
    @State private var mic = Permissions.microphone
    @State private var ax = Permissions.accessibility
    /// Seconds spent on this step without Accessibility going green. After a
    /// while the toggle dance has clearly failed — offer the automatic reset
    /// (the industry answer is "run tccutil in Terminal"; here it's a button).
    @State private var stuckSeconds = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Two permissions from macOS"))
                    .font(.system(size: 20, weight: .semibold)).kerning(-0.4)
                Text(L("macOS asks for these, not us. Dictate cannot work without both."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(title: L("Microphone"),
                              explain: L("To hear you. Audio is processed on this Mac and discarded."),
                              status: mic) {
                    Permissions.requestMicrophoneIfNeeded { _ in refresh() }
                }
                PermissionRow(title: L("Accessibility"),
                              explain: L("To type the recognized text into the app you are using. It is the only way an app can insert text elsewhere."),
                              status: ax) {
                    Permissions.promptAccessibilityIfNeeded()
                }
            }
            .frame(maxWidth: 620, alignment: .leading)

            HStack(spacing: 8) {
                Text(L("Already clicked and nothing changed?"))
                    .foregroundStyle(.tertiary)
                Button(L("Show me where to look")) {
                    Permissions.openSettingsPane("Privacy_Accessibility")
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.accentText)
                .pointerStyle(.link)
            }
            .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 4) {
                // The stale-entry dead end (seen live after an app update): the
                // switch in System Settings is already ON, yet macOS reports
                // "not trusted", the prompt won't reappear — and without this
                // hint there is NOTHING the user can click to move forward.
                if Settings.shared.onboardingDone, ax != .granted {
                    Label(L("Already ON in System Settings but not green here? Turn the Dictate switch off and back on — after an app update macOS sometimes keeps a stale entry."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.warn)
                }
                // The stale record survives the toggle dance in the worst
                // cases (deleted-and-reinstalled app, old Deny suppressing the
                // prompt). Resetting our own TCC record is the sanctioned fix
                // everyone else sends users to Terminal for — one click here.
                if ax != .granted, stuckSeconds >= 15 || Settings.shared.onboardingDone {
                    Button(L("Still stuck? Reset the permission — this clears the broken macOS record, then grant the fresh request.")) {
                        Permissions.resetAccessibility()
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .onReceive(timer) { _ in
            refresh()
            if ax != .granted { stuckSeconds += 1 }
        }
        .onAppear { Permissions.registerAccessibilityQuietly(); refresh() }
    }

    private func refresh() {
        mic = Permissions.microphone
        ax = Permissions.accessibility
    }
}

/// One permission as the design's card: a status circle at the leading end
/// (green check once granted), the name and its one-sentence reason, and at
/// the trailing end either quiet "Granted" or the small accent Grant….
private struct PermissionRow: View {
    let title: String
    let explain: String
    let status: Permissions.Status
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if status == .granted {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DS.good)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.4)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 20)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(explain)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if status == .granted {
                Text(L("Granted"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            } else {
                Button(action: action) {
                    Text(L("Grant…"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 23)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.accent))
                }
                .buttonStyle(.plain)
                .hoverEmphasis()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5))
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
    /// Ticks of the 1 s poll below — every 5th re-kicks the warm-up. The single
    /// preload fired on entering step 2 could die silently (tokenizer fetch on
    /// a fresh install needs the network) and nothing retried: the "Preparing
    /// the model…" banner then spun forever over stopped work. Re-kicking is
    /// free while a prepare is genuinely running (in-flight calls coalesce) and
    /// self-heals after a failure.
    @State private var readyTicks = 0
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
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Try it here first"))
                    .font(.system(size: 20, weight: .semibold)).kerning(-0.4)
                Text(L("Nothing here leaves this window. Two small things to try, then you are done."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    .foregroundStyle(DS.good)
                    .font(.callout.monospacedDigit())
            } else {
                Text(L("Changed your mind? Esc cancels the recording."))
                    .font(.caption).foregroundStyle(.tertiary)
            }

            // The switch leads and the sentence follows (design: playground).
            HStack(alignment: .top, spacing: 9) {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: launchAtLogin) { on in
                        if on { try? SMAppService.mainApp.register() }
                        else { try? SMAppService.mainApp.unregister() }
                    }
                Text(L("Start Dictate when I log in — it appears in the Dock and the menu bar, and the Dock icon can be hidden later in Settings"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            Spacer()
        }
        .onReceive(readyTimer) { _ in
            guard !engineReady else { return }
            readyTicks += 1
            if readyTicks % 5 == 0 { dictation.preloadModel() }
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
                .foregroundStyle(done ? AnyShapeStyle(DS.good) : AnyShapeStyle(.secondary))
            Text(text)
                .foregroundStyle(done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.2), value: done)
    }
}
