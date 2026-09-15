import Foundation

/// The text of one report field, read as blocks: paragraphs and lists.
///
/// The model is asked to mark list items with "- " (MeetingReports.request),
/// but vendors improvise — "•", "*", "1.", an en dash — and reports written
/// before the rule exist too. One reading serves the card, the exports and
/// the PDF, so a list looks like a list everywhere, whatever the model typed.
enum ReportText {
    enum Block: Equatable {
        case paragraph(String)
        case list([String])
    }

    /// Lines into blocks: every marked line is an item, consecutive items
    /// one list; every other non-empty line its own paragraph — the model
    /// separates thoughts with line breaks, and a break it chose is kept.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var items: [String] = []
        func flushList() {
            if !items.isEmpty { out.append(.list(items)); items = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushList(); continue }
            if let item = listItem(line) {
                items.append(item)
            } else {
                flushList()
                out.append(.paragraph(line))
            }
        }
        flushList()
        return out
    }

    /// The item's text when the line carries a list marker, else nil.
    static func listItem(_ line: String) -> String? {
        for marker in ["- ", "• ", "* ", "– ", "— ", "· ", "-\t", "•\t"] where line.hasPrefix(marker) {
            let rest = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        // "1. " / "1) " — a number, a separator, a space.
        var digits = 0
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber, digits < 3 { digits += 1; index = line.index(after: index) }
        guard digits > 0, index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == " " else { return nil }
        let rest = line[index...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// The same text with every list item marked "- " — what a Markdown
    /// export carries.
    static func markdown(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case .paragraph(let p): return p
            case .list(let items): return items.map { "- \($0)" }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    /// The same text with bullets a plain-text reader sees as bullets.
    static func plain(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case .paragraph(let p): return p
            case .list(let items): return items.map { "• \($0)" }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }
}
