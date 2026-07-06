import AppKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController!
    private let dictation = DictationController()
    private let hud = RecordingHUD()
    /// Sparkle: automatic update checks (feed URL is SUFeedURL in Info.plist).
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var resultShown = false
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                    self.hud.showRecording()
                case .transcribing:
                    self.hud.showTranscribing()
                case .idle:
                    // showResult hides the HUD itself; hide here only for cancel/short press
                    if !self.resultShown { self.hud.hide() }
                }
            }
        }
        dictation.onResult = { [weak self] success, words, seconds in
            DispatchQueue.main.async {
                self?.resultShown = true
                self?.hud.showResult(success: success, words: words, seconds: seconds)
            }
        }
        dictation.onWarmup = { [weak self] in
            DispatchQueue.main.async { self?.hud.showWarming() }
        }
        dictation.onWarmupDone = { [weak self] in
            DispatchQueue.main.async {
                guard self?.dictation.state == .transcribing else { return }
                self?.hud.showTranscribing()
            }
        }
        dictation.onCancelled = { [weak self] in
            DispatchQueue.main.async {
                self?.resultShown = true   // idle must not hide the "Cancelled" HUD
                self?.hud.showCancelled()
            }
        }
        dictation.onLevel = { [weak self] level in
            self?.hud.setLevel(level)
        }
        dictation.onModelDownload = { [weak self] progress in
            DispatchQueue.main.async { self?.hud.showDownloading(progress) }
        }

        if Settings.shared.onboardingDone && Permissions.allGranted {
            dictation.start()
            dictation.preloadModel()
        } else {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.shutdown()
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
        window.isReleasedWhenClosed = false
        settingsWindow = window
        present(window)
    }

    private func makeWindow<V: View>(title: String, content: V) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isMovableByWindowBackground = true
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        // .regular while a window is open so Cmd+Tab and focus behave normally;
        // back to .accessory once all our windows close.
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(
            self, selector: #selector(someWindowClosed),
            name: NSWindow.willCloseNotification, object: window
        )
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
            let stillOpen = [self.onboardingWindow, self.settingsWindow]
                .compactMap { $0 }
                .contains { $0 !== closing && $0.isVisible }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
