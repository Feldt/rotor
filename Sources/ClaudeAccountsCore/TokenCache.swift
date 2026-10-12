import Foundation

/// A decrypted `oauth:tokenCacheV2` entry (structure only; the token is never logged).
///
/// Shape, from Claude.app 2.26454.0's asar (index.chunk-C31r7VW_.js):
/// - persisted as `safeStorage.encryptString(JSON.stringify(zmn(ok))).toString("base64")`;
/// - `ok` is an object keyed by a string built by `Tmn(account, clientId, x, apiHost, scope)`:
///   `account ? "acct:" + account + "|" + "clientId:x:apiHost:scope" : "clientId:x:apiHost:scope"`
///   (`WO="acct:"`; `GO(key)` reads the account between "acct:" and "|"). Account tagging and the
///   scope live in the key, not in the value.
/// - values are `{token, expiresAt, …}` (`a?.token && Date.now() < a.expiresAt`; `expiresAt` is ms);
///   a value may be `null` (`ok[r]=null`). Older v1-seeded values may use `accessToken`.
/// - On an identity change the app clears the cache, and `zmn` persists only keys whose `GO(key)`
///   is the current account (or all when none is set), so every live entry is that account's.
public struct CachedToken: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var scopes: [String]
    /// From the key's "acct:<uuid>|" prefix (or a value field), lowercased.
    public var accountUuid: String?
}

/// Why no token was produced. Logged with structure only (counts, scope names, uuids), never values.
public enum TokenFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case noCache
    case keychainDenied
    case keychainMissing
    case decryptFailed
    case jsonParseFailed
    case noEntries
    case noProfileScope(entries: Int, scopes: [[String]])
    case ambiguous(entries: Int, tagged: [String: Int], untagged: Int)

    public var description: String {
        switch self {
        case .noCache: "no-cache"
        case .keychainDenied: "keychain-denied"
        case .keychainMissing: "keychain-missing"
        case .decryptFailed: "decrypt-failed"
        case .jsonParseFailed: "json-parse-failed"
        case .noEntries: "no-entries"
        case .noProfileScope(let n, let scopes):
            "no-profile-scope entries=\(n) scopes=\(scopes.map { "[" + $0.joined(separator: " ") + "]" }.joined(separator: ","))"
        case .ambiguous(let n, let tagged, let untagged):
            "ambiguous entries=\(n) tagged=\(tagged.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")) untagged=\(untagged)"
        }
    }
}

public enum TokenCache {
    public static let requiredScope = "user:profile"
    public static let keyPrefix = "acct:"
    /// Scopes that mark the Claude Code token set (preferred when several qualify).
    public static let claudeCodeMarkers: Set<String> = ["user:sessions:claude_code", "user:inference"]

    public enum Selection: Sendable, Equatable {
        case token(String, expiresAt: Date?)
        /// Every qualifying entry is expired; minutes since the newest expiry.
        case expired(minutesAgo: Int)
        case failed(TokenFailure)
    }

    /// Account and scopes from a cache key: `[acct:<uuid>|]clientId:x:apiHost:scope`.
    static func parseKey(_ key: String) -> (account: String?, scopes: [String]) {
        var rest = key
        var account: String?
        if rest.hasPrefix(keyPrefix), let bar = rest.firstIndex(of: "|") {
            account = String(rest[rest.index(rest.startIndex, offsetBy: keyPrefix.count)..<bar]).lowercased()
            rest = String(rest[rest.index(after: bar)...])
        }
        // clientId and x carry no colons; split them off, leaving "apiHost:scope".
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return (account, []) }
        var hostAndScope = String(parts[2])
        // apiHost may be a URL ("https://host[:port]"); drop it up to the colon that precedes the scope.
        if let schemeEnd = hostAndScope.range(of: "://") {
            hostAndScope = String(hostAndScope[schemeEnd.upperBound...])
        }
        guard let colon = hostAndScope.firstIndex(of: ":") else { return (account, []) }
        var scopePart = String(hostAndScope[hostAndScope.index(after: colon)...])
        // A port ("host:443:scope") is all digits; skip it.
        if let next = scopePart.firstIndex(of: ":"), scopePart[..<next].allSatisfy(\.isNumber) {
            scopePart = String(scopePart[scopePart.index(after: next)...])
        }
        let scopes = scopePart.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        return (account, scopes)
    }

    /// Entries from the decrypted JSON, or a failure (`json-parse-failed`).
    public static func parse(_ json: Data) -> Result<[CachedToken], TokenFailure> {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            return .failure(.jsonParseFailed)
        }
        var out: [CachedToken] = []
        for (key, value) in root {
            guard let v = value as? [String: Any] else { continue }  // null entries are cleared slots
            let token = (v["token"] as? String) ?? (v["accessToken"] as? String)
            guard let token, token.isEmpty == false else { continue }
            let (keyAccount, keyScopes) = parseKey(key)
            var scopes = keyScopes
            for field in ["grantedScopes", "scopeEcho", "scopes"] {
                if let a = v[field] as? [String] { scopes += a }
                if let s = v[field] as? String { scopes += s.split(separator: " ").map(String.init) }
            }
            var expires: Date?
            if let ms = v["expiresAt"] as? Double, ms > 0 { expires = Date(timeIntervalSince1970: ms / 1000) }
            else if let ms = v["expiresAt"] as? Int, ms > 0 { expires = Date(timeIntervalSince1970: Double(ms) / 1000) }
            let account = keyAccount ?? (v["accountUuid"] as? String)?.lowercased()
            out.append(CachedToken(accessToken: token, expiresAt: expires, scopes: Array(Set(scopes)).sorted(),
                                   accountUuid: account))
        }
        return .success(out)
    }

    /// Picks the token for `accountUuid`:
    /// 1. drop entries explicitly tagged with another account;
    /// 2. among the rest (tagged with the target or untagged, which the cache-clearing rule makes
    ///    the live account's), keep `user:profile` entries;
    /// 3. prefer unexpired, then the Claude Code scope set, then the latest `expiresAt`.
    /// `ambiguous` only when entries are tagged with two or more other accounts and none with the target.
    public static func select(_ json: Data, accountUuid: String, now: Date) -> Selection {
        let entries: [CachedToken]
        switch parse(json) {
        case .failure(let f): return .failed(f)
        case .success(let e): entries = e
        }
        guard entries.isEmpty == false else { return .failed(.noEntries) }
        let target = accountUuid.lowercased()
        let mine = entries.filter { $0.accountUuid == nil || $0.accountUuid == target }
        if mine.isEmpty {
            var tagged: [String: Int] = [:]
            for e in entries { if let a = e.accountUuid { tagged[a, default: 0] += 1 } }
            if tagged.count >= 2 {
                return .failed(.ambiguous(entries: entries.count, tagged: tagged, untagged: 0))
            }
            return .failed(.noEntries)
        }
        let profile = mine.filter { $0.scopes.contains(requiredScope) }
        guard profile.isEmpty == false else {
            return .failed(.noProfileScope(entries: mine.count, scopes: mine.map(\.scopes)))
        }
        func isClaudeCode(_ t: CachedToken) -> Bool { t.scopes.contains { claudeCodeMarkers.contains($0) } }
        func live(_ t: CachedToken) -> Bool { t.expiresAt.map { $0 > now } ?? true }
        let ranked = profile.sorted { a, b in
            if live(a) != live(b) { return live(a) }
            if isClaudeCode(a) != isClaudeCode(b) { return isClaudeCode(a) }
            return (a.expiresAt ?? .distantFuture) > (b.expiresAt ?? .distantFuture)
        }
        let best = ranked[0]
        if live(best) { return .token(best.accessToken, expiresAt: best.expiresAt) }
        let newest = profile.compactMap(\.expiresAt).max() ?? now
        return .expired(minutesAgo: max(0, Int((now.timeIntervalSince(newest) / 60).rounded())))
    }
}
