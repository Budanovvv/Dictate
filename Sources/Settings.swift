import Foundation

/// App settings, backed by UserDefaults.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var onboardingDone: Bool {
        get { d.bool(forKey: "onboardingDone") }
        set { d.set(newValue, forKey: "onboardingDone") }
    }

    /// Whether we've applied the "launch at login on by default" one-time
    /// registration. Set the first time the app runs so we never re-enable it
    /// after the user has turned it off themselves.
    var didSetLoginItemDefault: Bool {
        get { d.bool(forKey: "didSetLoginItemDefault") }
        set { d.set(newValue, forKey: "didSetLoginItemDefault") }
    }

    /// Virtual keycode of the hold-to-talk key (default 61 — right Option)
    var hotkeyKeyCode: Int {
        get { d.object(forKey: "hotkeyKeyCode") as? Int ?? 61 }
        set { d.set(newValue, forKey: "hotkeyKeyCode") }
    }

    /// Stored in English; localized for display via KeyNames.displayName.
    var hotkeyName: String {
        get { d.string(forKey: "hotkeyName") ?? "Right Option (⌥)" }
        set { d.set(newValue, forKey: "hotkeyName") }
    }

    /// Transcription language code; "" = auto-detect. Defaults to the system language.
    var language: String {
        get { d.string(forKey: "language") ?? LanguageList.systemDefaultCode }
        set { d.set(newValue, forKey: "language") }
    }

    /// Translate-to-English key, held instead of the main one (nil = disabled).
    var translateKeyCode: Int? {
        get { d.object(forKey: "translateKeyCode") as? Int }
        set {
            if let v = newValue { d.set(v, forKey: "translateKeyCode") }
            else { d.removeObject(forKey: "translateKeyCode") }
        }
    }

    var translateKeyName: String {
        get { d.string(forKey: "translateKeyName") ?? "" }
        set { d.set(newValue, forKey: "translateKeyName") }
    }

    /// Recording microphone: "" — built-in (the default: no Bluetooth
    /// negotiation delays, no HFP quality drop), "system" — follow the
    /// system default input, otherwise a specific device UID.
    /// Hidden, no UI: picking a mic is not a decision we ask for — the
    /// built-in one is deliberately forced (anti-Bluetooth fix). Still
    /// readable/writable via `defaults` if someone really needs another input.
    var micUID: String {
        get { d.string(forKey: "micUID") ?? "" }
        set { d.set(newValue, forKey: "micUID") }
    }

    // Retired settings (owner's call, 2026-08-27), keys cleaned up at startup
    // by AppDelegate.removeRetiredTextKnobs:
    // - "prompt" (vocabulary hint): a proven footgun — foreign text in it
    //   silently emptied recognitions, and it once swallowed a live dictation
    //   typed into its own settings field;
    // - "replacements" (user rules) and "removeFillers": the filler cleanup
    //   and built-in voice commands still run as fixed behavior — they are how
    //   dictation works, not something to configure.

    // MARK: Translate-tip bookkeeping (see AppDelegate.maybeShowTranslateTip)

    /// Successful real dictations (onboarding try-outs excluded).
    var dictationCount: Int {
        get { d.integer(forKey: "dictationCount") }
        set { d.set(newValue, forKey: "dictationCount") }
    }

    /// Name scheduled meetings from the calendar instead of from the model.
    /// Off until asked for: turning it on is what triggers the macOS calendar
    /// prompt, and this app already spends three permissions before it works
    /// at all (see MeetingCalendar for why it is not in onboarding).
    var nameMeetingsFromCalendar: Bool {
        get { d.bool(forKey: "nameMeetingsFromCalendar") }
        set { d.set(newValue, forKey: "nameMeetingsFromCalendar") }
    }

    /// How finely meetings are cut into sections — the reader's own call.
    ///
    /// Worth a control because the evidence says so: across the segmentation
    /// literature the NUMBER of sections dominates their placement, so letting
    /// somebody choose the count buys more than any better boundary-finder
    /// would. Defaults to the middle, which is where it has always been.
    var sectionDetail: MeetingPolicy.SectionDetail {
        get { MeetingPolicy.SectionDetail(rawValue: d.integer(forKey: "sectionDetail")) ?? .standard }
        set { d.set(newValue.rawValue, forKey: "sectionDetail") }
    }

    /// Who answers questions about the archive — or nobody, which is the
    /// default.
    ///
    /// nil means off, and it is the only setting in this app that turns
    /// something OUTWARD. Everything else Dictate does happens on this Mac, and
    /// a feature that breaks that promise cannot have its consent be a side
    /// effect of a credential pasted once, months ago. The picker is the
    /// consent, it is visible, and setting it to Off stops the offer appearing
    /// at all — not merely greys it out.
    ///
    /// This was a plain on/off toggle before there was a second provider —
    /// the old boolean is read once as a migration so nobody's choice is lost.
    var askProvider: AIProvider? {
        get {
            if let raw = d.string(forKey: "askProvider") { return AIProvider(rawValue: raw) }
            return d.bool(forKey: "askArchive") ? .anthropic : nil
        }
        set { d.set(newValue?.rawValue ?? "off", forKey: "askProvider") }
    }

    /// Whether asking is on at all — what the meetings window checks before
    /// offering the ask row; it does not care with whom.
    var askArchive: Bool { askProvider != nil }

    var meetingConsentSeen: Bool {
        get { d.bool(forKey: "meetingConsentSeen") }
        set { d.set(newValue, forKey: "meetingConsentSeen") }
    }

    /// The pill's one-time "closing the window does not stop the recording"
    /// line has been shown.
    var meetingPillNoticeSeen: Bool {
        get { d.bool(forKey: "meetingPillNoticeSeen") }
        set { d.set(newValue, forKey: "meetingPillNoticeSeen") }
    }

    var translateUsedEver: Bool {
        get { d.bool(forKey: "translateUsedEver") }
        set { d.set(newValue, forKey: "translateUsedEver") }
    }

    /// When onboarding finished — starts the tip's one-day grace period.
    var onboardingDoneAt: Date? {
        get { d.object(forKey: "onboardingDoneAt") as? Date }
        set { d.set(newValue, forKey: "onboardingDoneAt") }
    }

    var translateTipShownAt: Date? {
        get { d.object(forKey: "translateTipShownAt") as? Date }
        set { d.set(newValue, forKey: "translateTipShownAt") }
    }

    /// 0 → never shown; capped at 2 (one showing + one reminder a week later).
    var translateTipCount: Int {
        get { d.integer(forKey: "translateTipCount") }
        set { d.set(newValue, forKey: "translateTipCount") }
    }

    /// Live transcription preview in the HUD while recording (turbo passes
    /// over the growing buffer). Always on — it is what makes the HUD feel
    /// alive. Hidden escape hatch, no UI: only `defaults write … livePreview
    /// -bool NO` turns it off, for the rare battery-sensitive case.
    var livePreview: Bool {
        get { d.object(forKey: "livePreview") as? Bool ?? true }
        set { d.set(newValue, forKey: "livePreview") }
    }

    /// Type confirmed words straight into the focused app while the user is
    /// still speaking (rides on the live-preview cycle). Off by default while
    /// the feature is being broken in — it writes into a foreign document.
    var liveTyping: Bool {
        get { d.bool(forKey: "liveTyping") }
        set { d.set(newValue, forKey: "liveTyping") }
    }

    /// The app's appearance: "system" follows macOS, "light"/"dark" hold
    /// Dictate to one look everywhere (design: Settings › General).
    var appearance: String {
        get { d.string(forKey: "appearance") ?? "system" }
        set { d.set(newValue, forKey: "appearance") }
    }

    /// The transcript's text size — small / medium / large (design
    /// MeetingOutline: the three-A tray in the head). A reading preference,
    /// so it is global: eyes do not change between meetings.
    var transcriptTextSize: String {
        get { d.string(forKey: "transcriptTextSize") ?? "medium" }
        set { d.set(newValue, forKey: "transcriptTextSize") }
    }

    /// Final insertion route (Settings › Keys, design: "Insert text by").
    /// false = paste at once (default); true = type it out through the same
    /// unicode-event route live typing uses — for apps that block paste.
    var insertByTyping: Bool {
        get { d.bool(forKey: "insertByTyping") }
        set { d.set(newValue, forKey: "insertByTyping") }
    }

    /// Target language of the translate key. Every target — English included —
    /// is a plain transcription followed by Apple's on-device Translation.
    var translateTargetCode: String {
        get { d.string(forKey: "translateTargetCode") ?? "en" }
        set { d.set(newValue, forKey: "translateTargetCode") }
    }

    /// Permanent Dock icon (on by default since the meetings portal became a
    /// real window; clicking it opens Meetings). Off returns the app to the
    /// old menu-bar-only behavior, where the icon appears only while one of
    /// our windows is open. The menu bar item is not configurable — it is the
    /// app's state indicator and warning channel, not branding.
    var showInDock: Bool {
        get { d.object(forKey: "showInDock") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInDock") }
    }
}

/// Variant name in argmaxinc/whisperkit-coreml + approximate size.
enum ModelTier: String, CaseIterable, Identifiable {
    /// Compressed large-v3-turbo: ~4× faster decode — the everyday dictation
    /// workhorse and the live-preview engine. The only tier: it cannot
    /// translate, and it no longer has to (Apple Translation does that now).
    case fast
    var id: String { rawValue }

    var variant: String { "openai_whisper-large-v3-v20240930_626MB" }

    /// One source of truth for the download size shown in HUD/onboarding/settings.
    var sizeMB: Int { 626 }

    var sizeHint: String { "~\(sizeMB) MB" }
}
