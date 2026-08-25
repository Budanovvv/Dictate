import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where the downloadable text model lives, and whether it is here.
///
/// The path deserves its own explanation, because the obvious name is a trap.
/// This is `models/text/` inside the app's Application Support folder, beside
/// `models/diarizer` and the WhisperKit models — NOT `llm/`.
/// `AppDelegate.removeRetiredPolishModel` deletes Application Support/Dictate/llm
/// at EVERY launch, to reclaim the 1.9 GB left behind by the AI-polish feature
/// removed in 2.3.1. A new model put there would be downloaded, used once, and
/// silently eaten on the next start — forever, with no error anywhere. Do not
/// move it back.
enum LocalTextModelFile {

    /// Qwen3-4B-Instruct-2507, Q4_K_M — the model the archive was measured on:
    /// 36 of 36 passages, no retries, no quotations, no language drift and no
    /// refusals, against Apple's 25 of 36 with 11 refusals on the same text,
    /// at 1.1 s per passage. Apache-2.0, so it can be shipped and recommended
    /// without conditions.
    static let name = "Qwen3-4B-Instruct-2507"
    static let weightsFile = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    static let repository = "unsloth/Qwen3-4B-Instruct-2507-GGUF"

    /// One file of the model, pinned by size and hash.
    ///
    /// A LIST even though this model is a single file, because the shape is
    /// what makes the download code independent of the model: parts are
    /// fetched, resumed, size-checked and hashed the same way whether there is
    /// one of them or eleven.
    ///
    /// Pinned to the PUBLISHED artifact rather than "whatever that repository
    /// serves today": a GGUF that quietly changes underneath is a model whose
    /// measurements no longer describe it. The hash below is Hugging Face's own
    /// linked-etag for the file, verified against a local download.
    struct Part: Sendable {
        let name: String
        let bytes: Int64
        var sha256: String? = nil

        var url: URL {
            URL(string: "https://huggingface.co/\(repository)/resolve/main/\(name)")!
        }
    }

    static let parts: [Part] = [
        Part(name: weightsFile, bytes: 2_497_281_120,
             sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"),
    ]

    static var totalBytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }

    /// What the download costs, for the one sentence the user is asked to agree
    /// to.
    ///
    /// DECIMAL gigabytes (2.5), not binary (2.33), and the reason is what the
    /// number is FOR: the user compares it against the free space his own Mac
    /// reports, and Finder counts in decimal. A button reading 2.33 GB beside a
    /// file Get Info calls 2.5 GB understates the disk cost — a small lie in the
    /// direction that matters. The internal notes and the measurements use the
    /// binary figure; the interface uses the user's.
    static var sizeText: String {
        String(format: "%.1f GB", Double(totalBytes) / 1_000_000_000)
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("text", isDirectory: true)
    }

    /// The finished model. Nothing is ever written here directly — a download
    /// assembles itself in `staging` and is moved across in one step.
    static var location: URL { directory.appendingPathComponent(name, isDirectory: true) }

    /// Where a download in progress lives. A separate name so an interrupted
    /// fetch can never be mistaken for a model: the Whisper-model lesson, which
    /// is that a partial download that LOOKS complete fails every later load
    /// with an error nobody can act on, days after the cause.
    static var staging: URL { directory.appendingPathComponent(name + ".partial", isDirectory: true) }

    /// The weights themselves, for the helper's command line.
    static var weights: URL { location.appendingPathComponent(weightsFile) }

    /// Whether a usable model is on disk. Cheap enough to ask on every
    /// generation, which is what lets the engine follow a download finishing or
    /// a Remove in Settings without anything having to notify anything —
    /// size-checked rather than merely present, because "the folder exists" is
    /// true halfway through a download too.
    static var isInstalled: Bool {
        parts.allSatisfy { part in
            let url = location.appendingPathComponent(part.name)
            let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64) as? Int64
            return size == part.bytes
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: location)
        try? FileManager.default.removeItem(at: staging)
        Log.d("text model: removed")
    }

    /// The helper that runs the model, inside our own bundle.
    ///
    /// This is also the hardware gate, and it is deliberately a QUESTION ABOUT
    /// THE BINARY rather than about the architecture. The helper ships
    /// universal (arm64 + x86_64), so an Intel Mac runs the x86_64 slice on the
    /// CPU: slower, but working — which is the claim this project already makes
    /// about Intel elsewhere, and Intel is precisely the audience with no
    /// alternative, since those Macs are frozen on macOS 15 while Apple's model
    /// needs 26. A build that did not embed the helper answers nil here, and
    /// then there is no local engine and nothing offers a download.
    static var helper: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/llama-server"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isSupported: Bool { helper != nil }

    /// How much memory this Mac must have before the download is OFFERED at
    /// all.
    ///
    /// Measured: the helper holds 4.7 GB resident while generating (one slot;
    /// four slots cost 7.6 GB, which is why there is one). Below 8 GB that is
    /// most of the machine and then some — the download would be a trap, so
    /// there is no card and no Settings row. Honest absence, the same
    /// treatment a Mac with no helper binary gets.
    static let memoryFloor: Int64 = 8 << 30

    /// Where 4.7 GB is a guest rather than an eviction. Between the floor and
    /// this the offer still stands — 8 GB is the base configuration of every
    /// entry-level Mac, and refusing all of them outright decides for people
    /// who would happily accept the cost — but the cost is stated in the same
    /// breath, with the number in front of them.
    static let comfortableMemory: Int64 = 16 << 30

    private static var physicalMemory: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    static var hasEnoughMemory: Bool { physicalMemory >= memoryFloor }

    /// Enough to run it, not enough to run it unnoticed — the tier that gets
    /// the extra clause of copy.
    static var isMemoryTight: Bool {
        physicalMemory >= memoryFloor && physicalMemory < comfortableMemory
    }

    /// Whether this Mac may be offered the download: it can run it, and it can
    /// afford to. Separate from `isSupported`, which stays a question about
    /// the BINARY — the engine still uses a model that is somehow already
    /// installed, so nobody's 2.5 GB is stranded by a rule added after the
    /// fact.
    static var isOffered: Bool { isSupported && hasEnoughMemory }

    /// Apple Silicon or not — asked of the hardware rather than of the build,
    /// because the app ships universal and the answer is a PROMISE about
    /// speed. Measured: 1.1 s per passage on Apple Silicon against 13.9 s on
    /// Intel, where there is no Metal path and the helper runs on the CPU.
    /// That is roughly three minutes of background work for a fifty-minute
    /// meeting, and a user who is not told will report it as a hang.
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    /// Whether generation here runs on the CPU — the case the copy has to warn
    /// about.
    static var runsOnCPU: Bool { !isAppleSilicon }
}

/// The local generation engine: a downloaded model, run by a bundled
/// llama.cpp server in a CHILD PROCESS.
///
/// The child process is the whole design, not an implementation detail. This
/// app linked llama.cpp once before, for the AI-polish feature, and it crashed
/// with SIGABRT on EVERY quit for as long as a model had been loaded: llama's
/// C++ static destructors tear the Metal device down inside `exit()` and race
/// the library's own async init worker (ggml_metal_rsets_free → ggml_abort).
/// Crash reports piled up on every Quit and every silent update relaunch. The
/// workaround at the time was `_exit(0)` in applicationWillTerminate — skipping
/// static destructors altogether — and it was removed with the feature. Running
/// llama in a process of its own makes the entire class impossible rather than
/// worked around: its destructors run in a process whose death is the point.
struct LocalTextEngine: MeetingTextEngine {
    let engineName = "qwen3-4b"

    /// The whole transcript, not an excerpt — one of the two reasons the model
    /// is worth its download. 45 000 characters is roughly 12 000 tokens on
    /// these transcripts (measured: a 50-minute meeting is ~13k), which fits
    /// the helper's 16k window with the instructions and the answer. A longer
    /// meeting falls back to the same even sampling Apple's path uses, just
    /// with 37× the budget.
    let briefLimit = 45_000
    /// Deliberately identical to Apple's: a section is one subject, and this is
    /// the number every section measurement was taken at.
    let sectionLimit = MeetingSectioner.excerptLimit
    /// Reads Russian and answers in English, 11 of 11 measured — and the
    /// translation hop it skips is not free: translating first visibly LOSES
    /// content on these same passages.
    let readsEveryLanguage = true

    /// nil unless there is a model on disk AND a helper to run it.
    static func availableEngine() async -> LocalTextEngine? {
        guard LocalTextModelFile.isInstalled, LocalTextModelFile.isSupported else { return nil }
        return LocalTextEngine()
    }

    func brief(about text: String, instructions: String) async throws -> GeneratedBrief {
        // Two fields out of a free-text model. Apple's path gets them from
        // guided generation; here they are asked for on two labelled lines.
        // Anything that is NOT two labelled lines still yields a title (the
        // first line) and a summary (the rest), so a chatty answer degrades
        // instead of failing — and whatever comes out still has to survive
        // every filter in MeetingTitler afterwards.
        let asked = instructions + """


            Answer in exactly two lines and nothing else:
            TITLE: <the title>
            LINE: <the line under it>
            """
        let raw = try await LlamaServer.shared.complete(system: asked, user: text,
                                                        temperature: 0.3, maxTokens: 200)
        var title = "", summary = ""
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = trimmed.dropping(label: "TITLE:") { title = value }
            else if let value = trimmed.dropping(label: "LINE:") { summary = value }
            else if let value = trimmed.dropping(label: "SUMMARY:") { summary = value }
            else if title.isEmpty { title = trimmed }
            else if summary.isEmpty { summary = trimmed }
        }
        guard !title.isEmpty else { throw GenerationFailure.failed("no title in the answer") }
        return GeneratedBrief(title: title, summary: summary)
    }

    func line(about text: String, instructions: String,
              temperature: Double) async throws -> String {
        try await LlamaServer.shared.complete(system: instructions, user: text,
                                              temperature: temperature, maxTokens: 100)
    }
}

private extension String {
    /// The value after a label, or nil when this line does not carry it.
    func dropping(label: String) -> String? {
        guard lowercased().hasPrefix(label.lowercased()) else { return nil }
        return String(dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Owns the child process: starts it when something needs generating, answers
/// over loopback, stops it when nothing has for a while, and guarantees it does
/// not outlive us.
///
/// An actor because everything here is a race otherwise: the summaries backfill
/// and the sections backfill can both decide the server is not running, and
/// starting two servers means two copies of 2.4 GB of weights in memory.
actor LlamaServer {
    static let shared = LlamaServer()

    private var process: Process?
    private var port: Int?
    /// Held for the child's lifetime, and this is load-bearing: it is the read
    /// end of the pipe the child writes its log to. If WE die — crash included
    /// — the read end closes and the child's next log write takes SIGPIPE. One
    /// of three layers; see `reapOrphans`.
    private var output: Pipe?
    private var lastUsed = Date()
    private var idleWatch: Task<Void, Never>?

    /// How long an idle server keeps 2.4 GB of weights resident. A backfill
    /// works in bursts with pauses between meetings, so this has to outlast a
    /// pause comfortably; it does not have to outlast a coffee break.
    private let idleTimeout: TimeInterval = 180
    /// A cold start memory-maps 2.4 GB and warms the Metal pipeline. Measured
    /// at about 4 s warm; the ceiling is generous because the alternative to
    /// waiting is a meeting with no name.
    private let startupTimeout: TimeInterval = 120

    private init() {}

    /// One generation. Starts the server if it is not running.
    func complete(system: String, user: String,
                  temperature: Double, maxTokens: Int) async throws -> String {
        let port = try await running()
        lastUsed = Date()
        defer { lastUsed = Date() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
            "temperature": temperature,
            "max_tokens": maxTokens,
            // Qwen publishes these three for this model, and sending only
            // `temperature` does NOT leave them unset — it leaves them at
            // llama.cpp's own defaults, which are top_k 40, top_p 0.95 and
            // min_p 0.05. That is a silent contradiction of the model card
            // (20 / 0.8 / 0.0), and it is not cancelled out by a low
            // temperature: llama.cpp applies temperature LAST in the sampler
            // chain, so these three truncate the distribution before it ever
            // gets there.
            "top_p": 0.8,
            "top_k": 20,
            "min_p": 0.0,
            // The instructions are identical across a whole backfill, so the
            // server keeps their prefix tokenized and skips re-reading it —
            // most of the per-call cost on short passages.
            "cache_prompt": true,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GenerationFailure.failed(
                "helper returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw GenerationFailure.failed("unreadable answer")
        }
        return content
    }

    // MARK: - Lifecycle

    private func running() async throws -> Int {
        if let port, let process, process.isRunning { return port }
        return try await start()
    }

    private func start() async throws -> Int {
        stop()   // whatever is left of a previous, dead attempt
        guard let helper = LocalTextModelFile.helper, LocalTextModelFile.isInstalled else {
            throw GenerationFailure.unavailable
        }
        let chosen = try Self.freePort()
        let task = Process()
        task.executableURL = helper
        task.arguments = [
            "--model", LocalTextModelFile.weights.path,
            // Loopback only. Two reasons, and the second is not obvious: a
            // process listening on a routable address makes macOS put up the
            // firewall's "accept incoming connections?" dialog, which for a
            // helper the user never launched is alarming and unanswerable.
            // Bound to 127.0.0.1 it never appears.
            "--host", "127.0.0.1",
            "--port", String(chosen),
            // One slot: this app never generates two lines at once (the
            // sections backfill explicitly waits for the summaries one), and
            // every extra slot is another KV cache. Measured: 4.7 GB resident
            // at one slot against 7.6 GB at four.
            "--parallel", "1",
            // Room for a whole meeting plus its answer.
            "--ctx-size", "16384",
            "--no-webui",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // Nothing to say to it, and an inherited terminal would be a way for it
        // to block on a read.
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw GenerationFailure.failed("could not start the helper: \(error.localizedDescription)")
        }
        process = task
        port = chosen
        output = pipe
        Self.writePidFile(task.processIdentifier)
        Log.d("text model: helper started (pid \(task.processIdentifier), port \(chosen))")
        // The child's log has to be drained or the pipe fills and the child
        // blocks writing into it.
        drain(pipe)
        do {
            try await waitUntilHealthy(port: chosen, process: task)
        } catch {
            stop()
            throw error
        }
        startIdleWatch()
        return chosen
    }

    private func waitUntilHealthy(port: Int, process: Process) async throws {
        let deadline = Date().addingTimeInterval(startupTimeout)
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let started = Date()
        while Date() < deadline {
            guard process.isRunning else {
                throw GenerationFailure.failed("the helper exited while loading the model")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["status"] as? String == "ok" {
                Log.d(String(format: "text model: ready in %.1fs", Date().timeIntervalSince(started)))
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw GenerationFailure.failed("the helper never became healthy")
    }

    /// Stops the server when nothing has asked it for anything in a while. A
    /// timer, but one that exists only while a child process does — an idle app
    /// has no server, so it has no watch either, and nothing here can show up
    /// as idle CPU.
    private func startIdleWatch() {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                if await self.expireIfIdle() { return }
            }
        }
    }

    private func expireIfIdle() -> Bool {
        guard let process, process.isRunning else {
            stop()
            return true
        }
        guard Date().timeIntervalSince(lastUsed) >= idleTimeout else { return false }
        Log.d("text model: idle — stopping the helper")
        stop()
        return true
    }

    /// Ends the child, politely then not. Safe to call when nothing is running,
    /// which is what makes it safe to call unconditionally from
    /// applicationWillTerminate.
    nonisolated func shutdown() {
        // Synchronous on purpose: applicationWillTerminate does not outlive an
        // async hop, and a helper that is still alive when we exit is exactly
        // what this whole design is meant to prevent. The pid file is the
        // shared state, so this needs nothing from the actor.
        Self.killRecordedHelper(reason: "the app is quitting")
    }

    private func stop() {
        idleWatch?.cancel()
        idleWatch = nil
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()                     // SIGTERM
            // llama.cpp closes its socket and exits promptly on SIGTERM; the
            // kill is for the case where it is wedged inside Metal.
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning {
                Log.d("text model: helper ignored SIGTERM — killing it")
                kill(pid, SIGKILL)
            }
            Log.d("text model: helper stopped (pid \(pid))")
        }
        process = nil
        port = nil
        output = nil
        Self.clearPidFile()
    }

    /// Keeps the pipe from filling up (a full pipe blocks the child) and keeps
    /// the interesting lines. The helper's errors are worth having in our own
    /// log: when it refuses to start, its reason is the only thing that
    /// explains it.
    private nonisolated func drain(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline)
            where line.localizedCaseInsensitiveContains("error")
                || line.localizedCaseInsensitiveContains("failed") {
                Log.d("text model: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    // MARK: - No orphans

    /// Where the running child's pid is written, so a crashed app can still
    /// clean up after itself on the next launch.
    private static var pidFile: URL {
        LocalTextModelFile.directory.appendingPathComponent("helper.pid")
    }

    private static func writePidFile(_ pid: pid_t) {
        try? FileManager.default.createDirectory(at: LocalTextModelFile.directory,
                                                 withIntermediateDirectories: true)
        try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    private static func clearPidFile() {
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Called at launch and at quit: ends a helper this app is responsible for.
    ///
    /// Three layers keep an orphan from surviving us, because macOS has no
    /// parent-death signal and no single mechanism is enough on its own.
    /// (1) An ordinary quit calls this from applicationWillTerminate.
    /// (2) A crash leaves the log pipe's read end closed, so the child takes
    ///     SIGPIPE the next time it writes a line — which is every request and
    ///     every health check.
    /// (3) Whatever still survives is killed at the NEXT launch, and the app is
    ///     a login item, so the next launch is soon.
    ///
    /// The pid is only killed while the file still names it; the file is
    /// deleted the moment the child stops normally, which is what keeps a
    /// recycled pid from being mistaken for our helper.
    static func killRecordedHelper(reason: String) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0 else {
            clearPidFile()
            return
        }
        Log.d("text model: stopping helper pid \(pid) — \(reason)")
        kill(pid, SIGTERM)
        // Give it the same short grace the ordinary stop does, then insist.
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        clearPidFile()
    }

    static func reapOrphans() {
        killRecordedHelper(reason: "left over from a previous run")
    }

    /// An unused loopback port, obtained the only way that is not a guess: ask
    /// the kernel for one, note it, and hand it straight to the child. There is
    /// a window between closing and the child binding, which is why failing to
    /// become healthy is a normal, retried outcome rather than a crash.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GenerationFailure.failed("no socket") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw GenerationFailure.failed("could not reserve a port") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw GenerationFailure.failed("could not read the port") }
        return Int(assigned.sin_port.bigEndian)
    }
}
