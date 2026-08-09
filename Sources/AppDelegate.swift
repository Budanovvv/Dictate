import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var statusController: StatusItemController!
    private let dictation = DictationController()
    private let hud = RecordingHUD()
    /// Sparkle: automatic update checks (feed URL is SUFeedURL in Info.plist).
    /// Created in didFinishLaunching so the delegate (self) can be passed in.
    private var updater: SPUStandardUpdaterController!
    /// Installs the silently downloaded, staged update and relaunches the app.
    /// Kept until the user goes idle: a menu-bar app effectively never quits,
    /// so an install-on-quit update would otherwise wait for the next reboot.
    private var pendingUpdateInstall: (() -> Void)?
    private var updateRelaunchTimer: Timer?
    private var resultShown = false
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// Invisible 1×1 panel hosting the Apple Translation session (the
    /// framework only works through a SwiftUI view — see AppleTranslator).
    private var translatorHostPanel: NSPanel?
    /// Local meeting transcription (mic = You, system audio tap = Them).
    private let meeting = MeetingSession()
    private var meetingWindow: NSPanel?

    /// The live transcript window: floating, NON-ACTIVATING (glancing at it
    /// must not steal focus from the call), visible over fullscreen Spaces —
    /// the same combination the HUD and translator panels learned the hard
    /// way (GRABLI).
    private func showMeetingWindow() {
        if meetingWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered, defer: false
            )
            panel.title = L("Meeting transcript")
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 320, height: 260)
            panel.contentView = NSHostingView(rootView: MeetingTranscriptView(
                session: meeting,
                onStop: { [weak self] in self?.meeting.stop() }))
            panel.center()
            meetingWindow = panel
        }
        meetingWindow?.orderFront(nil)
    }

    /// Menu toggle for the meeting transcript. The first start of every
    /// session shows a consent reminder: recording call participants without
    /// their knowledge is illegal in many jurisdictions, and a menu click
    /// must not silently become a law problem. Everything is processed
    /// locally — the dialog says so.
    private func toggleMeetingTranscript() {
        if meeting.isActive {
            meeting.stop()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Record this meeting?")
        alert.informativeText = L("Dictate transcribes the call locally on this Mac — nothing leaves it. Make sure the other participants are okay with being transcribed: many places require their consent.")
        alert.addButton(withTitle: L("Start"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try meeting.start()
            statusController.applyState(dictation.state)   // show the red dot
            showMeetingWindow()
        } catch {
            statusController.showError(Lf("Couldn't start the meeting transcript: %@",
                                          error.localizedDescription))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostics first: catch a wedged main thread (CoreAnimation ↔
        // WindowServer freeze) and write evidence to ~/Library/Logs/Dictate.
        MainThreadWatchdog.shared.start()

        updater = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
        )

        // Launch at login is on by default: register the login item once, the
        // first time the app runs. A flag keeps us from re-enabling it if the
        // user later turns the toggle off (in onboarding or Settings). register()
        // needs the app in a valid location (/Applications) — try? swallows the
        // failure if it's run from elsewhere.
        if !Settings.shared.didSetLoginItemDefault {
            Settings.shared.didSetLoginItemDefault = true
            try? SMAppService.mainApp.register()
        }

        statusController = StatusItemController(
            dictation: dictation,
            openSettings: { [weak self] in self?.showSettings() },
            checkForUpdates: { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.updater.checkForUpdates(nil)
            },
            meetingActive: { [weak self] in self?.meeting.isActive ?? false },
            toggleMeeting: { [weak self] in self?.toggleMeetingTranscript() },
            showMeetingTranscript: { [weak self] in self?.showMeetingWindow() }
        )
        meeting.onFinished = { [weak self] url in
            // The finished transcript opens itself — the payoff moment; no
            // extra pill or dialog needed. The live window bows out to it.
            self?.meetingWindow?.orderOut(nil)
            NSWorkspace.shared.open(url)
            // Drop the red recording dot from the menu bar.
            if let self { self.statusController.applyState(self.dictation.state) }
        }
        dictation.onError = { [weak self] message in
            DispatchQueue.main.async { self?.statusController.showError(message) }
        }
        dictation.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusController.applyState(state)
                switch state {
                case .recording:
                    self.resultShown = false
                    self.hud.showRecording(translate: self.dictation.activeTranslate)
                case .transcribing:
                    self.hud.showTranscribing(translate: self.dictation.activeTranslate)
                case .idle:
                    // showResult hides the HUD itself; hide here only for cancel/short press
                    if !self.resultShown { self.hud.hide() }
                }
            }
        }
        dictation.onResult = { [weak self] success, _, _ in
            DispatchQueue.main.async {
                self?.resultShown = true
                self?.hud.showResult(success: success)
                if success { self?.maybeShowTranslateTip() }
            }
        }
        // Already delivered on main by DictationController (dispatched at the
        // source) — no extra hop here, the level drives a 60 fps equalizer.
        dictation.onTranscribeProgress = { [weak self] fraction, words in
            self?.hud.setTranscribeProgress(fraction, words: words)
        }
        dictation.onNotice = { [weak self] notice in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resultShown = true   // idle must not hide the notice pill
                switch notice {
                case .cancelled: self.hud.showCancelled()
                case .copiedInstead: self.hud.showCopied()
                case .micBusy(let appName): self.hud.showMicBusy(appName: appName)
                case .nothingHeard: self.hud.showResult(success: false)
                case .tooQuiet: self.hud.showTooQuiet()
                case .tooLoud: self.hud.showTooLoud()
                case .translateDataMissing: self.hud.showTranslateDataMissing()
                }
            }
        }
        // Same main-thread contract as onTranscribeProgress (see AudioRecorder).
        dictation.onLevel = { [weak self] level in
            self?.hud.setLevel(level)
            self?.statusController.setLevel(level)
        }
        // Delivered on main (MainActor.run at the source).
        dictation.onLivePreview = { [weak self] text in
            self?.hud.setLivePreview(text)
        }
        dictation.onModelDownload = { [weak self] progress, totalMB in
            DispatchQueue.main.async { self?.hud.showDownloading(progress, totalMB: totalMB) }
        }

        // Existing installs predate the onboarding timestamp — seed it now so
        // the translate tip's one-day grace period has a starting point.
        if Settings.shared.onboardingDone, Settings.shared.onboardingDoneAt == nil {
            Settings.shared.onboardingDoneAt = Date()
        }

        if Settings.shared.onboardingDone && Permissions.allGranted {
            dictation.start()
            dictation.preloadModel()
        } else {
            showOnboarding()
        }
        // Installs that predate the turbo tier have no fast model on disk, and
        // the first dictation after the update would run head-on into a
        // surprise 626 MB download. Fetch it here instead, in the background
        // and with the HUD saying what's happening. Only after onboarding —
        // onboarding downloads its own models with its own progress bar.
        if Settings.shared.onboardingDone,
           !WhisperEngine.shared.isModelDownloaded(tier: .fast) {
            catchUpFastModelDownload()
        }
        removeRetiredPolishModel()
        // Persistent invisible host for Apple Translation: the translationTask
        // modifier needs a live, on-screen view to run in.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = NSHostingView(rootView: TranslatorHostView())
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        // Present on every Space of every display. Without this the panel is
        // pinned to the Space it was born on, and NSApp.activate() yanks
        // Mission Control across all screens to fly there — visible as every
        // desktop "jumping" whenever a real window (Settings) opens.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.orderBack(nil)
        translatorHostPanel = panel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if meeting.isActive { meeting.stop() }
        dictation.shutdown()
    }

    /// The AI polish pass was removed after 2.3.1 (it distorted what people
    /// actually said), so its ~1.9 GB GGUF is now dead weight on the disk of
    /// everyone who ever turned the feature on. Reclaim it once, quietly.
    private func removeRetiredPolishModel() {
        let llmDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
            .appendingPathComponent("llm", isDirectory: true)
        UserDefaults.standard.removeObject(forKey: "polishEnabled")
        guard FileManager.default.fileExists(atPath: llmDir.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: llmDir)
            Log.d("cleanup: removed the retired polish model directory")
        }
    }

    /// One-time catch-up download of the turbo dictation model for installs
    /// that updated into the hybrid-model release (see the call site). The
    /// pill only reports while nothing else is using it — a dictation started
    /// mid-download owns the HUD. Failures are swallowed: there's nothing the
    /// user can do here and the next launch simply tries again.
    private func catchUpFastModelDownload() {
        Log.d("model: turbo missing after update — background download")
        Task { @MainActor in
            do {
                try await WhisperEngine.shared.download(tier: .fast) { [weak self] p in
                    DispatchQueue.main.async {
                        guard let self, self.dictation.state == .idle else { return }
                        self.hud.showDownloading(p, totalMB: ModelTier.fast.sizeMB)
                    }
                }
                if dictation.state == .idle { hud.hide() }
                Log.d("model: turbo catch-up download finished")
                dictation.preloadModel()
            } catch {
                if dictation.state == .idle { hud.hide() }
                Log.d("model: turbo catch-up download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Discovery nudge for the translate key (the deferred "first week" hint).
    /// The feature's whole funnel otherwise ends at onboarding: whoever missed
    /// the try-out never learns their second key exists. Gates: non-English
    /// speaker, key configured, zero translations ever, ≥5 real dictations,
    /// ≥1 day past onboarding. Shows once for ~5 s after a successful insert;
    /// at most one reminder a week later; silenced forever by the first
    /// translation (translateUsedEver).
    private func maybeShowTranslateTip() {
        let s = Settings.shared
        guard s.language != "en",
              // The tip's wording promises English — it would lie about any
              // other target the user picked.
              s.translateTargetCode == "en",
              s.translateKeyCode != nil,
              !s.translateUsedEver,
              s.dictationCount >= 5,
              s.translateTipCount < 2,
              let doneAt = s.onboardingDoneAt,
              Date().timeIntervalSince(doneAt) >= 86_400 else { return }
        if let last = s.translateTipShownAt, Date().timeIntervalSince(last) < 7 * 86_400 { return }
        s.translateTipShownAt = Date()
        s.translateTipCount += 1
        let keyName = KeyNames.displayName(s.translateKeyName)
        // After the success pill has topped up and slipped away (~0.55 s +
        // fade) — the tip replaces it instead of fighting it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.dictation.state == .idle else { return }
            Log.d("translate tip: shown (count \(s.translateTipCount))")
            self.hud.showTranslateTip(keyName: keyName)
        }
    }

    // MARK: - Sparkle: apply staged updates without waiting for a quit

    /// A silent update was downloaded and staged for install-on-quit. A menu-bar
    /// app with launch-at-login runs until the next reboot, so "on quit" means
    /// "in weeks" (live case: 2.2.1 sat a week after 2.2.2 shipped). Return true
    /// and keep the handler: we invoke it ourselves — installing and relaunching
    /// — at the first safe idle moment.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Log.d("update: v\(item.displayVersionString) staged — waiting for an idle moment to relaunch")
            self.pendingUpdateInstall = immediateInstallHandler
            self.scheduleUpdateRelaunchTimer()
        }
        return true
    }

    private func scheduleUpdateRelaunchTimer() {
        guard updateRelaunchTimer == nil else { return }
        updateRelaunchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.installPendingUpdateIfSafe()
        }
    }

    /// Safe = nothing in flight the relaunch could eat: no dictation running,
    /// none of our windows open, and the user idle long enough that a pending
    /// clipboard restore or an about-to-start dictation can't be caught mid-air.
    private func installPendingUpdateIfSafe() {
        guard let install = pendingUpdateInstall else { return }
        // A meeting counts as busy even though dictation is idle: the user
        // sits still while LISTENING, which reads as "inactive" to the input
        // check below — a silent relaunch would kill the live transcript.
        guard dictation.state == .idle,
              !meeting.isActive,
              onboardingWindow == nil,
              settingsWindow?.isVisible != true else { return }
        let idle = [CGEventType.keyDown, .flagsChanged, .leftMouseDown, .mouseMoved]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        // Overridable for update-flow testing (defaults write … updateRelaunchIdleSeconds 30)
        let required = UserDefaults.standard.object(forKey: "updateRelaunchIdleSeconds") as? Double ?? 300
        guard idle >= required else { return }
        Log.d("update: user idle \(Int(idle))s — installing staged update and relaunching")
        pendingUpdateInstall = nil
        updateRelaunchTimer?.invalidate()
        updateRelaunchTimer = nil
        install()
    }

    // Dock icon click (icon is visible only while a window is open)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Never trust `flag`: the invisible 1×1 translator host panel counts
        // as a visible window, so it is always true and a Dock click / reopen
        // would silently do nothing. Check OUR windows instead.
        let ourWindowOpen = [onboardingWindow, settingsWindow]
            .compactMap { $0 }
            .contains { $0.isVisible }
        if !ourWindowOpen {
            if Settings.shared.onboardingDone {
                showSettings()
            } else if onboardingWindow == nil {
                showOnboarding()
            }
        }
        return true
    }

    private func showOnboarding() {
        let view = OnboardingView(finish: { [weak self] in
            guard let self else { return }
            Settings.shared.onboardingDone = true
            Settings.shared.onboardingDoneAt = Date()
            self.dictation.suppressInsertion = false
            self.dictation.onResultText = nil
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            self.dictation.restart()
        }, dictation: dictation)
        let window = makeWindow(title: L("Welcome to Dictate"), content: view)
        onboardingWindow = window
        present(window)
    }

    private func showSettings() {
        if let settingsWindow {
            present(settingsWindow)
            return
        }
        let view = SettingsView { [weak self] in
            self?.dictation.restart()
        }
        let window = makeWindow(title: L("Dictate Settings"), content: view)
        settingsWindow = window
        present(window)
    }

    private func makeWindow<V: View>(title: String, content: V) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        // We keep strong references (onboardingWindow/settingsWindow) — without
        // this, closing releases the NSWindow under ARC and the next touch of
        // the dangling reference is an over-release crash.
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        // Subscribe once per window here — present() runs on every reopen, and
        // duplicate observers would fire someWindowClosed N times per close.
        NotificationCenter.default.addObserver(
            self, selector: #selector(someWindowClosed),
            name: NSWindow.willCloseNotification, object: window
        )
        return window
    }

    private func present(_ window: NSWindow) {
        // .regular while a window is open so Cmd+Tab and focus behave normally;
        // back to .accessory once all our windows close.
        NSApp.setActivationPolicy(.regular)
        // The window is cached and remembers the display it was last shown on,
        // which may not be where the user is now. The cursor is the honest
        // signal — Settings opens from a menu-bar or Dock click — so center on
        // the screen under it. Same screen → keep the user's manual position.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           window.screen !== screen {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }
        // Activate on the next runloop turn: the .accessory→.regular switch must
        // settle first, otherwise Picker/Menu popups can't open (the app isn't
        // truly frontmost yet).
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func someWindowClosed(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let closing = note.object as? NSWindow
            // The onboarding window is one-shot: closing it with the red button
            // must drop the reference, or applicationShouldHandleReopen sees a
            // "still open" onboarding and a Dock click does nothing at all.
            if let closing, closing === self.onboardingWindow {
                self.onboardingWindow = nil
            }
            let stillOpen = [self.onboardingWindow, self.settingsWindow]
                .compactMap { $0 }
                .contains { $0 !== closing && $0.isVisible }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
