import Foundation

/// Claude's `config.json`. The engine reads only `lastKnownAccountUuid` and key names, and edits
/// by keeping every other key as-is.
public enum ClaudeConfig {
    public static let accountKey = "lastKnownAccountUuid"
    public static let oauthKeys = ["oauth:tokenCache", "oauth:tokenCacheV2"]

    public static func load(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { throw EngineError.missing("config.json") }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any] else {
            throw EngineError.shapeMismatch("config.json is not a JSON object")
        }
        return dict
    }

    /// The account the app last ran as, or nil when the key is absent.
    public static func currentAccount(_ url: URL) -> String? {
        (try? load(url))?[accountKey] as? String
    }

    public static func keyNames(_ url: URL) throws -> [String] {
        try load(url).keys.sorted()
    }

    /// Sets the account (or keeps it when `account` is nil), drops both oauth caches, keeps every
    /// other key, and writes atomically with 0600.
    public static func rewrite(_ url: URL, account: String?) throws {
        var dict = try load(url)
        if let account { dict[accountKey] = account }
        for k in dict.keys where k.hasPrefix("oauth:") { dict.removeValue(forKey: k) }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes])
        try FileOps.writeAtomically(data, to: url)
    }

    /// The still-encrypted `oauth:tokenCacheV2` blob string, or nil. Never decrypted or logged here.
    public static func encryptedOAuthCache(_ url: URL) -> String? {
        (try? load(url))?["oauth:tokenCacheV2"] as? String
    }

    /// The app's own preflight: config.json is a JSON object with `lastKnownAccountUuid`.
    public static func checkShape(_ url: URL) throws {
        let dict = try load(url)
        guard dict[accountKey] is String else { throw EngineError.shapeMismatch("config.json has no \(accountKey)") }
        let unknown = dict.keys.filter { $0.hasPrefix("oauth:") && oauthKeys.contains($0) == false }.sorted()
        if unknown.isEmpty == false {
            throw EngineError.shapeMismatch("config.json has a new oauth key \(unknown[0])")
        }
    }
}
