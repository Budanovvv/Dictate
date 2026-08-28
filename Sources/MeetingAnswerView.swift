import SwiftUI

/// One round of the conversation: a question and the answer as it streams in.
struct AnswerTurn: Identifiable {
    let id = UUID()
    /// The question, as typed. Shown back to the reader because by the time an
    /// answer arrives the field may say something else, and an answer without
    /// its question is a paragraph from nowhere.
    let question: String
    /// The user turn as it went to the model — kept so later rounds can
    /// resend the conversation verbatim (the APIs are stateless).
    let prompt: String
    var text = ""
    var failure: String?
    /// Which of the four known failure shapes this is (design: askFailures) —
    /// decides the banner and its action; nil with a failure = generic.
    var failureKind: AskFailureKind?
}

/// The conversation being had.
///
/// A session, not a slot machine: every question is answered with the whole
/// conversation so far, so a follow-up can say "and who owed that?" and mean
/// something. The session lives exactly as long as the meetings window does.
///
/// Separate from the view because the answer outlives any one redraw and has to
/// survive the list being scrolled, the window being resized and the sidebar
/// being clicked. It is also the thing that has to be stoppable, and a stop
/// that only stops the drawing is not a stop.
@MainActor
final class MeetingAnswer: ObservableObject {

    @Published private(set) var turns: [AnswerTurn] = []
    @Published private(set) var isRunning = false
    /// What the model is doing with the archive right now ("Reading …"),
    /// posted by the tool layer — shown where the pane would otherwise say
    /// only that words are coming.
    @Published private(set) var progress: String?
    /// Two follow-up questions for the chips under the newest answer —
    /// fetched quietly after the answer lands, gone the moment a new
    /// question is asked. Never persisted: they are an offer, not content.
    @Published private(set) var suggested: [String] = []

    private var progressObserver: NSObjectProtocol?

    init() {
        progressObserver = NotificationCenter.default.addObserver(
            forName: MeetingAgentTool.progressNotification, object: nil,
            queue: .main) { [weak self] note in
            guard let self, self.isRunning else { return }
            self.progress = note.object as? String
        }
    }

    deinit {
        if let progressObserver {
            NotificationCenter.default.removeObserver(progressObserver)
        }
    }

    /// Which stored conversation this session IS. Every finished turn is
    /// persisted under it (AskHistoryStore), so an answer survives the window
    /// and the app — re-opening it later shows the stored text, no API call.
    private(set) var conversationID = UUID()
    private var createdAt = Date()
    /// First question unless the user renamed the conversation.
    var title = ""

    private var work: Task<Void, Never>?

    /// Whether anything is on screen at all.
    var isEmpty: Bool { turns.isEmpty }

    /// The question of the newest round — what the ask row compares against
    /// so re-clicking it does not ask the same thing twice.
    var lastQuestion: String? { turns.last?.question }
    var lastFailure: String? { turns.last?.failure }

    func ask(_ question: String, using oracle: MeetingOracle) {
        stop()
        // Earlier rounds go with every request — the session's memory IS
        // this array, resent whole (the APIs are stateless).
        let history = turns.compactMap { turn in
            turn.text.isEmpty ? nil : AnswerExchange(user: turn.prompt, assistant: turn.text)
        }
        let prompt = question
        turns.append(AnswerTurn(question: question, prompt: prompt))
        // The question itself is deliberately NOT logged (it is the owner's
        // private text); the shape of the work is, so a dead answer can be
        // diagnosed from the log alone.
        Log.d("ask: question (\(history.count) earlier turns)")

        guard oracle.isAvailable else {
            turns[turns.count - 1].failure = oracle.unavailableReason
            return
        }
        isRunning = true
        progress = nil
        suggested = []
        work = Task { [weak self] in
            do {
                for try await piece in oracle.answer(prompt, history: history) {
                    guard !Task.isCancelled, let self, !self.turns.isEmpty else { break }
                    self.turns[self.turns.count - 1].text += piece
                }
                Log.d("ask: answered")
            } catch {
                // A stop is not a failure — the person asked for it.
                if !Task.isCancelled, let self, !self.turns.isEmpty {
                    let kind = AskFailureKind.classify(error)
                    self.turns[self.turns.count - 1].failure = error.localizedDescription
                    self.turns[self.turns.count - 1].failureKind = kind
                    // A refused key is dead weight AND a hazard: every retry
                    // would resend it. Removed at once (⌘Z-able through the
                    // Settings buffer), and the banner says so.
                    if kind == .badKey, let provider = Settings.shared.askProvider {
                        _ = APIKey.store(nil, for: provider)
                    }
                    // "Look in the log" must work for the one feature that
                    // talks to a vendor's server: the pane's red line is gone
                    // the moment the window closes, this line is not.
                    Log.d("ask: failed — \(error.localizedDescription)")
                }
            }
            self?.isRunning = false
            self?.progress = nil
            self?.persist()
            // The chips: only after a real answer, and silently skippable —
            // a failed suggestion call must never mark a finished answer.
            if let self, !Task.isCancelled, let last = self.turns.last,
               last.failure == nil, !last.text.isEmpty {
                await self.fetchSuggestions(using: oracle)
            }
        }
    }

    /// Asks the same oracle for two follow-up questions (MeetingQuestion
    /// .followUps). Its output is chip text, not conversation: nothing is
    /// appended to `turns`, nothing persists, and any failure is silence.
    private func fetchSuggestions(using oracle: MeetingOracle) async {
        let history = turns.compactMap { turn in
            turn.text.isEmpty ? nil : AnswerExchange(user: turn.prompt, assistant: turn.text)
        }
        var raw = ""
        do {
            for try await piece in oracle.answer(MeetingQuestion.followUps, history: history) {
                if Task.isCancelled { return }
                raw += piece
            }
        } catch { return }
        let cleaned = raw.split(whereSeparator: \.isNewline)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                while let first = text.first,
                      first == "-" || first == "•" || first == "*" || first == "."
                          || first == ")" || first.isNumber {
                    text.removeFirst()
                    text = text.trimmingCharacters(in: .whitespaces)
                }
                return text
            }
            .filter { $0.count > 4 }
        guard !Task.isCancelled else { return }
        suggested = Array(cleaned.prefix(2))
    }

    /// Stop, keeping whatever arrived. A half-answer is often the answer, and
    /// throwing it away would punish the person for not waiting.
    func stop() {
        work?.cancel()
        work = nil
        isRunning = false
        progress = nil
        persist()
    }

    /// Clear WITHOUT persisting — the delete path only. clear() persists as
    /// it stops (a half-answer is an answer), and that very persist used to
    /// resurrect the file the user had just deleted: delete removed the JSON,
    /// clear() wrote the still-loaded turns straight back under the same id
    /// ("ни одна из них не удаляется", owner's report 2026-08-29).
    func discard() {
        work?.cancel()
        work = nil
        isRunning = false
        progress = nil
        turns = []
        suggested = []
        conversationID = UUID()
        createdAt = Date()
        title = ""
    }

    /// New chat: the previous conversation stays on disk (it was persisted as
    /// it went), this session simply becomes a fresh one.
    func clear() {
        stop()
        turns = []
        suggested = []
        conversationID = UUID()
        createdAt = Date()
        title = ""
    }

    /// Re-open a stored conversation: the answer shows instantly from disk —
    /// no API call — and a follow-up continues it (the prompts are kept).
    func restore(_ stored: AskConversation) {
        stop()
        suggested = []
        conversationID = stored.id
        createdAt = stored.createdAt
        title = stored.title
        turns = stored.turns.map { turn in
            AnswerTurn(question: turn.question,
                       prompt: turn.prompt,
                       text: turn.text)
        }
    }

    /// Every turn with any content goes to disk under this conversation's id.
    /// Called when a stream ends (success, failure or stop) — not per token.
    private func persist() {
        let kept = turns.filter { !$0.text.isEmpty || $0.failure != nil }
            .map { turn in
                AskConversation.Turn(question: turn.question, prompt: turn.prompt,
                                     text: turn.text)
            }
        guard !kept.isEmpty else { return }
        if title.isEmpty { title = kept[0].question }
        AskHistoryStore.shared.save(AskConversation(
            id: conversationID, title: title, createdAt: createdAt,
            lastActiveAt: Date(), turns: kept))
    }
}

/// Past Ask conversations, as a column beside the answer (design 11j):
/// titled by their first question, stamped with when they were last active
/// and how many meetings the answer drew from. Opening one shows the stored
/// answer with no re-asking; rename is inline (Return/Esc), delete is
/// immediate with an undo affordance bound to ⌘Z instead of a confirmation.
struct ConversationsColumn: View {
    /// The session shown in the pane — used to mark the open row and to know
    /// when a fresh conversation was persisted (isRunning flips).
    @ObservedObject var answer: MeetingAnswer
    let onOpen: (AskConversation) -> Void
    let onNew: () -> Void

    @State private var conversations: [AskConversation] = []
    @State private var renamingID: UUID?
    @State private var draft = ""
    /// The one-shot undo affordance for the last delete.
    @State private var deletedTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The design's one primary action, where a hunted-for "+" glyph
            // used to be (field report 2026-08-28): a full-width accent
            // button in its own 52 pt band. Dimmed when the current chat is
            // already fresh — there is nothing to start over.
            HStack {
                Button {
                    onNew()
                    reload()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("New question"))
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.accent.opacity(answer.isEmpty ? 0.4 : 1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEmphasis(scale: 1.02)
                .disabled(answer.isEmpty)
                .accessibilityLabel(L("New question"))
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Divider() }
            Text(L("Conversations"))
                .font(DS.sectionLabel)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 5)

            if let deletedTitle {
                // Undo replaces confirmation (12f): the list stays stable and
                // the way back is one keystroke.
                HStack(spacing: 6) {
                    Text(Lf("Deleted “%@”", deletedTitle))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(L("Undo")) { undelete() }
                        .buttonStyle(.dsSmall)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .font(DS.helpText)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(conversations) { conversation in
                        row(conversation)
                    }
                    if conversations.isEmpty {
                        Text(L("Questions you ask are kept here so you can return to an answer."))
                            .font(DS.helpText)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            Text(L("Kept on this Mac. Deleting is immediate; beyond 50 conversations the oldest age out."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Divider() }
        }
        .onAppear(perform: reload)
        // A finished answer persists its conversation — refresh when the
        // stream ends so a first question appears in the list right away.
        .onChange(of: answer.isRunning) { running in
            if !running { reload() }
        }
    }

    @ViewBuilder
    private func row(_ conversation: AskConversation) -> some View {
        let open = conversation.id == answer.conversationID
        Button {
            guard renamingID != conversation.id else { return }
            onOpen(conversation)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == conversation.id {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .onSubmit { commitRename(conversation) }
                        .onExitCommand { renamingID = nil }
                } else {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                }
                Text(subtitle(conversation))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Selection is a tint with an accent edge, never a filled row (13a).
        .background(
            HStack(spacing: 0) {
                if open {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DS.accent)
                        .frame(width: DS.selectionEdge)
                }
                Rectangle().fill(open ? DS.selectionTint : .clear)
            }
        )
        .hoverHighlight()
        .clipShape(DS.shape)
        .contextMenu {
            Button(L("Rename")) {
                draft = conversation.title
                renamingID = conversation.id
            }
            Button(L("Delete"), role: .destructive) { delete(conversation) }
        }
    }

    private func subtitle(_ conversation: AskConversation) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: conversation.lastActiveAt, relativeTo: Date())
    }

    private func commitRename(_ conversation: AskConversation) {
        AskHistoryStore.shared.rename(conversation.id, to: draft)
        if conversation.id == answer.conversationID {
            answer.title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        renamingID = nil
        reload()
    }

    private func delete(_ conversation: AskConversation) {
        // The open conversation is emptied BEFORE its file goes — in that
        // order, and with discard() rather than clear(): clear() persists on
        // its way out and would write the deleted file straight back.
        let wasOpen = conversation.id == answer.conversationID
        if wasOpen { answer.discard() }
        AskHistoryStore.shared.delete(conversation.id)
        deletedTitle = conversation.title
        if wasOpen { onNew() }
        reload()
    }

    private func undelete() {
        if let restored = AskHistoryStore.shared.undelete() {
            deletedTitle = nil
            reload()
            onOpen(restored)
        }
    }

    private func reload() {
        conversations = AskHistoryStore.shared.list()
    }
}

/// The conversation, in the reading pane.
///
/// Placed where a transcript goes rather than over the list, because an answer
/// is something to read and the pane is what this window reads in.
struct AnswerPane: View {
    @ObservedObject var answer: MeetingAnswer
    /// Openers for the cold state — the articulation barrier is real, and a
    /// blank prompt box teaches nobody what the agent can do. Handed in
    /// because the library owns the archive these are drawn from.
    let suggestions: [String]
    /// The honest one-liner under the empty state's title: how many meetings
    /// are searchable and WHO writes the answer ("answered by Claude") — the
    /// search is local, the answer is not, and this app does not blur that.
    var headerNote: String? = nil
    /// A follow-up typed in the pane itself: it continues THIS conversation
    /// over the passages already on the table, no trip back to the search
    /// field. New material still comes in the search-field way — a fresh
    /// search, a fresh click, and the new passages join the same session.
    let followUp: (String) -> Void
    /// Clearing is the library's business too (it owns the scope), so the
    /// button hands the act back instead of reaching into the model.
    let newChat: () -> Void
    /// The badKey banner's way out: the connect sheet, where a fresh key can
    /// be pasted (design: askFailures).
    var onAddKey: () -> Void = {}
    /// The archive's size, shown quietly inside the docked composer
    /// (design: "38 meetings · 26 h of audio"). nil hides it.
    var stats: String? = nil
    /// The window-level pane toggle (the sidebar's), handed in by the panes'
    /// owner — with the sidebar folded it also clears the traffic lights.
    var headerLeading: AnyView? = nil

    @State private var draft = ""
    /// Focused when a chat is (re)started — the "+" has to produce a visible,
    /// usable result, and a blinking caret in the composer is that result.
    @FocusState private var composerFocused: Bool
    /// Whether the previous render had turns — the composer grabs focus only
    /// on the empty-after-full transition (the "+"), never at window open.
    @State private var hadTurns = false

    var body: some View {
        VStack(spacing: 0) {
        // The pane's own 46 pt header (Composer.dc): what this surface is and
        // the honest line about who answers — present in every state, so an
        // opened conversation still says what it is scoped to.
        HStack {
            if let headerLeading {
                headerLeading.padding(.trailing, 4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Ask")).font(DS.windowTitle)
                if let headerNote {
                    Text(headerNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .overlay(alignment: .bottom) { Divider() }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if answer.isEmpty {
                        emptyState
                            .onAppear {
                                if hadTurns { composerFocused = true }
                                hadTurns = false
                            }
                            .onDisappear { hadTurns = true }
                    } else {
                        // (design answered2: the conversation reads in a
                        // centered 700 pt column, whatever the pane width)
                        // "New chat" used to sit here too — two controls for
                        // one act, and the pair read as unrelated (field
                        // report 2026-08-28). The Conversations column's "+"
                        // is the one way to start over.
                        ForEach(answer.turns) { turn in
                            turnView(turn, isLast: turn.id == answer.turns.last?.id)
                        }

                        if answer.isRunning {
                            Button(L("Stop")) { answer.stop() }
                                .buttonStyle(.dsSmall)
                        } else if !answer.suggested.isEmpty {
                            // The offer to keep going (design: follow-up
                            // chips) — two questions the answer itself
                            // raised, one click from being asked.
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(answer.suggested, id: \.self) { suggestion in
                                    suggestionChip(suggestion)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(EdgeInsets(top: 20, leading: 28, bottom: 18, trailing: 28))
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
                .id("thread")
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: answer.turns.count) { _ in
                withAnimation(.easeInOut(duration: DS.reveal)) {
                    proxy.scrollTo("thread", anchor: .bottom)
                }
            }
        }
        if !answer.isEmpty {
            followUpField
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .overlay(alignment: .top) { Divider() }
        }
        }
    }

    /// The conversation before its first question: what this is, three
    /// questions that already have answers in the archive, and the field.
    @ViewBuilder
    private var emptyState: some View {
        Text(L("Ask anything about your meetings"))
            .font(.system(size: 21, weight: .bold))
        Text(L("The agent searches and reads your transcripts on this Mac, and every answer names the meetings it drew from."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: DS.readingMeasure, alignment: .leading)
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Try one of these"))
                .font(DS.sectionLabel)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(suggestions, id: \.self) { suggestion in
                suggestionChip(suggestion)
            }
        }
        followUpField
    }

    /// One suggested question as a clickable capsule — the empty state's
    /// openers and the post-answer follow-ups wear the same clothes.
    private func suggestionChip(_ suggestion: String) -> some View {
        Button {
            followUp(suggestion)
        } label: {
            Text(suggestion)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.accentText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEmphasis(scale: 1.02)
        .pointerStyle(.link)
    }

    @ViewBuilder
    private func turnView(_ turn: AnswerTurn, isLast: Bool) -> some View {
        if turn.id != answer.turns.first?.id {
            Divider().padding(.vertical, 4)
        }
        QuestionBubble(text: turn.question)

        if let failure = turn.failure {
            failureBanner(turn: turn, fallback: failure)
        }

        if !turn.text.isEmpty {
            // Reading type (13a): 15/1.65 on a 72-character measure — the
            // content larger than the chrome around it. Serif stays: the
            // model's voice never wears the transcript's typeface. Inline
            // Markdown only — raw asterisks on screen read as a rendering
            // bug (field report 2026-08-28).
            Text((try? AttributedString(
                markdown: turn.text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(turn.text))
                .font(DS.readingBody)
                .fontDesign(.serif)
                .lineSpacing(DS.readingLineSpacing / 2)
                .frame(maxWidth: DS.readingMeasure, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if isLast, answer.isRunning {
            // Before the first token: the tool layer says what the model
            // is doing with the archive, so the wait is honest.
            Text(answer.progress ?? L("Reading…"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .animation(.easeOut(duration: DS.fade), value: answer.progress)
        }
    }

    /// The one composer (t14): rests at one line, grows a line at a time to
    /// a five-line cap and scrolls internally from there. Return sends, Esc
    /// clears; the key hint appears only while the field has content, and a
    /// character count appears only past 2,000 characters — quiet metadata,
    /// never a live counter.
    private var followUpField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(answer.isEmpty ? L("Ask about your meetings…")
                                         : L("Ask across all meetings…"),
                          text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .padding(.vertical, 4)
                    .focused($composerFocused)
                    .onSubmit(send)
                    // Shift-Return adds a line (design t14) — the vertical
                    // TextField only knows Option-Return natively, and Shift
                    // is what every chat app taught. Both work.
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        draft += "\n"
                        return .handled
                    }
                    .onExitCommand { draft = "" }
                // The archive's size, quiet, inside the field's right edge
                // (design) — gone the moment typing starts.
                if !answer.isEmpty, draft.isEmpty, let stats {
                    Text(stats)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 7)
                }
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        // A .plain button's explicit colours ignore the
                        // disabled environment — an empty composer showed a
                        // fully lit button that did nothing. The fill itself
                        // tells the truth now.
                        .background(canSend ? DS.accent : DS.accent.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .hoverEmphasis()
                .disabled(!canSend)
                .accessibilityLabel(L("Send"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            // The drawn field (design t14/hero): quiet fill, hairline, the
            // send control INSIDE — one object, whatever the state.
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1)))
            if !draft.isEmpty {
                HStack {
                    Text(L("Return sends · Shift-Return adds a line · Esc clears"))
                    Spacer(minLength: 8)
                    if draft.count > 2000 {
                        Text("\(draft.count)").monospacedDigit()
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        followUp(question)
    }

    /// One of the four typed failure banners (design: askFailures) — in the
    /// answer area, in place of the answer, never as an alert. Ask stays on;
    /// only this question failed, and each shape carries its own way out.
    @ViewBuilder
    private func failureBanner(turn: AnswerTurn, fallback: String) -> some View {
        let provider = Settings.shared.askProvider ?? .anthropic
        switch turn.failureKind ?? .other {
        case .offline:
            failureBox(icon: "wifi.slash",
                       title: L("This Mac is offline"),
                       sub: L("The answer stopped. Your question is kept above — retry when the connection returns. Search and transcripts still work."),
                       buttonTitle: L("Retry")) { followUp(turn.question) }
        case .rateLimited:
            failureBox(icon: "clock",
                       title: L("Too many questions at once"),
                       sub: L("Your provider is rate limiting. Wait a few seconds and retry — nothing was lost."),
                       buttonTitle: L("Retry")) { followUp(turn.question) }
        case .outOfCredit:
            failureBox(icon: "creditcard",
                       title: L("Your provider account is out of credit"),
                       sub: Lf("%@ refused the request for billing reasons. Add credit in your provider account, or switch Ask off in Settings.", provider.vendorName),
                       buttonTitle: L("Open Console")) {
                NSWorkspace.shared.open(provider.keysURL)
            }
        case .badKey:
            failureBox(icon: "lock",
                       title: L("The saved key no longer works"),
                       sub: L("It was revoked or replaced since you connected. It has been removed from the Keychain — nothing was retried with it."),
                       buttonTitle: L("Add a Key…")) { onAddKey() }
        case .other:
            Label(fallback, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(DS.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failureBox(icon: String, title: String, sub: String,
                            buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(sub)
                    .font(DS.helpText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(buttonTitle, action: action)
                .buttonStyle(.dsSmall)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .frame(maxWidth: DS.readingMeasure, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.5)))
    }

}

/// The question as the design's speech bubble (Composer.dc: sent): accent
/// fill, right-aligned, clamped at six lines with a Show more — a long
/// question must not bury its own answer.
private struct QuestionBubble: View {
    let text: String
    @State private var expanded = false
    /// Six lines of the bubble's measure, roughly.
    private var clamps: Bool { text.count > 420 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack {
                Spacer(minLength: 0)
                Text(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .lineLimit(expanded ? nil : 6)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(UnevenRoundedRectangle(
                        cornerRadii: .init(topLeading: 14, bottomLeading: 14,
                                           bottomTrailing: 4, topTrailing: 14),
                        style: .continuous)
                        .fill(DS.accent))
                    .frame(maxWidth: 480, alignment: .trailing)
            }
            if clamps {
                Button(expanded ? L("Show less") : L("Show more")) {
                    withAnimation(.easeOut(duration: DS.fade)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(DS.accentText)
                .hoverHighlight(radius: DS.radiusChip)
                .pointerStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
