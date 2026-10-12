import Foundation
import Synchronization
import Testing
@testable import ClaudeAccountsCore

// Synthetic password, keys and caches only. No real Keychain, no network.

private struct SyntheticPassword: SafeStoragePassword {
    var result: Result<Data, KeychainError>
    func password() throws -> Data { try result.get() }
}
private let pw = Data("synthetic-password".utf8)

/// Writes a live config whose `oauth:tokenCacheV2` is base64 of `v10` + AES(json), like the app.
private func writeLive(_ w: FakeWorld, plaintext: Data, password: Data = pw) throws {
    let blob = try OSCrypt.encrypt(plaintext, key: OSCrypt.deriveKey(password: password))
    try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a,
                            extra: ["oauth:tokenCacheV2": blob.base64EncodedString()])
}

private func source(_ w: FakeWorld, _ r: Result<Data, KeychainError> = .success(pw)) -> KeychainTokenSource {
    KeychainTokenSource(paths: w.paths, password: SyntheticPassword(result: r), currentAccount: { FakeWorld.a })
}

private func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

@Suite("Token reasons")
struct TokenReasonTests {
    @Test("happy path: base64 v10 blob, key-tagged entry, token field")
    func happy() throws {
        let w = try FakeWorld()
        let exp = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        try writeLive(w, plaintext: json(["acct:\(FakeWorld.a)|c:o:https://api.anthropic.com:user:inference user:profile":
                                            ["token": "SYNTH-TOKEN", "expiresAt": exp]]))
        guard case .token(let t, _) = source(w).token(accountID: FakeWorld.a, now: Date()) else { Issue.record("no token"); return }
        #expect(t == "SYNTH-TOKEN")
    }

    @Test("no-cache when config has no oauth cache")
    func noCache() throws {
        let w = try FakeWorld()
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": FakeWorld.a]).write(to: w.paths.liveConfig)
        #expect(source(w).token(accountID: FakeWorld.a, now: Date()) == .failed(.noCache))
    }

    @Test("keychain-missing and keychain-denied")
    func keychain() throws {
        let w = try FakeWorld()
        try writeLive(w, plaintext: json([:]))
        #expect(source(w, .failure(.missing)).token(accountID: FakeWorld.a, now: Date()) == .failed(.keychainMissing))
        #expect(source(w, .failure(.denied(-128))).token(accountID: FakeWorld.a, now: Date()) == .failed(.keychainDenied))
    }

    @Test("decrypt-failed: wrong key, or a value that isn't base64")
    func decrypt() throws {
        let w = try FakeWorld()
        try writeLive(w, plaintext: json([:]), password: Data("a-different-password".utf8))
        let r = source(w).token(accountID: FakeWorld.a, now: Date())
        // A wrong key fails padding (decrypt-failed) or, rarely, yields junk that isn't JSON.
        #expect(r == .failed(.decryptFailed) || r == .failed(.jsonParseFailed))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a, extra: ["oauth:tokenCacheV2": "not base64 !!"])
        #expect(source(w).token(accountID: FakeWorld.a, now: Date()) == .failed(.decryptFailed))
    }

    @Test("json-parse-failed and no-entries")
    func parseAndEmpty() throws {
        let w = try FakeWorld()
        try writeLive(w, plaintext: Data("not json".utf8))
        #expect(source(w).token(accountID: FakeWorld.a, now: Date()) == .failed(.jsonParseFailed))
        try writeLive(w, plaintext: json(["k": NSNull()]))      // a cleared slot
        #expect(source(w).token(accountID: FakeWorld.a, now: Date()) == .failed(.noEntries))
    }

    @Test("no-profile-scope reports the entry count and each scope list")
    func noProfile() throws {
        let w = try FakeWorld()
        try writeLive(w, plaintext: json(["c:o:h:user:inference": ["token": "X"], "c:o:h:org:create_api_key": ["token": "Y"]]))
        guard case .failed(.noProfileScope(let n, let scopes)) = source(w).token(accountID: FakeWorld.a, now: Date()) else {
            Issue.record("expected no-profile-scope"); return
        }
        #expect(n == 2)
        #expect(Set(scopes) == [["user:inference"], ["org:create_api_key"]])
    }

    @Test("expired reports minutes since expiry")
    func expired() throws {
        let w = try FakeWorld()
        let now = Date()
        try writeLive(w, plaintext: json(["c:o:h:user:profile": ["token": "X", "expiresAt": now.addingTimeInterval(-30 * 60).timeIntervalSince1970 * 1000]]))
        #expect(source(w).token(accountID: FakeWorld.a, now: now) == .expired(minutesAgo: 30))
    }

    @Test("logged reasons carry structure only: no token, no key, no blob")
    func logSafety() async throws {
        let w = try FakeWorld()
        try writeLive(w, plaintext: json(["c:o:h:user:inference": ["token": "SECRET-SYNTH-TOKEN"]]))
        let lines = Mutex<[String]>([])
        let s = UsageService(paths: w.paths, http: FakeHTTP([]), tokens: source(w), ticker: FakeTicker(world: w),
                             log: { m in lines.withLock { $0.append(m) } })
        _ = await s.refresh(FakeWorld.a)
        let all = lines.withLock { $0 }.joined(separator: "\n")
        #expect(all.contains("no-profile-scope entries=1 scopes=[user:inference]"))
        #expect(all.contains("SECRET-SYNTH-TOKEN") == false)
        #expect(all.contains("synthetic-password") == false)
        let blob = (try? ClaudeConfig.load(w.paths.liveConfig))?["oauth:tokenCacheV2"] as? String ?? "zzz"
        #expect(all.contains(blob) == false)
    }

    @Test("key parsing: account prefix, URL host with scheme, port, multi-word scope")
    func keyParsing() {
        let k = TokenCache.parseKey("acct:\(FakeWorld.a.uppercased())|client:org:https://api.anthropic.com:443:user:inference user:profile")
        #expect(k.account == FakeWorld.a)
        #expect(k.scopes == ["user:inference", "user:profile"])
        let plain = TokenCache.parseKey("client:org:api.anthropic.com:user:profile")
        #expect(plain.account == nil)
        #expect(plain.scopes == ["user:profile"])
    }
}
