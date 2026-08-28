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
    /// `prompt` is the user's question; `history` is every earlier round of
    /// this conversation. Both vendors' APIs are stateless, so the memory of
    /// the chat IS that array, resent whole on every call — that is the
    /// visible price of a conversation that remembers, and the quality it
    /// buys is the reason the asking pane is a session rather than a slot
    /// machine.
    func answer(_ prompt: String, history: [AnswerExchange])
        -> AsyncThrowingStream<String, Error>
}

/// One earlier round, exactly as it went over the wire: the user turn and
/// the answer that came back.
struct AnswerExchange {
    let user: String
    let assistant: String
}

/// What every oracle is told, kept in one place.
///
/// Shared on purpose: if the local answerer and the hosted one were instructed
/// differently, the same question would get different answers depending on who
/// was paying, and the difference would be invisible to whoever asked.
enum MeetingQuestion {

    static let instructions = """
        You answer questions about someone's own recorded meetings, in an \
        ongoing conversation.

        You have tools over that archive: list the meetings, search them, \
        and read one in full. Go looking before you answer — read the \
        meeting instead of guessing, search when the question reaches \
        beyond what this conversation already holds, and try different \
        words when a search comes back empty.

        Answer only from this conversation and what the tools return. \
        Where the wording matters, quote the speaker. Name the meeting you \
        took each fact from, so it can be checked. Answer in the language \
        the question was asked in.

        Be careful about who said what. These are real conversations and the \
        recognition is imperfect. If a transcript says a constraint was on \
        one person's side, do not move it to another's. Where the text \
        genuinely does not settle who owed what to whom, say that instead \
        of choosing.

        If the archive does not answer the question, say so and say what it \
        does cover. A confident answer assembled from nothing is worse than \
        an admission, because the person asking has usually forgotten the \
        meeting and cannot catch you.

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

}
