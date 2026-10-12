import Foundation
import Synchronization
import Testing
@testable import ClaudeAccountsCore

// Synthetic data only. No real Keychain, no network.

private final class GatedTokens: UsageTokenSource, @unchecked Sendable {
    let sel: Mutex<TokenCache.Selection>
    let current = Mutex<String?>(nil)
    let stamps = Mutex<[String: String]>([:])
    let live = Mutex<String?>("live-1")
    func liveConfigStamp() -> String? { live.withLock { $0 } }
    init(_ s: TokenCache.Selection) { sel = Mutex(s) }
    func token(accountID: String, now: Date) -> TokenCache.Selection { sel.withLock { $0 } }
    func isCurrent(_ id: String) -> Bool { current.withLock { $0 } == id }
    func blobStamp(_ id: String) -> String? { stamps.withLock { $0[id] } }
}

private func svc(_ w: FakeWorld, _ http: HTTPClient, _ t: UsageTokenSource) -> UsageService {
    UsageService(paths: w.paths, http: http, tokens: t, ticker: FakeTicker(world: w))
}
private let okBody = Data(#"{"five_hour":{"utilization":40},"seven_day":{"utilization":20}}"#.utf8)

@Suite("Usage review fixes")
struct UsageReviewTests {
    // 1
    @Test("#1 exponential backoff per account: 15 → 30 → 60 min, capped at 6 h")
    func backoffCurve() throws {
        let w = try FakeWorld()
        let s = svc(w, FakeHTTP([]), GatedTokens(.failed(.noCache)))
        #expect(s.backoff(failures: 1) == 15 * 60)
        #expect(s.backoff(failures: 2) == 30 * 60)
        #expect(s.backoff(failures: 3) == 60 * 60)
        #expect(s.backoff(failures: 10) == 6 * 3600)
    }

    @Test("#1 repeated failures are scheduled by attempt and back off, not retried every tick")
    func noUnboundedRetries() async throws {
        let w = try FakeWorld()
        let http = FakeHTTP([HTTPResponse(status: 503), HTTPResponse(status: 503), HTTPResponse(status: 503)])
        let s = svc(w, http, GatedTokens(.token("A", expiresAt: nil)))
        _ = await s.refresh(FakeWorld.a)                       // failure 1
        w.advance(6)
        #expect(s.due([FakeWorld.a], now: w.now) == nil)        // within 15 min backoff
        w.advance(15 * 60)
        #expect(s.due([FakeWorld.a], now: w.now) == FakeWorld.a)
        _ = await s.refresh(FakeWorld.a)                       // failure 2
        w.advance(20 * 60)
        #expect(s.due([FakeWorld.a], now: w.now) == nil)        // now needs 30 min
        w.advance(11 * 60)
        #expect(s.due([FakeWorld.a], now: w.now) == FakeWorld.a)
        #expect(http.requests.withLock { $0.count } == 2)
    }

    @Test("#1 a missing token backs off too")
    func missingTokenBacksOff() async throws {
        let w = try FakeWorld()
        let s = svc(w, FakeHTTP([]), GatedTokens(.failed(.noCache)))
        #expect(await s.refresh(FakeWorld.a) == .noToken(.noCache))
        w.advance(6)
        #expect(s.due([FakeWorld.a], now: w.now) == nil)
        #expect(s.stored(FakeWorld.a)?.failures == 1)
    }

    @Test("#1 needsRefresh accounts aren't polled until they become current or their blob changes")
    func needsRefreshGated() async throws {
        let w = try FakeWorld()
        let t = GatedTokens(.token("A", expiresAt: nil))
        t.stamps.withLock { $0[FakeWorld.b] = "100-1" }
        let s = svc(w, FakeHTTP([HTTPResponse(status: 401)]), t)
        _ = await s.refresh(FakeWorld.b)                       // 401 while not current
        w.advance(7 * 3600)
        #expect(s.due([FakeWorld.b], now: w.now) == nil)        // never, however long
        t.stamps.withLock { $0[FakeWorld.b] = "120-2" }         // slot blob changed
        #expect(s.due([FakeWorld.b], now: w.now) == FakeWorld.b)
        t.stamps.withLock { $0[FakeWorld.b] = "100-1" }
        t.current.withLock { $0 = FakeWorld.b }                 // a switch made it current
        t.live.withLock { $0 = "live-after-switch" }            // and wrote a fresh live config
        #expect(s.due([FakeWorld.b], now: w.now) == FakeWorld.b)
    }

    @Test("A: the current account's needsRefresh retries on backoff, and at once when config.json changes")
    func currentNeedsRefreshRetries() async throws {
        let w = try FakeWorld()
        let t = GatedTokens(.token("A", expiresAt: nil))
        t.current.withLock { $0 = FakeWorld.a }
        let s = svc(w, FakeHTTP([HTTPResponse(status: 401)]), t)
        _ = await s.refresh(FakeWorld.a)                       // 401 while current
        #expect(s.stored(FakeWorld.a)?.usage.needsRefresh == true)
        w.advance(6)
        #expect(s.due([FakeWorld.a], now: w.now) == nil)        // within backoff, config unchanged
        t.live.withLock { $0 = "live-2" }                       // Claude re-minted: config.json changed
        #expect(s.due([FakeWorld.a], now: w.now) == FakeWorld.a) // retried immediately
        t.live.withLock { $0 = "live-1" }                       // back to the marked stamp
        w.advance(15 * 60)
        #expect(s.due([FakeWorld.a], now: w.now) == FakeWorld.a) // and on normal backoff
    }

    // 2
    @Test("#2 a Keychain denial is cached: no re-prompt until Retry")
    func denialCached() throws {
        let w = try FakeWorld()
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a, extra: ["oauth:tokenCacheV2": "v10SYNTH"])
        let pw = CountingDeniedPassword()
        let src = KeychainTokenSource(paths: w.paths, password: pw, currentAccount: { FakeWorld.a })
        #expect(src.token(accountID: FakeWorld.a, now: Date()) == .failed(.keychainDenied))
        #expect(src.isKeychainDenied)
        _ = src.token(accountID: FakeWorld.a, now: Date())
        _ = src.token(accountID: FakeWorld.a, now: Date())
        #expect(pw.calls.withLock { $0 } == 1)                  // prompted once only
        src.retryKeychain()
        #expect(src.isKeychainDenied == false)
        _ = src.token(accountID: FakeWorld.a, now: Date())
        #expect(pw.calls.withLock { $0 } == 2)                  // one more prompt after Retry
    }

    // 3 is covered in UsageProviderTests (percent-only).

    // 4
    @Test("#4 resets_at accepts fractional seconds and plain ISO 8601")
    func dates() {
        #expect(UsageAPI.parseDate("2026-10-08T19:00:00.123456Z") != nil)
        #expect(UsageAPI.parseDate("2026-10-08T19:00:00Z") != nil)
        #expect(UsageAPI.parseDate("2026-10-08T19:00:00+00:00") != nil)
        let frac = UsageAPI.parse(Data(#"{"five_hour":{"utilization":10,"resets_at":"2026-10-08T19:00:00.5Z"}}"#.utf8), now: Date())
        #expect(frac?.fiveHour?.resetsAt != nil)
    }

    // 5
    @Test("#5 the session can't write the token to disk, and only api.anthropic.com over https is allowed")
    func secureSession() async {
        let c = SecureHTTPClient.makeConfiguration()
        #expect(c.urlCache == nil)
        #expect(c.httpShouldSetCookies == false)
        #expect(c.httpCookieStorage == nil)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(SecureHTTPClient.isAllowed(URL(string: "https://api.anthropic.com/api/oauth/usage")!))
        #expect(SecureHTTPClient.isAllowed(URL(string: "http://api.anthropic.com/x")!) == false)
        #expect(SecureHTTPClient.isAllowed(URL(string: "https://evil.example.com/x")!) == false)
        #expect(SecureHTTPClient.isAllowed(URL(string: "https://api.anthropic.com.evil.com/x")!) == false)
        // A disallowed host is refused before any request is made.
        await #expect(throws: HTTPGuardError.hostNotAllowed) {
            _ = try await SecureHTTPClient().send(HTTPRequest(url: URL(string: "https://evil.example.com")!, headers: [:]))
        }
    }

    @Test("#5 redirects are refused")
    func redirectRefused() async {
        let refuser = RedirectRefuser()
        let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com/a")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let got = Mutex<URLRequest??>(.none)
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.anthropic.com/a")!)
        refuser.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: resp,
                           newRequest: URLRequest(url: URL(string: "https://evil.example.com")!)) { r in got.withLock { $0 = .some(r) } }
        #expect(got.withLock { $0 } == .some(nil))
        task.cancel()
    }

    // 6 (revised by the asar: untagged entries are the live account's)
    @Test("#6 entries tagged with another account are dropped")
    func dropsOthers() {
        let json = try! JSONSerialization.data(withJSONObject: [
            "acct:\(FakeWorld.b)|c:o:https://api.anthropic.com:user:profile": ["token": "OTHER"]])
        #expect(TokenCache.select(json, accountUuid: FakeWorld.a, now: Date()) == .failed(.noEntries))
    }

    @Test("#6 several untagged entries with different scopes are normal, not ambiguous")
    func untaggedNormal() {
        let now = Date()
        let soon = now.addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let later = now.addingTimeInterval(7200).timeIntervalSince1970 * 1000
        let json = try! JSONSerialization.data(withJSONObject: [
            "c:o:https://api.anthropic.com:user:profile": ["token": "PROFILE", "expiresAt": later],
            "c:o:https://api.anthropic.com:org:create_api_key user:profile": ["token": "APIKEY", "expiresAt": later],
            "c:o:https://api.anthropic.com:user:inference user:profile user:sessions:claude_code": ["token": "CC", "expiresAt": soon],
            "c:o:https://api.anthropic.com:user:inference": ["token": "NOPROFILE", "expiresAt": later],
        ])
        // Claude Code scope set preferred over a later-expiring plain profile token.
        guard case .token(let t, _) = TokenCache.select(json, accountUuid: FakeWorld.a, now: now) else {
            Issue.record("expected a token"); return
        }
        #expect(t == "CC")
    }

    @Test("#6 among equals, the latest expiresAt wins; unexpired beats expired")
    func latestWins() {
        let now = Date()
        let json = try! JSONSerialization.data(withJSONObject: [
            "c:o:h:user:profile": ["token": "OLD", "expiresAt": now.addingTimeInterval(600).timeIntervalSince1970 * 1000],
            "c:o:h:user:profile x": ["token": "NEW", "expiresAt": now.addingTimeInterval(3000).timeIntervalSince1970 * 1000],
            "c:o:h:user:profile y": ["token": "DEAD", "expiresAt": now.addingTimeInterval(-60).timeIntervalSince1970 * 1000],
        ])
        #expect(TokenCache.select(json, accountUuid: FakeWorld.a, now: now) == .token("NEW", expiresAt:
            Date(timeIntervalSince1970: (now.addingTimeInterval(3000).timeIntervalSince1970 * 1000) / 1000)))
    }

    @Test("#6 ambiguous only when tagged with two other accounts and none with the target")
    func ambiguousRule() {
        let json = try! JSONSerialization.data(withJSONObject: [
            "acct:\(FakeWorld.b)|c:o:h:user:profile": ["token": "B"],
            "acct:\(FakeWorld.c)|c:o:h:user:profile": ["token": "C"],
        ])
        guard case .failed(.ambiguous(let n, let tagged, let untagged)) = TokenCache.select(json, accountUuid: FakeWorld.a, now: Date()) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(n == 2)
        #expect(tagged == [FakeWorld.b: 1, FakeWorld.c: 1])
        #expect(untagged == 0)
    }

    // 7
    @Test("#7 the live cache isn't read while an add is in progress")
    func skipDuringAdd() throws {
        let w = try FakeWorld()
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a, extra: ["oauth:tokenCacheV2": "v10SYNTH"])
        let pw = CountingDeniedPassword()
        let src = KeychainTokenSource(paths: w.paths, password: pw, currentAccount: { FakeWorld.a },
                                      isAddInProgress: { true })
        #expect(src.encryptedCache(for: FakeWorld.a) == nil)
        #expect(src.token(accountID: FakeWorld.a, now: Date()) == .failed(.noCache))
        #expect(pw.calls.withLock { $0 } == 0)                  // never even asked the Keychain
    }

    // 8
    @Test("#8 an unparseable 200 keeps the previous good values, marked stale")
    func unparseable200() async throws {
        let w = try FakeWorld()
        let s = svc(w, FakeHTTP([HTTPResponse(status: 200, body: okBody),
                                 HTTPResponse(status: 200, body: Data("<html>oops</html>".utf8))]),
                    GatedTokens(.token("A", expiresAt: nil)))
        #expect(await s.refresh(FakeWorld.a) == .ok)
        w.advance(20 * 60)
        #expect(await s.refresh(FakeWorld.a) == .unparseable)
        let u = await s.usage(for: FakeWorld.a)
        #expect(u?.fiveHour?.utilization == 0.40)               // previous good value kept
        #expect(u?.fiveHour?.stale == true)
    }
}

/// Always denies, counting how often the Keychain was asked.
final class CountingDeniedPassword: SafeStoragePassword, @unchecked Sendable {
    let calls = Mutex<Int>(0)
    func password() throws -> Data {
        calls.withLock { $0 += 1 }
        throw EngineError.io("denied")
    }
}
