import Foundation
import Testing
@testable import ClaudeAccountsCore

private func setUpChrome(_ w: FakeWorld, live account: String) throws {
    try Fixture.makeCookiesDB(w.paths.chromeCookies, rows: Fixture.chromeCookies(for: account) + Fixture.otherSiteCookies())
    try Fixture.writeExtensionSettings(w.paths.chromeExtensionSettings, account: account)
}

private func successOnOpen(_ w: FakeWorld) {
    w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token, caching", at: t) }
}

@Suite("Claude in Chrome")
struct ChromeTests {
    @Test("export copies only claude.ai-family rows with blobs intact; import replaces only those")
    func rowExportImport() throws {
        let w = try FakeWorld()
        try setUpChrome(w, live: FakeWorld.a)
        let slot = w.paths.slotChromeCookies(FakeWorld.a)
        let n = try CookieDB.exportFamilyRows(from: w.paths.chromeCookies, to: slot)
        #expect(n == 3)
        #expect(try Fixture.blobs(slot) == [
            ".claude.ai|sessionKey=chrome-\(FakeWorld.a)",
            "app.claude.ai|x=sub-\(FakeWorld.a)",
            "claude.ai|g_state=g-\(FakeWorld.a)",
        ])
        #expect(try CookieDB.columns(slot) == CookieDB.columns(w.paths.chromeCookies))
        #expect(FileOps.mode(slot) == 0o600)

        // Chrome now holds B's login; importing A's slot brings A back and leaves other sites alone.
        try Fixture.makeCookiesDB(w.paths.chromeCookies, rows: Fixture.chromeCookies(for: FakeWorld.b) + Fixture.otherSiteCookies())
        let others = try Fixture.blobs(w.paths.chromeCookies).filter { $0.contains("claude.ai|") == false }
        try CookieDB.importFamilyRows(from: slot, into: w.paths.chromeCookies)
        let after = try Fixture.blobs(w.paths.chromeCookies)
        #expect(after.filter { $0.contains("claude.ai|") == false } == others)
        #expect(after.contains("notclaude.ai|n=lookalike"))
        #expect(after.filter { $0.contains("claude.ai|") && $0.hasPrefix("notclaude") == false }.allSatisfy { $0.hasSuffix(FakeWorld.a) })
        #expect(after.contains { $0.hasSuffix(FakeWorld.b) } == false)
        #expect(CookieDB.sessionExpiry(slot) != nil)
    }

    @Test("import refuses a slot with a different schema and changes nothing")
    func schemaMismatch() throws {
        let w = try FakeWorld()
        try setUpChrome(w, live: FakeWorld.a)
        let odd = w.root.appending(path: "odd.sqlite")
        try Fixture.makeCookiesDB(odd, rows: [], schema: "CREATE TABLE meta(key, value); CREATE TABLE cookies(host_key TEXT, name TEXT, extra INTEGER);")
        let before = try Fixture.blobs(w.paths.chromeCookies)
        #expect(throws: EngineError.self) { try CookieDB.importFamilyRows(from: odd, into: w.paths.chromeCookies) }
        #expect(try Fixture.blobs(w.paths.chromeCookies) == before)
    }

    @Test("extension settings dir swaps with the account, and its uuid reads back")
    func extensionDirSwap() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        // B's Chrome slot, saved earlier.
        try setUpChrome(w, live: FakeWorld.b)
        try engine.saveChrome(as: FakeWorld.b)
        #expect(engine.store.account(FakeWorld.b)?.chrome?.extensionAccountUuid == FakeWorld.b)
        // Chrome is now on A, as the user attested in the panel.
        try setUpChrome(w, live: FakeWorld.a)
        try engine.attestChromeAccount(FakeWorld.a)
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)

        let o = try await engine.switchTo(FakeWorld.b, chrome: .ifClosed)
        #expect(o.chrome == .switched(confirmed: false))
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.b)
        #expect(try Fixture.blobs(w.paths.chromeCookies, hostLike: "%claude.ai").filter { $0.hasPrefix("notclaude") == false }.allSatisfy { $0.hasSuffix(FakeWorld.b) })
        // A's Chrome login was saved on the way out.
        #expect(ExtensionSettings.accountUuid(in: w.paths.slotChromeExtension(FakeWorld.a)) == FakeWorld.a)
        #expect(engine.store.state().chromeAccount == FakeWorld.b)
        #expect(engine.store.manifest(o.backupID)?.chromeBackupID != nil)
        #expect(w.app(Paths.chromeBundleID).opens == 0)

        // And back: A's Chrome login returns.
        let back = try await engine.switchTo(FakeWorld.a, chrome: .ifClosed)
        #expect(back.chrome == .switched(confirmed: false))
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)
    }

    @Test("Chrome running: 'when Chrome next quits' defers, then swaps on exit and leaves it closed")
    func deferredSwap() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try setUpChrome(w, live: FakeWorld.b)
        try engine.saveChrome(as: FakeWorld.b)
        try setUpChrome(w, live: FakeWorld.a)
        try engine.attestChromeAccount(FakeWorld.a)
        w.set(Paths.chromeBundleID) { $0.running = true }

        let o = try await engine.switchTo(FakeWorld.b, chrome: .whenNextQuits)
        #expect(o.chrome == .deferred)
        #expect(engine.store.state().pendingChrome == .slot(FakeWorld.b))
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)
        await #expect(throws: EngineError.chromeNotClosed) { try await engine.applyPendingChrome() }

        w.set(Paths.chromeBundleID) { $0.running = false }
        let r = try await engine.applyPendingChrome()
        #expect(r == .switched(confirmed: false))
        #expect(engine.store.state().pendingChrome == nil)
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.b)
        #expect(w.app(Paths.chromeBundleID).running == false)
    }

    @Test("Chrome running: 'Restart Chrome now' quits politely, swaps, reopens and verifies")
    func restartNow() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try setUpChrome(w, live: FakeWorld.b)
        try engine.saveChrome(as: FakeWorld.b)
        try setUpChrome(w, live: FakeWorld.a)
        try engine.attestChromeAccount(FakeWorld.a)
        w.set(Paths.chromeBundleID) {
            $0.running = true
            $0.exit = .after(3)
        }
        // After reopening, the extension signs in and writes its storage.
        let ext = w.paths.chromeExtensionSettings
        w.onOpen[Paths.chromeBundleID] = { [unowned w] t in
            try? Fixture.writeExtensionSettings(ext, account: FakeWorld.b)
            try? FileManager.default.setAttributes([.modificationDate: t.addingTimeInterval(2)],
                                                   ofItemAtPath: ext.appending(path: "000003.log").path)
            _ = w
        }
        let o = try await engine.switchTo(FakeWorld.b, chrome: .restartNow)
        #expect(o.chrome == .switched(confirmed: true))
        #expect(w.app(Paths.chromeBundleID).running)
        #expect(w.app(Paths.chromeBundleID).opens == 1)
        #expect(w.app(Paths.chromeBundleID).quitRequests == 1)
    }

    @Test("Chrome that won't quit keeps the swap pending instead of forcing it")
    func chromeWontQuit() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try setUpChrome(w, live: FakeWorld.b)
        try engine.saveChrome(as: FakeWorld.b)
        try setUpChrome(w, live: FakeWorld.a)
        try engine.attestChromeAccount(FakeWorld.a)
        w.set(Paths.chromeBundleID) {
            $0.running = true
            $0.exit = .never
        }
        let o = try await engine.switchTo(FakeWorld.b, chrome: .restartNow)
        #expect(o.chrome == .deferred)
        #expect(engine.store.state().pendingChrome == .slot(FakeWorld.b))
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)
        // The desktop switch itself still happened.
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
    }

    @Test("account without a Chrome slot switches the desktop only")
    func notSetUp() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try setUpChrome(w, live: FakeWorld.a)
        let before = try Fixture.blobs(w.paths.chromeCookies)
        let o = try await engine.switchTo(FakeWorld.b, chrome: .ifClosed)
        #expect(o.chrome == .notSetUp)
        #expect(try Fixture.blobs(w.paths.chromeCookies) == before)
    }

    @Test("Add account seeds Chrome: clears claude.ai and the extension, then saves the new login at next quit")
    func seedChrome() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try setUpChrome(w, live: FakeWorld.a)
        try engine.attestChromeAccount(FakeWorld.a)
        try await engine.beginAdd(label: "gamma@example.com", chrome: .ifClosed)
        #expect(try Fixture.blobs(w.paths.chromeCookies, hostLike: "%claude.ai").filter { $0.hasPrefix("notclaude") == false }.isEmpty)
        #expect(try Fixture.blobs(w.paths.chromeCookies).contains(".google.com|SID=google"))
        #expect(FileOps.exists(w.paths.chromeExtensionSettings) == false)
        #expect(w.app(Paths.chromeBundleID).opens == 1)
        #expect(engine.store.state().pendingChrome == .saveSignedIn)
        // A's Chrome login was kept.
        #expect(FileOps.exists(w.paths.slotChromeCookies(FakeWorld.a)))

        // The user signs in to the desktop app and in Chrome, then quits Chrome.
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.c))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.c)
        _ = try engine.completeAdd()
        try setUpChrome(w, live: FakeWorld.c)
        w.set(Paths.chromeBundleID) { $0.running = false }
        let r = try await engine.applyPendingChrome()
        #expect(r == .switched(confirmed: false))
        #expect(engine.store.account(FakeWorld.c)?.chrome?.extensionAccountUuid == FakeWorld.c)
        #expect(engine.store.state().chromeAccount == FakeWorld.c)
        #expect(engine.store.state().pendingChrome == nil)
    }

    @Test("rollback restores Chrome's claude.ai rows and extension settings too")
    func rollbackChrome() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try setUpChrome(w, live: FakeWorld.b)
        try engine.saveChrome(as: FakeWorld.b)
        try setUpChrome(w, live: FakeWorld.a)
        try engine.attestChromeAccount(FakeWorld.a)
        let chromeA = try Fixture.blobs(w.paths.chromeCookies)
        let o = try await engine.switchTo(FakeWorld.b, chrome: .ifClosed)
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.b)
        let r = try await engine.rollback(o.backupID)
        #expect(r.chrome == .switched(confirmed: false))
        #expect(try Fixture.blobs(w.paths.chromeCookies) == chromeA)
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)
    }

    @Test("restore-on-startup reads Chrome's Preferences without editing them")
    func restoreOnStartup() throws {
        let w = try FakeWorld()
        try JSONSerialization.data(withJSONObject: ["session": ["restore_on_startup": 1]]).write(to: w.paths.chromePreferences)
        #expect(ChromePreferences.restoresTabs(w.paths.chromePreferences))
        try JSONSerialization.data(withJSONObject: ["profile": [:]]).write(to: w.paths.chromePreferences)
        #expect(ChromePreferences.restoresTabs(w.paths.chromePreferences) == false)
    }
}

@Suite("Readers and guards")
struct ReaderTests {
    @Test("busy heuristic: fresh transcripts not at end of turn count as working")
    func busy() throws {
        let w = try FakeWorld()
        let dir = w.paths.claudeProjects.appending(path: "-Users-x-proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let idle = """
        {"type":"user","message":{"role":"user"}}
        {"type":"assistant","message":{"stop_reason":"end_turn"}}
        {"type":"attachment"}
        {"type":"system","subtype":"stop_hook_summary"}
        """
        let working = """
        {"type":"assistant","message":{"stop_reason":"tool_use"}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}
        """
        try Data(idle.utf8).write(to: dir.appending(path: "idle.jsonl"))
        try Data(working.utf8).write(to: dir.appending(path: "busy.jsonl"))
        try FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: true)
        try Data(working.utf8).write(to: dir.appending(path: "sub/old.jsonl"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                                              ofItemAtPath: dir.appending(path: "sub/old.jsonl").path)
        #expect(BusyCheck.workingChats(projects: w.paths.claudeProjects, now: Date()) == 1)
        #expect(BusyCheck.isIdle(transcriptTail: Data(idle.utf8)))
        #expect(BusyCheck.isIdle(transcriptTail: Data(working.utf8)) == false)
    }

    @Test("sync status reads the last sync.log line")
    func syncStatus() throws {
        let w = try FakeWorld()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let t = Date().addingTimeInterval(-12)
        let log = """
        2026-01-01 00:00:00 stores=1 unwatched=0 secs=0.1
        \(f.string(from: t)) stores=51 union_cards=2134 pending_writes=0 unwatched=2 secs=0.4

        """
        try Data(log.utf8).write(to: w.paths.syncLog)
        let s = SyncStatus.read(w.paths.syncLog)
        #expect(s.unwatched == 2)
        #expect(abs((s.lastPass?.timeIntervalSince(t) ?? 99)) < 1)
        #expect(s.needsAttention(now: Date()))
        #expect(s.isStale(now: Date()) == false)
        #expect(SyncStatus.read(w.root.appending(path: "nope.log")).isAvailable == false)
    }

    @Test("login health thresholds")
    func health() {
        let now = Date()
        #expect(LoginHealth.of(now.addingTimeInterval(26.5 * 86_400), now: now) == .ok(days: 26))
        #expect(LoginHealth.of(now.addingTimeInterval(5.2 * 86_400), now: now) == .expiringSoon(days: 5))
        #expect(LoginHealth.of(now.addingTimeInterval(-1), now: now) == .expired)
        #expect(LoginHealth.of(nil, now: now) == .unknown)
    }

    @Test("real paths are detected; fully overridden paths are not")
    func realPathGuard() throws {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(Paths.realDefaults(home: home).touchesRealData(home: home))
        let partial = Paths.fromEnvironment(["CLAUDE_ACCOUNTS_ROOT": "/tmp/x"], home: home)
        #expect(partial.touchesRealData(home: home))
        let fake = Paths.fromEnvironment([
            "CLAUDE_ACCOUNTS_ROOT": "/tmp/f/store", "CLAUDE_USERDATA_DIR": "/tmp/f/Claude",
            "CHROME_PROFILE_DIR": "/tmp/f/Chrome", "SESSION_SYNC_DIR": "/tmp/f/sync",
        ], home: home)
        #expect(fake.touchesRealData(home: home) == false)
        #expect(fake.liveCookies.path == "/tmp/f/Claude/Cookies")
    }

    @Test("launch log verdict reads only what was written after the launch offset")
    func launchLog() throws {
        let w = try FakeWorld()
        w.logLine("not_logged_in", at: Date().addingTimeInterval(-120))   // before launch
        let offset = LaunchLog.offset(w.paths.mainLog)
        #expect(LaunchLog.verdict(mainLog: w.paths.mainLog, from: offset, target: FakeWorld.a, now: Date()) == .pending)
        w.logLine("[oauth] obtained new token, caching", at: Date())
        #expect(LaunchLog.verdict(mainLog: w.paths.mainLog, from: offset, target: FakeWorld.a, now: Date()) == .success)
    }

    @Test("the quit coordinator ignores Chrome's native host and ShipIt inside Claude.app")
    func ignoredHelpers() async throws {
        let w = try FakeWorld()
        w.set(Paths.claudeBundleID) { $0.running = false }
        let q = QuitCoordinator(probe: FakeProbe(world: w), controller: FakeController(world: w), ticker: FakeTicker(world: w))
        #expect(await q.isRunning(.claude(w.paths)) == false)
        #expect(w.processes().count == 2)
    }
}
