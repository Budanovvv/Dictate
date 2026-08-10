import Foundation

/// One line of a transcript — the unit both the live session and the archive
/// speak in, so the same view renders a call in progress and one from last
/// week.
struct TranscriptEntry: Identifiable, Hashable {
    let id: UUID
    let time: String        // "13:56:28", as written to the file
    let speaker: String
    let text: String
    let isYou: Bool

    init(id: UUID = UUID(), time: String, speaker: String, text: String, isYou: Bool) {
        self.id = id
        self.time = time
        self.speaker = speaker
        self.text = text
        self.isYou = isYou
    }
}

/// Consecutive entries of one voice, merged. A speaker who talks for a minute
/// produces a handful of windows; showing each as its own labelled line reads
/// like a telegraph, so the UI shows one block per turn.
struct TranscriptTurn: Identifiable {
    let id: UUID
    let speaker: String
    let isYou: Bool
    let time: String        // start of the turn
    let entries: [TranscriptEntry]
    var text: String { entries.map(\.text).joined(separator: " ") }
}

/// A transcript on disk.
struct ArchivedMeeting: Identifiable, Hashable {
    let id: URL             // the file is the identity
    let url: URL
    let started: Date       // file creation, i.e. session start
    let entries: [TranscriptEntry]

    var speakers: [String] {
        var seen = Set<String>(), ordered: [String] = []
        for e in entries where seen.insert(e.speaker).inserted { ordered.append(e.speaker) }
        return ordered
    }
    /// Wall-clock length, derived from the first and last entry stamps.
    var duration: TimeInterval? {
        guard let first = entries.first?.time, let last = entries.last?.time,
              let a = MeetingArchive.seconds(fromClock: first),
              let b = MeetingArchive.seconds(fromClock: last), b >= a else { return nil }
        return TimeInterval(b - a)
    }
    var preview: String {
        entries.first?.text ?? ""
    }
}

/// Reads, lists and edits the transcripts in ~/Documents/Dictate Meetings.
/// The Markdown files stay the source of truth — the app is a nice window
/// onto them, never a database that could disagree with what the user sees
/// in Finder.
enum MeetingArchive {

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate Meetings", isDirectory: true)
    }

    // MARK: - Parsing (pure — unit-tested)

    /// Entry lines look like `**[13:56:28] You:** text`; anything else is
    /// either the title or a continuation of the previous entry's text (a
    /// transcription can contain line breaks).
    static func parse(markdown: String, youLabel: String = L("You")) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let entry = parseEntryLine(line, youLabel: youLabel) {
                entries.append(entry)
            } else if line.hasPrefix("#") {
                continue                       // title
            } else if let last = entries.popLast() {
                entries.append(TranscriptEntry(id: last.id, time: last.time,
                                               speaker: last.speaker,
                                               text: last.text + " " + line,
                                               isYou: last.isYou))
            }
        }
        return entries
    }

    private static func parseEntryLine(_ line: String, youLabel: String) -> TranscriptEntry? {
        guard line.hasPrefix("**["), let close = line.range(of: "]") else { return nil }
        let time = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard seconds(fromClock: time) != nil else { return nil }
        let rest = line[close.upperBound...]
        guard let marker = rest.range(of: ":**") else { return nil }
        let speaker = rest[rest.startIndex..<marker.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let text = rest[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty else { return nil }
        return TranscriptEntry(time: time, speaker: speaker, text: text,
                               isYou: speaker == youLabel)
    }

    /// Merges consecutive entries of the same voice into one turn.
    static func turns(_ entries: [TranscriptEntry]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for entry in entries {
            if let last = turns.last, last.speaker == entry.speaker {
                turns[turns.count - 1] = TranscriptTurn(id: last.id, speaker: last.speaker,
                                                        isYou: last.isYou, time: last.time,
                                                        entries: last.entries + [entry])
            } else {
                turns.append(TranscriptTurn(id: entry.id, speaker: entry.speaker,
                                            isYou: entry.isYou, time: entry.time,
                                            entries: [entry]))
            }
        }
        return turns
    }

    /// "13:56:28" → seconds since midnight; nil when it isn't a clock.
    static func seconds(fromClock clock: String) -> Int? {
        let parts = clock.split(separator: ":")
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]),
              let s = Int(parts[2]), (0...23).contains(h),
              (0...59).contains(m), (0...59).contains(s) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// Rewrites one voice's label everywhere in a transcript's text. The
    /// speaker label sits between the timestamp and `:**`, so the rename is
    /// exact — no chance of touching the spoken words themselves.
    static func renaming(markdown: String, from old: String, to new: String) -> String {
        markdown.replacingOccurrences(of: "] \(old):**", with: "] \(new):**")
    }

    // MARK: - Disk

    static func list() -> [ArchivedMeeting] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let youLabel = L("You")
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> ArchivedMeeting? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? Date.distantPast
                return ArchivedMeeting(id: url, url: url, started: created,
                                       entries: parse(markdown: text, youLabel: youLabel))
            }
            .sorted { $0.started > $1.started }
    }

    @discardableResult
    static func rename(speaker old: String, to new: String, in url: URL) -> Bool {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != old,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let updated = renaming(markdown: text, from: old, to: clean)
        guard updated != text, (try? updated.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return false }
        Log.d("meeting: renamed \"\(old)\" -> \"\(clean)\" in \(url.lastPathComponent)")
        return true
    }

    static func delete(_ meeting: ArchivedMeeting) {
        try? FileManager.default.trashItem(at: meeting.url, resultingItemURL: nil)
        Log.d("meeting: moved \(meeting.url.lastPathComponent) to the trash")
    }
}
