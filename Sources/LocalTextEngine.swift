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
    /// binary figure; the interface uses the user's. Locale-aware: the Russian
    /// interface writes "2,5 ГБ", not "2.5 GB".
    static var sizeText: String { MachineProfile.fileSizeText(totalBytes) }

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
                .attributesOfItem(atPath: url.path)[.size]) as? Int64
            return size == part.bytes
        }
    }

    /// Deletes the model from disk — AFTER the helper has let go of it.
    ///
    /// The helper memory-maps the weights. Unlinking a mapped file frees no
    /// disk until the last map closes, which used to be the idle timeout
    /// minutes later: a person who clicked Remove to get 2.5 GB back got
    /// nothing back, and the backfill in progress kept generating from a file
    /// that no longer had a name.
    static func remove() {
        LlamaServer.shared.shutdown()
        try? FileManager.default.removeItem(at: location)
        try? FileManager.default.removeItem(at: staging)
        Log.d("text model: removed")
    }

    /// The helper that runs the model, inside our own bundle.
    ///
    /// Deliberately a QUESTION ABOUT THE BINARY rather than about the
    /// architecture. The helper ships universal (arm64 + x86_64), so an Intel
    /// Mac runs the x86_64 slice on the CPU: slower, but working — which is the
    /// claim this project already makes about Intel elsewhere, and Intel is
    /// precisely the audience with no alternative, since those Macs are frozen
    /// on macOS 15 while Apple's model needs 26. A build that did not embed the
    /// helper answers nil here, and then there is no local engine and nothing
    /// offers a download.
    static var helper: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/llama-server"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isSupported: Bool { helper != nil }

    // MARK: - The memory gate

    /// How much memory this Mac must have before the model is offered — or,
    /// once installed, RUN.
    ///
    /// 16 GiB, and the history of the number is the reason it is not lower.
    /// It was 8, on the argument that 8 GB is the base configuration of every
    /// entry-level Mac and refusing them all decides for people who would
    /// accept the cost. Then the owner's MacBook M2 with 8 GB ran the model
    /// once (2026-09-13): the weights alone are 2.3 GiB, the context cache
    /// another 1–2, macOS wants 3 — and the machine did not slow down, it
    /// stopped, and had to be force-rebooted. That is not a cost a sentence
    /// of copy can state; it is a trap. Every 8 GB Mac reports exactly 8 GiB,
    /// so `>=` here is the whole difference between offering and not.
    static let memoryFloor: Int64 = 16 << 30

    /// Where the helper's working set stops being felt. Between the floor and
    /// this the model runs with a smaller context cache (see `helperPlan`)
    /// and the cost is stated in the offer; from here up it runs at full size
    /// and nothing needs saying.
    static let comfortableMemory: Int64 = 32 << 30

    static func hasEnoughMemory(_ memory: Int64) -> Bool { memory >= memoryFloor }

    /// Enough to run it, not enough to run it unnoticed — the tier that gets
    /// the extra clause of copy.
    static func isMemoryTight(_ memory: Int64) -> Bool {
        memory >= memoryFloor && memory < comfortableMemory
    }

    /// Whether this build can run the model on this Mac: the helper is here
    /// AND the memory is. A model that is somehow installed on a Mac below
    /// the floor (a migration from a bigger Mac, or a floor raised by an
    /// update, which is exactly what 3.2.6 did) is NOT run — it is shown, with
    /// the reason and a Remove button, so nobody's 2.5 GB is stranded and
    /// nobody's Mac is frozen.
    static func isRunnable(memory: Int64, supported: Bool) -> Bool {
        supported && hasEnoughMemory(memory)
    }

    static var hasEnoughMemory: Bool { hasEnoughMemory(MachineProfile.current.memoryBytes) }
    static var isMemoryTight: Bool { isMemoryTight(MachineProfile.current.memoryBytes) }
    static var isRunnable: Bool { isRunnable(memory: MachineProfile.current.memoryBytes,
                                             supported: isSupported) }

    /// Whether this Mac may be offered the download: it can run it, and it can
    /// afford to.
    static var isOffered: Bool { isRunnable }

    /// Apple Silicon or not — asked of the hardware rather than of the build,
    /// because the app ships universal and the answer is a PROMISE about
    /// speed. Measured: 1.1 s per passage on Apple Silicon against 13.9 s on
    /// Intel, where there is no Metal path and the helper runs on the CPU.
    /// That is roughly three minutes of background work for a fifty-minute
    /// meeting, and a user who is not told will report it as a hang.
    static var isAppleSilicon: Bool { MachineProfile.current.isAppleSilicon }

    /// Whether generation here runs on the CPU — the case the copy has to warn
    /// about.
    static var runsOnCPU: Bool { !isAppleSilicon }

    // MARK: - How the helper is run on this Mac

    enum KVCacheType: String, Sendable { case f16, q8_0 }

    /// The helper's configuration, derived from the machine rather than fixed:
    /// the context size, how the context cache is stored, how long an idle
    /// helper keeps its weights resident, and how much of a meeting the brief
    /// may read.
    struct HelperPlan: Sendable, Equatable {
        let contextSize: Int
        let kvCache: KVCacheType
        let flashAttention: Bool
        let idleTimeout: TimeInterval
        /// Characters of transcript the brief reads; see `LocalTextEngine.briefLimit`.
        let briefLimit: Int

        /// Bytes of context cache per token for Qwen3-4B: 36 layers × 8 KV
        /// heads × 128 dims × 2 (K and V) = 73 728 values — 2 bytes each as
        /// f16, 1.0625 as q8_0 (32 values in a 34-byte block).
        var kvBytesPerToken: Int64 {
            switch kvCache {
            case .f16: return 147_456
            case .q8_0: return 78_336
            }
        }

        var kvCacheBytes: Int64 { Int64(contextSize) * kvBytesPerToken }

        /// What the helper holds while generating: the weights (memory-mapped,
        /// but resident once read), the context cache, and roughly 0.4 GiB of
        /// compute buffers (the 152k-token logits alone are 311 MB). At 16k
        /// f16 this comes to 5 GiB, against 4.7 GB measured — the same number
        /// in decimal.
        var expectedResidentBytes: Int64 {
            LocalTextModelFile.totalBytes + kvCacheBytes + (2 << 28)
        }

        /// What must be free before the helper is started: its working set,
        /// and a gigabyte so the rest of the Mac does not pay for it.
        var neededHeadroomBytes: Int64 {
            expectedResidentBytes + (1 << 30) + (1 << 29)
        }
    }

    /// The plan for a machine.
    ///
    /// Below 32 GiB the context cache is quantised (q8_0) instead of halved:
    /// a 16 384-token window at q8_0 costs what an 8 192 one costs at f16, and
    /// keeps the whole-transcript brief — the reason the model is worth its
    /// download — intact. Intel gets a smaller window and a smaller brief
    /// outright: the prompt runs on the CPU there at 13.9 s per passage, and
    /// a brief over a whole hour would be five minutes of fan noise reported
    /// as a hang.
    static func helperPlan(for profile: MachineProfile) -> HelperPlan {
        if !profile.isAppleSilicon {
            return HelperPlan(contextSize: 8192, kvCache: .f16, flashAttention: false,
                              idleTimeout: 60, briefLimit: 18_000)
        }
        if profile.memoryBytes < comfortableMemory {
            return HelperPlan(contextSize: 16384, kvCache: .q8_0, flashAttention: true,
                              idleTimeout: 60, briefLimit: 45_000)
        }
        return HelperPlan(contextSize: 16384, kvCache: .f16, flashAttention: false,
                          idleTimeout: 180, briefLimit: 45_000)
    }

    static var currentPlan: HelperPlan { helperPlan(for: MachineProfile.current) }

    /// "It holds about 3.9 GB of memory while it writes" — the number in the
    /// tight-memory sentence, from the plan rather than typed in.
    static var expectedResidentText: String {
        MachineProfile.memoryText(currentPlan.expectedResidentBytes)
    }

    // MARK: - The verdict

    /// Whether this Mac can run the meeting model, and what that costs —
    /// one answer, rendered by every surface.
    static func verdict(on profile: MachineProfile, supported: Bool = isSupported,
                        appleIntelligence: AppleIntelligenceState) -> HardwareVerdict {
        guard supported else {
            return .unavailable(reason: L("This build of Dictate does not include the meeting model."),
                                instead: insteadText(appleIntelligence))
        }
        guard hasEnoughMemory(profile.memoryBytes) else {
            return .unavailable(
                reason: Lf("The meeting model needs 16 GB of memory; this Mac has %d.", profile.memoryGB),
                instead: insteadText(appleIntelligence))
        }
        if !profile.isAppleSilicon {
            return .availableWithCost(L("On this Mac it runs on the CPU: about three minutes of background work for a 50-minute meeting."))
        }
        if isMemoryTight(profile.memoryBytes) {
            let plan = helperPlan(for: profile)
            return .availableWithCost(
                Lf("It holds about %@ of memory while it writes, which this Mac will feel.",
                   MachineProfile.memoryText(plan.expectedResidentBytes)))
        }
        return .available
    }

    /// What reads meetings when the model cannot — the second half of every
    /// "not available" sentence.
    static func insteadText(_ state: AppleIntelligenceState) -> String {
        switch state {
        case .on:
            return L("Titles and summaries come from Apple Intelligence instead.")
        case .notEnabled:
            return L("Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri, or add a key for the agent.")
        case .notReady:
            return L("macOS is still setting up Apple Intelligence — check back later, or add a key for the agent.")
        case .notEligible:
            return L("Apple Intelligence isn't available on this Mac in this region or language. The agent with your own key still works.")
        case .unavailableOS:
            return L("Apple Intelligence needs macOS 26. The agent with your own key still works.")
        }
    }
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
    /// with 37× the budget. Smaller on Intel, where the window is too — see
    /// `LocalTextModelFile.helperPlan`.
    let briefLimit = LocalTextModelFile.currentPlan.briefLimit
    /// Deliberately identical to Apple's: a section is one subject, and this is
    /// the number every section measurement was taken at.
    let sectionLimit = MeetingSectioner.excerptLimit
    /// Reads Russian and answers in English, 11 of 11 measured — and the
    /// translation hop it skips is not free: translating first visibly LOSES
    /// content on these same passages.
    let readsEveryLanguage = true

    /// nil unless there is a model on disk AND this Mac may run it.
    ///
    /// The memory floor is checked HERE, for the engine, and not only for the
    /// offer: a model installed on a Mac that cannot afford it (see
    /// `LocalTextModelFile.isRunnable`) is the one case where running it is
    /// worse than not — the log says why, Settings says why, and Apple's
    /// engine takes over when it can.
    static func availableEngine() async -> LocalTextEngine? {
        guard LocalTextModelFile.isInstalled else { return nil }
        guard LocalTextModelFile.isRunnable else {
            Log.d("text model: installed but this Mac has \(MachineProfile.current.memoryGB) GB, needs 16 — not started")
            return nil
        }
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
        var passage = text
        var raw: String
        do {
            raw = try await LlamaServer.shared.complete(system: asked, user: passage,
                                                        temperature: 0.3, maxTokens: 200)
        } catch GenerationFailure.tooLong {
            // The character budget is a guess at a token budget, and Cyrillic
            // runs closer to 2.5 characters a token than the 3.75 the budget
            // was measured at. One retry on half the text, sampled evenly the
            // way the excerpt itself was — a shorter read beats a meeting
            // refused for the rest of the session.
            passage = Self.halved(passage)
            Log.d("text model: prompt over the context window — retrying with \(passage.count) chars")
            raw = try await LlamaServer.shared.complete(system: asked, user: passage,
                                                        temperature: 0.3, maxTokens: 200)
        }
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

    /// Every other line, so the retry still reads from the whole meeting
    /// rather than from its first half.
    static func halved(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { return String(text.prefix(text.count / 2)) }
        return lines.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            .joined(separator: "\n")
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

    /// Posted on the main queue when the helper is paused for memory (userInfo
    /// "reason") and again, without a reason, when the pause lifts — Settings
    /// and the meetings window show it, and AppDelegate kicks the backfills
    /// again on the way out.
    nonisolated static let pauseChanged = Notification.Name("dictate.textModelPause")

    /// Whether a meeting is being recorded right now — the helper must not
    /// start under a live call. Written by MeetingSession from the main actor
    /// on start and stop; read here, off it. A backfill already asks the
    /// session before every meeting, but the two hand-triggered paths (a
    /// recut, a one-time summary) did not, and on a 16 GB Mac a call plus the
    /// helper is the whole machine.
    nonisolated static let callInProgress = LockedFlag()

    private var process: Process?
    private var port: Int?
    /// Held for the child's lifetime, and this is load-bearing: it is the read
    /// end of the pipe the child writes its log to. If WE die — crash included
    /// — the read end closes and the child's next log write takes SIGPIPE. One
    /// of three layers; see `reapOrphans`.
    private var output: Pipe?
    private var lastUsed = Date()
    private var idleWatch: Task<Void, Never>?
    /// Alive only while a child is: the kernel's memory-pressure signal, on
    /// which an idle helper is dropped at once and a busy one at critical.
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Set when the helper was stopped for memory, so the request in flight
    /// reports a pause rather than a dead socket.
    private var stoppedForPressure = false
    /// While set, nothing generates and a poll every 30 s asks whether the
    /// memory has come back — the pressure source only ever announces the way
    /// down.
    private var pausedReason: String?
    private var resumeWatch: Task<Void, Never>?

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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // The socket died under the request. If WE killed the helper for
            // memory, that is a pause, not a failure: the meeting is retried
            // when the memory is back, not refused for the session.
            if stoppedForPressure { throw GenerationFailure.deferred(pausedReason ?? "memory pressure") }
            throw error
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // llama-server answers 400 for a prompt that does not fit its
            // window (context shift is off in the server); the body names
            // the tokens. The brief retries once on a shorter read.
            if status == 400, let body = String(data: data, encoding: .utf8),
               body.localizedCaseInsensitiveContains("context") {
                throw GenerationFailure.tooLong
            }
            throw GenerationFailure.failed("helper returned \(status)")
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
        // The pre-flight: the same machine that passed the static floor can be
        // out of room right now. A helper started into a Mac that is already
        // swapping is the 8 GB freeze at a larger scale — refused here, logged
        // with the numbers, and retried when the room is back.
        let plan = LocalTextModelFile.currentPlan
        if let (why, detail) = Self.refusal(for: plan) {
            pause(why, detail: detail)
            throw GenerationFailure.deferred(detail)
        }
        clearPause()
        let chosen = try Self.freePort()
        let task = Process()
        task.executableURL = helper
        var arguments = [
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
            // the context window is shared between slots otherwise.
            "--parallel", "1",
            // Room for a whole meeting plus its answer — sized by the machine.
            "--ctx-size", String(plan.contextSize),
            "--no-webui",
        ]
        if plan.flashAttention {
            // A quantised context cache needs flash attention, which Metal
            // has for this head size; the pair is what lets a 16 GB Mac keep
            // the full window.
            arguments += ["--flash-attn", "on",
                          "--cache-type-k", plan.kvCache.rawValue,
                          "--cache-type-v", plan.kvCache.rawValue]
        }
        task.arguments = arguments
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
        stoppedForPressure = false
        Self.writePidFile(task.processIdentifier)
        Log.d("text model: helper started (pid \(task.processIdentifier), port \(chosen), ctx \(plan.contextSize) \(plan.kvCache.rawValue), headroom \(MachineProfile.memoryText(MachineProfile.memoryHeadroom())))")
        // The child's log has to be drained or the pipe fills and the child
        // blocks writing into it.
        drain(pipe)
        do {
            try await waitUntilHealthy(port: chosen, process: task)
        } catch {
            stop()
            throw error
        }
        startIdleWatch(after: plan.idleTimeout)
        watchPressure()
        return chosen
    }

    /// Why the helper must not start right now, or nil.
    ///
    /// Two questions, both of the kernel: is the Mac already under memory
    /// pressure (then anything we add is paid for by everything else), and
    /// would the helper's working set fit in what is unused now.
    nonisolated static func refusal(for plan: LocalTextModelFile.HelperPlan)
        -> (TextModelRowCopy.Pause, String)? {
        if callInProgress.value {
            return (.call, "a meeting is being recorded")
        }
        let pressure = MachineProfile.memoryPressureLevel()
        if pressure >= 2 {
            return (.memory, "the Mac is under memory pressure (level \(pressure))")
        }
        let headroom = MachineProfile.memoryHeadroom()
        if headroom < plan.neededHeadroomBytes {
            return (.memory, "not enough free memory (\(MachineProfile.memoryText(headroom)) free, needs \(MachineProfile.memoryText(plan.neededHeadroomBytes)))")
        }
        return nil
    }

    /// Why the helper is waiting, or nil — what the row in Settings and the
    /// note in the meetings window show.
    nonisolated static func currentPause() -> TextModelRowCopy.Pause? {
        pauseState.value
    }

    /// Mirrors the pause for readers off the actor.
    nonisolated private static let pauseState = LockedValue<TextModelRowCopy.Pause?>(nil)

    private func pause(_ why: TextModelRowCopy.Pause, detail: String) {
        let changed = pausedReason != detail
        pausedReason = detail
        Self.pauseState.set(why)
        if changed {
            Log.d("text model: paused — \(detail)")
            Self.post(reason: why)
        }
        // Ask again every 30 s: the pressure source says nothing on the way
        // back to normal, so the only way to notice is to look.
        guard resumeWatch == nil else { return }
        resumeWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                if await self.resumeIfPossible() { return }
            }
        }
    }

    private func resumeIfPossible() -> Bool {
        guard pausedReason != nil else { return true }
        guard Self.refusal(for: LocalTextModelFile.currentPlan) == nil else { return false }
        Log.d("text model: memory is back — resuming")
        clearPause()
        Self.post(reason: nil)
        return true
    }

    private func clearPause() {
        resumeWatch?.cancel()
        resumeWatch = nil
        pausedReason = nil
        Self.pauseState.set(nil)
    }

    nonisolated private static func post(reason: TextModelRowCopy.Pause?) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: pauseChanged, object: nil,
                                            userInfo: reason.map { ["reason": $0.rawValue] })
        }
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
    private func startIdleWatch(after idleTimeout: TimeInterval) {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                if await self.expireIfIdle(after: idleTimeout) { return }
            }
        }
    }

    private func expireIfIdle(after idleTimeout: TimeInterval) -> Bool {
        guard let process, process.isRunning else {
            stop()
            return true
        }
        guard Date().timeIntervalSince(lastUsed) >= idleTimeout else { return false }
        Log.d("text model: idle — stopping the helper")
        stop()
        return true
    }

    /// The kernel's memory-pressure signal, for the life of the child. The
    /// handler runs on a dispatch queue, not on the actor — it hops.
    private func watchPressure() {
        pressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) ?? false
            Task { await self?.onPressure(critical: critical) }
        }
        source.resume()
        pressureSource = source
    }

    /// Warning: an idle helper is not worth 4 GB — drop it. Critical: drop it
    /// even mid-request; the request reports a pause and the meeting waits.
    private func onPressure(critical: Bool) {
        guard let process, process.isRunning else { return }
        let idle = Date().timeIntervalSince(lastUsed) > 2
        guard critical || idle else {
            Log.d("text model: memory pressure warning — helper busy, kept")
            return
        }
        Log.d("text model: memory pressure \(critical ? "critical" : "warning") — stopping the helper")
        stoppedForPressure = true
        stop()
        pause(.memory, detail: critical ? "the Mac is under critical memory pressure"
                                        : "the Mac is under memory pressure")
    }

    /// Ends the child, politely then not. Safe to call when nothing is running,
    /// which is what makes it safe to call unconditionally from
    /// applicationWillTerminate.
    nonisolated func shutdown() {
        // Synchronous on purpose: applicationWillTerminate does not outlive an
        // async hop, and a helper that is still alive when we exit is exactly
        // what this whole design is meant to prevent. The pid file is the
        // shared state, so this needs nothing from the actor.
        Self.killRecordedHelper(reason: "the app is quitting or the model is being removed")
    }

    private func stop() {
        idleWatch?.cancel()
        idleWatch = nil
        pressureSource?.cancel()
        pressureSource = nil
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
    /// explains it — and its own memory and timing figures are the ones this
    /// app used to estimate by hand.
    private nonisolated func drain(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline)
            where line.localizedCaseInsensitiveContains("error")
                || line.localizedCaseInsensitiveContains("failed")
                || line.contains("KV buffer size")
                || line.contains("compute buffer size")
                || line.contains("prompt eval time") {
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
    /// The pid is only killed while the file still names it and the process
    /// behind it is still OUR helper: a pid file restored by Migration
    /// Assistant onto a Mac where that number belongs to something else must
    /// not kill it.
    static func killRecordedHelper(reason: String) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0 else {
            clearPidFile()
            return
        }
        guard executableName(of: pid)?.hasSuffix("llama-server") == true else {
            Log.d("text model: pid \(pid) in the pid file is not our helper — leaving it")
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

    private static func executableName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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

/// A Bool readable from any thread — for the one fact the helper needs from
/// the main actor without hopping to it.
final class LockedFlag: @unchecked Sendable {   // NSLock guards `flag`
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ value: Bool) { lock.lock(); flag = value; lock.unlock() }
}

/// The same, for a value.
final class LockedValue<T: Sendable>: @unchecked Sendable {   // NSLock guards `stored`
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
}
