import Foundation

/// Turns the recognizer's output back into a conversation — mechanically, and
/// without a language model anywhere near it.
///
/// WHY THIS IS NOT A LANGUAGE PROBLEM. A transcript reads as torn scraps for
/// reasons that are entirely mechanical: the meeting pipeline cuts each
/// channel's audio into windows at a VAD pause OR at a 15-second hard cap
/// (MeetingPolicy.windowVerdict), and every window becomes its own line in the
/// file. A cap-cut lands wherever the fifteenth second lands — usually inside a
/// sentence — so the file shows a line trailing off mid-clause and the next one
/// opening in lower case. Around those sit lines the recognizer emits on
/// near-silence: a bare full stop, a bare "you", a hum. None of that is
/// anything the speakers did, and none of it needs a model to undo: the seams
/// are visible in the punctuation and in the speaker labels the file already
/// carries.
///
/// WHY THERE IS NO MODEL HERE. This project shipped an LLM polish pass over
/// dictated text and removed it (CONTEXT 5п, GRABLI "LLM-полировка"): the
/// verdict was that post-processing by a model changes CONTENT, and dictation
/// has to hand back the words the person said. The same verdict binds a
/// transcript twice over, because a transcript is a record of a conversation
/// that other people were in. So every rule below is deterministic, decidable
/// by eye from the two entries it looks at, and unit-tested.
///
/// WHAT IS AND IS NOT TOUCHED. The .md file on disk is the record and is never
/// rewritten by any of this — cleanup produces a VIEW, computed on read. The
/// words themselves are never edited: an entry's text is either passed through
/// unchanged, or concatenated with the next one's, or the whole entry is
/// dropped. Nothing is rephrased, recased, repunctuated or reordered.
///
/// WHAT IT DOES, in order:
///  1. drops entries with no lexical content at all (see `hasContent`);
///  2. drops the lone lowercase single tokens that nothing could be continuing;
///  3. merges each speaker's consecutive entries into one paragraph, which
///     re-joins the sentences the 15 s cap chopped — and closes the paragraph
///     over whatever steps 1 and 2 removed from the middle of it.
enum TranscriptCleanup {

    /// What the cleanup did, for the log and for the tests. Not shown in the
    /// UI: the window shows the result, and a transcript that advertises how
    /// much of itself was hidden would be inviting an argument it cannot win.
    struct Report: Equatable {
        var entriesIn = 0
        var entriesOut = 0
        /// Entries merged into a preceding paragraph.
        var merged = 0
        /// Of those, the ones that look like a sentence the hard cap cut in
        /// half — see `isCapSplit`.
        var capSplits = 0
        /// Nothing but punctuation.
        var punctuation = 0
        /// A bracketed non-speech annotation: `*scoffs*`, `[laughter]`.
        var annotations = 0
        /// A non-lexical vocalization: "Mm-hmm.", "Uh…".
        var backchannels = 0
        /// A lone lowercase token nothing could absorb: "you", "and".
        var orphans = 0

        var dropped: Int { punctuation + annotations + backchannels + orphans }
    }

    static func clean(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        cleaning(entries).entries
    }

    static func cleaning(_ entries: [TranscriptEntry]) -> (entries: [TranscriptEntry],
                                                           report: Report) {
        var report = Report()
        report.entriesIn = entries.count

        var kept: [TranscriptEntry] = []
        kept.reserveCapacity(entries.count)
        for entry in entries {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hasContent(text) { report.punctuation += 1; continue }
            if isAnnotation(text) { report.annotations += 1; continue }
            if isBackchannel(text) { report.backchannels += 1; continue }
            let candidate = entry.with(text: text)
            // A lone lowercase token is dropped UNLESS it could be the tail of
            // the sentence right before it — same voice, still mid-sentence,
            // seconds ago. That guard is the whole safety of the rule: a real
            // fragment the cap tore off its own sentence always has one, and
            // in this archive the phantom never does (it follows a finished
            // "Thank you." on the same channel, or another speaker entirely).
            if isOrphanFragment(text), !isCapSplit(kept.last, candidate) {
                report.orphans += 1
                continue
            }
            kept.append(candidate)
        }

        let out = merge(kept, into: &report)
        report.entriesOut = out.count
        return (out, report)
    }

    // MARK: - Merging

    /// Consecutive entries of one voice become one paragraph, keeping the
    /// EARLIER timestamp and carrying the stamps of everything it swallowed
    /// (`absorbed`), so a contents-block entry pointing at 10:26:17 still finds
    /// the paragraph that 10:26:17 is now part of.
    ///
    /// Joined with a single space and nothing else. The two halves of a
    /// cap-split are whole words either side of the cut — the cap falls between
    /// audio windows, not between letters — so a space is the entire repair,
    /// and it is a repair that can be read straight off the file.
    private static func merge(_ entries: [TranscriptEntry],
                              into report: inout Report) -> [TranscriptEntry] {
        var out: [TranscriptEntry] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            guard let previous = out.last, previous.speaker == entry.speaker else {
                out.append(entry)
                continue
            }
            if isCapSplit(previous, entry) { report.capSplits += 1 }
            report.merged += 1
            out[out.count - 1] = previous.with(
                text: previous.text + " " + entry.text,
                absorbed: previous.absorbed + entry.covers)
        }
        return out
    }

    /// How far apart two entries may be and still be one sentence. The window
    /// cap is 15 s, so two windows of one speaker start at most that far apart
    /// plus the recognizer's own slack; 20 s is that with room, and it is only
    /// ever asked in order to COUNT a join, never to make one — the merge above
    /// is what the window has always done to build a turn.
    static let capSplitWindow: TimeInterval = 20

    /// True when `next` is the second half of a sentence `previous` began: the
    /// earlier text stops without a full stop, the later one opens in lower
    /// case, and the two are adjacent in time. All three, because a wrong join
    /// is worse than a missed one — an unfinished line followed by a capital is
    /// somebody being interrupted, and that is not this.
    static func isCapSplit(_ previous: TranscriptEntry?, _ next: TranscriptEntry) -> Bool {
        guard let previous, previous.speaker == next.speaker,
              !endsSentence(previous.text), startsLowercase(next.text),
              let from = MeetingArchive.seconds(fromClock: previous.covers.last ?? previous.time),
              let to = MeetingArchive.seconds(fromClock: next.time)
        else { return false }
        return to >= from && Double(to - from) <= capSplitWindow
    }

    // MARK: - What is dropped

    /// A line with no letter and no digit anywhere in it: ".", "-", "…".
    ///
    /// Never speech, and — this is the part that makes it safe — never a
    /// LOSS either, whatever produced it: there is no word in it to keep. It is
    /// what the recognizer writes when it is asked to explain a window that
    /// held no words.
    static func hasContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// The recognizer's own stage direction: the whole line is one short
    /// bracketed token — `*scoffs*`, `[laughter]`, `(music)`. Whisper writes
    /// these to describe a NON-speech sound, so by the model's own account
    /// nobody said them. Bounded in length and required to be the entire line,
    /// so a spoken sentence that happens to sit inside brackets is untouched.
    static func isAnnotation(_ text: String) -> Bool {
        let pairs: [(Character, Character)] = [("*", "*"), ("[", "]"), ("(", ")")]
        guard let open = text.first, let close = text.last, text.count >= 3,
              pairs.contains(where: { $0.0 == open && $0.1 == close }) else { return false }
        let inside = text.dropFirst().dropLast()
        guard inside.count <= 20 else { return false }
        return !inside.contains { "*[]()".contains($0) }
    }

    /// A pure backchannel — a non-lexical vocalization, which is to say a hum
    /// rather than a word: "Mm-hmm.", "Mm.", "Uh…", "Um.", "Hmm.", "ага",
    /// "угу", "э-э".
    ///
    /// FOLDED RATHER THAN KEPT, and folding it means removing it: the hum
    /// belongs to the OTHER speaker, so it cannot be appended to the paragraph
    /// around it without putting one person's sound in another person's mouth.
    /// Dropping it is what lets that paragraph close over the interruption,
    /// which is the whole of what "fold into the surrounding paragraph" can
    /// mean here. Measured on the archive, that is 23 lines removed and 11
    /// further paragraphs closed up.
    ///
    /// The class is deliberately the non-lexical one and stops there. "Okay.",
    /// "Yeah.", "Да.", "Понятно." are WORDS: they assent, they answer a
    /// question, and a reader can quote them. Adding them would be the phrase
    /// blocklist this project has now rejected twice (CONTEXT 5е-разрез,
    /// GRABLI) — it would delete the real "Yes." along with the polite noise,
    /// and it would be a per-language chore forever. A hum has no proposition
    /// in it in any language, and that is the line.
    static func isBackchannel(_ text: String) -> Bool {
        // Everything that is not a letter comes off first: the same hum is
        // written "Mm-hmm.", "Mm-hmm" and "Mm, hmm..." on three consecutive
        // windows of the same call.
        let core = text.lowercased().filter(\.isLetter)
        guard !core.isEmpty, core.count <= 6 else { return false }
        return hums.contains(core)
    }

    /// Spelled out rather than pattern-matched, because the point of this list
    /// is that it is CLOSED and short. These are the syllables English and
    /// Russian write a hum with; every one of them is a sound, not a word, and
    /// none of them can be quoted as anything a person said.
    private static let hums: Set<String> = [
        "m", "mm", "mmm", "mhm", "mhmm", "mmhmm", "hm", "hmm", "hmmm",
        "uh", "uhh", "uhhuh", "huh", "um", "umm", "ah", "ahh", "aha", "ha",
        "haha", "eh", "ehh", "oh", "ohh", "ooh",
        "м", "мм", "ммм", "мгм", "мхм", "хм", "хмм",
        "а", "аа", "ага", "э", "ээ", "у", "уу", "угу", "ы",
    ]

    /// A single token, in lower case, that does not end a sentence: "you",
    /// "and", "that", "thanks". What the recognizer leaves behind on a window
    /// that was almost silence — "you" alone appears four times in the archive,
    /// three of them directly under a phantom "Thank you."
    ///
    /// The claim being made is narrow, and it is about the RECOGNIZER rather
    /// than about the words: Whisper capitalizes and punctuates what it has
    /// decoded as an utterance, so a one-token line with neither signal is not
    /// an utterance it rendered — it is residue. A real short reply carries
    /// both ("Yes.", "Спасибо.", "Да.") and is never offered to this rule at
    /// all; and this rule alone is not what decides the matter either — the
    /// caller keeps any fragment that could be the tail of the sentence before
    /// it, which is what a genuine cap-split fragment always is.
    ///
    /// Written to leave a caseless script alone (Japanese, Chinese, Korean,
    /// Arabic): "では" has no lower case to have, so the signal this rule reads
    /// is simply absent there and the line stays.
    static func isOrphanFragment(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count == 1, !endsSentence(text) else { return false }
        return text.contains(where: \.isLowercase) && !text.contains(where: \.isUppercase)
    }

    // MARK: - Reading the punctuation

    /// The text ends on a full stop, and is allowed to end on one that a
    /// closing quote or bracket sits after.
    static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = trimmed.last, "\"'»)]”’".contains(last) {
            trimmed = trimmed.dropLast()
            while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        }
        guard let last = trimmed.last else { return false }
        return ".!?…。？！".contains(last)
    }

    /// The first LETTER is lower case. Asked of letters only, so a line opening
    /// with a dash or a digit is judged on the word after it; false for a
    /// script that has no case at all, which is the conservative answer — no
    /// case means no evidence, and no evidence means no join.
    static func startsLowercase(_ text: String) -> Bool {
        guard let first = text.first(where: \.isLetter) else { return false }
        return first.isLowercase
    }
}

extension TranscriptEntry {
    fileprivate func with(text: String, absorbed: [String]? = nil) -> TranscriptEntry {
        TranscriptEntry(id: id, time: time, speaker: speaker, text: text, isYou: isYou,
                        absorbed: absorbed ?? self.absorbed)
    }
}
