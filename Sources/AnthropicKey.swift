import Foundation
import Security

/// The user's own Anthropic API key, in the Keychain.
///
/// Their key, their account, their bill. That is not a limitation we accepted
/// reluctantly — it is the only arrangement both vendors sanction for a
/// third-party application, and it is the one that matches what this app
/// already promises. Everything else here stays on the Mac; the one feature
/// that cannot is at least paid for, metered and revocable by the person whose
/// meetings they are.
///
/// In the Keychain rather than UserDefaults because a key in a plist is a key
/// in every backup, every screen share and every `defaults read`. This is the
/// second secret the app holds — the Sparkle signing key is the first — and it
/// goes where that one goes.
enum AnthropicKey {

    private static let service = "com.valentynbudanov.Dictate.anthropic"
    private static let account = "api-key"

    /// The stored key, or nil.
    static var current: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Store a key, or remove it when given nothing.
    @discardableResult
    static func store(_ key: String?) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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

    /// Whether a string looks like an Anthropic key at all.
    ///
    /// Shape only, and deliberately loose — the real test is a request that
    /// works, and a validator that is stricter than the issuer will one day
    /// reject a perfectly good key because the prefix changed. This exists to
    /// catch the paste that went wrong, not to authenticate.
    static func looksValid(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count > 20
    }

    /// A key never appears in full anywhere it might be read over a shoulder or
    /// pasted into a bug report.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "••••" }
        return String(key.prefix(8)) + "…" + String(key.suffix(4))
    }
}
