import Foundation

/// Post-processing of recognized text, two layers:
///
/// 1. Built-in voice commands (like the system dictation): five per language,
///    curated after Apple's dictation command sets. Only things Whisper can't
///    produce from intonation itself: line breaks and the rare marks. All
///    languages are active at once — the phrases are language-unique, and in
///    translate mode Whisper translates the spoken phrase into English where
///    the English set catches it.
/// 2. User dictionary: [heard phrase, exact output] pairs from Settings —
///    names, brands, acronyms ("сиквел" → "SQL"). User rules win over
///    built-ins on the same phrase. A phrase prefixed with "re:" is treated
///    as a raw case-insensitive regex (no escaping, no word-boundary wrap) —
///    one rule for a name that arrives in many spellings and inflections.
///
/// Matching is case-insensitive; word-boundary aware for alphabetic scripts,
/// bare for CJK (no spaces there). Longer phrases apply first.
enum Replacements {
    /// languageCode → [(spoken phrase, output)]. The settings showcase lists
    /// the current UI language's five; matching uses all of them.
    static let commandsByLanguage: [String: [(phrase: String, output: String)]] = [
        "en": [("new line", "\n"), ("new paragraph", "\n\n"),
               ("exclamation mark", "!"), ("question mark", "?"), ("colon", ":")],
        "ru": [("с новой строки", "\n"), ("новый абзац", "\n\n"),
               ("восклицательный знак", "!"), ("вопросительный знак", "?"), ("двоеточие", ":")],
        "uk": [("з нового рядка", "\n"), ("новий абзац", "\n\n"),
               ("знак оклику", "!"), ("знак питання", "?"), ("двокрапка", ":")],
        "es": [("nueva línea", "\n"), ("nuevo párrafo", "\n\n"),
               ("signo de exclamación", "!"), ("signo de interrogación", "?"), ("dos puntos", ":")],
        "pt": [("nova linha", "\n"), ("novo parágrafo", "\n\n"),
               ("ponto de exclamação", "!"), ("ponto de interrogação", "?"), ("dois pontos", ":")],
        "fr": [("à la ligne", "\n"), ("nouveau paragraphe", "\n\n"),
               ("point d'exclamation", "!"), ("point d'interrogation", "?"), ("deux points", ":")],
        "de": [("neue Zeile", "\n"), ("neuer Absatz", "\n\n"),
               ("Ausrufezeichen", "!"), ("Fragezeichen", "?"), ("Doppelpunkt", ":")],
        "zh": [("换行", "\n"), ("新段落", "\n\n"),
               ("感叹号", "！"), ("问号", "？"), ("冒号", "：")],
        "ja": [("改行", "\n"), ("新しい段落", "\n\n"),
               ("感嘆符", "！"), ("疑問符", "？"), ("コロン", "：")],
        "ko": [("줄 바꿈", "\n"), ("새 단락", "\n\n"),
               ("느낌표", "!"), ("물음표", "?"), ("콜론", ":")],
        "vi": [("xuống dòng", "\n"), ("đoạn mới", "\n\n"),
               ("dấu chấm than", "!"), ("dấu chấm hỏi", "?"), ("dấu hai chấm", ":")],
        "tl": [("bagong linya", "\n"), ("bagong talata", "\n\n"),
               ("tandang padamdam", "!"), ("tandang pananong", "?"), ("tutuldok", ":")],
    ]

    /// Commands for the settings showcase, in the given UI language.
    static func commands(for languageCode: String) -> [(phrase: String, output: String)] {
        commandsByLanguage[languageCode] ?? commandsByLanguage["en"]!
    }

    /// Filler words per language — deliberately conservative: only sounds
    /// that are near-never meaningful. NOT "ну"/"like"/"you know" (often
    /// carry meaning). Applied STRICTLY to the language of this dictation:
    /// fillers collide across languages ("um" is a German preposition),
    /// so unlike commands they must never be active all at once. Languages
    /// not listed simply get no cleanup yet.
    static let fillersByLanguage: [String: [String]] = [
        "ru": ["э-э-э", "э-э", "эээ", "ээ", "эм", "м-м", "мм", "гм"],
        "uk": ["е-е-е", "е-е", "еее", "ем", "м-м", "мм", "гм"],
        "en": ["um", "umm", "uh", "uhh", "uhm", "erm"],
    ]

    /// Full pipeline: optional filler cleanup (language-scoped), then user
    /// rules and voice commands, then punctuation/spacing tidy-up.
    static func process(_ text: String, rules: [[String]], fillerLanguage: String?) -> String {
        var t = text
        if let lang = fillerLanguage, let fillers = fillersByLanguage[lang] {
            for filler in fillers.sorted(by: { $0.count > $1.count }) {
                // the filler goes together with a trailing comma/period
                let p = pattern(for: filler) + #"[,.]?"#
                guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
                t = re.stringByReplacingMatches(in: t, options: [],
                                                range: NSRange(t.startIndex..., in: t),
                                                withTemplate: "")
            }
        }
        return apply(to: t, rules: rules)
    }

    static func apply(to text: String, rules: [[String]]) -> String {
        // Built-ins from every language…
        var byPhrase: [String: (String, String)] = [:]
        for set in commandsByLanguage.values {
            for (phrase, output) in set { byPhrase[phrase.lowercased()] = (phrase, output) }
        }
        // …user rules may deliberately override any of them.
        for rule in rules {
            guard rule.count == 2 else { continue }
            let phrase = rule[0].trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty else { continue }
            byPhrase[phrase.lowercased()] = (phrase, rule[1].replacingOccurrences(of: "\\n", with: "\n"))
        }
        let ordered = byPhrase.values.sorted { $0.0.count > $1.0.count }

        var result = text
        for (phrase, output) in ordered {
            // A rule may opt into a raw regex with the "re:" prefix — for names
            // that arrive in a swarm of spellings (accent, inflection) that no
            // list of literals can keep up with. The pattern author owns their
            // own boundaries; everything else stays an escaped literal.
            let rawPattern = phrase.hasPrefix("re:")
                ? String(phrase.dropFirst(3))
                : pattern(for: phrase)
            guard let re = try? NSRegularExpression(pattern: rawPattern,
                                                    options: [.caseInsensitive]) else { continue }
            // Marks inserted BY COMMAND get a sentinel: the user's explicit
            // mark must beat whatever punctuation Whisper guessed around the
            // spoken phrase ("знак. Восклицательный знак." → "знак!", not "знак.!.")
            let isMark = output.count <= 2 && output.rangeOfCharacter(from: .punctuationCharacters) != nil
                && !output.contains("\n")
            let template = isMark ? sentinel + output : output
            result = re.stringByReplacingMatches(
                in: result, options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: template)
            )
        }
        return tidy(result)
    }

    /// Private-use character — never occurs in dictated text.
    private static let sentinel = "\u{F8FF}"

    private static func pattern(for phrase: String) -> String {
        var escaped = NSRegularExpression.escapedPattern(for: phrase)
        // Whisper may use the typographic apostrophe ("point d’exclamation")
        escaped = escaped.replacingOccurrences(of: "'", with: "['’]")
        // CJK scripts have no word boundaries — match the phrase bare there.
        let cjk = phrase.unicodeScalars.contains {
            (0x3040...0x30FF).contains(Int($0.value)) || (0x4E00...0x9FFF).contains(Int($0.value))
        }
        return cjk ? escaped : "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
    }

    /// Whisper punctuates around spoken commands ("текст. С новой строки,
    /// текст") — after substitution that punctuation would dangle at line
    /// starts or float before inserted marks. Sweep it up.
    private static func tidy(_ text: String) -> String {
        var s = text
        let punct = "[,.;:!?…。，！？：]"
        // Whisper punctuation colliding with a command-inserted mark loses:
        // before the mark ("знак. ␣!" → "знак!")…
        s = s.replacingOccurrences(of: #" *\#(punct)* *"# + sentinel, with: sentinel,
                                   options: .regularExpression)
        // …and right after it ("!. Второй" → "! Второй")
        s = s.replacingOccurrences(of: sentinel + #"(.)\#(punct)+"#, with: "$1",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: sentinel, with: "")
        // stray punctuation right after an inserted line break: "\n, " → "\n"
        s = s.replacingOccurrences(of: #"\n *[,.;:!?…]+ *"#, with: "\n", options: .regularExpression)
        // no space before punctuation: "текст , текст" → "текст, текст"
        s = s.replacingOccurrences(of: #" +([,.;:!?…])"#, with: "$1", options: .regularExpression)
        // spaces hugging line breaks
        s = s.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        // double spaces left by replacements (dictated text never has them)
        s = s.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        // a removed leading filler can leave "  , text" at the very start
        s = s.replacingOccurrences(of: #"^[ ,.;:]+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
