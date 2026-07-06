import AppKit
import Combine

/// Captures the next key press inside the app window (local monitor,
/// no permissions needed) — for picking the hotkey in onboarding and settings.
final class KeyCapture: ObservableObject {
    @Published var capturing = false
    @Published var capturedKeyCode: Int?
    @Published var capturedName: String?

    private var monitor: Any?
    private var lastFlags = NSEvent.ModifierFlags()

    func begin() {
        end()
        capturedKeyCode = nil
        capturedName = nil
        capturing = true
        lastFlags = NSEvent.ModifierFlags()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.capturing else { return event }
            let code = Int(event.keyCode)

            // Return/Enter/Space just activated the "Assign" button —
            // don't capture that press as the hotkey.
            if event.type == .keyDown, code == 36 || code == 76 || code == 49 {
                return nil
            }

            if event.type == .flagsChanged {
                // React only to a modifier press (more flags than before);
                // 0xFFFF0000 = device-independent modifier flags
                let now = NSEvent.ModifierFlags(rawValue: event.modifierFlags.rawValue & 0xFFFF0000)
                let wasPress = !now.subtracting(self.lastFlags).isEmpty
                self.lastFlags = now
                guard wasPress else { return event }
                self.finish(code: code, event: event)
                return nil
            }

            if code == 53 { // Escape
                self.cancel()
                return nil
            }
            self.finish(code: code, event: event)
            return nil
        }
    }

    func cancel() {
        capturing = false
        end()
    }

    private func finish(code: Int, event: NSEvent) {
        // Name BEFORE keycode: onReceive observes $capturedKeyCode and fires
        // as soon as it is set — the name must already be ready by then.
        capturedName = KeyNames.baseName(forKeyCode: code, event: event.type == .keyDown ? event : nil)
        capturing = false
        end()
        capturedKeyCode = code
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
