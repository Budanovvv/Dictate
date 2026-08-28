import Foundation

/// Feed it successive whole-buffer hypotheses; it answers which words are safe
/// to type — words that can never need erasing.
///
/// LocalAgreement-2 (Macháček 2023, arXiv:2307.14743, ufal/whisper_streaming;
/// the same rule WhisperKit's eager mode calls tokenConfirmationsNeeded = 2):
/// a word is confirmed when two consecutive decodes of the growing buffer put
/// it at the same place in their common prefix. The last word of that common
/// prefix is still held back as a seam — see `seam` below.
///
/// Words are compared NORMALIZED (lower case, no surrounding punctuation)
/// because Whisper flips case and punctuation between passes for text it is
/// otherwise sure about; what gets typed is always the form from the freshest
/// hypothesis. Comparison is POSITIONAL, never by value — "мама мыла раму,
/// раму, раму" must commit three separate "раму"s, not collapse them.
///
/// Nothing this engine hands out is ever taken back: the caller types into a
/// foreign app append-only, with no backspaces and no revisions.
final class CommitEngine {
    struct Update: Equatable {
        /// Text to type right now, "" when nothing became safe. Carries its own
        /// leading separator: the first commit of a dictation starts bare, every
        /// later one starts with the space that joins it to what is already in
        /// the document.
        let newlyCommitted: String
        /// Everything heard but not yet safe — for the HUD's gray tail. The
        /// committed part is deliberately absent: it already lives in the
        /// user's document.
        let volatileTail: String
    }

    /// Words of the agreed prefix kept back. One guards the boundary word (an
    /// audio cut mid-word can produce the same truncated fragment twice); the
    /// agreement of two passes already guards everything before it. Two felt
    /// safer but measurably lagged live typing by two extra words — UFAL's
    /// reference LocalAgreement-2 commits the full agreed prefix with no seam
    /// at all.
    private static let seam = 1

    /// Hold-back phrases, normalized and split into words.
    private let phrases: [[String]]
    private let maxPhraseWords: Int

    private(set) var committedText = ""
    /// Committed words as typed, and their normalized twins. Kept separately so
    /// alignment can compare normalized while the document keeps the raw form.
    private var committedRaw: [String] = []
    private var committedNorm: [String] = []
    /// The previous hypothesis minus everything already committed — one half of
    /// every LocalAgreement comparison, and what forceCommit() flushes.
    private var pendingRaw: [String] = []
    private var pendingNorm: [String] = []

    /// - Parameter holdBackPhrases: voice-command phrases. Words that form
    ///   the beginning of any of
    ///   these are held back from committing until the phrase either completes
    ///   or diverges, so that a phrase is always typed as ONE chunk: the caller
    ///   runs Replacements over each chunk, and a phrase split across two
    ///   chunks would leak into the document literally ("с новой строки"
    ///   instead of a line break).
    init(holdBackPhrases: [String]) {
        phrases = holdBackPhrases
            .map { Self.tokenize($0).map(\.norm).filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
        maxPhraseWords = phrases.map(\.count).max() ?? 0
    }

    // MARK: - Feeding hypotheses

    /// A new hypothesis over the whole (possibly trimmed) buffer.
    @discardableResult
    func ingest(hypothesis: String) -> Update {
        let tokens = Self.tokenize(hypothesis)
        // A decode that returned nothing (silence, a cancelled pass) is not
        // evidence about the tail — it must not wipe the agreement collected so
        // far, or the next hypothesis would start counting from zero again.
        guard !tokens.isEmpty else {
            return Update(newlyCommitted: "", volatileTail: pendingRaw.joined(separator: " "))
        }
        let norm = tokens.map(\.norm)
        let raw = tokens.map(\.raw)

        let start = alignmentOffset(norm)
        let candNorm = Array(norm[start...])
        let candRaw = Array(raw[start...])

        var agree = 0
        while agree < min(candNorm.count, pendingNorm.count),
              candNorm[agree] == pendingNorm[agree] { agree += 1 }
        let confirmed = max(0, agree - Self.seam)
        let take = holdBackCut(candNorm, limit: confirmed)

        let chunk = commit(raw: Array(candRaw[0..<take]), norm: Array(candNorm[0..<take]))
        pendingRaw = Array(candRaw[take...])
        pendingNorm = Array(candNorm[take...])
        // Counts only — dictation CONTENT never reaches the log (privacy).
        Log.d("commit: words=\(tokens.count) skip=\(start) agree=\(agree) "
              + "take=\(take) held=\(confirmed - take) pending=\(pendingRaw.count)")
        return Update(newlyCommitted: chunk, volatileTail: pendingRaw.joined(separator: " "))
    }

    /// VAD heard ≥0.5 s of silence — commit the whole tail, seam and held-back
    /// words included. A pause is the strongest agreement signal there is (the
    /// audio behind those words will not change any more), and a phrase the
    /// user interrupted with a pause was never a command: "с новой" followed by
    /// half a second of silence is two ordinary words.
    @discardableResult
    func forceCommit() -> Update {
        guard !pendingRaw.isEmpty else { return Update(newlyCommitted: "", volatileTail: "") }
        let chunk = commit(raw: pendingRaw, norm: pendingNorm)
        Log.d("commit: force +\(pendingRaw.count) words")
        pendingRaw = []
        pendingNorm = []
        return Update(newlyCommitted: chunk, volatileTail: "")
    }

    /// Recording ended and the full-pass text arrived: returns what still has to
    /// be typed after everything already committed, with its leading separator.
    ///
    /// The final text is produced by a different (whole-buffer, post-processed)
    /// pass, so it may disagree with what we already typed. We do NOT try to fix
    /// the past — nothing typed is ever erased. Instead the committed words are
    /// located in the final text as a fuzzy prefix (an anchor of up to eight
    /// trailing committed words, the occurrence closest to where it should be —
    /// which is what keeps repeated words apart) and only the suffix after that
    /// is returned. If the final text is shorter than what we typed, the answer
    /// is "" — never a negative slice, never a re-type.
    func finish(finalText: String) -> String {
        pendingRaw = []
        pendingNorm = []
        let tokens = Self.tokenize(finalText)
        guard !tokens.isEmpty else { return "" }
        let norms = tokens.map(\.norm)
        let start = reconcileStart(finalNorm: norms)

        // Cut right after the LETTERS of the last already-typed word, not after
        // its punctuation: the sentence-final "." that only the full pass heard
        // still has to be typed, and that is true even when no whole word is
        // left. If the document already ends with that same punctuation, drop
        // it instead of doubling it.
        let cut = start == 0 ? finalText.startIndex : tokens[start - 1].coreEnd
        var tail = String(finalText[cut...])
        if start > 0, let last = committedRaw.last {
            let already = Self.trailingPunctuation(last)
            if !already.isEmpty, tail.hasPrefix(already) { tail.removeFirst(already.count) }
        }
        if start >= tokens.count {
            tail = String(tail.reversed().drop(while: \.isWhitespace).reversed())
        }
        guard !tail.isEmpty else {
            Log.d("commit: finish adds nothing (committed=\(committedNorm.count) final=\(tokens.count))")
            return ""
        }
        if let first = tail.first, needsSeparator(before: first) { tail = " " + tail }

        committedText += tail
        // The document now ends with the full pass's form of that word (ours
        // may have lacked its punctuation) — remember it, or a second finish()
        // would type the same comma again.
        if start > 0, !committedRaw.isEmpty, start - 1 < tokens.count {
            committedRaw[committedRaw.count - 1] = tokens[start - 1].raw
        }
        committedRaw.append(contentsOf: tokens[start...].map(\.raw))
        committedNorm.append(contentsOf: norms[start...])
        Log.d("commit: finish +\(tokens.count - start) words")
        return tail
    }

    // MARK: - Committing

    private func commit(raw: [String], norm: [String]) -> String {
        guard !raw.isEmpty else { return "" }
        var chunk = raw.joined(separator: " ")
        if let first = chunk.first, needsSeparator(before: first) { chunk = " " + chunk }
        committedText += chunk
        committedRaw.append(contentsOf: raw)
        committedNorm.append(contentsOf: norm)
        return chunk
    }

    /// A space is needed between what the document already holds and what comes
    /// next — unless there is nothing yet, one side already brings whitespace,
    /// or the new text opens with punctuation that belongs to the previous word.
    private func needsSeparator(before first: Character) -> Bool {
        guard let last = committedText.last else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        return !(first.isPunctuation || first.isSymbol)
    }

    // MARK: - Hold-back

    /// How many of the first `limit` confirmed words may actually be committed:
    /// a trailing run that still reads as the beginning of a hold-back phrase
    /// stays behind. A COMPLETE phrase is held too — it leaves only once the
    /// next word proves the phrase is over, and then the whole run (phrase plus
    /// the word that ended it) goes out in one chunk for the caller's
    /// Replacements pass to rewrite.
    private func holdBackCut(_ norm: [String], limit: Int) -> Int {
        guard limit > 0, maxPhraseWords > 0 else { return limit }
        let lowest = max(0, limit - maxPhraseWords)
        for h in lowest..<limit where growsIntoPhrase(norm, from: h, confirmed: limit) { return h }
        return limit
    }

    /// Do the words from `h` on still read as the beginning of a hold-back
    /// phrase? Words the hypothesis heard past the confirmed prefix count as
    /// evidence too: "с самолётом" proves the phrase "с новой строки" is not
    /// coming, and there is nothing left to wait for.
    private func growsIntoPhrase(_ norm: [String], from h: Int, confirmed limit: Int) -> Bool {
        for phrase in phrases where phrase.count >= limit - h {
            let end = min(norm.count, h + phrase.count)
            if Array(norm[h..<end]) == Array(phrase.prefix(end - h)) { return true }
        }
        return false
    }

    // MARK: - Aligning a hypothesis against what is already typed

    /// How many leading words of a fresh hypothesis are text we have already
    /// committed. Normally that is the whole committed tail (the audio behind it
    /// is still in the buffer, so every pass re-transcribes it); when the caller
    /// has trimmed the buffer past our commit point the overlap is zero and the
    /// hypothesis starts with genuinely new speech.
    private func alignmentOffset(_ newNorm: [String]) -> Int {
        guard !committedNorm.isEmpty, !newNorm.isEmpty else { return 0 }
        let maxOverlap = min(committedNorm.count, newNorm.count)
        // Longest exact overlap first — with repeated words ("раму раму раму")
        // only the longest match lands on the right one.
        for l in stride(from: maxOverlap, through: 1, by: -1)
        where Array(committedNorm.suffix(l)) == Array(newNorm.prefix(l)) { return l }
        // Nothing matched exactly. A long overlap with a word or two re-decoded
        // inside it is still an overlap — accepting it keeps us from typing the
        // whole utterance a second time, which is the one unrecoverable mistake
        // an append-only writer can make.
        for l in stride(from: maxOverlap, through: 4, by: -1) {
            let diff = zip(committedNorm.suffix(l), newNorm.prefix(l))
                .reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            if diff <= max(1, l / 5) { return l }
        }
        return 0
    }

    /// Index of the first word of the final text that has not been typed yet.
    private func reconcileStart(finalNorm: [String]) -> Int {
        guard !committedNorm.isEmpty else { return 0 }
        guard !finalNorm.isEmpty else { return 0 }
        let expected = committedNorm.count
        let maxAnchor = min(committedNorm.count, min(finalNorm.count, 8))
        for k in stride(from: maxAnchor, through: 1, by: -1) {
            let anchor = Array(committedNorm.suffix(k))
            var best: Int?
            for i in 0...(finalNorm.count - k) where Array(finalNorm[i..<(i + k)]) == anchor {
                if best == nil || abs(i + k - expected) < abs(best! - expected) { best = i + k }
            }
            if let best { return best }
        }
        // The full pass agrees with us nowhere. Skip as many words as we typed
        // and take the rest: a wrong seam is a blemish, a duplicated dictation
        // is a disaster.
        return min(committedNorm.count, finalNorm.count)
    }

    // MARK: - Words

    struct Token {
        let raw: String
        let norm: String
        /// End of the word's letters — before any trailing punctuation.
        let coreEnd: String.Index
    }

    /// Whitespace-separated words with their place in the source string.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard !text[i].isWhitespace else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            var core = j
            while core > i, isTrimmable(text[text.index(before: core)]) {
                core = text.index(before: core)
            }
            tokens.append(Token(raw: String(text[i..<j]), norm: normalize(text[i..<j]), coreEnd: core))
            i = j
        }
        return tokens
    }

    /// Lower case, no surrounding punctuation, straight apostrophe: everything
    /// Whisper changes its mind about between passes while meaning the same word.
    static func normalize<S: StringProtocol>(_ word: S) -> String {
        var s = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        while let f = s.first, isTrimmable(f) { s.removeFirst() }
        while let l = s.last, isTrimmable(l) { s.removeLast() }
        return s
    }

    private static func isTrimmable(_ c: Character) -> Bool {
        c.isPunctuation || c.isSymbol
    }

    private static func trailingPunctuation(_ word: String) -> String {
        String(word.reversed().prefix(while: isTrimmable).reversed())
    }
}
