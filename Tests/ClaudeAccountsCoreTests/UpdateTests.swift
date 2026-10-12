import Foundation
import Testing
@testable import ClaudeAccountsCore

@Suite("Update status")
struct UpdateTests {
    let installed = "/Users/x/Applications/Rotor.app"
    let running = BuildInfo(commit: "abc1234", date: "2026-10-08T10:00:00Z")

    @Test("up to date when running the installed copy at the repo's HEAD")
    func upToDate() {
        #expect(Updater.status(runningPath: installed, installedPath: installed, running: running,
                               installed: running, repoHead: "abc1234def5678") == .upToDate)
    }

    @Test("update available when the repo's HEAD differs")
    func available() {
        #expect(Updater.status(runningPath: installed, installedPath: installed, running: running,
                               installed: running, repoHead: "fff9999aaa") == .updateAvailable(head: "fff9999"))
    }

    @Test("old copy when running from elsewhere, or a newer copy is installed")
    func oldCopy() {
        let s1 = Updater.status(runningPath: "/repo/build/Rotor.app", installedPath: installed,
                                running: running, installed: running, repoHead: "abc1234")
        guard case .oldCopy = s1 else { Issue.record("expected old copy"); return }
        let newer = BuildInfo(commit: "def5678", date: "2026-10-08T12:00:00Z")
        let s2 = Updater.status(runningPath: installed, installedPath: installed, running: running,
                                installed: newer, repoHead: "def5678")
        guard case .oldCopy = s2 else { Issue.record("expected old copy (newer installed)"); return }
    }

    @Test("the in-app Update checks expect ~/Applications/Rotor.app, and a copy still named Claude Accounts is an old copy")
    func installedPathIsRotor() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        #expect(Updater.samePath(Updater.installedPath.path(percentEncoded: false), home + "/Applications/Rotor.app"))
        #expect(Updater.installedPath.lastPathComponent == Product.bundleName)
        let old = Updater.status(runningPath: "/Users/x/Applications/Claude Accounts.app", installedPath: installed,
                                 running: running, installed: running, repoHead: "abc1234")
        #expect(old == .oldCopy(reason: "not running from ~/Applications"))
    }

    @Test("what a person sees is Rotor; the CLI is rotor and claude-accounts stays an alias")
    func productNames() {
        #expect(Product.name == "Rotor")
        #expect(Product.bundleName == "Rotor.app")
        #expect(Product.cli == "rotor")
    }

    @Test("commit compare by prefix; dirty suffix stripped")
    func commits() {
        #expect(Updater.sameCommit("abc1234", "abc1234def"))
        #expect(Updater.sameCommit("abc1234", "abd") == false)
        #expect(Updater.sameCommit(nil, "abc") == false)
        let b = BuildInfo.from(plist: ["CAGitCommit": "abc1234-dirty", "CABuildDate": "d"])
        #expect(b.commit == "abc1234")
        #expect(b.dirty)
    }

    @Test("Update is disabled with a reason while anything is in flight")
    func blocked() {
        #expect(Updater.blockReason(isSwitching: false, isAdding: false, isChromeSwapping: false, hasInFlight: false) == nil)
        #expect(Updater.blockReason(isSwitching: true, isAdding: false, isChromeSwapping: false, hasInFlight: false) == "A switch is in progress")
        #expect(Updater.blockReason(isSwitching: false, isAdding: true, isChromeSwapping: false, hasInFlight: false) != nil)
        #expect(Updater.blockReason(isSwitching: false, isAdding: false, isChromeSwapping: true, hasInFlight: false) != nil)
        #expect(Updater.blockReason(isSwitching: false, isAdding: false, isChromeSwapping: false, hasInFlight: true) != nil)
    }

    @Test("repo HEAD read from loose refs, packed refs, or detached")
    func head() throws {
        let w = try FakeWorld()
        let git = w.root.appending(path: "repo/.git")
        try FileManager.default.createDirectory(at: git.appending(path: "refs/heads"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        try "1111111aaaa\n".write(to: git.appending(path: "refs/heads/main"), atomically: true, encoding: .utf8)
        #expect(Updater.repoHead(w.root.appending(path: "repo")) == "1111111aaaa")
        try FileManager.default.removeItem(at: git.appending(path: "refs/heads/main"))
        try "# pack\n2222222bbbb refs/heads/main\n".write(to: git.appending(path: "packed-refs"), atomically: true, encoding: .utf8)
        #expect(Updater.repoHead(w.root.appending(path: "repo")) == "2222222bbbb")
        try "3333333cccc\n".write(to: git.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        #expect(Updater.repoHead(w.root.appending(path: "repo")) == "3333333cccc")
    }
}
