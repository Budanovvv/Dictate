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
    /// What the meeting was about, when the on-device model managed to name
    /// it; nil means the meeting is known by its date alone.
    let title: String?
    /// One sentence saying what the meeting was about, written into the file
    /// when the meeting was named. nil until the model has said something
    /// usable about it — the library then shows nothing on that line.
    let summary: String?

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

    /// Every word Dictate has ever written for the owner's own turns.
    ///
    /// A transcript records the owner under the word that was current WHEN IT
    /// WAS WRITTEN — "You" for a call recorded in English, "Вы" for one
    /// recorded in Russian — and it keeps that word forever, because the file
    /// is the source of truth and nothing rewrites it. Deciding "is this the
    /// owner?" by comparing with `L("You")`, the CURRENT interface language,
    /// therefore breaks every older transcript the moment the language is
    /// switched: caught live while shooting the German UI, where every English
    /// "You" became a stranger, took a colour out of the speaker palette and
    /// painted the owner as someone else.
    ///
    /// So the question is asked of all eleven shipped words at once, and the
    /// answer no longer depends on which language the window happens to be in.
    /// (A real participant renamed by hand to exactly one of these words would
    /// be mistaken for the owner. That is a stranger typing "Вы" as a person's
    /// name — a price worth paying for an archive that reads correctly.)
    static let youLabels: Set<String> = {
        var labels: Set<String> = ["You"]
        for language in AppLanguage.allCases where language != .system {
            labels.insert(Localization.shared.string("You", in: language))
        }
        return labels
    }()

    /// Entry lines look like `**[13:56:28] You:** text`; anything else is
    /// either the title, the summary, or a continuation of the previous
    /// entry's text (a transcription can contain line breaks).
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
                               isYou: speaker == youLabel || youLabels.contains(speaker))
    }

    /// A named transcript looks like
    ///
    ///     # Release planning
    ///     _August 10, 2026 at 9:17 AM_
    ///
    /// while an unnamed one keeps the original date header. The italic date
    /// line is what tells them apart — a format we write ourselves, so the
    /// test is exact instead of guessing whether an H1 "looks like" a date
    /// in whatever language it was written.
    static func parseTitle(markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, lines[0].hasPrefix("# "),
              lines[1].hasPrefix("_"), lines[1].hasSuffix("_"), lines[1].count > 2
        else { return nil }
        let title = String(lines[0].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// A summary lives in the file, on its own line under the italic date:
    ///
    ///     # Release planning
    ///     _August 10, 2026 at 9:17 AM_
    ///
    ///     2.4 slipped a week — notarization still fails on the CI box.
    ///
    ///     **[09:17:52] You:** …
    ///
    /// In the file rather than in a database beside it, for the same reason
    /// the title is: renaming in Finder, editing by hand and reading the
    /// transcript in any Markdown app all keep working, and nothing can
    /// disagree with what the user sees.
    ///
    /// It is safe there because entry lines are the only lines that begin with
    /// `**[`: a plain line before the first entry is not an entry, and the
    /// continuation rule that would otherwise glue it to the previous entry
    /// has no previous entry to glue it to. See `parse`.
    static func parseSummary(markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3, lines[0].hasPrefix("# "),
              lines[1].hasPrefix("_"), lines[1].hasSuffix("_"), lines[1].count > 2,
              isSummaryLine(lines[2]) else { return nil }
        return lines[2]
    }

    /// A line that is neither an entry, nor a heading, nor the italic date —
    /// which, in the third position of one of our files, is the summary.
    private static func isSummaryLine(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        return !line.isEmpty && !line.hasPrefix("**[")
            && !line.hasPrefix("#") && !line.hasPrefix("_")
    }

    /// Writes the summary under the date line, replacing one already there.
    /// `nil` leaves the file alone — which is what retitling needs, so that
    /// renaming a meeting never silently throws its summary away.
    static func applying(summary: String?, to markdown: String) -> String {
        guard let summary, !summary.trimmingCharacters(in: .whitespaces).isEmpty else {
            return markdown
        }
        let clean = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var lines = markdown.components(separatedBy: .newlines)
        // Only a titled transcript has the italic date line to hang it under;
        // an unnamed one has no place to put it and is left as it is.
        guard let h1 = lines.firstIndex(where: { $0.hasPrefix("# ") }),
              let date = lines[(h1 + 1)...].firstIndex(where: {
                  !$0.trimmingCharacters(in: .whitespaces).isEmpty
              }),
              lines[date].hasPrefix("_"), lines[date].hasSuffix("_")
        else { return markdown }
        if let next = lines[(date + 1)...].firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }), isSummaryLine(lines[next]) {
            lines[next] = clean
            return lines.joined(separator: "\n")
        }
        // A blank line either side, so the summary is its own paragraph in a
        // Markdown reader instead of running on from the date.
        let blankFollows = date + 1 < lines.count
            && lines[date + 1].trimmingCharacters(in: .whitespaces).isEmpty
        if blankFollows {
            lines.insert(contentsOf: [clean, ""], at: date + 2)
        } else {
            lines.insert(contentsOf: ["", clean, ""], at: date + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Puts a title on a transcript, keeping the date visible underneath.
    static func applying(title: String, dateLine: String, to markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        guard let h1 = lines.firstIndex(where: { $0.hasPrefix("# ") }) else {
            return "# \(title)\n_\(dateLine)_\n\n" + markdown
        }
        lines[h1] = "# \(title)"
        // Replace an existing italic date line, or add one.
        let next = lines[(h1 + 1)...].firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let next, lines[next].hasPrefix("_"), lines[next].hasSuffix("_") {
            lines[next] = "_\(dateLine)_"
        } else {
            lines.insert("_\(dateLine)_", at: h1 + 1)
        }
        return lines.joined(separator: "\n")
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
                let created = startedDate(fileName: url.lastPathComponent)
                    ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    ?? Date.distantPast
                return ArchivedMeeting(id: url, url: url, started: created,
                                       entries: parse(markdown: text, youLabel: youLabel),
                                       title: parseTitle(markdown: text),
                                       summary: parseSummary(markdown: text))
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

    /// When the meeting happened, read from the file NAME. The name carries
    /// the stamp we wrote at the start of the session and survives every
    /// later edit; the file's creation date does not — an atomic rewrite
    /// (which is how a title is saved) resets it, and once did, making every
    /// transcript claim it was recorded the minute it was retitled.
    static func startedDate(fileName: String) -> Date? {
        var name = fileName
        for prefix in ["Meeting "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        let stamp = String(name.prefix(16))          // yyyy-MM-dd HH.mm
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.date(from: stamp)
    }

    /// `2026-08-10 09.17 — Release planning` — the date stays in front so
    /// sorting by name is still sorting by time, which is the order meetings
    /// actually have. Characters the file system can't take are replaced,
    /// never dropped silently.
    static func fileName(stamp: String, title: String?, maxTitle: Int = 60) -> String {
        guard let title else { return "\(stamp).md" }
        var clean = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .components(separatedBy: .newlines).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if clean.count > maxTitle {
            clean = String(clean.prefix(maxTitle)).trimmingCharacters(in: .whitespaces)
        }
        guard !clean.isEmpty else { return "\(stamp).md" }
        return "\(stamp) — \(clean).md"
    }

    /// Same name, minus collisions: " 2", " 3"… Two meetings can share a
    /// title ("Weekly standup") but never a minute, so this is a formality —
    /// which is exactly why it must not be forgotten.
    static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let base = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        for n in 2...99 {
            let candidate = "\(base) \(n).md"
            if !taken(candidate) { return candidate }
        }
        return name
    }

    /// Renames the transcript to match its new title, returning the new URL
    /// (or the old one when the rename isn't possible). The file's content is
    /// the source of truth — the name is a courtesy to Finder, so a failure
    /// here is logged and shrugged off.
    static func renameFile(at url: URL, stamp: String, title: String) -> URL {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let wanted = uniqueName(fileName(stamp: stamp, title: title)) {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard wanted != url.lastPathComponent else { return url }
        let target = directory.appendingPathComponent(wanted)
        do {
            try fm.moveItem(at: url, to: target)
            Log.d("meeting: file renamed -> \(wanted)")
            return target
        } catch {
            Log.d("meeting: rename failed (\(error.localizedDescription)) — keeping \(url.lastPathComponent)")
            return url
        }
    }

    /// Gives a finished meeting a new name: the title inside the file (the
    /// source of truth) and then the file name to match. Returns where the
    /// transcript lives now — the caller must follow it, since the URL is
    /// the meeting's identity.
    static func retitle(_ meeting: ArchivedMeeting, to title: String) -> URL {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != meeting.title else { return meeting.url }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let dateLine = DateFormatter.localizedString(from: meeting.started,
                                                     dateStyle: .long, timeStyle: .short)
        guard setTitle(clean, dateLine: dateLine, in: meeting.url) else { return meeting.url }
        return renameFile(at: meeting.url, stamp: stamp.string(from: meeting.started), title: clean)
    }

    /// Writes the title, and — when the model produced one in the same breath
    /// — the summary that goes under it.
    @discardableResult
    static func setTitle(_ title: String, dateLine: String, summary: String? = nil,
                         in url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let titled = applying(title: title, dateLine: dateLine, to: text)
        return rewrite(url, with: applying(summary: summary, to: titled))
    }

    @discardableResult
    static func setSummary(_ summary: String, in url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let updated = applying(summary: summary, to: text)
        guard updated != text else { return false }
        return rewrite(url, with: updated)
    }

    /// Replaces a transcript's content in place.
    ///
    /// An atomic write replaces the FILE, so the original creation date has to
    /// be carried over deliberately — Finder sorts by it, and a transcript
    /// that claims to be from the moment it was retitled is a small lie about
    /// the user's own history.
    private static func rewrite(_ url: URL, with updated: String) -> Bool {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        guard (try? updated.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        if let created {
            try? FileManager.default.setAttributes([.creationDate: created],
                                                   ofItemAtPath: url.path)
        }
        return true
    }

    static func delete(_ meeting: ArchivedMeeting) {
        try? FileManager.default.trashItem(at: meeting.url, resultingItemURL: nil)
        Log.d("meeting: moved \(meeting.url.lastPathComponent) to the trash")
    }
}
