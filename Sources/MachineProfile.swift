import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What this Mac is, asked once and answered everywhere.
///
/// One source of truth for every hardware-dependent decision in the app —
/// which model may be offered, how the helper is configured, what the copy
/// says on This Mac — so two surfaces can never disagree about the machine
/// they are running on. Before this existed the memory floor lived in
/// LocalTextEngine, the chip test lived beside it, Whisper had no gate at
/// all, and nothing wrote the configuration down: a MacBook M2 with 8 GB
/// froze solid under a 2.5 GB model (2026-09-13) and the log could not even
/// say how much memory the machine had.
///
/// A plain value, deliberately: every gate is a pure function of a profile,
/// so the tests hand in an 8 GB M2 or a 16 GB Intel without touching a
/// mutable static — and the app hands in `current`.
struct MachineProfile: Sendable {
    /// `hw.model`, e.g. "Mac14,2".
    let modelIdentifier: String
    /// `machdep.cpu.brand_string`, e.g. "Apple M2" — for the log and the
    /// This Mac header, never for a threshold.
    let chipName: String
    /// The one chip fact a threshold is derived from: Metal or no Metal.
    let isAppleSilicon: Bool
    /// Physical memory in bytes. Apple sells this in binary gigabytes: an
    /// "8 GB" Mac reports exactly 8 GiB.
    let memoryBytes: Int64
    let macOSVersion: OperatingSystemVersion

    /// The Neural Engine ships with every Apple Silicon Mac and with no Intel
    /// one — the answer for Whisper's compute path.
    var hasNeuralEngine: Bool { isAppleSilicon }

    /// Memory as the person knows it: "8", "16", "48".
    var memoryGB: Int { Int(memoryBytes >> 30) }

    /// "Apple M2 · 8 GB · macOS 26.1", for the This Mac header.
    var headline: String {
        "\(chipName) · \(Self.memoryText(memoryBytes)) · macOS \(macOSText)"
    }

    var macOSText: String {
        let v = macOSVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                                  : "\(v.majorVersion).\(v.minorVersion)"
    }

    /// The first line the log should carry after the watchdog's, so a log
    /// from somebody else's Mac says what Mac it came from.
    var logLine: String {
        "machine: \(modelIdentifier) · \(chipName) · \(Self.memoryText(memoryBytes)) · macOS \(macOSText) · \(isAppleSilicon ? "arm64" : "x86_64")"
    }

    /// The Mac this process runs on. Read once: none of it changes while the
    /// app is running, and a `let` needs no isolation.
    static let current: MachineProfile = {
        MachineProfile(
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Unknown chip",
            isAppleSilicon: sysctlInt32("hw.optional.arm64") == 1,
            memoryBytes: overriddenMemory ?? Int64(ProcessInfo.processInfo.physicalMemory),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }()

    // MARK: - Memory as text

    /// Binary gigabytes, the way Apple labels memory: 8 GiB → "8 GB".
    static func memoryText(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB]
        f.zeroPadsFractionDigits = false
        return f.string(fromByteCount: bytes)
    }

    /// Decimal gigabytes, the way Finder labels files: 2 497 281 120 → "2.5 GB".
    static func fileSizeText(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }

    // MARK: - Live memory

    /// How much memory a new process could take before the machine starts
    /// paying for it — the number Activity Monitor calls "Memory Used",
    /// subtracted from the physical total.
    ///
    /// NOT free + inactive + speculative: that counts dirty inactive pages as
    /// available, which they are only after being compressed or swapped, and
    /// on the owner's M4 Pro it overstated the headroom by about 30 %. Used
    /// memory is app memory (internal minus purgeable) plus wired plus the
    /// compressor's own footprint; the file cache is deliberately not counted
    /// on either side.
    static func memoryHeadroom() -> Int64 {
        if let forced = overriddenHeadroom { return forced }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Int64(ProcessInfo.processInfo.physicalMemory) / 2 }
        let page = Int64(vm_kernel_page_size)
        let usedPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
            + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        let used = max(0, usedPages) * page
        return max(0, Int64(ProcessInfo.processInfo.physicalMemory) - used)
    }

    /// The kernel's own memory-pressure verdict: 1 normal, 2 warning,
    /// 4 critical — the same levels DispatchSource delivers on the way UP,
    /// readable at any time (which the source is not: it never announces a
    /// return to normal).
    static func memoryPressureLevel() -> Int {
        if overriddenHeadroom != nil { return 1 }
        return Int(sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)
    }

    // MARK: - Test and demo overrides

    /// `defaults write com.valentynbudanov.Dictate debugPhysicalMemoryGB 8`
    /// makes a 48 GB Mac gate itself like an 8 GB one for the length of the
    /// run — the only way to photograph and verify the small-Mac states on
    /// the machine the app is developed on.
    static var overriddenMemory: Int64? {
        let gb = UserDefaults.standard.integer(forKey: "debugPhysicalMemoryGB")
        return gb > 0 ? Int64(gb) << 30 : nil
    }

    /// `defaults write … debugMemoryHeadroomGB 2` starves the helper's
    /// pre-flight check without starving the Mac.
    static var overriddenHeadroom: Int64? {
        let gb = UserDefaults.standard.double(forKey: "debugMemoryHeadroomGB")
        return gb > 0 ? Int64(gb * Double(1 << 30)) : nil
    }

    // MARK: - sysctl

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// What a capability can do on a given Mac — the one answer every surface
/// renders. Three cases, because three is what people can act on: it
/// works, it works and here is what it costs, or it does not and here is
/// why and what does instead.
enum HardwareVerdict: Sendable, Equatable {
    case available
    /// Works, with a sentence the person should read first.
    case availableWithCost(String)
    /// Does not work here. `reason` is the hardware fact; `instead` names
    /// what still does — an absence with nothing after it reads as a wall.
    case unavailable(reason: String, instead: String)

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// The cost or the reason, whichever applies; nil when there is nothing
    /// to say.
    var note: String? {
        switch self {
        case .available: return nil
        case .availableWithCost(let cost): return cost
        case .unavailable(let reason, _): return reason
        }
    }
}

/// Apple Intelligence's standing on this Mac, as the system reports it.
/// Five states rather than on/off because the copy differs for each — "turn
/// it on" is only true for one of them.
enum AppleIntelligenceState: Sendable, Equatable {
    /// macOS before 26: the framework is not there.
    case unavailableOS
    /// The Mac, region or language is not eligible.
    case notEligible
    /// Eligible, switched off in System Settings.
    case notEnabled
    /// Switched on; macOS is still downloading its model assets.
    case notReady
    case on

    var isOn: Bool { self == .on }
}
