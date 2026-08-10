import SwiftUI
import AppKit

/// The meetings surface: a library of past transcripts on the left, the
/// selected transcript — live or archived — on the right. One window instead
/// of "a debug panel plus a folder in Finder": the live call is simply the
/// first item in the list, so watching a call and reading last week's notes
/// are the same gesture.
struct MeetingsView: View {
    @ObservedObject var session: MeetingSession
    /// Subviews using L() must observe the localization (GRABLI).
    @ObservedObject private var loc = Localization.shared
    let onStop: () -> Void
    /// The window owner resizes/levels the panel when the library opens.
    let onSidebarChange: (Bool) -> Void

    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var selection: Selection?
    @State private var meetings: [ArchivedMeeting] = []
    @State private var query = ""
    /// The toolbar's Rename… routes to the same popover the title carries,
    /// so there is one editing surface no matter how you get to it.
    @State private var renamingFromMenu = false

    enum Selection: Hashable {
        case live
        case archived(URL)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .navigationTitle(L("Meetings"))
        .toolbar { toolbarItems }
        .onAppear {
            reload()
            // During a call the window is a glanceable strip over the call;
            // opened afterwards it is a library. The sidebar decides which.
            if session.isActive {
                selection = .live
                columns = .detailOnly
            } else {
                columns = .all
                selection = meetings.first.map { .archived($0.url) }
            }
        }
        .onChange(of: session.isActive) { active in
            // A finished session becomes a file: refresh and follow it.
            reload()
            if active { selection = .live }
            else if let newest = meetings.first { selection = .archived(newest.url) }
        }
        .onChange(of: columns) { value in
            onSidebarChange(value != .detailOnly)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
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
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: L("Search transcripts"))
        .overlay {
            if meetings.isEmpty && !session.isActive {
                ContentUnavailableView {
                    Label(L("No meetings yet"), systemImage: "text.bubble")
                } description: {
                    Text(L("Start a transcript from the menu bar during a call."))
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 2) {
            // A named meeting leads with its subject; an unnamed one is
            // known by when it happened.
            Text(meeting.title ?? timeOfDay(meeting.started))
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 5) {
                if meeting.title != nil {
                    Text(timeOfDay(meeting.started))
                    Text("·")
                }
                if let duration = meeting.duration {
                    Text(compactDuration(duration))
                }
                if !meeting.speakers.isEmpty {
                    Text("· \(meeting.speakers.count)")
                    Image(systemName: "person.wave.2")
                        .imageScale(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(meeting.preview)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .live:
            // A running meeting has no title yet (it is written when the
            // transcript closes), and its file is open for appending — so
            // titling waits until it's finished.
            TranscriptPane(entries: session.displayEntries,
                           title: L("Recording now"),
                           subtitle: nil,
                           live: session,
                           onStop: onStop,
                           onRename: { old, new in session.renameSpeaker(from: old, to: new) },
                           onRetitle: nil,
                           openRename: .constant(false))
        case .archived(let url):
            if let meeting = meetings.first(where: { $0.url == url }) {
                TranscriptPane(entries: meeting.entries,
                               title: meeting.title ?? dayAndTime(meeting.started),
                               subtitle: meeting.title == nil
                                   ? subtitle(for: meeting)
                                   : dayAndTime(meeting.started) + " · " + subtitle(for: meeting),
                               live: nil,
                               onStop: nil,
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
                               openRename: $renamingFromMenu)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            WaveMark(height: 40).opacity(0.45)
            Text(session.isActive ? L("Recording now") : L("Select a meeting"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if case .archived(let url) = selection,
               let meeting = meetings.first(where: { $0.url == url }) {
                Menu {
                    Button(L("Rename meeting…")) { renamingFromMenu = true }
                    Button(L("Copy transcript")) { copy(meeting) }
                    Button(L("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
                    }
                    Divider()
                    Button(L("Move to Trash"), role: .destructive) {
                        MeetingArchive.delete(meeting)
                        selection = nil
                        reload()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Data

    private var filtered: [ArchivedMeeting] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.entries.contains {
                $0.text.lowercased().contains(q) || $0.speaker.lowercased().contains(q)
            }
        }
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

    private func reload() {
        meetings = MeetingArchive.list()
    }

    private func copy(_ meeting: ArchivedMeeting) {
        let text = meeting.entries
            .map { "[\($0.time)] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func subtitle(for meeting: ArchivedMeeting) -> String {
        var parts: [String] = []
        if let duration = meeting.duration { parts.append(compactDuration(duration)) }
        if !meeting.speakers.isEmpty {
            parts.append(meeting.speakers.joined(separator: ", "))
        }
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

// MARK: - Transcript pane

/// Renders a transcript as a conversation: one block per turn, the speaker
/// named once in their own colour. A live session adds the recording header
/// and the status strip; an archived one is the same view without them, so
/// nothing about a finished meeting looks like a different app.
private struct TranscriptPane: View {
    let entries: [TranscriptEntry]
    let title: String
    let subtitle: String?
    let live: MeetingSession?
    let onStop: (() -> Void)?
    let onRename: (String, String) -> Void
    /// nil while a meeting is still recording — a title is written when the
    /// transcript closes.
    let onRetitle: ((String) -> Void)?
    /// Set by the toolbar's Rename… — the same popover, opened from elsewhere.
    @Binding var openRename: Bool

    @ObservedObject private var loc = Localization.shared
    @State private var retitling = false
    @State private var titleDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
        .onChange(of: openRename) { open in
            guard open, onRetitle != nil else { return }
            openRename = false
            titleDraft = title
            retitling = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if live?.isActive == true { PulsingDot() }
            VStack(alignment: .leading, spacing: 1) {
                if let onRetitle {
                    // The name the model chose is a suggestion, not a
                    // verdict: click it and type your own.
                    Button {
                        titleDraft = title
                        retitling = true
                    } label: {
                        Text(title).font(.headline)
                    }
                    .buttonStyle(.plain)
                    .help(L("Rename this meeting"))
                    .popover(isPresented: $retitling, arrowEdge: .bottom) {
                        retitlePopover(onRetitle)
                    }
                } else {
                    Text(title).font(.headline)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let live, live.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(String(format: "%d:%02d",
                                Int(context.date.timeIntervalSince(live.startedAt)) / 60,
                                Int(context.date.timeIntervalSince(live.startedAt)) % 60))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let onStop {
                    Button(L("Stop"), action: onStop).controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            WaveMark(height: 34).opacity(0.5)
            Text(live != nil ? L("Waiting for speech…") : L("This transcript is empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var turnsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(MeetingArchive.turns(entries)) { turn in
                        TurnView(turn: turn,
                                 color: color(for: turn.speaker, isYou: turn.isYou),
                                 onRename: onRename)
                    }
                    if let text = live?.livePreview {
                        currentLine(text)
                    } else if live?.listeningFor != nil {
                        listeningLine
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: entries.count) { _ in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: live?.livePreview) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
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

    /// Speakers keep a stable colour within one transcript: the user is
    /// always the brand indigo, the others take the palette in the order
    /// they first speak.
    private func color(for speaker: String, isYou: Bool) -> Color {
        if isYou { return Brand.indigoLabel }
        let others = entries.filter { !$0.isYou }.map(\.speaker)
        var seen = Set<String>(), ordered: [String] = []
        for name in others where seen.insert(name).inserted { ordered.append(name) }
        // Label-tuned brand colours first, then system hues that adapt to
        // both appearances on their own.
        let palette: [Color] = [Brand.cyanLabel, .purple, .teal, .orange, .pink]
        let index = ordered.firstIndex(of: speaker) ?? 0
        return palette[index % palette.count]
    }
}

/// One speaker's uninterrupted turn.
private struct TurnView: View {
    let turn: TranscriptTurn
    let color: Color
    let onRename: (String, String) -> Void

    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Button {
                    draft = turn.speaker
                    renaming = true
                } label: {
                    Text(turn.speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                }
                .buttonStyle(.plain)
                .help(L("Rename this speaker"))
                .popover(isPresented: $renaming, arrowEdge: .bottom) {
                    renamePopover
                }
                Text(turn.time)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Text(turn.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Name this speaker")).font(.caption).foregroundStyle(.secondary)
            TextField(L("Name"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button(L("Cancel")) { renaming = false }
                Button(L("Save"), action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func commit() {
        renaming = false
        onRename(turn.speaker, draft)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

/// Five brand bars dancing with the live level — flat when silent, alive
/// when anyone speaks. The window's proof of hearing.
private struct LevelWave: View {
    let level: Double
    private static let profile: [Double] = [0.36, 0.64, 1.0, 0.64, 0.36]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Brand.cyan)
                    .frame(width: 3, height: 4 + 12 * level * Self.profile[i])
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Recording indicator: a red dot with a slow, calm pulse.
private struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.45)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
