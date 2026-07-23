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

    /// Single model, no tier picker — see ModelTier.
    var modelTier: ModelTier { .ultra }
}

/// Variant name in argmaxinc/whisperkit-coreml + approximate size.
enum ModelTier: String, CaseIterable, Identifiable {
    // Compressed full large-v3: unlike turbo, it supports task=translate.
    case ultra
    var id: String { rawValue }

    var variant: String { "openai_whisper-large-v3_947MB" }

    var sizeHint: String { "~950 MB" }
}
