import SwiftUI

/// One answer being written.
///
/// Separate from the view because the answer outlives any one redraw and has to
/// survive the list being scrolled, the window being resized and the sidebar
/// being clicked. It is also the thing that has to be stoppable, and a stop
/// that only stops the drawing is not a stop.
@MainActor
final class MeetingAnswer: ObservableObject {

    /// The question, as typed. Shown back to the reader because by the time an
    /// answer arrives the field may say something else, and an answer without
    /// its question is a paragraph from nowhere.
    @Published private(set) var question = ""

    /// The passages it is allowed to use. On screen from the first moment —
    /// retrieval is instant and local, generation is not, and showing the real
    /// work already done beats a bar that guesses at work still to do.
    @Published private(set) var sources: [MeetingSource] = []

    @Published private(set) var text = ""
    @Published private(set) var isRunning = false
    @Published private(set) var failure: String?

    private var work: Task<Void, Never>?

    /// Whether anything is on screen at all.
    var isEmpty: Bool { question.isEmpty }

    func ask(_ question: String, from sources: [MeetingSource], using oracle: MeetingOracle) {
        stop()
        self.question = question
        self.sources = sources
        text = ""
        failure = nil

        guard oracle.isAvailable else {
            failure = oracle.unavailableReason
            return
        }
        isRunning = true
        work = Task { [weak self] in
            do {
                for try await piece in oracle.answer(question, from: sources) {
                    guard !Task.isCancelled else { break }
                    self?.text += piece
                }
            } catch {
                // A stop is not a failure — the person asked for it.
                if !Task.isCancelled { self?.failure = error.localizedDescription }
            }
            self?.isRunning = false
        }
    }

    /// Stop, keeping whatever arrived. A half-answer is often the answer, and
    /// throwing it away would punish the person for not waiting.
    func stop() {
        work?.cancel()
        work = nil
        isRunning = false
    }

    func clear() {
        stop()
        question = ""
        sources = []
        text = ""
        failure = nil
    }
}

/// The answer, in the reading pane.
///
/// Placed where a transcript goes rather than over the list, because an answer
/// is something to read and the pane is what this window reads in. Nothing the
/// person was looking at is destroyed: the sidebar still shows the meetings the
/// answer came from, and clicking any of them returns.
struct AnswerPane: View {
    @ObservedObject var answer: MeetingAnswer
    /// Going to the meeting a passage came from. The whole point of the source
    /// list is that this is one click, so it is handed in rather than guessed.
    let open: (MeetingSource) -> Void

    @State private var peeking: MeetingSource.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(answer.question)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let failure = answer.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !answer.text.isEmpty {
                    Text(answer.text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if answer.isRunning {
                    // Before the first token. Not a spinner over nothing: the
                    // sources below are already on screen, so this only has to
                    // say that words are coming.
                    Text(L("Reading…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if answer.isRunning {
                    Button(L("Stop")) { answer.stop() }
                        .controlSize(.small)
                }

                if !answer.sources.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text(L("Answered from"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(answer.sources) { source in
                        sourceRow(source)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A passage, readable without leaving.
    ///
    /// Hover shows what was actually said; click goes there. Deliberately not
    /// superscript footnote markers: measured, those go unclicked, and
    /// citations raise a reader's trust even when they are wrong — which makes
    /// an unfollowed marker a liability dressed as a check. Evidence that can
    /// be read in place is the thing this whole category never shipped.
    @ViewBuilder
    private func sourceRow(_ source: MeetingSource) -> some View {
        let showing = peeking == source.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let time = source.time {
                    Text(time)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(source.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(source.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showing {
                Text(source.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(showing ? 0.06 : 0.03)))
        .contentShape(Rectangle())
        .onHover { peeking = $0 ? source.id : nil }
        .onTapGesture { open(source) }
        .animation(.easeOut(duration: 0.12), value: showing)
    }
}
