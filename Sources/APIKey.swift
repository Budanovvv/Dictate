import Foundation
import Security

/// The two vendors whose models can answer questions about the archive.
///
/// A provider is an identity — a name on the picker, a key format, a console
/// where that key is issued. Whether asking is switched on at all, and with
/// which of these, is `Settings.askProvider`; this type only knows what each
/// vendor is called and what its credentials look like.
enum AIProvider: String, CaseIterable {
    case anthropic
    case openai

    /// The name on the picker — the product a person knows, not the company
    /// that bills them. Nobody says "I use Anthropic".
    var productName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openai: return "ChatGPT"
        }
    }

    /// The name in the privacy footer — who the passages are sent to. There it
    /// is the company that matters, because that is whose servers they reach.
    var vendorName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    var keyLabel: String {
        switch self {
        case .anthropic: return L("Anthropic API key")
        case .openai: return L("OpenAI API key")
        }
    }

    /// The shape of the thing being asked for, shown in the empty field.
    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        }
    }

    /// Where a key is issued — the step the field alone leaves the person to
    /// go and find out for themselves.
    var keysURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    fileprivate var keyPrefix: String {
        switch self {
        case .anthropic: return "sk-ant-"
        case .openai: return "sk-"
        }
    }

    /// The Keychain service name. The `anthropic` value predates the second
    /// provider and must never change — it is where existing users' keys
    /// already live.
    fileprivate var service: String {
        "com.valentynbudanov.Dictate." + rawValue
    }
}

/// The user's own API keys, one per provider, in the Keychain.
///
/// Their key, their account, their bill. That is not a limitation we accepted
/// reluctantly — it is the only arrangement these vendors sanction for a
/// third-party application, and it is the one that matches what this app
/// already promises. Everything else here stays on the Mac; the one feature
/// that cannot is at least paid for, metered and revocable by the person whose
/// meetings they are.
///
/// In the Keychain rather than UserDefaults because a key in a plist is a key
/// in every backup, every screen share and every `defaults read`. These are
/// the second secrets the app holds — the Sparkle signing key is the first —
/// and they go where that one goes.
enum APIKey {

    private static let account = "api-key"

    private static func query(_ provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored key, or nil.
    static func current(_ provider: AIProvider) -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Removing a key is one click with no confirmation; the replacement for
    /// confirmation is undo (design review 2026-08-27). The removed key is
    /// held in memory for the life of the process — never written anywhere —
    /// so "Undo" can restore it without the user re-fetching it from the
    /// vendor console.
    ///
    /// @MainActor because every writer is UI (the Settings key row, the
    /// connect sheet, the answer pane) — the undo slot never leaves the
    /// main thread.
    @MainActor private static var lastRemoved: [AIProvider: String] = [:]

    /// Restores the most recently removed key for the provider, if any.
    @discardableResult
    @MainActor static func undoRemove(for provider: AIProvider) -> Bool {
        guard let key = lastRemoved[provider] else { return false }
        lastRemoved[provider] = nil
        return store(key, for: provider)
    }

    @MainActor static func canUndoRemove(for provider: AIProvider) -> Bool {
        lastRemoved[provider] != nil
    }

    /// Store a key, or remove it when given nothing.
    /// @MainActor for the undo slot it fills (see `lastRemoved`).
    @discardableResult
    @MainActor static func store(_ key: String?, for provider: AIProvider) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty, let existing = current(provider) {
            lastRemoved[provider] = existing
        }
        let base = query(provider)
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return true }

        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        // Available after first unlock and never synced: a key that rode iCloud
        // to another Mac would be spending this person's money somewhere they
        // are not sitting.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Whether a string looks like this provider's key at all.
    ///
    /// Shape only, and deliberately loose — the real test is a request that
    /// works, and a validator that is stricter than the issuer will one day
    /// reject a perfectly good key because the prefix changed. This exists to
    /// catch the paste that went wrong, not to authenticate.
    static func looksValid(_ key: String, for provider: AIProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(provider.keyPrefix) && trimmed.count > 20
    }

    /// A key never appears in full anywhere it might be read over a shoulder or
    /// pasted into a bug report.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "••••" }
        return String(key.prefix(8)) + "…" + String(key.suffix(4))
    }
}
