import Foundation
import Testing
@testable import ClaudeAccountsCore

private func successOnOpen(_ w: FakeWorld) {
    w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token, caching", at: t) }
}

/// Reproduces the first live failure: after Claude quit, processes that outlive it kept the old
/// wait (which counted every process under Claude.app/ and claude-code/) from ever finishing.
@Suite("Quit stalls")
struct QuitStallTests {
    func app(_ w: FakeWorld) -> String { w.paths.claudeApp.path(percentEncoded: false) }

    @Test("a CLI session under claude-code/ that never exits doesn't block the switch",
          arguments: ["claude-code/2.1.289/x/claude.app/Contents/MacOS/claude", "claude-code/2.1.288/claude"])
    func cliChildOutlives(_ rel: String) async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let path = w.paths.claudeUserData.path(percentEncoded: false) + "/" + rel
        w.extraProcesses = { _, _ in [path] }
        let start = w.now
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .success)
        #expect(w.now.timeIntervalSince(start) < 20)   // ~2 s exit + 5 s grace, not 120 s
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        #expect(log.contains("quit: proceeding; 1 CLI/helper process(es) still exiting"))
    }

    @Test("bundle Helpers (disclaimer, claude-ios-sim) that outlive the app don't block",
          arguments: ["/Contents/Helpers/disclaimer", "/Contents/Helpers/Claude iOS Sim.app/Contents/MacOS/claude-ios-sim"])
    func helpersOutlive(_ rel: String) async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let path = app(w) + rel
        w.extraProcesses = { _, _ in [path] }
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .success)
    }

    @Test("a framework helper that lingers briefly is waited for (it can write Cookies)")
    func frameworkHelperLingers() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        successOnOpen(w)
        let helper = app(w) + "/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        w.extraProcesses = { exited, now in
            guard let exited else { return [helper] }
            return now.timeIntervalSince(exited) < 3 ? [helper] : []
        }
        let box = TaskBox()
        let o = try await engine.switchTo(FakeWorld.b) { box.record($0) }
        #expect(o.verdict == .success)
    }

    @Test("a framework helper that never exits times out with nothing changed and Claude reopened")
    func frameworkHelperStuck() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine(quitTimeout: 60)
        try w.setUpTwoAccounts(store: engine.store)
        let helper = app(w) + "/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
        w.extraProcesses = { _, _ in [helper] }
        let before = w.digest(w.paths.liveCookies)
        let box = TaskBox()
        await #expect(throws: EngineError.stillRunning("Claude")) { try await engine.switchTo(FakeWorld.b) { box.record($0) } }
        #expect(box.seen.contains(.waitingOn(1)))      // the blocking reason surfaced after 30 s
        #expect(w.digest(w.paths.liveCookies) == before)
        #expect(w.app(Paths.claudeBundleID).opens == 1) // main app was gone: relaunched
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        #expect(log.contains("quit: still waiting on 1 Claude process(es)"))
        #expect(log.contains("quit Claude aborted"))
    }

    @Test("Claude reopened during the wait: abort cleanly, nothing changed, logged")
    func reopenedDuringWait() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        let before = w.digest(w.paths.liveCookies)
        // Claude exits, then the user reopens it while a CLI child keeps the grace period running.
        let path = w.paths.claudeCodeDir.path(percentEncoded: false) + "/2.1.289/claude"
        w.extraProcesses = { exited, now in
            if let exited, now.timeIntervalSince(exited) > 0.2 { w.set(Paths.claudeBundleID) { $0.running = true } }
            return [path]
        }
        await #expect(throws: EngineError.claudeReopened) { try await engine.switchTo(FakeWorld.b) }
        #expect(w.digest(w.paths.liveCookies) == before)
        #expect(engine.store.backups().isEmpty)
        #expect(w.app(Paths.claudeBundleID).running)
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        #expect(log.contains("quit Claude aborted: Claude reopened"))
    }

    @Test("Add Account goes through the same wait and logs every step")
    func addLogsSteps() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        let path = w.paths.claudeCodeDir.path(percentEncoded: false) + "/2.1.289/claude"
        w.extraProcesses = { _, _ in [path] }
        try await engine.beginAdd(label: "gamma@example.com")
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        for step in ["add: requested", "sync: start", "sync: done", "quit: requested", "quit: exited",
                     "backup: start", "backup: ", "relaunch: Claude", "add: Claude reopened at sign-in; done"] {
            #expect(log.contains(step), "missing step \(step)")
        }
        #expect(w.app(Paths.claudeBundleID).running)
    }

    @Test("a failure after the quit relaunches Claude (except a half-swap)")
    func relaunchMandatory() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        // Make the restore fail before any write: the target slot vanishes after preflight.
        let slot = w.paths.slotDesktopCookies(FakeWorld.b)
        w.onExit[Paths.claudeBundleID] = { try? FileManager.default.removeItem(at: slot) }
        await #expect(throws: (any Error).self) { try await engine.switchTo(FakeWorld.b) }
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(w.app(Paths.claudeBundleID).opens == 1)
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        #expect(log.contains("switch aborted"))
    }
}

@Suite("Add half-swap")
struct AddHalfSwapTests {
    @Test("a config write that fails after the live Cookies was removed is a half-swap: no relaunch, in-flight kept")
    func addConfigWriteFails() async throws {
        let w = try FakeWorld()
        let engine = SwitchEngine(paths: w.paths, probe: FakeProbe(world: w), controller: FakeController(world: w),
                                  ticker: FakeTicker(world: w), sync: FakeSync(), verifyTimeout: 5,
                                  rewriteConfig: { _, _ in throw EngineError.io("synthetic write failure") })
        try w.setUpTwoAccounts(store: engine.store)
        var bid = ""
        do {
            try await engine.beginAdd(label: "gamma@example.com")
            Issue.record("expected restoreFailed")
        } catch EngineError.restoreFailed(let id) {
            bid = id
        }
        #expect(FileOps.exists(w.paths.liveCookies) == false)          // the half-changed state
        #expect(w.app(Paths.claudeBundleID).running == false)          // not relaunched
        #expect(w.app(Paths.claudeBundleID).opens == 0)
        #expect(engine.store.state().inFlight?.backupID == bid)
        #expect(engine.store.state().pendingAddLabel == nil)
        // Startup recovery puts the old login back.
        let m = await engine.recoverInterrupted()
        #expect(m?.contains("undone") == true)
        #expect(CookieDB.hasClaudeLogin(w.paths.liveCookies))
    }
}
