import AppKit
import SwiftUI

/// Moves a translocated app into /Applications instead of only warning about
/// it (the LetsMove pattern). Translocation means macOS is running a random
/// read-only copy: TCC grants die with it and the model would re-download on
/// every launch, so "warn and hope" loses to "offer to fix it in one click".
@MainActor
enum AppRelocator {
    static let destination = URL(fileURLWithPath: "/Applications/Dictate.app")

    /// Shown at launch when the app runs from its disk image (translocated).
    /// Returns without side effects otherwise. On "Move" the app copies
    /// itself, launches the installed copy and quits; on "Quit" it just quits
    /// — running on from a translocated path only manufactures the broken
    /// permission states GRABLI documents.
    static func offerMoveIfTranslocated() {
        guard Permissions.isTranslocated else { return }
        NSApp.activate()
        // The app's own dialog vocabulary (design Onboarding: dmg), not
        // NSAlert's — this window is the first thing a new user ever sees.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 10),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // First-run surface, same rule as onboarding: light by default.
        panel.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: RelocateCard(
            quit: { NSApp.stopModal(withCode: .cancel) },
            moveNow: { NSApp.stopModal(withCode: .OK) }))
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        // Forced visible before the modal loop, same as ConsentDialog: a
        // first launch from the DMG may run modal before activation has
        // settled, and an invisible relocation dialog is a frozen app.
        panel.level = .modalPanel
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        if response == .OK, move() {
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

/// The design's dmg screen, as a dialog: the warning and its reason, the
/// "Dictate.dmg → Applications" picture of what will happen, and the two
/// ways out. Return moves, Esc quits.
private struct RelocateCard: View {
    let quit: () -> Void
    let moveNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 17))
                        .foregroundStyle(DS.warn)
                    Text(L("Dictate is running from its disk image"))
                        .font(.system(size: 20, weight: .semibold))
                        .kerning(-0.4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("Permissions granted from a disk image are lost as soon as it is ejected, and the model would download again every time. Move Dictate to your Applications folder first."))
                    .font(.system(size: 13.5))
                    .lineSpacing(13.5 * 0.28)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Text(verbatim: "Dictate.dmg")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(L("Applications"))
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(.quaternary.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5))
                .padding(.top, 8)
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 20, trailing: 24))
            Divider()
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(L("Quit"), action: quit)
                    .buttonStyle(.dsRegular)
                    .keyboardShortcut(.cancelAction)
                Button(L("Move to Applications"), action: moveNow)
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
        }
        .frame(width: 560)
    }
}
