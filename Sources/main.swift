import AppKit

// Single instance: if another copy is running (same bundle id, or another
// build of Dictate.app), activate it and exit.
let myPID = ProcessInfo.processInfo.processIdentifier
let myBundleID = Bundle.main.bundleIdentifier
let info = Bundle.main.infoDictionary
Log.d("launch v\(info?["CFBundleShortVersionString"] ?? "?")(\(info?["CFBundleVersion"] ?? "?")) pid=\(myPID) path=\(Bundle.main.bundleURL.path)")
let already = NSWorkspace.shared.runningApplications.filter {
    $0.processIdentifier != myPID
        && ((myBundleID != nil && $0.bundleIdentifier == myBundleID)
            || $0.bundleURL?.lastPathComponent == "Dictate.app")
}
if let other = already.first {
    // The installed copy is canonical: when it launches while a dev/test copy
    // (build cache, DMG…) is running, the impostor is asked to quit and THIS
    // instance keeps going. Otherwise a stale test instance silently swallows
    // the launch — "the app doesn't react" with no crash and exit 0.
    let iAmCanonical = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    let otherIsCanonical = other.bundleURL?.path.hasPrefix("/Applications/") ?? false
    if iAmCanonical && !otherIsCanonical {
        NSLog("Dictate: taking over from non-canonical instance pid=%d path=%@",
              other.processIdentifier, other.bundleURL?.path ?? "nil")
        other.terminate()
    } else {
        NSLog("Dictate: exiting, another instance found: pid=%d bundle=%@ name=%@ path=%@",
              other.processIdentifier, other.bundleIdentifier ?? "nil",
              other.localizedName ?? "nil", other.bundleURL?.path ?? "nil")
        other.activate(options: [])
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// The Dock policy must be RIGHT from the first moment, not fixed up later:
// launching as .accessory and promoting to .regular in didFinishLaunching
// registers as Foreground but never materializes a Dock tile (reproduced
// 2026-08-28 — "Foreground" in lsappinfo, no icon in the Dock). Show in
// Dock is the default; the setting keeps the old menu-bar-only behaviour.
app.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
// The chosen appearance, from the very first frame — every window, the
// dictation overlay, the recording pill and the menu inherit NSApp's.
switch Settings.shared.appearance {
case "light": app.appearance = NSAppearance(named: .aqua)
case "dark": app.appearance = NSAppearance(named: .darkAqua)
default: break
}

// Without a main menu, Cmd+C/V/X/A don't work in an accessory app's own text fields.
let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
// Undo/Redo have no NSText selector — they reach the field's undo manager
// through the responder chain by selector name.
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(redoItem)
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu

app.run()
