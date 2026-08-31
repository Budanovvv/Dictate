import AppKit
import Carbon.HIToolbox
import SwiftUI

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
    /// The floating timer was hidden by hand while a recording runs — the
    /// menu is then the only way to bring it back (design: hidden state).
    private let pillHidden: () -> Bool
    private let showPill: () -> Void
    private var lastError: String?

    init(dictation: DictationController,
         openSettings: @escaping () -> Void,
         meetingActive: @escaping () -> Bool,
         meetingStarted: @escaping () -> Date?,
         toggleMeeting: @escaping () -> Void,
         showMeetings: @escaping (URL?) -> Void,
         pillHidden: @escaping () -> Bool,
         showPill: @escaping () -> Void) {
        // Variable, not square: while a meeting records, the elapsed time sits
        // right in the strip next to the mark — a long recording must never be
        // forgotten, and a tooltip only answers when someone thinks to hover.
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.dictation = dictation
        self.openSettings = openSettings
        self.meetingActive = meetingActive
        self.meetingStarted = meetingStarted
        self.toggleMeeting = toggleMeeting
        self.showMeetings = showMeetings
        self.pillHidden = pillHidden
        self.showPill = showPill
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
        // The attention state of the mark family: exclamation cursor, mark
        // dimmed — template, like every state. The message itself sits at the
        // top of the menu; the icon only says "look here".
        item.button?.image = FamilyGlyph.menuBarImage(.attention)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.updateIcon(for: self.dictation.state)
        }
    }

    // The icon is the mark family (identity, turn 11): monochrome template in
    // every state, so macOS recolours it for dark menu bars and the open-menu
    // highlight. The cursor is the state carrier — bars move while recording,
    // dots walk while recognizing, a record dot (plus elapsed time) while a
    // meeting runs, an exclamation when something needs attention. The record
    // dot never pulses (13a: one animated element per surface).
    private var rippleTimer: Timer?
    private var ripplePhase: Int = 0
    private var smoothedLevel: Double = 0

    private func updateIcon(for state: DictationController.State) {
        guard let button = item.button else { return }
        stopRipple()
        stopMeetingPulse()
        // The elapsed-time title belongs to the meeting state alone; every
        // other state is icon-only and must not inherit a stale clock.
        button.title = ""
        switch state {
        case .idle:
            if meetingActive() {
                startMeetingPulse()   // static glyph; the timer only drives the clock text
            } else if Permissions.accessibility != .granted {
                // The one problem the icon can announce: the mark dims and the
                // cursor becomes an exclamation. The reason is the first row
                // of the menu — never a notification.
                button.image = FamilyGlyph.menuBarImage(.attention)
                button.toolTip = L("Accessibility is off — dictation can hear you but cannot type")
            } else {
                button.image = FamilyGlyph.menuBarImage(.idle)
                button.toolTip = nil
            }
        case .recording:
            smoothedLevel = 0
            button.image = FamilyGlyph.menuBarImage(.recording(level: 0))
        case .transcribing:
            startRipple()
        }
    }

    /// Voice level 0…1 while recording — the mark's own bars follow it.
    func setLevel(_ level: Double) {
        guard dictation.state == .recording else { return }
        smoothedLevel = smoothedLevel * 0.6 + level * 0.4
        item.button?.image = FamilyGlyph.menuBarImage(.recording(level: smoothedLevel))
    }

    /// The running meeting's mark: the family glyph with the record dot in
    /// the cursor's place, plus the elapsed time in the strip. The dot never
    /// pulses (13a) — a forgotten recording is announced by the TIME growing,
    /// which is the honest signal; the only timer here redraws the clock text
    /// once a second.
    private var pulseTimer: Timer?

    private func startMeetingPulse() {
        stopMeetingPulse()
        drawPulse()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.drawPulse()
        }
    }

    private func drawPulse() {
        item.button?.image = FamilyGlyph.menuBarImage(.meeting)
        item.button?.toolTip = meetingTip()
        if let start = meetingStarted() {
            item.button?.attributedTitle = NSAttributedString(
                string: " " + Self.elapsed(since: start),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            item.button?.imagePosition = .imageLeading
        }
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
        item.button?.image = FamilyGlyph.menuBarImage(.recognizing(phase: 0))
        // Dots-on-the-line, the one place the dots motif is drawn (identity):
        // the lit dot walks left to right, ~3 redraws a second.
        rippleTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ripplePhase += 1
            self.item.button?.image = FamilyGlyph.menuBarImage(.recognizing(phase: self.ripplePhase))
        }
    }

    private func stopRipple() {
        rippleTimer?.invalidate()
        rippleTimer = nil
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
        // and nothing else in the menu matters until they are read. Two-line
        // banners (design 4b/4c): a bold sentence naming the state, a quiet
        // one saying what to do about it.
        var warned = false
        // Secure Keyboard Entry (password fields, Terminal option) blocks key capture system-wide.
        if IsSecureEventInputEnabled() {
            menu.addItem(Self.banner(
                icon: "lock.fill",
                title: L("Secure input is active — the hotkey cannot work"),
                sub: L("Something has a password field focused. macOS does not say which app. Click into an ordinary text field and dictation works again.")))
            warned = true
        }
        if let lastError {
            menu.addItem(Self.banner(icon: "exclamationmark.triangle",
                                     title: lastError, sub: nil))
            warned = true
        }
        // A revoked permission is the one problem the user can actually fix
        // from here, so the warning comes with its door. Checked live on every
        // open — lastError may long predate or outlive the actual state.
        if Permissions.accessibility != .granted {
            menu.addItem(Self.banner(
                icon: "exclamationmark.triangle",
                title: L("Accessibility access is turned off"),
                sub: L("Dictation can hear you but cannot type. Re-enable it to continue.")))
            let fix = NSMenuItem(title: "", action: #selector(openAccessibilityPane),
                                 keyEquivalent: "")
            // The door row in the accent colour (design rowAccent) — the one
            // actionable line under the explanation.
            fix.attributedTitle = NSAttributedString(
                string: L("Open Privacy & Security…"),
                attributes: [.foregroundColor: NSColor.controlAccentColor,
                             .font: NSFont.menuFont(ofSize: 0)])
            fix.target = self
            menu.addItem(fix)
            warned = true
        }
        // Recording outranks recognizing in the glyph (one slot), so while
        // both are true the previous dictation looks dropped — this line says
        // it is not.
        let recognizing = dictation.recognizingCount
        if dictation.state == .recording, recognizing > 0 {
            menu.addItem(Self.label(recognizing == 1
                ? L("1 dictation still being recognized")
                : Lf("%d dictations still being recognized", recognizing)))
            warned = true
        }
        if warned { menu.addItem(.separator()) }

        // Meeting rows sit at the top with no header and no icons (design
        // 4a/4d): position is the emphasis, and the design's menu carries
        // meaning in words alone. The stop row shows the elapsed time — a
        // long recording must never be forgotten, and this menu is one of
        // the places someone comes to remember it.
        let recording = meetingActive()
        let record = NSMenuItem(
            title: "",
            action: #selector(meetingClicked), keyEquivalent: ""
        )
        if recording, let started = meetingStarted() {
            let s = max(0, Int(Date().timeIntervalSince(started)))
            let time = String(format: "%d:%02d", s / 60, s % 60)
            let title = NSMutableAttributedString(
                string: L("Stop Recording Meeting"),
                attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(
                string: "  " + time,
                attributes: [.font: NSFont.monospacedDigitSystemFont(
                                ofSize: NSFont.systemFontSize(for: .small), weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            record.attributedTitle = title
        } else {
            record.title = L("Start Recording Meeting")
        }
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
            // Bring It Back (design: hidden state) — only while the person
            // has hidden the floating timer by hand; the rest of the time the
            // row would name something already on screen.
            if pillHidden() {
                let back = NSMenuItem(title: L("Show Floating Timer"),
                                      action: #selector(showPillClicked), keyEquivalent: "")
                back.target = self
                menu.addItem(back)
            }
        }

        addMeetingsItem(to: menu)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("Keys")))

        // What each key does, spelled out (design 4a): the key drawn as a
        // keycap chip, the explanation beside it. These were once two rows at
        // the very TOP of the menu, holding its most valuable position while
        // being unclickable; under a heading, halfway down the menu, a second
        // line is cheap and a sentence is worth having.
        for (key, what) in dictationKeyRows() {
            menu.addItem(Self.viewItem(KeycapRow(key: key, what: what)))
        }

        // Safety net: recent results are recoverable even when a paste went
        // nowhere or the clipboard got overwritten. Inline rows under their
        // own header, "click to copy" spelled out at its right (design 4a) —
        // a submenu was tried and was a door nobody found.
        if !dictation.history.isEmpty {
            menu.addItem(.separator())
            menu.addItem(Self.viewItem(RecentHeaderRow()))
            for text in dictation.history.prefix(3) {
                let entry = NSMenuItem(title: Self.shortened(text),
                                       action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = text
                entry.toolTip = text
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())

        // The service group stays unlabelled — a heading over "Settings…" would
        // only name what the items already say. "Check for Updates…" is gone
        // from here: it now sits beside the version number in Settings.
        // Language packs live in System Settings (macOS owns them; GRABLI:
        // they cannot be deleted programmatically). This is the menu-bar twin
        // of the overlay's "translation data isn't downloaded" hint — the
        // overlay cannot be reached by keyboard, the menu always can.
        let packs = NSMenuItem(title: L("Language Packs…"),
                               action: #selector(openLanguagePacks), keyEquivalent: "")
        packs.target = self
        menu.addItem(packs)

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: L("About Dictate"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

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
        let item = NSMenuItem(title: L("Meetings & Agent…"),
                              action: #selector(showAllMeetings), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
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
    /// (keycap, what it does) pairs for the Keys section (design 4a): the key
    /// as a chip, the sentence beside it.
    private func dictationKeyRows() -> [(String, String)] {
        let spoken = Settings.shared.language
        let dictateKey = Self.keycap(from: KeyNames.displayName(Settings.shared.hotkeyName))
        // "" is Automatic (any language) — Whisper decides per dictation, so
        // there is no language to name and saying one would be a guess.
        var rows = [(dictateKey, spoken.isEmpty
            ? L("dictate in any language")
            : Lf("dictate in %@", LanguageList.name(for: spoken)))]

        guard let _ = Settings.shared.translateKeyCode else { return rows }
        let target = Settings.shared.translateTargetCode
        // Speaking the target language already: the runtime skips the
        // translation hop entirely in that case (there is no en→en), so the
        // second key does exactly what the first does and a line claiming a
        // translation would be a lie.
        guard spoken != target else { return rows }
        let translateKey = Self.keycap(from: KeyNames.displayName(Settings.shared.translateKeyName))
        rows.append((translateKey, spoken.isEmpty
            ? Lf("translate into %@", LanguageList.name(for: target))
            : Lf("translate %@ → %@",
                 LanguageList.name(for: spoken), LanguageList.name(for: target))))
        return rows
    }

    /// "Right Option (⌥)" → "⌥": the chip carries the symbol, the sentence
    /// carries the meaning. Keys without a symbol keep their name ("F5").
    private static func keycap(from displayName: String) -> String {
        if let open = displayName.lastIndex(of: "("),
           let close = displayName.lastIndex(of: ")"), open < close {
            let symbol = displayName[displayName.index(after: open)..<close]
            if !symbol.isEmpty { return String(symbol) }
        }
        return displayName
    }

    /// A static, full-custom menu row (banners, keycap rows, headers) — the
    /// hosting view is sized to fit so the menu takes its width.
    private static func viewItem<V: View>(_ view: V) -> NSMenuItem {
        let item = NSMenuItem()
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        item.view = host
        return item
    }

    /// A two-line warning banner (design 4b/4c): icon, bold state, quiet cure.
    private static func banner(icon: String, title: String, sub: String?) -> NSMenuItem {
        viewItem(MenuBannerRow(icon: icon, title: title, sub: sub))
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

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func settingsClicked() {
        openSettings()
    }

    @objc private func openAccessibilityPane() {
        Permissions.openSettingsPane("Privacy_Accessibility")
    }

    @objc private func openLanguagePacks() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
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

    @objc private func showPillClicked() {
        showPill()
    }

    // Screenshot harness (design pass): open/close the menu without a mouse.
    func debugOpenMenu() { item.button?.performClick(nil) }
    func debugCloseMenu() { item.menu?.cancelTracking() }

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

// MARK: - Custom menu rows (design 4a–4d)

/// A two-line warning banner at the top of the menu: icon, bold state line,
/// quiet explanation. Static — it explains; the actionable row follows it.
private struct MenuBannerRow: View {
    let icon: String
    let title: String
    let sub: String?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(DS.warn)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let sub {
                    Text(sub)
                        .font(DS.helpText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 300, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

/// One Keys row: the key as a keycap chip, what it does beside it.
private struct KeycapRow: View {
    let key: String
    let what: String

    var body: some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 26, minHeight: 17)
                .background(RoundedRectangle(cornerRadius: DS.radiusChip)
                    .fill(.quaternary.opacity(0.6)))
            Text(what)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(width: 300, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

/// The Recent dictations header: the label at the left, the affordance —
/// "click to copy" — spelled out at the right, where a submenu used to hide it.
private struct RecentHeaderRow: View {
    var body: some View {
        HStack {
            Text(L("Recent dictations"))
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            Text(L("click to copy"))
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .frame(width: 300)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}
