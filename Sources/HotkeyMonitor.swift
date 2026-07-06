import AppKit
import CoreGraphics

/// Global key capture via CGEventTap; needs the Input Monitoring permission.
/// Modifier keys arrive as flagsChanged, regular keys as keyDown/keyUp.
/// Callbacks receive the triggering keycode (main key vs translate key).
final class HotkeyMonitor {
    /// Tracked keycodes (main key + optional translate key).
    var keyCodes: Set<Int64> = [61]
    var onPress: ((Int64) -> Void)?
    var onRelease: ((Int64) -> Void)?
    var onEsc: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressedCodes: Set<Int64> = []

    /// true if the event tap was created successfully.
    @discardableResult
    func start() -> Bool {
        stop()
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        pressedCodes = []
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables the tap on timeout — re-enable it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, code == 53 {
            DispatchQueue.main.async { [weak self] in self?.onEsc?() }
            return
        }
        guard keyCodes.contains(code) else { return }

        switch type {
        case .keyDown:
            setPressed(code, true)
        case .keyUp:
            setPressed(code, false)
        case .flagsChanged:
            // For a modifier: flag set → held, cleared → released
            setPressed(code, isModifierFlagActive(event.flags, keyCode: code))
        default:
            break
        }
    }

    private func setPressed(_ code: Int64, _ now: Bool) {
        let was = pressedCodes.contains(code)
        guard now != was else { return }
        if now { pressedCodes.insert(code) } else { pressedCodes.remove(code) }
        let cb = now ? onPress : onRelease
        DispatchQueue.main.async { cb?(code) }
    }

    private func isModifierFlagActive(_ flags: CGEventFlags, keyCode: Int64) -> Bool {
        switch keyCode {
        case 58, 61: return flags.contains(.maskAlternate)
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 59, 62: return flags.contains(.maskControl)
        case 63: return flags.contains(.maskSecondaryFn)
        case 57: return flags.contains(.maskAlphaShift)
        default: return false
        }
    }
}
