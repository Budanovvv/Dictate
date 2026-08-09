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
            // Every disable is a window where a release can be lost (seen live
            // 2026-08-06: a stuck 42 s recording) — leave a trace so the next
            // stuck-key report is diagnosable from the log.
            Log.d("tap: disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") -> re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events during the disabled window are gone. A missed keyUp would
            // leave the recording running to the 300 s limit and eat the next
            // press — re-sync held state from the hardware instead. Modifiers
            // are skipped while the flags state is clobbered by a synthetic
            // paste: the resync would read a held key as up and force a fake
            // release (same trap as the lost-release watchdog).
            for code in pressedCodes {
                if Self.isModifierCode(code), !Self.modifierStateTrustworthy {
                    Log.d("tap: resync skipped for key \(code) — flags state clobbered by a recent paste")
                    continue
                }
                if !Self.isKeyPhysicallyDown(code) {
                    Log.d("tap: resync — key \(code) is physically up, forcing release")
                    setPressed(code, false)
                }
            }
            return
        }

        // Any REAL flagsChanged (hardware modifiers; our synthetic ⌘V arrives
        // as keyDown/keyUp) refreshes the session flags state and makes it
        // trustworthy again after a paste clobbered it — timestamp them all,
        // not just the hotkey's.
        if type == .flagsChanged { Self.lastRealFlagsEventAt = Date() }

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
            setPressed(code, Self.isModifierFlagActive(event.flags, keyCode: code))
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

    /// Physical "is this key held right now", readable without a tap. CRITICAL:
    /// `CGEventSource.keyState` does NOT track modifier keys — they live in the
    /// flags state, not the key table, and keyState returns false for a
    /// physically held Option/Command (measured live 2026-08-06: the first
    /// lost-release watchdog cut every recording at 2 s because of exactly
    /// this). Modifiers must be read via flagsState + the same per-side bit
    /// logic the tap uses; keyState is correct only for regular keys.
    static func isKeyPhysicallyDown(_ code: Int64) -> Bool {
        switch code {
        case 54...63:   // both ⌘⌥⇧⌃ sides, caps lock, fn
            return isModifierFlagActive(CGEventSource.flagsState(.combinedSessionState), keyCode: code)
        default:
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
    }

    static func isModifierCode(_ code: Int64) -> Bool { (54...63).contains(code) }

    /// Last REAL flagsChanged seen by the tap. Together with the paster's
    /// timestamp this says whether flagsState currently reflects the physical
    /// keyboard — a synthetic ⌘V rewrites it (see Paster.lastSyntheticPasteAt)
    /// and only the next real flags event repairs it.
    fileprivate(set) static var lastRealFlagsEventAt = Date.distantPast

    /// False from the moment a synthetic paste clobbers the session flags
    /// state until the next real flagsChanged repairs it. While false,
    /// isKeyPhysicallyDown is meaningless for modifier codes.
    static var modifierStateTrustworthy: Bool {
        DictationPolicy.modifierStateTrustworthy(
            lastRealFlagsEvent: lastRealFlagsEventAt,
            lastSyntheticPaste: Paster.lastSyntheticPasteAt)
    }

    private static func isModifierFlagActive(_ flags: CGEventFlags, keyCode: Int64) -> Bool {
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
