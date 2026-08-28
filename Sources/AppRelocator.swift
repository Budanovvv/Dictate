import AppKit

/// Moves a translocated app into /Applications instead of only warning about
/// it (the LetsMove pattern). Translocation means macOS is running a random
/// read-only copy: TCC grants die with it and the model would re-download on
/// every launch, so "warn and hope" loses to "offer to fix it in one click".
enum AppRelocator {
    static let destination = URL(fileURLWithPath: "/Applications/Dictate.app")

    /// Shown at launch when the app runs from its disk image (translocated).
    /// Returns without side effects otherwise. On "Move" the app copies
    /// itself, launches the installed copy and quits; on "Quit" it just quits
    /// — running on from a translocated path only manufactures the broken
    /// permission states GRABLI documents.
    static func offerMoveIfTranslocated() {
        guard Permissions.isTranslocated else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Dictate is running from its disk image")
        alert.informativeText = L("Permissions granted from a disk image are lost as soon as it is ejected, and the model would download again every time. Move Dictate to your Applications folder first.")
        alert.addButton(withTitle: L("Move to Applications"))
        alert.addButton(withTitle: L("Quit"))
        if alert.runModal() == .alertFirstButtonReturn, move() {
            relaunchInstalledCopyAndQuit()
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Copies the running bundle to /Applications. The translocated mount is a
    /// faithful read-only copy, so copying FROM it is fine — resolving the
    /// pre-translocation original would need Security SPI for no gain.
    private static func move() -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
            // Strip quarantine so the installed copy opens without the
            // Gatekeeper right-click dance the DMG already went through.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            p.arguments = ["-dr", "com.apple.quarantine", destination.path]
            try? p.run()
            p.waitUntilExit()
            Log.d("relocate: copied to /Applications")
            return true
        } catch {
            Log.d("relocate: move failed: \(error.localizedDescription)")
            // Fall back to the manual gesture: reveal the destination so the
            // user can drag the icon themselves.
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            let fail = NSAlert()
            fail.alertStyle = .warning
            fail.messageText = L("Couldn't move Dictate automatically")
            fail.informativeText = L("Drag Dictate from the disk image into the Applications folder, then launch it from there.")
            fail.addButton(withTitle: L("OK"))
            fail.runModal()
            return false
        }
    }

    /// The single-instance guard kills a SECOND copy, so the order matters:
    /// spawn a detached `open` that fires after this process is gone, then
    /// terminate.
    private static func relaunchInstalledCopyAndQuit() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(destination.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
