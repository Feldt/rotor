import Foundation
import Testing
@testable import ClaudeAccountsCore

private func chrome(_ w: FakeWorld, _ account: String) throws {
    try Fixture.makeCookiesDB(w.paths.chromeCookies, rows: Fixture.chromeCookies(for: account) + Fixture.otherSiteCookies())
    try Fixture.writeExtensionSettings(w.paths.chromeExtensionSettings, account: account)
}

/// Two accounts, Chrome live on A (attested), B with a saved Chrome slot when `bSlot`.
private func setUp(_ w: FakeWorld, _ engine: SwitchEngine, bSlot: Bool, chromeRunning: Bool) throws {
    try w.setUpTwoAccounts(store: engine.store)
    w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("claude.ai account active and logged in", at: t) }
    if bSlot {
        try chrome(w, FakeWorld.b)
        try engine.saveChrome(as: FakeWorld.b)
    }
    try chrome(w, FakeWorld.a)
    try engine.attestChromeAccount(FakeWorld.a)
    w.set(Paths.chromeBundleID) { $0.running = chromeRunning; $0.exit = .after(3) }
}

@Suite("Chrome with Claude")
struct ChromeWithClaudeTests {
    @Test("quits Chrome alongside Claude, swaps both, relaunches both")
    func parallel() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try setUp(w, engine, bSlot: true, chromeRunning: true)
        let o = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        let asked = w.quitRequestedAt.withLock { $0 }
        let chromeAt = try #require(asked[Paths.chromeBundleID]), claudeAt = try #require(asked[Paths.claudeBundleID])
        #expect(chromeAt >= claudeAt)                                   // Claude first
        #expect(chromeAt.timeIntervalSince(claudeAt) <= 2.5)            // as soon as Claude is past its dialog/exit
        #expect(o.chrome == .switched(confirmed: false))
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.b)
        #expect(FileOps.exists(w.paths.slotChromeCookies(FakeWorld.a)))  // outgoing saved
        #expect(w.app(Paths.chromeBundleID).running)                      // relaunched
        #expect(w.app(Paths.claudeBundleID).running)
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        for s in ["chrome: quit requested (with Claude)", "chrome: exited", "chrome: restored", "chrome: relaunch"] {
            #expect(log.contains(s), "missing \(s)")
        }
    }

    @Test("Chrome that won't quit in 20 s: Claude switches anyway; Chrome swaps on quit")
    func chromeTimeout() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try setUp(w, engine, bSlot: true, chromeRunning: true)
        w.set(Paths.chromeBundleID) { $0.exit = .never }
        let o = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        #expect(o.chrome == .deferred)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
        #expect(engine.store.state().pendingChrome == .slot(FakeWorld.b))
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)  // untouched
        #expect(w.app(Paths.chromeBundleID).opens == 0)
    }

    @Test("no Chrome slot: clears claude.ai locally, relaunches Chrome with claude.ai/login, awaits sign-in")
    func noSlot() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try setUp(w, engine, bSlot: false, chromeRunning: true)
        _ = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        let claudeRows = try Fixture.blobs(w.paths.chromeCookies, hostLike: "%claude.ai").filter { $0.hasPrefix("notclaude") == false }
        #expect(claudeRows.isEmpty)
        #expect(try Fixture.blobs(w.paths.chromeCookies).contains(".google.com|SID=google"))  // other sites kept
        #expect(FileOps.exists(w.paths.chromeExtensionSettings) == false)
        #expect(engine.store.state().chromeAccount == nil)               // unknown until the extension reports
        #expect(engine.store.state().chromeAwaitingSignIn == FakeWorld.b)
        #expect(w.openedURLs.withLock { $0 } == [ChromeFollow.loginURL])
        #expect(FileOps.exists(w.paths.slotChromeCookies(FakeWorld.a)))   // A's Chrome login kept
        // The next switch clears the sign-in prompt.
        _ = try await engine.switchTo(FakeWorld.a, chrome: .skip)
        #expect(engine.store.state().chromeAwaitingSignIn == nil)
    }

    @Test("Chrome not running: swaps without launching it")
    func notRunning() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try setUp(w, engine, bSlot: true, chromeRunning: false)
        _ = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.b)
        #expect(w.app(Paths.chromeBundleID).opens == 0)
        #expect(w.app(Paths.chromeBundleID).quitRequests == 0)
    }

    @Test("first enable: no Chrome plan until the account is confirmed; guess from the reader")
    func attribution() throws {
        let w = try FakeWorld()
        var st = StoreState()
        st.chromeFollows = true
        #expect(ChromeFollow.plan(st) == .skip)
        st.chromeAttributionConfirmed = true
        #expect(ChromeFollow.plan(st) == .withClaude)
        st.chromeMode = .whenChromeQuits
        #expect(ChromeFollow.plan(st) == .whenNextQuits)
        try chrome(w, FakeWorld.a)
        let a = Account(id: FakeWorld.a, label: "a", colorIndex: 0, createdAt: Date())
        #expect(ChromeFollow.guess(paths: w.paths, accounts: [a]) == FakeWorld.a)
        #expect(ChromeFollow.guess(paths: w.paths, accounts: []) == nil)
    }

    @Test("tabs warning only when Chrome will restart and doesn't restore tabs")
    func tabs() {
        #expect(ChromeFollow.tabsWarning(plan: .withClaude, isChromeRunning: true, restoresTabs: false))
        #expect(ChromeFollow.tabsWarning(plan: .withClaude, isChromeRunning: true, restoresTabs: true) == false)
        #expect(ChromeFollow.tabsWarning(plan: .withClaude, isChromeRunning: false, restoresTabs: false) == false)
        #expect(ChromeFollow.tabsWarning(plan: .whenNextQuits, isChromeRunning: true, restoresTabs: false) == false)
    }
}

@Suite("Chrome review fixes")
struct ChromeReviewTests {
    @Test("1: seeding a target never clears an outgoing login it couldn't save")
    func seedKeeps() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try chrome(w, FakeWorld.a)                       // Chrome on A, never attested
        w.set(Paths.chromeBundleID) { $0.running = false }
        let before = w.digest(w.paths.chromeCookies)
        let o = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        #expect(o.chrome == .kept(label: "alpha"))
        #expect(w.digest(w.paths.chromeCookies) == before)
        #expect(FileOps.exists(w.paths.chromeExtensionSettings))
        #expect(engine.store.state().chromeAwaitingSignIn == nil)
    }

    @Test("2: after a seed, Chrome stays unattributed until the extension reports the target")
    func attributionAfterSeed() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try setUp(w, engine, bSlot: false, chromeRunning: false)
        _ = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        #expect(engine.store.state().chromeAccount == nil)
        #expect(engine.resolveChromeAttribution() == nil)                  // nothing reported yet
        try chrome(w, FakeWorld.b)                                         // The user signs in as B
        #expect(engine.resolveChromeAttribution() == nil)                  // matched the target
        #expect(engine.store.state().chromeAccount == FakeWorld.b)
        #expect(engine.store.state().chromeAwaitingSignIn == nil)
    }

    @Test("2: a sign-in as a different known account is attributed to that account and reported")
    func attributionOther() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try setUp(w, engine, bSlot: false, chromeRunning: false)
        _ = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        try chrome(w, FakeWorld.a)                                         // signed in as A instead
        #expect(engine.resolveChromeAttribution() == FakeWorld.a)
        #expect(engine.store.state().chromeAccount == FakeWorld.a)
    }

    @Test("2: switching out while still unknown doesn't save it and leaves Chrome as is")
    func switchOutUnknown() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try setUp(w, engine, bSlot: false, chromeRunning: false)
        _ = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        // A login appears but the extension can't tell whose it is.
        try Fixture.makeCookiesDB(w.paths.chromeCookies, rows: Fixture.chromeCookies(for: "someone") + Fixture.otherSiteCookies())
        let before = w.digest(w.paths.chromeCookies)
        let o = try await engine.switchTo(FakeWorld.a, chrome: .withClaude)
        #expect(o.chrome == .kept(label: nil))
        #expect(FileOps.exists(w.paths.slotChromeCookies(FakeWorld.b)) == false)
        #expect(w.digest(w.paths.chromeCookies) == before)
    }

    @Test("3: a failed Chrome swap after Claude switched retries on Chrome's next quit")
    func failedRetries() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try setUp(w, engine, bSlot: true, chromeRunning: true)
        let db = try SQLiteDB(w.paths.chromeCookies, mode: .readWrite)
        try db.exec("UPDATE meta SET value='25' WHERE key='version'")      // import will refuse
        let o = try await engine.switchTo(FakeWorld.b, chrome: .withClaude)
        #expect(o.chrome == .deferred)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
        #expect(engine.store.state().pendingChrome == .slot(FakeWorld.b))
    }

    @Test("4: cancelling in Claude's dialog never touches Chrome")
    func claudeDialogFirst() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine(quitTimeout: 30)
        try setUp(w, engine, bSlot: true, chromeRunning: true)
        w.set(Paths.claudeBundleID) { $0.exit = .never; $0.windowVisible = true }   // dialog up, the user cancels
        await #expect(throws: EngineError.stillRunning("Claude")) { try await engine.switchTo(FakeWorld.b, chrome: .withClaude) }
        #expect(w.app(Paths.chromeBundleID).quitRequests == 0)
        #expect(w.app(Paths.chromeBundleID).running)
    }
}
