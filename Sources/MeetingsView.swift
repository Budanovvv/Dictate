import SwiftUI
import AppKit

/// The meetings surface: a library of past transcripts on the left, the
/// selected transcript — live or archived — on the right. One window instead
/// of "a debug panel plus a folder in Finder": the live call is simply the
/// first item in the list, so watching a call and reading last week's notes
/// are the same gesture.
/// Where the meetings window should open.
///
/// The window is built once and reused for the whole session, so "open THIS
/// meeting" cannot be an argument to the view: the second request would arrive
/// long after the only `onAppear` that would have read it. It is state the view
/// watches instead — and every request counts, including a repeat of one
/// already served, or asking twice for the same meeting would do nothing the
/// second time.
final class MeetingsNavigator: ObservableObject {
    /// The transcript to select; nil means "wherever the window opens on its
    /// own" — the live call, or the newest meeting there is.
    private(set) var target: URL?
    @Published private(set) var requests = 0

    func open(_ url: URL?) {
        target = url
        requests += 1
    }
}

struct MeetingsView: View {
    @ObservedObject var session: MeetingSession
    /// Which meeting the menu asked for, if it asked for one.
    @ObservedObject var navigator: MeetingsNavigator
    /// Subviews using L() must observe the localization (GRABLI).
    @ObservedObject private var loc = Localization.shared
    /// Summaries arriving for older meetings — each one is a row that has
    /// something to say where it had nothing.
    @ObservedObject private var summaries = MeetingSummaries.shared
    /// Contents blocks arriving for older meetings — each one turns a
    /// fifty-minute transcript into a dozen findable moments.
    @ObservedObject private var sections = MeetingSections.shared
    /// The semantic index — meetings that match what was typed by MEANING,
    /// which is a different question from "contains these characters" and gets
    /// its own group in the list.
    @ObservedObject private var meaning = MeetingMeaning.shared
    /// Whether the optional text model may still be offered here. Observed so
    /// that "Not now" empties every surface at once.
    @ObservedObject private var offer = LocalTextModelOffer.shared
    let onStop: () -> Void
    /// The window owner resizes/levels the panel when the library opens.

    // The library is always here. It used to fold away, and during a live
    // call it folded ITSELF, turning the window into a glanceable strip over
    // the meeting. The pill does that job now (MeetingPill), so the window is
    // free to be one thing — a library with a transcript beside it — instead
    // of two modes with a toggle, an animated width and a rule about when each
    // applies.
    /// The library opens with the keyboard in the list — the way Mail and
    /// Notes open. It is also what makes the selected row read in the accent
    /// colour instead of the grey AppKit gives an unfocused list, and it means
    /// the arrow keys walk the meetings from the moment the window appears.
    @FocusState private var listFocused: Bool
    /// Drives the field's own focus ring (see searchField).
    @FocusState private var searchFocused: Bool
    @State private var selection: Selection?
    @State private var meetings: [ArchivedMeeting] = []
    /// Which `reload()` is the current one. Loads run in the background and
    /// may finish out of order; only the latest is allowed to land.
    @State private var reloadGeneration = 0
    @State private var query = ""
    /// The toolbar's Rename… routes to the same popover the title carries,
    /// so there is one editing surface no matter how you get to it.
    @State private var renamingFromMenu = false

    enum Selection: Hashable {
        case live
        case archived(URL)
        /// The same transcript, opened AT a moment — the clock time of the
        /// section that matched. A separate case rather than an optional on
        /// `archived` so the List can tell a moment hit apart from the plain
        /// row for the same meeting, and so selecting one is an ordinary list
        /// selection instead of a click handler bolted onto a row.
        case moment(URL, String)
        /// An answer to the question in the field. A selection like any other,
        /// so it lives and dies with the list rather than as a sheet bolted on
        /// top: clicking any meeting returns, and nothing the reader was
        /// looking at is destroyed.
        case answer(String)

        var url: URL? {
            switch self {
            case .live, .answer: return nil
            case .archived(let url), .moment(let url, _): return url
            }
        }

        var time: String? {
            if case .moment(_, let time) = self { return time }
            return nil
        }
    }

    /// Two columns, built by hand rather than with NavigationSplitView.
    ///
    /// The split view is written for a document window with a real NSToolbar,
    /// and this is a utility NSPanel that has none. Given that, it drew its own
    /// chrome instead: a strip under the title bar holding a second, floating
    /// copy of the sidebar toggle, and a rounded card for the sidebar inset
    /// from the window on a grid of its own. That is the whole of "things do
    /// not line up" — two panes laid out by two different authorities. An
    /// HStack has no opinions, so both columns sit on MeetingsChrome's grid and
    /// the rule under the two headers is a single line.
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: MeetingsChrome.sidebarWidth)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // During a call the window is a glanceable strip over the call;
            // opened afterwards it is a library. The sidebar decides which —
            // and does so before the archive has loaded, so the window is on
            // screen immediately even when the disk (iCloud) is slow.
            if session.isActive {
                selection = .live
            } else {
                // After the window has actually taken key status (AppDelegate
                // defers that by a runloop turn), or the request lands on a
                // window that cannot hold focus yet and is dropped.
                DispatchQueue.main.async { listFocused = true }
            }
            reload {
                if !session.isActive, selection == nil {
                    selection = meetings.first.map { .archived($0.url) }
                }
                // A meeting picked in the menu wins over both defaults — the
                // window is opening BECAUSE of it.
                applyRequest()
                backfillSummaries()
            }
        }
        // The same request arriving at a window that already exists.
        .onChange(of: navigator.requests) { _ in applyRequest() }
        .onChange(of: session.isActive) { active in
            // A session that has just started needs no list to be shown.
            if active { selection = .live }
            // A finished session becomes a file: refresh and follow it.
            reload {
                if !active, let newest = meetings.first { selection = .archived(newest.url) }
            }
            // Deliberately NOT backfilling here. A session that has just gone
            // inactive is still being titled and summarized by finalizeIfDrained,
            // and a backfill started in the same breath would ask the model
            // about the very same meeting twice. The next time the library is
            // opened is soon enough.
        }
        // A summary landed on disk for one of the older meetings: pick it up.
        // Only ever a handful of times, and only while the backfill runs —
        // there is nothing here that ticks.
        .onChange(of: summaries.written) { _ in reload() }
        // A contents block landed. Same story, and just as rare: only while
        // the backfill runs, and nothing here ticks.
        .onChange(of: sections.written) { _ in reload() }
    }

    // MARK: - Sidebar

    /// The library column: a search row of exactly the same height as the
    /// transcript's header, then the list. The two headers share one horizontal
    /// rule that runs the full width of the window — the cheapest possible
    /// proof that the two panes are one surface and not two.
    private var sidebar: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            searchArea
            list
            // The first of the two places the missing model is physically
            // visible: a column of meetings that are all named by their date.
            // At the FOOT of the column, under a rule — where a mail client
            // puts "downloading messages": it is the last thing read, not the
            // first, and it pushes nothing out of the way.
            if showsLibraryOffer {
                Divider()
                TextModelOffer(line: L("Your meetings are named by their date. A one-time download, kept on this Mac, writes titles, summaries and a table of contents."))
            }
        }
        // An explicit AppKit sidebar material, not the window's background:
        // it distinguishes the library from the transcript in both themes, and
        // (state = .active) it keeps doing so while the panel is not key.
        .background(SidebarMaterial())
    }

    private var list: some View {
        List(selection: $selection) {
            if session.isActive {
                Section(L("Now")) {
                    liveRow.tag(Selection.live)
                }
            }
            ForEach(groupedMeetings, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        meetingRow(meeting).tag(Selection.archived(meeting.url))
                    }
                }
            }
            // Meetings that don't contain the words but were about them. Last,
            // and under a heading that says why they are here: the exact hits
            // are what was asked for, and these are the answer to a question
            // that wasn't quite typed.
            if !related.isEmpty {
                Section(L("Related by meaning")) {
                    // Asking is one row, not a second field. Nothing is ever
                    // inferred from what was typed — this appears because the
                    // search already found passages, and is clicked because
                    // somebody wanted an answer. It cannot offer to answer a
                    // question it has no sources for, which is the failure this
                    // whole category ships with.
                    // Off by default, and off means absent. A greyed-out row
                    // would still be telling somebody who chose local-only that
                    // there is an online thing here they are missing.
                    if Settings.shared.askArchive {
                        askRow.tag(Selection.answer(query))
                    }
                    ForEach(related) { hit in
                        relatedRow(hit).tag(hit.selection)
                    }
                }
            }
        }
        // Selecting the ask row is what starts the work. Not typing, not a
        // timer, not a guess about what the words meant — a person chose it.
        .onChange(of: selection) { picked in
            guard case .answer(let question) = picked else { return }
            guard answer.question != question || answer.failure != nil else { return }
            answer.ask(question, from: sources(from: related), using: oracle)
        }
        .listStyle(.sidebar)
        // The list draws itself on the sidebar material above, instead of
        // stacking a second, opaque panel of its own on top of it.
        .scrollContentBackground(.hidden)
        .focused($listFocused)
        .overlay {
            if filtered.isEmpty && related.isEmpty && !session.isActive {
                ContentUnavailableView {
                    Label(meetings.isEmpty ? L("No meetings yet") : L("Nothing found"),
                          systemImage: meetings.isEmpty ? "text.bubble" : "magnifyingglass")
                } description: {
                    Text(meetings.isEmpty
                         ? L("Start a transcript from the menu bar during a call.")
                         : L("No transcript contains that."))
                } actions: {
                    // The second place the absence shows, and the sharper of
                    // the two: the search that came back empty matches by
                    // MEANING, and meaning is read out of the summaries and
                    // section lines the model writes. With no model there is
                    // nothing to match against — this search is not worse, it
                    // does not function. An empty result is exactly when to
                    // say so.
                    if showsSearchOffer {
                        TextModelOffer(line: L("Searching by meaning needs summaries and sections, and nothing on this Mac writes them yet. A one-time download does, and it stays here."))
                            .frame(maxWidth: MeetingsChrome.sidebarWidth)
                    }
                }
            }
        }
        // What was typed, scored against every meeting's subject. English is
        // answered on this keystroke; another language waits for the typing to
        // settle and hops through Apple Translation. Nothing here polls.
        .onChange(of: query) { meaning.search($0) }
    }

    /// The library's header: the control that closes the library, and nothing
    /// else — it is the title-bar band, and the window's own buttons own most
    /// of it.
    ///
    /// The toggle lives HERE rather than in the transcript's header whenever
    /// the sidebar is open, for two reasons. It is the control that hides this
    /// column, so it belongs over this column and not across the divider from
    /// it. And moving it out gives the transcript's header a single left edge:
    /// with the toggle in it, the meeting's title started 50pt in while the
    /// words underneath started at 14, which — next to the divider, which is a
    /// hard vertical reference — was the most visible instance of "things do
    /// not line up".
    private var headerRow: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
        }
        // The library holds the window's top-left corner while it is open, and
        // the window's own buttons live there — so this row starts after them
        // rather than on the list's margin. Everything BELOW the row keeps the
        // sidebar's 10pt inset; the row above them is the one place in the
        // window where the system, not the design, owns the left edge.
        .padding(.leading, MeetingsChrome.trafficLights)
        .padding(.trailing, MeetingsChrome.sidebarInset)
        .frame(height: MeetingsChrome.headerHeight)
    }

    /// The search field, across the column, and one line saying what it can do.
    ///
    /// The field used to share the header row with the sidebar toggle, which
    /// left it about 120pt — narrow enough that "Search transcripts" truncated
    /// in ENGLISH, which is why the placeholder had been cut to one word. That
    /// was the wrong thing to shrink. This search matches by MEANING, and a
    /// magnifying glass with "Search" beside it promises the opposite: literal
    /// words. Below the divider the field has the whole 240pt column, which is
    /// room for a placeholder that asks a question and for a caption that says
    /// what will happen to the answer.
    private var searchArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
            // Only until the first keystroke. It is an invitation, and once
            // typing has started it would be a permanent caption on a working
            // control — the results themselves say what the search did.
            // The invitation goes once typing starts; the tags stay, because
            // they are a control rather than a caption.
            if query.isEmpty {
                Text(L("Words, or a question — I'll match by meaning"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            tagFilterRow
        }
        .padding(.horizontal, MeetingsChrome.sidebarInset)
        .padding(.vertical, 8)
    }

    /// The archive's tags, most-used first, as a scrollable line of chips —
    /// always, not only while the field is empty.
    ///
    /// It used to hide as soon as a tag was chosen, which quietly made two
    /// things impossible: picking a SECOND tag (the row was gone) and seeing
    /// which ones were on. Filtering by two tags is the ordinary way to narrow
    /// — "this client, this product" — and it has to be reachable from where
    /// the first one was.
    @ViewBuilder
    private var tagFilterRow: some View {
        let all = MeetingArchive.tagCounts(in: meetings)
        let active = Set(MeetingSearch.split(query: query).tags)
        if !all.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(all, id: \.tag) { item in
                        TagChip(tag: item.tag,
                                onFilter: { toggleTagFilter(item.tag) },
                                active: active.contains(item.tag))
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
        }
    }

    /// Adds a tag to the filter, or takes it out if it is already there.
    ///
    /// The words in the field are kept either way: that is what makes
    /// "#wholecall pricing" — search inside the tag rather than across the
    /// whole archive — something you can build by clicking and then typing,
    /// instead of a syntax you have to know.
    private func toggleTagFilter(_ tag: String) {
        var (tags, text) = MeetingSearch.split(query: query)
        if let at = tags.firstIndex(of: tag) { tags.remove(at: at) } else { tags.append(tag) }
        let parts = tags.map { "#\($0)" } + (text.isEmpty ? [] : [text])
        query = parts.joined(separator: " ")
    }

    /// Search, hand-built rather than `.searchable`: the stock sidebar field is
    /// a tall pill on its own inset, which is what put the sidebar and the
    /// transcript on two different grids. This one sits at the list's own
    /// margin, on the same left edge as the rows under it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            TextField(L("What do you want to find?"), text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                .help(L("Search transcripts"))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(L("Clear search"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        // Lighter than a selected row and outlined instead of filled: the two
        // are the same shape at the same width, and the field must not read as
        // a list item that happens to be at the top. Focused, the outline is
        // the brand indigo — the system's own focus ring is drawn around
        // AppKit's field, and this one is ours.
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(searchFocused ? Brand.indigoLabel : Color.primary.opacity(0.12),
                              lineWidth: searchFocused ? 1.5 : 1)
        )
    }

    private var liveRow: some View {
        HStack(spacing: 8) {
            PulsingDot()
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Recording now"))
                    .font(.callout.weight(.medium))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func meetingRow(_ meeting: ArchivedMeeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // A named meeting leads with its subject; an unnamed one is
            // known by when it happened.
            Text(meeting.title ?? timeOfDay(meeting.started))
                .font(.callout.weight(.medium))
                .lineLimit(2)
            // One text run with one separator, so the gaps are even however
            // many facts a meeting happens to have; the speaker count is a
            // labelled figure rather than a third kind of separator.
            HStack(spacing: 7) {
                let facts = metaFacts(meeting)
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                }
                if meeting.speakers.count > 1 {
                    // Hand-built instead of a Label: the stock label style
                    // leaves a gap wide enough to read as another column.
                    HStack(spacing: 3) {
                        Image(systemName: "person.wave.2").imageScale(.small)
                        Text("\(meeting.speakers.count)")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // What the meeting was about, in one sentence the on-device model
            // wrote when the transcript closed.
            //
            // This line used to be the meeting's FIRST UTTERANCE, which is
            // whatever noise opened the call: "Thank you.", "*scoffs*", "Так,
            // что там, как у тебя дела?". Three rows of that told you nothing
            // about three meetings. A meeting with no summary yet shows
            // nothing here — the first utterance is not a fallback, it is the
            // thing being removed.
            // A PREVIEW of the summary, not the summary: two lines, cut. The
            // full sentence is in the transcript's head now, where there is
            // width to read it — which is what lets this row stay a fixed
            // enough height to scan a list by. Mail clients settled this
            // decades ago and cap their preview at three lines; two is what
            // fits beside a title that may take two of its own.
            if let summary = meeting.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    // Two lines, as a mail client previews a message: the
                    // column is 240pt wide and a third line would make every
                    // row taller than the scanning this list is for. A
                    // sentence that runs past them is readable in full as the
                    // row's tooltip — which costs no layout and nothing at
                    // rest.
                    .lineLimit(2)
                    .help(summary)
            }
            // Where the meeting belongs, last: the eye scans the title and the
            // preview, and the tags answer a different question — which pile is
            // this in — that is only asked once the row has been found.
            if !meeting.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(meeting.tags.prefix(4), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Brand.indigoLabel.opacity(0.12)))
                            .foregroundStyle(Brand.indigoLabel)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    /// A row under "Related by meaning". Either the meeting as a whole (its
    /// title or its summary was what matched) or a MOMENT inside it — a
    /// section, with the line the model wrote about it and the time it starts.
    struct RelatedHit: Identifiable {
        let meeting: ArchivedMeeting
        /// nil when the whole meeting matched rather than one passage of it.
        let section: TranscriptSection?

        var selection: Selection {
            guard let section else { return .archived(meeting.url) }
            return .moment(meeting.url, section.time)
        }
        var id: Selection { selection }
    }

    @ViewBuilder
    private func relatedRow(_ hit: RelatedHit) -> some View {
        if let section = hit.section {
            // The section's line leads, because it is the answer; the meeting
            // it came out of is the context underneath. The other way round —
            // the meeting first — is what the row above the "Related" heading
            // already does, and it is what makes a fifty-minute transcript
            // look like the answer to a three-minute question.
            VStack(alignment: .leading, spacing: 3) {
                Text(section.line)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                HStack(spacing: 7) {
                    // Monospaced, like every other time in this window, so a
                    // column of them lines up.
                    Text(clock(section.time))
                        .font(.caption.monospacedDigit())
                    Text(hit.meeting.title ?? dayAndTime(hit.meeting.started))
                        .lineLimit(1)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .help(section.line)
        } else {
            meetingRow(hit.meeting)
        }
    }

    /// "10:26:17" as the hour and minute a person would say. The seconds are
    /// in the transcript where they belong; in a list they are noise.
    private func clock(_ time: String) -> String {
        let parts = time.split(separator: ":")
        return parts.count >= 2 ? "\(parts[0]):\(parts[1])" : time
    }

    /// Time (unless it is already the row's title) and length — omitting a
    /// duration too short to state, so a one-line meeting doesn't advertise
    /// "0 s".
    private func metaFacts(_ meeting: ArchivedMeeting) -> [String] {
        var facts: [String] = []
        if meeting.title != nil { facts.append(timeOfDay(meeting.started)) }
        if let duration = meeting.duration, duration >= 1 {
            facts.append(compactDuration(duration))
        }
        return facts
    }

    // MARK: - Detail

    @ViewBuilder
    /// The row that offers an answer. Deliberately plain — a label rather than
    /// a sparkle, because a marker that is also a trigger teaches people that
    /// AI is a button rather than a property of what they are looking at.
    private var askRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(Brand.indigoLabel)
            Text(Lf("Answer this from %@ moments", "\(related.count)"))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var answerPane: some View {
        AnswerPane(answer: answer) { source in
            // Going to the passage is an ordinary selection, so the answer
            // stays behind in the list and one click comes back to it.
            selection = source.time.map { .moment(source.url, $0) } ?? .archived(source.url)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .answer:
            answerPane
        case .live:
            // A running meeting has no title yet (it is written when the
            // transcript closes), and its file is open for appending — so
            // titling waits until it's finished.
            TranscriptPane(entries: session.displayEntries,
                           // A scheduled call shows its real name from the
                           // first second — that is the point of reading the
                           // calendar at session start rather than naming the
                           // transcript at the end. Unscheduled ones say what
                           // they are.
                           title: session.scheduledTitle ?? L("Recording now"),
                           subtitle: nil,
                           // A live header has no subtitle line to hang them on
                           // — and the cast is still changing, so a row of
                           // chips would grow and shuffle mid-call. Renaming a
                           // voice during a call stays where it always was: on
                           // the speaker's own turn.
                           participants: [],
                           live: session,
                           onStop: onStop,
                           onRename: { old, new in session.renameSpeaker(from: old, to: new) },
                           onRetitle: nil,
                           openRename: .constant(false),
                           jumpTo: nil,
                           ) {
                // A meeting in progress has no file yet — but the text on
                // screen is exactly as copyable as an archived one, and taking
                // the transcript out mid-call is what the owner reaches for.
                Button(L("Copy transcript")) {
                    TranscriptCopy.put(TranscriptCopy.transcript(session.displayEntries))
                }
            }
        case .archived(let url), .moment(let url, _):
            if let meeting = meetings.first(where: { $0.url == url }) {
                TranscriptPane(entries: meeting.entries,
                               title: meeting.title ?? dayAndTime(meeting.started),
                               subtitle: subtitle(for: meeting),
                               participants: participants(of: meeting),
                               live: nil,
                               onStop: nil,
                               tags: meeting.tags,
                               knownTags: MeetingArchive.tagCounts(in: meetings),
                               onTags: { updated in
                                   MeetingArchive.setTags(updated, in: url)
                                   reload()
                               },
                               onTagFilter: { tag in
                                   toggleTagFilter(tag)
                               },
                               onRename: { old, new in
                                   MeetingArchive.rename(speaker: old, to: new, in: url)
                                   reload()
                               },
                               onRetitle: { newTitle in
                                   // The file is renamed too, so the meeting's
                                   // identity moves — follow it, or the pane
                                   // would show "select a meeting".
                                   let moved = MeetingArchive.retitle(meeting, to: newTitle)
                                   reload()
                                   selection = .archived(moved)
                               },
                               openRename: $renamingFromMenu,
                               // The whole point of a section hit: the
                               // transcript opens where the discussion was,
                               // not at the top of a fifty-minute file.
                               jumpTo: selection?.time,
                               overviewSummary: meeting.summary,
                               overviewSections: meeting.sections,
                               onRecut: { recut(meeting, to: $0) },
                               recutting: recutting == meeting.url,
                               recutLevel: sectionLevel[meeting.url],

                               notice: declined(meeting)
                                   ? AnyView(TextModelOffer(line: L("The built-in model had nothing to say about this meeting. A one-time download, kept on this Mac, is not restricted that way.")))
                                   : nil) {
                    Button(L("Rename meeting…")) { renamingFromMenu = true }
                    Button(L("Copy transcript")) {
                        TranscriptCopy.put(TranscriptCopy.transcript(meeting.entries))
                    }
                    Button(L("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
                    }
                    Divider()
                    Button(L("Move to Trash"), role: .destructive) {
                        MeetingArchive.delete(meeting)
                        selection = nil
                        reload()
                    }
                }
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    /// Nothing selected — but the window still has to look like the same
    /// window, so the placeholder carries the same header (and therefore the
    /// same sidebar toggle) as a transcript would.
    private var placeholder: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // As in a transcript's header: the toggle is here only when
                // there is no library header for it to sit on. The empty row
                // stays either way, so the rule under it is still one line
                // across the window.
                Spacer(minLength: 0)
            }
            .frame(height: MeetingsChrome.headerHeight)
            .padding(.leading, MeetingsChrome.inset)
            .padding(.trailing, MeetingsChrome.inset)
            Divider()
            VStack(spacing: 10) {
                // Still: nothing is happening, and an ornament that dances on
                // an empty pane is the window asking to be looked at.
                WaveMark(height: 40, animated: false).opacity(0.45)
                Text(session.isActive ? L("Recording now") : L("Select a meeting"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }


    // MARK: - Data

    private var filtered: [ArchivedMeeting] {
        MeetingSearch.literal(meetings, query: query)
    }

    /// Meetings that are ABOUT what was typed without containing it.
    ///
    /// Empty unless the owner has typed something, unless the model is on this
    /// Mac, and unless something actually scores — so the group below appears
    /// only when it has an answer. The literal hits are excluded here rather
    /// than in the ranking: they are already on screen above, and the same
    /// meeting offered twice reads as two answers.
    /// The passages an answer would be allowed to use — the same ones already
    /// on screen under "Related by meaning", with the words that go with them.
    ///
    /// The window is eight entries from the moment.
    ///
    /// Three was too mean. A decision is rarely made in the line where the
    /// subject is raised — somebody proposes, somebody objects, and the thing
    /// that was actually agreed lands four or five turns later, outside a
    /// three-line window. Eight of them across five passages is still a prompt
    /// rather than a transcript, and it is the strongest lever available here:
    /// widening the window sends MORE OF WHAT WAS ACTUALLY SAID, where every
    /// other option sends our own summary of it.
    ///
    /// It stays short enough for the source card to be checked by looking
    /// rather than by reading, which is the whole point of showing it.
    private func sources(from hits: [RelatedHit]) -> [MeetingSource] {
        hits.compactMap { hit -> MeetingSource? in
            let entries = hit.meeting.entries
            let lines: [TranscriptEntry]
            if let section = hit.section,
               let start = entries.firstIndex(where: { $0.time == section.time }) {
                lines = Array(entries[start..<min(start + 8, entries.count)])
            } else {
                lines = Array(entries.prefix(8))
            }
            guard !lines.isEmpty else { return nil }
            return MeetingSource(
                url: hit.meeting.url,
                title: hit.meeting.title ?? hit.meeting.url.deletingPathExtension().lastPathComponent,
                date: DateFormatter.localizedString(from: hit.meeting.started,
                                                    dateStyle: .medium, timeStyle: .none),
                time: hit.section?.time,
                text: lines.map { "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n"))
        }
    }

    /// The answer currently on screen, if any. A StateObject rather than local
    /// state because it outlives every redraw of the list beneath it and has to
    /// stay stoppable while the reader scrolls.
    /// Which meeting is being recut, if any — so the pane can say so and the
    /// menu cannot be used twice at once.
    @State private var recutting: URL?
    /// Which granularity each meeting is currently showing. Only for the
    /// control's own highlight — the truth is the file, and a meeting nobody
    /// has recut simply has no entry here.
    @State private var sectionLevel: [URL: MeetingPolicy.SectionDetail] = [:]

    /// Cut one meeting's contents again at a chosen granularity.
    ///
    /// One meeting, not the archive: recutting everything takes minutes of
    /// model time and answers a question nobody asked. This is somebody
    /// looking at THIS call and wanting a finer map of it, and it takes the
    /// seconds a dozen short model calls take.
    private func recut(_ meeting: ArchivedMeeting, to detail: MeetingPolicy.SectionDetail) {
        guard recutting == nil else { return }
        // A cut already made is put back instantly. Half a minute is a fair
        // price for a new shape and an absurd one for going back to the shape
        // you had a moment ago.
        if let kept = SectionCache.cut(meeting.url, meeting.entries, detail) {
            _ = MeetingArchive.setSections(kept, heading: L("Contents"), in: meeting.url)
            sectionLevel[meeting.url] = detail
            reload()
            return
        }
        recutting = meeting.url
        Task { @MainActor in
            defer { recutting = nil }
            let sections = await MeetingSectioner.sections(for: meeting.entries, detail: detail)
            guard !sections.isEmpty else { return }
            SectionCache.remember(sections, for: meeting.url, meeting.entries, detail)
            _ = MeetingArchive.setSections(sections, heading: L("Contents"), in: meeting.url)
            sectionLevel[meeting.url] = detail
            reload()
        }
    }

    @StateObject private var answer = MeetingAnswer()

    /// Who answers. One line to change when a hosted tier arrives — everything
    /// above this knows only the protocol.
    private var oracle: MeetingOracle { ClaudeAPIOracle() }

    private var related: [RelatedHit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let exact = Set(filtered.map(\.url))
        return MeetingSearch.related(meaning.matches, background: meaning.background,
                                     excluding: exact)
            .compactMap { match -> RelatedHit? in
                guard let meeting = meetings.first(where: { $0.url == match.id })
                else { return nil }
                // The moment is only as good as the line that goes with it: a
                // contents block rewritten between the query and the click
                // would leave a timestamp pointing at nothing to say, and then
                // the row is simply the meeting again.
                let section = match.moment.flatMap { moment in
                    meeting.sections.first { $0.time == moment }
                }
                return RelatedHit(meeting: meeting, section: section)
            }
    }

    // MARK: - Where the missing text model is offered

    /// The library's own offer: there are meetings, and not one of them has a
    /// name.
    ///
    /// ALL of them rather than any: a single untitled meeting is the newest
    /// one, still being summarized, and pitching a download at that is noise.
    /// Nothing titled anywhere means nothing on this Mac can title anything —
    /// which is the fact worth telling somebody. Never during a call, and never
    /// while the search's own offer is on screen: one surface, one offer.
    private var showsLibraryOffer: Bool {
        offer.allowed && !session.isActive && !meetings.isEmpty
            && !meetings.contains { $0.title != nil }
            && !showsSearchOffer
    }

    /// The search's offer: something was typed, nothing came back, and nothing
    /// could have — no meeting in the archive has a summary or a contents
    /// block, so the semantic index has an empty vocabulary to score against.
    private var showsSearchOffer: Bool {
        offer.allowed && !query.trimmingCharacters(in: .whitespaces).isEmpty
            && !meetings.isEmpty && filtered.isEmpty && related.isEmpty
            && !meetings.contains { $0.summary != nil || !$0.sections.isEmpty }
    }

    /// The macOS 26 case: a meeting Apple's model would not describe.
    ///
    /// A generic pitch would be noise on macOS 26 — the built-in model names
    /// meetings there perfectly well. What it does instead is refuse content it
    /// judges sensitive ("Detected content likely to be unsafe" — 112 of them
    /// in one of the owner's logs, most of an archive that happens to discuss
    /// medicine), and a refusal is a specific event worth answering
    /// specifically.
    ///
    /// Recognised by its shape rather than by a flag, because the refusal is
    /// not recorded anywhere per meeting: the backfill worked — other meetings
    /// came back with summaries and contents — and this one, with a real
    /// transcript, came back with neither. A model that is running and produced
    /// nothing here declined here. The backfill has to be finished before that
    /// reasoning holds, or the answer is simply "not its turn yet".
    private func declined(_ meeting: ArchivedMeeting) -> Bool {
        guard #available(macOS 26, *), offer.allowed else { return false }
        guard !summaries.running, meeting.entries.count >= 3 else { return false }
        guard meeting.summary == nil, meeting.sections.isEmpty else { return false }
        return meetings.contains { $0.url != meeting.url && $0.summary != nil }
    }

    private var groupedMeetings: [(title: String, meetings: [ArchivedMeeting])] {
        var groups: [(title: String, meetings: [ArchivedMeeting])] = []
        for meeting in filtered {
            let title = dayTitle(meeting.started)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].meetings.append(meeting)
            } else {
                groups.append((title, [meeting]))
            }
        }
        return groups
    }

    /// Show the meeting the menu asked for. A request with no meeting in it
    /// ("Show All Meetings…", or the window opening by itself) leaves the
    /// selection alone — the window simply comes forward on whatever it held.
    private func applyRequest() {
        guard let url = navigator.target else { return }
        // Picked from the menu, which reads the folder itself: the transcript
        // may be newer than the list this window last loaded.
        if !meetings.contains(where: { $0.url == url }) { reload() }
        selection = .archived(url)
    }

    /// Reads the archive off the main thread. `MeetingArchive.list()` opens
    /// every transcript in the folder, and the folder lives in iCloud-synced
    /// Documents — reading a file iCloud has evicted blocks on a network
    /// download, and on the main thread that froze the whole app for 16
    /// seconds at the start of a live meeting (caught by the hang watchdog,
    /// 2026-08-17). The window opens on what it has; the list lands when the
    /// disk answers, and whatever needed the list runs in `done`.
    private func reload(then done: @escaping () -> Void = {}) {
        reloadGeneration += 1
        let generation = reloadGeneration
        let youLabel = L("You")
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = MeetingArchive.list(youLabel: youLabel)
            DispatchQueue.main.async {
                // A reload started later has fresher facts (a rename, a
                // delete) — an older read arriving after it must not win.
                guard generation == reloadGeneration else { return }
                // Keep the instance we already have wherever the file still
                // says the same thing. This is the whole fix for the reader's
                // place jumping: a background writer touching ONE meeting used
                // to replace all 37, and the open transcript — new struct, new
                // entry identities, a summary above it re-laid out — moved
                // under whoever was reading it. Now only what actually changed
                // becomes a new value, and SwiftUI has nothing to redraw for
                // the rest.
                let previous = Dictionary(uniqueKeysWithValues: meetings.map { ($0.url, $0) })
                meetings = loaded.map { fresh in
                    if let old = previous[fresh.url], old.sameContent(as: fresh) { return old }
                    return fresh
                }
                // Eighteen short strings: cheap enough to do inline, and
                // cheapest of all on a reload that changed nothing (the
                // vectors are kept).
                meaning.index(meetings)
                done()
            }
        }
    }

    /// Fills in the summaries of meetings recorded before there were any.
    ///
    /// Not while a call is being transcribed: the model and the machine belong
    /// to the meeting in progress, and an old transcript can wait until it
    /// isn't.
    private func backfillSummaries() {
        guard !session.isActive else { return }
        // The same question again before every meeting in the queue — a call
        // can start halfway through, and then the rest waits.
        MeetingSummaries.shared.backfill(meetings) { [session] in !session.isActive }
        // And the contents blocks, which are the same job an order of
        // magnitude larger — a dozen model calls per meeting instead of one.
        // Started in the same breath on purpose: it waits for the summaries to
        // finish by itself (they share the one on-device model), and asks the
        // same question again before every single call it makes.
        MeetingSections.shared.backfill(meetings) { [session] in !session.isActive }
    }

    /// Who was in the meeting, in the order they first spoke — the same order
    /// (and therefore the same colours) the turns below use.
    ///
    /// Taken from the entries rather than from `meeting.speakers`, because the
    /// header needs one fact that list does not carry: which of these names is
    /// the owner. "You" is not a name the app gave a voice, it is the person
    /// reading the window, and it is the one participant that cannot be
    /// renamed.
    /// `isYou` is trustworthy here in a way it once was not: the parser used
    /// to decide it by comparing the transcript's label with the CURRENT
    /// interface language, so switching the app to German turned every English
    /// "You" in the archive into a stranger — a stolen palette slot, and a
    /// rename offered to the reader. `MeetingArchive.youLabels` now answers
    /// that question in all eleven languages at once, so this view can simply
    /// believe the flag.
    private func participants(of meeting: ArchivedMeeting) -> [Participant] {
        var seen = Set<String>()
        return meeting.entries
            .filter { seen.insert($0.speaker).inserted }
            .map { Participant(name: $0.speaker, isYou: $0.isYou) }
    }

    /// When it happened and how long it ran — assembled from the facts this
    /// meeting actually has.
    ///
    /// Built by joining a list rather than by concatenating around a separator:
    /// the old form spliced " · " in unconditionally, so a meeting with no
    /// duration and no speakers yet — an empty or just-started one — hung a
    /// dangling separator off the end of its date.
    private func subtitle(for meeting: ArchivedMeeting) -> String {
        var parts: [String] = []
        // The title already says WHAT it was, so the date belongs here; an
        // untitled meeting is named by its date and must not repeat it.
        if meeting.title != nil { parts.append(dayAndTime(meeting.started)) }
        // Same rule as the list: a meeting too short to measure says nothing
        // rather than "0 s".
        if let duration = meeting.duration, duration >= 1 {
            parts.append(compactDuration(duration))
        }
        // The participants used to be spliced in here as plain text. They are
        // chips now (see Participant): the same words, in the speaker's own
        // colour, and each one opens the rename popover its turns already
        // carry — because the moment you want to fix "Speaker 2" is the moment
        // you are looking at the header, not twenty minutes up the transcript.
        return parts.joined(separator: " · ")
    }

    // MARK: - Formatting

    private func elapsed(at date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(session.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func compactDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        return minutes >= 1 ? Lf("%d min", minutes) : Lf("%d s", Int(duration))
    }

    private func dayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    private func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func dayAndTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }
}

/// `defaults write com.valentynbudanov.Dictate dbgTrace -bool YES` makes the
/// transcript print which views SwiftUI re-evaluates and why. Kept because the
/// question "does hovering re-render the whole list?" has to be answerable by
/// measurement, not by reading the code.
enum DBG {
    static let trace = UserDefaults.standard.bool(forKey: "dbgTrace")
}

// MARK: - Shared chrome

/// The window's grid. Both panes hang off these three numbers, which is the
/// whole reason the search field, the transcript's title and the two controls
/// end up on the same lines instead of on four private ones.
enum MeetingsChrome {
    /// Height of the header row in BOTH panes, so the rule under them is one
    /// unbroken line across the window.
    ///
    /// 40 and not the 46 it was, because this row is now the title bar as well:
    /// AppKit centres the traffic lights in the standard 28pt title-bar band
    /// whatever the content under it does, so every point this row is taller
    /// than that band is a point the window's own buttons sit above everything
    /// beside them. At 40 the two centres are 5pt apart, which reads as one
    /// row; at 46 it read as buttons floating over a row.
    static let headerHeight: CGFloat = 40
    /// Margin of the transcript pane — its header, its turns and its copy
    /// column all start here.
    static let inset: CGFloat = 14
    /// The sidebar's margin, matched to the inset a `.sidebar` list gives its
    /// own rows so the search field sits on the same left edge as the titles
    /// under it.
    static let sidebarInset: CGFloat = 10
    /// What the window's own buttons occupy at the top-left, now that the
    /// header row IS the title bar. Measured on the built window, not guessed:
    /// the close button starts at x=7 and the zoom button ends at x=70, so this
    /// is that plus a column of air. Whatever is first in the top-left row —
    /// the search field's toggle with the library open, the transcript's toggle
    /// without it — starts here.
    static let trafficLights: CGFloat = 78
    /// The library column. Fixed, not draggable: a meeting's title, its time
    /// and a line of its preview are what a row has to show, and this is the
    /// width that shows them. The window widens by exactly this much when the
    /// library opens (AppDelegate), so the transcript keeps the width it had.
    static let sidebarWidth: CGFloat = 300
}

/// The window's one button shape: a borderless glyph in a 28pt target with a
/// 22pt chip behind it on hover — deliberately the same geometry as the
/// per-turn copy control (TurnCopy), so the ⋯ in the header and the copy chips
/// down the transcript share a centre line instead of being two ideas.
/// Stop, in this window's own idiom rather than the system's default push
/// button.
///
/// It was `Button("Stop")` with the standard bordered style, and next to a
/// header made of quiet glyphs and dim monospaced digits it read as a piece of
/// a different application — the one loud rectangle on the surface. The chrome
/// here has a shape already: a compact label that carries no weight at rest and
/// fills faintly under the pointer (ChromeGlyph). This is that shape, in red,
/// because red is what this app already uses for "a recording is running" —
/// the menu's stop item, the live row's dot, the menu bar mark. The button
/// ending the recording and the mark announcing it now say the same colour.
///
/// Semantic `.red` rather than a brand colour on purpose: the brand gradient
/// means Dictate, and stopping a recording is not a moment to advertise.
private struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "stop.fill").imageScale(.small)
                Text(L("Stop")).font(.callout)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(hovering ? 0.18 : 0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .help(L("Stop recording"))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

private struct ChromeButton: View {
    let icon: String
    let help: String
    /// nil = the chrome's own quiet grey. A colour here is reserved for the
    /// one control that ends something (stop), so the exception keeps its
    /// meaning: if every glyph were tinted, none of them would read.
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ChromeGlyph(icon: icon, hovering: hovering, tint: tint)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// What a chrome control looks like — shared by the button and by the ⋯ menu,
/// which cannot use the button but must not look different.
private struct ChromeGlyph: View {
    let icon: String
    let hovering: Bool
    var tint: Color? = nil

    var body: some View {
        Image(systemName: icon)
            .imageScale(.medium)
            .frame(width: TurnCopy.chipSize, height: TurnCopy.chipSize)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill((tint ?? Color.primary).opacity(hovering ? (tint == nil ? 0.08 : 0.16) : 0))
            )
            // Same rule as the copy chip: the target is the square around the
            // chip, so most of what takes the click is invisible padding.
            .frame(width: TurnCopy.targetSize, height: TurnCopy.targetSize)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// The sidebar's surface: the window's own background colour, opaque, next to
/// the transcript's paper.
///
/// This was an `NSVisualEffectView` with the `.sidebar` material, and the
/// translucency was the problem rather than the style. Blending BEHIND the
/// window, it sampled whatever was behind the panel — which for this window is
/// the video call it floats over, so the library's colour drifted with the
/// call's picture and shimmered whenever anyone moved, and AppKit re-sampled
/// that backdrop as it changed. Blending WITHIN the window instead fixed the
/// shimmer but left the surface a near-white #FBFBFB against a #FFFEFF
/// transcript: four levels apart, which is to say the two panes did not read as
/// two surfaces at all.
///
/// Nor could it be said with the obvious pair of semantic colours: measured,
/// `windowBackgroundColor` and `textBackgroundColor` resolve to the SAME value
/// in this window — #FFFFFF against #FFFFFF in light, #202020 against #202020
/// in dark — so "chrome beside paper" drawn that way is two identical whites.
///
/// So the surface is derived instead of named, and derived from the one thing
/// that already knows which way is "away from the page": the label colour.
/// Ink over the page at a few percent darkens white paper and lightens dark
/// paper, which is exactly the relationship macOS itself draws — sidebar
/// darker than the content in light, lighter than it in dark — without a
/// single hardcoded grey to keep in step with two appearances by hand.
private struct SidebarMaterial: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(Color.primary.opacity(0.05))
    }
}

// MARK: - The optional text model, offered where its absence is visible

/// One line saying what is missing, and one button. This is the whole of the
/// text model's presence outside Settings.
///
/// Deliberately NOT a card: no border, no icon, no accent, no illustration. A
/// caption and a small button, in the same idiom as every other hint in this
/// window. An app with nothing to sell has no business drawing a banner over
/// somebody's meetings, and a utility that is invisible by design cannot make
/// an exception for its own upsell.
///
/// Stacked rather than laid out side by side, because of the 240pt sidebar:
/// German and Russian run about a third longer than English, and a sentence
/// beside a button in that column reflows into a two-word ribbon.
///
/// The states are the download's own — pressing Download turns the button into
/// the bar it started, so the button cannot look like it did nothing, and the
/// whole view disappears when the model lands (there is nothing left to offer).
private struct TextModelOffer: View {
    /// What is lost without it, in this particular place.
    let line: String

    @ObservedObject private var loc = Localization.shared
    @ObservedObject private var offer = LocalTextModelOffer.shared
    @ObservedObject private var download = LocalTextModelDownload.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Intel Macs are the audience with the MOST to gain — Apple's model
            // needs macOS 26 and those Macs are frozen below it, so this is the
            // only way they get titles, summaries or a working search by
            // meaning — and they are also the slow case: measured 13.9 s per
            // passage against 1.1 s. Somebody who is not told will report it as
            // a hang, so it is said before the download, not after.
            if LocalTextModelFile.runsOnCPU {
                Text(L("On this Mac it runs on the CPU: about three minutes of background work for a 50-minute meeting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Under 16 GB it still runs, and it is still worth having — but it
            // holds 4.7 GB while it writes, and on such a Mac that is felt.
            // Said with the number in it rather than as a warning: the person
            // decides, the same way he decides about everything else here.
            if LocalTextModelFile.isMemoryTight {
                Text(L("It holds about 4.7 GB of memory while it writes, which this Mac will feel."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            action
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One appearance of the offer costs one of its two runs, wherever it
        // was shown.
        .onAppear { offer.noteShown() }
    }

    @ViewBuilder
    private var action: some View {
        switch download.state {
        case .downloading(let fraction):
            HStack(spacing: 6) {
                // Determinate, as in Settings: the total is known to the byte,
                // and 2.5 GB behind a spinner is indistinguishable from a hang.
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            Text(L("Checking…")).font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button(L("Retry")) { download.start() }.controlSize(.small)
        default:
            HStack(spacing: 10) {
                Button(Lf("Download %@", LocalTextModelFile.sizeText)) { download.start() }
                    .controlSize(.small)
                // "Not now" means never — here, in the search, and on every
                // meeting. Written to disk, so a relaunch does not forget it.
                // Settings keeps the row either way: that is where somebody
                // comes back on purpose.
                Button(L("Not now")) { offer.dismiss() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Transcript pane

/// The coordinate space the turn rectangles and the pointer are both
/// expressed in — one name shared by the geometry that records them and the
/// view that reads them.
private let turnSpace = "dictate.transcript.turns"

/// Renders a transcript as a conversation: one block per turn, the speaker
/// named once in their own colour. A live session adds the recording header
/// and the status strip; an archived one is the same view without them, so
/// nothing about a finished meeting looks like a different app.
private struct TranscriptPane<MenuItems: View>: View {
    let entries: [TranscriptEntry]
    let title: String
    let subtitle: String?
    /// Who was in the meeting. Rendered as chips in the subtitle line, each one
    /// a way into the rename popover; empty for a live call (see the call site).
    let participants: [Participant]
    let live: MeetingSession?
    let onStop: (() -> Void)?
    /// This meeting's tags and how to change them. nil for a live session —
    /// a call that is still happening has nothing to file yet, and the
    /// calendar has already put its own tag on it if there was one.
    var tags: [String] = []
    /// Every tag already in the archive, most-used first — what completion
    /// offers, so the familiar term is the easy one to type and the vocabulary
    /// stops forking into synonyms.
    var knownTags: [(tag: String, count: Int)] = []
    var onTags: (([String]) -> Void)?
    /// Clicking a tag asks the library to show everything filed under it.
    var onTagFilter: ((String) -> Void)?
    let onRename: (String, String) -> Void
    /// nil while a meeting is still recording — a title is written when the
    /// transcript closes.
    let onRetitle: ((String) -> Void)?
    /// Set by the header menu's Rename… — the same popover, opened from
    /// elsewhere.
    @Binding var openRename: Bool
    /// The clock time this transcript should open AT — the start of a section
    /// the owner picked out of the search results. nil is the ordinary case:
    /// an archive opens at the top, a call at its newest line.
    let jumpTo: String?
    /// What the meeting was about, in the model's one sentence. It used to
    /// appear ONLY in the sidebar row, which is why that row kept wanting to
    /// grow: a list is for scanning and a detail pane is for reading, and the
    /// summary was living in the wrong one.
    var overviewSummary: String? = nil
    /// A line per few minutes with the moment it starts at. Written into every
    /// transcript since sections existed and, until now, never shown anywhere —
    /// only searched. For an hour-long call it is the most useful thing in the
    /// file, and it only works if you can click it.
    var overviewSections: [TranscriptSection] = []
    /// Recut this meeting's contents at a chosen granularity. nil where there
    /// is nothing to recut — a live call has no contents yet. The pane holds
    /// the control because that is where somebody is looking at the result;
    /// the work belongs to whoever owns the file, so it is handed in.
    var onRecut: ((MeetingPolicy.SectionDetail) -> Void)? = nil
    /// True while that is happening, so the block can say so instead of
    /// looking broken for the twenty seconds a recut takes.
    var recutting = false
    /// Which granularity is showing, when anyone knows. nil for a meeting cut
    /// by the ordinary backfill, which is most of them — the control then
    /// highlights nothing rather than claiming a level it cannot verify.
    var recutLevel: MeetingPolicy.SectionDetail? = nil
    /// A one-line notice under the header — the offer of the text model, on
    /// the one meeting the built-in one refused to describe. nil is the
    /// ordinary case, which is every meeting and every live call.
    var notice: AnyView? = nil
    /// What the ⋯ menu offers for this transcript. Passed as items rather than
    /// as a whole menu so both call sites get the identical button.
    @ViewBuilder let menuItems: () -> MenuItems

    @ObservedObject private var loc = Localization.shared
    /// Whether the contents are open. Per pane rather than remembered: a
    /// choice about one meeting's shape is not a preference about all of them,
    /// and it resets when you move on, which is what you would want anyway.
    @State private var contentsExpanded = false
    @State private var retitling = false
    @State private var titleDraft = ""
    /// Which participant's rename popover is open — one at a time, by name.
    @State private var renamingSpeaker: String?
    /// Turns and speaker colours, derived once per change of `entries`.
    @State private var cache = TurnCache()
    /// The turn under the pointer — ONE optional id, owned here and nowhere
    /// else, so "two turns are hovered" cannot be expressed. It is derived
    /// from where the pointer is now (TurnPointer), never accumulated from
    /// enter/exit events, which is why a missed event costs one stale frame
    /// instead of a row that stays lit for good.
    @State private var hovered: UUID?
    /// Where each turn currently sits, for turning a pointer position into
    /// that one id. A plain object: written from geometry callbacks, and
    /// nothing about SwiftUI's state depends on it.
    @State private var frames = TurnFrames()
    /// Auto-scroll is armed only while the newest line is on screen and the
    /// user is not touching the list — see TranscriptScroll.
    @State private var pinned = true
    @State private var interacting = false
    /// Until when a report of "not at the bottom" is our own scroll landing
    /// rather than the user leaving it.
    @State private var followingUntil = Date.distantPast
    /// ⌘A has no real text selection to hand out (every turn is its own Text
    /// island), so it selects the transcript as a whole — visibly — and ⌘C
    /// takes it. Any click, Escape or a jump to the newest line clears it.
    @State private var allSelected = false
    /// Entry count at the moment auto-scroll froze, so the jump button can say
    /// how many lines were missed since.
    @State private var frozenAt = 0
    /// The turn the transcript was opened at, lit so the eye lands on it —
    /// scrolling somebody to a moment without saying which line is the moment
    /// leaves them looking at a screenful of dialogue. Cleared on a timer, so
    /// nothing here animates or repeats.
    @State private var marked: UUID?
    /// Near enough the top that the way back would be offering nothing.
    @State private var atTop = true
    /// Bumped per jump; only the newest jump gets to clear its own mark.
    @State private var markFlash = 0
    @State private var copiedVisible = false
    /// Bumped per copy; only the newest flash gets to clear the badge.
    @State private var copyFlash = 0
    @State private var menuHovering = false

    var body: some View {
        if DBG.trace { let _ = Self._printChanges() }
        return VStack(spacing: 0) {
            header
            Divider()
            // A row of its own, and not part of the subtitle: that line is
            // already one unwrappable row fighting for width between the date
            // and the participants, and tags would be the thing that finally
            // pushed the two panes' headers out of alignment.
            if let onTags {
                TagRow(tags: tags, known: knownTags, onChange: onTags,
                       onFilter: { onTagFilter?($0) })
                Divider()
            }
            if let notice {
                notice
                Divider()
            }
            if entries.isEmpty && live?.livePreview == nil {
                emptyState
            } else {
                turnsList
            }
            if let live, live.isActive {
                Divider()
                StatusStrip(session: live)
            }
        }
        // The transcript is a reading surface — the paper colour, next to the
        // sidebar's material. Two surfaces, told apart by what they are for.
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: openRename) { open in
            guard open, onRetitle != nil else { return }
            openRename = false
            titleDraft = title
            retitling = true
        }
    }

    /// One row, one height, the same margins as the turns below it: the
    /// transcript's name at the leading end — on the very same left edge as the
    /// words underneath it — and the ⋯ menu at the trailing end, directly above
    /// the column of copy chips it shares a centre line with.
    ///
    /// The sidebar toggle appears here only when there is no sidebar for it to
    /// sit on. While the library is open the toggle lives in the library's own
    /// header (MeetingsView.headerRow), where it is over the column it hides
    /// instead of across the divider from it — and where it is not pushing this
    /// title 36pt off the transcript's margin.
    private var header: some View {
        HStack(spacing: 6) {
            if live?.isActive == true {
                PulsingDot().padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let onRetitle {
                    // The name the model chose is a suggestion, not a
                    // verdict: click it and type your own.
                    Button {
                        titleDraft = title
                        retitling = true
                    } label: {
                        Text(title).font(.headline).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(L("Rename this meeting"))
                    .popover(isPresented: $retitling, arrowEdge: .bottom) {
                        retitlePopover(onRetitle)
                    }
                } else {
                    Text(title).font(.headline).lineLimit(1)
                }
                subtitleLine
            }
            Spacer(minLength: 6)
            if let live, live.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(String(format: "%d:%02d",
                                Int(context.date.timeIntervalSince(live.startedAt)) / 60,
                                Int(context.date.timeIntervalSince(live.startedAt)) % 60))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let onStop {
                    StopButton(action: onStop)
                }
            }
            menuButton
        }
        .frame(height: MeetingsChrome.headerHeight)
        // The plain margin at the trailing end. The ⋯ is a chip inset 3pt
        // inside its click target, and so is every copy chip down the
        // transcript, so the same padding is what puts them all on one line —
        // the trailing edge must NOT be "corrected", or the header control
        // would step 3pt out of the column it belongs to.
        //
        // The leading end depends on who owns the window's top-left corner: with
        // the library open this header starts on the transcript's own margin,
        // and without it the header IS the title bar and starts after the
        // window's buttons.
        .padding(.leading, MeetingsChrome.inset)
        .padding(.trailing, MeetingsChrome.inset)
    }

    /// The line under the meeting's name: when it happened, then who was in it.
    ///
    /// ONE line, always. A long German subtitle with five speakers in it used to
    /// wrap and push this header taller than the sidebar's, which is where the
    /// two panes came apart — so nothing here may wrap, and at a narrow window
    /// something has to give instead.
    ///
    /// `ViewThatFits` gives up the least useful thing first, in three steps:
    /// everything; then the date and length, keeping the participants, because
    /// they are the part you can click; then — when even the bare names would
    /// not fit — the participants, because five chips squeezed to "Y…", "T…",
    /// "S…" are not a list of people, they are noise where a subtitle used to
    /// be. A 360pt window shows the facts alone and the names come back with
    /// the width; the turns can always rename a speaker either way.
    @ViewBuilder
    private var subtitleLine: some View {
        let facts = subtitle ?? ""
        if !facts.isEmpty || !participants.isEmpty {
            ViewThatFits(in: .horizontal) {
                chips(leadingFacts: facts)
                chips(leadingFacts: "")
                Text(facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: 16)
        }
    }

    private func chips(leadingFacts facts: String) -> some View {
        HStack(spacing: 5) {
            if !facts.isEmpty {
                Text(facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ForEach(participants) { participant in
                SpeakerChip(participant: participant,
                            color: cache.color(named: participant.name,
                                               isYou: participant.isYou),
                            renaming: $renamingSpeaker,
                            onRename: onRename)
            }
            Spacer(minLength: 0)
        }
    }

    private var menuButton: some View {
        Menu {
            menuItems()
        } label: {
            ChromeGlyph(icon: "ellipsis", hovering: menuHovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .onHover { menuHovering = $0 }
        .help(L("Meeting actions"))
    }

    private func retitlePopover(_ commit: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Name this meeting")).font(.caption).foregroundStyle(.secondary)
            TextField(L("Name"), text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { retitling = false; commit(titleDraft) }
            HStack {
                Spacer()
                Button(L("Cancel")) { retitling = false }
                Button(L("Save")) { retitling = false; commit(titleDraft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            // Still even during a live call, which is the case this was most
            // tempting to animate. Measured at the size it actually renders,
            // an animating wave costs ~19% of a core for as long as it is on
            // screen — and the moment it would be on screen is the top of a
            // call, with Meet, a screen share and Whisper already on the same
            // cores. It would also be saying something the window says twice
            // already and more cheaply: the header carries the recording dot
            // and the running time, and the status strip below carries a live
            // level meter and the word "Listening…". The mark is a mark.
            WaveMark(height: 34, animated: false).opacity(0.5)
            Text(live != nil ? L("Waiting for speech…") : L("This transcript is empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// What this meeting was, above what was said in it.
    ///
    /// The app has been writing both of these into every transcript for weeks
    /// and showing neither: the summary leaked into the sidebar row (a list,
    /// where nobody reads), and the contents block was written, indexed for
    /// search, and never drawn at all. Put where there is width to read them,
    /// they turn an hour of dialogue into something you can enter in the
    /// middle — which is what a table of contents is for.
    ///
    /// Part of the transcript's own scroll rather than a fixed header: this is
    /// the top of a document, not a permanent band stealing height from the
    /// words. Scroll down and it is gone.
    @ViewBuilder
    private func overview(jump: @escaping (String) -> Void) -> some View {
        if overviewSummary != nil || !overviewSections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let overviewSummary {
                    // A rule down the side, not a bigger face.
                    //
                    // Size was tried and does not work here: everything around
                    // this is prose too, so one step up reads as a slightly
                    // louder paragraph rather than as a different kind of
                    // thing. What the eye needs is a signal of a different
                    // ORDER — and a coloured rule beside a block is the mark
                    // typesetting has used for the standfirst since long
                    // before screens. It also stays clear of the contents
                    // below, which is marked by a fill: two blocks, two
                    // different devices, no competition between them.
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Brand.indigoLabel.opacity(0.55))
                            .frame(width: 3)
                        Text(overviewSummary)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !overviewSections.isEmpty {
                    contentsBlock(jump: jump)
                }
                // Not a hairline. Above it is what this meeting WAS; below it
                // is what was said, and the eye should not have to work out
                // where one becomes the other — which was the whole complaint.
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 2)
            }
            .padding(.bottom, 10)
        }
    }

    /// The contents, as an index rather than as more prose.
    ///
    /// It used to sit here as a bare list one size below the summary, between
    /// two blocks of body text, and the three zones read as one texture. The
    /// fix is not a bigger heading: it is admitting that this is a DIFFERENT
    /// KIND of thing. A list you jump from is furniture, not reading, so it
    /// gets a fill of its own, smaller type and tighter rows — one object on
    /// the page instead of sixteen lines pretending to be sentences.
    ///
    /// And it collapses. Sixteen moments at reading size fill the pane of a
    /// 64-minute call, so the transcript — the thing the file exists for —
    /// begins below the fold.
    @ViewBuilder
    private func contentsBlock(jump: @escaping (String) -> Void) -> some View {
        let all = overviewSections
        // Four fits a short call whole and leaves a long one's transcript on
        // screen. A local constant, not a static: TranscriptPane is generic
        // over its menu items and cannot hold stored type properties.
        let collapsed = 4
        let shown = contentsExpanded ? all : Array(all.prefix(collapsed))
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(Lf("%@ moments", "\(all.count)"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if all.count > collapsed {
                    Button(contentsExpanded ? L("Show less") : L("Show all")) {
                        withAnimation(.easeOut(duration: 0.15)) { contentsExpanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Brand.indigoLabel)
                }
            }
            .padding(.bottom, 3)
            // Only while the block is open. Collapsed, this is a glance at
            // what a call contained; nobody adjusts granularity from there,
            // and a control on every closed block would be three words of
            // furniture on every meeting in the archive.
            if contentsExpanded, let onRecut {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { recutLevel ?? .standard },
                        set: { onRecut($0) })) {
                        Text(L("Fewer")).tag(MeetingPolicy.SectionDetail.coarse)
                        Text(L("Standard")).tag(MeetingPolicy.SectionDetail.standard)
                        Text(L("More")).tag(MeetingPolicy.SectionDetail.fine)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(recutting)
                    if recutting {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                }
                .padding(.bottom, 5)
            }
            ForEach(shown, id: \.time) { section in
                SectionLink(section: section) { jump(section.time) }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var turnsList: some View {
        cache.refresh(entries)
        // Everything the list does about scrolling hangs off this one rule:
        // follow the call only while the user is at the bottom and has their
        // hands off. Anything else means they are reading or selecting, and a
        // forced scroll would tear that away.
        // Following the newest line is a LIVE-call feature, and it took a
        // report to notice it had never said so: a finished transcript has
        // nothing to follow, but it inherited the whole mechanism anyway. The
        // symptom was exact — drag up to read the summary, and the moment you
        // let go the view snapped back to the bottom, because releasing clears
        // `interacting`, which re-arms auto-scroll, which jumps to the newest
        // line of a meeting that ended days ago.
        let autoScroll = live?.isActive == true && pinned && !interacting && !allSelected
        let missed = max(0, entries.count - frozenAt)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Color.clear.frame(height: 0).id("top")
                    overview { moment in jump(to: moment, proxy) }
                    ForEach(cache.turns) { turn in
                        TurnView(turn: turn,
                                 color: cache.color(for: turn),
                                 selected: allSelected || marked == turn.id,
                                 // The one and only answer to "is the pointer
                                 // on this turn": an id compared to an id.
                                 hovering: hovered == turn.id,
                                 // The turns are inside scrolling content and
                                 // must not each subscribe to the localization
                                 // (that would re-render the list on any
                                 // change); the pane observes it and hands the
                                 // language down as a plain value, which is
                                 // enough to invalidate the rows when the UI
                                 // language changes (GRABLI).
                                 language: loc.language,
                                 onRename: onRename,
                                 onCopy: { turn, attributed in
                                     copy(turn: turn, attributed: attributed)
                                 })
                            .equatable()
                            // Where this turn is, recorded into a plain object
                            // — no SwiftUI state is written here, so a row
                            // being measured can never invalidate anything.
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(turnSpace))
                            } action: { frames.record(turn.id, $0) }
                            .onDisappear { frames.forget(turn.id) }
                    }
                    if let text = live?.livePreview {
                        currentLine(text)
                    } else if live?.listeningFor != nil {
                        listeningLine
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, MeetingsChrome.inset)
                .padding(.vertical, 12)
                .coordinateSpace(name: turnSpace)
                // ONE pointer watcher for the whole transcript, not one per
                // turn — see TurnPointer.
                .overlay { TurnPointer(frames: frames) { hovered = $0 } }
            }
            // The scroll position is the whole signal: "still at the newest
            // line" arms auto-scroll, anything above it disarms it.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Half a screen down is where "I have scrolled away" starts:
                // near enough the top and the button would be offering to do
                // what a flick of the wheel already does.
                geometry.contentOffset.y < geometry.containerSize.height / 2
            } action: { _, near in
                atTop = near
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                TranscriptScroll.isPinned(contentOffsetY: geometry.contentOffset.y,
                                          containerHeight: geometry.containerSize.height,
                                          contentHeight: geometry.contentSize.height,
                                          bottomInset: geometry.contentInsets.bottom)
            } action: { _, isPinned in
                // A new line is laid out before the scroll that follows it
                // lands, so for a moment the list honestly reports "not at the
                // bottom". Taking that at face value would disarm auto-scroll
                // and flash the jump button on every recognized phrase, so
                // unpinning is ignored while our own jump is in flight.
                if isPinned { pinned = true }
                else if Date() >= followingUntil { pinned = false }
            }
            .background(eventCatcher)
            .overlay(alignment: .bottom) {
                // Only a running meeting can leave lines behind; an archive
                // has nothing to catch up with.
                if live?.isActive == true, !autoScroll {
                    jumpToNewest(proxy, missed: missed)
                }
            }
            .overlay(alignment: .top) {
                // The way back to the head of a long transcript. Same idiom as
                // "jump to newest" and the opposite direction, so the two read
                // as one pair rather than two inventions; shown only once there
                // is something to come back from.
                if !atTop { backToTop(proxy) }
            }
            .overlay(alignment: .bottomTrailing) { copiedBadge }
            .onChange(of: entries.count) { _ in
                guard autoScroll else { return }
                scrollToNewest(proxy)
            }
            .onChange(of: live?.livePreview) { _ in
                guard autoScroll else { return }
                scrollToNewest(proxy)
            }
            .onChange(of: autoScroll) { armed in
                if armed { scrollToNewest(proxy) } else { frozenAt = entries.count }
            }
            .onChange(of: title) { _ in
                // A different meeting is a clean slate: nothing is selected,
                // nothing is being dragged.
                allSelected = false
                interacting = false
                hovered = nil
                marked = nil
                frames.clear()
                // A call in progress opens on its newest line — that is where
                // it is happening. A finished one opens at the TOP, on its
                // summary and contents, because that is where you decide
                // whether this is the meeting you were looking for.
                //
                // `pinned` has to be cleared for the archive or the switch ends
                // up at the bottom anyway: pinned + a changed entry count arms
                // auto-scroll, which then jumps to the newest line of a meeting
                // that has nothing newer to show.
                pinned = live != nil
                if live != nil { scrollToNewest(proxy) }
                else { proxy.scrollTo("top", anchor: .top) }
            }
            .onAppear {
                jump(to: jumpTo, proxy)
                // A window opened in the middle of a call must show the last
                // thing that was said, not the first.
                guard live != nil, jumpTo == nil else { return }
                scrollToNewest(proxy)
            }
            // Opening the transcript AT a moment — a section hit, or a second
            // hit in the meeting already on screen. The moment is taken from
            // the callback rather than read back off `jumpTo`, and that is not
            // style: onChange runs the action closure captured by the PREVIOUS
            // body, whose `jumpTo` is still the old one. Reading the property
            // logged "jump(nil)" for a selection that plainly carried
            // 10:03:57, and nothing moved (measured 2026-08-14).
            .onChange(of: jumpTo) { moment in jump(to: moment, proxy) }
        }
    }

    /// "↓ Jump to newest", with how many lines arrived while the user was
    /// reading. Discreet and floating: it must not push the transcript around
    /// when it appears, and it is the way back to a live view — clicking it
    /// re-arms auto-scroll.
    private func jumpToNewest(_ proxy: ScrollViewProxy, missed: Int) -> some View {
        Button {
            allSelected = false
            interacting = false
            pinned = true
            scrollToNewest(proxy)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down").imageScale(.small)
                Text(L("Jump to newest")).font(.caption)
                if missed > 0 {
                    Text("\(missed)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
    }

    /// "↑ Back to the top", for a transcript long enough that the summary and
    /// the contents have scrolled out of reach.
    ///
    /// The same capsule as "jump to newest" pointing the other way: an hour of
    /// dialogue is a long way from its own head, and the alternative is a lot
    /// of scrolling to answer "what was this meeting again".
    private func backToTop(_ proxy: ScrollViewProxy) -> some View {
        Button {
            allSelected = false
            interacting = false
            pinned = false
            withAnimation { proxy.scrollTo("top", anchor: .top) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up").imageScale(.small)
                Text(L("Back to the top")).font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }

    /// Confirmation that something did land on the clipboard. An overlay, so
    /// the transcript never shifts under the pointer to make room for it.
    @ViewBuilder
    private var copiedBadge: some View {
        if copiedVisible {
            Text(L("Copied"))
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// Opens the transcript at the moment a section hit points to, and lights
    /// the turn it lands on for a few seconds.
    ///
    /// Where the moment lands, and why it can no longer be asked here, is
    /// `MeetingArchive.turn(at:in:)` — a pure rule, because it is the join
    /// between the contents block (cut from the FILE's entries) and the
    /// paragraphs the window actually shows, and that join has to be pinned by
    /// a test rather than by this method reading correctly.
    ///
    /// It stays deliberately tolerant of not finding anything: the file is the
    /// source of truth and a person may have edited it, and a jump that cannot
    /// land is a transcript opened at the top, not an error.
    ///
    /// One run-loop turn late, because the pane is often being built in the
    /// same pass — a scroll requested before the rows exist goes nowhere.
    private func jump(to moment: String?, _ proxy: ScrollViewProxy) {
        guard let moment else { return }
        guard let turn = MeetingArchive.turn(at: moment, in: cache.turns) else {
            Log.d("meetings: nothing at \(moment) in \(cache.turns.count) turn(s)")
            return
        }
        markFlash += 1
        let token = markFlash
        DispatchQueue.main.async {
            guard token == markFlash else { return }
            proxy.scrollTo(turn.id, anchor: .top)
            marked = turn.id
        }
        // Long enough to find with the eye, short enough that it is gone by the
        // time it would be in the way of reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            guard token == markFlash else { return }   // a newer jump owns the mark
            withAnimation(.easeIn(duration: 0.4)) { marked = nil }
        }
    }

    /// Animation is dropped on a long transcript — see the reasoning at
    /// TranscriptScroll.animationLimit.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        // The scroll observer must not mistake our own jump for the user
        // walking away from the bottom.
        followingUntil = Date().addingTimeInterval(0.5)
        if TranscriptScroll.animates(entryCount: entries.count) {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - Copying

    /// One turn, with or without its speaker and time. The same two commands
    /// sit in the context menu, behind the hover button and behind ⌘C, so
    /// whichever gesture a user reaches for first is the one that works.
    private func copy(turn: TranscriptTurn, attributed: Bool) {
        let text = attributed ? TranscriptCopy.attributed(turn) : TranscriptCopy.text(of: turn)
        guard TranscriptCopy.put(text) else { return }
        flashCopied()
    }

    @discardableResult
    private func copyEverything() -> Bool {
        guard TranscriptCopy.put(TranscriptCopy.transcript(entries)) else { return false }
        flashCopied()
        return true
    }

    private func flashCopied() {
        copyFlash += 1
        let token = copyFlash
        withAnimation(.easeOut(duration: 0.12)) { copiedVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard token == copyFlash else { return }   // a newer copy owns the badge
            withAnimation(.easeIn(duration: 0.25)) { copiedVisible = false }
        }
    }

    // MARK: - Keyboard and pointer

    /// The panel is non-activating by design (AppDelegate): a glance at the
    /// transcript during a call must never take focus from the call, which
    /// also means the app's Edit menu never sees ⌘C here. The catcher watches
    /// events already addressed to Dictate — it can serve ⌘C/⌘A when the user
    /// is actually in the app, and stays silent by construction while the call
    /// app is frontmost (nothing can reach us then, which is precisely why
    /// copying is also a button and a context menu). It watches the mouse for
    /// the same reason SwiftUI can't tell us: a press inside the list means a
    /// selection may be in progress, and the line under the pointer must not
    /// be scrolled away for the length of that gesture.
    private var eventCatcher: some View {
        TranscriptEventCatcher(
            claimsCopy: {
                // An explicit ⌘A selection is the user's own and outranks
                // anything the responder chain may still be holding on to.
                guard allSelected else { return false }
                allSelected = false
                return copyEverything()
            },
            copyByPointer: {
                // Nobody had a text selection. The pointer is the only hint
                // left about what "copy" means: the turn under it is the line
                // the user is looking at. Outside the list we copy the whole
                // transcript rather than nothing — a shortcut that silently
                // does nothing is the worst of the options.
                if let id = hovered, let turn = cache.turns.first(where: { $0.id == id }) {
                    copy(turn: turn, attributed: false)
                    return true
                }
                return copyEverything()
            },
            onSelectAll: {
                allSelected = true
            },
            onEscape: {
                guard allSelected else { return false }
                allSelected = false
                return true
            },
            onPressBegan: {
                interacting = true
                allSelected = false
            },
            onPressEnded: { dragged in
                // A drag is a selection: leave auto-scroll frozen so the
                // highlighted text survives long enough to be copied. A plain
                // click was just a click — follow the call again.
                interacting = dragged
            },
            // While a meeting is being recorded the panel must not take focus,
            // period. A finished transcript is an ordinary window the user
            // clicked into, and clicking into a window is how the keyboard
            // (⌘C, ⌘A) is supposed to arrive.
            activatesOnClick: live?.isActive != true
        )
    }

    /// The utterance still being spoken — grey and italic, replaced by the
    /// final entry when the window is cut.
    private func currentLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.red).frame(width: 5, height: 5).padding(.top, 5)
            Text(text)
                .font(.body.italic())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var listeningLine: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 5, height: 5)
            Text(L("Listening…")).font(.callout).foregroundStyle(.secondary)
        }
    }

}

/// One voice in a meeting, as the header shows it.
///
/// `isYou` is not decoration: the owner is the one participant whose name is
/// not a guess the app made, so it is the one chip that does not offer to be
/// renamed.
struct Participant: Identifiable, Hashable {
    let name: String
    let isYou: Bool
    var id: String { name }
}

/// A participant in the transcript's header: the speaker's colour, their name,
/// and a way into the same rename popover their turns carry.
///
/// Quiet metadata until it is pointed at — this is a subtitle line, not a
/// toolbar. The chip's padding is the same whether it is hovered or not and
/// only the background behind it changes, so lighting one up cannot move the
/// header around (the same rule as the copy chips down the transcript).
private struct SpeakerChip: View {
    let participant: Participant
    let color: Color
    @Binding var renaming: String?
    let onRename: (String, String) -> Void

    @State private var hovering = false
    @State private var draft = ""

    private var isOpen: Bool { renaming == participant.name }

    var body: some View {
        let label = HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(participant.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(hovering || isOpen ? 0.08 : 0))
        )
        .animation(.easeOut(duration: 0.1), value: hovering)

        // "You" is the person reading this window, not a name the app invented
        // — there is nothing to correct, so it is a fact rather than a control.
        if participant.isYou {
            label
        } else {
            Button {
                draft = participant.name
                renaming = participant.name
            } label: { label }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(L("Rename this speaker"))
            .popover(isPresented: Binding(get: { isOpen },
                                          set: { if !$0, isOpen { renaming = nil } }),
                     arrowEdge: .bottom) {
                SpeakerRenamePopover(draft: $draft, width: 180) { newName in
                    renaming = nil
                    guard let newName else { return }
                    onRename(participant.name, newName)
                }
            }
        }
    }
}

/// The one surface for renaming a voice, reached from a turn's speaker name and
/// from the header's participant chips. `nil` from `commit` means the user
/// backed out.
private struct SpeakerRenamePopover: View {
    @Binding var draft: String
    var width: CGFloat = 180
    let commit: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Name this speaker")).font(.caption).foregroundStyle(.secondary)
            TextField(L("Name"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .onSubmit { commit(draft) }
            HStack {
                Spacer()
                Button(L("Cancel")) { commit(nil) }
                Button(L("Save")) { commit(draft) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

/// Turns and speaker colours are derived data, and deriving them in `body` is
/// what made a long call stutter: the pane re-renders at least once a second
/// while recording, and a real meeting is ~350 entries / ~250 turns — merging
/// the turns and re-scanning every entry for each turn's speaker colour ran
/// into ~100k string operations per frame, on top of an animated scroll. This
/// recomputes only when the entries actually change; the usual case costs one
/// comparison, because an unchanged array compares by buffer identity.
private final class TurnCache {
    private var entries: [TranscriptEntry] = []
    private var signature: [String] = []
    private var loaded = false
    private(set) var turns: [TranscriptTurn] = []
    private(set) var colors: [String: Color] = [:]

    func refresh(_ new: [TranscriptEntry]) {
        // Compared by CONTENT, not by struct equality. A TranscriptEntry
        // carries a UUID minted when the file is parsed, and equality includes
        // it — so re-reading a file nothing had changed still looked like a
        // different transcript. Every reload therefore rebuilt the turns with
        // fresh identities, the list underneath the reader lost its place, and
        // the scroll jumped. Visible whenever the archive is re-read while
        // somebody is reading it, which the summary backfill does after every
        // meeting it writes.
        guard !loaded || Self.signature(new) != signature else { return }
        loaded = true
        signature = Self.signature(new)
        entries = new
        // The cleaned form is what is read, hovered, copied and jumped to —
        // derived HERE and nowhere else, so the pane cannot end up showing one
        // transcript and copying another.
        turns = MeetingArchive.readable(new)
        colors = Self.palette(for: new)
    }

    /// What actually distinguishes one transcript from another: the words,
    /// who said them and when. Deliberately not the identity of the objects
    /// carrying them, which changes every time the file is read.
    private static func signature(_ entries: [TranscriptEntry]) -> [String] {
        entries.map { "\($0.time)\u{1}\($0.speaker)\u{1}\($0.text)" }
    }

    /// The palette is keyed by name, so a turn's colour is a dictionary hit
    /// and not a scan.
    func color(for turn: TranscriptTurn) -> Color {
        color(named: turn.speaker, isYou: turn.isYou)
    }

    /// The same lookup for a speaker the header knows only by name, so a
    /// participant chip and that speaker's dots are never two different colours.
    func color(named speaker: String, isYou: Bool) -> Color {
        colors[speaker] ?? (isYou ? Brand.indigoLabel : Brand.cyanLabel)
    }

    /// Speakers keep a stable colour within one transcript: the user is
    /// always the brand indigo, the others take the palette in the order
    /// they first speak.
    private static func palette(for entries: [TranscriptEntry]) -> [String: Color] {
        let palette = Brand.speakerPalette
        var colors: [String: Color] = [:]
        var next = 0
        for entry in entries where colors[entry.speaker] == nil {
            if entry.isYou {
                colors[entry.speaker] = Brand.indigoLabel
            } else {
                colors[entry.speaker] = palette[next % palette.count]
                next += 1
            }
        }
        return colors
    }
}

/// Where every turn currently sits, in the transcript's own coordinate space.
///
/// Deliberately a plain object and not observable state: it is rewritten by
/// geometry callbacks during layout, and nothing in SwiftUI may depend on it —
/// only TurnPointer reads it, and only to answer one question.
private final class TurnFrames {
    private var rects: [UUID: CGRect] = [:]

    func record(_ id: UUID, _ rect: CGRect) { rects[id] = rect }

    /// A turn scrolled out of the LazyVStack must take its rectangle with it,
    /// or a stale rectangle could still claim the pointer.
    func forget(_ id: UUID) { rects.removeValue(forKey: id) }

    /// A different transcript is a different set of turns; none of the old
    /// rectangles mean anything any more.
    func clear() { rects.removeAll() }

    /// The turn at a point — at most one, because the turns do not overlap.
    /// This is the whole reason "two rows are both hovered" is not a state
    /// this pane can reach.
    func turn(at point: CGPoint) -> UUID? {
        for (id, rect) in rects where rect.contains(point) { return id }
        return nil
    }
}

/// The transcript's ONE pointer watcher.
///
/// The previous design gave every turn its own tracking area and its own
/// `hovering` flag, OR-ed with SwiftUI's `.onHover`. Both of those signals are
/// event streams — "the pointer came in", "the pointer went out" — and both
/// drop events: `.onHover` is documented not to fire reliably on exit at speed,
/// and `mouseExited` is never sent for a boundary the pointer did not actually
/// cross, which is exactly what happens when the content SCROLLS under a
/// motionless pointer. A dropped exit left that row lit forever, and since each
/// row kept its own flag, rows latched on one by one until the whole transcript
/// was highlighted.
///
/// So hover is not accumulated here at all. This single view asks where the
/// pointer is *now* and answers with a single id; a lost event costs one stale
/// frame, and the next resolve — a mouse move, a scroll, a new line arriving —
/// corrects it. It refuses every click (`hitTest` returns nil), so text
/// selection, the copy chip and the context menu behave as if it were absent.
private struct TurnPointer: NSViewRepresentable {
    let frames: TurnFrames
    let changed: (UUID?) -> Void

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        view.frames = frames
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: PointerView, context: Context) {
        // The closure captures SwiftUI state, so it is refreshed on every pass
        // rather than captured once — same rule as the event catcher.
        nsView.frames = frames
        nsView.changed = changed
    }

    final class PointerView: NSView {
        var frames: TurnFrames?
        var changed: ((UUID?) -> Void)?
        private var area: NSTrackingArea?
        private var current: UUID?
        private var scheduled = false
        private var watchers: [Any] = []

        /// Same origin and same direction as the SwiftUI coordinate space the
        /// turn rectangles are measured in, so a point converted into this view
        /// can be compared with them directly.
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if area == nil {
                // `.activeAlways` is load-bearing, not a default: the meetings
                // window is a non-activating panel and stays non-key while the
                // call is frontmost (AppDelegate) — precisely when the owner
                // glances at the transcript — and `.activeInKeyWindow` would go
                // silent exactly then. `.inVisibleRect` keeps the area in step
                // with scrolling without rebuilding it every layout.
                let fresh = NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .mouseMoved,
                              .activeAlways, .inVisibleRect],
                    owner: self
                )
                addTrackingArea(fresh)
                area = fresh
            }
            // The turns move under a motionless pointer — the list scrolls, a
            // live call appends a line — and no boundary is ever crossed. Ask
            // again. One turn of the run loop later, because this runs inside a
            // layout pass and SwiftUI state must never be written there.
            schedule()
        }

        override func mouseEntered(with event: NSEvent) { resolve() }

        override func mouseMoved(with event: NSEvent) { schedule() }

        override func mouseExited(with event: NSEvent) { report(nil) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window == nil else { return watch() }
            unwatch()
            let changed = self.changed
            current = nil
            DispatchQueue.main.async { changed?(nil) }
        }

        deinit { unwatch() }

        /// Why a tracking area is not enough on its own: this panel is
        /// non-activating and normally NOT the active app's window (the call
        /// is), and AppKit delivers `mouseMoved` only to the active
        /// application. `.activeAlways` buys enter and exit — which is how the
        /// old per-row trackers got a "true" they could never take back — but
        /// nothing in between. Monitors see the movement either way: the local
        /// one when Dictate is active, the global one when it is not. Both only
        /// observe; every event is passed through untouched.
        private func watch() {
            guard watchers.isEmpty else { return }
            let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
            if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
                self?.schedule()
                return event
            }) { watchers.append(local) }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
                self?.schedule()
            }) { watchers.append(global) }
        }

        private func unwatch() {
            watchers.forEach(NSEvent.removeMonitor)
            watchers.removeAll()
        }

        /// Coalesced: a layout pass can touch this view many times, and one
        /// answer per run-loop turn is all anybody needs.
        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.scheduled = false
                self?.resolve()
            }
        }

        /// The hovered turn as a FUNCTION of where the pointer is, evaluated
        /// from scratch every time. Nothing accumulates, so nothing can latch.
        private func resolve() {
            guard let window, let frames else { return report(nil) }
            let pointer = window.mouseLocationOutsideOfEventStream
            // The pointer has to be over this window's content at all — a
            // pointer parked outside owns no turn...
            guard window.contentLayoutRect.contains(pointer) else { return report(nil) }
            // ...and this window has to be the one the pointer is actually on:
            // the monitors above fire for movement anywhere on screen, and a
            // window lying over the transcript owns those pixels, not us.
            guard NSWindow.windowNumber(at: window.convertPoint(toScreen: pointer),
                                        belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return report(nil) }
            let local = convert(pointer, from: nil)
            // ...and over the part of the transcript that is actually on
            // screen, so a turn scrolled out of sight cannot be "under" it.
            guard visibleRect.contains(local) else { return report(nil) }
            report(frames.turn(at: local))
        }

        private func report(_ id: UUID?) {
            guard id != current else { return }
            current = id
            changed?(id)
        }
    }
}

/// Keyboard and pointer plumbing for the transcript list — an invisible view
/// behind the ScrollView that listens to events already destined for this app
/// and passes every one of them on. See TranscriptPane.eventCatcher for why
/// this exists at all.
private struct TranscriptEventCatcher: NSViewRepresentable {
    /// ⌘C, before the responder chain: true if the pane copied something of
    /// its own (an explicit ⌘A selection).
    var claimsCopy: () -> Bool
    /// ⌘C, after the responder chain declined: copy by pointer.
    var copyByPointer: () -> Bool
    var onSelectAll: () -> Void
    /// True if Escape actually cleared something — otherwise the key is left
    /// alone, because Escape also closes the panel.
    var onEscape: () -> Bool
    var onPressBegan: () -> Void
    /// Reports whether the press turned into a drag, i.e. a text selection.
    var onPressEnded: (Bool) -> Void
    /// Whether a click in the list may bring the app forward: browsing an
    /// archive, yes; during a live call, never.
    var activatesOnClick: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The handlers close over SwiftUI state, so they are refreshed on
        // every pass rather than captured once at install time.
        context.coordinator.owner = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var owner: TranscriptEventCatcher
        weak var view: NSView?
        private var monitor: Any?
        private var pressOrigin: NSPoint?
        private var dragged = false

        init(_ owner: TranscriptEventCatcher) { self.owner = owner }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let panel = view.window else { return event }
            switch event.type {
            case .keyDown:
                return handleKey(event, in: panel)
            case .leftMouseDown:
                guard event.window === panel, hits(event, view) else { return event }
                pressOrigin = event.locationInWindow
                dragged = false
                // Clicking the transcript hands the panel the keyboard, so ⌘C
                // has somewhere to land. `becomesKeyOnlyIfNeeded` keeps a
                // click from doing this on its own, and a non-activating panel
                // taking key status does not pull the user out of their call.
                if owner.activatesOnClick { NSApp.activate() }
                if NSApp.isActive, !panel.isKeyWindow { panel.makeKey() }
                owner.onPressBegan()
            case .leftMouseDragged:
                if let origin = pressOrigin, !dragged,
                   hypot(event.locationInWindow.x - origin.x,
                         event.locationInWindow.y - origin.y) > 3 {
                    dragged = true
                }
            case .leftMouseUp:
                if pressOrigin != nil { owner.onPressEnded(dragged) }
                pressOrigin = nil
            default:
                break
            }
            return event
        }

        private func hits(_ event: NSEvent, _ view: NSView) -> Bool {
            view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }

        private func handleKey(_ event: NSEvent, in panel: NSWindow) -> NSEvent? {
            // A keystroke meant for another window of ours (Settings, the
            // rename popover) is none of our business. `window == nil` is the
            // panel's own doing: it refuses to become key until something in
            // it needs typing, so a shortcut aimed at Dictate can arrive with
            // nowhere to land — that one is ours, unless someone else is
            // genuinely holding the keyboard.
            if let target = event.window {
                guard target === panel else { return event }
            } else if NSApp.keyWindow != nil {
                return event
            }
            guard panel.isVisible else { return event }
            // Real text inputs (the sidebar search field, a rename popover)
            // own the keyboard while they have it; the Edit menu serves them.
            if panel.firstResponder is NSText { return event }

            if event.keyCode == 53 {                      // Escape
                return owner.onEscape() ? nil : event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "c":
                if owner.claimsCopy() { return nil }
                // A live text selection owns ⌘C: offer it to the responder
                // chain first and only copy a whole turn when nobody claims
                // it, or the shortcut would quietly ignore the very words the
                // user highlighted.
                if panel.firstResponder?.tryToPerform(#selector(NSText.copy(_:)),
                                                      with: nil) == true { return nil }
                return owner.copyByPointer() ? nil : event
            case "a":
                owner.onSelectAll()
                return nil
            default:
                return event
            }
        }
    }
}

/// One speaker's uninterrupted turn.
private struct TurnView: View, Equatable {
    let turn: TranscriptTurn
    let color: Color
    /// Part of a whole-transcript ⌘A selection.
    let selected: Bool
    /// Told, not decided: the pane owns the one id under the pointer and this
    /// row is simply informed whether it is that one. A turn has no opinion of
    /// its own about hover, which is what makes "two turns are lit" impossible
    /// rather than merely unlikely.
    let hovering: Bool
    /// The UI language, passed as a value instead of observed. Rows live inside
    /// scrolling content: N subscriptions to one shared object mean one change
    /// re-renders the whole list, so the pane observes the localization once
    /// and this is what tells the rows their L() strings went stale (GRABLI).
    let language: AppLanguage
    let onRename: (String, String) -> Void
    /// Copy this turn — the words alone, or the line with speaker and time.
    let onCopy: (TranscriptTurn, Bool) -> Void

    @State private var renaming = false
    @State private var draft = ""

    /// Everything a turn draws, and nothing else. With `.equatable()` this is
    /// what keeps a hover from re-running the body of every visible row: only
    /// the row that gained the pointer and the one that lost it differ.
    /// (The closures are excluded on purpose — they capture the pane's state
    /// through its storage, so a stale copy still reads the current value.)
    static func == (a: TurnView, b: TurnView) -> Bool {
        a.turn.id == b.turn.id
            && a.turn.text == b.turn.text
            && a.turn.speaker == b.turn.speaker
            && a.turn.time == b.turn.time
            && a.color == b.color
            && a.selected == b.selected
            && a.hovering == b.hovering
            && a.language == b.language
    }

    var body: some View {
        if DBG.trace { let _ = Self._printChanges() }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Button {
                    draft = turn.speaker
                    renaming = true
                } label: {
                    Text(turn.speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        // A name long enough to wrap would push the row (and
                        // its click target) around; one line, truncated, keeps
                        // the header the same shape for every speaker.
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(L("Rename this speaker"))
                .popover(isPresented: $renaming, arrowEdge: .bottom) {
                    renamePopover
                }
                Text(turn.time)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            Text(turn.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        // The gutter is the copy control's own column, reserved at every
        // window width — that, and not a rule about hover, is what keeps the
        // chip off the words and off the speaker's name-button.
        .padding(.trailing, TurnCopy.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { copyChip }
        // Negative padding: the highlight reaches past the text without
        // moving a single glyph, so turning a selection — or a hover — on and
        // off never reflows the transcript.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlight)
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
                .animation(.easeOut(duration: 0.1), value: hovering)
        )
        .contextMenu {
            Button(L("Copy text")) { onCopy(turn, false) }
            Button(L("Copy with speaker and time")) { onCopy(turn, true) }
        }
    }

    /// ⌘A's selection is the loud one; hover is a whisper whose only job is to
    /// say which block the copy button and ⌘C mean.
    private var highlight: Color {
        if selected { return Brand.indigoLabel.opacity(0.14) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }

    /// The copy affordance: a chip pinned to the trailing edge, in the same
    /// place in every turn, with a 28×28 target (the glyph is a third of that
    /// — aiming at the glyph was the reported "impossible to click"). It never
    /// fades to nothing, only down to a hint: an invisible control still takes
    /// clicks in SwiftUI, and a control that only exists while the pointer is
    /// on it is a target that moves away as you approach. See TurnCopy for the
    /// numbers.
    private var copyChip: some View {
        Button { onCopy(turn, false) } label: {
            Image(systemName: "doc.on.doc")
                .imageScale(.small)
                // At rest the chip carries its own per-appearance ink (see
                // TurnCopy.restingAlpha); under the pointer it is the ordinary
                // secondary label, at full strength.
                .foregroundStyle(hovering ? AnyShapeStyle(.secondary)
                                          : AnyShapeStyle(TurnCopy.restingInk))
                .frame(width: TurnCopy.chipSize, height: TurnCopy.chipSize)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                // The target is the square, not the glyph: everything around
                // the chip is padding that still takes the click.
                .frame(width: TurnCopy.targetSize, height: TurnCopy.targetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(L("Copy text"))
    }

    private var renamePopover: some View {
        SpeakerRenamePopover(draft: $draft) { newName in
            renaming = false
            guard let newName else { return }
            onRename(turn.speaker, newName)
        }
    }
}

/// "It's alive" strip: level bars plus the state in words.
private struct StatusStrip: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        HStack(spacing: 8) {
            LevelWave(level: session.audioLevel)
            if session.modelWarming {
                ProgressView().controlSize(.mini)
                Text(L("Warming up the model…")).font(.caption).foregroundStyle(.secondary)
            } else if session.inflightCount > 0 {
                ProgressView().controlSize(.mini)
                Text(L("Recognizing…")).font(.caption).foregroundStyle(.secondary)
            } else if session.listeningFor != nil {
                Text(L("Listening…")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, MeetingsChrome.inset)
        .padding(.vertical, 7)
    }
}

/// Five brand bars dancing with the live level — flat when silent, alive
/// when anyone speaks. The window's proof of hearing.
///
/// Measured before this was rewritten: 11.3% of a core, for the whole length of
/// every call, from five 3pt bars. The cause is the one this window has now
/// been bitten by three times — `frame(height:)` under an implicit animation.
/// Each audio level (about twelve a second) started a fresh 0.12 s curve on a
/// LAYOUT property, and each of those asks AppKit to re-lay out the window —
/// the transcript included — every display frame. Since the curves are longer
/// than the gap between levels, that re-layout never stopped.
///
/// Now the bars are the shared WaveBar: their height is a transform, the layout
/// engine only ever sees one fixed slot, and there is no implicit animation
/// anywhere — the meter simply follows the level it is given, which arrives
/// often enough (~12 Hz) to look alive on its own.
private struct LevelWave: View {
    let level: Double
    private static let profile: [Double] = [0.36, 0.64, 1.0, 0.64, 0.36]
    private static let slot: CGFloat = 16

    var body: some View {
        WaveShape(heights: Self.profile.map { CGFloat(4 + 12 * level * $0) },
                  barWidth: 3, spacing: 2.5)
            .fill(Brand.cyan)
            .frame(width: 5 * 3 + 4 * 2.5, height: Self.slot)
    }
}

/// Recording indicator: a red dot with a slow, calm pulse.
///
/// The pulse is STEPPED by a schedule, not faded by an implicit animation.
/// This one 8pt dot used a `.repeatForever(autoreverses:)` fade on its
/// opacity, and measured on its own in this window that cost 14.4% of a core —
/// the same ~19%-class bill WaveMark's animation turned out to carry, for the
/// same reason: a repeatForever animation never settles, so SwiftUI asks the
/// window for a new frame sixty times a second for as long as it runs. And
/// this one runs for the WHOLE length of every call (it is in the transcript's
/// header and again in the library's live row), which is precisely when the
/// machine is also carrying the call, a screen share and Whisper.
///
/// A blink needs about two frames a second, not sixty. A periodic
/// `TimelineView` gives exactly that, stops itself when the view goes away,
/// and — unlike a repeatForever animation — has nothing that can keep running
/// after the dot is gone.
private struct PulsingDot: View {
    /// Blinking is motion; someone who has asked the system for less of it
    /// gets a steady dot, which says "recording" just as well.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let beat: TimeInterval = 0.6

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.beat)) { context in
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(reduceMotion || lit(context.date) ? 1 : 0.45)
        }
    }

    private func lit(_ date: Date) -> Bool {
        Int(date.timeIntervalSinceReferenceDate / Self.beat) % 2 == 0
    }
}

/// The meeting, minimized: proof that it is still recording, how long it has
/// run, and the two controls that matter — stop, and back to the transcript.
///
/// Deliberately the dictation pill's shape, material and corner radius: the
/// app already has one word for "something is being recorded right now", and a
/// second dialect would only make the two look like different products. It is
/// the same object at a different size, not a new one.
///
/// What it does NOT show is the speaker's name, and that is a decision rather
/// than an omission. A glanceable badge is read without context and believed;
/// a diarizer label is a guess that this project has repeatedly had to correct
/// (a monologue was split across two names as recently as this week). The
/// transcript is where a label can be seen next to the words that justify it,
/// and renamed when it is wrong — a pill is not.
struct MeetingPillView: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var loc = Localization.shared
    let onStop: () -> Void
    let onExpand: () -> Void
    /// Put even this away: the recording carries on, and the menu bar's red
    /// wave becomes the only thing saying so. The third step of one gesture —
    /// close the transcript to get the pill, close the pill to get the menu
    /// bar — rather than a separate idea to be discovered.
    let onHide: () -> Void

    static let size = CGSize(width: 280, height: 64)

    var body: some View {
        // Two rows, and the second one spans the whole width on purpose.
        // With the state text sharing a column beside the buttons it had 97pt
        // to live in, and "Warming up the model…" needs 127 in English, 135 in
        // German and 137 in French — every language truncated, measured rather
        // than eyeballed. Given its own line it has 250, which fits the longest
        // string in all thirteen with room left.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                LevelWave(level: session.audioLevel)
                // One tick a second, and only while the pill is on screen —
                // the TimelineView stops itself when the view goes away. The
                // house pattern for anything periodic here (see PulsingDot);
                // a repeating animation would bill sixty frames a second for
                // the whole length of the call.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed).font(.body.monospacedDigit())
                }
                Spacer(minLength: 0)
                ChromeButton(icon: "stop.fill", help: L("Stop recording"),
                             tint: .red, action: onStop)
                ChromeButton(icon: "chevron.up", help: L("Show transcript"), action: onExpand)
                ChromeButton(icon: "xmark", help: L("Hide"), action: onHide)
            }
            Text(state)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var elapsed: String {
        let s = max(0, Int(Date().timeIntervalSince(session.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The same three phrases the full window's status strip uses, so the two
    /// sizes of the same window never disagree about what is happening.
    private var state: String {
        if session.modelWarming { return L("Warming up the model…") }
        if session.inflightCount > 0 { return L("Recognizing…") }
        if session.listeningFor != nil { return L("Listening…") }
        return L("Recording")
    }
}

/// The tags on one meeting: what it is filed under, and the one control that
/// changes that.
///
/// The interface IS the gatekeeper here. Asset systems that survive give a
/// person the job of approving new terms, because a free text box drifts into
/// synonyms — "acme", "Acme Corp", "acme-corp" — and a vocabulary with three
/// words for one idea answers a third of the questions it should. With one
/// user there is nobody to hold that job, so it is held by two mechanics:
/// every tag is normalised on the way in (MeetingTags), and what already
/// exists is always offered before anything new is typed. Adding a familiar
/// tag has to be easier than inventing one, or the two diverge.
///
/// What is deliberately absent is a tag manager. This class of feature is
/// killed by ceremony far more often than by missing power: the documented
/// failure is perfectionism paralysis — people plan a taxonomy, tag for two
/// weeks, then stop, and the archive ends up half-filed, which is worse than
/// not filed at all. Add, remove, filter. Nothing else.
private struct TagRow: View {
    let tags: [String]
    let known: [(tag: String, count: Int)]
    let onChange: ([String]) -> Void
    let onFilter: (String) -> Void
    @ObservedObject private var loc = Localization.shared
    @State private var adding = false
    @State private var addHovering = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag,
                        onFilter: { onFilter(tag) },
                        onRemove: { onChange(tags.filter { $0 != tag }) })
            }
            Button { adding = true } label: {
                ChromeGlyph(icon: tags.isEmpty ? "tag" : "plus", hovering: addHovering)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Add a tag"))
            .onHover { addHovering = $0 }
            .popover(isPresented: $adding, arrowEdge: .bottom) { addPopover }
            if tags.isEmpty {
                Text(L("No tags")).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MeetingsChrome.inset)
        .padding(.vertical, 5)
    }

    /// Type, and see what you already use. The suggestions are the point: the
    /// list is what keeps the next meeting filed under the same word as the
    /// last one.
    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("Tag"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commit(draft) }
            let matches = suggestions
            if !matches.isEmpty {
                Divider()
                ForEach(matches, id: \.tag) { item in
                    Button { commit(item.tag) } label: {
                        HStack {
                            Text("#\(item.tag)").font(.callout)
                            Spacer()
                            Text("\(item.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            // Creating a NEW term is a separate, deliberate act rather than
            // whatever happens when you stop typing — that is the whole
            // difference between a vocabulary and a text box.
            if let fresh = MeetingTags.normalize(draft), !known.contains(where: { $0.tag == fresh }) {
                Divider()
                Button { commit(fresh) } label: {
                    Text(Lf("Create #%@", fresh)).font(.callout)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 220)
    }

    private var suggestions: [(tag: String, count: Int)] {
        let typed = MeetingTags.normalize(draft)
        return known
            .filter { !tags.contains($0.tag) }
            .filter { typed == nil || $0.tag.contains(typed!) }
            .prefix(6)
            .map { $0 }
    }

    private func commit(_ raw: String) {
        defer { draft = ""; adding = false }
        guard let tag = MeetingTags.normalize(raw) else { return }
        onChange(MeetingTags.unique(tags + [tag]))
    }
}

/// One tag on a meeting: click it to see everything else filed there, and
/// remove it with the × that appears under the pointer.
///
/// The click USED to remove the tag, which was wrong twice over. A destructive
/// action does not belong on the main target of a control — the owner tapped a
/// tag he had just added and watched it vanish — and it wasted the one gesture
/// everybody tries first on a chip. Filtering is what a tag is FOR, so that is
/// what clicking it does; it also turns out to be how the filter gets
/// discovered at all, which typing "#tag" into a search field never was.
private struct TagChip: View {
    let tag: String
    let onFilter: () -> Void
    /// Filled in rather than tinted: the filter row has to say which tags are
    /// ON, or picking a second one is guesswork.
    var active: Bool = false
    /// nil where there is nothing to remove FROM — the library's filter row
    /// shows the same chip, but a tag is not attached to anything there.
    var onRemove: (() -> Void)? = nil
    @ObservedObject private var loc = Localization.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onFilter) {
                Text("#\(tag)").font(.caption)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Lf("Show everything tagged #%@", tag))

            // A real button, not a decoration on a tap gesture: removing has
            // to be something you aim at, and only what you aimed at is what
            // goes away.
            if hovering, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.caption2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Lf("Remove #%@ from this meeting", tag))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Brand.indigoLabel.opacity(
            active ? 1.0 : (hovering ? 0.20 : 0.12))))
        .foregroundStyle(active ? Color.white : Brand.indigoLabel)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}


/// One line of the contents block: when it starts, and what was discussed
/// there. Clicking scrolls the transcript to that moment.
///
/// The timestamp is monospaced and dim, the line is ordinary text — the same
/// pairing the transcript itself uses for a turn, so the contents read as an
/// index OF this document rather than as a separate widget bolted above it.
private struct SectionLink: View {
    let section: TranscriptSection
    let onJump: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onJump) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.time.prefix(5))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(section.line)
                    // A step below the summary AND below the transcript, so
                    // this block reads as an index rather than as a third
                    // block of prose competing with the two around it.
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
