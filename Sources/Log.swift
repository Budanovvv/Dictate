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
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func d(_ message: String) {
        guard enabled else { return }
        let line = "\(time.string(from: Date()))  \(message)\n"
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > 2_000_000 {
                try? FileManager.default.removeItem(at: url)   // keep it small: drop and start over
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
