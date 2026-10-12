import Foundation
import Testing
@testable import ClaudeAccountsCore

private func successOnOpen(_ w: FakeWorld) {
    w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token, caching", at: t) }
}

private func chrome(_ w: FakeWorld, _ account: String) throws {
    try Fixture.makeCookiesDB(w.paths.chromeCookies, rows: Fixture.chromeCookies(for: account) + Fixture.otherSiteCookies())
    try Fixture.writeExtensionSettings(w.paths.chromeExtensionSettings, account: account)
}

@Suite("Re-review fixes")
struct ReReviewTests {
    // A
    @Test("A: in-flight at backup or save step: recovery clears the record and touches nothing")
    func earlyStepsUntouched() async throws {
        for step in ["backup", "save"] {
            let w = try FakeWorld()
            let engine = w.makeEngine()
            try w.setUpTwoAccounts(store: engine.store)
            w.set(Paths.claudeBundleID) { $0.running = false }
            try engine.store.updateState { $0.inFlight = InFlight(kind: .switchAccount, backupID: "nope", from: nil, to: nil, step: step) }
            let before = w.digest(w.paths.liveCookies)
            #expect(await engine.recoverInterrupted() == nil)
            #expect(w.digest(w.paths.liveCookies) == before)
            #expect(engine.store.state().inFlight == nil)
        }
    }

    @Test("A: an incomplete or size-mismatched backup is never restored")
    func unverifiedBackupRefused() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.set(Paths.claudeBundleID) { $0.running = false }
        let b = try engine.store.makeBackup(reason: "t", from: FakeWorld.a, to: FakeWorld.b, now: w.now)
        #expect(engine.store.isVerified(b.id))
        // Truncated copy: sizes no longer match.
        try Data("x".utf8).write(to: engine.store.backupDir(b.id).appending(path: "Cookies"))
        try engine.store.updateState { $0.inFlight = InFlight(kind: .switchAccount, backupID: b.id, from: nil, to: nil, step: "restore") }
        let before = w.digest(w.paths.liveCookies)
        let m = await engine.recoverInterrupted()
        #expect(m?.contains("incomplete") == true)
        #expect(w.digest(w.paths.liveCookies) == before)
        // No manifest at all (crash mid-backup).
        let id = engine.store.newBackupID(now: w.now.addingTimeInterval(5))
        try FileOps.ensureDirectory(engine.store.backupDir(id))
        try engine.store.updateState { $0.inFlight?.backupID = id }
        #expect(await engine.recoverInterrupted()?.contains("incomplete") == true)
        #expect(w.digest(w.paths.liveCookies) == before)
        #expect(engine.store.backups().map(\.id).contains(id) == false)
    }

    @Test("A: restoring a backup without Cookies never deletes the live Cookies")
    func neverDeletesLiveCookies() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        w.set(Paths.claudeBundleID) { $0.running = false }
        let b = try engine.store.makeBackup(reason: "t", from: FakeWorld.a, to: nil, now: w.now)
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.a))
        try engine.store.updateState { $0.inFlight = InFlight(kind: .add, backupID: b.id, from: nil, to: nil, step: "restore") }
        _ = await engine.recoverInterrupted()
        #expect(FileOps.exists(w.paths.liveCookies))
    }

    @Test("A: the manifest is written last, with the sizes of the copied files")
    func manifestLast() throws {
        let w = try FakeWorld()
        let store = AccountStore(paths: w.paths)
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.a))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        let m = try store.makeBackup(reason: "t", from: nil, to: nil, now: w.now)
        #expect(m.sizes?["Cookies"] == FileOps.size(w.paths.liveCookies))
        #expect(m.sizes?["config.json"] == FileOps.size(w.paths.liveConfig))
    }

    // B
    @Test("B: Restore backup after a half-swap doesn't save the live cookie into config's account")
    func restoreAfterHalfSwapSkipsSave() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let live = w.paths.liveCookies
        w.reappearsWhen[Paths.claudeBundleID] = {
            ((try? Fixture.blobs(live)) ?? []).contains { $0.contains("v3-\(FakeWorld.b)") }
        }
        var bid = ""
        do { _ = try await engine.switchTo(FakeWorld.b) } catch EngineError.restoreFailed(let id) { bid = id }
        w.reappearsWhen[Paths.claudeBundleID] = nil
        // Live now: B's cookie, config still A. A's slot was saved before the swap; keep it intact.
        let slotA = try Fixture.blobs(w.paths.slotDesktopCookies(FakeWorld.a))
        _ = try await engine.rollback(bid)
        #expect(try Fixture.blobs(w.paths.slotDesktopCookies(FakeWorld.a)) == slotA)
        #expect(slotA.contains { $0.contains("v3-\(FakeWorld.a)") })
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.a)
        #expect(try Fixture.blobs(w.paths.liveCookies).contains { $0.contains("v3-\(FakeWorld.a)") })
    }

    @Test("B: a live cookie that matches another account's saved login is never saved under config's account")
    func fingerprintGuard() throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.set(Paths.claudeBundleID) { $0.running = false }
        try FileOps.copyAtomically(w.paths.slotDesktopCookies(FakeWorld.b), to: w.paths.liveCookies)
        _ = try engine.saveCurrentDesktop()
        #expect(FileOps.exists(w.paths.slotDesktopCookies(FakeWorld.a)) == false)
    }

    // C
    @Test("C: repeated Chrome failures rotate only Chrome backups, never desktop ones")
    func chromeRotationSeparate() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try chrome(w, FakeWorld.b)
        try engine.saveChrome(as: FakeWorld.b)
        try chrome(w, FakeWorld.a)
        let o = try await engine.switchTo(FakeWorld.b, chrome: .skip)
        let desktop = engine.store.backups().map(\.id)
        #expect(desktop == [o.backupID])
        // A schema change makes every retry fail.
        let db = try SQLiteDB(w.paths.chromeCookies, mode: .readWrite)
        try db.exec("UPDATE meta SET value='25' WHERE key='version'")
        try engine.store.updateState { $0.pendingChrome = .slot(FakeWorld.b) }
        for i in 0..<14 {
            w.advance(Double(i + 1))
            _ = try await engine.applyPendingChrome()
        }
        #expect(engine.store.state().pendingChrome == .slot(FakeWorld.b))
        #expect(engine.store.backups().map(\.id) == desktop)
        #expect(engine.store.chromeBackups().count <= 10)
    }

    // #3 remainder
    @Test("#3: if the extension-folder rename fails, the cookie rename is undone")
    func unitCommit() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try chrome(w, FakeWorld.b)
        try engine.saveChrome(as: FakeWorld.b)
        try chrome(w, FakeWorld.a)
        try engine.attestChromeAccount(FakeWorld.a)
        let liveA = try Fixture.blobs(w.paths.chromeCookies)
        let parent = w.paths.chromeExtensionSettings.deletingLastPathComponent()
        try FileOps.setMode(parent, 0o500)
        defer { try? FileOps.setMode(parent, 0o700) }
        let r = await engine.swapChromeNow(to: FakeWorld.b, backupID: nil)
        try FileOps.setMode(parent, 0o700)
        guard case .failed = r else { Issue.record("expected failure, got \(r)"); return }
        #expect(try Fixture.blobs(w.paths.chromeCookies) == liveA)
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)
        #expect(engine.store.state().chromeAccount == FakeWorld.a)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: w.paths.chromeProfile.path)
            .filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test("Also switch Chrome is off in a fresh state")
    func chromeOffByDefault() throws {
        let w = try FakeWorld()
        #expect(AccountStore(paths: w.paths).state().chromeFollows == false)
    }
}

@Suite("Sync health")
struct SyncHealthTests {
    let now = Date()
    func status(_ ago: Double?, unwatched: Int = 5) -> SyncStatus {
        SyncStatus(lastPass: ago.map { now.addingTimeInterval(-$0) }, unwatched: unwatched, isAvailable: true)
    }

    @Test("unwatched stores and a recent pass are healthy")
    func healthy() {
        #expect(SyncHealth.check(status: status(120, unwatched: 9), agentLoaded: true, claudeRunning: true, lastSyncFailed: false, now: now) == .ok)
        // Old pass while Claude is closed is fine: nothing to sync.
        #expect(SyncHealth.check(status: status(7200), agentLoaded: true, claudeRunning: false, lastSyncFailed: false, now: now) == .ok)
        // No sync installed: no UI.
        #expect(SyncHealth.check(status: SyncStatus(lastPass: nil, unwatched: 0, isAvailable: false), agentLoaded: false,
                                 claudeRunning: true, lastSyncFailed: true, now: now) == .ok)
    }

    @Test("broken: agent not loaded, pass older than 30 min while Claude runs, or the pre-switch pass failed")
    func broken() {
        #expect(SyncHealth.check(status: status(60), agentLoaded: false, claudeRunning: true, lastSyncFailed: false, now: now) != .ok)
        #expect(SyncHealth.check(status: status(31 * 60), agentLoaded: true, claudeRunning: true, lastSyncFailed: false, now: now) != .ok)
        #expect(SyncHealth.check(status: status(60), agentLoaded: true, claudeRunning: true, lastSyncFailed: true, now: now) != .ok)
    }

    @Test("the pre-switch sync result is recorded")
    func recorded() async throws {
        let w = try FakeWorld()
        let engine = SwitchEngine(paths: w.paths, probe: FakeProbe(world: w), controller: FakeController(world: w),
                                  ticker: FakeTicker(world: w), sync: FakeSync(failure: "exit 1"), verifyTimeout: 2)
        try w.setUpTwoAccounts(store: engine.store)
        _ = try await engine.switchTo(FakeWorld.b)
        #expect(engine.store.state().lastSyncFailed == true)
    }
}

@Suite("OAuth cache slot save")
struct OAuthSlotSaveTests {
    private func successOnOpen(_ w: FakeWorld) {
        w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token, caching", at: t) }
    }

    @Test("the encrypted oauth cache is saved to the outgoing slot, with a .prev, on a switch")
    func savedOnSwitch() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a,
                                extra: ["oauth:tokenCacheV2": "v10BLOBA"])
        _ = try await engine.switchTo(FakeWorld.b)
        let slot = w.paths.slotOAuthCache(FakeWorld.a)
        #expect(FileOps.exists(slot))
        #expect(String(decoding: try Data(contentsOf: slot), as: UTF8.self) == "v10BLOBA")
        #expect(FileOps.mode(slot) == 0o600)
        // Switch back (now on B): B's cache is saved, and A's prev is created on the next save to A.
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.b, extra: ["oauth:tokenCacheV2": "v10BLOBB"])
        _ = try await engine.switchTo(FakeWorld.a)
        #expect(String(decoding: try Data(contentsOf: w.paths.slotOAuthCache(FakeWorld.b)), as: UTF8.self) == "v10BLOBB")
        // Switch away from A again with a changed cache: A's prior blob moves to .prev.
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a, extra: ["oauth:tokenCacheV2": "v10BLOBA2"])
        _ = try await engine.switchTo(FakeWorld.b)
        let prev = w.paths.slotOAuthCache(FakeWorld.a).deletingLastPathComponent().appending(path: "oauth-cache-v2.prev")
        #expect(String(decoding: try Data(contentsOf: prev), as: UTF8.self) == "v10BLOBA")
        #expect(String(decoding: try Data(contentsOf: w.paths.slotOAuthCache(FakeWorld.a)), as: UTF8.self) == "v10BLOBA2")
    }

    @Test("not saved when attribution is uncertain (live cookie belongs to another account)")
    func notSavedWhenUncertain() throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.set(Paths.claudeBundleID) { $0.running = false }
        // Live cookie is B's login, config says A. saveDesktop refuses, so no oauth copy either.
        try FileOps.copyAtomically(w.paths.slotDesktopCookies(FakeWorld.b), to: w.paths.liveCookies)
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a, extra: ["oauth:tokenCacheV2": "v10BLOBA"])
        _ = try engine.saveCurrentDesktop()
        #expect(FileOps.exists(w.paths.slotOAuthCache(FakeWorld.a)) == false)
    }

    @Test("not saved when there is no cache in the live config")
    func notSavedWhenAbsent() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        // setUpTwoAccounts writes a config with oauth caches; strip them.
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        var cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: w.paths.liveConfig)) as! [String: Any]
        cfg.removeValue(forKey: "oauth:tokenCacheV2")
        cfg.removeValue(forKey: "oauth:tokenCache")
        try JSONSerialization.data(withJSONObject: cfg).write(to: w.paths.liveConfig)
        _ = try await engine.switchTo(FakeWorld.b)
        #expect(FileOps.exists(w.paths.slotOAuthCache(FakeWorld.a)) == false)
    }
}
