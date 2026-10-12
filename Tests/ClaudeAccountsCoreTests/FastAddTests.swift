import Foundation
import Testing
@testable import ClaudeAccountsCore

@Suite("Fast Add and exit")
struct FastAddTests {
    @Test("registers from the uuid change alone, before the cookie row reaches disk")
    func registersOnUuidChange() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try await engine.beginAdd(label: "gamma@example.com")
        #expect(FileOps.exists(w.paths.liveCookies) == false)
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.c)   // login-state transition
        guard case .added(let a) = try engine.completeAdd() else { Issue.record("still waiting"); return }
        #expect(a.id == FakeWorld.c)
        #expect(a.label == "gamma@example.com")
    }

    @Test("an unchanged uuid still waits until a session row appears")
    func unchangedWaitsForCookie() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try await engine.beginAdd(label: "alpha again", reauth: FakeWorld.a)
        #expect(try engine.completeAdd() == .waiting)                     // config still says A, no cookie
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: Fixture.desktopCookies(for: FakeWorld.a))
        guard case .added(let a) = try engine.completeAdd() else { Issue.record("not added"); return }
        #expect(a.id == FakeWorld.a)
    }

    @Test("a uuid change to a known account is reported at once")
    func knownAtOnce() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try await engine.beginAdd(label: "gamma@example.com")
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.b)
        guard case .signedInAsKnown(let a) = try engine.completeAdd() else { Issue.record("expected known"); return }
        #expect(a.id == FakeWorld.b)
    }

    @Test("the post-exit grace is about half a second, not 5")
    func shortGrace() async throws {
        let w = try FakeWorld()
        let cli = w.paths.claudeCodeDir.path(percentEncoded: false) + "/2.1.289/claude"
        w.extraProcesses = { _, _ in [cli] }
        let q = QuitCoordinator(probe: FakeProbe(world: w), controller: FakeController(world: w), ticker: FakeTicker(world: w))
        w.set(Paths.claudeBundleID) { $0.exit = .after(1) }
        let start = w.now
        try await q.quitAndWait(.claude(w.paths))
        let elapsed = w.now.timeIntervalSince(start)
        #expect(elapsed < 2.5)    // ~1 s to exit + ~0.5 s grace, previously ~6 s
        #expect(q.lingerGrace == 0.5)
    }

    @Test("step lines read as progress")
    func stepCopy() {
        #expect(PanelCopy.step(.quittingClaude) == "Closing Claude…")
        #expect(PanelCopy.step(.saving) == "Saving…")
        #expect(PanelCopy.step(.restoring) == "Saving…")
        #expect(PanelCopy.step(.opening) == "Opening Claude…")
        #expect(PanelCopy.step(.waitingForClaude) == PanelCopy.waitingForClaude)
    }
}
