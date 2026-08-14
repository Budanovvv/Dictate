import AppKit
import Foundation
import SwiftUI

/// Two rules the transcript window lives by, kept pure so they can be pinned
/// by tests: what a copied turn looks like once it leaves the app, and when a
/// live transcript is allowed to scroll itself. The first is the only artefact
/// the user carries out of here by hand; the second decides whether the line
/// they are selecting stays under the pointer or is yanked away by the next
/// recognized phrase.
enum TranscriptCopy {

    /// The spoken words alone — what goes into a chat message or a task.
    static func text(of turn: TranscriptTurn) -> String {
        turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `[09:18:26] Speaker 1: …` — the same shape the transcript files use, so
    /// a quoted turn still looks like the transcript it came from and stays
    /// attributable after it is pasted somewhere else.
    static func attributed(_ turn: TranscriptTurn) -> String {
        "[\(turn.time)] \(turn.speaker): \(text(of: turn))"
    }

    /// The whole transcript as it is READ: one paragraph per turn, blank line
    /// between them, each stamped with the moment that turn began.
    ///
    /// It used to be one line per entry, exactly as the .md file has it — and
    /// that is precisely what made a pasted transcript unusable. An entry is
    /// not an utterance, it is a fifteen-second audio window: pasting one line
    /// per window into a document reproduces the ticker tape, complete with
    /// sentences cut in half by the cap and lines that are a lone full stop.
    /// The file on disk keeps every one of those (it is the record); what
    /// leaves on the clipboard is the conversation (TranscriptCleanup).
    static func transcript(_ entries: [TranscriptEntry]) -> String {
        MeetingArchive.readable(entries)
            .map(attributed)
            .joined(separator: "\n\n")
    }

    /// Puts text on the general pasteboard, reporting whether there was
    /// anything to put there (an empty transcript must not silently wipe the
    /// user's clipboard). This is a plain, deliberate copy: unlike a dictation
    /// paste, nothing here borrows the clipboard and hands it back later
    /// (GRABLI, "Буфер обмена") — the transcript window is not in the paste
    /// path at all.
    @discardableResult
    static func put(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The geometry of the per-turn copy control. These are rules, not taste: the
/// first build shipped an 11pt glyph inline after the timestamp, and it was
/// reported as "appears in the wrong place and cannot be hit" — the target was
/// a third of a comfortable one and its x position moved with every speaker
/// name and every window width. Keeping the numbers here means the tests can
/// hold the invariants that made it unclickable.
enum TurnCopy {
    /// The clickable square. 28pt is the smallest target that reliably takes a
    /// click on the first try; the glyph inside is much smaller, and that is
    /// the point — most of this square is invisible padding.
    static let targetSize: CGFloat = 28

    /// The drawn chip inside the target — smaller, so the button reads as a
    /// small affordance and not as a slab.
    static let chipSize: CGFloat = 22

    /// The column reserved at the turn's trailing edge for the control. The
    /// turn's own content stops here, at every window width, so the chip can
    /// never land on a word or on the speaker's name-button, and never has to
    /// move out of their way.
    static let gutter: CGFloat = 34

    /// The chip is never fully transparent, only faint. Two reasons, both
    /// learned the hard way: a control at opacity 0 still takes clicks in
    /// SwiftUI (an invisible thing swallowing clicks is worse than a visible
    /// one), and a chip that is always on screen cannot become a moving target
    /// the pointer chases — nor does it depend on hover detection working.
    ///
    /// It is faint rather than merely soft because there is one per turn at the
    /// same x: at 0.25 the repetition read as a grey column ruled down the
    /// right edge of the transcript, which is the thing the eye saw first. The
    /// hovered chip goes to full strength, so the affordance is not weaker —
    /// only the twenty chips the user is not pointing at are.
    ///
    /// And it is weighted PER APPEARANCE, because one number cannot mean the
    /// same thing in both. The chip used to be one opacity over the secondary
    /// label colour, and measured on the rendered window that came out at ~6%
    /// contrast against white (darkest pixel 0.940) while the identical value
    /// light-on-dark read clearly — dark ink on a bright page loses far more to
    /// the eye than bright ink on a dark one. The result was a control that was
    /// perfectly findable in the dark appearance and all but invisible in the
    /// light one, which is the appearance most people read a transcript in.
    ///
    /// So the resting chip is drawn with its own ink at its own alpha in each
    /// appearance, chosen so the two read alike: heavier on white, lighter on
    /// black. Hover still takes it to full strength, and the geometry — the
    /// 28pt target, the 22pt chip, the reserved gutter — is untouched.
    ///
    /// The numbers are bounded on both sides by things already learned here.
    /// The old single value came out at 0.05 effective in both appearances:
    /// 6% against white, which is the invisibility being fixed. Twice that —
    /// 0.125 effective — is what once read as "a grey column ruled down the
    /// right edge". So light sits between them at 0.11, and dark takes 0.06,
    /// because the same step is worth about twice as much to the eye on a dark
    /// page: measured in L*, white ink at 0.06 on the dark transcript is the
    /// same distance from its background as black ink at 0.11 is from white.
    static func restingAlpha(dark: Bool) -> Double { dark ? 0.06 : 0.11 }

    /// The resting chip's ink. Built as an appearance-aware NSColor rather than
    /// read from the SwiftUI environment on purpose: the turns are `.equatable()`
    /// rows in a scrolling list, and a colour that resolves itself at draw time
    /// keeps them out of the comparison entirely (same trick as Brand.indigoLabel).
    static let restingInk = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black)
            .withAlphaComponent(restingAlpha(dark: dark))
    })

    /// What is left of a turn's width for the speaker row and the words.
    static func contentWidth(inTurnWidth width: CGFloat) -> CGFloat {
        max(0, width - gutter)
    }

    /// True while the copy target cannot touch the turn's content — the check
    /// behind "the copy button and the rename button can never overlap",
    /// including a narrow panel and a very long speaker name.
    static func targetIsClear(ofTurnWidth width: CGFloat) -> Bool {
        contentWidth(inTurnWidth: width) + targetSize <= width
    }
}

/// When a live transcript may scroll itself to the newest line.
enum TranscriptScroll {
    /// How far from the bottom still counts as "at the bottom". A couple of
    /// points of rubber-banding or a half-rendered last line must not read as
    /// "the user scrolled up"; a deliberate scroll of even one line must.
    static let pinSlack: CGFloat = 24

    /// True while the newest line is on screen. Auto-scroll is armed only
    /// then: once the user has scrolled up they are reading something they
    /// chose, and dragging the list back down under them is exactly how a
    /// selection gets torn away mid-drag.
    static func isPinned(contentOffsetY: CGFloat,
                         containerHeight: CGFloat,
                         contentHeight: CGFloat,
                         bottomInset: CGFloat = 0,
                         slack: CGFloat = pinSlack) -> Bool {
        // A transcript shorter than its window has nothing to scroll: it is
        // pinned by definition, and must never be reported as "scrolled up"
        // (a bounce can report an offset outside the content entirely).
        guard contentHeight > containerHeight else { return true }
        return contentOffsetY + containerHeight + slack >= contentHeight + bottomInset
    }

    /// Above this many entries the jump to the newest line stops being
    /// animated: an animated scroll walks the layout of everything in between,
    /// and a real meeting is a few hundred lines arriving one per second. The
    /// animation is a nicety; a stutter on every new line is not.
    static let animationLimit = 80

    static func animates(entryCount: Int) -> Bool { entryCount <= animationLimit }
}
