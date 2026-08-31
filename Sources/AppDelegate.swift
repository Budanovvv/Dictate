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
    private let callDetector = CallDetector()
    private let callPrompt = CallPrompt()
    private var settingsWindow: NSWindow?
    /// Corner-menu notification tokens — alive for the app's lifetime.
    private var menuObservers: [any NSObjectProtocol] = []
    /// Invisible 1×1 panel hosting the Apple Translation session (the
    /// framework only works through a SwiftUI view — see AppleTranslator).
    private var translatorHostPanel: NSPanel?
    /// Local meeting transcription (mic = You, system audio tap = Them).
    private let meeting = MeetingSession()
    private var meetingWindow: NSPanel?
    private var meetingPill: MeetingPill?
    private var meetingCloseGuard: WindowCloseGuard?
    /// The transcript is folded into the pill. Only meaningful while a session
    /// is live — a finished meeting is a library, and a library has no
    /// minimized form.
    private var meetingMinimized = false
    /// Which transcript the meetings window should show. The window is created
    /// once and reused, so "open this one" has to be state the view watches
    /// (see MeetingsNavigator) rather than an argument it would only ever read
    /// on the first open.
    private let meetingNavigator = MeetingsNavigator()

    /// The meetings window. While a call is being recorded it behaves like
    /// the HUD — floating over fullscreen Spaces and NON-ACTIVATING, so a
    /// glance at the transcript never steals focus from the call (GRABLI);
    /// `becomesKeyOnlyIfNeeded` still lets the search field and the rename
    /// popover take keystrokes when they're actually clicked. Opening the
    /// library (the sidebar) turns it into an ordinary window and widens it,
    /// because browsing is a deliberate, focused activity.
    ///
    /// `focus` is the user asking for the library by name (menu → Meetings…)
    /// while nothing is being recorded — see applyMeetingWindowMode().
    /// `select` is the menu asking for one particular transcript.
    private func showMeetingWindow(select: URL? = nil, focus: Bool = false) {
        // Before the window exists, so a first open honours the request in its
        // own onAppear instead of picking a default and then jumping.
        meetingNavigator.open(select)
        if meetingWindow == nil {
            let panel = NSPanel(
                // Room for the library AND a readable transcript beside it:
                // 300 for the cards, the rest for the words. The window used to
                // open at 420 and animate to 780 when the library appeared —
                // there is one layout now, so it opens at the size that layout
                // needs. AppKit remembers what the user resizes it to, so this
                // is a first-open default, not a size imposed on anyone.
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 748),
                // .miniaturizable so the middle traffic light EXISTS: folding
                // a window away is what that button is for on this platform,
                // and a bespoke chevron elsewhere in the window is a second
                // vocabulary for a word macOS already has (the owner went
                // looking for the yellow button and found nothing there).
                styleMask: [.titled, .closable, .miniaturizable, .resizable,
                            .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            // One row of chrome, not two. The window used to stack a 34pt
            // system title bar reading "Meetings" on top of the pane's own 46pt
            // header — 80pt of window spent saying what the list underneath
            // says better. The title bar is now transparent and empty, the
            // content runs up under it, and the pane header IS the title bar:
            // the traffic lights sit at its leading end and the meeting's name
            // is the title.
            //
            // .utilityWindow is gone with it. A utility panel draws a shorter
            // title bar with smaller buttons, which is a second set of chrome
            // metrics to line the header up against for no gain — nothing about
            // this window's behaviour came from it (floating over a call is the
            // window LEVEL, and not stealing focus is .nonactivatingPanel).
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            // The title still exists for the Window menu, for accessibility and
            // for the screenshot tooling that finds this window by name.
            panel.title = L("Meetings")
            // The header row's height is MeetingsChrome.headerHeight and it is
            // chosen to sit on the band AppKit centres the traffic lights in
            // (see there). Growing the title bar instead — an empty
            // NSTitlebarAccessoryViewController of the height we want, which is
            // the usual recipe — was tried and does not survive
            // fullSizeContentView on this panel: the accessory reserved its
            // height twice and pushed the whole header off the top of the
            // window.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            // 300 of library + 340 of transcript is where the cards stop
            // being readable, and a card that cannot be read is a list that
            // cannot be scanned.
            panel.minSize = NSSize(width: 960, height: 600)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let meetingsHosting = NSHostingView(rootView: MeetingsView(
                session: meeting,
                navigator: meetingNavigator,
                onStop: { [weak self] in self?.meeting.stop() },
                onRecord: { [weak self] in self?.toggleMeetingTranscript() })
                // Without this the window is unified only in appearance: the
                // backgrounds run to the top edge but SwiftUI keeps a title-bar
                // safe area, so the header row is pushed 28pt down and the two
                // rows are back — an empty one with the traffic lights, and
                // ours under it. The header row IS the title bar here, so it
                // has to be laid out in the title bar's own space.
                .ignoresSafeArea(.container, edges: .top))
            meetingsHosting.sizingOptions = []
            panel.contentView = meetingsHosting
            // The window keeps the frame the user gave it (HIG) — re-centring
            // a window somebody has placed is what "it jumped screens" feels
            // like. Centre only the very first time.
            if !panel.setFrameUsingName("Meetings") { panel.center() }
            panel.setFrameAutosaveName("Meetings")
            // Closing is the gesture people already reach for, so it has to
            // mean the safest thing it could mean. While a session is live the
            // close button folds the transcript into the pill instead of
            // shutting it: the recording keeps running and says so, visibly,
            // one step smaller. (Field test 2026-08-19: the owner closed the
            // window looking for a way to minimize it and read the result as
            // "everything stopped" — a recorder that LOOKS stopped while it
            // records is the worst outcome of the three.) With no session it
            // is an ordinary library window and closes.
            meetingCloseGuard = WindowCloseGuard { [weak self] in
                guard let self, self.meeting.isActive else { return true }
                self.minimizeMeeting()
                return false
            }
            panel.delegate = meetingCloseGuard
            // The yellow button means the pill, not the Dock: this app has no
            // permanent Dock icon to minimize INTO, and a recording parked on
            // the Dock's shelf is a recording nobody can see is running.
            //
            // Re-targeting the button itself, because there is no delegate hook
            // for this: NSWindowDelegate has windowShouldClose but nothing
            // corresponding for miniaturize — only windowWillMiniaturize, which
            // cannot say no. (Written as a delegate method first; it compiled,
            // was never called, and the window went to the Dock exactly as
            // before.)
            if let yellow = panel.standardWindowButton(.miniaturizeButton) {
                yellow.target = self
                yellow.action = #selector(meetingMiniaturizeClicked)
            }
            // With "Show in Dock" off the Dock icon must vanish when the last
            // of our windows closes — this panel counts as one of them.
            NotificationCenter.default.addObserver(
                self, selector: #selector(someWindowClosed),
                name: NSWindow.willCloseNotification, object: panel
            )
            meetingWindow = panel
        }
        // Showing the transcript IS leaving the minimized state, whichever
        // door was used to get here — the window button, the pill's chevron, or
        // the menu's "Show Live Transcript". Doing it here rather than in the
        // expand path is what keeps the two from being shown at once, which is
        // exactly what the menu route did (found 2026-08-19).
        meetingMinimized = false
        meetingPill?.hide()
        applyMeetingWindowMode()
        // A fresh open goes to the screen the user is on (the click is the
        // honest signal); a window already visible is never moved.
        if let panel = meetingWindow, !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
               panel.screen !== screen {
                let vis = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: vis.midX - panel.frame.width / 2,
                                             y: vis.midY - panel.frame.height / 2))
            }
        }
        // Only an explicit "open the library" with no call running may take the
        // keyboard. Everything else — the window appearing because a meeting
        // started or finished — merely orders it in.
        meetingWindow?.orderFront(nil)
        guard focus, !meeting.isActive else { return }
        // On the next runloop turn, not now: this is called from the status
        // menu's action, the menu is still tracking, and a window made key
        // underneath it loses key status again the moment the menu closes —
        // which is how the library ended up drawn in the inactive appearance
        // every single time it was opened the normal way.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.meetingWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// Two windows in one, and the recording is what decides which.
    ///
    /// While a call is being transcribed this is the HUD's bigger sibling: a
    /// floating panel that must NEVER hold the keyboard, or a glance at the
    /// transcript would pull focus out of Zoom mid-sentence.
    /// `becomesKeyOnlyIfNeeded` is what enforces that — the panel only takes
    /// key status when something in it genuinely needs typing.
    ///
    /// Afterwards it is an ordinary library window, and the same flag becomes a
    /// bug: a window that refuses to be key is drawn by AppKit in its INACTIVE
    /// appearance forever — grey list, grey selection, grey title — which is
    /// exactly the "permanently in fog" the sidebar was reported for. Browsing
    /// an archive steals focus from nobody, so out of a call the panel behaves
    /// like any other window: click it and it is key, and it looks it.
    /// Fold the transcript into the pill, and back.
    ///
    /// Two windows rather than one window resizing: the transcript is a titled,
    /// resizable panel and the pill is a borderless capsule that must float
    /// over full-screen calls without ever taking the keyboard. Those are
    /// different windows in AppKit's terms, and morphing one into the other
    /// would mean rewriting its style mask under the user mid-call.
    private func minimizeMeeting() {
        guard meeting.isActive else { return }
        meetingMinimized = true
        // Read the frame BEFORE hiding it — that is where the pill goes.
        let frame = meetingWindow?.frame
        meetingWindow?.orderOut(nil)
        meetingPillController().show(from: frame)
        Log.d("meeting: transcript minimized to the pill")
    }

    @objc private func meetingMiniaturizeClicked() {
        guard meeting.isActive else {
            meetingWindow?.miniaturize(nil)
            return
        }
        minimizeMeeting()
    }

    private func expandMeeting() {
        showMeetingWindow()
        Log.d("meeting: pill expanded back to the transcript")
    }

    private func meetingPillController() -> MeetingPill {
        if let meetingPill { return meetingPill }
        let pill = MeetingPill(
            session: meeting,
            onStop: { [weak self] in self?.meeting.stop() },
            onExpand: { [weak self] in self?.expandMeeting() },
            onHide: { [weak self] in
                self?.meetingPill?.hideByUser()
                Log.d("meeting: pill hidden — menu bar only")
            })
        meetingPill = pill
        return pill
    }

    private func applyMeetingWindowMode() {
        guard let panel = meetingWindow else { return }
        let live = meeting.isActive
        panel.level = live ? .floating : .normal
        panel.becomesKeyOnlyIfNeeded = live
        // Spaces follow the same split: the live strip floats over every
        // Space and full-screen call; the library is an ordinary window that
        // lives on its own Space. canJoinAllSpaces on the LIBRARY was the
        // owner's "it throws me to another screen" (2026-08-29) — the window
        // popped up on whatever display it was left on, and activation
        // dragged the eyes there.
        panel.collectionBehavior = live
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : []
    }


    /// Menu toggle for the meeting transcript.
    ///
    /// The consent reminder appears ONCE, before the first meeting this
    /// installation ever records.
    ///
    /// It used to appear before every session. Recording other people without
    /// their knowledge is illegal in many places, so a menu click should not
    /// quietly become a legal problem — but somebody who reaches for "Record
    /// Meeting" for the tenth time has already been told, and a dialog that
    /// repeats itself weekly is dismissed unread, which is the opposite of
    /// informed (owner's call, 2026-08-19). Said once, at the moment it is
    /// news, it is a notice; said every time, it is only friction.
    private func toggleMeetingTranscript() {
        if meeting.isActive {
            meeting.stop()
            return
        }
        if !Settings.shared.meetingConsentSeen {
            // The app's own consent card (design), NSAlert retired. Return
            // starts, Esc declines; the ring rests on Don't Record.
            guard ConsentDialog.run() else { return }
            // Only after they agreed: someone who cancels has not been told
            // anything they acted on, and deserves the notice again.
            Settings.shared.meetingConsentSeen = true
        }
        // The menu too starts as the pill (owner's call, 2026-08-31: the
        // portal opened over his screen again) — the full window appears
        // only when the person opens it themselves. With the window already
        // open, the guard below records in it, same as the card's path.
        startMeetingSession(asPill: true)
    }

    /// The actual start, shared by the menu, the window's Record control and
    /// the call prompt (which carries its own consent line, so it comes here
    /// directly). `asPill` is the presentation: the recording starts as the
    /// small pill and the window stays wherever it was (owner's rule — the
    /// portal only ever opens by hand). `fromCallPrompt` is the provenance,
    /// kept separate on purpose: it seeds the auto-stop's "a call platform
    /// was here" flag, and a menu start may be no call at all — seeding it
    /// there would let the dead-air stop kill a dictated note 90 s into its
    /// first pause.
    private func startMeetingSession(asPill: Bool = false, fromCallPrompt: Bool = false) {
        callPrompt.hide()
        do {
            try meeting.start(fromCallPrompt: fromCallPrompt)
            statusController.applyState(dictation.state)   // show the red mark
            // The pill only when there is no window already on screen: with
            // the portal open, recording lands in it — a pill OVER an open
            // window would be two surfaces for one recording (weak-case
            // review, 2026-08-29).
            if asPill, meetingWindow?.isVisible != true {
                meetingMinimized = true
                meetingPillController().show(from: nil)
                Log.d("meeting: started as the pill")
            } else {
                showMeetingWindow()
            }
        } catch {
            statusController.showError(Lf("Couldn't start the meeting transcript: %@",
                                          error.localizedDescription))
        }
    }

    /// A call was recognised (CallDetector): the market's converged answer —
    /// detect, then ask. Always ask (owner's call, 2026-08-29): the offer is
    /// automatic, the recording never is. With noticing OFF, the card is the
    /// one-time educational offer instead — and after two declines (or an
    /// explicit never), calls pass in silence.
    private func callDetected(platform: String?) {
        guard !meeting.isActive else { return }
        if Settings.shared.noticeCalls {
            Log.d("call: prompting")
            callPrompt.show(platform: platform, style: .prompt) { [weak self] in
                self?.startMeetingSession(asPill: true, fromCallPrompt: true)
            }
            return
        }
        guard OfferLedger.mayOffer(.recordCallAudio) else { return }
        Log.d("call: offering (noticing off)")
        callPrompt.show(platform: platform, style: .offer) { [weak self] in
            // Accepting the offer IS turning the capability on — a "Record
            // this call" that then recorded only the microphone would be
            // the silent degradation section 9 forbids.
            MeetingCapability.recordCallAudio.isOn = true
            MeetingCapability.separateVoices.isOn = true
            OfferLedger.decided(.recordCallAudio)
            self?.startMeetingSession(asPill: true, fromCallPrompt: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostics first: catch a wedged main thread (CoreAnimation ↔
        // WindowServer freeze) and write evidence to ~/Library/Logs/Dictate.
        MainThreadWatchdog.shared.start()

        // Capability migration (design MeetingsOff, 2026-08-29): the
        // switches default OFF for a fresh install — the meetings window's
        // first-run screen is the onboarding. An installation that already
        // recorded meetings (or consented to) predates the switches; for it
        // they describe what was already happening, so they migrate to on.
        if !Settings.shared.meetingCapsMigrated {
            Settings.shared.meetingCapsMigrated = true
            let existing = Settings.shared.meetingConsentSeen
                || !((try? FileManager.default.contentsOfDirectory(
                        at: MeetingArchive.directory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "md" }.isEmpty
            if existing {
                Settings.shared.noticeCalls = true
                Settings.shared.recordCallAudio = true
                Settings.shared.separateVoices = true
                Settings.shared.readMeetings = true
                Log.d("meeting: capability migration — existing install, all on")
            }
        }

        // Call detection. Armed only after onboarding: a first-run user
        // meets the consent story in order, not as a popup over their call.
        // The watcher runs even with noticing OFF — solely to make the
        // one-time "this call is not being recorded" offer (design
        // MeetingsOff); after two declines it goes quiet for good.
        callDetector.isRecording = { [weak self] in self?.meeting.isActive ?? false }
        callDetector.onCallDetected = { [weak self] platform in
            self?.callDetected(platform: platform)
        }
        callDetector.onCallOver = { [weak self] in
            self?.callPrompt.callOver()
        }
        if Settings.shared.onboardingDone { callDetector.start() }

        // Before anything acquires state worth keeping: a translocated run is
        // offered a one-click move to /Applications (or quits) — every launch
        // from the DMG only manufactures broken TCC state.
        AppRelocator.offerMoveIfTranslocated()

        // Permanent Dock presence (Settings › General). The meetings portal
        // made this a real windowed app, so the icon is on by default; the
        // toggle returns the old accessory behavior for utility purists.
        applyDockPolicy()
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil
        )

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
            meetingActive: { [weak self] in self?.meeting.isActive ?? false },
            meetingStarted: { [weak self] in
                guard let self, self.meeting.isActive else { return nil }
                return self.meeting.startedAt
            },
            toggleMeeting: { [weak self] in self?.toggleMeetingTranscript() },
            showMeetings: { [weak self] url in self?.showMeetingWindow(select: url, focus: true) },
            pillHidden: { [weak self] in
                guard let self else { return false }
                return self.meeting.isActive && self.meetingPill?.isUserHidden == true
            },
            showPill: { [weak self] in self?.meetingPillController().showAgain() }
        )
        // The URL is USED, not ignored: onFinished fires twice — once when the
        // transcript is closed on disk, and again after the model has named it
        // and the file has been RENAMED to carry that name. Dropping the second
        // URL left the window holding a path that no longer existed, so "Show
        // in Finder" revealed nothing, and Rename and Move to Trash were
        // pointed at a ghost (found 2026-08-19, right after a webinar).
        // Passing it through as `select:` makes the window notice the file is
        // not in its list, reload, and land on it.
        meeting.onFinished = { [weak self] url in
            guard let self else { return }
            // The window IS the reader now: the finished transcript simply
            // becomes the newest item in the library, in place. No external
            // editor, no file hunting. Not `focus:` — the call itself may well
            // still be running, and the moment a transcript closes is the worst
            // possible one to grab the keyboard.
            // Someone who folded the transcript away asked not to look at it;
            // finishing is not a reason to overrule that. The meeting is in the
            // library either way, one menu click from here.
            let wasMinimized = self.meetingMinimized
            self.meetingMinimized = false
            self.meetingPill?.hide()
            if !wasMinimized { self.showMeetingWindow(select: url) }
            // Drop the red recording indicator from the menu bar.
            self.statusController.applyState(self.dictation.state)
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
                    self.hud.showRecording(translate: self.dictation.activeTranslate,
                                           alsoMeeting: self.meeting.isActive,
                                           queuedBehind: self.dictation.recognizingCount)
                    // Dictating in the first seconds after launch, before the
                    // model is loaded: the panel says it is preparing and to
                    // keep holding (design DictationOverlay: warming), then
                    // flips back the moment the engine is ready. Only for a
                    // model already on disk — a missing one has its own
                    // download flow.
                    Task { @MainActor in
                        guard await !WhisperEngine.shared.isReady(for: .fast),
                              WhisperEngine.shared.isModelDownloaded(tier: .fast)
                        else { return }
                        self.hud.setWarming(true)
                        while await !WhisperEngine.shared.isReady(for: .fast) {
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                        self.hud.setWarming(false)
                    }
                case .transcribing:
                    self.hud.showTranscribing(translate: self.dictation.activeTranslate)
                case .idle:
                    // showResult hides the HUD itself; hide here only for cancel/short press
                    if !self.resultShown { self.hud.hide() }
                }
            }
        }
        dictation.onResult = { [weak self] success, _, _, text, appName in
            DispatchQueue.main.async {
                self?.resultShown = true
                if success {
                    self?.hud.showInserted(app: appName, text: text)
                    self?.maybeShowTranslateTip()
                } else {
                    self?.hud.showResult(success: false)
                }
            }
        }
        hud.onOpenSettings = { [weak self] in self?.showSettings() }
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
                case .copiedInstead(let text): self.hud.showCopied(text: text)
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
        dictation.onLiveTypingStarted = { [weak self] app in
            DispatchQueue.main.async { self?.hud.setLiveTyping(app: app) }
        }
        dictation.onLiveTyped = { [weak self] words in
            DispatchQueue.main.async { self?.hud.setTypedWords(words) }
        }
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
        removeRetiredTextKnobs()
        // Third of the three layers that keep the text model's helper process
        // from outliving us (the other two are the quit below and SIGPIPE on
        // our log pipe when we crash): anything still running from a previous
        // run dies here. The app is a login item, so "the next launch" is soon.
        LlamaServer.reapOrphans()
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

        // The meetings window's corner menu (design): its rows arrive here.
        // The block-API observers RETURN a token that must be kept alive —
        // discarded, the observation dies on the spot, and every corner-menu
        // row posted into silence (owner's field report 2026-08-31: "click
        // Settings, nothing happens").
        menuObservers.append(NotificationCenter.default.addObserver(
            forName: .init("dictate.openSettings"), object: nil, queue: .main
        ) { [weak self] _ in
            Log.d("corner: openSettings notification received")
            self?.showSettings()
        })
        menuObservers.append(NotificationCenter.default.addObserver(
            forName: .init("dictate.checkUpdates"), object: nil, queue: .main
        ) { [weak self] _ in
            Log.d("corner: checkUpdates notification received")
            self?.activateThenRun { self?.updater.checkForUpdates(nil) }
        })

        applyDebugShot()
    }

    /// Hidden screenshot harness for the design pass: `defaults write
    /// com.valentynbudanov.Dictate debugShot "<surface[:variant]>"` and a
    /// relaunch opens a surface with no clicking, so every screen can be
    /// photographed and compared to the mockups. The key is read once and
    /// CLEARED — a normal launch is never affected.
    private func applyDebugShot() {
        let d = UserDefaults.standard
        guard let shot = d.string(forKey: "debugShot") else { return }
        d.removeObject(forKey: "debugShot")
        Log.d("debugShot: \(shot)")
        let parts = shot.split(separator: ":").map(String.init)
        let variant = parts.count > 1 ? parts[1] : ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            switch parts.first ?? "" {
            case "settings":
                if !variant.isEmpty { d.set(variant, forKey: "debugShotTab") }
                showSettings()
            case "onboarding":
                if !variant.isEmpty { d.set(variant, forKey: "debugShotStep") }
                showOnboarding()
            case "meetings":
                if !variant.isEmpty { d.set(variant, forKey: "debugShotMeetings") }
                showMeetingWindow(focus: true)
            case "menu":
                // performClick blocks in menu tracking; a runloop timer still
                // fires, so the menu closes itself after the photograph.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    self.statusController.debugCloseMenu()
                }
                statusController.debugOpenMenu()
            case "hud":
                debugHUD(variant.isEmpty ? "recording" : variant)
            case "callprompt":
                // The detection card, both faces, without a call: the record
                // action only logs — a photograph must not start a session.
                callPrompt.show(platform: variant == "unnamed" ? nil : "Zoom",
                                style: variant == "offer" ? .offer : .prompt) {
                    Log.d("debugShot: callprompt record tapped")
                }
            default:
                break
            }
        }
    }

    private func debugHUD(_ state: String) {
        switch state {
        case "warming":
            hud.showRecording(translate: false, alsoMeeting: false, queuedBehind: 0)
            hud.setWarming(true)
        case "recording":
            hud.showRecording()
            hud.setLivePreview("let's move the release to the fourteenth and tell the beta group")
        case "translating":
            hud.showRecording(translate: true)
            hud.setLivePreview("the release moves to the fourteenth, and I will tell the beta group tonight")
        case "also":
            hud.showRecording(alsoMeeting: true)
            hud.setLivePreview("let's move the release to the fourteenth")
        case "queued":
            hud.showTranscribing()
            hud.setTranscribeProgress(0.6, words: 34)
            hud.showRecording(queuedBehind: 1)
            hud.setLivePreview("and add Priya to the invite")
        case "livetyping":
            hud.showRecording()
            hud.setLiveTyping(app: "Notes")
            hud.setTypedWords(31)
            hud.setLivePreview("and tell the beta group")
        case "recognizing":
            hud.showTranscribing()
            hud.setTranscribeProgress(0.64, words: 34)
        case "inserted":
            hud.showInserted(app: "Mail", text: "Let's move the release to the fourteenth and tell the beta group tonight, before the localization freeze.")
        case "copied":
            hud.showCopied(text: "Let's move the release to the fourteenth and tell the beta group tonight.")
        case "cancelled": hud.showCancelled()
        case "empty": hud.showResult(success: false)
        case "micbusy": hud.showMicBusy(appName: "Zoom")
        case "tooquiet": hud.showTooQuiet()
        case "tooloud": hud.showTooLoud()
        case "tip": hud.showTranslateTip(keyName: "Right ⌘")
        case "packmissing": hud.showTranslateDataMissing()
        case "downloading": hud.showDownloading(0.65, totalMB: 630)
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if meeting.isActive { meeting.stop() }
        dictation.shutdown()
        // Synchronous, and it has to be: this handler does not outlive an async
        // hop, and a helper still running after we exit is precisely what the
        // child-process design exists to prevent. Costs nothing when no helper
        // is running, which is the usual case.
        LlamaServer.shared.shutdown()
    }

    /// The vocabulary prompt and user replacement rules left the app with
    /// their settings UI (owner's call, 2026-08-27). A stored prompt that
    /// nothing displays any more would silently keep biasing every
    /// recognition — the exact failure GRABLI documents — so the keys go too.
    private func removeRetiredTextKnobs() {
        for key in ["prompt", "replacements", "removeFillers"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
        // Same up-front disk check as onboarding — a silent background
        // download must not be the thing that fills the disk.
        let neededMB = Int(Double(ModelTier.fast.sizeMB) * 1.5) + 200
        let freeMB = OnboardingView.freeDiskMB()
        guard freeMB >= neededMB else {
            Log.d("model: catch-up skipped — \(freeMB) MB free, needs \(neededMB)")
            return
        }
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

    // MARK: - Dock presence

    /// Applies the "Show in Dock" setting. With it on the app is a regular
    /// windowed citizen (Cmd+Tab, permanent icon); with it off the icon only
    /// appears while one of our windows is open (the old accessory pattern —
    /// someWindowClosed drops back to .accessory).
    private func applyDockPolicy() {
        if Settings.shared.showInDock {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        } else {
            let anyWindowOpen = [onboardingWindow, settingsWindow, meetingWindow]
                .compactMap { $0 }
                .contains { $0.isVisible }
            if !anyWindowOpen, NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc private func defaultsChanged() {
        // Cheap idempotent re-apply; UserDefaults.didChangeNotification fires
        // on the posting thread, and policy changes belong on main.
        DispatchQueue.main.async { [weak self] in self?.applyDockPolicy() }
    }

    // Dock icon click / reopen. The meetings portal is the app's main window
    // now, so that is what a Dock click opens (Settings stays one menu away).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Never trust `flag`: the invisible 1×1 translator host panel counts
        // as a visible window, so it is always true and a Dock click / reopen
        // would silently do nothing. Check OUR windows instead.
        let ourWindowOpen = [onboardingWindow, settingsWindow, meetingWindow]
            .compactMap { $0 }
            .contains { $0.isVisible }
        if !ourWindowOpen {
            if Settings.shared.onboardingDone {
                showMeetingWindow(focus: true)
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
        // The view draws its own 46 px top strip with the "Step N of 5" label
        // (design 12j); the native title bar goes transparent so only the
        // traffic lights remain, overlaying that strip.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // Always light (owner's call 2026-08-29): a first-run user has not
        // chosen Dictate an appearance yet, and the mockups' canonical face
        // is the light one — the theme choice comes later, in Settings.
        window.appearance = NSAppearance(named: .aqua)
        onboardingWindow = window
        present(window)
    }

    private func showSettings() {
        if let settingsWindow {
            Log.d("corner: showSettings — cached window (visible=\(settingsWindow.isVisible))")
            // The anchor matters on reopen too: without it the cached
            // window resurfaces wherever it was last shown, which may be a
            // different display from the meetings window that asked.
            present(settingsWindow,
                    over: meetingWindow?.isVisible == true ? meetingWindow : nil)
            return
        }
        Log.d("corner: showSettings — building the window")
        // The manual update check moved here from the status menu: updates are
        // found daily and installed silently, so asking by hand is a rare,
        // impatient act — and it is the same Sparkle call it always was.
        let view = SettingsView(
            onHotkeyChanged: { [weak self] in self?.dictation.restart() },
            onCheckForUpdates: { [weak self] in
                self?.activateThenRun { self?.updater.checkForUpdates(nil) }
            })
        let window = makeWindow(title: L("Dictate Settings"), content: view)
        settingsWindow = window
        present(window, over: meetingWindow?.isVisible == true ? meetingWindow : nil)
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
        // The window comes to the person, not the person to the window: the
        // meetings panel rides every Space (canJoinAllSpaces), so its corner
        // menu gets clicked from INSIDE full-screen apps — and a plain
        // window then opened on the desktop Space, invisibly (field logs
        // 2026-08-31 12:58: ordered front, visible, active — and the owner
        // in full-screen PyCharm saw nothing). moveToActiveSpace brings it
        // to the current Space; fullScreenAuxiliary lets that Space be a
        // full-screen one.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        // Subscribe once per window here — present() runs on every reopen, and
        // duplicate observers would fire someWindowClosed N times per close.
        NotificationCenter.default.addObserver(
            self, selector: #selector(someWindowClosed),
            name: NSWindow.willCloseNotification, object: window
        )
        return window
    }

    /// Runs UI that is about to go MODAL (Sparkle's alerts, panels) only
    /// after the app is truly frontmost. Activation kicked off in the same
    /// runloop turn has not settled yet — a modal alert fired that instant
    /// opens BEHIND other apps' windows, invisible, and the modal loop then
    /// reads as a hang (watchdog, 2026-08-31 12:32 and 12:42: the "You're
    /// up to date" alert, twice).
    private func activateThenRun(_ work: @escaping () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { work() }
    }

    private func present(_ window: NSWindow, over anchor: NSWindow? = nil) {
        // Opened from inside another window, Settings replaces it visually:
        // same screen, centred on that window's frame (owner's call
        // 2026-08-28) — not on whichever screen the mouse happens to be.
        if let anchor, anchor.isVisible {
            let a = anchor.frame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: a.midX - size.width / 2,
                                          y: a.midY - size.height / 2))
        }
        // .regular while a window is open so Cmd+Tab and focus behave normally;
        // back to .accessory once all our windows close.
        NSApp.setActivationPolicy(.regular)
        // The window is cached and remembers the display it was last shown on,
        // which may not be where the user is now. With an anchor the RULE is
        // absolute (owner, 2026-08-31): the main window open means Settings
        // sits over the main window, full stop — the cursor's screen must
        // not override that. Only an anchorless open (menu bar, Dock, no
        // meetings window) follows the cursor.
        let mouse = NSEvent.mouseLocation
        if anchor == nil,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           window.screen !== screen {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }
        if let vis = (window.screen ?? NSScreen.main)?.visibleFrame,
           window.frame.height > vis.height {
            let size = NSSize(width: min(window.frame.width, vis.width),
                              height: min(748, vis.height))
            window.setFrame(NSRect(x: vis.midX - size.width / 2,
                                   y: vis.midY - size.height / 2,
                                   width: size.width, height: size.height),
                            display: true)
        }
        // Activate on the next runloop turn: the .accessory→.regular switch must
        // settle first, otherwise Picker/Menu popups can't open (the app isn't
        // truly frontmost yet).
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // Above other apps' windows even when cooperative activation
            // says no — which it does whenever the request originates in
            // the meetings panel: a NON-ACTIVATING panel's clicks never
            // count as "the user is in this app", so activate() is quietly
            // refused and the window lands BEHIND the frontmost app
            // (field logs 2026-08-31 12:53: ordered front, visible=true,
            // and the owner saw nothing).
            window.orderFrontRegardless()
            Log.d("present: \(window.title.isEmpty ? "window" : window.title) ordered front — visible=\(window.isVisible) frame=\(Int(window.frame.origin.x)),\(Int(window.frame.origin.y)) \(Int(window.frame.width))x\(Int(window.frame.height)) screen=\(window.screen?.localizedName ?? "nil") active=\(NSApp.isActive) onActiveSpace=\(window.isOnActiveSpace)")
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
            // With a permanent Dock icon the policy never drops; without one,
            // the icon disappears when the last of our windows closes.
            guard !Settings.shared.showInDock else { return }
            let stillOpen = [self.onboardingWindow, self.settingsWindow, self.meetingWindow]
                .compactMap { $0 }
                .contains { $0 !== closing && $0.isVisible }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
