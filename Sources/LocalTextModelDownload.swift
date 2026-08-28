import Combine
import CryptoKit
import Foundation

/// Fetches the text model, once, with the user watching.
///
/// The model is 2.5 GB. That is not a thing to slip in behind somebody's back
/// on a metered connection, so nothing here starts on its own: Settings offers
/// it, the user says yes, and this does exactly what it was asked and stops.
///
/// The download is OURS rather than the model library's, deliberately. A
/// framework that reaches for the network on its own decides where the bytes
/// land, and this app has been burned by that: WhisperKit's tokenizer quietly
/// downloaded itself into ~/Documents/huggingface, which made macOS put up a
/// "Dictate wants to access your Documents folder" prompt — alarming for
/// something the user never asked for, and fatal to model loading if refused
/// (GRABLI). Everything here goes into Application Support and the model
/// library is only ever pointed at a directory that is already complete.
@MainActor
final class LocalTextModelDownload: ObservableObject {
    static let shared = LocalTextModelDownload()

    enum State: Equatable {
        /// No helper in this build — nothing to offer and nothing to run.
        case unsupported
        case absent
        case downloading(Double)  // 0…1
        case verifying
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private var task: Task<Void, Never>?

    private init() {
        state = Self.onDisk()
    }

    /// Re-reads the disk. Cheap, and the window may have been open while the
    /// model was removed or finished arriving.
    func refresh() {
        guard task == nil else { return }
        state = Self.onDisk()
    }

    /// What the disk and the hardware say, with no download in flight.
    ///
    /// The order matters. An installed model is `.ready` before the memory
    /// floor is consulted, so a Mac that already has one keeps its Remove
    /// button — a rule added later must not strand 2.5 GB with no way to
    /// delete it. Only the OFFER is gated: too little memory reads the same as
    /// no helper at all, and nothing anywhere proposes the download.
    private static func onDisk() -> State {
        guard LocalTextModelFile.isSupported else { return .unsupported }
        if LocalTextModelFile.isInstalled { return .ready }
        return LocalTextModelFile.hasEnoughMemory ? .absent : .unsupported
    }

    func start() {
        guard LocalTextModelFile.isOffered, task == nil else { return }
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                try await LocalTextModelFetch.run { [weak self] fraction in
                    await MainActor.run { self?.state = .downloading(fraction) }
                } verifying: { [weak self] in
                    await MainActor.run { self?.state = .verifying }
                }
                await MainActor.run {
                    self?.state = .ready
                    self?.task = nil
                }
                Log.d("text model: download complete")
            } catch is CancellationError {
                await MainActor.run {
                    self?.state = LocalTextModelFile.isInstalled ? .ready : .absent
                    self?.task = nil
                }
                Log.d("text model: download cancelled — partial files kept for resume")
            } catch {
                await MainActor.run {
                    self?.state = .failed(error.localizedDescription)
                    self?.task = nil
                }
                Log.d("text model: download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stops, but keeps what has arrived: the next Download picks up where this
    /// left off. A cancelled 2 GB download that has to start again is a
    /// cancelled download the user will not attempt twice.
    func cancel() {
        task?.cancel()
        task = nil
        state = LocalTextModelFile.isInstalled ? .ready : .absent
    }

    /// Removes the model AND anything half-downloaded — the button says
    /// "Remove" and the disk should agree with it completely.
    func remove() {
        cancel()
        LocalTextModelFile.remove()
        refresh()
    }
}

/// Whether the model may be OFFERED where the user is working, and how often.
///
/// Settings is not a signal. A row there is where somebody RETURNS on purpose,
/// and a person who has never seen a named meeting has no reason to go looking
/// for one — the owner found this himself on a clean install. So the offer also
/// appears where the absence is physically visible: a library of meetings named
/// by date.
///
/// Everything about the appearance budget is defensive, because this app has no
/// subscription to sell and a banner that keeps coming back would be the most
/// foreign thing in it. Two runs of the app, then silence for good; "Not now"
/// means never, in every surface at once, and it is written to disk so a
/// relaunch does not forget it.
@MainActor
final class LocalTextModelOffer: ObservableObject {
    static let shared = LocalTextModelOffer()

    private static let dismissedKey = "textModelOfferDismissed"
    private static let seenKey = "textModelOfferSeen"
    /// How many runs of the app may show it. Two: one to plant the idea, one
    /// to catch the person who was busy the first time. A third is nagging.
    static let budget = 2

    /// Dismissed for good. Published so every offer surface vanishes on the click
    /// rather than on the next redraw.
    @Published private(set) var dismissed: Bool
    /// Runs that have already shown it, read ONCE at launch: counting live
    /// would make the card disappear from under the pointer the moment it was
    /// counted.
    private let seenBefore: Int
    private var countedThisRun = false

    private init() {
        dismissed = UserDefaults.standard.bool(forKey: Self.dismissedKey)
        seenBefore = UserDefaults.standard.integer(forKey: Self.seenKey)
    }

    /// Whether a surface may offer the download right now.
    var allowed: Bool {
        !dismissed && seenBefore < Self.budget
            && LocalTextModelFile.isOffered && !LocalTextModelFile.isInstalled
    }

    /// One appearance spent — once per run of the app, however many surfaces
    /// showed it. The card stays on screen for the rest of this run.
    func noteShown() {
        guard !countedThisRun else { return }
        countedThisRun = true
        UserDefaults.standard.set(seenBefore + 1, forKey: Self.seenKey)
    }

    func dismiss() {
        dismissed = true
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        Log.d("text model: offer dismissed for good")
    }
}

/// The actual bytes. Separated from the observable object so the download logic
/// is testable and has no opinion about SwiftUI.
enum LocalTextModelFetch {

    enum Failure: LocalizedError {
        case badResponse(String)
        case wrongSize(String, Int64, Int64)
        case wrongHash(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let what): return "The server refused: \(what)"
            case .wrongSize(let name, let got, let want):
                return "\(name) arrived as \(got) bytes, expected \(want)"
            case .wrongHash(let name): return "\(name) failed its checksum"
            }
        }
    }

    /// Downloads every missing part, resuming any that were interrupted, then
    /// promotes the whole set into place at once.
    ///
    /// Nothing is visible under the model's own name until every part is
    /// present and checked. That is the Whisper-model lesson repeated: a
    /// half-finished download that LOOKS like a model fails every later load
    /// with an error the user cannot act on, and the failure arrives days after
    /// the cause.
    static func run(progress: @escaping @Sendable (Double) async -> Void,
                    verifying: @escaping @Sendable () async -> Void) async throws {
        let staging = LocalTextModelFile.staging
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let parts = LocalTextModelFile.parts
        let total = parts.reduce(Int64(0)) { $0 + $1.bytes }
        var alreadyDone: Int64 = 0
        for part in parts {
            let destination = staging.appendingPathComponent(part.name)
            let have = fileSize(destination)
            if have == part.bytes {
                alreadyDone += part.bytes
                continue
            }
            let base = alreadyDone
            try await fetch(part, to: destination, from: have) { received in
                await progress(Double(base + received) / Double(total))
            }
            alreadyDone += part.bytes
            await progress(Double(alreadyDone) / Double(total))
            try Task.checkCancellation()
        }
        await verifying()
        try verify(parts, in: staging)
        // One atomic move: either the model directory exists complete, or it
        // does not exist.
        let final = LocalTextModelFile.location
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: staging, to: final)
    }

    /// One part, resuming from `offset` when something is already on disk.
    private static func fetch(_ part: LocalTextModelFile.Part, to destination: URL,
                              from offset: Int64,
                              progress: @escaping @Sendable (Int64) async -> Void) async throws {
        var request = URLRequest(url: part.url)
        request.timeoutInterval = 60
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            Log.d("text model: resuming \(part.name) at \(offset) bytes")
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.badResponse(part.name)
        }
        // 206 means the range was honoured; 200 means the whole file is coming
        // and whatever we had is worthless.
        var received = offset
        if http.statusCode == 200, offset > 0 {
            try? FileManager.default.removeItem(at: destination)
            received = 0
        } else if http.statusCode != 200 && http.statusCode != 206 {
            throw Failure.badResponse("\(part.name) — HTTP \(http.statusCode)")
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        // Written in chunks rather than byte by byte: a 2 GB file at one write
        // per byte is not a download, it is a benchmark of FileHandle.
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var sinceReport: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                sinceReport += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Four times a second's worth of bytes, not every megabyte: the
                // progress bar is on the main actor and this is a hot loop.
                if sinceReport >= (8 << 20) {
                    await progress(received)
                    sinceReport = 0
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        await progress(received)
    }

    /// Every part the right size, and the weights the right bytes.
    ///
    /// Size alone catches the truncation that actually happens (a dropped
    /// connection, a full disk); the hash on the weight file catches the rest,
    /// and it is the only part big enough for silent corruption to matter. The
    /// small JSON files are checked by size only — hashing them would pin us to
    /// a repository revision that changes for reasons that do not affect us.
    private static func verify(_ parts: [LocalTextModelFile.Part], in directory: URL) throws {
        for part in parts {
            let url = directory.appendingPathComponent(part.name)
            let size = fileSize(url)
            guard size == part.bytes else {
                throw Failure.wrongSize(part.name, size, part.bytes)
            }
            guard let expected = part.sha256 else { continue }
            guard try sha256(of: url) == expected else {
                throw Failure.wrongHash(part.name)
            }
        }
    }

    /// Streamed, because the file is 2.5 GB and reading it into memory to check
    /// it would cost more than the download did.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) as? Int64 ?? 0
    }
}
