import Foundation

/// The meeting capabilities — four independent, opt-in switches — and the
/// ONE place their words live (design turn 25: one canonical string set per
/// capability). Every surface that mentions a capability — the Settings
/// pane, the first-run rows, the offer card, the absence strip — renders
/// these strings rather than writing its own: a surface with private
/// wording is how one feature ends up described three different ways.
enum MeetingCapability: String, CaseIterable {
    case noticeCalls, recordCallAudio, separateVoices, readMeetings

    /// The switch's name, verbatim on every surface.
    var name: String {
        switch self {
        case .noticeCalls:     return L("Notice when a call starts")
        case .recordCallAudio: return L("Record the call audio too")
        case .separateVoices:  return L("Separate the voices")
        // One capability with two consequences — the summary AND the agent
        // (design turn 24) — so it is named by what it IS, not by one of
        // the two things it produces.
        case .readMeetings:    return L("Let the model read your meetings")
        }
    }

    /// What turning it on adds — the why-text under the switch.
    var adds: String {
        switch self {
        case .noticeCalls:
            return L("With this on, a small panel appears when a call starts and you decide there — no need to remember to start anything.")
        case .recordCallAudio:
            return L("Off, you get only your own microphone — your half of the conversation. On, the other side is transcribed as well.")
        case .separateVoices:
            return L("Turns one block of text into named turns, so you can see who committed to what. Names are yours to set and can be changed after the fact.")
        case .readMeetings:
            return L("This is what writes the summary and the outline, and what gives your agent something to answer from. Off, you get the raw transcript — no summary, no outline, and no agent. Nothing is sent anywhere either way.")
        }
    }

    var isOn: Bool {
        get {
            switch self {
            case .noticeCalls:     return Settings.shared.noticeCalls
            case .recordCallAudio: return Settings.shared.recordCallAudio
            case .separateVoices:  return Settings.shared.separateVoices
            case .readMeetings:    return Settings.shared.readMeetings
            }
        }
        nonmutating set {
            switch self {
            case .noticeCalls:     Settings.shared.noticeCalls = newValue
            case .recordCallAudio: Settings.shared.recordCallAudio = newValue
            case .separateVoices:  Settings.shared.separateVoices = newValue
            case .readMeetings:    Settings.shared.readMeetings = newValue
            }
        }
    }

    /// The one way a SURFACE turns a capability on: the switch flips and
    /// the ledger records a human decision in the same breath — the two
    /// lines were hand-paired at ten call sites before this existed.
    func turnOnByHand() {
        isOn = true
        OfferLedger.decided(self)
    }

    static func turnAllOnByHand() {
        allCases.forEach { $0.turnOnByHand() }
    }

    /// Voice separation is meaningless without the call audio it separates
    /// — rendered nested and dimmed under its parent, never as a peer
    /// (design section 9: needs another switch first).
    var parent: MeetingCapability? {
        self == .separateVoices ? .recordCallAudio : nil
    }

    // The first-run pane groups audio and voices into one decision (settled
    // with the designer, 2026-08-31) — the combined row's words are
    // canonical too, held here rather than written by the pane.
    static var audioAndVoicesName: String {
        L("Record the call audio, and separate the voices")
    }
    static var audioAndVoicesAdds: String {
        L("Off, a recording holds your microphone only — your half of the conversation, in one unbroken block. On, both sides are transcribed as named turns.")
    }

    /// The offer card's body for the one capability that is ever offered —
    /// recording calls (shown when a call is detected with recording off).
    static var recordOfferBody: String {
        L("Call recording is off, so this one is passing untranscribed. Turning it on gives you a searchable transcript and a summary afterwards, kept on this Mac.")
    }

    // The absence strip's sentences (design section 9, Q4: one combined
    // strip, the missing things in one sentence ordered by consequence).
    // Whole sentences rather than fragments composed at runtime: eleven
    // languages do not share a grammar, and a sentence stitched from
    // fragments would read like one.
    static var absenceMicOnly: String {
        L("This is your microphone only — the other side of the call is missing, the text is one unbroken block, and there is no summary or outline.")
    }
    static var absenceMicOnlySub: String {
        L("Writing one now reads only this transcript and leaves the switches off. The other side of this call was not recorded and cannot be recovered.")
    }
    static var absenceNoSummary: String {
        L("There is no summary or outline — reading your meetings is off.")
    }
    static var absenceNoSummarySub: String {
        L("Turning it on also writes them for the recordings that come next. Writing one now leaves the switch off.")
    }

    /// The list column's note while calls go unnoticed — the noticing
    /// capability's own absence, worded once.
    static var callsUnnoticedNote: String {
        L("Calls are not noticed automatically. You can start each one here, or let Dictate offer when a call begins.")
    }
}

/// The offers' central ceiling (design section 9; designer's Q3 answer,
/// 2026-08-31). Only HUD offer cards count toward it: a card shown and
/// IGNORED — the call ended with no answer — spends one of the two
/// lifetime mentions; an explicit decline retires the offer immediately,
/// so the ceiling only ever governs ignored cards. The first-run rows and
/// the absence strip never count — they describe, they don't ask.
///
/// An offer is for "not set up yet", never for "turned off on purpose":
/// a capability the person has toggled BY HAND anywhere (Settings, the
/// first-run pane, a strip's button) is decided, and a decided capability
/// is not offered again.
enum OfferLedger {
    /// Swappable so the tests run against their own suite, not the app's.
    static var defaults: UserDefaults = .standard

    static func mayOffer(_ capability: MeetingCapability) -> Bool {
        !capability.isOn
            && !defaults.bool(forKey: key(capability, "retired"))
            && !defaults.bool(forKey: key(capability, "decided"))
            && defaults.integer(forKey: key(capability, "ignored")) < 2
    }

    /// A card was shown and the call ended before anyone answered.
    static func shownIgnored(_ capability: MeetingCapability) {
        let count = defaults.integer(forKey: key(capability, "ignored")) + 1
        defaults.set(count, forKey: key(capability, "ignored"))
        Log.d("offer: \(capability.rawValue) ignored (\(count)/2)")
    }

    /// "Not now" or "Don't offer this again" — either one is an answer,
    /// and an answered offer never returns.
    static func declined(_ capability: MeetingCapability) {
        defaults.set(true, forKey: key(capability, "retired"))
        Log.d("offer: \(capability.rawValue) declined — retired")
    }

    /// The person flipped this switch themselves, in either direction.
    static func decided(_ capability: MeetingCapability) {
        defaults.set(true, forKey: key(capability, "decided"))
    }

    private static func key(_ capability: MeetingCapability, _ field: String) -> String {
        "offer.\(capability.rawValue).\(field)"
    }
}
