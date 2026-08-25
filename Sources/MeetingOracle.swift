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
    func answer(_ question: String, from sources: [MeetingSource])
        -> AsyncThrowingStream<String, Error>
}

/// One passage the answer may draw on — a meeting, or a moment inside it.
///
/// Assembled from what the search already found. The oracle never goes looking
/// on its own: retrieval happens locally, instantly and visibly, and the model
/// only reads what the person can already see on screen. That ordering is what
/// lets the sources appear before the first token does.
struct MeetingSource {
    let title: String
    let date: String
    /// nil when the whole meeting is the source rather than one passage of it.
    let time: String?
    /// What was actually said — speaker-attributed lines, verbatim.
    let text: String

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
        You answer questions about someone's own recorded meetings. You are \
        given the passages their search already found, and nothing else.

        Answer from those passages only. Where the wording matters, quote the \
        speaker. Name the meeting you took each fact from, so it can be checked.

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

    /// The user turn: the sources, then the question.
    ///
    /// The question goes LAST, after the passages. Long-context models attend
    /// best to what sits at the ends, and of the two the instruction is the one
    /// that must survive a wall of transcript above it.
    static func user(question: String, sources: [MeetingSource]) -> String {
        sources.map(\.block).joined(separator: "\n\n")
            + "\n\nThe question: \(question)"
    }
}
