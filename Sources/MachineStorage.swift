import Foundation

/// What the app keeps on this Mac's disk, by name and size — the Storage
/// rows on This Mac. Measured, not remembered: the person is about to decide
/// what to remove, and a number from a table would be a guess.
///
/// Sizes come from `totalFileAllocatedSize` through an enumerator that never
/// opens a file: the meeting archive may live in iCloud, and reading an
/// evicted file blocks on the network (the 16-second main-thread hang of
/// 2026-08-17). Callers run this off the main thread anyway.
struct MachineStorage: Sendable {
    /// The speech model and its tokenizer.
    let speechModelBytes: Int64
    /// The meeting model — zero when it is not installed.
    let meetingModelBytes: Int64
    /// Everything else under models/: the speaker models the diarizer fetched.
    let speakerModelBytes: Int64
    let meetingArchiveBytes: Int64
    /// Meeting files in the archive — reports live inside them, so this is
    /// the one count About needs.
    let meetingCount: Int
    /// The debug audio dumps (`meetingAudioDump`), when the default is on.
    let debugDumpBytes: Int64
    /// PDFs in the archive's Reports folder, written by versions that still
    /// wrote them; nil when there is no such folder. Named in About, never
    /// touched.
    let reportsPDFCount: Int?

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
    }

    static var modelsDirectory: URL { applicationSupport.appendingPathComponent("models", isDirectory: true) }
    static var replayDirectory: URL { applicationSupport.appendingPathComponent("replay", isDirectory: true) }

    static func measure(archive: URL) -> MachineStorage {
        let models = modelsDirectory
        let whisper = size(of: models.appendingPathComponent("models", isDirectory: true))
            + size(of: models.appendingPathComponent("tokenizers", isDirectory: true))
        let text = size(of: LocalTextModelFile.location)
        let everything = size(of: models)
        let speakers = max(0, everything - whisper - size(of: LocalTextModelFile.directory))
        return MachineStorage(
            speechModelBytes: whisper,
            meetingModelBytes: text,
            speakerModelBytes: speakers,
            meetingArchiveBytes: size(of: archive),
            meetingCount: ((try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? [])
                .filter { $0.hasSuffix(".md") }.count,
            debugDumpBytes: size(of: replayDirectory),
            reportsPDFCount: (try? FileManager.default.contentsOfDirectory(
                atPath: archive.appendingPathComponent("Reports", isDirectory: true).path))
                .map { $0.filter { $0.lowercased().hasSuffix(".pdf") }.count })
    }

    /// Bytes allocated under a directory, without opening anything.
    static func size(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                        options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
