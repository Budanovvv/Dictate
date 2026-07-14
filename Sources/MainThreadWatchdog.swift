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
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "com.valentynbudanov.Dictate.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var lastBeat = Date()
    /// Seconds the main thread may be unresponsive before it's called wedged.
    private let threshold: TimeInterval = 15
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

        lock.lock()
        let age = Date().timeIntervalSince(lastBeat)
        lock.unlock()

        if age >= threshold {
            if !captured {
                captured = true
                capture(stuckFor: age)
            }
        } else {
            captured = false   // main answered again — re-arm for the next hang
        }
    }

    private func beat() {
        lock.lock()
        lastBeat = Date()
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
            h.seekToEndOfFile()
            h.write(Data(summary.utf8))
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
