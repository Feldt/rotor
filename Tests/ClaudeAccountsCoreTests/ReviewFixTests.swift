import Foundation
import Testing
@testable import ClaudeAccountsCore

private func successOnOpen(_ w: FakeWorld) {
    w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token, caching", at: t) }
}

private func chrome(_ w: FakeWorld, _ account: String, withLogin: Bool = true) throws {
    let rows = withLogin ? Fixture.chromeCookies(for: account) : Fixture.chromeCookies(for: account).filter { $0.name != "sessionKey" }
    try Fixture.makeCookiesDB(w.paths.chromeCookies, rows: rows + Fixture.otherSiteCookies())
    try Fixture.writeExtensionSettings(w.paths.chromeExtensionSettings, account: account)
}

/// Two accounts, B with a saved Chrome slot, Chrome live on A.
private func twoWithChrome(_ w: FakeWorld, _ engine: SwitchEngine) throws {
    try w.setUpTwoAccounts(store: engine.store)
    successOnOpen(w)
    try chrome(w, FakeWorld.b)
    try engine.saveChrome(as: FakeWorld.b)
    try chrome(w, FakeWorld.a)
}

@Suite("Review fixes")
struct ReviewFixTests {
    // 1
    @Test("#1 an unattributed outgoing Chrome login is kept: Chrome left exactly as it was")
    func unattributedNotSaved() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try twoWithChrome(w, engine)
        let before = w.digest(w.paths.chromeCookies)
        let o = try await engine.switchTo(FakeWorld.b, chrome: .ifClosed)
        #expect(o.chrome == .kept(label: "alpha"))
        #expect(w.digest(w.paths.chromeCookies) == before)
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)
        #expect(FileOps.exists(w.paths.slotChromeCookies(FakeWorld.a)) == false)
        #expect(engine.store.state().chromeNotice == "Chrome kept on alpha")
        #expect(engine.store.chromeBackups().isEmpty)   // nothing written, not even a backup
    }

    @Test("#1 reader disagreeing with the recorded account keeps Chrome untouched")
    func readerDisagrees() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try twoWithChrome(w, engine)
        try engine.store.register(FakeWorld.c, label: "c", now: w.now)
        try engine.attestChromeAccount(FakeWorld.c)
        let before = w.digest(w.paths.chromeCookies)
        let o = try await engine.switchTo(FakeWorld.b, chrome: .ifClosed)
        #expect(o.chrome == .kept(label: "alpha"))
        #expect(w.digest(w.paths.chromeCookies) == before)
        #expect(FileOps.exists(w.paths.slotChromeCookies(FakeWorld.c)) == false)
        #expect(FileOps.exists(w.paths.slotChromeCookies(FakeWorld.a)) == false)
    }

    @Test("#1 an unreadable extension (can't tell) still saves under the recorded account")
    func readerCantTell() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try twoWithChrome(w, engine)
        try engine.attestChromeAccount(FakeWorld.a)
        try FileManager.default.removeItem(at: w.paths.chromeExtensionSettings.appending(path: "000003.log"))
        _ = try await engine.switchTo(FakeWorld.b, chrome: .ifClosed)
        #expect(try Fixture.blobs(w.paths.slotChromeCookies(FakeWorld.a)).contains(".claude.ai|sessionKey=chrome-\(FakeWorld.a)"))
    }

    @Test("#1 slots keep a .prev copy before being overwritten")
    func prevCopies() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try twoWithChrome(w, engine)
        try engine.attestChromeAccount(FakeWorld.a)
        _ = try await engine.switchTo(FakeWorld.b, chrome: .ifClosed)
        _ = try await engine.switchTo(FakeWorld.a, chrome: .ifClosed)
        // B's desktop and Chrome slots were overwritten on the way back; the old ones are kept.
        let bDesk = w.paths.slotDesktopCookies(FakeWorld.b)
        #expect(FileOps.exists(bDesk.deletingLastPathComponent().appending(path: "Cookies.prev")))
        let bChrome = w.paths.slotChromeCookies(FakeWorld.b)
        #expect(FileOps.exists(bChrome.deletingLastPathComponent().appending(path: "claude-cookies.sqlite.prev")))
        #expect(FileOps.isDirectory(bChrome.deletingLastPathComponent().appending(path: "extension-settings.prev")))
    }

    // 2
    @Test("#2 Restart Chrome now without new extension writes is unconfirmed")
    func unconfirmedRestart() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try twoWithChrome(w, engine)
        try engine.attestChromeAccount(FakeWorld.a)
        w.set(Paths.chromeBundleID) {
            $0.running = true
            $0.exit = .after(2)
        }
        let o = try await engine.switchTo(FakeWorld.b, chrome: .restartNow)
        #expect(o.chrome == .switched(confirmed: false))
    }

    // 3
    @Test("#3 Chrome reappearing before the rename leaves the live DB untouched and no temp files")
    func reappearsMidSwap() throws {
        let w = try FakeWorld()
        try chrome(w, FakeWorld.a)
        let slot = w.root.appending(path: "slot.sqlite")
        try Fixture.makeCookiesDB(slot, rows: Fixture.chromeCookies(for: FakeWorld.b))
        let before = w.digest(w.paths.chromeCookies)
        #expect(throws: EngineError.chromeNotClosed) {
            try CookieDB.importFamilyRows(from: slot, into: w.paths.chromeCookies) { throw EngineError.chromeNotClosed }
        }
        #expect(w.digest(w.paths.chromeCookies) == before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: w.paths.chromeProfile.path).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test("#3 a deferred swap that fails stays pending, leaves a notice, and retries at the next quit")
    func deferredFailureRetries() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try twoWithChrome(w, engine)
        try engine.attestChromeAccount(FakeWorld.a)
        w.set(Paths.chromeBundleID) { $0.running = true }
        _ = try await engine.switchTo(FakeWorld.b, chrome: .whenNextQuits)
        w.set(Paths.chromeBundleID) { $0.running = false }
        // Chrome reappears (a helper starts) after the swap began: once its Chrome backup exists.
        let backups = w.paths.chromeBackupsDir
        w.reappearsWhen[Paths.chromeBundleID] = {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
            return names.contains { FileOps.exists(backups.appending(path: "\($0)/manifest.json")) }
        }
        let r = try await engine.applyPendingChrome()
        guard case .failed = r else { Issue.record("expected failure, got \(r)"); return }
        #expect(engine.store.state().pendingChrome == .slot(FakeWorld.b))
        #expect(engine.store.state().chromeNotice != nil)
        #expect(engine.store.state().chromeAccount == FakeWorld.a)  // nothing was written
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.a)
        let chromeA = try Fixture.blobs(w.paths.chromeCookies)
        #expect(chromeA.contains(".claude.ai|sessionKey=chrome-\(FakeWorld.a)"))
        w.reappearsWhen[Paths.chromeBundleID] = nil
        let retry = try await engine.applyPendingChrome()
        #expect(retry == .switched(confirmed: false))
        #expect(engine.store.state().pendingChrome == nil)
        #expect(ExtensionSettings.accountUuid(in: w.paths.chromeExtensionSettings) == FakeWorld.b)
        #expect(FileOps.exists(w.paths.slotChromeCookies(FakeWorld.a)))
    }

    // 4
    @Test("#4 saveChrome refuses a profile without a claude.ai login and keeps the good slot")
    func saveChromeGuard() throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try chrome(w, FakeWorld.a)
        try engine.saveChrome(as: FakeWorld.a)
        let good = try Fixture.blobs(w.paths.slotChromeCookies(FakeWorld.a))
        try chrome(w, FakeWorld.a, withLogin: false)
        #expect(throws: EngineError.noChromeLogin) { try engine.saveChrome(as: FakeWorld.a) }
        #expect(try Fixture.blobs(w.paths.slotChromeCookies(FakeWorld.a)) == good)
    }

    // 5
    @Test("#5 slots record Chrome's meta version; a version change refuses the import with a notice")
    func schemaVersion() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try twoWithChrome(w, engine)
        try engine.attestChromeAccount(FakeWorld.a)
        #expect(engine.store.account(FakeWorld.b)?.chrome?.schemaVersion == "24")
        #expect(engine.store.account(FakeWorld.b)?.chrome?.lastCompatibleVersion == "24")
        // Chrome updates its cookie DB.
        let db = try SQLiteDB(w.paths.chromeCookies, mode: .readWrite)
        try db.exec("UPDATE meta SET value='25' WHERE key='version'")
        let before = w.digest(w.paths.chromeCookies)
        let o = try await engine.switchTo(FakeWorld.b, chrome: .ifClosed)
        #expect(o.chrome == .failed(EngineError.chromeSchemaChanged.description))
        #expect(engine.store.state().chromeNotice == "Chrome updated, sign in to the extension once")
        #expect(w.digest(w.paths.chromeCookies) == before)
    }

    // 6
    @Test("#6 signing in to a known account again is reported, never relabelled, and the add stays pending")
    func addLandsOnKnown() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try await engine.beginAdd(label: "gamma@example.com")
        // The user signs in as B by mistake.
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.b))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.b)
        let r = try engine.completeAdd()
        guard case .signedInAsKnown(let a) = r else { Issue.record("got \(r)"); return }
        #expect(a.id == FakeWorld.b)
        #expect(engine.store.account(FakeWorld.b)?.label == "beta@example.com")
        #expect(engine.store.state().pendingAddLabel == "gamma@example.com")
        // Same for the account the add started from.
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        guard case .signedInAsKnown = try engine.completeAdd() else { Issue.record("expected known"); return }
        #expect(engine.store.account(FakeWorld.a)?.label == "alpha@example.com")
    }

    @Test("#6 Sign in again for a known account completes when that account signs in")
    func reauth() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try await engine.beginAdd(label: "beta@example.com", reauth: FakeWorld.b)
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.b))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.b)
        guard case .added(let a) = try engine.completeAdd() else { Issue.record("not added"); return }
        #expect(a.id == FakeWorld.b)
        #expect(engine.store.state().pendingAddLabel == nil)
    }

    // 7
    @Test("#7 an unconfirmed launch is not recorded as a good Claude version")
    func pendingVerdict() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .pending)
        #expect(engine.store.state().lastGoodClaudeVersion == nil)
        successOnOpen(w)
        let back = try await engine.switchTo(FakeWorld.a)
        #expect(back.verdict == .success)
        #expect(engine.store.state().lastGoodClaudeVersion == "2.26454.0")
    }

    // 8 + 9
    @Test("#8/#9 Claude reappearing mid-restore: no relaunch, in-flight kept, startup recovery restores the backup")
    func inFlightRecovery() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let liveA = try Fixture.blobs(w.paths.liveCookies)
        let configA = try Data(contentsOf: w.paths.liveConfig)
        let live = w.paths.liveCookies
        // Claude comes back once B's cookies are in place, before config.json is written.
        w.reappearsWhen[Paths.claudeBundleID] = {
            ((try? Fixture.blobs(live)) ?? []).contains { $0.contains("v3-\(FakeWorld.b)") }
        }
        do {
            _ = try await engine.switchTo(FakeWorld.b)
            Issue.record("expected restoreFailed")
        } catch EngineError.restoreFailed(let bid) {
            #expect(engine.store.state().inFlight?.backupID == bid)
            #expect(engine.store.state().inFlight?.step == "restore")
        }
        #expect(w.app(Paths.claudeBundleID).opens == 0)

        // Next launch of the app, with Claude closed.
        w.reappearsWhen[Paths.claudeBundleID] = nil
        let message = await engine.recoverInterrupted()
        #expect(message?.contains("undone") == true)
        #expect(try Fixture.blobs(w.paths.liveCookies) == liveA)
        #expect(try Data(contentsOf: w.paths.liveConfig) == configA)
        #expect(engine.store.state().inFlight == nil)
    }

    @Test("#8 recovery does nothing while Claude is running")
    func recoveryWaitsForClaude() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try engine.store.updateState { $0.inFlight = InFlight(kind: .switchAccount, backupID: "x", from: nil, to: nil, step: "restore") }
        let before = w.digest(w.paths.liveCookies)
        let m = await engine.recoverInterrupted()
        #expect(m?.contains("nothing was restored") == true)
        #expect(w.digest(w.paths.liveCookies) == before)
        #expect(engine.store.state().inFlight != nil)
    }

    @Test("#9 rollback saves the live login to its slot first; a partial failure points at the pre-rollback backup")
    func rollbackSavesAndPoints() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let o = try await engine.switchTo(FakeWorld.b)
        // B's live login re-stamped since; rollback keeps it.
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: "\(FakeWorld.b)-restamped"))
        let live = w.paths.liveCookies
        w.reappearsWhen[Paths.claudeBundleID] = {
            ((try? Fixture.blobs(live)) ?? []).contains { $0.contains("v3-\(FakeWorld.a)") }
        }
        do {
            _ = try await engine.rollback(o.backupID)
            Issue.record("expected rollbackFailed")
        } catch EngineError.rollbackFailed(let bid, let pre) {
            #expect(bid == o.backupID)
            #expect(engine.store.manifest(pre) != nil)
            #expect(engine.store.state().inFlight?.preBackupID == pre)
        }
        #expect(try Fixture.blobs(w.paths.slotDesktopCookies(FakeWorld.b)).contains { $0.contains("restamped") })
        #expect(w.app(Paths.claudeBundleID).opens == 1)
    }

    // 10
    @Test("#10 busy heuristic skips subagent and terminal transcripts")
    func busySkips() throws {
        let w = try FakeWorld()
        let dir = w.paths.claudeProjects.appending(path: "proj")
        try FileManager.default.createDirectory(at: dir.appending(path: "s1/subagents"), withIntermediateDirectories: true)
        let desktop = #"{"type":"user","entrypoint":"claude-desktop","message":{}}"#
        let cli = #"{"type":"user","entrypoint":"cli","message":{}}"#
        try Data(desktop.utf8).write(to: dir.appending(path: "desk.jsonl"))
        try Data(cli.utf8).write(to: dir.appending(path: "term.jsonl"))
        try Data(desktop.utf8).write(to: dir.appending(path: "s1/subagents/agent-1.jsonl"))
        #expect(BusyCheck.workingChats(projects: w.paths.claudeProjects, now: Date()) == 1)
    }

    // 11
    @Test("#11 every oauth: key is dropped; an unknown oauth: key pauses switching")
    func oauthKeys() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a, extra: ["oauth:tokenCacheV3": "x"])
        await #expect(throws: EngineError.shapeMismatch("config.json has a new oauth key oauth:tokenCacheV3")) {
            try await engine.switchTo(FakeWorld.b)
        }
        #expect(w.app(Paths.claudeBundleID).quitRequests == 0)
        try ClaudeConfig.rewrite(w.paths.liveConfig, account: FakeWorld.b)
        let keys = try ClaudeConfig.keyNames(w.paths.liveConfig)
        #expect(keys.contains { $0.hasPrefix("oauth:") } == false)
    }

    // 12
    @Test("#12 a claude-code child that lingers no longer blocks: proceed after the grace period")
    func reopenOnMainOnly() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine(quitTimeout: 30)
        try w.setUpTwoAccounts(store: engine.store)
        w.set(Paths.claudeBundleID) {
            $0.exit = .after(2)
            $0.childLinger = 10_000
        }
        _ = try await engine.switchTo(FakeWorld.b)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
        #expect(w.app(Paths.claudeBundleID).running)
    }

    @Test("#12 'Claude is asking' only with a window up; otherwise 'Waiting for Claude to finish quitting'")
    func askingNeedsWindow() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        w.set(Paths.claudeBundleID) {
            $0.exit = .after(20)
            $0.windowVisible = false
        }
        let box = TaskBox()
        _ = try await engine.switchTo(FakeWorld.b) { box.record($0) }
        #expect(box.seen.contains(.waitingForClaude))
        #expect(box.seen.contains(.claudeAsking) == false)
    }
}
