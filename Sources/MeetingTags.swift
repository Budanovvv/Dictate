import Foundation

/// Tags on a meeting: the owner's own classification, for the axis nothing
/// else can answer.
///
/// Search already covers two axes without being asked — what was said (full
/// text) and who said it (the speakers in the file). Neither knows
/// which PRODUCT a call was about, or which engagement it belonged to. That is
/// the gap a tag fills, and the reason there is no point tagging anything the
/// archive can already work out for itself.
///
/// The design follows the one failure this class of feature reliably has, and
/// it is not laziness — it is vocabulary drift. Left as a free text field,
/// tags become "acme", "Acme Corp" and "acme-corp" within a month, and then
/// search returns a third of what it should because the rest is filed under a
/// synonym nobody thinks to look for. Serious asset systems answer that with a
/// gatekeeper who approves new terms. With one user the interface has to be the
/// gatekeeper, which is why:
///
/// * everything is normalised on the way in (lower case, hyphens, no
///   punctuation), so case and spacing can never fork a tag;
/// * completion offers what already exists, making the familiar tag the easy
///   one to type;
/// * a tag can be renamed across the whole archive, because drift happens
///   anyway and a vocabulary with no way to merge is a vocabulary that rots.
///
/// Tags live IN the transcript, as ordinary hashtags on their own line. The
/// folder has to stay useful without this app — that rule already governs the
/// title, the summary and the contents block, and a tag stored in some private
/// index would be the first piece of a meeting that only Dictate can read.
enum MeetingTags {

    /// Characters a tag may contain after normalisation. Slash is allowed on
    /// purpose: `#product/agent` is how note systems get depth without a
    /// nested-tag feature, and it costs nothing here because it is just text.
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyz0123456789-/_")

    /// One tag, as it will be stored — whatever was typed.
    ///
    /// "Acme Corp" and "acme corp" and "ACME-Corp" all land on `acme-corp`,
    /// which is the single highest-value rule in the whole feature: it removes
    /// the most common way a vocabulary forks without asking the user to think
    /// about it at all.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text = String(text.dropFirst()) }
        // Spaces and underscores become the separator; everything else that is
        // not allowed simply goes, so a typed "acme, corp." cannot smuggle
        // punctuation into the vocabulary.
        var out = ""
        for ch in text {
            if ch == " " || ch == "_" { out.append("-"); continue }
            let scalars = String(ch).unicodeScalars
            if scalars.allSatisfy({ allowed.contains($0) }) { out.append(ch) }
            else if ch.isLetter || ch.isNumber { out.append(ch) }   // keep non-Latin words
        }
        // Collapse and trim separators: "acme -- corp-" is one tag, not three.
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        return out.isEmpty ? nil : out
    }

    /// The tags written on one line of a transcript, or nil if this is not a
    /// tag line.
    ///
    /// Strict on purpose: EVERY token has to be a hashtag. A sentence that
    /// happens to mention "#1" is not a tag line, and neither is the "##
    /// Contents" heading — which is why the token after `#` may not be another
    /// `#` or empty.
    static func parseLine(_ line: String) -> [String]? {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }
        var tags: [String] = []
        for token in tokens {
            guard token.hasPrefix("#") else { return nil }
            let body = token.dropFirst()
            guard !body.isEmpty, !body.hasPrefix("#"),
                  let tag = normalize(String(body)) else { return nil }
            tags.append(tag)
        }
        return tags
    }

    /// The tags of a transcript, read from its header.
    ///
    /// Only the header is inspected — everything above the first spoken entry.
    /// Somebody saying "#1 priority" in the meeting must never become a tag.
    static func parse(markdown: String) -> [String] {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("**[") { break }        // the transcript starts here
            // Canonical form, not file order: a hand-edited file may list
            // them any way round, and every comparison in the app — filters,
            // counts, "did this change" — assumes one shape.
            if let tags = parseLine(trimmed) { return unique(tags) }
        }
        return []
    }

    /// How a set of tags is written: sorted, so the same tags always produce
    /// the same line and a rewrite never churns the file for nothing.
    static func tagLine(_ tags: [String]) -> String {
        unique(tags).map { "#\($0)" }.joined(separator: " ")
    }

    /// Normalised, de-duplicated, sorted — the canonical form of any tag list
    /// this app holds.
    static func unique(_ tags: [String]) -> [String] {
        Array(Set(tags.compactMap(normalize))).sorted()
    }

    /// The transcript with `tags` as its tag line — added, replaced or (for an
    /// empty list) removed.
    ///
    /// Placed under the date line, above the summary: the title says what the
    /// meeting was called, the tags say where it belongs, and the summary —
    /// the longest of the three — comes last. A reader scanning the top of the
    /// file gets the two short answers first.
    static func applying(_ tags: [String], to markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        // Drop any existing tag line first, so this is a replacement rather
        // than an accumulation.
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("**[") { break }
            if parseLine(trimmed) != nil {
                lines.remove(at: i)
                // A blank line left behind by the removal would otherwise
                // double up every time.
                if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                   i > 0, lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.remove(at: i)
                }
                break
            }
        }
        let clean = unique(tags)
        guard !clean.isEmpty else { return lines.joined(separator: "\n") }
        // After the italic date line if there is one, otherwise after the
        // title, otherwise at the very top.
        var insertAt = 0
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("**[") { break }
            if trimmed.hasPrefix("# ") { insertAt = max(insertAt, i + 1) }
            if trimmed.hasPrefix("_"), trimmed.hasSuffix("_"), trimmed.count > 2 {
                insertAt = max(insertAt, i + 1)
                break
            }
        }
        lines.insert(contentsOf: ["", tagLine(clean)], at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// A calendar's name as a tag — `valentyn@wholecall.ai` becomes
    /// `wholecall`, `Work` becomes `work`, a personal mailbox becomes nothing.
    ///
    /// Calendars are commonly named after the account they came from, and the
    /// whole address is both ugly and useless as a label. What is useful is the
    /// ORGANISATION: `wholecall` says which company's meetings these are, which
    /// is exactly the axis a tag is for. The local part does not — it is the
    /// owner's own name, identical across every calendar they have, and
    /// therefore worthless as a way to tell meetings apart.
    ///
    /// A calendar on a mail provider (gmail, icloud…) gets NO automatic tag at
    /// all. "valentyn-budanov" would be noise on every personal meeting, and a
    /// vocabulary earns nothing from a term that never divides anything.
    static func fromCalendarName(_ name: String) -> String? {
        guard name.contains("@") else { return normalize(name) }
        let parts = name.split(separator: "@")
        guard parts.count == 2 else { return normalize(name) }
        let domain = String(parts[1]).split(separator: ".").first.map(String.init) ?? ""
        // A work address is usually name@company; a personal one is usually
        // name@gmail. The company is the useful tag, the mail provider is not.
        let providers: Set<String> = ["gmail", "icloud", "me", "outlook", "hotmail",
                                      "yahoo", "proton", "protonmail", "yandex", "mail"]
        guard !domain.isEmpty, !providers.contains(domain.lowercased()) else { return nil }
        return normalize(domain)
    }
}
