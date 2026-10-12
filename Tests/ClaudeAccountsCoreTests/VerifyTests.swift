import Foundation
import Testing
@testable import ClaudeAccountsCore

/// The exact lines Claude.app wrote in the a live switch (account ids replaced) (structure only).
private let target = "11111111-2222-4333-8444-555555555555"
private let liveLines = """
2026-10-08 13:11:26 [info] [oauth-v2] performing fresh /authorize
2026-10-08 13:11:28 [info] claude.ai account active and logged in
2026-10-08 13:11:28 [info] [LocalSessionManager] Initialization succeeded — accountId=11111111-2222-4333-8444-555555555555
"""

@Suite("Verify")
struct VerifyTests {
    let now = Date()

    @Test("the live success lines verify, without any 'obtained new token'")
    func liveSuccess() {
        #expect(LaunchLog.verdict(text: liveLines, target: target, now: now) == .success)
        let onlyInit = "2026-10-08 13:11:28 [info] [LocalSessionManager] Initialization succeeded — accountId=\(target)"
        #expect(LaunchLog.verdict(text: onlyInit, target: target, now: now) == .success)
        // Another account's init isn't success for this target.
        let other = "2026-10-08 13:11:28 [info] [LocalSessionManager] Initialization succeeded — accountId=\(FakeWorld.a)"
        #expect(LaunchLog.verdict(text: other, target: target, now: now) == .pending)
    }

    @Test("failure markers")
    func failures() {
        #expect(LaunchLog.verdict(text: "x not_logged_in", target: target, now: now) == .failure("not_logged_in"))
        #expect(LaunchLog.verdict(text: "x User is logged out", target: target, now: now) == .failure("user is logged out"))
        #expect(LaunchLog.verdict(text: "oauth: sessionKey names a different account than the flow", target: target, now: now)
                == .failure("names a different account"))
    }

    @Test("'account changed mid-flow' fails only if no success follows within 10 s")
    func midFlow() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let t = now.addingTimeInterval(-3)
        let mid = "\(f.string(from: t)) [warn] identity: account changed mid-flow"
        #expect(LaunchLog.verdict(text: mid, target: target, now: now) == .pending)          // within 10 s
        #expect(LaunchLog.verdict(text: mid, target: target, now: now.addingTimeInterval(20)) == .failure("account changed mid-flow"))
        #expect(LaunchLog.verdict(text: mid + "\n" + liveLines, target: target, now: now.addingTimeInterval(20)) == .success)
    }

    @Test("reads only the new part of main.log, and survives rotation")
    func offsetAndRotation() throws {
        let w = try FakeWorld()
        try Data("2026-10-08 13:00:00 [info] claude.ai account active and logged in\n".utf8).write(to: w.paths.mainLog)
        let offset = LaunchLog.offset(w.paths.mainLog)
        #expect(LaunchLog.verdict(mainLog: w.paths.mainLog, from: offset, target: target, now: now) == .pending)
        // Rotation: main.log moves to main1.log, a short new main.log starts with the success line.
        try FileManager.default.moveItem(at: w.paths.mainLog, to: w.paths.claudeLogs.appending(path: "main1.log"))
        try Data(liveLines.utf8).write(to: w.paths.mainLog)
        // New file is shorter than the offset? Make sure: pad check either way.
        #expect(LaunchLog.verdict(mainLog: w.paths.mainLog, from: offset, target: target, now: now) == .success)
    }

    @Test("verify ends at the ceiling even with no log at all")
    func ceiling() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()    // verifyTimeout 10 in fakes
        try w.setUpTwoAccounts(store: engine.store)
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .pending)
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        #expect(log.contains("verify: pending"))
        #expect(log.contains("done"))
    }

    @Test("a switch verifies from the live success lines")
    func switchWithLiveLines() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        let log = w.paths.mainLog
        w.onOpen[Paths.claudeBundleID] = { _ in
            let line = "2026-10-08 13:11:28 [info] [LocalSessionManager] Initialization succeeded — accountId=\(FakeWorld.b)\n"
            if let h = try? FileHandle(forWritingTo: log) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }
        }
        #expect(try await engine.switchTo(FakeWorld.b).verdict == .success)
    }
}
