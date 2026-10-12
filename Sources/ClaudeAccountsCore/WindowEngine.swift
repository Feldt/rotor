import Foundation
import Synchronization

/// One extra window as the panel shows it.
public struct WindowStatus: Sendable, Equatable {
    public var accountId: String
    public var dataDir: String
    public var signedIn: Bool
    public var isOpen: Bool
    public var pid: Int32?
    public var openedAt: Date?
    /// The window quit to install an update (Claude left an `update-attempt` marker) and is waiting
    /// for the main window to reach this version; `reopenAfterUpdate()` brings it back.
    public var waitingForUpdate: String? = nil
}

public struct WindowOpenResult: Sendable, Equatable {
    public var accountId: String
    public var pid: Int32
    /// The window was already running; nothing was launched.
    public var alreadyOpen: Bool
    /// Settings or chat sync problems. The window opened anyway.
    public var warnings: [String]
}

public struct ReconcileReport: Sendable, Equatable {
    /// Windows the registry thought were running but whose process is gone (closed by hand, quit for
    /// an update, crashed). The panel can offer "Reopen windows"; nothing reopens by itself.
    public var vanished: [String]
    /// Windows found running that the registry did not know.
    public var adopted: [String]
    /// Closed windows that left an update marker: they quit to install an update and are waiting for
    /// the main window to update (a subset of `vanished`, plus any still waiting from earlier).
    public var waitingForUpdate: [String] = []
}

/// What Claude writes to `<userData>/update-attempt` right before it quits to install an update
/// (`{"fromVersion","toVersion","ts"}`, ts in milliseconds). Claude reads and deletes it at its next
/// start, so a marker that is still there means the window has not started since that quit.
public struct UpdateMarker: Sendable, Equatable {
    public var fromVersion: String?
    public var toVersion: String?
    public var writtenAt: Date

    /// A marker older than this is ignored: whatever it was about, nobody is waiting on it now.
    public static let maxAge: Double = 7 * 86_400

    public static func read(_ url: URL) -> UpdateMarker? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = (obj["ts"] as? NSNumber)?.doubleValue, ts > 0 else { return nil }
        let from = obj["fromVersion"] as? String
        let to = obj["toVersion"] as? String
        guard from != nil || to != nil else { return nil }
        return UpdateMarker(fromVersion: from, toVersion: to, writtenAt: Date(timeIntervalSince1970: ts / 1000))
    }

    /// Has the installed app reached the version this update was installing? Without a target
    /// version, any change from the version that quit counts.
    public func isInstalled(version installed: String?) -> Bool {
        guard let installed else { return false }
        if let to = toVersion, let c = AppVersion.compare(installed, to) { return c >= 0 }
        if let from = fromVersion { return installed != from }
        return false
    }
}

/// Dotted app versions such as `2.26454.2`, compared number by number.
public enum AppVersion {
    static func parts(_ v: String) -> [Int]? {
        let nums = v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard nums.isEmpty == false, nums.allSatisfy({ $0 != nil }) else { return nil }
        return nums.compactMap { $0 }
    }

    /// -1, 0 or 1; nil when either side is not a dotted number.
    public static func compare(_ a: String, _ b: String) -> Int? {
        guard let x = parts(a), let y = parts(b) else { return nil }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

public struct UpdateReopenResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Reopened with the normal launch line.
        case reopened(pid: Int32)
        /// Not yet: the main window has not updated or is not running. Tried again at the next call.
        case waiting
        /// The window could not be reopened (the error text). It is not retried by itself.
        case failed(String)
        /// The wait was cancelled: the account became the main window's, or a window is open for it.
        case dropped
    }
    public var accountId: String
    public var outcome: Outcome
}

/// Opens, closes and tracks the extra Claude windows. Each window is another `Claude.app` process
/// started with its own `--user-data-dir`; the engine never touches the main window's files and
/// never signals a pid it has not matched by exact arguments. All I/O goes through the injected
/// probe, controller, ticker and sync runners, so tests run against fakes.
public final class WindowEngine: Sendable {
    public let paths: Paths
    public let store: AccountStore
    public let quitter: QuitCoordinator
    public let sync: SyncRunner
    public let settings: WindowSettingsSync
    public let launchTimeout: Double
    public let closeTimeout: Double
    public let syncTimeout: Double
    /// One action at a time across this engine and the switch engine (shared with it by the app).
    public let gate: ActionGate
    private let registryLock = Mutex<Void>(())
    /// Update markers already acted on in this run ("account|ts"): a window is reopened once per
    /// update quit, never in a loop.
    private let reopenAttempted = Mutex<Set<String>>([])

    public var ticker: Ticker { quitter.ticker }
    public var controller: AppController { quitter.controller }
    public var mainApp: ManagedApp { .claude(paths) }

    public init(paths: Paths, store: AccountStore? = nil, probe: ProcessProbe, controller: AppController,
                ticker: Ticker, sync: SyncRunner, settings: WindowSettingsSync,
                launchTimeout: Double = 30, closeTimeout: Double = 60, syncTimeout: Double = 60,
                gate: ActionGate = ActionGate()) {
        self.gate = gate
        self.paths = paths
        self.store = store ?? AccountStore(paths: paths)
        var q = QuitCoordinator(probe: probe, controller: controller, ticker: ticker)
        q.quitTimeout = closeTimeout
        self.quitter = q
        self.sync = sync
        self.settings = settings
        self.launchTimeout = launchTimeout
        self.closeTimeout = closeTimeout
        self.syncTimeout = syncTimeout
    }

    /// The real system (or the dry-run controller with `CLAUDE_ACCOUNTS_DRY_CONTROLLER=1`).
    public static func system(paths: Paths, settingsScript: URL? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              gate: ActionGate = ActionGate()) -> WindowEngine {
        let script = settingsScript ?? PythonWindowSettingsSync.defaultScript(environment: environment)
        if environment["CLAUDE_ACCOUNTS_DRY_CONTROLLER"] == "1" {
            return WindowEngine(paths: paths, probe: EmptyProcessProbe(), controller: DryRunAppController(),
                                ticker: SystemTicker(), sync: PythonSyncRunner.system(paths: paths, environment: environment),
                                settings: PythonWindowSettingsSync(script: script), gate: gate)
        }
        return WindowEngine(paths: paths, probe: SystemProcessProbe(), controller: SystemAppController(),
                            ticker: SystemTicker(), sync: PythonSyncRunner.system(paths: paths, environment: environment),
                            settings: PythonWindowSettingsSync(script: script), gate: gate)
    }

    // MARK: Read-only queries

    public func mainAccount() -> String? { ClaudeConfig.currentAccount(paths.liveConfig) }

    func processMap() -> ClaudeProcessMap {
        ClaudeProcessMap(quitter.probe.processes(), windowsRoot: ParallelWindows.dirString(paths.windowsRoot))
    }

    /// Our extra windows that are running right now (exact arguments, inside `windows/`).
    public func liveWindows() -> [LiveWindow] { processMap().ourWindows(in: paths) }

    public func mainPID() -> Int32? { processMap().mainPID }

    public func registry() -> WindowRegistry { WindowRegistryStore.read(paths) }

    func step(_ message: String) { store.log("windows: \(message)", now: ticker.now()) }

    func dataDir(_ accountId: String) throws -> URL {
        guard ParallelWindows.isValidAccountID(accountId) else { throw WindowError.invalidAccount(accountId) }
        return paths.windowDataDir(accountId)
    }

    /// The window's browser process is running (matched by exact arguments).
    func windowIsRunning(_ accountId: String) -> Bool {
        guard ParallelWindows.isValidAccountID(accountId) else { return false }
        return processMap().exactWindowPID(dataDir: ParallelWindows.dirString(paths.windowDataDir(accountId))) != nil
    }

    /// Whether the window's own config.json names the account.
    func isSignedIn(_ accountId: String) -> Bool {
        ClaudeConfig.currentAccount(paths.windowConfig(accountId)) == accountId
    }

    /// May a window for this account open now? Cap 3, one account in one place (main counts).
    /// An account that is already open in a window passes (opening it again is a no-op).
    public func checkCanOpen(_ accountId: String) throws {
        guard ParallelWindows.isValidAccountID(accountId) else { throw WindowError.invalidAccount(accountId) }
        guard store.account(accountId) != nil else { throw EngineError.unknownAccount(accountId) }
        let open = liveWindows().map { URL(filePath: $0.dataDir).lastPathComponent }
        if open.contains(accountId) { return }
        try ParallelWindows.checkOpen(account: accountId, mainAccount: mainAccount(), openWindows: open)
    }

    // MARK: Registry

    /// Read, change and write `windows.json` under one lock. Returns what `body` returns.
    @discardableResult
    func updateRegistry<T>(_ body: (inout WindowRegistry) -> T) throws -> T {
        try registryLock.withLock { _ in
            var reg = WindowRegistryStore.read(paths)
            let r = body(&reg)
            try WindowRegistryStore.write(reg, to: paths)
            return r
        }
    }

    func upsert(_ record: WindowRecord, in reg: inout WindowRegistry) {
        if let i = reg.windows.firstIndex(where: { $0.accountId == record.accountId }) {
            reg.windows[i] = record
        } else {
            reg.windows.append(record)
        }
    }

    /// Makes sure the window's folder and registry entry exist (signed out until proven otherwise).
    func prepare(_ accountId: String) throws -> URL {
        let dir = try dataDir(accountId)
        try FileOps.ensureDirectory(paths.storeRoot)
        try FileOps.ensureDirectory(paths.windowsRoot)
        try FileOps.ensureDirectory(dir)
        let dirString = ParallelWindows.dirString(dir)
        let signedIn = isSignedIn(accountId)
        try updateRegistry { reg in
            var r = reg.record(accountId) ?? WindowRecord(accountId: accountId, dataDir: dirString, signedIn: signedIn)
            r.dataDir = dirString
            r.signedIn = signedIn
            upsert(r, in: &reg)
        }
        return dir
    }

    /// Brings the registry in line with the live processes: pid and openedAt follow the process,
    /// `signedIn` follows the window's own config.json, and running windows nobody recorded are added.
    @discardableResult
    public func reconcile() -> ReconcileReport {
        let live = liveWindows()
        let now = ticker.now()
        var report = ReconcileReport(vanished: [], adopted: [])
        let before = registry()
        var reg = before
        for i in reg.windows.indices {
            var r = reg.windows[i]
            if let w = live.first(where: { $0.dataDir == r.dataDir }) {
                r.pid = w.pid
                if r.openedAt == nil { r.openedAt = now }
                if isSignedIn(r.accountId) { r.signedIn = true }
            } else {
                if r.pid != nil { report.vanished.append(r.accountId) }
                r.pid = nil
                r.openedAt = nil
                r.signedIn = isSignedIn(r.accountId)
            }
            reg.windows[i] = r
        }
        for w in live where reg.windows.contains(where: { $0.dataDir == w.dataDir }) == false {
            let id = URL(filePath: w.dataDir).lastPathComponent
            guard ParallelWindows.isValidAccountID(id) else { continue }
            reg.windows.append(WindowRecord(accountId: id, dataDir: w.dataDir, signedIn: isSignedIn(id), openedAt: now, pid: w.pid))
            report.adopted.append(id)
        }
        if reg != before {
            do { try registryLock.withLock { _ in try WindowRegistryStore.write(reg, to: paths) } } catch {
                step("registry write failed: \(error)")
            }
        }
        for id in report.vanished { step("window \(id) is gone (not closed by \(Product.name))") }
        for r in reg.windows where r.pid == nil {
            guard let m = pendingUpdate(r.accountId) else { continue }
            report.waitingForUpdate.append(r.accountId)
            if report.vanished.contains(r.accountId) {
                step("window \(r.accountId) quit for an update to \(m.toVersion ?? "?"); it reopens after the main window updates")
            }
        }
        return report
    }

    /// Every window the registry knows, as the panel shows it.
    public func status() -> [WindowStatus] {
        reconcile()
        return registry().windows.map {
            WindowStatus(accountId: $0.accountId, dataDir: $0.dataDir, signedIn: $0.signedIn,
                         isOpen: $0.pid != nil, pid: $0.pid, openedAt: $0.openedAt,
                         waitingForUpdate: $0.pid == nil ? pendingUpdate($0.accountId).map { $0.toVersion ?? "newer" } : nil)
        }
    }

    // MARK: Open

    /// Runs `body` when no other switch, window action or sign-in is running (first come, first served).
    func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await gate.run(body) } catch is CancellationError { throw WindowError.cancelled }
    }

    /// Opens the window for a signed-in account: chat sync, settings sync, then launch. A window
    /// that has never been signed in throws `.needsFirstSignIn` (use `FirstSignIn`). Waits for any
    /// action that is already running.
    public func open(_ accountId: String) async throws -> WindowOpenResult {
        step("open \(accountId): requested")
        return try await exclusively { try await self.openUnlocked(accountId) }
    }

    func openUnlocked(_ accountId: String) async throws -> WindowOpenResult {
        do {
            try checkCanOpen(accountId)
            let dir = try dataDir(accountId)
            if let pid = processMap().exactWindowPID(dataDir: ParallelWindows.dirString(dir)) {
                reconcile()
                return WindowOpenResult(accountId: accountId, pid: pid, alreadyOpen: true, warnings: [])
            }
            guard isSignedIn(accountId) else { throw WindowError.needsFirstSignIn(accountId) }
            _ = try prepare(accountId)
            var warnings: [String] = []
            if let w = stagedUpdateWarning() { warnings.append(w) }
            if let w = await runChatSync() { warnings.append(w) }
            let r = try await launch(accountId, warnings: &warnings)
            step("open \(accountId): pid \(r.pid)")
            return r
        } catch {
            step("open \(accountId) aborted: \(error)")
            throw error
        }
    }

    func runChatSync() async -> String? {
        step("sync: start")
        let w = await sync.run(arguments: [], timeout: syncTimeout)
        step(w.map { "sync: failed (\($0))" } ?? "sync: done")
        return w.map { "Chat sync: \($0)" }
    }

    /// Settings sync (window closed), then `open -n -a Claude --args --user-data-dir=<dir>`, then wait
    /// for the process. Never signals anything.
    func launch(_ accountId: String, warnings: inout [String]) async throws -> WindowOpenResult {
        let dir = try prepare(accountId)
        let dirString = ParallelWindows.dirString(dir)
        if let pid = processMap().exactWindowPID(dataDir: dirString) {
            return WindowOpenResult(accountId: accountId, pid: pid, alreadyOpen: true, warnings: warnings)
        }
        if let w = await settings.apply(from: paths.claudeUserData, to: dir) {
            step("settings sync: failed (\(w))")
            // Background jobs run only in the main window: without the copy they must already be off here.
            guard ParallelWindows.backgroundJobsOff(in: dir) else { throw WindowError.settingsNotApplied(w) }
            warnings.append("Settings sync: \(w)")
        } else {
            step("settings sync: done")
        }
        do {
            try await controller.launchNewInstance(appAt: paths.claudeApp, arguments: ParallelWindows.launchArguments(dataDir: dir))
        } catch {
            throw error as? WindowError ?? WindowError.launchFailed(accountId)
        }
        let start = ticker.now()
        while true {
            if let pid = processMap().exactWindowPID(dataDir: dirString) {
                let now = ticker.now()
                try updateRegistry { reg in
                    var r = reg.record(accountId) ?? WindowRecord(accountId: accountId, dataDir: dirString, signedIn: false)
                    r.pid = pid
                    r.openedAt = now
                    upsert(r, in: &reg)
                }
                return WindowOpenResult(accountId: accountId, pid: pid, alreadyOpen: false, warnings: warnings)
            }
            if ticker.now().timeIntervalSince(start) > launchTimeout { throw WindowError.launchFailed(accountId) }
            if Task.isCancelled { throw WindowError.cancelled }
            do { try await ticker.sleep(seconds: 0.25) } catch { throw WindowError.cancelled }
        }
    }

    // MARK: Close

    /// Closes one window by signalling only its own process (SIGTERM, by exact arguments) and waiting
    /// for it and its helpers to go. The main window and the other windows are never touched, and
    /// nothing is force-killed: if the window does not exit in `closeTimeout`, this throws and leaves it.
    /// Returns the chat-sync warning, if any.
    @discardableResult
    public func close(_ accountId: String) async throws -> String? {
        _ = try dataDir(accountId)
        step("close \(accountId): requested")
        return try await exclusively { try await self.closeUnlocked(accountId) }
    }

    @discardableResult
    func closeUnlocked(_ accountId: String) async throws -> String? {
        let dir = try dataDir(accountId)
        let app = ManagedApp.claudeWindow(paths, dataDir: dir)
        let dirString = ParallelWindows.dirString(dir)
        if processMap().exactWindowPID(dataDir: dirString) == nil {
            // Closing a window that is waiting for an update cancels the wait.
            cancelPendingReopen(accountId)
        } else {
            do {
                try await quitter.quitAndWait(app)
            } catch EngineError.stillRunning {
                step("close \(accountId): still running after \(Int(closeTimeout)) s; nothing forced")
                throw WindowError.windowStillRunning(accountId)
            } catch EngineError.cancelled {
                throw WindowError.cancelled
            }
        }
        try updateRegistry { reg in
            if var r = reg.record(accountId) {
                r.pid = nil
                r.openedAt = nil
                r.signedIn = isSignedIn(accountId)
                upsert(r, in: &reg)
            }
        }
        step("close \(accountId): done")
        // Chats started in this window flow to the others.
        return await runChatSync()
    }

    // MARK: Updates

    func updateMarkerURL(_ accountId: String) -> URL { paths.windowDataDir(accountId).appending(path: "update-attempt") }

    /// The update marker of a window that is not running, if it is still a live reason to wait.
    func pendingUpdate(_ accountId: String) -> UpdateMarker? {
        guard ParallelWindows.isValidAccountID(accountId), windowIsRunning(accountId) == false,
              let m = UpdateMarker.read(updateMarkerURL(accountId)),
              ticker.now().timeIntervalSince(m.writtenAt) <= UpdateMarker.maxAge else { return nil }
        return m
    }

    /// Windows that quit to install an update and have not been reopened.
    public func windowsWaitingForUpdate() -> [(accountId: String, marker: UpdateMarker)] {
        registry().windows.compactMap { r in pendingUpdate(r.accountId).map { (r.accountId, $0) } }
    }

    /// Forgets that a window was waiting for an update (the marker is Claude's, but a window the
    /// user closed on purpose must not come back).
    public func cancelPendingReopen(_ accountId: String) {
        guard ParallelWindows.isValidAccountID(accountId), windowIsRunning(accountId) == false else { return }
        if (try? FileManager.default.removeItem(at: updateMarkerURL(accountId))) != nil {
            step("window \(accountId): update wait cancelled")
        }
    }

    /// The main window has downloaded an update it has not installed yet (its own config.json holds
    /// the staged version). An extra window opened now would quit when that update installs.
    func stagedUpdateWarning() -> String? {
        guard let cfg = try? ClaudeConfig.load(paths.liveConfig),
              let staged = (cfg["updaterStagedPayloadKind"] as? [String: Any])?["version"] as? String,
              let installed = ClaudeApp.version(paths),
              let c = AppVersion.compare(staged, installed), c > 0 else { return nil }
        return "The main window has an update waiting (\(staged)). Update it first; an extra window quits when an update installs, and \(Product.name) reopens it after the main window has updated."
    }

    /// Reopens every window that quit for an update once the installed Claude has reached the
    /// marker's version and the main window is running again. One try per update quit: a window
    /// that fails to come back stays closed and is reported, not retried in a loop. Call this
    /// every few seconds; it does nothing when no window is waiting. It is background work, so it runs
    /// only when nothing else does: while a switch, an open, a close or a sign-in is running it is skipped
    /// (empty result) and tried again at the next call.
    @discardableResult
    public func reopenAfterUpdate() async -> [UpdateReopenResult] {
        guard let results = await gate.runIfIdle({ await reopenUnlocked() }) else {
            step("reopen after update: skipped, another action is running")
            return []
        }
        return results
    }

    private func reopenKey(_ id: String, _ marker: UpdateMarker) -> String {
        "\(id)|\(Int(marker.writtenAt.timeIntervalSince1970 * 1000))"
    }

    /// The windows `reopenAfterUpdate()` would reopen right now: waiting for an update that the installed
    /// Claude has reached, with the main window running, and not tried yet. Read-only and never waits,
    /// so the app can ask before it shows a "reopening" action.
    public func windowsReadyToReopen() -> [String] {
        reconcile()
        let installed = ClaudeApp.version(paths)
        guard mainPID() != nil else { return [] }
        return windowsWaitingForUpdate().filter { id, marker in
            marker.isInstalled(version: installed) && reopenAttempted.withLock { $0.contains(reopenKey(id, marker)) } == false
        }.map(\.accountId)
    }

    func reopenUnlocked() async -> [UpdateReopenResult] {
        reconcile()
        var results: [UpdateReopenResult] = []
        for (id, marker) in windowsWaitingForUpdate() {
            let key = reopenKey(id, marker)
            if reopenAttempted.withLock({ $0.contains(key) }) { continue }
            guard marker.isInstalled(version: ClaudeApp.version(paths)), mainPID() != nil else {
                results.append(UpdateReopenResult(accountId: id, outcome: .waiting))
                continue
            }
            reopenAttempted.withLock { _ = $0.insert(key) }
            step("window \(id): main window is on the new version; reopening")
            do {
                let r = try await openUnlocked(id)
                results.append(UpdateReopenResult(accountId: id, outcome: .reopened(pid: r.pid)))
            } catch WindowError.accountIsMain, WindowError.accountInWindow {
                cancelPendingReopen(id)
                results.append(UpdateReopenResult(accountId: id, outcome: .dropped))
            } catch WindowError.capReached(let cap) {
                // Nothing was started, so it is safe to try again once a place is free.
                reopenAttempted.withLock { _ = $0.remove(key) }
                step("window \(id): not reopened, \(cap) extra windows are already open")
                results.append(UpdateReopenResult(accountId: id, outcome: .failed("\(WindowError.capReached(cap))")))
            } catch {
                step("window \(id): reopen failed: \(error)")
                results.append(UpdateReopenResult(accountId: id, outcome: .failed("\(error)")))
            }
        }
        return results
    }
}
