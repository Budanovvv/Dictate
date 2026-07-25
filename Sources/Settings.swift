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

    /// Transcription hint: names, terms, jargon.
    var prompt: String {
        get { d.string(forKey: "prompt") ?? "" }
        set { d.set(newValue, forKey: "prompt") }
    }

    /// Remove filler words ("э-э", "um") from the result. On by default: the
    /// filler lists are deliberately conservative (only unambiguous hesitation
    /// sounds), so nobody has to find a switch to get clean text.
    var removeFillers: Bool {
        get { d.object(forKey: "removeFillers") as? Bool ?? true }
        set { d.set(newValue, forKey: "removeFillers") }
    }

    /// User dictionary: [heard phrase, exact output] pairs applied to the
    /// recognized text. Spoken punctuation/line-break commands are built in
    /// (Replacements.commands), not stored here.
    var replacements: [[String]] {
        get { d.array(forKey: "replacements") as? [[String]] ?? [] }
        set { d.set(newValue, forKey: "replacements") }
    }

    // MARK: Translate-tip bookkeeping (see AppDelegate.maybeShowTranslateTip)

    /// Successful real dictations (onboarding try-outs excluded).
    var dictationCount: Int {
        get { d.integer(forKey: "dictationCount") }
        set { d.set(newValue, forKey: "dictationCount") }
    }

    /// The translate key produced a result at least once (incl. onboarding) —
    /// the user knows the feature, the tip stays silent forever.
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

    /// Target language of the translate key. Every target — English included —
    /// is a plain transcription followed by Apple's on-device Translation.
    var translateTargetCode: String {
        get { d.string(forKey: "translateTargetCode") ?? "en" }
        set { d.set(newValue, forKey: "translateTargetCode") }
    }

    /// Post-process dictation with the local LLM (grammar/filler cleanup).
    /// Off by default: costs seconds of latency and ~2 GB of disk.
    var polishEnabled: Bool {
        get { d.bool(forKey: "polishEnabled") }
        set { d.set(newValue, forKey: "polishEnabled") }
    }

    /// Polish style: "clean" | "formal" | "friendly".
    var polishStyle: String {
        get { d.string(forKey: "polishStyle") ?? "clean" }
        set { d.set(newValue, forKey: "polishStyle") }
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
