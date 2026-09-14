import SwiftUI

/// What changed, told once per version and only for versions with
/// something to see. Updates install silently (Sparkle), so this is the
/// one place a person learns the app grew — a strip in the meetings window
/// the first time it opens after the update, a short sheet behind it, and
/// a "New" mark on the control itself until the sheet has been seen. Never
/// a window at launch: the app starts at login, in the menu bar, and a
/// window then is the interruption this app exists to avoid.
///
/// The notes are the release notes — written once per release, here, in
/// the same words the appcast carries.
enum WhatsNew {
    struct Item: Identifiable {
        let title: String
        let line: String
        var id: String { title }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The notes for a version — empty for a version with nothing to say,
    /// which is most patches.
    static func items(for version: String) -> [Item] {
        switch version {
        case "3.3":
            return [
                Item(title: L("Reports from templates"),
                     line: L("Open a meeting and press Write report in its header, then pick a template. The report lands on the card and as a PDF in Dictate Meetings › Reports.")),
                Item(title: L("Your own templates"),
                     line: L("Settings › Templates: start from Meeting summary or Decisions & actions, or name your own fields and tell the model what goes under each.")),
                Item(title: L("Summaries in your language"),
                     line: L("Settings › Meetings › Write summaries and reports in: the summary line and every report come in the language you read, whatever language the call was in.")),
            ]
        default:
            return []
        }
    }

    static var currentItems: [Item] { items(for: currentVersion) }

    /// Whether this version's notes are still unseen — what shows the strip
    /// and the "New" marks.
    static var pending: Bool {
        !currentItems.isEmpty && Settings.shared.whatsNewShownVersion != currentVersion
    }

    static func markSeen() {
        Settings.shared.whatsNewShownVersion = currentVersion
    }
}

/// The sheet: the version, three items, one button.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Lf("What’s new in Dictate %@", WhatsNew.currentVersion))
                .font(.system(size: 15, weight: .semibold))
            ForEach(WhatsNew.currentItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13, weight: .semibold))
                    Text(item.line)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(L("Got it")) {
                    WhatsNew.markSeen()
                    dismiss()
                }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 440)
        .onDisappear { WhatsNew.markSeen() }
    }
}

/// The small "New" mark beside a control that arrived with this version,
/// worn until the notes have been seen.
struct NewBadge: View {
    var body: some View {
        Text(L("New"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DS.accentText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(DS.accentText.opacity(0.12)))
            // Its own width: in a header cluster the word was squeezed to
            // a sliver.
            .fixedSize()
            .accessibilityLabel(L("New in this version"))
    }
}
