import SwiftUI

/// The live meeting transcript window: the same lines the file gets, as they
/// arrive. Deliberately quiet — a reading surface, not a dashboard: a red
/// dot + elapsed time say "recording", the entries speak for themselves, and
/// one small Stop button ends the session without hunting for the menu bar.
struct MeetingTranscriptView: View {
    @ObservedObject var session: MeetingSession
    /// Subviews using L() must observe the localization (language-change
    /// pitfall — see GRABLI).
    @ObservedObject private var loc = Localization.shared
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.displayEntries.isEmpty && session.inflightCount == 0 {
                emptyState
            } else {
                entryList
            }
        }
        .frame(minWidth: 320, minHeight: 260)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if session.isActive {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if session.inflightCount > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(L("Recognizing…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if session.isActive {
                Button(L("Stop"), action: onStop)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            WaveMark()
                .frame(width: 34, height: 22)
                .opacity(0.5)
            Text(L("Waiting for speech…"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.displayEntries) { entry in
                        row(entry)
                    }
                    currentLine
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: session.displayEntries.count) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.livePreview) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// The utterance still being spoken: the live Whisper hypothesis in
    /// gray italic (the same "volatile text" idea as the dictation pill),
    /// or a quiet "Listening…" while the first decode is under way. Without
    /// this row, accumulating a long phrase looked like a hang — the
    /// owner's first field complaint.
    @ViewBuilder
    private var currentLine: some View {
        if let text = session.livePreview {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Color.red).frame(width: 5, height: 5)
                    .padding(.top, 5)
                Text(text)
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if session.listeningFor != nil {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 5, height: 5)
                Text(L("Listening…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: MeetingSession.DisplayEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.time)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.isYou ? Brand.indigo : Brand.cyan)
                Text(entry.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func elapsed(at date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(session.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
