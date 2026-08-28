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
    /// Whether the optional text model may still be offered here. Observed so
    /// that "Not now" empties every surface at once.
    @ObservedObject private var offer = LocalTextModelOffer.shared
    let onStop: () -> Void
    /// Starts a meeting recording through the owner's consent-aware path —
    /// the same flow the menu bar uses (first-run consent alert included).
    let onRecord: () -> Void
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
    /// The "How this works" popover on the first-run empty state.
    @State private var showingHowItWorks = false
    /// The bottom-left corner menu (design).
    @State private var settingsMenuOpen = false
    /// Which panes are folded away (design MeetingsWindow: panes) — the
    /// sidebar and the meeting list each have a toggle in the reading pane's
    /// header. Persisted: a layout choice outlives the window.
    @State private var sidebarHidden = UserDefaults.standard.bool(forKey: "meetingsSidebarHidden")
    @State private var listHidden = UserDefaults.standard.bool(forKey: "meetingsListHidden")
    @State private var convHidden = UserDefaults.standard.bool(forKey: "meetingsConvHidden")

    /// The adjustable column widths (a preference of the eyes, like text
    /// size): the design's 214/296 until dragged, then whatever was chosen.
    @State private var navWidth: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "meetingsNavWidth")
        return v > 0 ? CGFloat(v) : 214
    }()
    @State private var listWidth: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "meetingsListWidth")
        return v > 0 ? CGFloat(v) : 296
    }()
    @State private var convWidth: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "meetingsConvWidth")
        return v > 0 ? CGFloat(v) : 268
    }()

    /// Bumped on every star toggle — the one thing that makes a UserDefaults
    /// write visible to SwiftUI (see body).
    @State private var starRevision = 0
    /// Same disease, different organ: Ask on/off lives in Settings (plain
    /// UserDefaults). Turning it off in the Settings window must take the Ask
    /// row, header button and footer link out of THIS window immediately.
    @State private var askArchiveOn = Settings.shared.askArchive
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
        /// The conversation itself, entered cold from the pinned sidebar row —
        /// no question yet, just the place where asking happens. The same
        /// pane as `.answer`; the difference is only how one arrives.
        case ask

        var url: URL? {
            switch self {
            case .live, .answer, .ask: return nil
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
        // Stars live in UserDefaults, not in the meetings array — toggling
        // one changes nothing SwiftUI diffs, so the click LOOKED dead (field
        // report 2026-08-27). Reading the revision here makes the whole tree
        // re-evaluate on every toggle: the header star fills, the sidebar
        // count moves.
        let _ = starRevision
        let _ = askArchiveOn
        // Three columns, the design's own (t13): navigation 214, the meeting
        // list 296, and the reading pane. Selecting Ask drops the list column
        // so the answer gets the width (t2); All Meetings brings it back.
        // The first two dividers drag (owner 2026-08-29) — widths persist,
        // clamped so neither column can crush its content or eat the pane.
        HStack(spacing: 0) {
            if !sidebarHidden {
                navColumn.frame(width: navWidth)
                ColumnGrip(width: $navWidth, range: 180...320, key: "meetingsNavWidth")
                    .zIndex(2)
            }
            if selection != .ask, !listHidden {
                listColumn.frame(width: listWidth)
                ColumnGrip(width: $listWidth, range: 240...420, key: "meetingsListWidth")
                    .zIndex(2)
            }
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Any defaults write, filtered down to the one this window must
        // mirror live: the Ask switch in the Settings window.
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            if Settings.shared.askArchive != askArchiveOn {
                askArchiveOn = Settings.shared.askArchive
                if !askArchiveOn, selection == .ask { selection = nil }
            }
        }
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
            // Screenshot harness (design pass): select the newest meeting
            // once the archive has loaded.
            if UserDefaults.standard.string(forKey: "debugShotMeetings") == "first" {
                UserDefaults.standard.removeObject(forKey: "debugShotMeetings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if let first = meetings.first { selection = .archived(first.url) }
                }
            }
            // Ask is the selected item at launch (design t2) — the window
            // opens on the question, not on a transcript. With the agent off
            // the nil selection keeps the old portal home, which carries the
            // connect offer.
            if Settings.shared.askArchive, selection == nil, !session.isActive {
                selection = .ask
            }
            reload {
                // A meeting picked in the menu wins over the default — the
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
            // about the very same meeting twice. The session kicks the
            // backfills itself the moment that titling is done
            // (MeetingSession.kickBackfills).
        }
        // A summary landed on disk for one of the older meetings: pick it up.
        // Only ever a handful of times, and only while the backfill runs —
        // there is nothing here that ticks.
        .onChange(of: summaries.written) { _ in reload() }
        // A contents block landed. Same story, and just as rare: only while
        // the backfill runs, and nothing here ticks.
        .onChange(of: sections.written) { _ in reload() }
        .sheet(isPresented: $showConnect) {
            AgentConnectSheet(question: connectQuestion, onConnected: {
                showConnect = false
                // The first success is the answer to the question they came
                // with — with whatever passages the search had already found.
                if let question = connectQuestion?.trimmingCharacters(in: .whitespaces),
                   !question.isEmpty {
                    askScope = nil
                    answer.scopePath = nil
                    answer.ask(question, from: [], using: oracle)
                    selection = .ask
                }
                connectQuestion = nil
            }, onCancel: {
                showConnect = false
                connectQuestion = nil
            })
        }
    }

    // MARK: - Sidebar

    /// The library column: a search row of exactly the same height as the
    /// transcript's header, then the list. The two headers share one horizontal
    /// rule that runs the full width of the window — the cheapest possible
    /// proof that the two panes are one surface and not two.
    /// Column one (214, design t13): the window's own buttons up top, the
    /// Library and Sources navigation, and an ambient footer — "watching" at
    /// rest, the recording controls while a session runs.
    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' zone. AppKit draws them over the title-bar
            // band; this row only reserves their height so the nav starts
            // under them — the one place the system owns the corner.
            Color.clear.frame(height: MeetingsChrome.headerHeight)
            libraryNav
            Spacer(minLength: 0)
            if showsLibraryOffer {
                TextModelOffer(line: L("Your meetings are named by their date. A one-time download, kept on this Mac, writes titles, summaries and a table of contents."))
            }
            Divider()
            navFooter
        }
        // An explicit AppKit sidebar material, not the window's background:
        // it distinguishes the library from the transcript in both themes, and
        // (state = .active) it keeps doing so while the panel is not key.
        .background(SidebarMaterial())
    }

    /// The sidebar's bottom line: readiness at rest, the recording controls
    /// while a session runs — with no clock (one clock per surface, 12d; the
    /// header carries this window's).
    @ViewBuilder
    private var navFooter: some View {
        if session.isActive {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    PulsingDot()
                    Text(L("Recording"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
                Button {
                    session.stop()
                } label: {
                    Text(L("Stop Recording"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.record)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(.plain)
                .background(DS.hoverFill,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .hoverHighlight(radius: 7)
            }
            .padding(11)
        } else {
            HStack(spacing: 9) {
                Circle().fill(DS.good).frame(width: 8, height: 8)
                Text(L("Watching for browser calls"))
                    .font(DS.helpText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        // The corner Settings row (design): the gear, the word, the ⌘, —
        // and a small menu of the destinations that used to need the menu
        // bar (Settings, shortcuts, appearance, models, updates, quit).
        Button {
            settingsMenuOpen.toggle()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .frame(width: 15)
                Text(L("Settings"))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("⌘,")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .popover(isPresented: $settingsMenuOpen, arrowEdge: .top) {
            settingsCornerMenu
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// The corner menu (design): quick doors in the app's own menu
    /// vocabulary. Every row closes the menu and goes.
    private var settingsCornerMenu: some View {
        VStack(alignment: .leading, spacing: 1) {
            cornerRow(L("Settings…"), trailing: "⌘,") { openSettingsWindow(tab: nil) }
            cornerRow(L("Keyboard shortcuts")) { openSettingsWindow(tab: "keys") }
            Divider().padding(.vertical, 4)
            cornerRow(L("Appearance"), trailing: appearanceValue) { openSettingsWindow(tab: "general") }
            cornerRow(L("Storage & models")) { openSettingsWindow(tab: "meetings") }
            Divider().padding(.vertical, 4)
            cornerRow(L("Check for updates")) {
                settingsMenuOpen = false
                NotificationCenter.default.post(name: .init("dictate.checkUpdates"), object: nil)
            }
            cornerRow(L("Quit Dictate"), trailing: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(5)
        .frame(width: 212)
    }

    private var appearanceValue: String {
        switch Settings.shared.appearance {
        case "light": return L("Light")
        case "dark": return L("Dark")
        default: return L("Match system")
        }
    }

    private func openSettingsWindow(tab: String?) {
        settingsMenuOpen = false
        if let tab { UserDefaults.standard.set(tab, forKey: "settingsOpenTab") }
        NotificationCenter.default.post(name: .init("dictate.openSettings"), object: nil)
    }

    private func cornerRow(_ title: String, trailing: String? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    /// Column two (296): search up top in its own 52 pt header, the meetings
    /// by day beneath, the search-scoped offers at the foot.
    private var listColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                searchField
            }
            .padding(.horizontal, 12)
            // With the sidebar folded this column owns the window's top-left
            // corner, and the search field must clear the traffic lights.
            .padding(.leading, sidebarHidden ? MeetingsChrome.trafficLights - 12 : 0)
            .padding(.vertical, 8)
            Divider()
            if !session.isActive {
                Button {
                    onRecord()
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(.white).frame(width: 7, height: 7)
                        Text(L("Record"))
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    // Accent, not record-red: the house rule keeps red for
                    // "recording is HAPPENING", never for a button at rest.
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.accent))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEmphasis(scale: 1.02)
                .help(L("Record this call"))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            tagFilterRow
                .padding(.horizontal, 12)
                .padding(.top, 6)
            list
        }
    }

    private var list: some View {
        // Selection is OURS, not the List's: the system sidebar pill is a
        // solid accent fill, and the design's selection is a 12% tint with a
        // 3 px accent edge (13a) — the two cannot coexist, so the List gets
        // no selection binding and the rows carry the look themselves.
        // Arrow keys are re-wired below (onMoveCommand), which is what once
        // kept this on the system look.
        List {
            if session.isActive {
                Section(L("Now")) {
                    selectable(liveRow, .live)
                }
            }
            ForEach(groupedMeetings, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        selectable(meetingRow(meeting), .archived(meeting.url))
                    }
                }
            }
            // Asking is one row, not a second field, and it is LAST — under
            // the results, never instead of them (the pattern search-plus-AI
            // products converge on: the literal results stay primary, the
            // escalation is explicit). It used to require the meaning search
            // to have found something — honest while the model could only
            // read supplied passages, a dead end now that the agent can list,
            // search and read the archive itself.
            // Off by default, and off means absent. A greyed-out row would
            // still be telling somebody who chose local-only that there is an
            // online thing here they are missing.
            if Settings.shared.askArchive,
               !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    selectable(askRow, .answer(query))
                }
            } else if !Settings.shared.askArchive,
                      !query.trimmingCharacters(in: .whitespaces).isEmpty,
                      agentOffer.allowed {
                // The agent is off and somebody just typed a question it
                // could answer — the one moment a pointer is honest rather
                // than a banner. Same budget and dismissal as every offer.
                Section {
                    connectTeaserRow
                }
            }
        }
        // Selecting the ask row is what starts the work. Not typing, not a
        // timer, not a guess about what the words meant — a person chose it.
        .onChange(of: selection) { picked in
            guard case .answer(let question) = picked else { return }
            guard answer.lastQuestion != question || answer.lastFailure != nil else { return }
            // Appends to the running conversation: the session is the window's
            // lifetime, and a question asked from a fresh search joins it with
            // its fresh passages rather than starting over.
            answer.ask(question, from: [], using: oracle)
        }
        .listStyle(.sidebar)
        // The list draws itself on the sidebar material above, instead of
        // stacking a second, opaque panel of its own on top of it.
        .scrollContentBackground(.hidden)
        .focused($listFocused)
        // Arrow keys, hand-wired: without a selection binding the List no
        // longer moves anything itself. Same order the eye reads.
        .onMoveCommand { direction in moveSelection(direction) }
        .overlay {
            if filtered.isEmpty && !session.isActive,
               !meetings.isEmpty, !MeetingSearch.split(query: query).tags.isEmpty {
                // Tag filters combine with AND, and that rule is exactly what
                // an empty tag-filtered list needs to say (design: tagEmpty) —
                // with the one-click ways out beside it. Compact, hand-built:
                // ContentUnavailableView is a full-window poster, and in the
                // 296 pt column it wrapped its own buttons past the edges
                // (field report 2026-08-28).
                let activeTags = MeetingSearch.split(query: query).tags
                ListEmptyState(
                    title: activeTags.count == 1 ? L("No meeting has this tag")
                                                 : L("No meeting has all of these tags"),
                    blurb: L("Tag filters combine with “and” — a meeting must carry every selected tag to appear.")) {
                    if activeTags.count > 1, let last = activeTags.last {
                        Button(Lf("Remove “%@”", last)) { toggleTagFilter(last) }
                    }
                    Button(L("Clear All Filters")) {
                        query = MeetingSearch.split(query: query).text
                    }
                }
            } else if filtered.isEmpty && !session.isActive {
                ListEmptyState(
                    title: meetings.isEmpty ? L("No meetings yet") : L("Nothing found"),
                    blurb: meetings.isEmpty
                         ? L("Start a transcript from the menu bar during a call.")
                         : L("No transcript contains that.")) {
                }
            }
        }
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
                        .padding(2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .hoverHighlight(radius: 6)
                .padding(-2)
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
            DS.shape
                .fill(DS.restingFill)
        )
        .overlay(
            DS.shape
                .strokeBorder(searchFocused ? DS.accentText : Color.primary.opacity(0.12),
                              lineWidth: searchFocused ? 1.5 : 1)
        )
    }

    private var liveRow: some View {
        // No clock here: elapsed time lives once per surface, and this
        // window's home for it is the header (12d) — a second clock one inch
        // away could visibly disagree with it by a second.
        HStack(spacing: 8) {
            PulsingDot()
            Text(L("Recording now"))
                .font(.callout.weight(.medium))
        }
        .padding(.vertical, 2)
    }

    /// The design's selection (13a): a 12% accent tint with a 3 px accent
    /// edge on the left — never a filled row. Tap selects; the row keeps its
    /// text colours in both states, which is the point of a tint.
    @ViewBuilder
    private func selectable<V: View>(_ content: V, _ value: Selection) -> some View {
        SelectableRow(selected: selection == value,
                      tap: { selection = value }) { content }
            .id(value)
    }

    /// Everything currently in the list, top to bottom — the path the arrow
    /// keys walk.
    private func visibleSelections() -> [Selection] {
        var out: [Selection] = []
        if session.isActive { out.append(.live) }
        for group in groupedMeetings { out += group.meetings.map { .archived($0.url) } }
        if Settings.shared.askArchive,
           !query.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(.answer(query))
        }
        return out
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        let order = visibleSelections()
        guard !order.isEmpty else { return }
        guard let current = selection, let idx = order.firstIndex(of: current) else {
            selection = direction == .down ? order.first : order.last
            return
        }
        let next = direction == .down ? min(idx + 1, order.count - 1) : max(idx - 1, 0)
        selection = order[next]
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
                            .background(Capsule().fill(DS.accentText.opacity(0.12)))
                            .foregroundStyle(DS.accentText)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
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
        // The platform, when the recording knew it ("· Google Meet").
        if let source = meeting.source { facts.append(source) }
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
                .foregroundStyle(DS.accentText)
            Text(L("Ask the agent about this"))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    /// The pointer shown in place of the ask row while the agent is off.
    private var connectTeaserRow: some View {
        Button {
            connectQuestion = query
            showConnect = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(DS.accentText)
                Text(L("The agent could answer this — connect Claude or ChatGPT."))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .onAppear { agentOffer.noteShown() }
    }

    /// The Library block at the top of the sidebar (design t2): Ask, the
    /// whole archive, the starred shortlist, and the platforms the calls ran
    /// on. Selection wears the tint-plus-edge, never a filled row (13a).
    @ViewBuilder
    private var libraryNav: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L("Library"))
                .font(DS.sectionLabel)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 3)
            if Settings.shared.askArchive {
                navRow(icon: "questionmark.bubble", title: L("Ask"),
                       selected: selection == .ask) {
                    askScope = nil
                    selection = .ask
                    // One lit row, always (owner's report 2026-08-29: Ask and
                    // Starred glowed together). Entering Ask retires the list
                    // filters — they are a place in the library, and Ask is
                    // another place.
                    starredOnly = false
                    recentOnly = false
                    sourceFilter = nil
                }
            }
            navRow(icon: "rectangle.grid.1x2", title: L("All Meetings"),
                   count: meetings.count,
                   selected: selection != .ask && !starredOnly && !recentOnly
                             && sourceFilter == nil) {
                starredOnly = false
                recentOnly = false
                sourceFilter = nil
                if selection == .ask, let newest = meetings.first {
                    selection = .archived(newest.url)
                }
            }
            let starredCount = meetings.filter { MeetingStars.isStarred($0.started) }.count
            if starredCount > 0 || starredOnly {
                navRow(icon: starredOnly ? "star.fill" : "star", title: L("Starred"),
                       count: starredCount, selected: starredOnly) {
                    starredOnly.toggle()
                    if starredOnly { recentOnly = false; sourceFilter = nil }
                    leaveAsk()
                }
            }
            navRow(icon: "clock", title: L("Recently Added"),
                   selected: recentOnly) {
                recentOnly.toggle()
                if recentOnly { starredOnly = false; sourceFilter = nil }
                leaveAsk()
            }
            let sources = sourcesPresent
            // Shown whenever anything is bucketed at all (design): even one
            // "Other browser calls" row tells where the archive came from.
            if !sources.isEmpty || sourceFilter != nil {
                Text(L("Sources"))
                    .font(DS.sectionLabel)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 3)
                ForEach(sources, id: \.name) { source in
                    let name = source.name == Self.otherSourcesBucket
                        ? L("Other browser calls") : source.name
                    navRow(icon: "video", dot: Self.sourceDot(source.name),
                           title: name, count: source.count,
                           selected: sourceFilter == source.name) {
                        sourceFilter = sourceFilter == source.name ? nil : source.name
                        if sourceFilter != nil { starredOnly = false; recentOnly = false }
                        leaveAsk()
                    }
                }
            }
        }
        .padding(.horizontal, MeetingsChrome.sidebarInset)
        .padding(.bottom, 6)
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: DS.reveal)) { sidebarHidden.toggle() }
        UserDefaults.standard.set(sidebarHidden, forKey: "meetingsSidebarHidden")
    }

    private func toggleList() {
        withAnimation(.easeInOut(duration: DS.reveal)) { listHidden.toggle() }
        UserDefaults.standard.set(listHidden, forKey: "meetingsListHidden")
    }

    private func toggleConversations() {
        withAnimation(.easeInOut(duration: DS.reveal)) { convHidden.toggle() }
        UserDefaults.standard.set(convHidden, forKey: "meetingsConvHidden")
    }

    /// The pane switches for a reading-pane header (design MeetingsWindow:
    /// "Show or hide the sidebar/meeting list"). When the pane holding this
    /// cluster has become the window's leftmost, it also reserves the room
    /// the traffic lights occupy — the header row IS the title bar here.
    private enum PaneContext { case meeting, ask }

    private func paneToggles(_ context: PaneContext) -> AnyView {
        let secondHidden = context == .meeting ? listHidden : convHidden
        let leftmost = sidebarHidden && secondHidden
        return AnyView(HStack(spacing: 2) {
            ChromeButton(icon: "sidebar.left",
                         help: L("Show or hide the sidebar")) { toggleSidebar() }
            ChromeButton(icon: "sidebar.right",
                         help: context == .meeting
                             ? L("Show or hide the meeting list")
                             : L("Show or hide the conversations")) {
                if context == .meeting { toggleList() } else { toggleConversations() }
            }
        }
        .padding(.leading, leftmost ? MeetingsChrome.trafficLights - MeetingsChrome.inset : 0))
    }

    /// A filter row was clicked while Ask was open: the person asked to SEE
    /// that slice of the library, so the pane goes back to reading — the same
    /// move the All Meetings row already makes.
    private func leaveAsk() {
        if selection == .ask, let newest = meetings.first {
            selection = .archived(newest.url)
        }
    }

    /// The platform marker dots of the Sources group (design): Meet blue,
    /// Zoom teal, everything else violet.
    private static func sourceDot(_ name: String) -> Color {
        switch name {
        case "Google Meet": return DS.accent
        case "Zoom": return DS.you
        default: return DS.them
        }
    }

    private func navRow(icon: String, dot: Color? = nil, title: String,
                        count: Int? = nil,
                        selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let dot {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dot)
                        .frame(width: 8, height: 8)
                        .frame(width: 16)
                } else {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(selected ? DS.accentText : .secondary)
                }
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(DS.timestamp)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .background(
            HStack(spacing: 0) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DS.accent)
                        .frame(width: DS.selectionEdge)
                }
                Rectangle().fill(selected ? DS.selectionTint : .clear)
            }
        )
        .hoverHighlight()
        .clipShape(DS.shape)
    }

    @ViewBuilder
    private var answerPane: some View {
        AnswerPane(answer: answer,
                   suggestions: askSuggestions,
                   headerNote: askHeaderNote,
                   open: { source in
            // Going to the passage is an ordinary selection, so the answer
            // stays behind in the list and one click comes back to it.
            selection = source.time.map { .moment(source.url, $0) } ?? .archived(source.url)
        }, followUp: { question in
            // One Ask, always global (16): no new passages — a question typed
            // in the pane leans on the conversation and on the agent's own
            // tools, which search and read the whole archive.
            answer.ask(question, from: [], using: oracle)
        }, newChat: {
            answer.clear()
            askScope = nil
        }, onAddKey: {
            connectQuestion = answer.lastQuestion ?? ""
        }, stats: askStats,
           headerLeading: paneToggles(.ask))
    }

    /// A copy of the transcript wherever the user points — the .md is the
    /// export format (it IS the file), so this is a save panel and a copy.
    private func exportTranscript(_ meeting: ArchivedMeeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.url.lastPathComponent
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: meeting.url, to: destination)
        }
    }

    /// The honest line under the Ask title: search is local, the written
    /// answer is not — it comes from the user's provider with their own key
    /// (design 16; the header must never claim "answered on this Mac").
    private var askHeaderNote: String? {
        guard let provider = Settings.shared.askProvider else { return nil }
        return meetings.isEmpty
            ? Lf("Quotes come from your transcripts; the written answer comes from %@ with your own key.", provider.productName)
            : Lf("Across all %d meetings · answered by %@", meetings.count, provider.productName)
    }

    /// Seeds for the cold conversation — a blank prompt box is a question
    /// nobody can answer (the articulation barrier), so the pane opens with
    /// three the archive can. The third names the newest titled meeting: the
    /// one suggestion that proves the agent has read THIS person's calls.
    private var askSuggestions: [String] {
        var out = [L("What did I promise, and to whom?"),
                   L("What decisions were made this week?")]
        if let titled = meetings.compactMap(\.title).first {
            out.append(Lf("What was “%@” about?", titled))
        }
        return out
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .answer, .ask:
            // The Ask view brings its conversation column (11j): past
            // questions, titled by their first one, opened without re-asking.
            // Same manners as the meeting list: the conversations column
            // drags and remembers its width (owner 2026-08-29).
            HStack(spacing: 0) {
                if !convHidden {
                    ConversationsColumn(answer: answer,
                                        onOpen: { answer.restore($0) },
                                        onNew: { answer.clear() })
                        .frame(width: convWidth)
                    ColumnGrip(width: $convWidth, range: 220...380, key: "meetingsConvWidth")
                        .zIndex(2)
                }
                answerPane
            }
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
                           headerLeading: paneToggles(.meeting)) {
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
                               onGrow: { detail, done in growCut(meeting, to: detail, done: done) },
                               recutting: recutting == meeting.url,
                               recutLevel: sectionLevel[meeting.url],
                               recutLevels: SectionCache.levels(for: meeting.url,
                                                                entries: meeting.entries),
                               cuts: {
                                   var out: [MeetingPolicy.SectionDetail: [TranscriptSection]] = [:]
                                   for level in MeetingPolicy.SectionDetail.allCases {
                                       if let cut = SectionCache.cut(meeting.url, meeting.entries, level) {
                                           out[level] = cut
                                       }
                                   }
                                   return out
                               }(),
                               durationMinutes: Int((meeting.duration ?? 0) / 60),

                               notice: declined(meeting)
                                   ? AnyView(TextModelOffer(line: L("The built-in model had nothing to say about this meeting. A one-time download, kept on this Mac, is not restricted that way.")))
                                   : nil,
                               headerLeading: paneToggles(.meeting),
                               // One Ask, never scoped (16): a transcript's
                               // ask affordance is a door to the single
                               // global Ask — the answer names the meeting
                               // itself, in prose and in every quote.
                               onAsk: Settings.shared.askArchive ? {
                                   askScope = nil
                                   answer.scopePath = nil
                                   selection = .ask
                               } : nil,
                               starred: MeetingStars.isStarred(meeting.started),
                               onStar: {
                                   MeetingStars.toggle(meeting.started)
                                   starRevision += 1
                                   reload()
                               },
                               onExport: { exportTranscript(meeting) }) {
                    Button(MeetingStars.isStarred(meeting.started)
                           ? L("Unstar meeting") : L("Star meeting")) {
                        MeetingStars.toggle(meeting.started)
                        starRevision += 1
                        reload()
                    }
                    Button(L("Rename meeting…")) { renamingFromMenu = true }
                    Button(L("Copy transcript")) {
                        TranscriptCopy.put(TranscriptCopy.transcript(meeting.entries))
                    }
                    Button(L("Export transcript…")) { exportTranscript(meeting) }
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
            // The brief-portal is retired (the design's launch view is Ask):
            // with nothing selected the pane shows the first-run empty state
            // (10a) or the plain placeholder, never a dashboard.
            if meetings.isEmpty, !session.isActive {
                firstRunEmpty
            } else {
                placeholder
            }
        }
    }

    /// The whole window before anything was ever recorded (design 10a): the
    /// monochrome mark and one sentence, with the way to start.
    private var firstRunEmpty: some View {
        VStack(spacing: 13) {
            GlyphMark(state: .idle, color: .primary.opacity(0.22), width: 46)
            Text(L("No meetings yet"))
                .font(.system(size: 15, weight: .semibold))
            Text(L("Dictate can record a browser call and keep the transcript on this Mac. Start one from the menu bar when your next call begins — you will be asked for consent once."))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L("Start Recording a Meeting")) { onRecord() }
                    .buttonStyle(.dsPrimary)
                Button(L("How this works")) { showingHowItWorks = true }
                    .buttonStyle(.dsRegular)
                    .popover(isPresented: $showingHowItWorks, arrowEdge: .bottom) {
                        Text(L("Join a call in the browser, then start recording. Dictate captures your microphone and the call audio, transcribes both on this Mac, and keeps the transcript here. Nothing is uploaded."))
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .frame(width: 280, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                // an empty pane is the window asking to be looked at. The mark
                // is the identity glyph — the one drawing, every surface.
                GlyphMark(state: session.isActive ? .meeting : .idle,
                          color: .primary.opacity(0.25), width: 46)
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
        var out = MeetingSearch.literal(meetings, query: query)
        if starredOnly { out = out.filter { MeetingStars.isStarred($0.started) } }
        if recentOnly {
            let cutoff = Date().addingTimeInterval(-7 * 86400)
            out = out.filter { $0.started >= cutoff }
        }
        if let sourceFilter {
            out = out.filter { ($0.source ?? Self.otherSourcesBucket) == sourceFilter }
        }
        return out
    }

    /// The bucket every un-attributed call falls into ("Other browser calls"
    /// in the sidebar) — a browser holds the mic for every web call alike, so
    /// most history lives here honestly.
    static let otherSourcesBucket = "…"

    /// Platforms present in the archive, most-used first, with the "other"
    /// bucket last when anything is unattributed.
    private var sourcesPresent: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for meeting in meetings { counts[meeting.source ?? Self.otherSourcesBucket, default: 0] += 1 }
        var out = counts.filter { $0.key != Self.otherSourcesBucket }
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        if let other = counts[Self.otherSourcesBucket] {
            out.append((name: Self.otherSourcesBucket, count: other))
        }
        return out
    }

    /// Meetings that are ABOUT what was typed without containing it.
    /// "38 meetings · 26 h of audio" for the docked composer (design).
    private var askStats: String? {
        guard !meetings.isEmpty else { return nil }
        let seconds = meetings.reduce(0.0) { $0 + ($1.duration ?? 0) }
        let hours = Int((seconds / 3600).rounded())
        return hours >= 1
            ? Lf("%d meetings · %d h of audio", meetings.count, hours)
            : Lf("%d meetings · %d min of audio", meetings.count, max(1, Int(seconds / 60)))
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
    /// Generates a granularity into the cache WITHOUT touching the file —
    /// the outline's depth control needs the cut, not a rewritten document.
    private func growCut(_ meeting: ArchivedMeeting, to detail: MeetingPolicy.SectionDetail,
                         done: @escaping () -> Void) {
        if SectionCache.cut(meeting.url, meeting.entries, detail) != nil { done(); return }
        Task { @MainActor in
            let sections = await MeetingSectioner.sections(for: meeting.entries, detail: detail)
            if !sections.isEmpty {
                SectionCache.remember(sections, for: meeting.url, meeting.entries, detail)
            }
            reload()
            done()
        }
    }

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

    /// The meeting the conversation is currently scoped to — set by the
    /// transcript header's ask button, cleared by the portal, the pinned
    /// entry and New chat. The scope rides into the prompt (see
    /// scopedSources), not into the UI state machine.
    @State private var askScope: ArchivedMeeting?

    /// Library filters (sidebar): the starred shortlist and one platform.
    @State private var starredOnly = false
    /// The sidebar's Recently Added filter (design): the last seven days.
    @State private var recentOnly = false
    @State private var sourceFilter: String?

    /// The connect sheet, and the question that opened it — asked the moment
    /// the key verifies, because the first success must be an answer, not a
    /// stored credential.
    @ObservedObject private var agentOffer = AgentOffer.shared
    @State private var showConnect = false
    @State private var connectQuestion: String?

    /// Who answers — the provider picked in Settings; everything above this
    /// knows only the protocol.
    private var oracle: MeetingOracle {
        switch Settings.shared.askProvider {
        case .openai: return OpenAIAPIOracle()
        // Off never reaches here (the ask row is gated on askArchive), and if
        // it somehow did, an oracle whose key is missing fails politely.
        case .anthropic, nil: return ClaudeAPIOracle()
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
        // Where the call ran (design: "· Google Meet") — the fact that used
        // to hide in the list row belongs with the meeting's own facts.
        if let source = meeting.source { parts.append(source) }
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
    static let headerHeight: CGFloat = 52
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
            .background(Capsule().fill(DS.record.opacity(hovering ? 0.18 : 0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.record)
        .help(L("Stop recording"))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.fade), value: hovering)
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
                DS.shape
                    .fill((tint ?? Color.primary).opacity(hovering ? (tint == nil ? 0.08 : 0.16) : 0))
            )
            // Same rule as the copy chip: the target is the square around the
            // chip, so most of what takes the click is invisible padding.
            .frame(width: TurnCopy.targetSize, height: TurnCopy.targetSize)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: DS.fade), value: hovering)
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
struct SidebarMaterial: View {
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
                    .font(DS.timestamp)
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
    /// Fills a missing granularity into the cache (no file rewrite) and calls
    /// back when it is there — the depth control's background growth.
    var onGrow: ((MeetingPolicy.SectionDetail, @escaping () -> Void) -> Void)? = nil
    /// True while that is happening, so the block can say so instead of
    /// looking broken for the twenty seconds a recut takes.
    var recutting = false
    /// Which granularity is showing, when anyone knows. nil for a meeting cut
    /// by the ordinary backfill, which is most of them — the control then
    /// highlights nothing rather than claiming a level it cannot verify.
    var recutLevel: MeetingPolicy.SectionDetail? = nil
    /// Which granularities this meeting actually has. A short call has one
    /// shape; offering three would be a control that lies about what it can do.
    var recutLevels: Set<MeetingPolicy.SectionDetail> = []
    /// Every cut already generated for this meeting (SectionCache) — the raw
    /// material the outline nests from.
    var cuts: [MeetingPolicy.SectionDetail: [TranscriptSection]] = [:]
    /// The meeting's length in minutes — what decides how many levels the
    /// outline is allowed (design MeetingOutline).
    var durationMinutes: Int = 0
    /// A one-line notice under the header — the offer of the text model, on
    /// the one meeting the built-in one refused to describe. nil is the
    /// ordinary case, which is every meeting and every live call.
    var notice: AnyView? = nil
    /// The window-level pane toggles, handed in by whoever owns the panes —
    /// this pane only gives them the header's leading end to sit on.
    var headerLeading: AnyView? = nil
    /// Opens the conversation scoped to this meeting. nil while the agent is
    /// off (absent, not greyed) and for live calls.
    var onAsk: (() -> Void)? = nil
    /// The header's own quick actions for a finished meeting (design detail
    /// bar): the star and the export, with names for VoiceOver (8a).
    var starred: Bool = false
    var onStar: (() -> Void)? = nil
    var onExport: (() -> Void)? = nil
    /// What the ⋯ menu offers for this transcript. Passed as items rather than
    /// as a whole menu so both call sites get the identical button.
    @ViewBuilder let menuItems: () -> MenuItems

    @ObservedObject private var loc = Localization.shared
    /// Whether the contents are open. Per pane rather than remembered: a
    /// choice about one meeting's shape is not a preference about all of them,
    /// and it resets when you move on, which is what you would want anyway.
    /// The outline opens FOLDED on every meeting (owner's call 2026-08-28):
    /// expanding is a deliberate act and is not remembered.
    @State private var outlineFolded = true
    /// The reading scale (design MeetingOutline: the three-A tray). Global —
    /// a reading preference follows the eyes, not the meeting.
    @State private var textScale = DS.TextScale.current
    /// Fewer / Standard / More — how deep the tree SHOWS (owner's report:
    /// the control used to re-cut the file and visibly change nothing).
    @State private var outlineDepth: OutlineDepth = .standard
    /// Which collapsed branches are open right now.
    @State private var expandedBranches: Set<String> = []
    /// A missing granularity is being generated in the background.
    @State private var growingOutline = false

    enum OutlineDepth: Int, CaseIterable { case fewer = 1, standard = 2, more = 3 }
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
            // Archived meetings carry the MeetingOutline head: the title at
            // reading size inside the pane, the channel legend under it. A
            // live call keeps the compact chrome header — its cast and
            // length are still being written.
            if live == nil, !entries.isEmpty {
                archivedHead
            } else {
                header
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
            if live == nil, let onAsk {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("Questions are never limited to one meeting. Ask searches everything you have recorded and the answer names the meeting and the person."))
                        .font(DS.helpText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L("Open Ask")) { onAsk() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.accentText)
                        .hoverHighlight(radius: DS.radiusChip)
                        .pointerStyle(.link)
                }
                .padding(.horizontal, MeetingsChrome.inset)
                .padding(.top, 11)
                .padding(.bottom, 13)
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

    /// The archived meeting's head (design MeetingOutline): the title at
    /// 19 pt inside the pane — this surface's own headline, not window
    /// chrome — the date line under it, the actions at the right, and the
    /// channel legend with the honesty chip, closed by a hairline.
    private var archivedHead: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                if let headerLeading {
                    headerLeading.padding(.top, 3)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let onRetitle {
                        Button {
                            titleDraft = title
                            retitling = true
                        } label: {
                            Text(title)
                                .font(.system(size: 19, weight: .bold))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(radius: 5)
                        .pointerStyle(.link)
                        .padding(.horizontal, -4)
                        .help(L("Rename this meeting"))
                        .popover(isPresented: $retitling, arrowEdge: .bottom) {
                            retitlePopover(onRetitle)
                        }
                    } else {
                        Text(title)
                            .font(.system(size: 19, weight: .bold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    // The reading-size tray (design MeetingOutline): part of
                    // the head's actions, parted from them by a hair of rail.
                    DSTextSizeTray(scale: Binding(
                        get: { textScale },
                        set: { newValue in
                            textScale = newValue
                            Settings.shared.transcriptTextSize = newValue.rawValue
                        }))
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 0.5, height: 20)
                    HStack(spacing: 2) {
                        if let onStar {
                            ChromeButton(icon: starred ? "star.fill" : "star",
                                         help: starred ? L("Unstar meeting") : L("Star meeting"),
                                         tint: starred ? DS.accentText : nil,
                                         action: onStar)
                        }
                        if let onExport {
                            ChromeButton(icon: "square.and.arrow.up",
                                         help: L("Export transcript…"),
                                         action: onExport)
                        }
                        menuButton
                    }
                }
                .padding(.top, 2)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("Voices"))
                        .font(DS.sectionLabel)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.3)
                    FlowRow(spacing: 6) {
                        ForEach(speakingShares, id: \.name) { share in
                            VoiceChip(name: share.name, isYou: share.isYou,
                                      minutes: share.minutes, onRename: onRename)
                        }
                    }
                }
            }
            .padding(.bottom, 14)
        }
        .padding(.top, 16)
        .padding(.horizontal, 24)
        .overlay(alignment: .bottom) { Divider() }
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
            if let headerLeading {
                headerLeading.padding(.trailing, 4)
            }
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
                        Text(title).font(DS.windowTitle).lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(radius: 5)
                    .pointerStyle(.link)
                    .padding(.horizontal, -4)
                    .help(L("Rename this meeting"))
                    .popover(isPresented: $retitling, arrowEdge: .bottom) {
                        retitlePopover(onRetitle)
                    }
                } else {
                    Text(title).font(DS.windowTitle).lineLimit(1)
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
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: DS.reveal), value: context.date)
                }
                if let onStop {
                    StopButton(action: onStop)
                }
            }
            if let onStar {
                ChromeButton(icon: starred ? "star.fill" : "star",
                             help: starred ? L("Unstar meeting") : L("Star meeting"),
                             tint: starred ? DS.accentText : nil,
                             action: onStar)
            }
            if let onExport {
                ChromeButton(icon: "square.and.arrow.up",
                             help: L("Export transcript…"),
                             action: onExport)
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

    /// Seconds-of-day of the meeting's first entry — the zero the relative
    /// stamps count from.
    private var startSeconds: Int? {
        entries.first.flatMap { MeetingArchive.seconds(fromClock: $0.time) }
    }

    /// "02:12" from the wall clock — the design's meeting-relative stamp.
    /// Falls back to the wall clock when either end fails to parse.
    private func relativeStamp(_ clock: String) -> String {
        guard let sec = MeetingArchive.seconds(fromClock: clock),
              let zero = startSeconds else { return clock }
        let d = (sec - zero + 86400) % 86400
        return d >= 3600
            ? String(format: "%d:%02d:%02d", d / 3600, (d % 3600) / 60, d % 60)
            : String(format: "%02d:%02d", d / 60, d % 60)
    }

    /// Rough speaking share per side of the call: each entry counts until the
    /// next one starts, capped at 25 s (a cap because the gap after the LAST
    /// word of a monologue is silence, not speech). An estimate presented as
    /// one ("~14 min") — good enough for "who did the talking".
    private var speakingShares: [(name: String, isYou: Bool, minutes: Int)] {
        var seconds: [String: Int] = [:]
        var isYou: [String: Bool] = [:]
        var order: [String] = []
        for (i, entry) in entries.enumerated() {
            guard let start = MeetingArchive.seconds(fromClock: entry.time) else { continue }
            let next = i + 1 < entries.count
                ? MeetingArchive.seconds(fromClock: entries[i + 1].time) : nil
            let span = min(max((next ?? start + 10) - start, 2), 25)
            if seconds[entry.speaker] == nil { order.append(entry.speaker) }
            seconds[entry.speaker, default: 0] += span
            isYou[entry.speaker] = entry.isYou
        }
        return order.map { (name: $0, isYou: isYou[$0] ?? false,
                            minutes: max(1, (seconds[$0] ?? 0) / 60)) }
    }

    /// The legend's two channels (design): everything of yours on one dot,
    /// everything of the call's — however many voices — on the other. The
    /// per-voice split lives in the turns, where the names are.
    private var channelShares: [(name: String, isYou: Bool, minutes: Int)] {
        let you = speakingShares.filter(\.isYou).reduce(0) { $0 + $1.minutes }
        let them = speakingShares.filter { !$0.isYou }.reduce(0) { $0 + $1.minutes }
        var out: [(String, Bool, Int)] = []
        if you > 0 { out.append((L("You"), true, you)) }
        if them > 0 { out.append((L("Call audio"), false, them)) }
        return out.map { (name: $0.0, isYou: $0.1, minutes: $0.2) }
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
        // Facts only (design): date · length · source. The speaker chips are
        // gone from here — a four-voice call turned the subtitle into a
        // wrapping chip pile, and renaming lives on the turns anyway.
        let facts = subtitle ?? ""
        if !facts.isEmpty {
            Text(facts)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 14)
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
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) { retitling = false }
                    .buttonStyle(.dsSmall)
                Button(L("Save")) { retitling = false; commit(titleDraft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.dsSmall)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            // Still even during a live call, which is the case this was most
            // tempting to animate. Measured at the size it actually renders,
            // an animating mark costs ~19% of a core for as long as it is on
            // screen — and the moment it would be on screen is the top of a
            // call, with Meet, a screen share and Whisper already on the same
            // cores. It would also be saying something the window says twice
            // already and more cheaply: the header carries the recording dot
            // and the running time, and the status strip below carries a live
            // level meter and the word "Listening…". The mark is a mark.
            GlyphMark(state: live != nil ? .meeting : .idle,
                      color: .primary.opacity(0.22), width: 46)
            if live != nil {
                Text(L("Waiting for speech…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // An archived recording with no words in it (design: noSpeech).
                // Named as a diagnosis, not shrugged off as "empty": in the
                // field this is almost always the call audio never arriving.
                Text(L("Nothing was said, or nothing was heard"))
                    .font(.system(size: 15, weight: .semibold))
                Text(L("The recording ran, but no speech was recognized on either side. Usually this means the call audio was never captured — a browser tab without audio permission, or the wrong output device."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Check Audio Setup")) {
                    NSWorkspace.shared.open(URL(
                        string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                .buttonStyle(.dsRegular)
                .padding(.top, 2)
            }
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
        VStack(alignment: .leading, spacing: 18) {
            // Tags first (design MeetingOutline): part of the document's
            // head matter, labelled like its siblings.
            if let onTags {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("Tags"))
                        .font(DS.sectionLabel)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.3)
                    TagRow(tags: tags, known: knownTags, onChange: onTags,
                           onFilter: { onTagFilter?($0) })
                }
            }
            if let overviewSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Summary"))
                        .font(DS.sectionLabel)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.3)
                    Text(overviewSummary)
                        .font(.system(size: textScale.body))
                        .lineSpacing(textScale.extraLeading / 2)
                        .frame(maxWidth: DS.readingMeasure, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            outlineBlock(jump: jump)
            // Not a hairline. Above it is what this meeting WAS; below it
            // is what was said, and the eye should not have to work out
            // where one becomes the other — which was the whole complaint.
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 2)
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// One outline row: the stamp in accent, the line, an optional trailing
    /// figure (a section's span, a collapsed branch's count).
    private func outlineRow(time: String, line: String, weight: Font,
                            ink: Color, trailing: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(relativeStamp(time))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(DS.accentText)
                    .frame(width: 44, alignment: .leading)
                    .help(time)
                Text(line)
                    .font(weight)
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let trailing {
                    Spacer(minLength: 8)
                    Text(trailing)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 7)
        .padding(.horizontal, -8)
        .pointerStyle(.link)
    }

    /// The rail an indented level hangs from (design: 0.5 pt line).
    private func rail<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.leading, 16)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5)
            }
            .padding(.leading, 20)
    }

    /// The navigation (design MeetingOutline). Folded on every open; the
    /// depth control decides how much of the tree SHOWS — Fewer is sections
    /// alone, Standard opens one level, More opens everything — and a depth
    /// the cuts cannot serve yet is grown in the background under shimmer
    /// rows. Under ten minutes there is nothing to navigate at all.
    @ViewBuilder
    private func outlineBlock(jump: @escaping (String) -> Void) -> some View {
        let outline = MeetingOutlineModel.build(
            cuts: effectiveCuts, minutes: durationMinutes)
        if !outline.nodes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(outlineEyebrow(outline))
                        .font(DS.sectionLabel)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.3)
                    if !outlineFolded {
                        DSSegmented(options: [
                            (OutlineDepth.fewer, L("Fewer")),
                            (OutlineDepth.standard, L("Standard")),
                            (OutlineDepth.more, L("More")),
                        ], selection: $outlineDepth)
                        .onChange(of: outlineDepth) { _ in growForDepth(outline) }
                        if growingOutline {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(outlineFolded ? L("Show outline") : L("Hide outline")) {
                        withAnimation(.easeOut(duration: DS.fade)) {
                            outlineFolded.toggle()
                        }
                        if !outlineFolded { growForDepth(outline) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.accentText)
                    .hoverHighlight(radius: DS.radiusChip)
                    .pointerStyle(.link)
                }
                if !outlineFolded {
                    outlineTree(outline, jump: jump)
                        .frame(maxWidth: DS.readingMeasure, alignment: .leading)
                    if growingOutline { shimmerRows }
                }
            }
        }
    }

    /// How deep the current duration is ALLOWED to go (design: two levels to
    /// forty minutes, three past it).
    private var allowedDepth: Int { durationMinutes > 40 ? 3 : 2 }

    /// The depth control asked for more than the cuts can serve — grow the
    /// next missing granularity in the background.
    private func growForDepth(_ outline: MeetingOutlineModel) {
        guard let onGrow, !growingOutline else { return }
        let want = min(outlineDepth.rawValue, allowedDepth)
        guard outline.levels < want else { return }
        let order: [MeetingPolicy.SectionDetail] = [.coarse, .standard, .fine]
        guard let missing = order.first(where: { effectiveCuts[$0]?.isEmpty ?? true })
        else { return }
        growingOutline = true
        onGrow(missing) { growingOutline = false }
    }

    /// Placeholder rows while a granularity is being cut (the design's
    /// shimmer skeleton).
    private var shimmerRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<2, id: \.self) { i in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .frame(width: 44, height: 9)
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .frame(width: i == 0 ? 260 : 180, height: 9)
                }
            }
        }
        .shimmering()
        .padding(.leading, 8)
    }

    /// The tree, drawn to the chosen depth. One available level renders in
    /// the leaf voice — bold section heads exist only once they HAVE children
    /// (owner's report: a flat list of bold rows read as a bug).
    @ViewBuilder
    private func outlineTree(_ outline: MeetingOutlineModel,
                             jump: @escaping (String) -> Void) -> some View {
        let depth = min(outlineDepth.rawValue, max(outline.levels, 1))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(outline.nodes, id: \.section.time) { top in
                VStack(alignment: .leading, spacing: 3) {
                    if outline.levels == 1 {
                        outlineRow(time: top.section.time, line: top.section.line,
                                   weight: .system(size: textScale.leaf),
                                   ink: .secondary) { jump(top.section.time) }
                    } else {
                        outlineRow(time: top.section.time, line: top.section.line,
                                   weight: .system(size: 13.5, weight: .semibold),
                                   ink: .primary,
                                   trailing: outline.levels == 3 ? top.span : nil) {
                            jump(top.section.time)
                        }
                        if depth >= 2, !top.children.isEmpty {
                            rail {
                                ForEach(top.children, id: \.section.time) { mid in
                                    midBranch(mid, depth: depth, jump: jump)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func midBranch(_ mid: MeetingOutlineModel.Node, depth: Int,
                           jump: @escaping (String) -> Void) -> some View {
        if mid.children.isEmpty {
            outlineRow(time: mid.section.time, line: mid.section.line,
                       weight: .system(size: textScale.leaf),
                       ink: .secondary) { jump(mid.section.time) }
        } else if depth >= 3 || expandedBranches.contains(mid.section.time) {
            VStack(alignment: .leading, spacing: 2) {
                outlineRow(time: mid.section.time, line: mid.section.line,
                           weight: .system(size: 12.5, weight: .medium),
                           ink: .primary) {
                    if depth >= 3 { jump(mid.section.time) }
                    else {
                        withAnimation(Animation.easeOut(duration: DS.fade)) {
                            _ = expandedBranches.remove(mid.section.time)
                        }
                    }
                }
                rail {
                    ForEach(mid.children, id: \.section.time) { leaf in
                        outlineRow(time: leaf.section.time, line: leaf.section.line,
                                   weight: .system(size: textScale.leaf),
                                   ink: .secondary) { jump(leaf.section.time) }
                    }
                }
            }
        } else {
            outlineRow(time: mid.section.time, line: mid.section.line,
                       weight: .system(size: 12.5, weight: .medium),
                       ink: .secondary,
                       trailing: Lf("%d moments", mid.children.count)) {
                withAnimation(Animation.easeOut(duration: DS.fade)) {
                    _ = expandedBranches.insert(mid.section.time)
                }
            }
        }
    }

    private func outlineEyebrow(_ outline: MeetingOutlineModel) -> String {
        var parts = [L("Outline"), Lf("%d moments", outline.momentCount)]
        if outline.levels == 3 { parts.append(L("three levels")) }
        else if outline.levels == 2 { parts.append(L("two levels")) }
        return parts.joined(separator: " · ")
    }

    /// The cuts on hand: the cache's plus whatever cut the file itself holds
    /// (the current one, under its level when known — standard otherwise).
    private var effectiveCuts: [MeetingPolicy.SectionDetail: [TranscriptSection]] {
        var out = cuts
        if !overviewSections.isEmpty {
            out[recutLevel ?? .standard] = overviewSections
        }
        return out
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
                // The head matter (summary + outline) sits OUTSIDE the lazy
                // stack: as a lazy row it was unmeasured after a jump to a
                // moment, and scrolling back up kept landing short of the top
                // as its real height snapped in (field report 2026-08-28,
                // second time this class of bug bit).
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    overview { moment in jump(to: moment, proxy) }
                LazyVStack(alignment: .leading, spacing: textScale.turnGap) {
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
                                 relative: relativeStamp(turn.time),
                                 scale: textScale,
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
                .padding(.top, 16)
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
                // nothing is being dragged — and the outline folds again.
                outlineFolded = true
                expandedBranches = []
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
                        .font(DS.timestamp)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .hoverEmphasis()
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
            withAnimation(.easeInOut(duration: DS.reveal)) { proxy.scrollTo("top", anchor: .top) }
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
        .hoverEmphasis()
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
        withAnimation(.easeOut(duration: DS.fade)) { copiedVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard token == copyFlash else { return }   // a newer copy owns the badge
            withAnimation(.easeIn(duration: DS.reveal)) { copiedVisible = false }
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
    /// The unconfirmed utterance: upright and at full contrast, marked by a
    /// coloured rule instead of dim italics (13a) — a hypothesis is still
    /// words being read, and dimming it punished exactly the line the reader
    /// is following live. The rule (accent, 2 px) is what says "not final".
    private func currentLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(DS.accent)
                .frame(width: 2)
            Text(text)
                .font(.system(size: textScale.body))
                .lineSpacing(textScale.extraLeading / 3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var listeningLine: some View {
        HStack(spacing: 6) {
            Circle().fill(DS.good).frame(width: 5, height: 5)
            Text(L("Listening…")).font(.callout).foregroundStyle(.secondary)
        }
    }

}

/// A draggable column divider (design MeetingsWindow: grip). At rest a short
/// 2×44 pill marks the handle; while dragging the line runs full height in
/// accent and a floating badge names the live width. The width is computed
/// ABSOLUTELY — the width at drag start plus how far the mouse travelled in
/// global coordinates. The first version applied local deltas, and since the
/// divider moves with the column, its coordinate space moved too: a feedback
/// loop the owner reported as "трясётся как неимоверное".
private struct ColumnGrip: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let key: String
    @State private var startWidth: CGFloat?
    @State private var dragging = false

    var body: some View {
        Divider()
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(dragging ? DS.accent : Color.primary.opacity(0.12))
                    .frame(width: 2)
                    .frame(maxHeight: dragging ? .infinity : 44)
            )
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if startWidth == nil {
                                startWidth = width
                                dragging = true
                            }
                            let base = startWidth ?? width
                            width = min(max(base + value.translation.width,
                                            range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in
                            startWidth = nil
                            dragging = false
                            UserDefaults.standard.set(Double(width), forKey: key)
                        })
            )
            .overlay(alignment: .topLeading) {
                if dragging {
                    Text(verbatim: "\(Int(width)) pt")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.24), radius: 11, y: 4))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5))
                        .fixedSize()
                        .offset(x: 8, y: 60)
                }
            }
            .animation(.easeOut(duration: DS.fade), value: dragging)
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
            DS.chipShape
                .fill(hovering || isOpen ? DS.hoverFill : .clear)
        )
        .animation(.easeOut(duration: DS.fade), value: hovering)

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
            // Plainly said (12h): a voice is an acoustic cluster, not an
            // identified person — the rename applies to this voice's turns
            // and the label must not borrow more certainty than that.
            Text(L("Voices are matched by sound — the name applies only to this voice's turns."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) { commit(nil) }
                    .buttonStyle(.dsSmall)
                Button(L("Save")) { commit(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.dsSmall)
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
        colors[speaker] ?? (isYou ? DS.you : DS.them)
    }

    /// Two streams, two colours (13a: colour does one job) — your microphone
    /// is teal, everything from the call side is violet. Speakers left the
    /// accent hue so a name never looks tappable, and the remote VOICES share
    /// one hue on purpose: their names ("Speaker 1", "Anna") carry identity,
    /// the colour only carries which side of the call it came from.
    private static func palette(for entries: [TranscriptEntry]) -> [String: Color] {
        var colors: [String: Color] = [:]
        for entry in entries where colors[entry.speaker] == nil {
            colors[entry.speaker] = entry.isYou ? DS.you : DS.them
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
    /// The meeting-relative stamp ("02:12"), computed by the pane — derived
    /// from turn.time, so Equatable needs nothing extra.
    let relative: String
    /// The reading scale, as a value — rows are Equatable and must re-render
    /// when the tray is clicked, so the scale is part of their identity.
    let scale: DS.TextScale
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
            && a.scale == b.scale
    }

    var body: some View {
        if DBG.trace { let _ = Self._printChanges() }
        // The design's gutter grammar: a fixed right-aligned speaker column
        // (the name IS the colour carrier — no dot), the meeting-relative
        // stamp under it, and the words beside them at reading size. The wall
        // clock is one hover away on the stamp.
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .trailing, spacing: 1) {
                Button {
                    draft = turn.speaker
                    renaming = true
                } label: {
                    Text(turn.speaker)
                        .font(.system(size: scale.speaker, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 3)
                        // A name long enough to wrap would push the row (and
                        // its click target) around; one line, truncated, keeps
                        // the column the same shape for every speaker.
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .hoverHighlight(radius: DS.radiusChip)
                .pointerStyle(.link)
                .padding(.horizontal, -3)
                .help(L("Rename this speaker"))
                .popover(isPresented: $renaming, arrowEdge: .bottom) {
                    renamePopover
                }
                Text(relative)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(turn.time)
            }
            .frame(width: 84, alignment: .trailing)
            // Reading type (13a): 15/1.65 on a 72-character measure — the
            // transcript is the content, and it is finally larger than the
            // chrome around it.
            Text(turn.text)
                .font(.system(size: scale.body))
                .lineSpacing(scale.extraLeading / 2)
                .frame(maxWidth: DS.readingMeasure, alignment: .leading)
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
            DS.shape
                .fill(highlight)
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
                .animation(.easeOut(duration: DS.fade), value: hovering)
        )
        .contextMenu {
            Button(L("Copy text")) { onCopy(turn, false) }
            Button(L("Copy with speaker and time")) { onCopy(turn, true) }
        }
    }

    /// ⌘A's selection is the loud one; hover is a whisper whose only job is to
    /// say which block the copy button and ⌘C mean.
    private var highlight: Color {
        if selected { return DS.selectionFill }
        return hovering ? DS.hoverFill : .clear
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
                    DS.shape
                        .fill(hovering ? DS.hoverFill : .clear)
                )
                // The target is the square, not the glyph: everything around
                // the chip is padding that still takes the click.
                .frame(width: TurnCopy.targetSize, height: TurnCopy.targetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: DS.fade), value: hovering)
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

/// "It's alive" strip: the state as a chip, and BOTH streams metered — the
/// two-stream speaker model made visible where the recording happens. No
/// clock here: elapsed time lives once per surface, in the header (12d).
private struct StatusStrip: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        HStack(spacing: 16) {
            chip
            meter(label: L("You"), level: session.youLevel, tint: DS.you)
            meter(label: L("Call"), level: session.themLevel, tint: DS.them)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MeetingsChrome.inset)
        .padding(.vertical, 8)
    }

    /// One state at a time. Recognizing wears the dots-on-the-line glyph —
    /// the family's one drawing of that state; downloads and warming keep the
    /// system ring (task progress, not a state).
    @ViewBuilder
    private var chip: some View {
        if session.modelWarming {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("Warming up the model…")).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10).frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        } else if session.inflightCount > 0 {
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 0.35)) { context in
                    GlyphMark(state: .recognizing(phase:
                        Int(context.date.timeIntervalSinceReferenceDate / 0.35)),
                        color: DS.accent, width: 15)
                }
                Text(L("Recognizing…")).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(DS.accent)
            .padding(.horizontal, 10).frame(height: 22)
            .background(Capsule().fill(DS.selectionTint))
        } else if session.listeningFor != nil {
            HStack(spacing: 6) {
                Circle().fill(DS.good).frame(width: 6, height: 6)
                Text(L("Listening…")).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(DS.good)
            .padding(.horizontal, 10).frame(height: 22)
            .background(Capsule().fill(DS.good.opacity(0.1)))
        }
    }

    private func meter(label: String, level: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(4, 110 * min(1, level * 1.6)))
                    .animation(.linear(duration: 0.12), value: level)
            }
            .frame(width: 110, height: 4)
        }
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
            .fill(DS.you)
            .frame(width: 5 * 3 + 4 * 2.5, height: Self.slot)
    }
}

/// Recording indicator: a red dot with a slow, calm pulse.
///
/// The pulse is STEPPED by a schedule, not faded by an implicit animation.
/// This one 8pt dot used a `.repeatForever(autoreverses:)` fade on its
/// opacity, and measured on its own in this window that cost 14.4% of a core —
/// the same ~19%-class bill the old animated mark turned out to carry, for the
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

    /// The hosting panel's fixed frame — big enough for the widest variant
    /// (the one-time education card); the drawn material is smaller and the
    /// window shadow hugs it, so the spare space is invisible.
    static let size = CGSize(width: 344, height: 168)

    @State private var gripHover = false
    /// One-time education: the first fold-away mid-recording expands the pill
    /// into a card saying that closing did not stop anything (field test
    /// 2026-08-19: the owner read the collapse as "everything stopped").
    @State private var educating = false
    // No hover expansion. It was tried (design 9b's two-meter card) and cut
    // by the owner (2026-08-27): the mouse travelling TOWARD the capsule's
    // own buttons swapped the capsule for the card, so the buttons could
    // never be clicked — a hover trap. The capsule is self-sufficient: stop,
    // transcript and hide are on it, and the glyph carries the live level.

    var body: some View {
        Group {
            if educating {
                educationCard
            } else {
                capsule
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .onAppear {
            guard !Settings.shared.meetingPillNoticeSeen, session.isActive else { return }
            Settings.shared.meetingPillNoticeSeen = true
            educating = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { educating = false }
        }
    }

    /// The 42 pt collapsed capsule: proof it is running (the meeting glyph,
    /// its bars carrying the live level), elapsed time, and the three
    /// controls. Stop is a neutral control with a red glyph — red is status,
    /// never a button fill (12c).
    /// The 2×3 drag-grip dot cluster at the capsule's leading edge.
    private var gripDots: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(Color.primary)
    }

    private var capsule: some View {
        HStack(spacing: 11) {
            gripDots
                .opacity(gripHover ? 0.7 : 0.4)
                .onHover { gripHover = $0 }
                .pointerStyle(.grabIdle)
                .animation(.easeOut(duration: DS.fade), value: gripHover)
            if session.finishing {
                ProgressView().controlSize(.small)
                Text(L("Finishing the transcript…"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            } else {
                meetingGlyph(width: 22)
                clock
                if session.lowDisk {
                    Text(L("Disk almost full — will stop to keep the transcript"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.warn)
                        .lineLimit(2)
                        .frame(maxWidth: 130, alignment: .leading)
                } else if let notice = session.deviceNotice {
                    // The input device changed mid-recording — said in
                    // passing, without stopping (design: interrupted).
                    Text(notice)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 130, alignment: .leading)
                }
                Divider().frame(height: 20)
                ChromeButton(icon: "line.3.horizontal", help: L("Show transcript"),
                             action: onExpand)
                ChromeButton(icon: "stop.fill", help: L("Stop recording"),
                             tint: DS.record, action: onStop)
                ChromeButton(icon: "xmark", help: L("Hide"), action: onHide)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 42)
        .fixedSize()
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// Hover: the two streams metered separately — what tells "You" from
    /// "Call audio" in the transcript, made visible where the recording is.
    /// Shown once, the first time the window is closed mid-recording.
    private var educationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                meetingGlyph(width: 18)
                Text(L("Still recording"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                clock
            }
            Text(L("Closing the window does not stop the recording. Stop it here, or from the menu bar at any time."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                pillButton(L("Got it")) { educating = false }
                pillButton(L("Stop Recording"), tint: DS.record, action: onStop)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
        .frame(width: 330)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// The meeting glyph with its bars driven by the combined level — "the
    /// state glyph carries the live level" (turn 11); the record dot is the
    /// one red thing and it never pulses.
    private func meetingGlyph(width: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            GlyphMark(state: .recording(level: session.audioLevel),
                      color: .primary, width: width)
            Circle().fill(DS.record)
                .frame(width: width * 0.22, height: width * 0.22)
                .offset(x: -width * 0.06, y: width * 0.16)
        }
    }

    private var clock: some View {
        // One tick a second, only while on screen — the TimelineView stops
        // itself with the view (the house pattern for anything periodic).
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(elapsed)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
    }


    private func pillButton(_ title: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: tint == nil ? .regular : .semibold))
                .foregroundStyle(tint ?? Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        .buttonStyle(.plain)
        .background(DS.hoverFill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .hoverHighlight(radius: 8)
    }

    private var elapsed: String {
        let s = max(0, Int(Date().timeIntervalSince(session.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
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
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text(L("Add tag"))
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(DS.accentText)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().strokeBorder(Color.primary.opacity(0.11)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .hoverHighlight(radius: 11)
            .pointerStyle(.link)
            .help(L("Add a tag"))
            .popover(isPresented: $adding, arrowEdge: .bottom) { addPopover }
            Spacer(minLength: 0)
        }
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
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .padding(.horizontal, -6)
                }
            }
            // Creating a NEW term is a separate, deliberate act rather than
            // whatever happens when you stop typing — that is the whole
            // difference between a vocabulary and a text box.
            if let fresh = MeetingTags.normalize(draft), !known.contains(where: { $0.tag == fresh }) {
                Divider()
                Button { commit(fresh) } label: {
                    Text(Lf("Create #%@", fresh)).font(.callout)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .padding(.horizontal, -6)
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
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(radius: 5)
                .padding(-2)
                .help(Lf("Remove #%@ from this meeting", tag))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(DS.accentText.opacity(
            active ? 1.0 : (hovering ? 0.20 : 0.12))))
        .foregroundStyle(active ? Color.white : DS.accentText)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.fade), value: hovering)
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
                    .font(DS.timestamp)
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
                DS.shape
                    .fill(hovering ? DS.hoverFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.fade), value: hovering)
    }
}

/// One list-column row: our own selection (12% tint + 3 px edge, 13a) and a
/// hover wash — the List has no selection binding, so both live here.
private struct SelectableRow<Content: View>: View {
    let selected: Bool
    let tap: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .onHover { hovering = $0 }
            .listRowBackground(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? AnyShapeStyle(DS.selectionTint)
                              : hovering ? AnyShapeStyle(DS.hoverFill)
                              : AnyShapeStyle(Color.clear))
                    if selected {
                        Rectangle().fill(DS.accent).frame(width: DS.selectionEdge)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 6)
                .animation(.easeOut(duration: DS.fade), value: hovering)
            )
    }
}

/// The design's compact empty state (States.dc): the mark, a 15 pt title, a
/// quiet blurb, small actions — sized for the 296 pt column, where the
/// system's ContentUnavailableView is a full-window poster whose buttons ran
/// past the edges (field report 2026-08-28).
struct ListEmptyState<Actions: View>: View {
    let title: String
    let blurb: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            GlyphMark(state: .idle, color: .primary.opacity(0.22), width: 46)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(blurb)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }
                .buttonStyle(.dsSmall)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }
}

/// The outline's shape (design MeetingOutline), built from whatever cuts the
/// model has already produced. Pure and deterministic:
///
///   < 10 min      — no outline: the summary IS the navigation.
///   10–40 min     — two levels: the coarsest cut as sections, the next one
///                   as the moments inside them.
///   > 40 min      — three levels when three cuts exist; the middle level is
///                   what collapses to "N moments".
///
/// A finer line that repeats its parent word for word is dropped — the model
/// often opens a section with the same sentence at every granularity.
struct MeetingOutlineModel {
    struct Node {
        let section: TranscriptSection
        var children: [Node] = []
        /// A top-level section's span ("23 min"), filled for 3-level trees.
        var span: String?
    }

    let nodes: [Node]
    let levels: Int
    let momentCount: Int

    static func build(cuts: [MeetingPolicy.SectionDetail: [TranscriptSection]],
                      minutes: Int) -> MeetingOutlineModel {
        guard minutes >= 10 else { return .init(nodes: [], levels: 0, momentCount: 0) }
        let order: [MeetingPolicy.SectionDetail] = [.coarse, .standard, .fine]
        let present = order.compactMap { cuts[$0].flatMap { $0.isEmpty ? nil : $0 } }
        guard let top = present.first else { return .init(nodes: [], levels: 0, momentCount: 0) }
        let wantLevels = minutes > 40 ? 3 : 2
        let used = Array(present.prefix(wantLevels))

        func seconds(_ t: String) -> Int { MeetingArchive.seconds(fromClock: t) ?? 0 }
        func group(_ finer: [TranscriptSection], under parents: [TranscriptSection],
                   parent index: Int) -> [TranscriptSection] {
            let from = seconds(parents[index].time)
            let to = index + 1 < parents.count ? seconds(parents[index + 1].time) : Int.max
            return finer.filter {
                let t = seconds($0.time)
                return t >= from && t < to && $0.line != parents[index].line
            }
        }

        var nodes: [Node] = []
        var moments = 0
        for (i, sect) in top.enumerated() {
            var node = Node(section: sect)
            if used.count >= 2 {
                let mids = group(used[1], under: top, parent: i)
                if used.count == 3 {
                    node.children = mids.enumerated().map { j, mid in
                        var midNode = Node(section: mid)
                        midNode.children = group(used[2], under: mids, parent: j)
                            .map { Node(section: $0) }
                        return midNode
                    }
                    moments += node.children.reduce(0) { $0 + max($1.children.count, 1) }
                } else {
                    node.children = mids.map { Node(section: $0) }
                    moments += max(mids.count, 1)
                }
            } else {
                moments += 1
            }
            if used.count == 3 {
                let from = seconds(sect.time)
                let to = i + 1 < top.count ? seconds(top[i + 1].time) : from
                if to > from { node.span = Lf("%d min", max(1, (to - from) / 60)) }
            }
            nodes.append(node)
        }
        return .init(nodes: nodes, levels: used.count, momentCount: moments)
    }
}

/// One voice of the meeting (design MeetingOutline): a pill with the
/// channel dot, the name and the speaking share. A voice still wearing its
/// automatic label carries a pencil and opens the rename popover — the same
/// rename the turns offer, one click closer.
private struct VoiceChip: View {
    let name: String
    let isYou: Bool
    let minutes: Int
    let onRename: (String, String) -> Void

    @State private var renaming = false
    @State private var draft = ""

    /// An automatic label rather than a chosen name — in any UI language the
    /// file may have been written in.
    private var unnamed: Bool {
        if isYou { return false }
        if name == "Them" || name == "Call audio" { return true }
        return name.range(of: #"· (voice|голос|голос) \d+$"#,
                          options: .regularExpression) != nil
            || name.range(of: #"voice \d+$"#, options: .regularExpression) != nil
    }

    var body: some View {
        Button {
            guard !isYou else { return }
            draft = unnamed ? "" : name
            renaming = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isYou ? DS.you : DS.them)
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.system(size: 12, weight: unnamed ? .regular : .semibold))
                    .foregroundStyle(unnamed ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(Lf("%d min", minutes))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
                if unnamed {
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
            .overlay(Capsule().strokeBorder(
                Color.primary.opacity(unnamed ? 0.16 : 0.08), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEmphasis(scale: isYou ? 1.0 : 1.03)
        .pointerStyle(.link)
        .disabled(isYou)
        .help(isYou ? "" : L("Rename this speaker"))
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            SpeakerRenamePopover(draft: $draft) { newName in
                renaming = false
                guard let newName else { return }
                onRename(name, newName)
            }
        }
    }
}

/// A wrapping HStack (the design's flex-wrap): rows break where the width
/// runs out. Layout-protocol, no GeometryReader relayout storms.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
