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
    /// The stamps of the entries this one swallowed when the transcript was
    /// cleaned up for reading (TranscriptCleanup) — empty for an entry as the
    /// file has it, which is every entry until then.
    ///
    /// Load-bearing rather than bookkeeping: the contents block, the search
    /// index and every section hit point at the stamp the FILE carries, and a
    /// merged paragraph shows only the first of them. Without this, opening a
    /// transcript at 10:26:17 would find nothing the moment 10:26:17 became
    /// the second sentence of a paragraph that starts at 10:26:04.
    let absorbed: [String]

    init(id: UUID = UUID(), time: String, speaker: String, text: String, isYou: Bool,
         absorbed: [String] = []) {
        self.id = id
        self.time = time
        self.speaker = speaker
        self.text = text
        self.isYou = isYou
        self.absorbed = absorbed
    }

    /// Every clock stamp this entry now speaks for, its own first.
    var covers: [String] { absorbed.isEmpty ? [time] : [time] + absorbed }

    func speaks(for clock: String) -> Bool {
        time == clock || absorbed.contains(clock)
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

    /// True when one of the stamps the FILE carries falls inside this turn —
    /// including the ones a cleaned-up paragraph swallowed. This is how a
    /// section hit ("open at 10:26:17") finds where to land once the transcript
    /// is read as paragraphs rather than as windows.
    func speaks(for clock: String) -> Bool {
        entries.contains { $0.speaks(for: clock) }
    }
}

/// One stretch of a meeting — a few minutes of it — and the English line the
/// on-device model wrote about it.
///
/// The unit that makes an archive answerable. A meeting carries ONE summary
/// for its whole hour, which is too coarse to find anything by: the three
/// minutes the owner is looking for are not in it. A section is small enough
/// to describe honestly, small enough to feed to a model whose window is 4096
/// tokens, and — because it carries the timestamp it starts at — small enough
/// to be a place rather than a document.
struct TranscriptSection: Equatable, Hashable {
    /// "10:26:17", the stamp of the entry the section starts at, so a hit can
    /// be turned back into a position in the transcript.
    let time: String
    /// What was discussed there, in English, always — see MeetingSectioner.
    let line: String
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
    /// The contents block: a line per few minutes, with the moment it starts
    /// at. Empty for a meeting too short to have one, and for every meeting
    /// recorded before sections existed until the backfill reaches it.
    var sections: [TranscriptSection] = []
    /// The owner's own classification of this meeting — the axis neither the
    /// words nor the speakers can answer (which product, which engagement).
    /// Read from the file, like everything else here.
    var tags: [String] = []
    /// The platform the call ran on ("Zoom", "Google Meet"), written once at
    /// creation as an invisible comment in the header. nil for everything
    /// recorded before the field existed and for unidentified browser calls —
    /// the library's "other" bucket.
    var source: String? = nil

    /// What this meeting IS, independent of the objects carrying it.
    ///
    /// Reading the folder mints a fresh `ArchivedMeeting` — and fresh UUIDs
    /// inside every entry — for all 37 transcripts, whether or not anything in
    /// them changed. Struct equality therefore reports "different" for a file
    /// nobody touched, and everything downstream believes it: the view
    /// rebuilds, the summary above the reader changes height, and the place
    /// they were reading moves. Comparing what the file SAYS is how a reload
    /// can leave untouched meetings alone.
    func sameContent(as other: ArchivedMeeting) -> Bool {
        url == other.url && title == other.title && summary == other.summary
            && tags == other.tags && sections == other.sections
            && entries.count == other.entries.count
            && zip(entries, other.entries).allSatisfy {
                $0.time == $1.time && $0.speaker == $1.speaker && $0.text == $1.text
            }
    }

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
    /// The platform comment written at creation — `<!-- source: Zoom -->`.
    /// Header-only, like tags: the string "source:" inside spoken text must
    /// never become a platform.
    static func parseSource(markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix(8) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<!-- source:"), trimmed.hasSuffix("-->") else { continue }
            let body = trimmed.dropFirst("<!-- source:".count).dropLast("-->".count)
            let source = body.trimmingCharacters(in: .whitespaces)
            return source.isEmpty ? nil : source
        }
        return nil
    }

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

    // MARK: - The contents block

    /// How a section reads in the file:
    ///
    ///     ## Contents
    ///
    ///     - **[10:26:17]** Yury wants a simple database for the demo
    ///
    /// A bullet, so a Markdown reader lays it out as the list it is; the time
    /// in the same `**[…]**` shape the entries below use, so the eye connects
    /// the two without being told.
    static func sectionLine(_ section: TranscriptSection) -> String {
        "- **[\(section.time)]** \(section.line)"
    }

    /// True for one of our own contents bullets. This is the marker the block
    /// is found by — NOT the heading above it, which is written in the user's
    /// interface language and can therefore be a different string tomorrow
    /// than it was yesterday.
    static func isSectionLine(_ raw: String) -> Bool {
        parseSectionLine(raw.trimmingCharacters(in: .whitespaces)) != nil
    }

    private static func parseSectionLine(_ line: String) -> TranscriptSection? {
        guard line.hasPrefix("- **["), let close = line.range(of: "]**") else { return nil }
        let start = line.index(line.startIndex, offsetBy: 5)
        let time = String(line[start..<close.lowerBound])
        guard seconds(fromClock: time) != nil else { return nil }
        let text = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return TranscriptSection(time: time, line: text)
    }

    /// The contents block as the file has it.
    ///
    /// Safe to keep in the transcript for the same reason the summary is: an
    /// entry is the only line that starts with `**[`, so a bullet is not an
    /// entry, and a plain line before the first entry has no previous entry
    /// for `parse` to glue it onto. Proven by round-trip test rather than by
    /// that argument — see MeetingArchiveTests.
    static func parseSections(markdown: String) -> [TranscriptSection] {
        var sections: [TranscriptSection] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Only ever the block at the top: an entry means the transcript
            // has begun and nothing below is contents.
            if line.hasPrefix("**[") { break }
            if let section = parseSectionLine(line) { sections.append(section) }
        }
        return sections
    }

    /// Writes the contents block under the summary, replacing one already
    /// there. Empty sections leave the file alone — which is what retitling
    /// and renaming a speaker need, so neither can throw the block away.
    static func applying(sections: [TranscriptSection], heading: String,
                         to markdown: String) -> String {
        guard !sections.isEmpty else { return markdown }
        var lines = markdown.components(separatedBy: .newlines)
        // Where the old block was, heading included: the bullets, plus a
        // heading line immediately above the first of them (in whatever
        // language it was written).
        let existing = lines.indices.filter { isSectionLine(lines[$0]) }
        if let first = existing.first, let last = existing.last {
            var from = first
            var above = first - 1
            while above >= 0, lines[above].trimmingCharacters(in: .whitespaces).isEmpty {
                above -= 1
            }
            if above >= 0, lines[above].hasPrefix("#") { from = above }
            lines.replaceSubrange(from...last, with: block(sections, heading: heading))
            return lines.joined(separator: "\n")
        }
        // No block yet: it goes after the title, the date and the summary —
        // everything that describes the meeting as a whole — and before the
        // first entry.
        guard let h1 = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return markdown }
        var at = lines.count
        for index in (h1 + 1)..<lines.count where lines[index].hasPrefix("**[") {
            at = index
            break
        }
        lines.insert(contentsOf: block(sections, heading: heading) + [""], at: at)
        return lines.joined(separator: "\n")
    }

    private static func block(_ sections: [TranscriptSection], heading: String) -> [String] {
        ["## \(heading)", ""] + sections.map(sectionLine)
    }

    @discardableResult
    static func setSections(_ sections: [TranscriptSection], heading: String,
                            in url: URL) -> Bool {
        guard !sections.isEmpty,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let updated = applying(sections: sections, heading: heading, to: text)
        guard updated != text else { return false }
        return rewrite(url, with: updated)
    }

    /// The entries of each section, in order — the bridge between the pure cut
    /// rule and the transcript it is cut from. Empty when the meeting is too
    /// short to be worth sectioning at all.
    static func sectionRanges(of entries: [TranscriptEntry],
                              detail: MeetingPolicy.SectionDetail = Settings.shared.sectionDetail)
        -> [Range<Int>] {
        let marks = entries.map { entry in
            MeetingPolicy.SectionMark(
                start: Double(seconds(fromClock: entry.time) ?? 0),
                speaker: entry.speaker,
                words: entry.text.split(whereSeparator: \.isWhitespace).count,
                endsSentence: endsSentence(entry.text),
                startsSentence: startsSentence(entry.text))
        }
        let starts = MeetingPolicy.sectionStarts(marks, target: detail.target,
                                                 minimum: detail.minimum,
                                                 maximum: detail.maximum)
        guard !starts.isEmpty else { return [] }
        return starts.indices.map { i in
            starts[i]..<(i + 1 < starts.count ? starts[i + 1] : entries.count)
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?…。？！".contains(last)
    }

    /// The first LETTER is a capital. Asked of letters only, so a line opening
    /// with a dash or a number is judged on the word that follows it; and true
    /// for Cyrillic as readily as for Latin, which matters because half of this
    /// archive is Russian.
    private static func startsSentence(_ text: String) -> Bool {
        guard let first = text.first(where: \.isLetter) else { return false }
        return first.isUppercase
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

    /// The transcript as it is READ: the file's windows cleaned up into
    /// paragraphs (TranscriptCleanup) and then grouped by voice. The file
    /// itself is untouched — this is the view, computed every time.
    static func readable(_ entries: [TranscriptEntry]) -> [TranscriptTurn] {
        turns(TranscriptCleanup.clean(entries))
    }

    /// Where a moment from the contents block lands once the transcript is
    /// read as paragraphs — the join between Phase A (which cuts sections from
    /// the FILE's entries) and the cleanup (which reads them as turns).
    ///
    /// The two agree far more often than they had to. A section boundary is
    /// scored by `MeetingPolicy.seam`, which rewards exactly the two things
    /// that also STOP a paragraph — the speaker changing, and the next line
    /// opening on a capital — so a section usually starts where a paragraph
    /// starts. Measured over the whole archive (25 sections in 18 transcripts):
    /// 23 land on the paragraph that begins at the section's own stamp, and
    /// none is missed.
    ///
    /// The other two land EARLY, by 6 s and by 16 s, and early is the only
    /// direction this can err in:
    ///
    ///  * the stamp is inside a merged paragraph → the paragraph that speaks
    ///    for it, whose first line is up to one window (15 s) earlier per
    ///    swallowed entry. The reader is not lost: that whole paragraph is the
    ///    one the jump highlights, and the section's own moment is inside it.
    ///  * the stamp belonged to an entry the cleanup dropped (a phantom) →
    ///    nothing speaks for it, so the next paragraph takes it instead.
    ///    That one lands late, by less than a window; it has never happened in
    ///    the archive, because a section never starts on a phantom.
    ///
    /// nil only when the transcript has nothing at or after that time at all —
    /// a hand-edited file, and then the transcript simply opens at the top.
    static func turn(at clock: String, in turns: [TranscriptTurn]) -> TranscriptTurn? {
        if let exact = turns.first(where: { $0.speaks(for: clock) }) { return exact }
        guard let wanted = seconds(fromClock: clock) else { return nil }
        return turns.first { (seconds(fromClock: $0.time) ?? .min) >= wanted }
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

    /// `youLabel` is taken as a parameter so a background caller can capture
    /// it on the main thread first — the localization table is not something
    /// to read while the user may be switching languages on main.
    static func list(youLabel: String) -> [ArchivedMeeting] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
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
                                       summary: parseSummary(markdown: text),
                                       sections: parseSections(markdown: text),
                                       tags: MeetingTags.parse(markdown: text),
                                       source: parseSource(markdown: text))
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
        // The file may ALREADY have the name being asked for — a meeting named
        // from the calendar is created under its final name at session start,
        // and the end-of-session pass then asks for the same one. Without this
        // the collision suffix treats the file as its own rival and renames
        // "Product Daily" to "Product Daily 2" (caught the day calendar naming
        // landed).
        let ideal = fileName(stamp: stamp, title: title)
        guard ideal != url.lastPathComponent else { return url }
        let wanted = uniqueName(ideal) {
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

    /// Replaces a transcript's tags with `tags`.
    @discardableResult
    static func setTags(_ tags: [String], in url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let updated = MeetingTags.applying(tags, to: text)
        guard updated != text else { return true }
        return rewrite(url, with: updated)
    }

    /// Renames one tag everywhere in the archive.
    ///
    /// The escape valve the research says a vocabulary cannot live without: a
    /// term WILL fork eventually — a typo, a change of mind about what the
    /// engagement is called — and a system with no way to merge two tags is a
    /// system whose answers quietly get worse. Cheap here because a tag lives
    /// in the file, so merging is a rewrite of a header line, not a migration.
    ///
    /// Returns how many transcripts changed.
    @discardableResult
    static func renameTag(from old: String, to new: String) -> Int {
        guard let from = MeetingTags.normalize(old),
              let to = MeetingTags.normalize(new), from != to else { return 0 }
        var changed = 0
        for meeting in list(youLabel: L("You")) where meeting.tags.contains(from) {
            // Through `unique` so renaming onto an existing tag MERGES rather
            // than writing it twice.
            let updated = MeetingTags.unique(meeting.tags.map { $0 == from ? to : $0 })
            if setTags(updated, in: meeting.url) { changed += 1 }
        }
        Log.d("tags: renamed #\(from) -> #\(to) in \(changed) transcript(s)")
        return changed
    }

    /// Every tag in the archive with how many meetings carry it — what
    /// completion offers, so the familiar tag is the easy one to type.
    static func tagCounts(in meetings: [ArchivedMeeting]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for m in meetings { for t in m.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (tag: $0.key, count: $0.value) }
    }

    static func delete(_ meeting: ArchivedMeeting) {
        try? FileManager.default.trashItem(at: meeting.url, resultingItemURL: nil)
        Log.d("meeting: moved \(meeting.url.lastPathComponent) to the trash")
    }
}
