import Foundation
import Testing
@testable import ClaudeAccountsCore

// All keys and tokens here are synthetic, generated in-test. No real Keychain or network is touched.

private let syntheticPassword = Data("synthetic-safe-storage-password".utf8)

/// Shaped like the app's cache (asar): keys `acct:<uuid>|clientId:org:apiHost:scope`, values `{token, expiresAt}`.
private func cacheJSON(access: String, scopes: [String], expiresAtMs: Double?, account: String) -> Data {
    var entry: [String: Any] = ["token": access, "refreshToken": "REFRESH-never-used"]
    if let expiresAtMs { entry["expiresAt"] = expiresAtMs }
    let key = "acct:\(account)|client-1:org-1:https://api.anthropic.com:\(scopes.joined(separator: " "))"
    return try! JSONSerialization.data(withJSONObject: [key: entry])
}

@Suite("OSCrypt and token cache")
struct CryptoTests {
    @Test("decrypt round trip with a synthetic password and an in-test blob")
    func roundTrip() throws {
        let key = OSCrypt.deriveKey(password: syntheticPassword)
        #expect(key.count == 16)
        let plaintext = Data("the quick brown fox — oauth cache bytes".utf8)
        let blob = try OSCrypt.encrypt(plaintext, key: key)
        #expect(String(decoding: blob.prefix(3), as: UTF8.self) == "v10")
        #expect(try OSCrypt.decrypt(blob, key: key) == plaintext)
        // A wrong key never recovers the plaintext (it throws or yields garbage).
        let wrong = OSCrypt.deriveKey(password: Data("other".utf8))
        #expect((try? OSCrypt.decrypt(blob, key: wrong)) != plaintext)
        #expect(throws: OSCrypt.Failure.notEncrypted) { try OSCrypt.decrypt(Data("nope".utf8), key: key) }
    }

    @Test("cache parsing finds the profile-scoped, unexpired token and never the refresh token")
    func cacheParse() {
        let now = Date()
        let good = cacheJSON(access: "ACCESS-good", scopes: ["user:profile", "user:inference"],
                             expiresAtMs: (now.addingTimeInterval(3600).timeIntervalSince1970) * 1000, account: FakeWorld.a)
        switch TokenCache.select(good, accountUuid: FakeWorld.a, now: now) {
        case .token(let t, let exp):
            #expect(t == "ACCESS-good")
            #expect(exp != nil)
        default: Issue.record("expected a token")
        }
        let parsed = (try? TokenCache.parse(good).get()) ?? []
        #expect(parsed.allSatisfy { $0.accessToken != "REFRESH-never-used" })
        #expect(parsed.first?.accountUuid == FakeWorld.a)

        // Missing scope → none.
        let noScope = cacheJSON(access: "x", scopes: ["user:inference"], expiresAtMs: nil, account: FakeWorld.a)
        guard case .failed(.noProfileScope) = TokenCache.select(noScope, accountUuid: FakeWorld.a, now: now) else { Issue.record("expected no-profile-scope"); return }

        // Expired → .expired.
        let expired = cacheJSON(access: "old", scopes: ["user:profile"],
                                expiresAtMs: (now.addingTimeInterval(-60).timeIntervalSince1970) * 1000, account: FakeWorld.a)
        guard case .expired(let mins) = TokenCache.select(expired, accountUuid: FakeWorld.a, now: now) else { Issue.record("expected expired"); return }
        #expect(mins == 1)
    }
}

@Suite("Usage response parsing")
struct UsageParseTests {
    @Test("utilization is a 0–100 percent (asar: Tl clamps/floors to 0–100, no ×100)")
    func parse() {
        let now = Date()
        let body = #"{"five_hour":{"utilization":42,"resets_at":"2026-10-08T19:00:00Z"},"seven_day":{"utilization":97},"seven_day_opus":{"utilization":5}}"#
        let u = UsageAPI.parse(Data(body.utf8), now: now)
        #expect(u?.fiveHour?.utilization == 0.42)
        #expect(u?.weekly?.level == .critical)
        // No 0–1 heuristic: 0.5 means half a percent.
        let small = UsageAPI.parse(Data(#"{"five_hour":{"utilization":0.5}}"#.utf8), now: now)
        #expect(small?.fiveHour?.utilization == 0.005)
        #expect(UsageAPI.parse(Data(#"{"five_hour":{"utilization":null}}"#.utf8), now: now) == nil)
    }

    @Test("the request carries the bearer, beta header and an honest user agent")
    func request() {
        let r = UsageAPI.request(bearer: "ACCESS")
        #expect(r.headers["Authorization"] == "Bearer ACCESS")
        #expect(r.headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(r.headers["User-Agent"] == "ClaudeAccounts/1.0")
        #expect(r.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    }
}

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    let responses: Mutex<[HTTPResponse]>
    let requests = Mutex<[HTTPRequest]>([])
    let throwNext = Mutex<Bool>(false)
    init(_ responses: [HTTPResponse]) { self.responses = Mutex(responses) }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.withLock { $0.append(request) }
        if throwNext.withLock({ let v = $0; $0 = false; return v }) { throw EngineError.io("network down") }
        return responses.withLock { $0.isEmpty ? HTTPResponse(status: 200, body: Data("{}".utf8)) : $0.removeFirst() }
    }
}

final class FixedTokenSource: UsageTokenSource, @unchecked Sendable {
    var selection: TokenCache.Selection
    init(_ s: TokenCache.Selection) { selection = s }
    func token(accountID: String, now: Date) -> TokenCache.Selection { selection }
}

import Synchronization

@Suite("Usage service: scheduling, backoff, needsRefresh, logging")
struct UsageServiceTests {
    func service(_ w: FakeWorld, http: HTTPClient, token: UsageTokenSource,
                 log: @escaping @Sendable (String) -> Void = { _ in }) -> UsageService {
        UsageService(paths: w.paths, http: http, tokens: token, ticker: FakeTicker(world: w), log: log)
    }

    @Test("200 is cached and persisted; a stale read carries the stale flag")
    func cacheAndPersist() async throws {
        let w = try FakeWorld()
        let body = #"{"five_hour":{"utilization":50},"seven_day":{"utilization":20}}"#
        let svc = service(w, http: FakeHTTP([HTTPResponse(status: 200, body: Data(body.utf8))]),
                          token: FixedTokenSource(.token("A", expiresAt: nil)))
        #expect(await svc.refresh(FakeWorld.a) == .ok)
        #expect(FileOps.exists(w.paths.usageFile))
        #expect(await svc.usage(for: FakeWorld.a)?.fiveHour?.utilization == 0.5)
        // Reloads from disk.
        let reloaded = UsageService(paths: w.paths, http: FakeHTTP([]), tokens: NoTokenSource(), ticker: FakeTicker(world: w))
        #expect(reloaded.stored(FakeWorld.a)?.usage.weekly?.utilization == 0.2)
    }

    @Test("expiry and 401 mark needsRefresh; grey ring data")
    func needsRefresh() async throws {
        let w = try FakeWorld()
        let svc = service(w, http: FakeHTTP([]), token: FixedTokenSource(.expired(minutesAgo: 5)))
        #expect(await svc.refresh(FakeWorld.a) == .needsRefresh)
        #expect(await svc.usage(for: FakeWorld.a)?.needsRefresh == true)

        let svc2 = service(w, http: FakeHTTP([HTTPResponse(status: 401)]), token: FixedTokenSource(.token("A", expiresAt: nil)))
        #expect(await svc2.refresh(FakeWorld.b) == .needsRefresh)
        #expect(await svc2.usage(for: FakeWorld.b)?.needsRefresh == true)
    }

    @Test("429 honours Retry-After, capped at 24 h, and backs off scheduling")
    func rateLimit() async throws {
        let w = try FakeWorld()
        let svc = service(w, http: FakeHTTP([HTTPResponse(status: 429, headers: ["retry-after": "600"])]),
                          token: FixedTokenSource(.token("A", expiresAt: nil)))
        let r = await svc.refresh(FakeWorld.a)
        guard case .rateLimited(let until) = r else { Issue.record("not rate limited"); return }
        #expect(until == w.now.addingTimeInterval(600))
        #expect(svc.due([FakeWorld.a], now: w.now) == nil)
        // Cap at 24 h.
        let svc2 = service(w, http: FakeHTTP([HTTPResponse(status: 429, headers: ["retry-after": "999999"])]),
                           token: FixedTokenSource(.token("A", expiresAt: nil)))
        guard case .rateLimited(let cap) = await svc2.refresh(FakeWorld.a) else { Issue.record("no cap"); return }
        #expect(cap == w.now.addingTimeInterval(24 * 3600))
        // No header → 30 min default.
        let svc3 = service(w, http: FakeHTTP([HTTPResponse(status: 429)]),
                           token: FixedTokenSource(.token("A", expiresAt: nil)))
        guard case .rateLimited(let def) = await svc3.refresh(FakeWorld.a) else { Issue.record("no default"); return }
        #expect(def == w.now.addingTimeInterval(30 * 60))
    }

    @Test("a network error keeps the cache and marks it stale")
    func networkError() async throws {
        let w = try FakeWorld()
        let http = FakeHTTP([HTTPResponse(status: 200, body: Data(#"{"five_hour":{"utilization":30}}"#.utf8))])
        let svc = service(w, http: http, token: FixedTokenSource(.token("A", expiresAt: nil)))
        _ = await svc.refresh(FakeWorld.a)
        http.throwNext.withLock { $0 = true }
        #expect(await svc.refresh(FakeWorld.a) == .networkError)
        let u = await svc.usage(for: FakeWorld.a)
        #expect(u?.fiveHour?.utilization == 0.3)  // cache kept
        #expect(u?.fiveHour?.stale == true)
    }

    @Test("scheduler: oldest due first, 5 s spacing, 15 min interval")
    func scheduling() async throws {
        let w = try FakeWorld()
        let ok = HTTPResponse(status: 200, body: Data(#"{"five_hour":{"utilization":10}}"#.utf8))
        let svc = service(w, http: FakeHTTP([ok, ok, ok]),
                          token: FixedTokenSource(.token("A", expiresAt: nil)))
        let ids = [FakeWorld.a, FakeWorld.b]
        #expect(svc.due(ids, now: w.now) == FakeWorld.a)   // never fetched
        _ = await svc.refresh(FakeWorld.a)
        #expect(svc.due(ids, now: w.now) == nil)           // 5 s spacing
        w.advance(6)
        #expect(svc.due(ids, now: w.now) == FakeWorld.b)   // b still never fetched
        _ = await svc.refresh(FakeWorld.b)
        w.advance(10)
        #expect(svc.due(ids, now: w.now) == nil)           // both within 15 min
        w.advance(15 * 60)
        #expect(svc.due(ids, now: w.now) == FakeWorld.a)   // a is oldest
    }

    @Test("panel round: queues stale accounts, at most once per 5 min, through the same spaced queue")
    func panelRound() async throws {
        let w = try FakeWorld()
        let ok = HTTPResponse(status: 200, body: Data(#"{"five_hour":{"utilization":10}}"#.utf8))
        let svc = service(w, http: FakeHTTP([ok, ok, ok]), token: FixedTokenSource(.token("A", expiresAt: nil)))
        _ = await svc.refresh(FakeWorld.a)
        w.advance(6)
        // a is fresh (<5 min), b never fetched → only b queued.
        #expect(svc.queuePanelRound([FakeWorld.a, FakeWorld.b], now: w.now) == [FakeWorld.b])
        // A second panel open within 5 min queues nothing.
        #expect(svc.queuePanelRound([FakeWorld.a, FakeWorld.b], now: w.now.addingTimeInterval(60)).isEmpty)
        // The queued account comes out first, respecting spacing.
        #expect(svc.due([FakeWorld.a, FakeWorld.b], now: w.now) == FakeWorld.b)
    }

    @Test("logs carry only status codes, timestamps and uuids — never token or value bytes")
    func noSecretLogging() async throws {
        let w = try FakeWorld()
        let lines = Mutex<[String]>([])
        // 4242 can't occur in a log stamp (2-digit runs plus the year) or a uuid, so the check below never depends on the clock.
        let body = #"{"five_hour":{"utilization":4242}}"#
        let svc = service(w, http: FakeHTTP([HTTPResponse(status: 200, body: Data(body.utf8)), HTTPResponse(status: 429, headers: ["retry-after": "10"])]),
                          token: FixedTokenSource(.token("SECRET-BEARER-TOKEN", expiresAt: nil))) { msg in lines.withLock { $0.append(msg) } }
        _ = await svc.refresh(FakeWorld.a)
        _ = await svc.refresh(FakeWorld.a)
        let all = lines.withLock { $0 }.joined(separator: "\n")
        #expect(all.contains("SECRET-BEARER-TOKEN") == false)
        #expect(all.contains("4242") == false)
        #expect(all.contains(FakeWorld.a))
        #expect(all.contains("200") || all.contains("429"))
    }
}
