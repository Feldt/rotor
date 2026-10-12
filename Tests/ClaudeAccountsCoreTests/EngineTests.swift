import Foundation
import Testing
@testable import ClaudeAccountsCore

private func successOnOpen(_ w: FakeWorld) {
    w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token for account, caching", at: t) }
}

@Suite("Desktop switch")
struct DesktopSwitchTests {
    @Test("save/restore round trip")
    func roundTrip() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let liveA = try Fixture.blobs(w.paths.liveCookies)

        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .success)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
        #expect(try Fixture.blobs(w.paths.liveCookies) == Fixture.blobs(w.paths.slotDesktopCookies(FakeWorld.b)))
        #expect(try Fixture.blobs(w.paths.slotDesktopCookies(FakeWorld.a)) == liveA)
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(w.app(Paths.claudeBundleID).opens == 1)
        #expect(engine.store.account(FakeWorld.a)?.desktop?.cookieExpiresAt != nil)
        #expect(engine.store.account(FakeWorld.b)?.lastUsedAt != nil)
        #expect(FileOps.exists(w.paths.liveCookiesJournal) == false)

        // And back again: A's original login returns intact.
        let back = try await engine.switchTo(FakeWorld.a)
        #expect(back.verdict == .success)
        #expect(try Fixture.blobs(w.paths.liveCookies) == liveA)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.a)
    }

    @Test("config edit keeps other keys and drops both oauth caches")
    func configEdit() throws {
        let w = try FakeWorld()
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: w.paths.liveConfig)) as! [String: Any]
        try ClaudeConfig.rewrite(w.paths.liveConfig, account: FakeWorld.b)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: w.paths.liveConfig)) as! [String: Any]
        #expect(after["lastKnownAccountUuid"] as? String == FakeWorld.b)
        #expect(after["oauth:tokenCache"] == nil)
        #expect(after["oauth:tokenCacheV2"] == nil)
        let kept = Set(before.keys).subtracting(ClaudeConfig.oauthKeys)
        #expect(Set(after.keys) == kept)
        #expect(after["windowControlsZoomFactor"] as? Double == 1.25)
        #expect(after["dxt:allowlistEnabled:abc"] as? Bool == true)
        #expect(after["locale"] as? String == "en-US")
        #expect(FileOps.mode(w.paths.liveConfig) == 0o600)
    }

    @Test("a leftover config.json.journal is deleted after exit, before config.json is written")
    func journalHandling() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let journal = w.paths.liveConfigJournal
        let cookiesJournal = w.paths.liveCookiesJournal
        w.onExit[Paths.claudeBundleID] = {
            try? Data("deadbeef - .\n{\"lastKnownAccountUuid\":\"\(FakeWorld.a)\"}".utf8).write(to: journal)
            try? Data("x".utf8).write(to: cookiesJournal)
        }
        // The cookie journal empties a few seconds after exit, as Chromium's does.
        w.afterExit[Paths.claudeBundleID] = (4, { try? Data().write(to: cookiesJournal) })
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .success)
        #expect(FileOps.exists(journal) == false)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
    }

    @Test("a cookie journal that never empties aborts with nothing changed")
    func cookieJournalNeverSettles() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        let cookiesJournal = w.paths.liveCookiesJournal
        w.onExit[Paths.claudeBundleID] = { try? Data("x".utf8).write(to: cookiesJournal) }
        let liveBefore = w.digest(w.paths.liveCookies)
        let configBefore = w.digest(w.paths.liveConfig)
        await #expect(throws: EngineError.notClean("Claude")) { try await engine.switchTo(FakeWorld.b) }
        #expect(w.digest(w.paths.liveCookies) == liveBefore)
        #expect(w.digest(w.paths.liveConfig) == configBefore)
        #expect(engine.store.backups().isEmpty)
    }

    @Test("Claude still running after the wait: abort, change nothing, never force-kill")
    func refusesWhileRunning() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.set(Paths.claudeBundleID) { $0.exit = .never }
        let liveBefore = w.digest(w.paths.liveCookies)
        let configBefore = w.digest(w.paths.liveConfig)
        let box = TaskBox()
        let start = w.now
        await #expect(throws: EngineError.stillRunning("Claude")) {
            try await engine.switchTo(FakeWorld.b) { box.record($0) }
        }
        #expect(box.seen.contains(.claudeAsking))
        #expect(box.seen.contains(.saving) == false)
        #expect(w.digest(w.paths.liveCookies) == liveBefore)
        #expect(w.digest(w.paths.liveConfig) == configBefore)
        #expect(FileOps.exists(w.paths.slotDesktopCookies(FakeWorld.a)) == false)
        #expect(engine.store.backups().isEmpty)
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(w.app(Paths.claudeBundleID).opens == 0)
        #expect(w.now.timeIntervalSince(start) >= 119)
    }

    @Test("slow exit with a lingering claude-code child still switches")
    func slowExit() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        w.set(Paths.claudeBundleID) {
            $0.exit = .after(70)
            $0.childLinger = 10
        }
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .success)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
    }

    @Test("Claude's quit dialog, then Cancel here: nothing changes")
    func quitDialogCancel() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.set(Paths.claudeBundleID) { $0.exit = .never }
        let liveBefore = w.digest(w.paths.liveCookies)
        let box = TaskBox()
        let start = w.now
        let task = Task {
            try await engine.switchTo(FakeWorld.b) { phase in
                box.record(phase)
                if phase == .claudeAsking { box.lock.withLock { box.task }?.cancel() }
            }
        }
        box.lock.withLock { box.task = task }
        await #expect(throws: EngineError.cancelled) { try await task.value }
        #expect(w.digest(w.paths.liveCookies) == liveBefore)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.a)
        #expect(engine.store.backups().isEmpty)
        #expect(w.now.timeIntervalSince(start) < 100)
    }

    @Test("Claude's quit dialog, then Quit anyway in Claude: switch completes")
    func quitDialogQuitAnyway() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        w.set(Paths.claudeBundleID) { $0.exit = .after(25) }
        let box = TaskBox()
        let o = try await engine.switchTo(FakeWorld.b) { box.record($0) }
        #expect(box.seen.contains(.claudeAsking))
        #expect(o.verdict == .success)
    }

    @Test("shape mismatch refuses before quitting anything")
    func shapeMismatch() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try Fixture.writeConfig(w.paths.liveConfig, account: nil)
        await #expect(throws: EngineError.self) { try await engine.switchTo(FakeWorld.b) }
        #expect(w.app(Paths.claudeBundleID).quitRequests == 0)

        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.otherSiteCookies())
        do {
            _ = try await engine.switchTo(FakeWorld.b)
            Issue.record("expected a refusal")
        } catch let e as EngineError {
            guard case .shapeMismatch = e else { Issue.record("wrong error \(e)"); return }
        }
        // A changed Cookies schema also refuses.
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: [], schema: "CREATE TABLE meta(key, value); CREATE TABLE cookies(host_key TEXT, name TEXT);")
        await #expect(throws: EngineError.self) { try await engine.switchTo(FakeWorld.b) }
        #expect(w.app(Paths.claudeBundleID).quitRequests == 0)
        #expect(engine.store.backups().isEmpty)
    }

    @Test("verify catches a sign-in failure in main.log")
    func verifyFailure() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.logLine("not_logged_in from an earlier launch", at: w.now.addingTimeInterval(-3600))
        w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] not_logged_in", at: t.addingTimeInterval(2)) }
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .failure("not_logged_in"))
    }

    @Test("no saved login, unknown or current target refuse")
    func refusals() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        await #expect(throws: EngineError.unknownAccount(FakeWorld.c)) { try await engine.switchTo(FakeWorld.c) }
        await #expect(throws: EngineError.alreadyCurrent) {
            try Fixture.makeCookiesDB(w.paths.slotDesktopCookies(FakeWorld.a), rows: Fixture.desktopCookies(for: FakeWorld.a))
            return try await engine.switchTo(FakeWorld.a)
        }
        try engine.store.register(FakeWorld.c, label: "c", now: w.now)
        await #expect(throws: EngineError.noSavedLogin(FakeWorld.c)) { try await engine.switchTo(FakeWorld.c) }
        #expect(w.app(Paths.claudeBundleID).quitRequests == 0)
    }

    @Test("an unknown outgoing account is registered as Unnamed and saved")
    func unknownOutgoing() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.c)
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.registeredOutgoing == FakeWorld.c)
        #expect(engine.store.account(FakeWorld.c)?.needsLabel == true)
        #expect(FileOps.exists(w.paths.slotDesktopCookies(FakeWorld.c)))
    }

    @Test("chat sync runs before quitting; a failure only warns")
    func chatSync() async throws {
        let w = try FakeWorld()
        let sync = FakeSync(failure: "mirror.py exited 1")
        let engine = SwitchEngine(paths: w.paths, probe: FakeProbe(world: w), controller: FakeController(world: w),
                                  ticker: FakeTicker(world: w), sync: sync, verifyTimeout: 5)
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.syncWarning == "mirror.py exited 1")
        #expect(sync.calls.withLock { $0 } == [[]])
    }
}

@Suite("Backups and rollback")
struct BackupTests {
    @Test("rollback restores the pre-switch files and backs up the current ones first")
    func rollback() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let liveA = try Fixture.blobs(w.paths.liveCookies)
        let configA = try Data(contentsOf: w.paths.liveConfig)
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)

        let r = try await engine.rollback(o.backupID)
        #expect(try Fixture.blobs(w.paths.liveCookies) == liveA)
        #expect(try Data(contentsOf: w.paths.liveConfig) == configA)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.a)
        #expect(r.verdict == .success)
        #expect(w.app(Paths.claudeBundleID).running)
        let backups = engine.store.backups()
        #expect(backups.count == 2)
        #expect(backups.first?.reason.hasPrefix("before rollback") == true)
        // The rollback itself can be undone.
        _ = try await engine.rollback(r.backupID)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
    }

    @Test("rollback while Claude won't quit changes nothing")
    func rollbackRefusesWhileRunning() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let o = try await engine.switchTo(FakeWorld.b)
        w.set(Paths.claudeBundleID) { $0.exit = .never }
        let before = w.digest(w.paths.liveCookies)
        await #expect(throws: EngineError.stillRunning("Claude")) { try await engine.rollback(o.backupID) }
        #expect(w.digest(w.paths.liveCookies) == before)
        #expect(engine.store.backups().count == 1)
    }

    @Test("rotation keeps the newest 10 and never deletes a protected backup")
    func rotation() throws {
        let w = try FakeWorld()
        let store = AccountStore(paths: w.paths)
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.a))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        var ids: [String] = []
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<13 {
            ids.append(try store.makeBackup(reason: "t\(i)", from: nil, to: nil, now: base.addingTimeInterval(Double(i))).id)
        }
        let kept = store.backups().map(\.id)
        #expect(kept.count == 10)
        #expect(kept == Array(ids.suffix(10).reversed()))
        let oldest = kept.last!
        _ = try store.makeBackup(reason: "protect", from: nil, to: nil, protecting: [oldest], now: base.addingTimeInterval(100))
        #expect(store.backups().map(\.id).contains(oldest))
        #expect(FileOps.exists(store.backupDir(oldest).appending(path: "Cookies")))
    }

    @Test("store directories are 0700 and files 0600")
    func permissions() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        _ = try await engine.switchTo(FakeWorld.b)
        let fm = FileManager.default
        var checked = 0
        let all = (fm.enumerator(at: w.paths.storeRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for url in all {
            #expect(FileOps.mode(url) == (FileOps.isDirectory(url) ? 0o700 : 0o600), "\(url.lastPathComponent)")
            checked += 1
        }
        #expect(FileOps.mode(w.paths.storeRoot) == 0o700)
        #expect(FileOps.mode(w.paths.liveCookies) == 0o600)
        #expect(checked > 6)
    }
}

@Suite("Add account")
struct AddAccountTests {
    @Test("add removes the live login locally, then registers the new uuid with its label")
    func addFlow() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        let liveA = try Fixture.blobs(w.paths.liveCookies)
        let box = TaskBox()
        try await engine.beginAdd(label: "gamma@example.com") { box.record($0) }
        #expect(box.seen.last == .waitingForSignIn)
        #expect(FileOps.exists(w.paths.liveCookies) == false)
        #expect(try Fixture.blobs(w.paths.slotDesktopCookies(FakeWorld.a)) == liveA)
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: w.paths.liveConfig)) as! [String: Any]
        #expect(cfg["oauth:tokenCache"] == nil)
        #expect(cfg["lastKnownAccountUuid"] as? String == FakeWorld.a)
        #expect(try engine.completeAdd() == .waiting)

        // The user signs in: Claude writes a new login and names the account.
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.c))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.c)
        guard case .added(let added) = try engine.completeAdd() else { Issue.record("not added"); return }
        #expect(added.id == FakeWorld.c)
        #expect(added.label == "gamma@example.com")
        #expect(engine.store.state().pendingAddLabel == nil)
        // The sync label map names it.
        let map = try JSONSerialization.jsonObject(with: Data(contentsOf: w.paths.syncAccountsFile)) as! [String: String]
        #expect(map[FakeWorld.c] == "gamma@example.com")

        // It's saved on the next switch away.
        successOnOpen(w)
        _ = try await engine.switchTo(FakeWorld.b)
        #expect(FileOps.exists(w.paths.slotDesktopCookies(FakeWorld.c)))
    }

    @Test("first run registers the live account as Unnamed, needing a label")
    func firstRun() throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.a))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        let a = try engine.registerCurrentIfNeeded()
        #expect(a?.needsLabel == true)
        #expect(try engine.registerCurrentIfNeeded() == nil)
        try engine.store.setLabel(FakeWorld.a, "alpha@example.com")
        #expect(engine.store.account(FakeWorld.a)?.shortLabel == "alpha")
        #expect(engine.store.account(FakeWorld.a)?.initials == "AL")
    }
}
