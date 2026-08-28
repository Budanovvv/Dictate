import Foundation

/// Answering a question from the archive.
///
/// The question comes from the same field that searches — one field, because
/// the reason every comparable product grew a second one does not apply here.
/// They split to make room for choosing a corpus: a team workspace, folders,
/// date ranges, checkboxes over a hundred meetings. Dictate has one person and
/// one folder, and its search already covers all of it, so a question needs no
/// setup and fits where the searching already happens.
///
/// What DOES need care is the trigger. Nothing is ever inferred from the shape
/// of what was typed — no question marks, no question words, no classifier. The
/// answer appears because somebody asked for it, and the row that asks appears
/// only when the search already found something to answer from. That last
/// clause is the important one: it means the app can never offer to answer a
/// question it has no sources for, which is the failure every product in this
/// category has and none has solved — a person cannot tell "that is not in your
/// meetings" from "that is not in my index", and both come back as a confident
/// nothing.
protocol MeetingOracle {

    /// Whether this oracle can run right now.
    ///
    /// Every backend answers this differently — a key that is missing, a binary
    /// that is not installed — and none can answer it for another, which is why
    /// it lives on the protocol rather than in the view.
    var isAvailable: Bool { get }

    /// One sentence, already localised, for when it cannot.
    var unavailableReason: String { get }

    /// The answer, in pieces, as it is written.
    ///
    /// A stream rather than a string because this takes seconds to tens of
    /// seconds, and past ten seconds a person stops waiting and starts
    /// wondering. Text appearing as it is composed is the only honest progress
    /// available here: a determinate bar over work whose length nobody knows is
    /// a lie the app would be telling, and this project has that scar already.
    ///
    /// `prompt` is the already-composed user turn (passages and question, see
    /// MeetingQuestion.user); `history` is every earlier round of this
    /// conversation. Both vendors' APIs are stateless, so the memory of the
    /// chat IS that array, resent whole on every call — that is the visible
    /// price of a conversation that remembers, and the quality it buys is the
    /// reason the asking pane is a session rather than a slot machine.
    func answer(_ prompt: String, history: [AnswerExchange])
        -> AsyncThrowingStream<String, Error>
}

/// One earlier round, exactly as it went over the wire: the composed user
/// turn (passages included) and the answer that came back. Passages stay in
/// the history on purpose — a follow-up like "and who owed that?" is usually
/// about the evidence, and an answer's summary of it is not the evidence.
struct AnswerExchange {
    let user: String
    let assistant: String
}

/// One passage the answer may draw on — a meeting, or a moment inside it.
///
/// Assembled from what the search already found. The oracle never goes looking
/// on its own: retrieval happens locally, instantly and visibly, and the model
/// only reads what the person can already see on screen. That ordering is what
/// lets the sources appear before the first token does.
struct MeetingSource: Identifiable {
    /// Where the passage came from, so the answer can be checked by going
    /// there. The whole design of the answer rests on this being one click
    /// away: measured, citations raise trust even when they are wrong, which
    /// makes a footnote nobody follows a liability rather than a check.
    let url: URL
    let title: String
    let date: String
    /// nil when the whole meeting is the source rather than one passage of it.
    let time: String?
    /// What was actually said — speaker-attributed lines, verbatim. Shown to
    /// the reader as well as to the model: evidence that can be read without a
    /// click is the thing this category never shipped.
    let text: String
    /// The passage's channel, for the quote card's colour bar and label
    /// (design: Supporting quotes) — from the passage's FIRST line. nil for
    /// restored conversations, which predate the field.
    var channelIsYou: Bool? = nil
    var channelLabel: String? = nil

    var id: String { "\(url.path)#\(time ?? "")" }

    /// How a source is written into the prompt. Labelled so the model can name
    /// it back, which is the only way an answer can be checked.
    var block: String {
        let head = time.map { "\(title) — \(date), \($0)" } ?? "\(title) — \(date)"
        return "<meeting>\n\(head)\n\n\(text)\n</meeting>"
    }
}

/// What every oracle is told, kept in one place.
///
/// Shared on purpose: if the local answerer and the hosted one were instructed
/// differently, the same question would get different answers depending on who
/// was paying, and the difference would be invisible to whoever asked.
enum MeetingQuestion {

    static let instructions = """
        You answer questions about someone's own recorded meetings, in an \
        ongoing conversation. A question may bring passages their local \
        search found; a follow-up may bring none and lean on the passages \
        already in this conversation.

        You also have tools over the same archive: list the meetings, search \
        them (queries in English), and read one in full. The supplied \
        passages are excerpts and a starting point — when they do not settle \
        the question, read the meeting they came from instead of guessing, \
        and search when the question reaches beyond them.

        Answer only from those passages, this conversation and what the \
        tools return. Where the wording matters, quote the speaker. Name the \
        meeting you took each fact from, so it can be checked. Answer in the \
        language the question was asked in.

        Be careful about who said what. These are real conversations and the \
        recognition is imperfect. If a passage says a constraint was on one \
        person's side, do not move it to another's. Where the text genuinely \
        does not settle who owed what to whom, say that instead of choosing.

        If the passages do not answer the question, say so and say what they do \
        cover. A confident answer assembled from nothing is worse than an \
        admission, because the person asking has usually forgotten the meeting \
        and cannot catch you.

        Write plainly, a few sentences to a few short paragraphs. No headings, \
        no bullet lists unless the answer is genuinely a list of items.
        """

    /// The quiet second call after an answer lands: two follow-up questions
    /// for the chips under it. Sent through the same oracle with the same
    /// conversation, so the suggestions know what was actually said — and
    /// worded to come back bare, because anything else on those lines ends up
    /// inside a chip.
    static let followUps = """
        Suggest two short follow-up questions the person might naturally ask \
        next in this conversation. Each must be answerable from the meetings \
        and passages discussed above, and written in the language the person \
        has been asking in. Return exactly two questions, one per line — no \
        numbering, no dashes, nothing else.
        """

    /// The user turn: the sources, then the question.
    ///
    /// The question goes LAST, after the passages. Long-context models attend
    /// best to what sits at the ends, and of the two the instruction is the one
    /// that must survive a wall of transcript above it.
    ///
    /// A follow-up arrives with no sources of its own and is sent bare — its
    /// evidence is the passages already in the conversation's history.
    ///
    /// `scope` is the one line that pins a conversation to a single meeting
    /// (set when asking from a transcript's own header): it goes FIRST, so a
    /// wall of excerpt cannot bury which meeting is being discussed.
    static func user(question: String, sources: [MeetingSource],
                     scope: String? = nil) -> String {
        var parts: [String] = []
        if let scope { parts.append(scope) }
        if !sources.isEmpty { parts.append(sources.map(\.block).joined(separator: "\n\n")) }
        guard !parts.isEmpty else { return question }
        return parts.joined(separator: "\n\n") + "\n\nThe question: \(question)"
    }
}
