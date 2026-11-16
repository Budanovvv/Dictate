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

    /// The notes for a version. Every shipped version has some: the
    /// "What's new" buttons in Settings and the corner menu always open
    /// this sheet, so a version without notes shows an empty one —
    /// WhatsNewTests holds the release to it, and release.sh refuses to
    /// build a DMG for a version that has none. Written when the version
    /// is raised, in the tone of the ones below: three or four items, a
    /// title and one line each, said from the reader's side.
    static func items(for version: String) -> [Item] {
        switch version {
        // Its own notes: someone arriving from 3.3.5 has seen 3.3.4's. Both
        // items are the microphone being held by a call — once by a call
        // that makes the first attach slow, once by a call in another app
        // that muffles what reaches Dictate — so they are told as what the
        // pill now says, the thing a person will actually notice.
        case "3.3.6":
            return [
                Item(title: L("The first words of a dictation during a call"),
                     line: L("While a call has the microphone, the first seconds of a dictation could be lost. The microphone is now made ready as soon as a call starts, and until it is really recording the pill, the meetings window and the recording control say “Turning on the microphone…”.")),
                Item(title: L("When another app muffles the microphone"),
                     line: L("A call left open in another app — a browser tab still in a meeting after you took your headphones off — can muffle the microphone for everyone else. The pill now names that app instead of sitting still, and Dictate no longer gets stuck turning the microphone on.")),
            ]
        // A maintenance release, told the 3.3.2 way: anyone arriving from
        // 3.3.3 or earlier has not seen 3.3.4's notes yet, and the one fix —
        // a core left spinning after the text model was put away — is a
        // line, not a feature.
        case "3.3.5":
            return items(for: "3.3.4") + [
                Item(title: L("Quiet after a summary"),
                     line: L("After a summary or report was written on this Mac, Dictate could keep a whole processor core busy until it was quit, warming the Mac and draining the battery. It now goes quiet as soon as the model is put away.")),
            ]
        // Three repairs to one story — the app noticing a call — so they are
        // told as three, not folded into "Small fixes". Two of them are
        // silences a person could never have reported precisely: a card that
        // did not come, and a refusal that carried further than it was meant to.
        // The fourth is the meetings window over a full-screen app, where ⋯
        // and Export… did nothing and opening it threw you to another screen.
        case "3.3.4":
            return [
                Item(title: L("The second call is announced too"),
                     line: L("When one meeting ran straight into the next and the browser never released the microphone, the card for the second call never appeared. Each call is now recognised on its own.")),
                Item(title: L("“Not this one” means only this one"),
                     line: L("Declining a call used to silence every call that followed it. It now declines just the one it was shown for.")),
                Item(title: L("A meeting called “Daily” still counts"),
                     line: L("A calendar event named only for its genre — Daily, Sync, Meeting — is recognised as the call being recorded. Its tag and platform reach the transcript, while the name still comes from what was said.")),
                Item(title: L("Works over full-screen apps"),
                     line: L("With Meetings open over a full-screen app, the ⋯ menu and Export… appear right there instead of on another desktop, and opening Meetings brings the window to the screen you are on rather than taking you to it.")),
            ]
        // Its own notes, not 3.3.2's plus one: inheriting once more would
        // show a person who updated from 3.3.2 the same four 3.3.1 items a
        // second time, and two "Small fixes" would share one id.
        case "3.3.3":
            return [
                Item(title: L("Templates in every language"),
                     line: L("In Russian and Ukrainian, Settings › Templates could quit the app or show garbled counts under a template. It opens and reads correctly again, as does the PDF count in About › Storage.")),
                Item(title: L("Written again means replaced"),
                     line: L("Writing a report from a template that was deleted and made again under the same name now replaces the report on the meeting’s card instead of adding a second one. A card that already carries two keeps one the next time it is written.")),
                Item(title: L("Settings read from the left"),
                     line: L("Text in every settings row starts at the left edge. The field names and instructions in the template editor no longer sit against the right.")),
            ]
        // A maintenance release writes no showcase of its own: nobody
        // arriving here from 3.3 or earlier has seen 3.3.1's notes yet, and
        // what 3.3.2 actually changed is a line of fixes rather than a
        // feature to open the app for.
        case "3.3.2":
            return items(for: "3.3.1") + [
                Item(title: L("Small fixes"),
                     line: L("The recording control can be dragged where you want it and no longer covers what it does not draw, and the list of meetings stays put while a call records.")),
            ]
        case "3.3.1":
            return [
                Item(title: L("Settings in six panes"),
                     line: L("Dictation, Meetings, Summaries & reports, Templates, General, About. Every setting sits in the pane that owns it, and every link from the app lands on the right row.")),
                Item(title: L("Reports where you read"),
                     line: L("A meeting’s reports are rows on its card, collapsed until you open one, with Copy and Export…. Library › Reports collects them by template and writes for a selection.")),
                Item(title: L("Recent dictations that insert"),
                     line: L("The menu bar keeps your last ten dictations. Click one to insert it where the cursor is; ⌥-click copies it instead.")),
                Item(title: L("Answers you can quote"),
                     line: L("Copy with quotes puts the agent’s answer on the clipboard with the transcript lines it drew from, as Markdown or plain text.")),
            ]
        case "3.3":
            return [
                Item(title: L("Reports from templates"),
                     line: L("Open a meeting and press Write report in its header, then pick a template. The report lands on the meeting’s card and travels with its transcript.")),
                Item(title: L("Your own templates"),
                     line: L("Settings › Templates: start from Meeting summary or Decisions & actions, or name your own fields and tell the model what goes under each.")),
                Item(title: L("Summaries in your language"),
                     line: L("Settings › Summaries & reports › Written in: the summary line and every report come in the language you read, whatever language the call was in.")),
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
