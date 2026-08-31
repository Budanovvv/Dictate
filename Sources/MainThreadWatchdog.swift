import AppKit
import Foundation

/// Catches a wedged main thread and captures evidence.
///
/// The main thread can freeze inside a CoreAnimation transaction commit that
/// blocks on the WindowServer (observed 2026-07-13: a ~19-hour-old session was
/// stuck in `CA::Transaction::commit → mach_msg`, hotkey and menu bar both
/// dead). That freeze is SILENT — nothing gets logged because nothing runs, so
/// the only symptom is the app going unresponsive until it's killed by hand.
///
/// This watchdog turns that into evidence. A background timer asks the main
/// thread to stamp a heartbeat every 2s; if the main thread hasn't answered for
/// `threshold` seconds it is wedged, and we record it:
///   1. a one-line entry in ~/Library/Logs/Dictate/hangs.log — always written
///      (plain file I/O), so we get the frequency and timing of hangs no matter
///      what;
///   2. a full `/usr/bin/sample` of the process to hang-<timestamp>.txt — the
///      deep call graph, best-effort (needs task_for_pid; logged if it fails).
///
/// Runs unconditionally, NOT behind the debugLog flag: a hang is exactly the
/// thing the user would otherwise only notice by the app being dead. It does
/// not touch the app's behaviour — it only observes and writes diagnostics.
///
/// Transcription and audio run off the main thread (Task/async, the recorder's
/// ioQueue), so the main thread never legitimately blocks for `threshold`
/// seconds — a trip means a real wedge, not a slow operation.
///
/// `@unchecked Sendable` backed by real synchronization: lastBeat/lastTick sit
/// behind `lock`; timer is written once in start() before the first tick can
/// race it, and `captured` is confined to the watchdog queue (tick only).
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "com.valentynbudanov.Dictate.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    /// Monotonic timestamps (`systemUptime` = mach_absolute_time), NOT wall clock:
    /// system sleep freezes the whole process, so `Date()` would advance by the
    /// full sleep duration while the timer sat suspended — every wake would then
    /// look like a multi-minute "wedge" (confirmed against pmset: each false hang
    /// matched the preceding Maintenance Sleep to the second). systemUptime does
    /// not tick during sleep, so sleeping adds ~0 to the measured age; a genuine
    /// main-thread block (process running, main stuck) still advances it.
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    /// When the watchdog tick itself last ran. If two ticks are separated by far
    /// more than the 2s schedule, the timer was suspended (sleep/app-nap) — this
    /// tick woke into a stale world and must not judge the gap as a hang.
    private var lastTick = ProcessInfo.processInfo.systemUptime
    /// Seconds the main thread may be unresponsive before it's called wedged.
    private let threshold: TimeInterval = 15
    /// A tick gap beyond this means the timer was suspended, not merely late.
    private let sleepGap: TimeInterval = 8
    /// Set once per continuous hang so we capture one sample, not one every tick.
    private var captured = false

    private init() {}

    func start() {
        beat()   // seed before the first check
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        Log.d("watchdog: started (threshold \(Int(threshold))s)")
    }

    /// Runs on the watchdog queue every 2s.
    private func tick() {
        // Queue a heartbeat behind whatever the main thread is doing. If main is
        // wedged this block never runs, so lastBeat goes stale.
        DispatchQueue.main.async { [weak self] in self?.beat() }

        let nowUptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let sinceTick = nowUptime - lastTick
        lastTick = nowUptime
        let age = nowUptime - lastBeat
        lock.unlock()

        // The timer skipped its own cadence by a wide margin -> the process was
        // suspended (system sleep / app nap), not hung. systemUptime already
        // excludes sleep, so `age` shouldn't spike, but a wake also hasn't let
        // the pending heartbeat run yet; treat this tick as a fresh start.
        if sinceTick >= sleepGap {
            beat()             // re-seed so the post-wake main thread isn't judged
            captured = false
            Log.d("watchdog: tick gap \(Int(sinceTick))s (process was suspended) -> re-armed")
            return
        }

        if age >= threshold {
            if !captured {
                captured = true
                // Rescue BEFORE the sample: the sample takes 5+ seconds and
                // the rescue is the one act that can end the hang.
                rescueInvisibleModal()
                capture(stuckFor: age)
                // The sample itself blocked this queue for seconds — without
                // a fresh stamp the next tick reads that as a sleep gap,
                // re-arms, and samples the same continuing hang again.
                lock.lock()
                lastTick = ProcessInfo.processInfo.systemUptime
                lock.unlock()
            }
        } else {
            captured = false   // main answered again — re-arm for the next hang
        }
    }

    /// The one kind of wedge that can be UNDONE: a modal window running its
    /// loop behind another app's windows. The app is a non-activating panel
    /// most of the time, macOS's cooperative activation quietly refuses our
    /// activate calls, and a modal shown in that state (Sparkle's "You're up
    /// to date", three times on 2026-08-31) opens invisible — the loop then
    /// reads as a hang. The main dispatch QUEUE is stuck mid-drain, but the
    /// modal RUNLOOP still spins — a runloop-based perform in common modes
    /// gets serviced where a dispatch_async never would.
    private func rescueInvisibleModal() {
        // CFRunLoopPerformBlock + explicit wake, not RunLoop.perform:
        // RunLoop is documented non-thread-safe, and a loop asleep in
        // mach_msg needs the wake-up call or the block sits unserviced.
        CFRunLoopPerformBlock(CFRunLoopGetMain(),
                              [RunLoop.Mode.common.rawValue as CFString,
                               RunLoop.Mode.modalPanel.rawValue as CFString] as CFArray) {
            // Performed BY the main runloop — this block runs on the main
            // thread by construction, whatever queue scheduled it.
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow else { return }
                Log.d("watchdog: modal rescue — forcing \"\(modal.title)\" front")
                // Set, not insert: moveToActiveSpace is documented mutually
                // exclusive with canJoinAllSpaces, and the window may carry it.
                modal.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                modal.level = .modalPanel
                modal.orderFrontRegardless()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func beat() {
        lock.lock()
        lastBeat = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func capture(stuckFor age: TimeInterval) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Dictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = Date()
        let stamp = Self.fileStamp.string(from: now)
        let pid = ProcessInfo.processInfo.processIdentifier
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"

        // 1) Always-on tally — plain append, no external tools involved.
        let summary = "\(Self.lineStamp.string(from: now))  MAIN THREAD WEDGED ~\(Int(age))s  v\(version)(\(build)) pid=\(pid)\n"
        let tally = dir.appendingPathComponent("hangs.log")
        if let h = try? FileHandle(forWritingTo: tally) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(summary.utf8))
        } else {
            try? summary.write(to: tally, atomically: true, encoding: .utf8)
        }
        Log.d("watchdog: MAIN THREAD WEDGED ~\(Int(age))s -> hang-\(stamp).txt")

        // 2) Best-effort deep sample of every thread. Needs task_for_pid; on a
        // build where that's denied it just fails and we keep the tally line.
        let out = dir.appendingPathComponent("hang-\(stamp).txt")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        proc.arguments = [String(pid), "5", "-file", out.path]
        do {
            try proc.run()
            proc.waitUntilExit()
            Log.d("watchdog: sample \(proc.terminationStatus == 0 ? "written" : "exited \(proc.terminationStatus)") (\(out.lastPathComponent))")
        } catch {
            Log.d("watchdog: sample failed: \(error.localizedDescription)")
        }
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
    private static let lineStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
