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

    /// Recording microphone: "" — built-in (recommended: no Bluetooth
    /// negotiation delays, no HFP quality drop), "system" — follow the
    /// system default input, otherwise a specific device UID.
    var micUID: String {
        get { d.string(forKey: "micUID") ?? "" }
        set { d.set(newValue, forKey: "micUID") }
    }

    /// Transcription hint: names, terms, jargon.
    var prompt: String {
        get { d.string(forKey: "prompt") ?? "" }
        set { d.set(newValue, forKey: "prompt") }
    }

    /// Remove filler words ("э-э", "um") from the result. Off by default —
    /// cleanup is opt-in, the raw text is the honest default.
    var removeFillers: Bool {
        get { d.bool(forKey: "removeFillers") }
        set { d.set(newValue, forKey: "removeFillers") }
    }

    /// User dictionary: [heard phrase, exact output] pairs applied to the
    /// recognized text. Spoken punctuation/line-break commands are built in
    /// (Replacements.commands), not stored here.
    var replacements: [[String]] {
        get { d.array(forKey: "replacements") as? [[String]] ?? [] }
        set { d.set(newValue, forKey: "replacements") }
    }

    /// Hands-free: end the recording automatically after a pause, instead of
    /// requiring the key held the whole time. Off by default — push-to-talk is
    /// the predictable default; this changes the interaction model.
    var autoStopOnSilence: Bool {
        get { d.bool(forKey: "autoStopOnSilence") }
        set { d.set(newValue, forKey: "autoStopOnSilence") }
    }

    /// Seconds of silence that end a hands-free recording. Clamped to a sane
    /// range so a stray value can't make it fire instantly or never.
    var autoStopSilenceSeconds: Double {
        get {
            let v = d.object(forKey: "autoStopSilenceSeconds") as? Double ?? 1.5
            return min(5, max(0.6, v))
        }
        set { d.set(newValue, forKey: "autoStopSilenceSeconds") }
    }

    /// Pre-roll: keep the last moment of audio buffered so speech started a
    /// hair before the key is pressed isn't clipped. OFF by default and gated
    /// behind this switch because it keeps the microphone open continuously —
    /// the macOS privacy indicator stays lit and it uses a little more power.
    var prerollEnabled: Bool {
        get { d.bool(forKey: "prerollEnabled") }
        set { d.set(newValue, forKey: "prerollEnabled") }
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
    /// over the growing buffer). Costs some battery — can be turned off.
    var livePreview: Bool {
        get { d.object(forKey: "livePreview") as? Bool ?? true }
        set { d.set(newValue, forKey: "livePreview") }
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
