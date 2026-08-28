import Foundation

/// Which parts of a generated answer are actually backed by the quotes shown
/// under it.
///
/// The answer pane's promise is "answers cite the transcript", but prose and
/// evidence rendered alike make the supported and the invented sentence look
/// identical (design review 2026-08-27). This policy marks the sentences whose
/// words demonstrably come from a quote; the view underlines them dotted and
/// says what the rest is.
///
/// A heuristic, deliberately conservative: a sentence counts as supported when
/// most of its content words appear in a single quote. Under-marking is the
/// safe failure — an unmarked true sentence loses emphasis, a marked invented
/// one would borrow trust it never earned. Dependency-free so it unit-tests in
/// the plain test target.
enum AnswerSupportPolicy {

    /// Sentence ranges of `answer` supported by at least one of `quotes`.
    static func supportedRanges(in answer: String, quotes: [String]) -> [Range<String.Index>] {
        guard !answer.isEmpty, !quotes.isEmpty else { return [] }
        let quoteTokenSets = quotes.map { Set(tokens($0)) }.filter { !$0.isEmpty }
        guard !quoteTokenSets.isEmpty else { return [] }

        var supported: [Range<String.Index>] = []
        answer.enumerateSubstrings(in: answer.startIndex..<answer.endIndex,
                                   options: .bySentences) { _, range, _, _ in
            // Unique tokens — a repeated "the" must not vote twice.
            let sentenceTokens = Set(tokens(String(answer[range])))
            // Too short to judge: three content words match half the archive.
            guard sentenceTokens.count >= 4 else { return }
            let needed = Int((Double(sentenceTokens.count) * 0.6).rounded(.up))
            for quoteSet in quoteTokenSets {
                let hits = sentenceTokens.intersection(quoteSet).count
                if hits >= needed {
                    supported.append(range)
                    return
                }
            }
        }
        return supported
    }

    /// Lowercased content words — 3+ characters, letters and digits only, so
    /// punctuation and the tiny glue words ("a", "of", "и") don't vote.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }
}
