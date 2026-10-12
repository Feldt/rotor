import Foundation
import Synchronization
import Testing
@testable import ClaudeAccountsCore

// MARK: Helpers

private func writeBusyTranscript(_ w: FakeWorld, count: Int = 1) throws {
    let dir = w.paths.claudeProjects.appending(path: "proj")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let working = """
    {"type":"user","entrypoint":"claude-desktop","message":{}}
    {"type":"assistant","message":{"stop_reason":"tool_use"}}
    """
    for i in 0..<count { try Data(working.utf8).write(to: dir.appending(path: "busy\(i).jsonl")) }
}

/// A world with main signed in as `FakeWorld.a`, plus accounts 1...n registered for windows.
private func windowWorld(accounts n: Int = 5) throws -> (FakeWorld, WindowEngine) {
    let w = try FakeWorld()
    let engine = w.makeWindowEngine()
    try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
    try engine.store.register(FakeWorld.a, label: "alpha@example.com", now: w.now)
    try w.registerAccounts(n, store: engine.store)
    return (w, engine)
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: Rules, registry, process map

@Suite("Parallel windows: rules and registry")
struct ParallelWindowRulesTests {
    @Test("cap of 3 extra windows: the fourth is refused, a closed one frees a place")
    func cap() async throws {
        let (w, engine) = try windowWorld()
        for i in 1...3 { try w.runWindow(FakeWorld.id(i)) }
        #expect(engine.liveWindows().count == 3)
        #expect(throws: WindowError.capReached(3)) { try engine.checkCanOpen(FakeWorld.id(4)) }
        await #expect(throws: WindowError.capReached(3)) { _ = try await engine.open(FakeWorld.id(4)) }
        #expect(w.launches.withLock { $0.isEmpty })

        // Two open leaves room.
        try await engine.close(FakeWorld.id(3))
        #expect(engine.liveWindows().count == 2)
        try engine.checkCanOpen(FakeWorld.id(4))
        #expect(ParallelWindows.maxExtraWindows == 3)
    }

    @Test("one account in one place: the main account cannot open as a window")
    func mainAccountRefused() async throws {
        let (w, engine) = try windowWorld()
        _ = try w.makeSignedInWindowDir(FakeWorld.a)
        #expect(throws: WindowError.accountIsMain(FakeWorld.a)) { try engine.checkCanOpen(FakeWorld.a) }
        await #expect(throws: WindowError.accountIsMain(FakeWorld.a)) { _ = try await engine.open(FakeWorld.a) }
        #expect(w.launches.withLock { $0.isEmpty })
    }

    @Test("one account in one place: a pure rule check and an already-open window is a no-op")
    func onePlaceRule() async throws {
        let (w, engine) = try windowWorld()
        #expect(throws: WindowError.accountInWindow("a1234567")) {
            try ParallelWindows.checkOpen(account: "a1234567", mainAccount: nil, openWindows: ["a1234567"])
        }
        let pid = try w.runWindow(FakeWorld.id(1))
        let r = try await engine.open(FakeWorld.id(1))
        #expect(r.alreadyOpen && r.pid == pid)
        #expect(w.launches.withLock { $0.isEmpty })
    }

    @Test("switching the main window to an account that is open in a window is refused, nothing is touched")
    func switchRefusedForWindowAccount() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try w.runWindow(FakeWorld.b)
        let liveBefore = try Fixture.blobs(w.paths.liveCookies)
        await #expect(throws: WindowError.accountInWindow(FakeWorld.b)) { try await engine.switchTo(FakeWorld.b) }
        #expect(w.bundleQuitCount.withLock { $0 } == 0)
        #expect(w.pidRequests.withLock { $0.isEmpty })
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(try Fixture.blobs(w.paths.liveCookies) == liveBefore)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.a)
    }

    @Test("account ids name folders, so only uuid-like text is accepted")
    func ids() throws {
        let (_, engine) = try windowWorld()
        for bad in ["../evil", "a/b", "", "zzzzzzzz", "-aaaaaaaa", "abc"] {
            #expect(ParallelWindows.isValidAccountID(bad) == false)
            #expect(throws: WindowError.invalidAccount(bad)) { try engine.checkCanOpen(bad) }
        }
        #expect(ParallelWindows.isValidAccountID(FakeWorld.a))
    }

    @Test("registry: a missing file reads as empty, status creates nothing")
    func registryMissing() throws {
        let (w, engine) = try windowWorld()
        #expect(FileOps.exists(w.paths.windowsFile) == false)
        #expect(WindowRegistryStore.read(w.paths) == WindowRegistry())
        #expect(engine.status().isEmpty)
        #expect(FileOps.exists(w.paths.windowsFile) == false)
        // An unreadable file also reads as empty.
        try FileManager.default.createDirectory(at: w.paths.storeRoot, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: w.paths.windowsFile)
        #expect(WindowRegistryStore.read(w.paths).windows.isEmpty)
    }

    @Test("registry: atomic write, 0600, pinned shape with explicit nulls, no temp files left")
    func registryWrite() throws {
        let w = try FakeWorld()
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let reg = WindowRegistry(windows: [
            WindowRecord(accountId: FakeWorld.id(1), dataDir: "/x/windows/\(FakeWorld.id(1))", signedIn: true, openedAt: opened, pid: 4242),
            WindowRecord(accountId: FakeWorld.id(2), dataDir: "/x/windows/\(FakeWorld.id(2))", signedIn: false),
        ])
        try WindowRegistryStore.write(reg, to: w.paths)
        try WindowRegistryStore.write(reg, to: w.paths) // overwrite replaces, never appends
        #expect(FileOps.mode(w.paths.windowsFile) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: w.paths.storeRoot.path(percentEncoded: false))
            .filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: w.paths.windowsFile)) as! [String: Any]
        #expect(json["version"] as? Int == 1)
        let list = json["windows"] as! [[String: Any]]
        #expect(list.count == 2)
        #expect(Set(list[0].keys) == ["accountId", "dataDir", "signedIn", "openedAt", "pid"])
        #expect(list[0]["pid"] as? Int == 4242)
        #expect(list[0]["openedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(list[1]["pid"] is NSNull && list[1]["openedAt"] is NSNull)
        #expect(list[1]["signedIn"] as? Bool == false)
        #expect(WindowRegistryStore.read(w.paths) == reg)
    }

    @Test("process map: exact arguments find the window, helpers belong to it by parent, main stays main")
    func processMap() {
        let exe = "/Applications/Claude.app/Contents/MacOS/Claude"
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        let procs = [
            ProcInfo(pid: 10, path: exe, args: [exe], parentPID: 1),
            ProcInfo(pid: 11, path: helper, args: [helper, "--type=gpu"], parentPID: 10),
            ProcInfo(pid: 20, path: exe, args: [exe, "--user-data-dir=/s/windows/w1"], parentPID: 1),
            ProcInfo(pid: 21, path: helper, args: [], parentPID: 20),
            ProcInfo(pid: 22, path: helper, args: [helper, "--user-data-dir=/s/windows/w1", "--type=renderer"], parentPID: 99),
            ProcInfo(pid: 30, path: exe, args: [exe, "--user-data-dir=/s/windows/w2", "--extra"], parentPID: 1),
        ]
        let m = ClaudeProcessMap(procs)
        #expect(m.mainPID == 10)
        #expect(m.exactWindowPID(dataDir: "/s/windows/w1") == 20)
        #expect(m.exactWindowPID(dataDir: "/s/windows/w2") == nil) // extra argument: never signalled
        #expect(m.windowDataDir(of: procs[1]) == nil)
        // The main window's helpers carry the default folder flag; that folder is not an extra window's.
        let mainHelperProc = ProcInfo(pid: 12, path: helper, args: [helper, "--type=utility", "--user-data-dir=/u/Application Support/Claude"], parentPID: 10)
        #expect(m.windowDataDir(of: mainHelperProc) == nil)
        #expect(m.windowDataDir(of: procs[3]) == "/s/windows/w1")
        #expect(m.windowDataDir(of: procs[4]) == "/s/windows/w1")
        #expect(Set(m.processes(ofWindow: "/s/windows/w1").map(\.pid)) == [20, 21, 22])
    }

    @Test("a process is placed by the process tree before its flag, and the windows folder comes from Paths")
    func processTreeBeforeFlag() throws {
        let w = try FakeWorld()
        let root = ParallelWindows.dirString(w.paths.windowsRoot)
        let exe = "/Applications/Claude.app/Contents/MacOS/Claude"
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        let w1 = "\(root)/\(FakeWorld.id(1))"
        let mainDefault = "--user-data-dir=/Users/x/Library/Application Support/Claude"
        let procs = [
            ProcInfo(pid: 10, path: exe, args: [exe], parentPID: 1),
            ProcInfo(pid: 20, path: exe, args: [exe, "--user-data-dir=\(w1)"], parentPID: 1),
            // Below the main window's browser process, carrying a window's folder flag: still the main window's.
            ProcInfo(pid: 11, path: helper, args: [helper, "--type=utility", "--user-data-dir=\(w1)"], parentPID: 10),
            ProcInfo(pid: 12, path: helper, args: [helper, "--type=renderer"], parentPID: 11),
            // Below the window's browser process, carrying the main folder flag: still that window's.
            ProcInfo(pid: 21, path: helper, args: [helper, "--type=utility", mainDefault], parentPID: 20),
            // Left behind by a window whose browser process is gone: placed by a flag that names a folder inside the windows root.
            ProcInfo(pid: 30, path: helper, args: [helper, "--user-data-dir=\(root)/\(FakeWorld.id(2))"], parentPID: 1),
            // A path that only looks like a windows folder (the old fixed marker would have claimed it).
            ProcInfo(pid: 31, path: helper, args: [helper, "--user-data-dir=/Users/x/Library/Application Support/ClaudeAccounts/windows/\(FakeWorld.id(3))"],
                     parentPID: 1),
            // The windows root itself, and a folder deeper than one level, are not a window's folder.
            ProcInfo(pid: 32, path: helper, args: [helper, "--user-data-dir=\(root)"], parentPID: 1),
            ProcInfo(pid: 33, path: helper, args: [helper, "--user-data-dir=\(root)/\(FakeWorld.id(2))/deeper"], parentPID: 1),
        ]
        func owner(_ pid: Int32, _ m: ClaudeProcessMap) -> String? { m.windowDataDir(of: procs.first { $0.pid == pid }!) }
        let m = ClaudeProcessMap(procs, windowsRoot: root)
        #expect(owner(11, m) == nil && owner(12, m) == nil)
        #expect(owner(20, m) == w1 && owner(21, m) == w1)
        #expect(owner(30, m) == "\(root)/\(FakeWorld.id(2))")
        #expect(owner(31, m) == nil && owner(32, m) == nil && owner(33, m) == nil)
        #expect(owner(10, m) == nil)
        // Without a known windows folder a lone flag only counts when a live window uses that folder.
        let bare = ClaudeProcessMap(procs)
        #expect(owner(30, bare) == nil && owner(31, bare) == nil)
        #expect(owner(21, bare) == w1 && owner(11, bare) == nil)
    }

    @Test("the chat sync the app runs is the bundled or configured mirror.py, else the deployed one")
    func mirrorScriptChoice() throws {
        let w = try FakeWorld()
        #expect(PythonSyncRunner.defaultScript(paths: w.paths, environment: [:]) == w.paths.mirrorScript)
        let custom = PythonSyncRunner.defaultScript(paths: w.paths, environment: ["CLAUDE_ACCOUNTS_MIRROR_SCRIPT": "/x/mirror.py"])
        #expect(custom.path(percentEncoded: false) == "/x/mirror.py")
    }

    @Test("Repair Chat Sync: --reload and --write-plist run the deployed mirror.py, sync passes the bundled one")
    func agentArgumentsRunTheDeployedScript() async throws {
        // mirror.py --reload checks that the LaunchAgent's plist runs the very file it was called as, and the plist
        // runs the deployed copy: run from the bundled copy, Repair always failed.
        let dir = FileManager.default.temporaryDirectory.appending(path: "mirror-pick-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = "import pathlib, sys\npathlib.Path(__file__).with_name('ran.txt').write_text(' '.join(sys.argv[1:]))\n"
        var scripts: [String: URL] = [:]
        for name in ["bundled", "deployed"] {
            let d = dir.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            scripts[name] = d.appending(path: "mirror.py")
            try Data(stub.utf8).write(to: scripts[name]!)
        }
        func ran(_ name: String) -> String? {
            try? String(contentsOf: dir.appending(path: "\(name)/ran.txt"), encoding: .utf8)
        }
        let runner = PythonSyncRunner(script: scripts["bundled"]!, deployedScript: scripts["deployed"]!)

        #expect(await runner.run(arguments: [], timeout: 30) == nil)
        #expect(ran("bundled") == "" && ran("deployed") == nil)

        for args in [["--reload"], ["--write-plist"], ["-v", "--reload"]] {
            try? FileManager.default.removeItem(at: dir.appending(path: "bundled/ran.txt"))
            #expect(await runner.run(arguments: args, timeout: 30) == nil)
            #expect(ran("deployed") == args.joined(separator: " "))
            #expect(ran("bundled") == nil)
            try? FileManager.default.removeItem(at: dir.appending(path: "deployed/ran.txt"))
        }
        // Other flags stay with the bundled copy.
        #expect(await runner.run(arguments: ["--dry-run"], timeout: 30) == nil)
        #expect(ran("bundled") == "--dry-run" && ran("deployed") == nil)
        // A missing deployed copy is reported, not papered over with the bundled one.
        let none = PythonSyncRunner(script: scripts["bundled"]!, deployedScript: dir.appending(path: "nowhere/mirror.py"))
        #expect(await none.run(arguments: ["--reload"], timeout: 30) == "mirror.py not found")
    }

    @Test("the app runs the bundled mirror.py; the command line tool, outside the .app, falls back to the deployed one")
    func cliFallsBackToTheDeployedScript() throws {
        let w = try FakeWorld()
        let app = w.root.appending(path: "Rotor.app", directoryHint: .isDirectory)
        let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: resources.appending(path: "mirror.py"))

        // The app: Bundle.main is the .app, so its Resources/mirror.py is the sync script.
        let inApp = AppBundle.resources(bundleURL: app, resourceURL: resources)
        #expect(inApp == resources)
        #expect(PythonSyncRunner.system(paths: w.paths, environment: [:], resources: inApp).script == resources.appending(path: "mirror.py"))

        // The tool run through ~/.local/bin/rotor (or its claude-accounts alias): Bundle.main is the symlink's folder, which is no bundle.
        let bin = URL(filePath: "/Users/x/.local/bin", directoryHint: .isDirectory)
        let inTool = AppBundle.resources(bundleURL: bin, resourceURL: bin)
        #expect(inTool == nil)
        let tool = PythonSyncRunner.system(paths: w.paths, environment: [:], resources: inTool)
        #expect(tool.script == w.paths.mirrorScript && tool.deployedScript == w.paths.mirrorScript)
        // ...and honours the override.
        let custom = PythonSyncRunner.system(paths: w.paths, environment: ["CLAUDE_ACCOUNTS_MIRROR_SCRIPT": "/x/mirror.py"], resources: inTool)
        #expect(custom.script.path(percentEncoded: false) == "/x/mirror.py" && custom.deployedScript == w.paths.mirrorScript)
    }

    @Test("argv parsing from KERN_PROCARGS2 and the live probe reads this process's own arguments")
    func argv() {
        var b: [UInt8] = [2, 0, 0, 0]
        b += Array("/a/Claude".utf8) + [0, 0, 0]
        b += Array("/a/Claude".utf8) + [0] + Array("--user-data-dir=/d".utf8) + [0]
        b += Array("HOME=/x".utf8) + [0]
        #expect(SystemProcessProbe.parseProcArgs(b) == ["/a/Claude", "--user-data-dir=/d"])
        #expect(SystemProcessProbe.parseProcArgs([1, 0]) == [])
        #expect(SystemProcessProbe.arguments(of: getpid()).isEmpty == false)
    }
}

// MARK: Window engine

@Suite("Parallel windows: window engine")
struct WindowEngineTests {
    @Test("open: chat sync, then settings sync, then launch with the pinned flag; registry records the pid")
    func openSignedIn() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        let dir = try w.makeSignedInWindowDir(id)
        let r = try await engine.open(id)
        #expect(r.alreadyOpen == false && r.warnings.isEmpty)
        #expect(w.events.withLock { $0 } == ["chat-sync", "settings-sync", "launch-window"])
        #expect(w.launches.withLock { $0 } == [["--user-data-dir=\(ParallelWindows.dirString(dir))"]])
        #expect(w.windowPID(dataDir: dir) == r.pid)
        let rec = try #require(WindowRegistryStore.read(w.paths).record(id))
        #expect(rec.pid == r.pid && rec.signedIn && rec.openedAt != nil)
        #expect(rec.dataDir == ParallelWindows.dirString(dir))
        #expect(FileOps.mode(dir) == 0o700 && FileOps.mode(w.paths.windowsRoot) == 0o700)
        // The main window was not touched.
        #expect(w.app(Paths.claudeBundleID).running && w.bundleQuitCount.withLock { $0 } == 0)
        #expect(w.pidRequests.withLock { $0.isEmpty })
    }

    @Test("open: a window that was never signed in asks for its first sign-in and launches nothing")
    func openNeedsSignIn() async throws {
        let (w, engine) = try windowWorld()
        await #expect(throws: WindowError.needsFirstSignIn(FakeWorld.id(1))) { _ = try await engine.open(FakeWorld.id(1)) }
        #expect(w.launches.withLock { $0.isEmpty })
    }

    @Test("open: a failed settings copy refuses the launch unless background jobs are already off in the window")
    func openRefusedWithoutJobsOff() async throws {
        let w = try FakeWorld()
        let engine = w.makeWindowEngine(settings: FakeSettingsSync(world: w, failure: "settings sync exited 2"))
        try engine.store.register(FakeWorld.id(1), label: "w1", now: w.now)
        _ = try w.makeSignedInWindowDir(FakeWorld.id(1))
        await #expect(throws: WindowError.settingsNotApplied("settings sync exited 2")) { _ = try await engine.open(FakeWorld.id(1)) }
        #expect(w.launches.withLock { $0.isEmpty })
        #expect(w.windowSims().isEmpty)
    }

    @Test("open: sync trouble is a warning, the window still opens (jobs already off)")
    func openWithWarnings() async throws {
        let w = try FakeWorld()
        let engine = w.makeWindowEngine(sync: FakeSync(failure: "mirror.py exited 1", world: w),
                                        settings: FakeSettingsSync(world: w, failure: "settings sync exited 2"))
        try engine.store.register(FakeWorld.id(1), label: "w1", now: w.now)
        let dir = try w.makeSignedInWindowDir(FakeWorld.id(1))
        try w.writeJobsOff(dir)
        let r = try await engine.open(FakeWorld.id(1))
        #expect(r.warnings.count == 2)
        #expect(w.isWindowRunning(dataDir: w.paths.windowDataDir(FakeWorld.id(1))))
    }

    @Test("a failed settings copy leaves the window closed unless every background job is off, auto-archive days included")
    func jobsOffNeedsInactiveDaysZero() async throws {
        let w = try FakeWorld()
        let engine = w.makeWindowEngine(settings: FakeSettingsSync(world: w, failure: "settings sync exited 2"))
        let id = FakeWorld.id(1)
        try engine.store.register(id, label: "w1", now: w.now)
        _ = try w.makeSignedInWindowDir(id)
        let dir = w.paths.windowDataDir(id)
        func writeConfig(days: Any?, keepAwake: Bool = true) throws {
            var prefs: [String: Any] = Dictionary(uniqueKeysWithValues: ParallelWindows.backgroundJobKeys.map { ($0, false) })
            if let days { prefs["ccAutoArchiveInactiveDays"] = days }
            // The keep-awake options only hold the Mac awake while a session here works: they may stay on.
            prefs["ccKeepAwakeWhileWorking"] = keepAwake
            prefs["ccKeepAwakeOnBattery"] = keepAwake
            try JSONSerialization.data(withJSONObject: ["preferences": prefs]).write(to: dir.appending(path: "claude_desktop_config.json"))
        }
        try writeConfig(days: 14)
        #expect(ParallelWindows.backgroundJobsOff(in: dir) == false)
        await #expect(throws: WindowError.self) { _ = try await engine.open(id) }
        #expect(w.windowSims().isEmpty)
        try writeConfig(days: nil)
        #expect(ParallelWindows.backgroundJobsOff(in: dir) == false)  // not set: Claude's default is 0, but "not known to be off"
        try writeConfig(days: false)
        #expect(ParallelWindows.backgroundJobsOff(in: dir) == false)  // false is not a day count
        try writeConfig(days: 0)
        #expect(ParallelWindows.backgroundJobsOff(in: dir))
        _ = try await engine.open(id)
        #expect(w.isWindowRunning(dataDir: dir))
        #expect(ParallelWindows.backgroundJobDayKeys == ["ccAutoArchiveInactiveDays"])
    }

    @Test("open: a launch that never produces the process fails and records no pid")
    func openLaunchFails() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        _ = try w.makeSignedInWindowDir(id)
        w.windowLaunchFails = true
        await #expect(throws: WindowError.launchFailed(id)) { _ = try await engine.open(id) }
        #expect(WindowRegistryStore.read(w.paths).record(id)?.pid == nil)
    }

    @Test("close signals only that window's exact pid, never the main window or another window")
    func scopedClose() async throws {
        let (w, engine) = try windowWorld()
        w.mainHelper = true
        let p1 = try w.runWindow(FakeWorld.id(1))
        let p2 = try w.runWindow(FakeWorld.id(2))
        _ = try await engine.open(FakeWorld.id(1)) // registers them
        _ = try await engine.open(FakeWorld.id(2))
        w.events.withLock { $0.removeAll() }

        let warning = try await engine.close(FakeWorld.id(1))
        #expect(warning == nil)
        let reqs = w.pidRequests.withLock { $0 }
        #expect(reqs.map(\.pid) == [p1])
        #expect(reqs.allSatisfy { $0.kind == "SIGTERM" })
        #expect(w.bundleQuitCount.withLock { $0 } == 0)
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(engine.mainPID() == 100)
        #expect(w.window(pid: p1)?.running == false)
        #expect(w.window(pid: p2)?.running == true)
        // The registry follows; the other window keeps its pid.
        let reg = WindowRegistryStore.read(w.paths)
        #expect(reg.record(FakeWorld.id(1))?.pid == nil && reg.record(FakeWorld.id(1))?.signedIn == true)
        #expect(reg.record(FakeWorld.id(2))?.pid == p2)
        // Chats started in the window flow out after it closes.
        #expect(w.events.withLock { $0 } == ["chat-sync"])
    }

    @Test("close never forces: a window that ignores SIGTERM is left running and the error says so")
    func closeNeverForces() async throws {
        let (w, engine) = try windowWorld()
        let p1 = try w.runWindow(FakeWorld.id(1))
        w.windowsIgnoreSigterm = true
        await #expect(throws: WindowError.windowStillRunning(FakeWorld.id(1))) { try await engine.close(FakeWorld.id(1)) }
        let reqs = w.pidRequests.withLock { $0 }
        #expect(reqs.isEmpty == false)
        #expect(reqs.allSatisfy { $0.pid == p1 && $0.kind == "SIGTERM" })
        #expect(w.window(pid: p1)?.running == true)
        #expect(w.app(Paths.claudeBundleID).running)
    }

    @Test("closing a window that is not running just updates the registry")
    func closeNotRunning() async throws {
        let (w, engine) = try windowWorld()
        _ = try w.makeSignedInWindowDir(FakeWorld.id(1))
        try await engine.close(FakeWorld.id(1))
        #expect(w.pidRequests.withLock { $0.isEmpty })
    }

    @Test("quitting the main window while windows run asks only the main pid; the windows keep running")
    func mainQuitIsScoped() async throws {
        let (w, engine) = try windowWorld()
        w.mainHelper = true
        let p1 = try w.runWindow(FakeWorld.id(1))
        let p2 = try w.runWindow(FakeWorld.id(2))
        // A bundle-level answer would say "still running" because of the windows.
        #expect(await engine.controller.isRunning(bundleID: Paths.claudeBundleID))
        try await engine.quitter.quitAndWait(engine.mainApp)
        #expect(w.pidRequests.withLock { $0.map(\.pid) } == [100])
        #expect(w.bundleQuitCount.withLock { $0 } == 0)
        #expect(w.app(Paths.claudeBundleID).running == false)
        #expect(w.window(pid: p1)?.running == true && w.window(pid: p2)?.running == true)
        #expect(engine.mainPID() == nil)
        #expect(await engine.controller.isRunning(bundleID: Paths.claudeBundleID) == false)
    }

    @Test("main-window scope keeps its own helpers (they carry the default folder flag) while windows run")
    func mainScopeKeepsHelpers() async throws {
        let (w, engine) = try windowWorld()
        w.mainHelper = true
        _ = try w.runWindow(FakeWorld.id(1))
        let required = engine.quitter.requiredProcesses(engine.mainApp).map(\.pid)
        #expect(Set(required) == [100, 110]) // not the window's browser (>= 1000) or its helper
        // The main browser process is gone but its cookie-writing helper is not: still running, quit must wait.
        w.mainHelperOutlivesMain = true
        w.set(Paths.claudeBundleID) { $0.running = false }
        #expect(await engine.quitter.isRunning(engine.mainApp))
    }

    @Test("a main-window switch with windows open leaves them alone and starts the main window as a new instance")
    func switchWithWindowsOpen() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token for account, caching", at: t) }
        let win = try w.runWindow(FakeWorld.c)
        let o = try await engine.switchTo(FakeWorld.b)
        #expect(o.verdict == .success)
        #expect(ClaudeConfig.currentAccount(w.paths.liveConfig) == FakeWorld.b)
        #expect(w.bundleQuitCount.withLock { $0 } == 0)
        #expect(w.pidRequests.withLock { $0.map(\.pid) } == [100])
        #expect(w.window(pid: win)?.running == true)
        // With another instance running, opening the app by URL would only activate it.
        #expect(w.launches.withLock { $0 } == [[]])
        #expect(w.app(Paths.claudeBundleID).running)
    }

    @Test("reconcile: vanished windows are reported, unknown running ones are adopted, signedIn follows config.json")
    func reconcile() async throws {
        let (w, engine) = try windowWorld()
        let p1 = try w.runWindow(FakeWorld.id(1))
        _ = try await engine.open(FakeWorld.id(1))
        // Window 1 disappears (quit for an update, closed by hand).
        w.planSelfClose(dataDir: w.paths.windowDataDir(FakeWorld.id(1)), after: 0)
        w.advance(1)
        #expect(w.window(pid: p1)?.running == false)
        // Window 2 appears without us.
        let p2 = try w.runWindow(FakeWorld.id(2))
        let report = engine.reconcile()
        #expect(report.vanished == [FakeWorld.id(1)])
        #expect(report.adopted == [FakeWorld.id(2)])
        let reg = WindowRegistryStore.read(w.paths)
        #expect(reg.record(FakeWorld.id(1))?.pid == nil && reg.record(FakeWorld.id(1))?.openedAt == nil)
        #expect(reg.record(FakeWorld.id(2))?.pid == p2 && reg.record(FakeWorld.id(2))?.signedIn == true)
        // Reconciling again changes nothing.
        #expect(engine.reconcile() == ReconcileReport(vanished: [], adopted: []))
        // A closed window whose login disappears is no longer signed in.
        try FileManager.default.removeItem(at: w.paths.windowConfig(FakeWorld.id(1)))
        #expect(engine.status().first { $0.accountId == FakeWorld.id(1) }?.signedIn == false)
    }
}

// MARK: Busy chats

@Suite("Parallel windows: busy chats never gate a switch")
struct BusyChatsDoNotGateTests {
    /// The same switch as the Desktop switch tests: A is live, B has a saved login.
    private func switchOnce(busyChats: Int) async throws -> (outcome: SwitchOutcome, events: [String], requests: [Int32], quits: Int, account: String?) {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token for account, caching", at: t) }
        if busyChats > 0 { try writeBusyTranscript(w, count: busyChats) }
        #expect(engine.busyChats() == busyChats) // the informational count is still there (the CLI prints it)
        let o = try await engine.switchTo(FakeWorld.b)
        return (o, w.events.withLock { $0 }, w.pidRequests.withLock { $0.map(\.pid) }, w.app(Paths.claudeBundleID).quitRequests,
                ClaudeConfig.currentAccount(w.paths.liveConfig))
    }

    @Test("a switch with busy chats asks nothing and goes exactly the way it goes without them")
    func switchIgnoresBusyChats() async throws {
        let calm = try await switchOnce(busyChats: 0)
        let busy = try await switchOnce(busyChats: 2)
        #expect(calm.outcome.verdict == .success && busy.outcome.verdict == .success)
        #expect(busy.account == FakeWorld.b)
        // No refusal, no extra step: the same quit request to Claude (its own dialog is what asks), same order of events.
        #expect(busy.events == calm.events)
        #expect(busy.requests == calm.requests && busy.quits == calm.quits)
        #expect(busy.quits >= 1)
    }
}

// MARK: First sign-in

@Suite("Parallel windows: first sign-in")
struct FirstSignInTests {
    private func makeFlow(_ w: FakeWorld, _ engine: WindowEngine, signInTimeout: Double = 120) -> FirstSignIn {
        FirstSignIn(windows: engine, signInTimeout: signInTimeout, reopenTimeout: 10, windowGoneGrace: 5, pollInterval: 1,
                    mainQuitTimeout: 5)
    }

    @Test("happy path: sync, close main, open the window, wait for its sign-in, reopen main")
    func happyPath() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        let dir = w.paths.windowDataDir(id)
        w.planSignIn(dataDir: dir, after: 20, account: id)
        let phases = Mutex<[FirstSignInPhase]>([])
        let mainConfigBefore = w.digest(w.paths.liveConfig)

        let out = try await makeFlow(w, engine).run(id) { p in phases.withLock { $0.append(p) } }

        #expect(out.accountId == id && out.mainReopened && out.warnings.isEmpty)
        #expect(w.events.withLock { $0 } == ["chat-sync", "quit-main", "settings-sync", "launch-window", "launch-main", "chat-sync"])
        // The window never got a saved login or a device id: its folder holds only what Claude wrote.
        #expect(ClaudeConfig.currentAccount(w.paths.windowConfig(id)) == id)
        #expect(w.isWindowRunning(dataDir: dir))
        #expect(w.app(Paths.claudeBundleID).running && w.app(Paths.claudeBundleID).opens == 1)
        // Only the main window was asked to quit (no other window runs, so the plain quit is fine here).
        #expect(w.pidRequests.withLock { $0.isEmpty } && w.bundleQuitCount.withLock { $0 } == 1)
        #expect(w.digest(w.paths.liveConfig) == mainConfigBefore)
        let rec = try #require(WindowRegistryStore.read(w.paths).record(id))
        #expect(rec.signedIn && rec.pid == w.windowPID(dataDir: dir))
        #expect(engine.store.state().pendingWindowSignIn == nil)
        let seen = phases.withLock { $0 }
        #expect(seen.first == .checking && seen.last == .done)
        #expect(seen.contains(.closingMain) && seen.contains(.waitingForSignIn) && seen.contains(.reopeningMain))
        // The window's folder was created 0700.
        #expect(FileOps.mode(dir) == 0o700)
    }

    @Test("main window not running: nothing to close and nothing to reopen")
    func mainNotRunning() async throws {
        let (w, engine) = try windowWorld()
        w.set(Paths.claudeBundleID) { $0.running = false }
        let id = FakeWorld.id(1)
        w.planSignIn(dataDir: w.paths.windowDataDir(id), after: 5, account: id)
        let out = try await makeFlow(w, engine).run(id)
        #expect(out.mainReopened == false)
        #expect(w.events.withLock { $0 } == ["chat-sync", "settings-sync", "launch-window", "chat-sync"])
        #expect(w.app(Paths.claudeBundleID).running == false)
    }

    enum Failure: String, CaseIterable, CustomStringConvertible {
        case timeout, windowClosesEarly, wrongAccount, launchFails, cancelled
        var description: String { rawValue }
    }

    @Test("every failure after the main window closed closes the new window and reopens the main window", arguments: Failure.allCases)
    func failurePaths(_ failure: Failure) async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        let dir = w.paths.windowDataDir(id)
        let flow = makeFlow(w, engine, signInTimeout: 60)
        let expected: any Error
        switch failure {
        case .timeout: expected = WindowError.signInTimedOut(id)
        case .windowClosesEarly:
            w.planSelfClose(dataDir: dir, after: 3)
            expected = WindowError.windowClosedBeforeSignIn(id)
        case .wrongAccount:
            w.planSignIn(dataDir: dir, after: 5, account: FakeWorld.id(2))
            expected = WindowError.signedInAsOther(expected: id, actual: FakeWorld.id(2))
        case .launchFails:
            w.windowLaunchFails = true
            expected = WindowError.launchFailed(id)
        case .cancelled: expected = WindowError.cancelled
        }

        let phases = Mutex<[FirstSignInPhase]>([])
        let box = Box<Task<FirstSignInOutcome, Error>>()
        let task = Task {
            try await flow.run(id) { p in
                phases.withLock { $0.append(p) }
                if failure == .cancelled, p == .waitingForSignIn {
                    var spins = 0
                    while box.value == nil, spins < 50_000 { usleep(100); spins += 1 }
                    box.value?.cancel()
                }
            }
        }
        box.value = task
        let result = await task.result
        guard case .failure(let error) = result else { Issue.record("expected \(failure) to fail"); return }
        #expect("\(error)" == "\(expected)")

        // The main window is back, the new window is gone, nothing is left pending.
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(engine.mainPID() == 100)
        #expect(w.events.withLock { $0.filter { $0 == "launch-main" }.count } == 1)
        #expect(w.isWindowRunning(dataDir: dir) == false)
        #expect(engine.store.state().pendingWindowSignIn == nil)
        #expect(phases.withLock { $0.last } == .rolledBack(mainReopened: true))
        // Only the main window and the new window were ever signalled.
        #expect(w.pidRequests.withLock { $0.allSatisfy { $0.pid == 100 || $0.pid >= 500 } })
        #expect(w.bundleQuitCount.withLock { $0 } == 1)
        // A folder this flow created is not left behind half-made.
        #expect(FileOps.exists(dir) == false)
        #expect(WindowRegistryStore.read(w.paths).record(id) == nil)
    }

    @Test("a main window that refuses to quit: nothing changes, nothing launches, nothing reopens")
    func mainRefusesToQuit() async throws {
        let (w, engine) = try windowWorld()
        w.set(Paths.claudeBundleID) { $0.exit = .never }
        let flow = makeFlow(w, engine)
        let id = FakeWorld.id(1)
        let before = w.digest(w.paths.liveConfig)
        await #expect(throws: EngineError.stillRunning("Claude")) { _ = try await flow.run(id) }
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(w.launches.withLock { $0.isEmpty })
        #expect(w.digest(w.paths.liveConfig) == before)
        #expect(engine.store.state().pendingWindowSignIn == nil)
        #expect(FileOps.exists(w.paths.windowDataDir(id)) == false)
    }

    @Test("settings or chat sync problems are warnings, not failures")
    func syncWarnings() async throws {
        let w = try FakeWorld()
        let engine = w.makeWindowEngine(sync: FakeSync(failure: "boom", world: w), settings: FakeSettingsSync(world: w, failure: "nope"))
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a)
        try engine.store.register(FakeWorld.id(1), label: "w1", now: w.now)
        try w.writeJobsOff(w.paths.windowDataDir(FakeWorld.id(1)))
        w.planSignIn(dataDir: w.paths.windowDataDir(FakeWorld.id(1)), after: 3, account: FakeWorld.id(1))
        let out = try await makeFlow(w, engine).run(FakeWorld.id(1))
        #expect(out.warnings.count == 3) // chat sync before, settings, chat sync after
        #expect(out.mainReopened)
    }

    @Test("busy chats neither ask nor refuse: the sign-in goes ahead as usual")
    func busyChats() async throws {
        let (w, engine) = try windowWorld()
        try writeBusyTranscript(w, count: 2)
        let id = FakeWorld.id(1)
        w.planSignIn(dataDir: w.paths.windowDataDir(id), after: 5, account: id)
        let out = try await makeFlow(w, engine).run(id)
        #expect(out.mainReopened)
        #expect(ClaudeConfig.currentAccount(w.paths.windowConfig(id)) == id)
    }

    @Test("checks first: the main account, a full house and an already signed-in window change nothing")
    func preflight() async throws {
        let (w, engine) = try windowWorld()
        let flow = makeFlow(w, engine)
        await #expect(throws: WindowError.accountIsMain(FakeWorld.a)) { _ = try await flow.run(FakeWorld.a) }

        _ = try w.makeSignedInWindowDir(FakeWorld.id(5))
        await #expect(throws: WindowError.alreadySignedIn(FakeWorld.id(5))) { _ = try await flow.run(FakeWorld.id(5)) }
        try FileManager.default.removeItem(at: w.paths.windowDataDir(FakeWorld.id(5)))

        for i in 1...3 { try w.runWindow(FakeWorld.id(i)) }
        await #expect(throws: WindowError.capReached(3)) { _ = try await flow.run(FakeWorld.id(4)) }
        await #expect(throws: WindowError.accountInWindow(FakeWorld.id(1))) { _ = try await flow.run(FakeWorld.id(1)) }

        #expect(w.events.withLock { $0.isEmpty })
        #expect(w.pidRequests.withLock { $0.isEmpty } && w.app(Paths.claudeBundleID).running)
        #expect(engine.store.state().pendingWindowSignIn == nil)
    }

    @Test("a first sign-in with another extra window open is refused before anything changes")
    func otherWindowOpenRefuses() async throws {
        let (w, engine) = try windowWorld()
        let other = try w.runWindow(FakeWorld.id(2))
        let id = FakeWorld.id(1)
        await #expect(throws: WindowError.closeOtherWindowsFirst) { _ = try await makeFlow(w, engine).run(id) }
        #expect(w.pidRequests.withLock { $0.isEmpty })
        #expect(w.launches.withLock { $0.isEmpty })
        #expect(w.window(pid: other)?.running == true)
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(engine.store.state().pendingWindowSignIn == nil)
    }

    @Test("an interrupted flow is undone at the next start: the main window comes back and the marker clears")
    func recovery() async throws {
        let (w, engine) = try windowWorld()
        let flow = makeFlow(w, engine)
        #expect(await flow.recoverIfInterrupted() == nil)
        w.set(Paths.claudeBundleID) { $0.running = false }
        try engine.store.updateState {
            $0.pendingWindowSignIn = PendingWindowSignIn(accountID: FakeWorld.id(1), reopenMain: true, startedAt: w.now)
        }
        let note = await flow.recoverIfInterrupted()
        #expect(note?.contains("main window was reopened") == true)
        #expect(w.app(Paths.claudeBundleID).running)
        #expect(engine.store.state().pendingWindowSignIn == nil)
        #expect(await flow.recoverIfInterrupted() == nil)
    }

    @Test("recovery with a main window that won't open keeps the marker so the next start tries again")
    func recoveryFails() async throws {
        let (w, engine) = try windowWorld()
        w.set(Paths.claudeBundleID) { $0.running = false }
        w.mainLaunchFails = true
        try engine.store.updateState {
            $0.pendingWindowSignIn = PendingWindowSignIn(accountID: FakeWorld.id(1), reopenMain: true, startedAt: w.now)
        }
        let note = await makeFlow(w, engine).recoverIfInterrupted()
        #expect(note?.contains("did not reopen") == true)
        #expect(engine.store.state().pendingWindowSignIn != nil)
    }
}

// MARK: Updates

private func setInstalledVersion(_ w: FakeWorld, _ version: String) throws {
    let plist: [String: Any] = ["CFBundleShortVersionString": version]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: w.paths.claudeInfoPlist)
}

/// What Claude leaves in a window's folder when it quits to install an update.
private func writeUpdateMarker(_ w: FakeWorld, _ id: String, from: String = "2.26454.0", to: String? = "2.26500.0",
                               ageSeconds: Double = 60) throws {
    var obj: [String: Any] = ["fromVersion": from, "ts": (w.now.timeIntervalSince1970 - ageSeconds) * 1000]
    if let to { obj["toVersion"] = to }
    try JSONSerialization.data(withJSONObject: obj).write(to: w.paths.windowDataDir(id).appending(path: "update-attempt"))
}

/// Window `id` is open through the engine, then quits by itself for an update.
private func windowQuitsForUpdate(_ w: FakeWorld, _ engine: WindowEngine, _ id: String, to: String? = "2.26500.0") async throws {
    let dir = try w.makeSignedInWindowDir(id)
    _ = try await engine.open(id)
    w.planSelfClose(dataDir: dir, after: 0)
    w.advance(1)
    try writeUpdateMarker(w, id, to: to)
    w.launches.withLock { $0.removeAll() }
    w.events.withLock { $0.removeAll() }
}

@Suite("Parallel windows: updates")
struct WindowUpdateTests {
    @Test("versions compare number by number, not as text")
    func versions() {
        #expect(AppVersion.compare("2.26454.2", "2.26454.10") == -1)
        #expect(AppVersion.compare("2.26500.0", "2.26454.9") == 1)
        #expect(AppVersion.compare("2.26454", "2.26454.0") == 0)
        #expect(AppVersion.compare("2.26454.0", "latest") == nil)
        #expect(AppVersion.compare("", "1") == nil)
    }

    @Test("an update marker reads Claude's file; garbage and empty markers read as nothing")
    func markerParsing() throws {
        let w = try FakeWorld()
        let url = w.root.appending(path: "update-attempt")
        try Data(#"{"fromVersion":"2.1.0","toVersion":"2.2.0","ts":1800000000000}"#.utf8).write(to: url)
        let m = try #require(UpdateMarker.read(url))
        #expect(m.fromVersion == "2.1.0" && m.toVersion == "2.2.0")
        #expect(m.writtenAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(m.isInstalled(version: "2.1.9") == false)
        #expect(m.isInstalled(version: "2.2.0") && m.isInstalled(version: "2.10.0"))
        #expect(m.isInstalled(version: nil) == false)
        // Without a target, any change from the quitting version counts.
        let open = UpdateMarker(fromVersion: "2.1.0", toVersion: nil, writtenAt: m.writtenAt)
        #expect(open.isInstalled(version: "2.1.0") == false && open.isInstalled(version: "2.1.1"))
        for bad in ["{ no", "[]", #"{"ts":1}"#, #"{"toVersion":"2.2.0"}"#, #"{"toVersion":"2.2.0","ts":0}"#] {
            try Data(bad.utf8).write(to: url)
            #expect(UpdateMarker.read(url) == nil)
        }
        #expect(UpdateMarker.read(w.root.appending(path: "missing")) == nil)
    }

    @Test("a window that quits for an update is shown as waiting, kept in the registry, and not reopened early")
    func quitForUpdateWaits() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id)

        let report = engine.reconcile()
        #expect(report.vanished == [id] && report.waitingForUpdate == [id])
        let st = try #require(engine.status().first)
        #expect(st.accountId == id && st.isOpen == false && st.signedIn && st.waitingForUpdate == "2.26500.0")
        #expect(WindowRegistryStore.read(w.paths).record(id) != nil)

        // The main window is still on the old version: nothing is launched, nothing is signalled.
        let results = await engine.reopenAfterUpdate()
        #expect(results == [UpdateReopenResult(accountId: id, outcome: .waiting)])
        #expect(w.launches.withLock { $0.isEmpty } && w.pidRequests.withLock { $0.isEmpty })
        #expect(engine.windowsWaitingForUpdate().map(\.accountId) == [id])
    }

    @Test("once the main window runs the new version the window reopens with the normal launch line, once")
    func reopensAfterMainUpdated() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id)
        try setInstalledVersion(w, "2.26500.0")

        let results = await engine.reopenAfterUpdate()
        guard case .reopened(let pid)? = results.first?.outcome, results.count == 1 else {
            Issue.record("expected one reopened window, got \(results)")
            return
        }
        let dir = w.paths.windowDataDir(id)
        #expect(w.launches.withLock { $0 } == [["--user-data-dir=\(ParallelWindows.dirString(dir))"]])
        // Same sequence as any open: chat sync, settings sync, then launch.
        #expect(w.events.withLock { $0 } == ["chat-sync", "settings-sync", "launch-window"])
        #expect(w.windowPID(dataDir: dir) == pid)
        #expect(WindowRegistryStore.read(w.paths).record(id)?.pid == pid)
        #expect(w.pidRequests.withLock { $0.isEmpty } && w.bundleQuitCount.withLock { $0 } == 0)
        // Running again, so nothing is waiting and a later call does nothing.
        #expect(engine.windowsWaitingForUpdate().isEmpty)
        #expect(await engine.reopenAfterUpdate().isEmpty)
        #expect(w.launches.withLock { $0.count } == 1)
    }

    @Test("a newer version than the marker's target also counts; an older one does not")
    func versionBoundary() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id, to: "2.26500.0")
        try setInstalledVersion(w, "2.26499.9")
        #expect(await engine.reopenAfterUpdate().first?.outcome == .waiting)
        try setInstalledVersion(w, "2.26501.0")
        guard case .reopened? = await engine.reopenAfterUpdate().first?.outcome else {
            Issue.record("expected reopen on a newer version")
            return
        }
    }

    @Test("the main window must be running again: an updated app that is not started yet keeps the wait")
    func needsMainRunning() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id)
        try setInstalledVersion(w, "2.26500.0")
        w.set(Paths.claudeBundleID) { $0.running = false }
        #expect(await engine.reopenAfterUpdate().first?.outcome == .waiting)
        #expect(w.launches.withLock { $0.isEmpty })
        w.set(Paths.claudeBundleID) { $0.running = true }
        guard case .reopened? = await engine.reopenAfterUpdate().first?.outcome else {
            Issue.record("expected reopen once main runs")
            return
        }
    }

    @Test("a failed reopen is reported and not retried in a loop")
    func reopenFailsOnce() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id)
        try setInstalledVersion(w, "2.26500.0")
        w.windowLaunchFails = true
        let first = await engine.reopenAfterUpdate()
        guard case .failed? = first.first?.outcome else {
            Issue.record("expected a failure, got \(first)")
            return
        }
        w.windowLaunchFails = false
        #expect(await engine.reopenAfterUpdate().isEmpty)
        #expect(engine.liveWindows().isEmpty)
    }

    @Test("a second update quit is a new wait: it reopens again")
    func secondUpdate() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id)
        try setInstalledVersion(w, "2.26500.0")
        guard case .reopened(let pid)? = await engine.reopenAfterUpdate().first?.outcome else {
            Issue.record("first reopen")
            return
        }
        // The window quits again for the next update, a minute later.
        w.planSelfClose(dataDir: w.paths.windowDataDir(id), after: 0)
        w.advance(60)
        #expect(w.window(pid: pid)?.running == false)
        try writeUpdateMarker(w, id, from: "2.26500.0", to: "2.26600.0", ageSeconds: 5)
        _ = engine.reconcile()
        #expect(await engine.reopenAfterUpdate().first?.outcome == .waiting)
        try setInstalledVersion(w, "2.26600.0")
        guard case .reopened? = await engine.reopenAfterUpdate().first?.outcome else {
            Issue.record("second reopen")
            return
        }
        #expect(w.launches.withLock { $0.count } == 2)
    }

    @Test("a window closed on purpose never comes back: closing cancels the wait")
    func closeCancelsWait() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id)
        #expect(engine.windowsWaitingForUpdate().count == 1)
        try await engine.close(id)
        #expect(engine.windowsWaitingForUpdate().isEmpty)
        #expect(engine.status().first?.waitingForUpdate == nil)
        try setInstalledVersion(w, "2.26500.0")
        #expect(await engine.reopenAfterUpdate().isEmpty)
        #expect(w.launches.withLock { $0.isEmpty })
    }

    @Test("a window that Rotor closed leaves no marker, so it is not a waiting window")
    func normalCloseIsNotAnUpdate() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        _ = try w.makeSignedInWindowDir(id)
        _ = try await engine.open(id)
        try await engine.close(id)
        try setInstalledVersion(w, "2.26500.0")
        #expect(engine.reconcile().waitingForUpdate.isEmpty)
        #expect(await engine.reopenAfterUpdate().isEmpty)
        #expect(w.launches.withLock { $0.count } == 1)
    }

    @Test("when the account became the main window's meanwhile, the wait is dropped and nothing launches")
    func accountBecameMain() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id)
        try setInstalledVersion(w, "2.26500.0")
        try Fixture.writeConfig(w.paths.liveConfig, account: id)
        #expect(await engine.reopenAfterUpdate().first?.outcome == .dropped)
        #expect(w.launches.withLock { $0.isEmpty })
        #expect(engine.windowsWaitingForUpdate().isEmpty)
    }

    @Test("the cap and the one-place rule still apply when windows come back after an update")
    func capOnReopen() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, engine, id)
        try setInstalledVersion(w, "2.26500.0")
        // The user filled the three places while it was gone.
        for i in 2...4 { try w.runWindow(FakeWorld.id(i)) }
        guard case .failed(let why)? = await engine.reopenAfterUpdate().first?.outcome else {
            Issue.record("expected the cap to refuse")
            return
        }
        #expect(why.contains("3 extra windows"))
        #expect(w.launches.withLock { $0.isEmpty })
        // Nothing was started, so the wait stays and the window comes back once a place is free.
        #expect(engine.windowsWaitingForUpdate().count == 1)
        try await engine.close(FakeWorld.id(4))
        guard case .reopened? = await engine.reopenAfterUpdate().first(where: { $0.accountId == id })?.outcome else {
            Issue.record("expected the window to come back once a place was free")
            return
        }
        #expect(w.launches.withLock { $0.count } == 1)
    }

    @Test("old and broken markers do not make a window wait")
    func staleAndBrokenMarkers() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        _ = try w.makeSignedInWindowDir(id)
        _ = try await engine.open(id)
        try await engine.close(id)
        let marker = w.paths.windowDataDir(id).appending(path: "update-attempt")
        try writeUpdateMarker(w, id, ageSeconds: 8 * 86_400)
        #expect(engine.windowsWaitingForUpdate().isEmpty)
        try Data("{ not json".utf8).write(to: marker)
        #expect(engine.windowsWaitingForUpdate().isEmpty)
        try writeUpdateMarker(w, id, ageSeconds: 6 * 86_400)
        #expect(engine.windowsWaitingForUpdate().count == 1)
    }

    @Test("a marker with an invalid account folder name is never read")
    func invalidAccountMarker() throws {
        let (_, engine) = try windowWorld()
        #expect(engine.pendingUpdate("../evil") == nil)
    }

    @Test("opening a window while the main window has an update staged warns, and still opens")
    func stagedUpdateWarning() async throws {
        let (w, engine) = try windowWorld()
        let id = FakeWorld.id(1)
        _ = try w.makeSignedInWindowDir(id)
        try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a,
                                extra: ["updaterStagedPayloadKind": ["version": "2.26500.0", "kind": "zip", "arch": "arm64"]])
        let r = try await engine.open(id)
        #expect(r.warnings.count == 1 && r.warnings[0].contains("2.26500.0") && r.warnings[0].contains("Update it first"))
        #expect(w.isWindowRunning(dataDir: w.paths.windowDataDir(id)))
    }

    @Test("no warning when the staged version is the running one, older, or absent")
    func noWarning() async throws {
        let (w, engine) = try windowWorld()
        #expect(engine.stagedUpdateWarning() == nil)
        for staged in ["2.26454.0", "2.26000.0"] {
            try Fixture.writeConfig(w.paths.liveConfig, account: FakeWorld.a,
                                    extra: ["updaterStagedPayloadKind": ["version": staged, "kind": "zip"]])
            #expect(engine.stagedUpdateWarning() == nil)
        }
    }
}

// MARK: One action at a time

/// A switch engine and a window engine that share one gate, as the app wires them.
private func sharedGateWorld(switchSync: ((FakeWorld) -> SyncRunner)? = nil, windowSync: ((FakeWorld) -> SyncRunner)? = nil)
    throws -> (FakeWorld, SwitchEngine, WindowEngine, ActionGate) {
    let w = try FakeWorld()
    let gate = ActionGate()
    let switcher = w.makeEngine(sync: switchSync?(w), gate: gate)
    let windows = w.makeWindowEngine(sync: windowSync?(w), gate: gate)
    try w.setUpTwoAccounts(store: switcher.store)
    try w.registerAccounts(3, store: switcher.store)
    w.onOpen[Paths.claudeBundleID] = { [unowned w] t in w.logLine("[oauth] obtained new token for account, caching", at: t) }
    return (w, switcher, windows, gate)
}

private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite("One action at a time")
struct OneActionAtATimeTests {
    @Test("the gate runs actions one after another in the order they asked, and a free gate runs a background action")
    func gateOrder() async throws {
        let gate = ActionGate()
        let order = Journal()
        let hold = Latch()
        let a = Task { try await gate.run { order.add("a"); await hold.wait() } }
        await until("a to start") { order.all == ["a"] }
        #expect(gate.isBusy)
        let b = Task { try await gate.run { order.add("b") } }
        await until("b to queue") { gate.waitingCount == 1 }
        let c = Task { try await gate.run { order.add("c") } }
        await until("c to queue") { gate.waitingCount == 2 }
        // Background work never queues: it is skipped while anything runs.
        let skipped: Int? = await gate.runIfIdle { 1 }
        #expect(skipped == nil)
        hold.open()
        try await a.value; try await b.value; try await c.value
        #expect(order.all == ["a", "b", "c"])
        #expect(gate.isBusy == false && gate.waitingCount == 0)
        let ran: Int? = await gate.runIfIdle { 7 }
        #expect(ran == 7)
    }

    @Test("a waiter that is cancelled leaves the queue without running, and the gate is not lost")
    func cancelledWaiter() async throws {
        let gate = ActionGate()
        let hold = Latch()
        let ran = Journal()
        let a = Task { try await gate.run { await hold.wait() } }
        await until("a to hold the gate") { gate.isBusy }
        let b = Task { try await gate.run { ran.add("b") } }
        await until("b to queue") { gate.waitingCount == 1 }
        b.cancel()
        await #expect(throws: CancellationError.self) { try await b.value }
        #expect(gate.waitingCount == 0)
        // Cancelled before it ever asked: never queued, never runs.
        let early = Task { () throws -> Void in
            while Task.isCancelled == false { await Task.yield() }
            try await gate.run { ran.add("early") }
        }
        early.cancel()
        await #expect(throws: CancellationError.self) { try await early.value }
        hold.open()
        try await a.value
        #expect(ran.all.isEmpty)
        let after: Int? = await gate.runIfIdle { 1 }
        #expect(after == 1)
    }

    @Test("a failing action frees the gate for the next one")
    func failureReleases() async throws {
        let gate = ActionGate()
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await gate.run { throw Boom() } }
        #expect(gate.isBusy == false)
        #expect(try await gate.run { 5 } == 5)
    }

    @Test("reopen after an update is skipped while a switch runs, and goes ahead once it is done")
    func reopenSkippedDuringSwitch() async throws {
        let (w, switcher, windows, gate) = try sharedGateWorld(switchSync: { GatedSync(world: $0) })
        let id = FakeWorld.id(1)
        try await windowQuitsForUpdate(w, windows, id)
        try setInstalledVersion(w, "2.26500.0")
        let held = try #require(switcher.sync as? GatedSync)
        held.hold()

        let sw = Task { try await switcher.switchTo(FakeWorld.b) }
        await until("the switch to start its chat sync") { held.entered == 1 }
        #expect(gate.isBusy)
        // The window is ready to come back, but a switch has the main window.
        #expect(windows.windowsReadyToReopen() == [id])
        #expect(await windows.reopenAfterUpdate().isEmpty)
        #expect(w.launches.withLock { $0.isEmpty })
        #expect(windows.windowsWaitingForUpdate().map(\.accountId) == [id]) // still waiting, not dropped, not marked tried

        held.release()
        let o = try await sw.value
        #expect(o.verdict == .success)
        let results = await windows.reopenAfterUpdate()
        guard case .reopened? = results.first?.outcome, results.count == 1 else {
            Issue.record("expected the window to reopen after the switch, got \(results)")
            return
        }
    }

    @Test("Open waits while a reopen runs and then opens, in that order")
    func openWaitsForReopen() async throws {
        let (w, _, windows, gate) = try sharedGateWorld(windowSync: { GatedSync(world: $0) })
        let held = try #require(windows.sync as? GatedSync)
        let id1 = FakeWorld.id(1), id2 = FakeWorld.id(2)
        try await windowQuitsForUpdate(w, windows, id1)
        try setInstalledVersion(w, "2.26500.0")
        _ = try w.makeSignedInWindowDir(id2)
        held.hold()
        let entered0 = held.entered
        w.events.withLock { $0.removeAll() }

        let reopen = Task { await windows.reopenAfterUpdate() }
        await until("the reopen to reach its chat sync") { held.entered == entered0 + 1 }
        let open = Task { try await windows.open(id2) }
        await until("Open to queue behind the reopen") { gate.waitingCount == 1 }
        // Open has not started: no second chat sync, nothing launched yet.
        #expect(held.entered == entered0 + 1 && w.launches.withLock { $0.isEmpty })

        held.release()
        let reopened = await reopen.value
        guard case .reopened? = reopened.first?.outcome else { Issue.record("expected a reopened window, got \(reopened)"); return }
        let r = try await open.value
        #expect(r.alreadyOpen == false)
        let launches = w.launches.withLock { $0 }
        #expect(launches == [["--user-data-dir=\(ParallelWindows.dirString(w.paths.windowDataDir(id1)))"],
                             ["--user-data-dir=\(ParallelWindows.dirString(w.paths.windowDataDir(id2)))"]])
        #expect(w.events.withLock { $0 } == ["chat-sync", "settings-sync", "launch-window", "chat-sync", "settings-sync", "launch-window"])
    }

    @Test("a switch waits for a window action that is running")
    func switchWaitsForOpen() async throws {
        let (w, switcher, windows, gate) = try sharedGateWorld(windowSync: { GatedSync(world: $0) })
        let held = try #require(windows.sync as? GatedSync)
        let id = FakeWorld.id(1)
        _ = try w.makeSignedInWindowDir(id)
        held.hold()
        let open = Task { try await windows.open(id) }
        await until("Open to reach its chat sync") { held.entered == 1 }

        let sw = Task { try await switcher.switchTo(FakeWorld.b) }
        await until("the switch to queue") { gate.waitingCount == 1 }
        #expect(w.app(Paths.claudeBundleID).quitRequests == 0) // Claude was not asked to quit under the open window's feet
        held.release()
        _ = try await open.value
        let o = try await sw.value
        #expect(o.verdict == .success)
        #expect(w.app(Paths.claudeBundleID).quitRequests >= 1)
    }

    @Test("a first sign-in holds every other action off until it ends")
    func firstSignInHoldsOthers() async throws {
        let (w, _, windows, gate) = try sharedGateWorld(windowSync: { GatedSync(world: $0) })
        let held = try #require(windows.sync as? GatedSync)
        let reopenId = FakeWorld.id(1), signInId = FakeWorld.id(3)
        try await windowQuitsForUpdate(w, windows, reopenId)
        try setInstalledVersion(w, "2.26500.0")
        w.planSignIn(dataDir: w.paths.windowDataDir(signInId), after: 5, account: signInId)
        held.hold()
        let before = held.entered
        let flow = FirstSignIn(windows: windows, signInTimeout: 120, reopenTimeout: 10, windowGoneGrace: 5, pollInterval: 1, mainQuitTimeout: 5)

        let signIn = Task { try await flow.run(signInId) }
        await until("the sign-in to reach its chat sync") { held.entered == before + 1 }
        #expect(await windows.reopenAfterUpdate().isEmpty)
        let close = Task { try await windows.close(reopenId) }
        await until("Close to queue") { gate.waitingCount == 1 }
        held.release()
        let out = try await signIn.value
        #expect(out.mainReopened)
        _ = try await close.value
        #expect(gate.isBusy == false)
    }
}
