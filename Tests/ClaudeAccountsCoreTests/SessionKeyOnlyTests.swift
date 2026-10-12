import Foundation
import Testing
@testable import ClaudeAccountsCore

/// A fresh sign-in has `sessionKey` / `sessionKeyLC` rows and no `sessionKeyV3` yet.
private func freshSignIn(for account: String, days: Double = 28) -> [DummyCookie] {
    let exp = Date().addingTimeInterval(days * 86_400)
    return [
        DummyCookie(host: ".claude.ai", name: "sessionKey", blob: "v1-\(account)", expires: exp),
        DummyCookie(host: ".claude.ai", name: "sessionKeyLC", blob: "lc-\(account)", expires: exp),
    ]
}

@Suite("sessionKey-only logins")
struct SessionKeyOnlyTests {
    @Test("Add completes when the new login has only sessionKey")
    func addCompletes() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try await engine.beginAdd(label: "me@example.com")
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: freshSignIn(for: FakeWorld.c))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.c)
        guard case .added(let a) = try engine.completeAdd() else { Issue.record("still waiting"); return }
        #expect(a.id == FakeWorld.c)
        #expect(a.label == "me@example.com")
    }

    @Test("a sessionKey-only login is saved at switch-out, then restored")
    func saveAndRestore() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token", at: t) }
        try Fixture.makeCookiesDB(w.paths.liveCookies, rows: freshSignIn(for: FakeWorld.a))
        let liveA = try Fixture.blobs(w.paths.liveCookies)
        _ = try await engine.switchTo(FakeWorld.b)
        #expect(try Fixture.blobs(w.paths.slotDesktopCookies(FakeWorld.a)) == liveA)   // saved
        _ = try await engine.switchTo(FakeWorld.a)                                     // preflight accepts it
        #expect(try Fixture.blobs(w.paths.liveCookies) == liveA)                        // restored
    }

    @Test("fingerprint and expiry fall back to sessionKey; V3 never matches sessionKey")
    func fingerprintAndExpiry() throws {
        let w = try FakeWorld()
        let onlyKey = w.root.appending(path: "k.sqlite")
        try Fixture.makeCookiesDB(onlyKey, rows: freshSignIn(for: FakeWorld.a, days: 20))
        let fp = CookieDB.sessionFingerprint(onlyKey)
        #expect(fp?.name == "sessionKey")
        let exp = try #require(CookieDB.sessionExpiry(onlyKey))
        #expect(abs(exp.timeIntervalSinceNow - 20 * 86_400) < 120)

        let withV3 = w.root.appending(path: "v3.sqlite")
        try Fixture.makeCookiesDB(withV3, rows: Fixture.desktopCookies(for: FakeWorld.a))
        #expect(CookieDB.sessionFingerprint(withV3)?.name == "sessionKeyV3")
        #expect(CookieDB.sessionFingerprint(withV3) != fp)   // unlike kinds never match
        #expect(CookieDB.hasClaudeLogin(onlyKey))
    }

    @Test("a sessionKey-only live cookie matching another slot's isn't saved under config's account")
    func attributionLikeForLike() throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.set(Paths.claudeBundleID) { $0.running = false }
        try Fixture.makeCookiesDB(w.paths.slotDesktopCookies(FakeWorld.b), rows: freshSignIn(for: FakeWorld.b))
        try FileOps.copyAtomically(w.paths.slotDesktopCookies(FakeWorld.b), to: w.paths.liveCookies)
        _ = try engine.saveCurrentDesktop()
        #expect(FileOps.exists(w.paths.slotDesktopCookies(FakeWorld.a)) == false)
    }
}
