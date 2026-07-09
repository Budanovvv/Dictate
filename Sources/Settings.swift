import Foundation

/// App settings, backed by UserDefaults.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var onboardingDone: Bool {
        get { d.bool(forKey: "onboardingDone") }
        set { d.set(newValue, forKey: "onboardingDone") }
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
