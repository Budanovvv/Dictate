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
            }
        )
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
                }
            }
        }
        // Same main-thread contract as onTranscribeProgress (see AudioRecorder).
        dictation.onLevel = { [weak self] level in
            self?.hud.setLevel(level)
            self?.statusController.setLevel(level)
        }
        dictation.onModelDownload = { [weak self] progress in
            DispatchQueue.main.async { self?.hud.showDownloading(progress) }
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
        // Bring the pre-roll ring up if it's enabled (no-op otherwise). Also
        // called after the settings toggle and after mic permission is granted.
        PrerollBuffer.shared.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.shutdown()
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
        guard dictation.state == .idle,
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
        if !flag {
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
            PrerollBuffer.shared.refresh()   // mic permission just granted
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
