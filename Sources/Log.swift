import Foundation

/// Diagnostic log: ~/Library/Logs/Dictate/dictate.log — one line per event.
/// Dictation CONTENT is never written, only event metadata (privacy).
///
/// OFF by default: in production the app writes nothing at all. For support
/// and local debugging enable with
///     defaults write com.valentynbudanov.Dictate debugLog -bool YES
/// and restart the app (NO to turn back off).
enum Log {
    private static let enabled = UserDefaults.standard.bool(forKey: "debugLog")
    private static let queue = DispatchQueue(label: "dictate.log", qos: .utility)
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Dictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictate.log")
    }()
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // ASCII digits on any system locale
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Size at which the log rotates. Raised from 2 MB because one meeting
    /// can fill that: a 70-minute session writes previews, VAD verdicts and
    /// window cuts several times a second, and the diagnostics are only worth
    /// having if a whole session fits in them. Two files of this size is the
    /// most the log will ever occupy.
    private static let maxSize = 8_000_000

    static func d(_ message: String) {
        guard enabled else { return }
        let line = "\(time.string(from: Date()))  \(message)\n"
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > maxSize {
                // Rotate, do NOT delete. Deleting cost us the first 45 minutes
                // of a 70-minute webinar (2026-08-19) — including the one line
                // that said WHEN a spurious voice was born, which was the whole
                // question being investigated. A meeting logs a few lines a
                // second, so the file that matters is the one that just filled
                // up, and the previous one is exactly where a long session's
                // beginning lives.
                let previous = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + ".1")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: url, to: previous)
            }
            if let h = FileHandle(forWritingAtPath: url.path) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
