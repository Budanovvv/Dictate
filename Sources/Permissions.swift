import AppKit
import ApplicationServices
import AVFoundation

/// Checks and requests the macOS permissions dictation can't work without.
enum Permissions {
    enum Status {
        case granted, denied, undetermined
    }

    // MARK: Microphone

    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    static func requestMicrophoneIfNeeded(_ completion: @escaping (Bool) -> Void) {
        switch microphone {
        case .granted:
            completion(true)
        case .undetermined:
            requestMicrophone(completion)
        case .denied:
            openSettingsPane("Privacy_Microphone")
            completion(false)
        }
    }

    // MARK: Accessibility (simulated Cmd+V)

    static var accessibility: Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Shows the TCC dialog and adds the app to the Accessibility list.
    /// Don't open System Settings ourselves: the dialog's own button does that
    /// and dismisses it; opening manually leaves the dialog hanging on "Deny".
    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func promptAccessibilityIfNeeded() {
        guard accessibility != .granted else { return }
        promptAccessibility()
    }

    /// Registers the app in the Accessibility list without showing a dialog.
    static func registerAccessibilityQuietly() {
        _ = AXIsProcessTrusted()
    }

    /// The app is running from macOS App Translocation (launched straight from
    /// the DMG or a quarantined Downloads copy): the process lives at a random
    /// read-only path, so TCC grants land on a copy that won't exist next
    /// launch — the permissions step can never go green. Detected precisely by
    /// the path marker; dev builds and normal installs never match.
    static var isTranslocated: Bool {
        DictationPolicy.isTranslocatedPath(Bundle.main.bundlePath)
    }

    /// Clears this app's own Accessibility record via `tccutil` — the one
    /// sanctioned escape from the stale-entry dead end (switch ON in System
    /// Settings yet "not trusted" here, or an old Deny suppressing the prompt).
    /// Needs no admin rights for our own bundle id; verified to reach tccd from
    /// a hardened-runtime app. After the reset the fresh system prompt fires.
    static func resetAccessibility() {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility",
                           Bundle.main.bundleIdentifier ?? "com.valentynbudanov.Dictate"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do {
                try p.run()
                p.waitUntilExit()
                let msg = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                // exit 64 ("No such bundle identifier") just means no record
                // existed — harmless, the prompt below still re-registers us.
                Log.d("permissions: tccutil reset exit=\(p.terminationStatus) \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch {
                Log.d("permissions: tccutil spawn failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { promptAccessibility() }
        }
    }

    // MARK: Opening the relevant System Settings pane

    static func openSettingsPane(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    /// Microphone + Accessibility. Input Monitoring isn't checked separately:
    /// Accessibility already grants keyboard listening (enough for an event tap),
    /// and on failure the tap retries every 3 s anyway.
    static var allGranted: Bool {
        microphone == .granted && accessibility == .granted
    }
}
