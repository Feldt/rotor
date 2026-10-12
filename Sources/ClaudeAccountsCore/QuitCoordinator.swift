import Foundation

/// Which instance of the app a `ManagedApp` means. Extra Claude windows are other processes of the
/// same bundle, so "Claude" must say whose.
public enum InstanceScope: Sendable, Equatable {
    /// Every matching process (Chrome, and anything that never runs twice).
    case whole
    /// The main window: matching processes minus every extra window's.
    case mainOnly
    /// One extra window, identified by its `--user-data-dir`.
    case window(dataDir: String)
}

/// One app the engine quits and reopens, and what "fully exited" means for it.
public struct ManagedApp: Sendable {
    public var name: String
    public var bundleID: String
    public var appURL: URL
    /// A process whose executable starts with any of these keeps the app "running".
    public var processPrefixes: [String]
    /// Executable names that live in the bundle but never touch the data (Chrome's native host,
    /// Squirrel's ShipIt, crashpad). Ignored.
    public var ignoredExecutables: Set<String>
    /// Must be absent or empty before files are touched.
    public var journals: [URL]
    public var scope: InstanceScope = .whole
    /// `Paths.windowsRoot`, so a process of a window can be told from the main window's by its folder.
    public var windowsRoot: String? = nil

    /// The main Claude window (and its CLI sessions). Extra windows' processes are not part of it.
    public static func claude(_ p: Paths) -> ManagedApp {
        ManagedApp(
            name: "Claude", bundleID: Paths.claudeBundleID, appURL: p.claudeApp,
            processPrefixes: [dirPrefix(p.claudeApp), dirPrefix(p.claudeCodeDir)],
            ignoredExecutables: ["chrome-native-host", "ShipIt", "chrome_crashpad_handler"],
            journals: [p.liveCookiesJournal], scope: .mainOnly, windowsRoot: ParallelWindows.dirString(p.windowsRoot))
    }

    /// One extra Claude window. Nothing in the data dir is swapped, so there are no journals to wait for.
    public static func claudeWindow(_ p: Paths, dataDir: URL) -> ManagedApp {
        let dir = ParallelWindows.dirString(dataDir)
        return ManagedApp(
            name: "Claude window", bundleID: Paths.claudeBundleID, appURL: p.claudeApp,
            processPrefixes: [dirPrefix(p.claudeApp), dirPrefix(dataDir.appending(path: "claude-code", directoryHint: .isDirectory))],
            ignoredExecutables: ["chrome-native-host", "ShipIt", "chrome_crashpad_handler"],
            journals: [], scope: .window(dataDir: dir), windowsRoot: ParallelWindows.dirString(p.windowsRoot))
    }

    public static func chrome(_ p: Paths) -> ManagedApp {
        ManagedApp(
            name: "Chrome", bundleID: Paths.chromeBundleID, appURL: p.chromeApp,
            processPrefixes: [dirPrefix(p.chromeApp)],
            ignoredExecutables: ["chrome_crashpad_handler"],
            journals: [p.chromeCookiesJournal])
    }

    static func dirPrefix(_ url: URL) -> String {
        let s = url.standardizedFileURL.path(percentEncoded: false)
        return s.hasSuffix("/") ? s : s + "/"
    }
}

public enum QuitEvent: Sendable, Equatable {
    case requested
    /// Still running a few seconds after the request with a window up: the app is probably
    /// showing its own "still working" dialog.
    case appIsAsking
    /// Still running a few seconds after the request, no window: it's cleaning up.
    case waitingToFinish
    /// Still waiting after 30 s: this many of the app's own processes are open.
    case waitingOn(Int)
    /// The main app and its helpers are gone.
    case exited
    /// Proceeding while this many CLI/helper processes are still exiting (they don't write the files).
    case lingering(Int)
}

/// Quit, wait, verify. Never force-kills: if the app doesn't exit in time, it throws and the
/// caller changes nothing.
///
/// "Safe to touch the files" means: the main executable and the bundle's framework helpers (which
/// own the cookie store and config writes) are gone, and the journals are empty. Other matched
/// processes (`Contents/Helpers/…` such as `disclaimer` and `claude-ios-sim`, and CLI sessions under
/// `Application Support/Claude/claude-code/`) may outlive the app; they don't write Cookies or
/// config.json, so they get a 0.5 s grace and are then ignored.
public struct QuitCoordinator: Sendable {
    public var probe: ProcessProbe
    public var controller: AppController
    public var ticker: Ticker
    public var quitTimeout: Double = 120
    public var settleTimeout: Double = 20
    public var askingAfter: Double = 3
    public var reportBlockersAfter: Double = 30
    /// Everything that can write the swapped files is already gone; this only lets the cookie
    /// journal settle. CLI sessions and helpers that keep running don't block.
    public var lingerGrace: Double = 0.5
    public var pollInterval: Double = 0.25

    public init(probe: ProcessProbe, controller: AppController, ticker: Ticker) {
        self.probe = probe
        // Every "Claude" call is about the main window while extra windows run (see MainScopedController).
        self.controller = controller is MainScopedController ? controller : MainScopedController(base: controller, probe: probe)
        self.ticker = ticker
    }

    /// Every matched process except the ignored ones, limited to the app's instance (`scope`).
    public func liveProcesses(_ app: ManagedApp) -> [ProcInfo] {
        let all = probe.processes()
        let map = app.scope == .whole ? nil : ClaudeProcessMap(all, windowsRoot: app.windowsRoot)
        return all.map { p in
            var p = p
            while p.path.contains("//") { p.path = p.path.replacingOccurrences(of: "//", with: "/") }
            return p
        }.filter { proc in
            guard app.processPrefixes.contains(where: { proc.path.hasPrefix($0) }) else { return false }
            let exe = (proc.path as NSString).lastPathComponent
            guard app.ignoredExecutables.contains(exe) == false else { return false }
            switch app.scope {
            case .whole: return true
            case .mainOnly: return map?.windowDataDir(of: proc) == nil
            case .window(let dir): return map?.windowDataDir(of: proc) == dir
            }
        }
    }

    /// The signal target for an extra window: its browser process, by exact arguments.
    func windowPID(_ app: ManagedApp) -> Int32? {
        guard case .window(let dir) = app.scope else { return nil }
        return ClaudeProcessMap(probe.processes()).exactWindowPID(dataDir: dir)
    }

    /// The processes that can write the files we swap: the bundle's `Contents/MacOS/` and
    /// `Contents/Frameworks/` executables (main app and its helpers).
    public func requiredProcesses(_ app: ManagedApp) -> [ProcInfo] {
        let bundle = ManagedApp.dirPrefix(app.appURL)
        let roots = [bundle + "Contents/MacOS/", bundle + "Contents/Frameworks/"]
        return liveProcesses(app).filter { p in roots.contains { p.path.hasPrefix($0) } }
    }

    /// Matched processes that don't write the swapped files (bundle Helpers, CLI sessions).
    public func lingeringProcesses(_ app: ManagedApp) -> [ProcInfo] {
        let required = Set(requiredProcesses(app).map(\.pid))
        return liveProcesses(app).filter { required.contains($0.pid) == false }
    }

    /// The app counts as running while its main app or any required process is alive.
    public func isRunning(_ app: ManagedApp) async -> Bool {
        // An extra window is a process, not "the app": the bundle-level answer would be about all of them.
        if case .window = app.scope { return requiredProcesses(app).isEmpty == false }
        if await controller.isRunning(bundleID: app.bundleID) { return true }
        return requiredProcesses(app).isEmpty == false
    }

    /// A polite quit of exactly this instance. For an extra window that is SIGTERM to its exact pid.
    func requestQuit(_ app: ManagedApp) async {
        if case .window = app.scope {
            if let pid = windowPID(app) { await controller.signalTerminate(pid: pid) }
            return
        }
        await controller.requestQuit(bundleID: app.bundleID)
    }

    func hasWindowUp(_ app: ManagedApp) async -> Bool {
        if case .window = app.scope {
            guard let pid = windowPID(app) else { return false }
            return await controller.hasVisibleWindow(pid: pid)
        }
        guard await controller.isRunning(bundleID: app.bundleID) else { return false }
        return await controller.hasVisibleWindow(bundleID: app.bundleID)
    }

    public func journalsSettled(_ app: ManagedApp) -> Bool {
        app.journals.allSatisfy { j in FileOps.exists(j) == false || (FileOps.size(j) ?? 0) == 0 }
    }

    func reopenedError(_ app: ManagedApp) -> EngineError {
        app.bundleID == Paths.chromeBundleID ? .chromeNotClosed : .claudeReopened
    }

    /// Requests a quit and waits until it's safe to touch the files. Throws `.stillRunning` after
    /// `quitTimeout`, `.notClean` if the journals never settle, `.cancelled` if the task is cancelled,
    /// `.claudeReopened` if the app comes back after exiting. In every throw, no file was touched.
    public func quitAndWait(_ app: ManagedApp, events: @Sendable (QuitEvent) -> Void = { _ in }) async throws {
        if await isRunning(app) {
            await requestQuit(app)
            events(.requested)
            let start = ticker.now()
            var reported: QuitEvent?
            while await isRunning(app) {
                if Task.isCancelled { throw EngineError.cancelled }
                let elapsed = ticker.now().timeIntervalSince(start)
                if elapsed > quitTimeout { throw EngineError.stillRunning(app.name) }
                if elapsed > askingAfter {
                    let windowUp = await hasWindowUp(app)
                    var ev: QuitEvent = windowUp ? .appIsAsking : .waitingToFinish
                    if windowUp == false, elapsed > reportBlockersAfter {
                        ev = .waitingOn(max(1, requiredProcesses(app).count))
                    }
                    if ev != reported {
                        reported = ev
                        events(ev)
                    }
                }
                do { try await ticker.sleep(seconds: pollInterval) } catch { throw EngineError.cancelled }
            }
            events(.exited)
            // Grace for CLI/helper processes that are still exiting; then proceed regardless.
            let graceStart = ticker.now()
            while lingeringProcesses(app).isEmpty == false, ticker.now().timeIntervalSince(graceStart) < lingerGrace {
                if await isRunning(app) { throw reopenedError(app) }
                if Task.isCancelled { throw EngineError.cancelled }
                do { try await ticker.sleep(seconds: pollInterval) } catch { throw EngineError.cancelled }
            }
            let left = lingeringProcesses(app).count
            if left > 0 { events(.lingering(left)) }
        }
        let settleStart = ticker.now()
        while journalsSettled(app) == false {
            if await isRunning(app) { throw reopenedError(app) }
            if ticker.now().timeIntervalSince(settleStart) > settleTimeout { throw EngineError.notClean(app.name) }
            try? await ticker.sleep(seconds: pollInterval)
        }
        if await isRunning(app) { throw reopenedError(app) }
    }
}
