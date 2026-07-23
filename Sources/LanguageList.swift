import Foundation
import WhisperKit

/// Languages supported by Whisper, with localized names (for pickers).
enum LanguageList {
    static let options: [(code: String, name: String)] = {
        Array(Constants.languageCodes).map { code -> (String, String) in
            let name = Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
            return (code, name)
        }
        .sorted { $0.name < $1.name }
    }()

    /// The system language if Whisper supports it, otherwise "en".
    static var systemDefaultCode: String {
        let code = Locale.preferredLanguages.first?
            .split(separator: "-").first.map(String.init) ?? "en"
        return Constants.languageCodes.contains(code) ? code : "en"
    }

    static func name(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    /// A language's OWN native name (endonym): ask that language's locale to name
    /// itself — Locale(identifier: "de").localizedString(forLanguageCode: "de") =
    /// "Deutsch", "ja" = "日本語". Users scan for their language in its own script,
    /// so the endonym is the primary label in the picker (research-backed).
    /// Uppercases only the first character (leaves non-Latin scripts untouched).
    static func endonym(for code: String) -> String {
        let raw = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
        guard let first = raw.first else { return code.uppercased() }
        return first.uppercased() + raw.dropFirst()
    }

    /// (code, native endonym, English exonym) for every supported language,
    /// sorted by the native name. The English name is kept for the search index
    /// and an optional dimmed secondary label.
    static let display: [(code: String, native: String, english: String)] = {
        Array(Constants.languageCodes)
            .map { (code: $0, native: endonym(for: $0), english: name(for: $0)) }
            .sorted { $0.native.localizedCaseInsensitiveCompare($1.native) == .orderedAscending }
    }()
}
