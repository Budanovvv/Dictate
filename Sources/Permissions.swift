import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid

/// Checks and requests the three macOS permissions dictation can't work without.
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

    // MARK: Input Monitoring (global key capture)

    static var inputMonitoring: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeUnknown: return .undetermined
        default: return .denied
        }
    }

    /// Shows the TCC dialog and adds the app to the Input Monitoring list.
    static func promptInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
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
