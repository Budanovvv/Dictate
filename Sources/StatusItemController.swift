import AppKit
import Carbon.HIToolbox

/// The menu bar icon and its menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let dictation: DictationController
    private let openSettings: () -> Void
    private let checkForUpdates: () -> Void
    private var lastError: String?

    init(dictation: DictationController,
         openSettings: @escaping () -> Void,
         checkForUpdates: @escaping () -> Void) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.dictation = dictation
        self.openSettings = openSettings
        self.checkForUpdates = checkForUpdates
        super.init()

        item.button?.toolTip = L("Dictate — voice dictation")
        item.isVisible = true
        updateIcon(for: .idle)

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func applyState(_ state: DictationController.State) {
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

    private func updateIcon(for state: DictationController.State) {
        guard let button = item.button else { return }
        switch state {
        case .idle:
            // Monochrome template per HIG — adapts to the menu bar theme.
            button.image = dictation.paused
                ? coloredSymbol("mic.slash.fill", color: .systemGray)
                : Self.waveIcon
        case .recording:
            button.image = coloredSymbol("mic.fill", color: .systemRed)
        case .transcribing:
            button.image = coloredSymbol("ellipsis.circle.fill", color: .systemOrange)
        }
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
    private static let waveIcon: NSImage = {
        let s: CGFloat = 18
        let image = NSImage(size: NSSize(width: s, height: s))
        image.lockFocus()
        NSColor.black.setFill()
        let heights: [CGFloat] = [0.36, 0.64, 1.0, 0.64, 0.36]
        let barW: CGFloat = 2.4
        let gap: CGFloat = 3.5
        let startX = (s - (CGFloat(heights.count - 1) * gap + barW)) / 2
        for (i, hf) in heights.enumerated() {
            let h = s * 0.80 * hf
            let r = NSRect(x: startX + CGFloat(i) * gap, y: (s - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()

    // Rebuilt on every open so the items reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(
            title: Lf("Hotkey: %@", KeyNames.displayName(Settings.shared.hotkeyName)),
            action: nil, keyEquivalent: ""
        )
        title.isEnabled = false
        menu.addItem(title)

        if Settings.shared.translateKeyCode != nil {
            let tr = NSMenuItem(
                title: Lf("Translate key: %@", KeyNames.displayName(Settings.shared.translateKeyName)),
                action: nil, keyEquivalent: ""
            )
            tr.isEnabled = false
            menu.addItem(tr)
        }

        if let result = dictation.lastResult, !result.isEmpty {
            let preview = result.count > 60 ? String(result.prefix(60)) + "…" : result
            let last = NSMenuItem(title: Lf("Last: %@", preview), action: nil, keyEquivalent: "")
            last.isEnabled = false
            menu.addItem(last)
        }
        if let lastError {
            let err = NSMenuItem(title: "⚠️ \(lastError)", action: nil, keyEquivalent: "")
            err.isEnabled = false
            menu.addItem(err)
        }

        // Secure Keyboard Entry (password fields, Terminal option) blocks key capture system-wide.
        if IsSecureEventInputEnabled() {
            let sec = NSMenuItem(
                title: "⚠️ " + L("Secure input is on (password field?) — the hotkey won't work for now"),
                action: nil, keyEquivalent: ""
            )
            sec.isEnabled = false
            menu.addItem(sec)
        }

        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: dictation.paused ? L("Resume dictation") : L("Pause dictation"),
            action: #selector(togglePause), keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(title: L("Check for Updates…"), action: #selector(updatesClicked), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        let about = NSMenuItem(title: L("About Dictate"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("Quit Dictate"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func togglePause() {
        dictation.paused.toggle()
        updateIcon(for: dictation.state)
    }

    @objc private func settingsClicked() {
        openSettings()
    }

    @objc private func updatesClicked() {
        checkForUpdates()
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
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
