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
}
