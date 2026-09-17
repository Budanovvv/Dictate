import Foundation

/// A report as a meeting's file carries it: the template it was written
/// from, who wrote it, when, and one answer per field. An empty answer means
/// the call did not cover that field — the report shows "Not discussed"
/// there and never invents anything.
struct MeetingReport: Hashable, Sendable {
    struct Answer: Hashable, Sendable {
        /// The field as the template names it — what the CSV column and
        /// "already has one" are matched on.
        let field: String
        let text: String
        /// The heading as the report shows it: the field's name in the
        /// report's language (owner, 2026-09-15 — a Russian report under
        /// English headings read as two documents). nil when it is the
        /// field's own name.
        var heading: String? = nil
        var title: String { heading ?? field }
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    let templateID: UUID?
    let templateName: String
    /// The product that wrote it — "Claude", "ChatGPT" — for the byline.
    let writer: String
    let written: Date?
    let answers: [Answer]
}

extension MeetingArchive {

    // MARK: - The report block

    /// How a report reads in the file:
    ///
    ///     <!-- report: 3F2B… | Claude | 2026-09-14T14:05:00Z | Sales call -->
    ///     ## Report · Sales call
    ///
    ///     ### Client profile
    ///
    ///     Priya Nair, Head of Operations at Northwind…
    ///
    ///     ### Objections
    ///
    /// The comment is the marker the block is found by — NOT the heading,
    /// which is written in the interface language and can be a different
    /// string tomorrow. Field names are headings exactly as the person typed
    /// them; a field with nothing under it was not discussed.
    ///
    /// Safe next to the other parsers for the same reason the contents block
    /// is: no line here starts with `**[`, so nothing is an entry, and a plain
    /// line before the first entry has no previous entry to be glued onto.
    static let reportMarkerPrefix = "<!-- report:"

    /// Fresh per call: the formatter is not Sendable, and the block is
    /// written a few times a day.
    private static var reportDate: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static func reportMarker(_ report: MeetingReport) -> String {
        let id = report.templateID?.uuidString ?? "-"
        let when = report.written.map { reportDate.string(from: $0) } ?? "-"
        let name = report.templateName.replacingOccurrences(of: "-->", with: "—>")
        return "\(reportMarkerPrefix) \(id) | \(report.writer) | \(when) | \(name) -->"
    }

    static func isReportMarker(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).hasPrefix(reportMarkerPrefix)
    }

    private static func parseReportMarker(_ raw: String)
        -> (id: UUID?, writer: String, written: Date?, name: String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(reportMarkerPrefix), line.hasSuffix("-->") else { return nil }
        let inner = line.dropFirst(reportMarkerPrefix.count).dropLast(3)
            .trimmingCharacters(in: .whitespaces)
        let parts = inner.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4 else { return nil }
        return (UUID(uuidString: parts[0]), parts[1], reportDate.date(from: parts[2]), parts[3])
    }

    /// The report block as lines, ready to splice into a file.
    static func reportBlock(_ report: MeetingReport, heading: String) -> [String] {
        var lines = [reportMarker(report), "## \(heading) · \(report.templateName)", ""]
        for answer in report.answers {
            // The heading in the report's language; the template's own
            // name rides along in a comment when the two differ, so the
            // CSV column and "already written" still find the field.
            if let heading = answer.heading, heading != answer.field {
                lines.append("### \(heading) <!-- field: \(answer.field.replacingOccurrences(of: "-->", with: "—>")) -->")
            } else {
                lines.append("### \(answer.field)")
            }
            lines.append("")
            let text = cleanReportText(answer.text)
            if !text.isEmpty {
                lines.append(contentsOf: text.components(separatedBy: "\n"))
                lines.append("")
            }
        }
        return lines
    }

    /// A model's answer, made safe for the file: no line may look like a
    /// heading, a contents bullet or a transcript entry, or the other parsers
    /// would read the report as part of the meeting.
    static func cleanReportText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { raw -> String in
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("**[") || line.hasPrefix("- **[") {
                line = line.replacingOccurrences(of: "**[", with: "[")
            }
            if isReportMarker(line) { line = "" }
            return line
        }
        // Paragraphs survive; runs of blank lines collapse to one.
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Where each report block sits in `lines`: from its marker to the line
    /// before whatever follows it — the next report, the contents block,
    /// the first entry, a heading that is not one of the report's own.
    private static func reportRanges(in lines: [String])
        -> [(range: Range<Int>, id: UUID?, name: String?)] {
        var out: [(Range<Int>, UUID?, String?)] = []
        var start: Int? = nil
        var sawHeading = false
        func close(_ end: Int) {
            guard let from = start else { return }
            var to = end
            while to > from + 1, lines[to - 1].trimmingCharacters(in: .whitespaces).isEmpty { to -= 1 }
            let marker = parseReportMarker(lines[from])
            out.append((from..<to, marker?.id, marker?.name))
            start = nil
        }
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isReportMarker(line) {
                close(index)
                start = index
                sawHeading = false
                continue
            }
            guard start != nil else { continue }
            if line.hasPrefix("**[") || isSectionLine(line) || line.hasPrefix("# ") {
                close(index)
            } else if line.hasPrefix("## ") {
                if sawHeading { close(index) } else { sawHeading = true }
            }
        }
        close(lines.count)
        return out
    }

    /// Every report in the file, in the order they were written.
    static func parseReports(markdown: String) -> [MeetingReport] {
        let lines = markdown.components(separatedBy: .newlines)
        return reportRanges(in: lines).compactMap { parseReport(lines: lines, in: $0.range) }
    }

    /// The first report in the file, when there is one.
    static func parseReport(markdown: String) -> MeetingReport? {
        parseReports(markdown: markdown).first
    }

    private static func parseReport(lines: [String], in range: Range<Int>) -> MeetingReport? {
        guard let marker = parseReportMarker(lines[range.lowerBound]) else { return nil }
        var answers: [MeetingReport.Answer] = []
        var field: String?
        var heading: String?
        var body: [String] = []
        func flush() {
            if let field {
                let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                answers.append(.init(field: field, text: text, heading: heading))
            }
            body = []
        }
        for raw in lines[(range.lowerBound + 1)..<range.upperBound] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                flush()
                let title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                // "### Решения <!-- field: Decisions -->": the heading shown,
                // the field it answers.
                if let open = title.range(of: " <!-- field: "), title.hasSuffix("-->") {
                    heading = String(title[..<open.lowerBound])
                    field = String(title[open.upperBound...].dropLast(3)).trimmingCharacters(in: .whitespaces)
                } else {
                    heading = nil
                    field = title
                }
            } else if line.hasPrefix("## ") {
                continue
            } else if field != nil {
                body.append(line)
            }
        }
        flush()
        return MeetingReport(templateID: marker.id, templateName: marker.name,
                             writer: marker.writer, written: marker.written, answers: answers)
    }

    /// Writes the report block. A report from the same template replaces
    /// the one already there; a report from another template goes in after
    /// the last one — a meeting can carry one report per template. The
    /// first block goes after the summary and before the contents block:
    /// everything that describes the meeting as a whole, then the reports,
    /// then the map of the transcript, then the transcript.
    static func applying(report: MeetingReport, heading: String, to markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        let block = reportBlock(report, heading: heading)
        let existing = reportRanges(in: lines)
        // The same report is the template's id OR its name — the card, the
        // collection and "already written" all say so (hasReport, haveOne):
        // a template deleted and made again under the same name has a new
        // id and is still that report. Matching the id alone appended a
        // second block under the same heading while the dialog promised a
        // replacement (shipped in 3.3.1, audit of 2026-09-17). The block
        // with the matching id survives when there is one, the first by
        // name otherwise; every other match goes, so a file already holding
        // two such blocks heals on its next write.
        let matches = existing.indices.filter {
            let r = existing[$0]
            return (r.id != nil && r.id == report.templateID) || r.name == report.templateName
        }
        if let survivor = matches.first(where: { existing[$0].id != nil && existing[$0].id == report.templateID })
            ?? matches.first {
            var drop = IndexSet()
            for i in matches where i != survivor {
                var upper = existing[i].range.upperBound
                while upper < lines.count, lines[upper].trimmingCharacters(in: .whitespaces).isEmpty {
                    upper += 1
                }
                drop.insert(integersIn: existing[i].range.lowerBound..<upper)
            }
            let kept = existing[survivor].range
            var out: [String] = []
            for (index, line) in lines.enumerated() where !drop.contains(index) {
                if index == kept.lowerBound { out.append(contentsOf: block) }
                if kept.contains(index) { continue }
                out.append(line)
            }
            return out.joined(separator: "\n")
        }
        guard let h1 = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return markdown }
        var at = lines.count
        if let last = existing.last {
            at = last.range.upperBound
        } else if let bullet = lines.indices.first(where: { isSectionLine(lines[$0]) }) {
            var above = bullet - 1
            while above > h1, lines[above].trimmingCharacters(in: .whitespaces).isEmpty { above -= 1 }
            at = lines[above].hasPrefix("#") && above > h1 ? above : bullet
        } else if let entry = lines[(h1 + 1)...].firstIndex(where: { $0.hasPrefix("**[") }) {
            at = entry
        }
        // A blank line either side, so the block is its own paragraph.
        var insert = block + [""]
        if at > 0, !lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insert.insert("", at: 0)
        }
        lines.insert(contentsOf: insert, at: at)
        return lines.joined(separator: "\n")
    }

    /// Removes one template's report, or every report when `templateID`
    /// is nil.
    static func removingReport(from markdown: String, templateID: UUID? = nil) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        let ranges = reportRanges(in: lines)
            .filter { templateID == nil || $0.id == templateID }
            .map(\.range)
            .sorted { $0.lowerBound > $1.lowerBound }
        guard !ranges.isEmpty else { return markdown }
        for range in ranges {
            var upper = range.upperBound
            while upper < lines.count, lines[upper].trimmingCharacters(in: .whitespaces).isEmpty {
                upper += 1
            }
            lines.removeSubrange(range.lowerBound..<upper)
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    static func setReport(_ report: MeetingReport, heading: String, in url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let updated = applying(report: report, heading: heading, to: text)
        guard updated != text else { return true }
        return rewrite(url, with: updated)
    }

    @discardableResult
    static func removeReport(in url: URL, templateID: UUID? = nil) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let updated = removingReport(from: text, templateID: templateID)
        guard updated != text else { return true }
        return rewrite(url, with: updated)
    }
}
