import Foundation
import SQLite3
import Synchronization
import Testing
@testable import ClaudeAccountsCore

/// The Chromium Cookies schema, taken from the real databases with `.schema` (no data).
let chromiumCookiesSchema = """
CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
CREATE TABLE cookies(creation_utc INTEGER NOT NULL,host_key TEXT NOT NULL,top_frame_site_key TEXT NOT NULL,name TEXT NOT NULL,value TEXT NOT NULL,encrypted_value BLOB NOT NULL,path TEXT NOT NULL,expires_utc INTEGER NOT NULL,is_secure INTEGER NOT NULL,is_httponly INTEGER NOT NULL,last_access_utc INTEGER NOT NULL,has_expires INTEGER NOT NULL,is_persistent INTEGER NOT NULL,priority INTEGER NOT NULL,samesite INTEGER NOT NULL,source_scheme INTEGER NOT NULL,source_port INTEGER NOT NULL,last_update_utc INTEGER NOT NULL,source_type INTEGER NOT NULL,has_cross_site_ancestor INTEGER NOT NULL);
CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key, top_frame_site_key, has_cross_site_ancestor, name, path, source_scheme, source_port);
"""

struct DummyCookie {
    var host: String
    var name: String
    var blob: String
    var expires: Date
}

enum Fixture {
    static func makeCookiesDB(_ url: URL, rows: [DummyCookie], schema: String = chromiumCookiesSchema) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(url, mode: .create)
        try db.exec(schema)
        try db.exec("INSERT INTO meta VALUES('version','24'),('last_compatible_version','24')")
        for r in rows {
            let exp = ChromiumTime.micros(r.expires)
            try db.run("""
                INSERT INTO cookies VALUES(?, ?, '', ?, '', CAST(? AS BLOB), '/', ?, 1, 1, ?, 1, 1, 1, 0, 2, 443, ?, 0, 0)
                """, [.int(exp - 1), .text(r.host), .text(r.name), .text(r.blob), .int(exp), .int(exp - 1), .int(exp - 1)])
        }
    }

    /// Dummy blobs, as text, ordered by host and name. Test data only.
    static func blobs(_ url: URL, hostLike: String = "%") throws -> [String] {
        let db = try SQLiteDB(url, mode: .readOnlyImmutable)
        return try db.query("SELECT host_key || '|' || name || '=' || CAST(encrypted_value AS TEXT) FROM cookies WHERE host_key LIKE ? ORDER BY host_key, name",
                            [.text(hostLike)]).compactMap { $0[0].text }
    }

    static func desktopCookies(for account: String, days: Double = 28) -> [DummyCookie] {
        let exp = Date().addingTimeInterval(days * 86_400)
        return [
            DummyCookie(host: ".claude.ai", name: "sessionKeyV3", blob: "v3-\(account)", expires: exp),
            DummyCookie(host: ".claude.ai", name: "sessionKey", blob: "v1-\(account)", expires: exp),
            DummyCookie(host: "claude.ai", name: "anthropic-device-id", blob: "dev-\(account)", expires: exp),
        ]
    }

    static func chromeCookies(for account: String) -> [DummyCookie] {
        let exp = Date().addingTimeInterval(20 * 86_400)
        return [
            DummyCookie(host: ".claude.ai", name: "sessionKey", blob: "chrome-\(account)", expires: exp),
            DummyCookie(host: "claude.ai", name: "g_state", blob: "g-\(account)", expires: exp),
            DummyCookie(host: "app.claude.ai", name: "x", blob: "sub-\(account)", expires: exp),
        ]
    }

    static func otherSiteCookies() -> [DummyCookie] {
        let exp = Date().addingTimeInterval(100 * 86_400)
        return [
            DummyCookie(host: ".google.com", name: "SID", blob: "google", expires: exp),
            DummyCookie(host: "github.com", name: "user_session", blob: "github", expires: exp),
            DummyCookie(host: "notclaude.ai", name: "n", blob: "lookalike", expires: exp),
        ]
    }

    static func writeConfig(_ url: URL, account: String?, extra: [String: Any] = [:]) throws {
        var d: [String: Any] = [
            "oauth:tokenCache": "dummy-cache",
            "oauth:tokenCacheV2": ["k": "dummy"],
            "locale": "en-US",
            "userThemeMode": "system",
            "dxt:allowlistEnabled:abc": true,
            "windowControlsZoomFactor": 1.25,
        ]
        if let account { d["lastKnownAccountUuid"] = account }
        for (k, v) in extra { d[k] = v }
        try JSONSerialization.data(withJSONObject: d).write(to: url)
    }

    static func writeExtensionSettings(_ dir: URL, account: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("MANIFEST-000001\n".utf8).write(to: dir.appending(path: "CURRENT"))
        var bytes = Data([0x01, 0x00, 0x0b])
        bytes.append(Data("accountUuid".utf8))
        bytes.append(Data([0x26]))
        bytes.append(Data("\"\(account)\"".utf8))
        try bytes.write(to: dir.appending(path: "000003.log"))
    }
}

/// A fake Mac: a temp tree for every path, plus simulated Claude and Chrome processes.
final class FakeWorld: @unchecked Sendable {
    enum ExitBehavior: Equatable {
        case after(Double)
        case never
    }

    struct AppSim {
        var running = false
        var quitRequestedAt: Date?
        var exit: ExitBehavior = .after(2)
        var childLinger: Double = 0
        var exitedAt: Date?
        var opens = 0
        var quitRequests = 0
        /// Its main window (or quit dialog) is on screen.
        var windowVisible = true
    }

    let root: URL
    let paths: Paths
    private let state = Mutex<(clock: Date, apps: [String: AppSim])>((Date(), [:]))
    /// Called (outside the lock) when an app exits, e.g. to leave a journal behind.
    var onExit: [String: @Sendable () -> Void] = [:]
    /// Runs once, `delay` seconds after the app exits (e.g. Chromium emptying its cookie journal).
    var afterExit: [String: (delay: Double, action: @Sendable () -> Void)] = [:]
    private let afterExitDone = Mutex<Set<String>>([])
    /// URLs opened in an app (e.g. claude.ai/login in Chrome).
    let openedURLs = Mutex<[URL]>([])
    /// When each app's quit was first requested (fake clock), to check parallel quits.
    let quitRequestedAt = Mutex<[String: Date]>([:])
    /// Extra process paths given Claude's exit time and the clock (lingering helpers, CLI sessions).
    var extraProcesses: @Sendable (_ claudeExitedAt: Date?, _ now: Date) -> [String] = { _, _ in [] }
    /// When this returns true the probe reports the app's main process (it "reappeared").
    var reappearsWhen: [String: @Sendable () -> Bool] = [:]
    /// Called when an app is opened, e.g. to write main.log lines.
    var onOpen: [String: @Sendable (Date) -> Void] = [:]

    // MARK: Extra windows (processes of the same bundle started with --user-data-dir)

    struct WindowSim {
        var pid: Int32
        var helperPID: Int32
        var dataDir: String
        var running = true
        var launchedAt: Date
        var quitRequestedAt: Date?
    }
    private let windowState = Mutex<(sims: [Int32: WindowSim], next: Int32)>(([:], 500))
    /// Every signal or quit request sent to a pid: ("SIGTERM" | "quit", pid).
    let pidRequests = Mutex<[(kind: String, pid: Int32)]>([])
    /// Bundle-level quit requests (`requestQuit(bundleID:)`), which would quit every window.
    let bundleQuitCount = Mutex<Int>(0)
    /// Ordered log of what happened: chat-sync, settings-sync, quit-main, launch-window, launch-main.
    let events = Mutex<[String]>([])
    /// Arguments of every `launchNewInstance`.
    let launches = Mutex<[[String]]>([])
    /// The extra window never appears (launch silently fails).
    var windowLaunchFails = false
    /// The main window never comes back from `open -n`.
    var mainLaunchFails = false
    /// A window ignores SIGTERM.
    var windowsIgnoreSigterm = false
    /// Seconds a window takes to exit after SIGTERM.
    var windowExitDelay: Double = 1
    /// Main has a helper process (child of pid 100) under Contents/Frameworks.
    var mainHelper = false
    /// The main window's helper outlives its browser process (as the cookie-writing NetworkService can).
    var mainHelperOutlivesMain = false
    /// dataDir -> (seconds after launch, account) at which the window's config.json names the account.
    let signInPlans = Mutex<[String: (delay: Double, account: String)]>([:])
    /// dataDir -> seconds after launch at which the window exits by itself.
    let selfClosePlans = Mutex<[String: Double]>([:])

    func log(_ event: String) { events.withLock { $0.append(event) } }

    func planSignIn(dataDir: URL, after delay: Double, account: String) {
        signInPlans.withLock { $0[ParallelWindows.dirString(dataDir)] = (delay, account) }
    }

    func planSelfClose(dataDir: URL, after delay: Double) {
        selfClosePlans.withLock { $0[ParallelWindows.dirString(dataDir)] = delay }
    }

    /// Starts a window process as `open -n -a Claude --args --user-data-dir=<dir>` would.
    @discardableResult
    func addWindow(dataDir: String) -> Int32 {
        let clock = now
        return windowState.withLock { s in
            let pid = s.next
            s.next += 1
            s.sims[pid] = WindowSim(pid: pid, helperPID: pid + 1000, dataDir: dataDir, launchedAt: clock)
            return pid
        }
    }

    func windowSims() -> [WindowSim] { windowState.withLock { Array($0.sims.values).sorted { $0.pid < $1.pid } } }
    func window(pid: Int32) -> WindowSim? { windowState.withLock { $0.sims[pid] } }
    func isWindowRunning(dataDir: URL) -> Bool {
        let d = ParallelWindows.dirString(dataDir)
        return windowSims().contains { $0.dataDir == d && $0.running }
    }
    func windowPID(dataDir: URL) -> Int32? {
        let d = ParallelWindows.dirString(dataDir)
        return windowSims().first { $0.dataDir == d && $0.running }?.pid
    }

    func quitWindow(pid: Int32) {
        let t = now
        windowState.withLock { s in
            if var w = s.sims[pid], w.running, w.quitRequestedAt == nil { w.quitRequestedAt = t; s.sims[pid] = w }
        }
    }

    private func advanceWindows() {
        let clock = now
        let plans = signInPlans.withLock { $0 }
        let closes = selfClosePlans.withLock { $0 }
        var writes: [(URL, String)] = []
        windowState.withLock { s in
            for (pid, var w) in s.sims where w.running {
                let age = clock.timeIntervalSince(w.launchedAt)
                if let q = w.quitRequestedAt, windowsIgnoreSigterm == false, clock.timeIntervalSince(q) >= windowExitDelay {
                    w.running = false
                }
                if let c = closes[w.dataDir], age >= c { w.running = false }
                if w.running, let plan = plans[w.dataDir], age >= plan.delay {
                    writes.append((URL(filePath: w.dataDir).appending(path: "config.json"), plan.account))
                }
                s.sims[pid] = w
            }
        }
        for (url, account) in writes where ClaudeConfig.currentAccount(url) != account {
            try? Fixture.writeConfig(url, account: account)
        }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "claude-accounts-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = Paths(
            storeRoot: root.appending(path: "store", directoryHint: .isDirectory),
            claudeUserData: root.appending(path: "Claude", directoryHint: .isDirectory),
            chromeProfile: root.appending(path: "Chrome/Default", directoryHint: .isDirectory),
            sessionSync: root.appending(path: "session-sync", directoryHint: .isDirectory),
            claudeProjects: root.appending(path: "projects", directoryHint: .isDirectory),
            claudeLogs: root.appending(path: "Logs", directoryHint: .isDirectory),
            claudeApp: root.appending(path: "Applications/Claude.app", directoryHint: .isDirectory),
            chromeApp: root.appending(path: "Applications/Google Chrome.app", directoryHint: .isDirectory))
        let fm = FileManager.default
        for d in [paths.claudeUserData, paths.chromeProfile, paths.sessionSync, paths.claudeProjects, paths.claudeLogs,
                  paths.claudeApp.appending(path: "Contents"), paths.claudeCodeDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.26454.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: paths.claudeInfoPlist)
        try Data().write(to: paths.mainLog)
        set(Paths.claudeBundleID) { $0.running = true }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var now: Date { state.withLock { $0.clock } }

    func app(_ id: String) -> AppSim { state.withLock { $0.apps[id] ?? AppSim() } }

    func set(_ id: String, _ body: (inout AppSim) -> Void) {
        state.withLock { s in
            var a = s.apps[id] ?? AppSim()
            body(&a)
            s.apps[id] = a
        }
    }

    func advance(_ seconds: Double) {
        var exited: [String] = []
        state.withLock { s in
            s.clock = s.clock.addingTimeInterval(seconds)
            for (id, var a) in s.apps where a.running {
                if let q = a.quitRequestedAt, case .after(let d) = a.exit, s.clock.timeIntervalSince(q) >= d {
                    a.running = false
                    a.quitRequestedAt = nil
                    a.exitedAt = s.clock
                    s.apps[id] = a
                    exited.append(id)
                }
            }
        }
        for id in exited { onExit[id]?() }
        advanceWindows()
        for (id, item) in afterExit {
            let a = app(id)
            guard let t = a.exitedAt, now.timeIntervalSince(t) >= item.delay else { continue }
            let first = afterExitDone.withLock { $0.insert(id).inserted }
            if first { item.action() }
        }
    }

    func processes() -> [ProcInfo] {
        let claudeBack = reappearsWhen[Paths.claudeBundleID]?() ?? false
        let (exitedAt, clock) = state.withLock { ($0.apps[Paths.claudeBundleID]?.exitedAt, $0.clock) }
        let extras = extraProcesses(exitedAt, clock)
        let chromeBack = reappearsWhen[Paths.chromeBundleID]?() ?? false
        return state.withLock { s in
            var out: [ProcInfo] = []
            let claude = s.apps[Paths.claudeBundleID] ?? AppSim()
            let claudeApp = paths.claudeApp.path(percentEncoded: false)
            let helperExe = claudeApp + "/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
            if claude.running || claudeBack {
                out.append(ProcInfo(pid: 100, path: claudeApp + "/Contents/MacOS/Claude", args: [claudeApp + "/Contents/MacOS/Claude"], parentPID: 1))
            }
            // Real shape: the main window's helpers carry the default folder flag although the main process has none.
            if mainHelper, claude.running || claudeBack || mainHelperOutlivesMain {
                out.append(ProcInfo(pid: 110, path: helperExe,
                                    args: [helperExe, "--type=gpu-process", "--user-data-dir=" + paths.claudeUserData.path(percentEncoded: false)],
                                    parentPID: 100))
            }
            for w in windowState.withLock({ Array($0.sims.values) }).sorted(by: { $0.pid < $1.pid }) where w.running {
                let exe = claudeApp + "/Contents/MacOS/Claude"
                out.append(ProcInfo(pid: w.pid, path: exe, args: [exe, "--user-data-dir=\(w.dataDir)"], parentPID: 1))
                // Helpers are found by their parent alone.
                out.append(ProcInfo(pid: w.helperPID, path: claudeApp + "/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
                                    args: [], parentPID: w.pid))
            }
            if claude.running || (claude.exitedAt.map { s.clock.timeIntervalSince($0) < claude.childLinger } ?? false) {
                out.append(ProcInfo(pid: 101, path: paths.claudeCodeDir.path(percentEncoded: false) + "/2.1.289/x/claude.app/Contents/MacOS/claude"))
            }
            // Never counts: Chrome's native host and ShipIt live in the bundle but outlive the app.
            out.append(ProcInfo(pid: 102, path: claudeApp + "/Contents/Helpers/chrome-native-host"))
            out.append(ProcInfo(pid: 103, path: claudeApp + "/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"))
            for (i, path) in extras.enumerated() { out.append(ProcInfo(pid: Int32(300 + i), path: path)) }
            if (s.apps[Paths.chromeBundleID] ?? AppSim()).running || chromeBack {
                out.append(ProcInfo(pid: 200, path: paths.chromeApp.path(percentEncoded: false) + "/Contents/MacOS/Google Chrome"))
            }
            return out
        }
    }

    func bundleID(for url: URL) -> String {
        url.standardizedFileURL == paths.chromeApp.standardizedFileURL ? Paths.chromeBundleID : Paths.claudeBundleID
    }

    // MARK: Setup helpers

    /// Two accounts: A is live (and registered), B has a saved slot.
    func setUpTwoAccounts(a: String = FakeWorld.a, b: String = FakeWorld.b, store: AccountStore) throws {
        try Fixture.makeCookiesDB(paths.liveCookies, rows: Fixture.desktopCookies(for: a) + Fixture.otherSiteCookies())
        try Data().write(to: paths.liveCookiesJournal)
        try Fixture.writeConfig(paths.liveConfig, account: a)
        try store.register(a, label: "alpha@example.com", now: now)
        try store.register(b, label: "beta@example.com", now: now)
        try Fixture.makeCookiesDB(paths.slotDesktopCookies(b), rows: Fixture.desktopCookies(for: b))
        // As if the engine had saved it.
        try FileOps.chmodTree(paths.slotsDir)
    }

    static let a = "aaaaaaaa-0000-4000-8000-000000000001"
    static let b = "bbbbbbbb-0000-4000-8000-000000000002"
    static let c = "cccccccc-0000-4000-8000-000000000003"

    func logLine(_ text: String, at date: Date) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: date)) [info] \(text)\n"
        if let h = try? FileHandle(forWritingTo: paths.mainLog) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        }
    }

    func makeEngine(quitTimeout: Double = 120, sync: SyncRunner? = nil, gate: ActionGate = ActionGate()) -> SwitchEngine {
        SwitchEngine(paths: paths, probe: FakeProbe(world: self), controller: FakeController(world: self),
                     ticker: FakeTicker(world: self), sync: sync ?? FakeSync(), quitTimeout: quitTimeout,
                     verifyTimeout: 10, chromeVerifyTimeout: 3, gate: gate)
    }

    func digest(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    func makeWindowEngine(sync: SyncRunner? = nil, settings: FakeSettingsSync? = nil,
                          launchTimeout: Double = 30, closeTimeout: Double = 20, gate: ActionGate = ActionGate()) -> WindowEngine {
        WindowEngine(paths: paths, probe: FakeProbe(world: self), controller: FakeController(world: self),
                     ticker: FakeTicker(world: self), sync: sync ?? FakeSync(world: self),
                     settings: settings ?? FakeSettingsSync(world: self),
                     launchTimeout: launchTimeout, closeTimeout: closeTimeout, gate: gate)
    }

    static func id(_ n: Int) -> String { "dddddddd-0000-4000-8000-00000000000\(n)" }

    /// Registers accounts 1...n (ids `FakeWorld.id`) so windows can be opened for them.
    func registerAccounts(_ n: Int, store: AccountStore) throws {
        for i in 1...n { try store.register(FakeWorld.id(i), label: "w\(i)@example.com", now: now) }
    }

    /// A signed-in window folder: config.json naming the account.
    func makeSignedInWindowDir(_ account: String) throws -> URL {
        let dir = paths.windowDataDir(account)
        try FileOps.ensureDirectory(paths.storeRoot)
        try FileOps.ensureDirectory(paths.windowsRoot)
        try FileOps.ensureDirectory(dir)
        try Fixture.writeConfig(dir.appending(path: "config.json"), account: account)
        return dir
    }

    /// The window's own config already has the background jobs switched off (as a past settings copy left it).
    func writeJobsOff(_ dir: URL) throws {
        try FileOps.ensureDirectory(paths.storeRoot)
        try FileOps.ensureDirectory(paths.windowsRoot)
        try FileOps.ensureDirectory(dir)
        var prefs: [String: Any] = Dictionary(uniqueKeysWithValues: ParallelWindows.backgroundJobKeys.map { ($0, false) })
        for k in ParallelWindows.backgroundJobDayKeys { prefs[k] = 0 }
        try JSONSerialization.data(withJSONObject: ["preferences": prefs]).write(to: dir.appending(path: "claude_desktop_config.json"))
    }

    /// A signed-in window that is already running.
    @discardableResult
    func runWindow(_ account: String) throws -> Int32 {
        let dir = try makeSignedInWindowDir(account)
        return addWindow(dataDir: ParallelWindows.dirString(dir))
    }
}

struct FakeTicker: Ticker {
    let world: FakeWorld
    func now() -> Date { world.now }
    func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        world.advance(seconds)
        await Task.yield()
    }
    func sleepBlocking(seconds: Double) { world.advance(seconds) }
}

struct FakeProbe: ProcessProbe {
    let world: FakeWorld
    func processes() -> [ProcInfo] { world.processes() }
}

struct FakeController: AppController {
    let world: FakeWorld
    func isRunning(bundleID: String) async -> Bool { world.app(bundleID).running }
    func open(url: URL, inAppAt app: URL) async throws {
        world.openedURLs.withLock { $0.append(url) }
    }
    func requestQuit(pid: Int32) async {
        world.pidRequests.withLock { $0.append(("quit", pid)) }
        if pid == 100 {
            world.log("quit-main")
            let now = world.now
            world.set(Paths.claudeBundleID) { a in
                a.quitRequests += 1
                if a.running, a.quitRequestedAt == nil { a.quitRequestedAt = now }
            }
        } else {
            world.quitWindow(pid: pid)
        }
    }
    func signalTerminate(pid: Int32) async {
        world.pidRequests.withLock { $0.append(("SIGTERM", pid)) }
        if pid == 100 {
            let now = world.now
            world.set(Paths.claudeBundleID) { a in if a.running, a.quitRequestedAt == nil { a.quitRequestedAt = now } }
        } else {
            world.quitWindow(pid: pid)
        }
    }
    func hasVisibleWindow(pid: Int32) async -> Bool {
        pid == 100 && world.app(Paths.claudeBundleID).running && world.app(Paths.claudeBundleID).windowVisible
    }
    func launchNewInstance(appAt url: URL, arguments: [String]) async throws {
        world.launches.withLock { $0.append(arguments) }
        if let flag = arguments.first(where: { $0.hasPrefix(ClaudeProcessMap.userDataFlag) }) {
            world.log("launch-window")
            if world.windowLaunchFails { return }
            world.addWindow(dataDir: String(flag.dropFirst(ClaudeProcessMap.userDataFlag.count)))
        } else {
            world.log("launch-main")
            if world.mainLaunchFails { return }
            world.set(Paths.claudeBundleID) { a in
                a.running = true
                a.opens += 1
                a.quitRequestedAt = nil
            }
            world.onOpen[Paths.claudeBundleID]?(world.now)
        }
    }
    func requestQuit(bundleID: String) async {
        if bundleID == Paths.claudeBundleID {
            world.bundleQuitCount.withLock { $0 += 1 }
            world.log("quit-main")
        }
        let now = world.now
        world.quitRequestedAt.withLock { if $0[bundleID] == nil { $0[bundleID] = now } }
        world.set(bundleID) { a in
            a.quitRequests += 1
            if a.running, a.quitRequestedAt == nil { a.quitRequestedAt = now }
        }
    }
    func hasVisibleWindow(bundleID: String) async -> Bool {
        let a = world.app(bundleID)
        return a.running && a.windowVisible
    }
    func open(appAt url: URL) async throws {
        let id = world.bundleID(for: url)
        world.set(id) { a in
            a.running = true
            a.opens += 1
        }
        world.onOpen[id]?(world.now)
    }
}

final class FakeSync: SyncRunner, @unchecked Sendable {
    let calls = Mutex<[[String]]>([])
    let failure: String?
    let world: FakeWorld?
    init(failure: String? = nil, world: FakeWorld? = nil) {
        self.failure = failure
        self.world = world
    }
    func run(arguments: [String], timeout: Double) async -> String? {
        calls.withLock { $0.append(arguments) }
        world?.log("chat-sync")
        return failure
    }
}

/// Opens once and stays open: whoever waits on it continues.
final class Latch: @unchecked Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { c in
            let isOpen = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(c)
                return false
            }
            if isOpen { c.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for c in waiters { c.resume() }
    }
}

/// A chat sync that can be held mid-pass, to keep an engine action "running" while a test asks for another.
final class GatedSync: SyncRunner, @unchecked Sendable {
    let world: FakeWorld
    private let state = Mutex<(latch: Latch?, entered: Int)>((nil, 0))
    init(world: FakeWorld) { self.world = world }

    /// How many passes have started (held or not).
    var entered: Int { state.withLock { $0.entered } }
    /// From now on every pass waits until `release()`.
    func hold() { state.withLock { $0.latch = Latch() } }
    func release() { state.withLock { $0.latch }?.open() }

    func run(arguments: [String], timeout: Double) async -> String? {
        world.log("chat-sync")
        let latch = state.withLock { s -> Latch? in
            s.entered += 1
            return s.latch
        }
        await latch?.wait()
        return nil
    }
}

/// Polls (real time) until the condition holds; records an issue if it never does.
func until(_ what: String, _ condition: @Sendable () -> Bool) async {
    for _ in 0..<3000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out waiting for \(what)")
}

final class FakeSettingsSync: WindowSettingsSync, @unchecked Sendable {
    let calls = Mutex<[(from: URL, to: URL)]>([])
    let failure: String?
    let world: FakeWorld
    init(world: FakeWorld, failure: String? = nil) {
        self.world = world
        self.failure = failure
    }
    func apply(from main: URL, to window: URL) async -> String? {
        calls.withLock { $0.append((main, window)) }
        world.log("settings-sync")
        // The script refuses to run while the window is open.
        if world.isWindowRunning(dataDir: window) { return "refused: window is open" }
        return failure
    }
}

final class TaskBox: @unchecked Sendable {
    let lock = NSLock()
    var task: Task<SwitchOutcome, Error>?
    var phases: [SwitchPhase] = []
    func record(_ p: SwitchPhase) { lock.withLock { phases.append(p) } }
    var seen: [SwitchPhase] { lock.withLock { phases } }
}
