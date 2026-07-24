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

    /// Whether the tap exists and the system still delivers events to it.
    /// Revoking Accessibility kills delivery without any notification — a
    /// periodic isAlive check is the only way to notice and recreate the tap.
    var isAlive: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // Our own live typing comes back through this tap (it is a real keyboard
        // event as far as the system is concerned). It is marked with a magic
        // location — never treat it as something the user pressed.
        if event.location == TypeInjector.syntheticEventLocation { return }

        // The system disables the tap on timeout — re-enable it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events during the disabled window are gone. A missed keyUp would
            // leave the recording running to the 300 s limit and eat the next
            // press — re-sync held state from the hardware instead.
            for code in pressedCodes
            where !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) {
                setPressed(code, false)
            }
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
        // The shared masks (.maskAlternate…) cover BOTH keys of a pair: with
        // left and right Option held together, releasing one keeps the flag set
        // and the release would be lost (the code sticks in pressedCodes, the
        // next press is eaten). The NX_DEVICE* bits in the low word tell the
        // sides apart; some external/remapped keyboards set neither, so the
        // shared flag alone is the fallback.
        let general: CGEventFlags
        let deviceBit: UInt64
        let siblingBit: UInt64
        switch keyCode {
        case 58: (general, deviceBit, siblingBit) = (.maskAlternate, 0x20, 0x40)     // left ⌥
        case 61: (general, deviceBit, siblingBit) = (.maskAlternate, 0x40, 0x20)     // right ⌥
        case 55: (general, deviceBit, siblingBit) = (.maskCommand, 0x08, 0x10)       // left ⌘
        case 54: (general, deviceBit, siblingBit) = (.maskCommand, 0x10, 0x08)       // right ⌘
        case 56: (general, deviceBit, siblingBit) = (.maskShift, 0x02, 0x04)         // left ⇧
        case 60: (general, deviceBit, siblingBit) = (.maskShift, 0x04, 0x02)         // right ⇧
        case 59: (general, deviceBit, siblingBit) = (.maskControl, 0x01, 0x2000)     // left ⌃
        case 62: (general, deviceBit, siblingBit) = (.maskControl, 0x2000, 0x01)     // right ⌃
        case 63: return flags.contains(.maskSecondaryFn)
        case 57: return flags.contains(.maskAlphaShift)
        default: return false
        }
        guard flags.contains(general) else { return false }
        let raw = flags.rawValue
        if raw & (deviceBit | siblingBit) == 0 { return true }   // no device bits — trust the shared flag
        return raw & deviceBit != 0
    }
}
