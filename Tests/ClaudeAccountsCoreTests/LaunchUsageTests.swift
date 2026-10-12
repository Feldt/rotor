import Foundation
import Testing
@testable import ClaudeAccountsCore

@Suite("Launch usage attempt")
struct LaunchUsageTests {
    private func seedBackoff(_ w: FakeWorld, commit: String?, retryUntil: Date? = nil) throws {
        var rec = StoredUsage(usage: AccountUsage(fiveHour: nil, weekly: nil), fetchedAt: w.now,
                              stale: true, retryUntil: retryUntil, lastAttemptAt: w.now, failures: 4)
        rec.commit = commit
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try FileOps.ensureDirectory(w.paths.storeRoot)
        try e.encode([FakeWorld.a: rec]).write(to: w.paths.usageFile)
    }

    @Test("a different build's backoff is cleared at load, and the commit is stored")
    func resetOnNewBuild() throws {
        let w = try FakeWorld()
        try seedBackoff(w, commit: "old1234")
        let s = UsageService(paths: w.paths, http: FakeHTTP([]), tokens: NoTokenSource(), ticker: FakeTicker(world: w),
                             buildCommit: "new5678")
        #expect(s.stored(FakeWorld.a)?.failures == 0)
        #expect(s.stored(FakeWorld.a)?.lastAttemptAt == nil)
        #expect(s.stored(FakeWorld.a)?.commit == "new5678")
        #expect(s.due([FakeWorld.a], now: w.now) == FakeWorld.a)
        // Persisted.
        let again = UsageService(paths: w.paths, http: FakeHTTP([]), tokens: NoTokenSource(), ticker: FakeTicker(world: w),
                                 buildCommit: "new5678")
        #expect(again.stored(FakeWorld.a)?.failures == 0)
    }

    @Test("the same build keeps its backoff")
    func sameBuildKeeps() throws {
        let w = try FakeWorld()
        try seedBackoff(w, commit: "same123")
        let s = UsageService(paths: w.paths, http: FakeHTTP([]), tokens: NoTokenSource(), ticker: FakeTicker(world: w),
                             buildCommit: "same123")
        #expect(s.stored(FakeWorld.a)?.failures == 4)
        #expect(s.due([FakeWorld.a], now: w.now) == nil)
    }

    @Test("launch attempts the current account despite backoff, but not inside a 429 window")
    func launchAttempt() throws {
        let w = try FakeWorld()
        try seedBackoff(w, commit: "same123")
        let s = UsageService(paths: w.paths, http: FakeHTTP([]), tokens: NoTokenSource(), ticker: FakeTicker(world: w),
                             buildCommit: "same123")
        s.queueLaunch(FakeWorld.a, now: w.now)
        #expect(s.due([FakeWorld.a], now: w.now) == FakeWorld.a)   // forced once
        #expect(s.due([FakeWorld.a], now: w.now) == nil)           // then normal backoff

        let w2 = try FakeWorld()
        try seedBackoff(w2, commit: "same123", retryUntil: w2.now.addingTimeInterval(600))
        let s2 = UsageService(paths: w2.paths, http: FakeHTTP([]), tokens: NoTokenSource(), ticker: FakeTicker(world: w2),
                              buildCommit: "same123")
        s2.queueLaunch(FakeWorld.a, now: w2.now)
        #expect(s2.due([FakeWorld.a], now: w2.now) == nil)
    }

    @Test("an aborted quit logs 'nothing was changed' once")
    func abortLogOnce() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine(quitTimeout: 10)
        try w.setUpTwoAccounts(store: engine.store)
        w.set(Paths.claudeBundleID) { $0.exit = .never }
        _ = try? await engine.switchTo(FakeWorld.b)
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        let line = log.split(separator: "\n").first { $0.contains("quit Claude aborted") } ?? ""
        #expect(line.contains("nothing was changed"))
        #expect(line.contains("nothing changed") == false)
    }
}
