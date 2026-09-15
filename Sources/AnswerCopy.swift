import Foundation

/// What "Copy with quotes" puts on the clipboard (design 9.4 paste): the
/// answer, then the quotes with their meeting, date and moment, then one
/// line saying what wrote it and how far it looked. Markdown for editors
/// that read it, plain text for everything else.
enum AnswerCopy {
    @MainActor static func markdown(_ turn: AnswerTurn) -> String {
        var out = "**\(turn.question)**\n\n\(turn.text)\n"
        if !turn.quotes.isEmpty {
            out += "\n### \(L("Quotes"))\n\n"
            for (index, quote) in turn.quotes.enumerated() {
                out += "\(index + 1). **\(quote.meeting)** — \(when(quote.started)) · \(quote.speaker) \(quote.time)\n"
                out += "   > \(quote.text)\n"
            }
        }
        if let line = closingLine(turn) { out += "\n*\(line)*\n" }
        return out
    }

    @MainActor static func plain(_ turn: AnswerTurn) -> String {
        var out = "\(turn.text)\n"
        if !turn.quotes.isEmpty {
            out += "\n\(L("Quotes"))\n\n"
            for (index, quote) in turn.quotes.enumerated() {
                out += "\(index + 1). \(quote.meeting) — \(when(quote.started)), \(quote.speaker) at \(quote.time)\n"
                out += "   “\(quote.text)”\n"
            }
        }
        if let line = closingLine(turn) { out += "\n\(line)\n" }
        return out
    }

    /// "Answered by Claude from 3 of 38 meetings…" — only when the turn
    /// knows its reach (a conversation stored before 3.3.1 does not).
    @MainActor private static func closingLine(_ turn: AnswerTurn) -> String? {
        guard turn.archiveCount > 0, let provider = Settings.shared.askProvider else { return nil }
        return Lf("Answered by %@ from %d of %d meetings. Quotes are verbatim from transcripts on this Mac.",
                  provider.productName, turn.meetingsTouched, turn.archiveCount)
    }

    private static func when(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}
