import AppKit
import Carbon.HIToolbox

/// The menu bar icon and its menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let dictation: DictationController
    private let openSettings: () -> Void
    private let meetingActive: () -> Bool
    /// When the running session started — for the live entry's clock. nil when
    /// nothing is being recorded.
    private let meetingStarted: () -> Date?
    private let toggleMeeting: () -> Void
    /// Opens the meetings window. A URL selects that transcript; nil opens the
    /// window wherever it would open on its own (the live call, or the newest
    /// meeting in the library).
    private let showMeetings: (URL?) -> Void
    private var lastError: String?

    init(dictation: DictationController,
         openSettings: @escaping () -> Void,
         meetingActive: @escaping () -> Bool,
         meetingStarted: @escaping () -> Date?,
         toggleMeeting: @escaping () -> Void,
         showMeetings: @escaping (URL?) -> Void) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.dictation = dictation
        self.openSettings = openSettings
        self.meetingActive = meetingActive
        self.meetingStarted = meetingStarted
        self.toggleMeeting = toggleMeeting
        self.showMeetings = showMeetings
        super.init()

        item.button?.toolTip = L("Dictate — voice dictation")
        item.isVisible = true
        updateIcon(for: .idle)

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func applyState(_ state: DictationController.State) {
        // A new dictation makes the stored error stale — without this the
        // "⚠️ …" menu line from one long-fixed failure sticks around forever.
        if state == .recording { lastError = nil }
        updateIcon(for: state)
    }

    func showError(_ message: String) {
        lastError = message
        if let button = item.button {
            button.image = coloredSymbol("exclamationmark.triangle.fill", color: .systemYellow)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.updateIcon(for: self.dictation.state)
        }
    }

    // The icon is always the brand wave (monochrome template per HIG) — the
    // state shows as motion, not as a different colored symbol: recording
    // makes the bars dance to the voice, transcribing ripples them.
    private var rippleTimer: Timer?
    private var ripplePhase: Double = 0
    private var smoothedLevel: Double = 0

    private func updateIcon(for state: DictationController.State) {
        guard let button = item.button else { return }
        stopRipple()
        stopMeetingPulse()
        switch state {
        case .idle:
            // A live meeting shows as a RED WAVE the whole time — an armed
            // recording must never be invisible, and it doubles as the "don't
            // forget to stop" reminder. It was a static red dot, and a dot is
            // only proof that the app INTENDS to record; bars that move with
            // the room are proof that it is hearing something, which is the
            // question actually being asked when the transcript is hidden.
            // Dictation states (below) still take over while a dictation runs.
            if meetingActive() {
                startMeetingPulse()
            } else {
                button.image = Self.waveIcon
                button.toolTip = nil
            }
        case .recording:
            smoothedLevel = 0
            button.image = Self.waveImage(scale: { _ in 0.3 })
        case .transcribing:
            startRipple()
        }
    }

    /// Voice level 0…1 while recording — the menu bar bars follow it.
    func setLevel(_ level: Double) {
        guard dictation.state == .recording else { return }
        smoothedLevel = smoothedLevel * 0.6 + level * 0.4
        let l = smoothedLevel
        item.button?.image = Self.waveImage(scale: { _ in 0.3 + 0.7 * l })
    }

    /// The running meeting's mark: a red wave breathing on a fixed cycle.
    ///
    /// Mechanical on purpose, and it started out the other way. Driving the
    /// bars from the meeting's audio level was the obvious idea — the dictation
    /// mark does exactly that — but it answers a question nobody is asking. A
    /// glance at the menu bar during a call asks "is this thing still
    /// recording", not "how loud is the room right now"; and level-driven bars
    /// go flat during every pause, which is the one moment the answer must not
    /// look like "no". A steady breath says "running" and cannot say anything
    /// misleading.
    ///
    /// Cost is why the period is what it is: a dictation lasts seconds, a
    /// meeting runs for forty minutes, and this project has twice paid a
    /// double-digit percentage of a core for motion that never settled
    /// (GRABLI). Five redraws a second of an 18pt image is a different order of
    /// thing from a SwiftUI animation asking the window for sixty frames — but
    /// it is not free either, which is why it steps five times a second and not
    /// twelve like the ripple it sits next to.
    private var pulseTimer: Timer?
    private var pulsePhase: Double = 0
    private static let pulseStep: TimeInterval = 0.2
    private static let pulsePeriod: Double = 2.0

    private func startMeetingPulse() {
        stopMeetingPulse()
        pulsePhase = 0
        drawPulse()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: Self.pulseStep, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulsePhase += Self.pulseStep / Self.pulsePeriod * 2 * .pi
            self.drawPulse()
        }
    }

    private func drawPulse() {
        // 0.35…0.95 — never flat (flat would read as "not recording") and never
        // at full height (that is the idle mark's size, and the two must not
        // look the same at a glance).
        let breath = 0.65 + 0.30 * sin(pulsePhase)
        item.button?.image = Self.waveImage(scale: { _ in breath }, color: .systemRed)
        item.button?.toolTip = meetingTip()
    }

    private func stopMeetingPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    /// What hovering the mark says. The wave proves the app is hearing
    /// something; the tooltip answers the two questions it cannot — how long
    /// this has been running, and whether anything is being written down.
    private func meetingTip() -> String {
        guard let start = meetingStarted() else { return L("Recording") }
        return Lf("Recording · %@", Self.elapsed(since: start))
    }

    private func startRipple() {
        ripplePhase = 0
        rippleTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ripplePhase += 0.5
            let phase = self.ripplePhase
            self.item.button?.image = Self.waveImage(scale: { i in
                0.55 + 0.45 * sin(phase + Double(i) * 0.9)
            })
        }
    }

    private func stopRipple() {
        rippleTimer?.invalidate()
        rippleTimer = nil
    }

    private func coloredSymbol(_ name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        img?.isTemplate = false
        return img
    }

    /// Template image (HIG: menu bar icons are monochrome; the system recolors it for light/dark).
    private static let waveIcon = waveImage(scale: { _ in 1 })

    /// Brand wave with per-bar height multipliers (0…1) for the animated states.
    ///
    /// `color` breaks the template rule on purpose, and only for one state: a
    /// live meeting. HIG wants menu bar icons monochrome so the system can
    /// recolor them, and every state here obeys that — except the one that says
    /// a recording is running, where red is the convention every recorder on
    /// this platform (and the system's own privacy dot) already uses. It
    /// replaced a red `record.circle.fill`, so the colour is not new; what is
    /// new is that the mark now moves with the voices it is recording.
    private static func waveImage(scale: (Int) -> Double, color: NSColor? = nil) -> NSImage {
        let s: CGFloat = 18
        let image = NSImage(size: NSSize(width: s, height: s))
        image.lockFocus()
        (color ?? .black).setFill()
        let profile: [CGFloat] = [0.36, 0.64, 1.0, 0.64, 0.36]
        let barW: CGFloat = 2.4
        let gap: CGFloat = 3.5
        let startX = (s - (CGFloat(profile.count - 1) * gap + barW)) / 2
        for (i, hf) in profile.enumerated() {
            let h = max(2.4, s * 0.80 * hf * CGFloat(scale(i)))
            let r = NSRect(x: startX + CGFloat(i) * gap, y: (s - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        image.unlockFocus()
        image.isTemplate = color == nil
        return image
    }

    // Rebuilt on every open so the items reflect current state.
    //
    // The app does two things — it records meetings and it dictates — and the
    // menu says so: two labelled sections (NSMenuItem.sectionHeader, macOS 14+,
    // and this app requires 15), meetings first. Dictation lives on a hotkey
    // and is hardly ever *started* from here; the menu is opened to record a
    // call or to go back to one. HIG: group related items, frequent groups
    // above rare ones, attributes apart from actions.
    //
    // On the key equivalents below. A status-item menu is NOT the main menu, so
    // its shortcuts are live only while the menu itself is open — measured, not
    // assumed: a harness item fires from a menu in tracking (submenus included)
    // and never with the menu closed, app active or not. ⌘, on Settings is kept
    // because it means the same here as everywhere in macOS. The library
    // deliberately has NO shortcut: ⌘M is the system's Minimize, in the Window
    // menu of nearly every app, and a benefit that exists only while the menu
    // is already open — where everything is one mouse move away — does not pay
    // for teaching that key a second meaning.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Warnings first and unlabelled: they explain why the app looks broken,
        // and nothing else in the menu matters until they are read.
        var warned = false
        // Secure Keyboard Entry (password fields, Terminal option) blocks key capture system-wide.
        if IsSecureEventInputEnabled() {
            menu.addItem(Self.label("⚠️ " + L("Secure input is on (password field?) — the hotkey won't work for now")))
            warned = true
        }
        if let lastError {
            menu.addItem(Self.label("⚠️ \(lastError)"))
            warned = true
        }
        if warned { menu.addItem(.separator()) }

        menu.addItem(.sectionHeader(title: L("Meetings")))

        // Meeting transcript: local two-channel recording of a browser call
        // (mic = You, system audio = Them). "Record Meeting", because the
        // transcript is the by-product — recording is what is being asked for.
        //
        // The one symbol in this menu, and the one item that gets any emphasis
        // at all. It is the menu's primary action and nothing but its position
        // said so; a red record glyph says both "this is the thing" and WHAT
        // the thing does, which a bold title could not. Apple's own menus never
        // bold an item — they carry meaning in symbols — and the emphasis only
        // works while it is alone: a menu where every row has an icon
        // highlights nothing.
        let recording = meetingActive()
        let record = NSMenuItem(
            title: recording ? L("Stop Recording") : L("Record Meeting"),
            action: #selector(meetingClicked), keyEquivalent: ""
        )
        // Not a template image: a template is recoloured to the menu's own text
        // colour, which is exactly the meaning being removed here. A palette
        // configuration keeps it red in both appearances and under the
        // highlight bar.
        record.image = Self.redSymbol(recording ? "stop.circle.fill" : "record.circle")
        record.target = self
        menu.addItem(record)

        // The way BACK to a running transcript belongs at the top level, next
        // to the way to stop it. It also lives inside the Meetings submenu
        // below, and that was the whole of it until a field test found the
        // hole: with the window closed and the pill hidden, the menu is the
        // only door left, and a door behind a submenu is a door nobody finds
        // ("there was only Stop Recording" — 2026-08-19).
        if recording {
            let show = NSMenuItem(title: L("Show Live Transcript"),
                                  action: #selector(showLiveMeeting), keyEquivalent: "")
            show.target = self
            menu.addItem(show)
        }

        addMeetingsItem(to: menu)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("Dictation")))

        // What each key does, spelled out. These were once two rows at the very
        // TOP of the menu, holding its most valuable position while being
        // unclickable; they were then collapsed into one glyph line
        // ("⌥ dictate · ⌘ English"), which fit but stopped explaining itself —
        // it never said what the second key does or in which direction. Under a
        // heading, halfway down the menu, a second line is cheap and a sentence
        // is worth having.
        for line in dictationKeyLines() { menu.addItem(Self.label(line)) }

        // Safety net: recent results are recoverable even when a paste went
        // nowhere or the clipboard got overwritten. Click → copy.
        if !dictation.history.isEmpty {
            let recent = NSMenuItem(title: L("Recent Dictations"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for text in dictation.history {
                let entry = NSMenuItem(title: Self.shortened(text),
                                       action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = text
                entry.toolTip = text
                sub.addItem(entry)
            }
            recent.submenu = sub
            menu.addItem(recent)
        }

        menu.addItem(.separator())

        // The service group stays unlabelled — a heading over "Settings…" would
        // only name what the items already say. "Check for Updates…" is gone
        // from here: it now sits beside the version number in Settings.
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: L("About Dictate"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("Quit Dictate"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// The way into the library: the window, and — the point of this — the last
    /// few meetings, so going back to one is a click instead of a click, a
    /// window and a hunt down a list.
    ///
    /// "Show All Meetings…" sits at the BOTTOM, under a separator. It was tried
    /// at the top — a parent item with a submenu does not fire on click, so the
    /// window costs one step more than it used to, and first place makes that
    /// step positional rather than something to read. The owner then went
    /// looking for it at the end of the list and asked where it had gone: "see
    /// all" lives last in every list a Mac user has ever opened, and a
    /// convention people navigate by beats a saved inch of mouse travel.
    ///
    /// Every row leads with its DATE, "12 Aug · Agent Discussion", so the dates
    /// line up down the left edge of a newest-first list and the eye can find
    /// last week without reading a single title. The month comes from the
    /// locale's own short form (an English interface gets "12 Aug", a Russian
    /// one "12 авг."), because a hardcoded English month in a Russian menu is a
    /// bug, not a style.
    /// One row, not a submenu of recent meetings.
    ///
    /// There used to be a list of the five newest transcripts here. It was a
    /// poor copy of the library — no summary, no tags, no search, five of
    /// however many — kept behind a hover, and everything it did uniquely (the
    /// running call) now sits at the top level as "Show Live Transcript". It
    /// also cost a file read per meeting on EVERY menu open, in a folder that
    /// iCloud may have evicted, which is a stall this app has already paid for
    /// once. The menu does actions; the window does browsing.
    private func addMeetingsItem(to menu: NSMenu) {
        let item = NSMenuItem(title: L("Meetings…"),
                              action: #selector(showAllMeetings), keyEquivalent: "")
        item.image = Self.plainSymbol("list.bullet.rectangle")
        item.target = self
        menu.addItem(item)
    }
    /// "12 Aug · Agent Discussion". Only the TITLE is ever cut — the date is
    /// the part that has to survive, and it is what makes the column scannable.
    private static func row(for meeting: RecentMeeting) -> String {
        Self.shortDate(meeting.started) + " · " + shortened(meeting.name)
    }

    /// One line per key, saying which key and what comes out of it:
    ///
    ///     Right Option (⌥) — dictate in Russian
    ///     Right Command (⌘) — translate Russian → English
    ///
    /// The key is named exactly as Settings and onboarding name it, side
    /// included: left and right modifiers are different keycodes in this app,
    /// people have been bitten by that, and a bare "⌥" cannot say which one is
    /// bound.
    ///
    /// Languages are named in the LANGUAGE OF THE INTERFACE — "dictate in
    /// Russian", not "dictate in Русский". The endonym is the right label in
    /// the picker, where a person hunts for their own language and has to
    /// recognise it in its own script; inside a sentence written in another
    /// language it reads as a glitch.
    private func dictationKeyLines() -> [String] {
        let spoken = Settings.shared.language
        let dictateKey = KeyNames.displayName(Settings.shared.hotkeyName)
        // "" is Automatic (any language) — Whisper decides per dictation, so
        // there is no language to name and saying one would be a guess.
        var lines = [spoken.isEmpty
            ? Lf("%@ — dictate in any language", dictateKey)
            : Lf("%@ — dictate in %@", dictateKey, LanguageList.name(for: spoken))]

        guard let _ = Settings.shared.translateKeyCode else { return lines }
        let target = Settings.shared.translateTargetCode
        // Speaking the target language already: the runtime skips the
        // translation hop entirely in that case (there is no en→en), so the
        // second key does exactly what the first does and a line claiming a
        // translation would be a lie.
        guard spoken != target else { return lines }
        let translateKey = KeyNames.displayName(Settings.shared.translateKeyName)
        lines.append(spoken.isEmpty
            ? Lf("%@ — translate into %@", translateKey, LanguageList.name(for: target))
            : Lf("%@ — translate %@ → %@", translateKey,
                 LanguageList.name(for: spoken), LanguageList.name(for: target)))
        return lines
    }

    /// A red SF Symbol at menu-item size.
    private static func redSymbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    /// An SF Symbol in the menu's own ink — a template image, so it follows the
    /// text colour in both appearances and under the highlight bar.
    private static func plainSymbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// A line of text in the menu rather than a command.
    private static func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Menu-width truncation, one rule for both submenus so they read as
    /// siblings.
    private static func shortened(_ text: String) -> String {
        text.count > 50 ? String(text.prefix(50)) + "…" : text
    }

    private static func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private struct RecentMeeting {
        let url: URL
        let started: Date
        /// The meeting's name, or the time of day it happened when the model
        /// never managed to name it (the date is on the row already).
        let name: String
    }

    /// The newest transcripts, read the cheap way — this runs on every single
    /// open of the menu.
    ///
    /// `MeetingArchive.list()` opens and fully parses EVERY file in the folder
    /// (entries, summary, sections), which is right for the library window and
    /// wrong here: nineteen meetings today, a working year of them later, all
    /// to print five titles. So the directory is only *listed* (names, no
    /// reads), the date comes out of our own file names, and exactly five files
    /// are opened — the first 4 KB of each, which is far more than an H1 and
    /// the italic date line under it ever need. Cost per menu open: one
    /// readdir plus five short reads, flat in the size of the archive.
    private static func recentMeetings(limit: Int = 5) -> [RecentMeeting] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: MeetingArchive.directory, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let newest = files
            .filter { $0.pathExtension == "md" }
            .map { url -> (URL, Date) in
                (url, MeetingArchive.startedDate(fileName: url.lastPathComponent)
                    ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return newest.map { url, started in
            RecentMeeting(url: url, started: started,
                          name: head(of: url).flatMap(MeetingArchive.parseTitle) ?? timeOfDay(started))
        }
    }

    /// The first bytes of a transcript — its heading, not the meeting.
    private static func head(of url: URL, bytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        // The cut can land mid-character; decoding leniently keeps the title,
        // which is at the very top, readable regardless.
        return String(decoding: data, as: UTF8.self)
    }

    /// "12 Aug" — the day as a number and the month as the locale's own short
    /// word, from a TEMPLATE rather than a fixed pattern, so the pieces come
    /// out in the order that locale writes them.
    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: date)
    }

    private static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func settingsClicked() {
        openSettings()
    }

    @objc private func meetingClicked() {
        toggleMeeting()
    }

    @objc private func showAllMeetings() {
        showMeetings(nil)
    }

    /// The window opens on the running call by itself when one is running.
    @objc private func showLiveMeeting() {
        showMeetings(nil)
    }

    @objc private func openMeeting(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        showMeetings(url)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "Free & open source · GPL-3.0\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        credits.append(NSAttributedString(
            string: "github.com/Budanovvv/Dictate",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .link: URL(string: "https://github.com/Budanovvv/Dictate")!]
        ))
        credits.append(NSAttributedString(
            string: "\nMade by Valentyn Budanov",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))
        // Show "Version 2.2.0" without the parenthetical build number: it's now
        // the git commit count (a Sparkle-only technical value), meaningless to
        // a user. Empty .version drops the "(…)" the standard panel would add.
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .version: ""])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
