import Foundation

/// Output-side sanity checks for the LLM polish pass. Separate from
/// PolishEngine so the unit tests can compile them without the LLM package.
enum PolishGuard {

    /// True when `from` is written mostly in a non-Latin script but `to` came
    /// back Latin — the signature of the model TRANSLATING the dictation into
    /// English instead of editing it (caught live on Russian, 2026-07-25; the
    /// prompt's «Keep the language» does not reliably prevent it). An edit
    /// preserves the writing system; a translation does not. Latin covers the
    /// extended ranges too, so Vietnamese diacritics or the odd accented name
    /// never count as "non-Latin".
    static func scriptFlipped(from input: String, to output: String) -> Bool {
        func nonLatinShare(_ s: String) -> Double {
            var letters = 0, nonLatin = 0
            for scalar in s.unicodeScalars where scalar.properties.isAlphabetic {
                letters += 1
                let latin = scalar.isASCII
                    || (0x00C0...0x024F).contains(scalar.value)   // Latin-1 Sup + Ext-A/B
                    || (0x1E00...0x1EFF).contains(scalar.value)   // Ext Additional (Vietnamese)
                if !latin { nonLatin += 1 }
            }
            return letters == 0 ? 0 : Double(nonLatin) / Double(letters)
        }
        return nonLatinShare(input) > 0.5 && nonLatinShare(output) < 0.2
    }
}
