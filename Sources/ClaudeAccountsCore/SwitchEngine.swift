import Foundation

public enum SwitchPhase: Sendable, Equatable {
    case checking, syncingChats, quittingClaude, claudeAsking, waitingForClaude, saving, restoring, opening, verifying
    /// Still waiting after 30 s on this many of Claude's own processes.
    case waitingOn(Int)
    case quittingChrome, chromeAsking, restoringChrome, openingChrome
    case waitingForSignIn
    case done

    /// The switch can be cancelled with nothing changed until files start moving.
    public var isInterruptible: Bool {
        switch self {
        case .checking, .syncingChats, .quittingClaude, .claudeAsking, .waitingForClaude, .waitingOn: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .checking: "Checking"
        case .syncingChats: "Syncing chats"
        case .quittingClaude: "Quitting Claude"
        case .claudeAsking: "Claude is asking…"
        case .waitingForClaude: "Waiting for Claude to close…"
        case .waitingOn(let n): n == 1 ? "Waiting on 1 Claude process" : "Waiting on \(n) Claude processes"
        case .saving: "Saving"
        case .restoring: "Restoring"
        case .opening: "Opening"
        case .verifying: "Opening"
        case .quittingChrome: "Quitting Chrome"
        case .chromeAsking: "Chrome is asking"
        case .restoringChrome: "Restoring Chrome"
        case .openingChrome: "Opening Chrome"
        case .waitingForSignIn: "Sign in to Claude"
        case .done: "Done"
        }
    }
}

/// What to do about Chrome during a switch.
public enum ChromePlan: Sendable, Equatable {
    /// Desktop only.
    case skip
    /// Swap Chrome if it's closed; otherwise leave it alone.
    case ifClosed
    /// Quit Chrome politely, swap, reopen. If it won't quit, fall back to `whenNextQuits`.
    case restartNow
    /// Swap within a second of Chrome's next exit, and leave it closed.
    case whenNextQuits
    /// Quit Chrome together with Claude, swap both, relaunch both (default when Chrome follows).
    /// If Chrome won't quit within 20 s, the Claude switch goes ahead and Chrome swaps on quit.
    case withClaude
}

public enum ChromeOutcome: Sendable, Equatable {
    case notRequested
    case notSetUp
    /// `confirmed` only with evidence: the extension wrote its storage after Chrome reopened and
    /// reports the target account. A swap while Chrome is closed is never confirmed.
    case switched(confirmed: Bool)
    case deferred
    case failed(String)
    /// The outgoing Chrome login couldn't be saved, so Chrome was left exactly as it was.
    case kept(label: String?)
}

public enum AddResult: Sendable, Equatable {
    case waiting
    case added(Account)
    /// The sign-in landed on an account already saved here; the add stays pending.
    case signedInAsKnown(Account)
}

public struct SwitchOutcome: Sendable, Equatable {
    public var backupID: String
    public var target: String
    public var verdict: LaunchVerdict
    public var chrome: ChromeOutcome
    public var syncWarning: String?
    /// The outgoing account was unknown and got registered as "Unnamed account".
    public var registeredOutgoing: String?
}

/// The switch, add, rollback and Chrome flows. All I/O goes through `Paths`, the store and the
/// injected probe/controller/ticker/sync runner.
public final class SwitchEngine: Sendable {
    public let paths: Paths
    public let store: AccountStore
    public let quitter: QuitCoordinator
    public let sync: SyncRunner
    public let verifyTimeout: Double
    public let chromeVerifyTimeout: Double
    public let syncTimeout: Double
    let browserPaneDelay: Double
    /// One action at a time across this engine and the window engine (shared with it by the app).
    public let gate: ActionGate
    /// Writes config.json with the account set and oauth keys dropped. Injectable so tests can fail it.
    let rewriteConfig: @Sendable (URL, String?) throws -> Void

    public var ticker: Ticker { quitter.ticker }
    public var controller: AppController { quitter.controller }
    public var claude: ManagedApp { .claude(paths) }
    public var chromeApp: ManagedApp { .chrome(paths) }

    public init(paths: Paths, store: AccountStore? = nil, probe: ProcessProbe, controller: AppController,
                ticker: Ticker, sync: SyncRunner, quitTimeout: Double = 120, verifyTimeout: Double = 30,
                chromeVerifyTimeout: Double = 30, syncTimeout: Double = 60,
                rewriteConfig: @escaping @Sendable (URL, String?) throws -> Void = { try ClaudeConfig.rewrite($0, account: $1) },
                browserPaneDelay: Double = 20, gate: ActionGate = ActionGate()) {
        self.browserPaneDelay = browserPaneDelay
        self.gate = gate
        self.rewriteConfig = rewriteConfig
        self.paths = paths
        self.store = store ?? AccountStore(paths: paths)
        var q = QuitCoordinator(probe: probe, controller: controller, ticker: ticker)
        q.quitTimeout = quitTimeout
        self.quitter = q
        self.sync = sync
        self.verifyTimeout = verifyTimeout
        self.chromeVerifyTimeout = chromeVerifyTimeout
        self.syncTimeout = syncTimeout
    }

    /// The real system: libproc, NSWorkspace, wall clock, mirror.py.
    public static func system(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) -> SwitchEngine {
        if environment["CLAUDE_ACCOUNTS_DRY_CONTROLLER"] == "1" {
            return SwitchEngine(paths: paths, probe: EmptyProcessProbe(), controller: DryRunAppController(),
                                ticker: SystemTicker(), sync: PythonSyncRunner.system(paths: paths, environment: environment))
        }
        return SwitchEngine(paths: paths, probe: SystemProcessProbe(), controller: SystemAppController(),
                     ticker: SystemTicker(), sync: PythonSyncRunner.system(paths: paths, environment: environment))
    }

    // MARK: Read-only queries

    public func currentAccount() -> String? { ClaudeConfig.currentAccount(paths.liveConfig) }

    public func busyChats() -> Int {
        BusyCheck.workingChats(projects: paths.claudeProjects, now: ticker.now())
    }

    public func liveCookieExpiry() -> Date? { CookieDB.sessionExpiry(paths.liveCookies) }

    /// Checks that the live files look the way this build expects. Read only.
    public func checkLiveShape() throws {
        try ClaudeConfig.checkShape(paths.liveConfig)
        guard FileOps.exists(paths.liveCookies) else { throw EngineError.shapeMismatch("no Cookies file") }
        let cols = try CookieDB.columns(paths.liveCookies)
        for c in ["host_key", "name", "encrypted_value", "expires_utc"] where cols.contains(c) == false {
            throw EngineError.shapeMismatch("Cookies has no \(c) column")
        }
        guard CookieDB.hasClaudeLogin(paths.liveCookies) else { throw EngineError.shapeMismatch("no claude.ai session cookie") }
    }

    /// Synchronous re-check right before a destructive write: no process of the app is alive.
    func assertClosed(_ app: ManagedApp) throws {
        if quitter.requiredProcesses(app).isEmpty == false {
            throw app.bundleID == Paths.chromeBundleID ? EngineError.chromeNotClosed : EngineError.claudeReopened
        }
    }

    func notice(_ message: String) {
        store.log("notice: \(message)")
        try? store.updateState { $0.chromeNotice = message }
    }

    func setInFlight(_ f: InFlight?) throws {
        try store.updateState { $0.inFlight = f }
    }

    func setStep(_ step: String) {
        try? store.updateState { $0.inFlight?.step = step }
    }

    func preflight(target: String) throws -> String {
        guard store.account(target) != nil else { throw EngineError.unknownAccount(target) }
        // One account in one place: the main window may not take an account an extra window has open.
        if ParallelWindows.isOpenInWindow(target, procs: quitter.probe.processes(), paths: paths) {
            throw WindowError.accountInWindow(target)
        }
        guard FileOps.exists(paths.slotDesktopCookies(target)) else { throw EngineError.noSavedLogin(target) }
        guard CookieDB.hasClaudeLogin(paths.slotDesktopCookies(target)) else {
            throw EngineError.shapeMismatch("saved login for \(target) has no session cookie")
        }
        do {
            try checkLiveShape()
        } catch let e as EngineError {
            store.log("preflight refused: \(e)")
            throw e
        }
        let version = ClaudeApp.version(paths)
        if let version, let last = store.state().lastGoodClaudeVersion, last != version {
            store.log("Claude version changed \(last) -> \(version); shape check passed")
        }
        guard let current = currentAccount() else { throw EngineError.shapeMismatch("no lastKnownAccountUuid") }
        if current == target { throw EngineError.alreadyCurrent }
        return current
    }

    // MARK: Desktop switch

    /// Steps 1–11 of the spec. The busy check is informational and the caller's (`busyChats()`);
    /// Claude's own quit dialog is what actually asks.
    public func switchTo(_ target: String, chrome plan: ChromePlan = .skip,
                         progress: @escaping @Sendable (SwitchPhase) -> Void = { _ in }) async throws -> SwitchOutcome {
        step("switch to \(target): requested")
        return try await exclusively { try await self.switchToUnlocked(target, chrome: plan, progress: progress) }
    }

    /// Runs `body` when no other switch, rollback, add or window action is running.
    func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await gate.run(body) } catch is CancellationError { throw EngineError.cancelled }
    }

    func switchToUnlocked(_ target: String, chrome plan: ChromePlan,
                          progress: @escaping @Sendable (SwitchPhase) -> Void) async throws -> SwitchOutcome {
        progress(.checking)
        let current: String
        do { current = try preflight(target: target) } catch { step("switch aborted: \(error)"); throw error }
        step("switch \(current) -> \(target): start")

        progress(.syncingChats)
        step("sync: start")
        let syncWarning = await sync.run(arguments: [], timeout: syncTimeout)
        step(syncWarning.map { "sync: failed (\($0))" } ?? "sync: done")
        try? store.updateState { $0.lastSyncFailed = syncWarning != nil }
        if Task.isCancelled { step("switch aborted: cancelled"); throw EngineError.cancelled }

        try? store.updateState { $0.chromeAwaitingSignIn = nil }

        // With Claude: ask Chrome to quit at the same time as Claude, and wait for both.
        let chromeWasRunning = plan == .withClaude ? await quitter.isRunning(chromeApp) : false
        // Chrome's quit is requested only once Claude is past its "still working" dialog (no window
        // left, or exited), so cancelling in Claude's dialog never touches Chrome. It then overlaps
        // Claude's exit and cleanup.
        let chromeBox = ChromeQuitBox()
        let startChrome: @Sendable () -> Void = { [self] in
            guard chromeWasRunning else { return }
            chromeBox.startOnce { Task { await self.quitChromeBounded() } }
        }
        var chromeQuit: Task<Bool, Never>? { chromeBox.task }
        do {
            try await quitClaudeOrAbort(progress: progress, pastDialog: startChrome)
            startChrome()
        } catch {
            // The switch is off: bring Chrome back if we closed it.
            if let chromeQuit, await chromeQuit.value, await quitter.isRunning(chromeApp) == false {
                step("chrome: relaunch after aborted switch")
                try? await controller.open(appAt: chromeApp.appURL)
            }
            throw error
        }
        let chromeExited = await chromeQuit?.value ?? true
        let chromeCtx = ChromeContext(wasRunning: chromeWasRunning, exited: chromeExited)

        // Files start moving: from here on cancellation is ignored.
        return try await afterQuit("switch") {
            try await self.performSwap(from: current, to: target, plan: plan, chrome: chromeCtx,
                                       syncWarning: syncWarning, progress: progress)
        }
    }

    /// One timestamped line per step in switch.log, so a stall is never silent.
    func step(_ message: String) { store.log(message, now: ticker.now()) }

    /// Diagnostic line about Claude's in-app browser pane (read only).
    func logBrowserPane(_ when: String) {
        step(BrowserPane.line(BrowserPane.read(paths)) + " (\(when))")
    }

    /// The same line ~20 s after a relaunch, once Claude has settled. Skipped if the store is gone.
    func scheduleBrowserPaneLog() {
        let delay = browserPaneDelay
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            guard FileOps.isDirectory(paths.storeRoot) else { return }
            logBrowserPane("~\(Int(delay)) s after relaunch")
        }
    }

    /// Reopens Claude unless its main app is already running.
    func reopenClaudeIfClosed() async {
        if await controller.isRunning(bundleID: claude.bundleID) == false {
            step("relaunch: Claude")
            try? await controller.open(appAt: claude.appURL)
        }
    }

    /// Runs the post-quit part uncancellably. Any failure relaunches Claude, except a half-swap
    /// (restore failed / rollback failed), which leaves it closed for Restore Backup.
    func afterQuit<T: Sendable>(_ op: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        do {
            return try await task.value
        } catch {
            switch error {
            case EngineError.restoreFailed, EngineError.rollbackFailed:
                step("\(op) aborted: \(error); Claude left closed")
            default:
                step("\(op) aborted: \(error)")
                await reopenClaudeIfClosed()
            }
            throw error
        }
    }

    func quitClaudeOrAbort(progress: @escaping @Sendable (SwitchPhase) -> Void,
                           pastDialog: @escaping @Sendable () -> Void = {}) async throws {
        progress(.quittingClaude)
        logBrowserPane("before quit")
        do {
            try await quitter.quitAndWait(claude) { [self] ev in
                switch ev {
                case .requested: step("quit: requested")
                case .appIsAsking:
                    step("quit: Claude's dialog is up")
                    progress(.claudeAsking)
                case .waitingToFinish:
                    step("quit: waiting for Claude to close")
                    progress(.waitingForClaude)
                    pastDialog()
                case .waitingOn(let n):
                    step("quit: still waiting on \(n) Claude process(es)")
                    progress(.waitingOn(n))
                case .exited:
                    step("quit: exited")
                    pastDialog()
                    logBrowserPane("after exit")
                case .lingering(let n): step("quit: proceeding; \(n) CLI/helper process(es) still exiting")
                }
            }
        } catch {
            step("quit Claude aborted: \(error)")
            // Reopen only if the main app is gone; lingering claude-code children don't count.
            await reopenClaudeIfClosed()
            throw error
        }
    }

    struct ChromeContext: Sendable {
        var wasRunning: Bool
        var exited: Bool
    }

    /// Asks Chrome to quit (never forced) and waits up to 20 s. True if it exited.
    func quitChromeBounded() async -> Bool {
        var q = quitter
        q.quitTimeout = ChromeFollow.quitTimeout
        step("chrome: quit requested (with Claude)")
        do {
            try await q.quitAndWait(chromeApp)
            step("chrome: exited")
            return true
        } catch {
            step("chrome: didn't quit in \(Int(ChromeFollow.quitTimeout)) s (\(error))")
            return false
        }
    }

    /// The target has no Chrome slot: back up, save the outgoing login (attribution rules), then
    /// remove only the claude.ai rows and the extension settings locally (no server sign-out). The
    /// slot is saved at the next switch-out, attributed to `target`.
    /// `.kept` (Chrome untouched) when the outgoing login can't be saved.
    @discardableResult
    func seedChrome(for target: String, backupID: String?) throws -> ChromeOutcome {
        try assertClosed(chromeApp)
        if case .keep(let l) = prepareOutgoingChrome(target: target) {
            notice(PanelCopy.chromeKept(l))
            return .kept(label: l)
        }
        let cb = try store.makeChromeBackup(reason: "chrome seed for \(target)", chromeAccount: store.state().chromeAccount, now: ticker.now())
        if let backupID { try store.link(chromeBackup: cb.id, toBackup: backupID) }
        let staged = try CookieDB.stageRemove(paths.chromeCookies)
        try store.updateState { $0.chromeAccount = nil }
        try commitChrome(stagedCookies: staged, extensionSource: nil)
        // Unknown until the extension reports who signed in (resolveChromeAttribution).
        try store.updateState {
            $0.chromeAccount = nil
            $0.chromeAwaitingSignIn = target
        }
        step("chrome: cleared claude.ai for \(target) to sign in")
        return .switched(confirmed: false)
    }

    func performSwap(from current: String, to target: String, plan: ChromePlan, chrome: ChromeContext = .init(wasRunning: false, exited: true),
                     syncWarning: String?,
                     progress: @escaping @Sendable (SwitchPhase) -> Void) async throws -> SwitchOutcome {
        let now = ticker.now()
        try assertClosed(claude)
        try FileOps.removeIfPresent(paths.liveConfigJournal)

        progress(.saving)
        let backupID = store.newBackupID(now: now)
        var registered: String?
        do {
            try setInFlight(InFlight(kind: .switchAccount, backupID: backupID, from: current, to: target, step: "backup"))
            step("backup: start")
            _ = try store.makeBackup(id: backupID, reason: "switch", from: current, to: target, now: now)
            step("backup: \(backupID)")
            step("save: \(current)")
            setStep("save")
            try assertClosed(claude)
            registered = try saveDesktop(current, now: now)
        } catch {
            // The live files are untouched so far; afterQuit relaunches Claude.
            step("save failed: \(error); live files unchanged")
            try? setInFlight(nil)
            throw error
        }

        progress(.restoring)
        setStep("restore")
        step("restore: \(target)")
        var wroteLive = false
        do {
            try assertClosed(claude)
            try FileOps.copyAtomically(paths.slotDesktopCookies(target), to: paths.liveCookies)
            wroteLive = true
            try FileOps.removeIfPresent(paths.liveCookiesJournal)
            try assertClosed(claude)
            try rewriteConfig(paths.liveConfig, target)
            try FileOps.removeIfPresent(paths.liveConfigJournal)
            store.log("restored desktop slot \(target)")
        } catch {
            if wroteLive == false {
                store.log("restore stopped before any write: \(error)")
                try? setInFlight(nil)
                throw error
            }
            // Half-swapped: never relaunch. The in-flight record stays so startup recovery or the
            // panel's Restore backup action can put the old login back.
            store.log("restore failed after a write: \(error); Claude left closed; backup \(backupID)")
            throw EngineError.restoreFailed(backupID: backupID)
        }
        try setInFlight(nil)

        var chromeOutcome = ChromeOutcome.notRequested
        var chromeSeeded = false
        if plan == .withClaude {
            let hasSlot = FileOps.exists(paths.slotChromeCookies(target))
            if chrome.exited, await quitter.isRunning(chromeApp) == false {
                if hasSlot {
                    chromeOutcome = await swapChromeNow(to: target, backupID: backupID)
                    if case .switched = chromeOutcome { step("chrome: restored \(target)") }
                } else {
                    do {
                        chromeOutcome = try seedChrome(for: target, backupID: backupID)
                        if case .switched = chromeOutcome { chromeSeeded = true }
                    } catch {
                        step("chrome: clearing for sign-in failed (\(error))")
                        chromeOutcome = .failed("\(error)")
                    }
                }
                if case .failed = chromeOutcome {
                    // Claude switched; retry Chrome on its next quit.
                    try? store.updateState { $0.pendingChrome = hasSlot ? .slot(target) : .seedTarget(target) }
                    step("chrome: swap failed; will retry when Chrome next quits")
                    chromeOutcome = .deferred
                }
            } else {
                try? store.updateState { $0.pendingChrome = hasSlot ? .slot(target) : .seedTarget(target) }
                step("chrome: swap to \(target) queued for when Chrome quits")
                chromeOutcome = .deferred
            }
        } else if plan != .skip, await quitter.isRunning(chromeApp) == false {
            chromeOutcome = await swapChromeNow(to: target, backupID: backupID)
        }

        progress(.opening)
        let logOffset = LaunchLog.offset(paths.mainLog)
        step("relaunch: Claude")
        try await controller.open(appAt: claude.appURL)
        if plan == .withClaude, chrome.wasRunning, chrome.exited {
            step("chrome: relaunch")
            try? await controller.open(appAt: chromeApp.appURL)
            if chromeSeeded {
                step("chrome: opened claude.ai/login")
                try? await controller.open(url: ChromeFollow.loginURL, inAppAt: chromeApp.appURL)
            }
        }
        scheduleBrowserPaneLog()
        progress(.verifying)
        step("verify: start")
        let verdict = await verifyLaunch(target: target, logOffset: logOffset)
        step("verify: \(verdict)")

        try store.updateAccounts { list in
            if let i = list.firstIndex(where: { $0.id == target }) { list[i].lastUsedAt = ticker.now() }
        }
        if verdict == .success {
            let v = ClaudeApp.version(paths)
            try? store.updateState { $0.lastGoodClaudeVersion = v }
        }

        if plan != .skip, chromeOutcome == .notRequested {
            chromeOutcome = await handleRunningChrome(target: target, plan: plan, progress: progress)
        }
        store.writeSyncLabels()
        step("switch \(current) -> \(target): done")
        progress(.done)
        return SwitchOutcome(backupID: backupID, target: target, verdict: verdict, chrome: chromeOutcome,
                             syncWarning: syncWarning, registeredOutgoing: registered)
    }

    /// Step 7. Copies the live Cookies into the outgoing slot if it holds a login, keeping the
    /// previous slot as `Cookies.prev`. Returns the id if the account had to be registered.
    func saveDesktop(_ id: String, now: Date) throws -> String? {
        guard CookieDB.hasClaudeLogin(paths.liveCookies) else {
            store.log("outgoing \(id) has no session cookie; not saved")
            return nil
        }
        if let owner = otherSlotOwning(liveFingerprint: id) {
            store.log("live login matches \(owner)'s saved login, not \(id)'s; not saved")
            return nil
        }
        let wasKnown = store.account(id) != nil
        if wasKnown == false { try store.register(id, label: nil, now: now) }
        let slot = paths.slotDesktopCookies(id)
        try FileOps.ensureDirectory(slot.deletingLastPathComponent())
        try store.keepPrevious(slot)
        try FileOps.copyAtomically(paths.liveCookies, to: slot)
        // Attribution is certain here (cookie guard + fingerprint passed), so the raw encrypted
        // oauth cache may be saved for usage reads. It's never decrypted or logged.
        saveOAuthCache(for: id)
        let expiry = CookieDB.sessionExpiry(slot)
        let version = ClaudeApp.version(paths)
        try store.updateAccounts { list in
            if let i = list.firstIndex(where: { $0.id == id }) {
                list[i].desktop = DesktopSlot(savedAt: now, claudeVersion: version, cookieExpiresAt: expiry)
            }
        }
        store.log("saved desktop slot \(id)")
        return wasKnown ? nil : id
    }

    /// Another account whose saved login has the same `sessionKeyV3` creation time as the live
    /// one: the live cookie is that account's, whatever config.json says. Metadata only.
    func otherSlotOwning(liveFingerprint id: String) -> String? {
        guard let live = CookieDB.sessionFingerprint(paths.liveCookies) else { return nil }
        return store.accounts().first { a in
            a.id != id && CookieDB.sessionFingerprint(paths.slotDesktopCookies(a.id)) == live
        }?.id
    }

    /// Copies the live, still-encrypted `oauth:tokenCacheV2` into the account's slot, keeping a
    /// `.prev`. Silent if the live config has no cache. Only called from `saveDesktop`, after the
    /// cookie guard and attribution checks pass.
    func saveOAuthCache(for id: String) {
        guard let blob = ClaudeConfig.encryptedOAuthCache(paths.liveConfig) else { return }
        let dest = paths.slotOAuthCache(id)
        do {
            try FileOps.ensureDirectory(dest.deletingLastPathComponent())
            try store.keepPrevious(dest)
            try FileOps.writeAtomically(Data(blob.utf8), to: dest)
            store.log("saved oauth cache slot \(id)")
        } catch {
            store.log("oauth cache not saved for \(id): \(error)")
        }
    }

    /// Saves the live login as the current account's slot. Claude must be closed. Returns false
    /// when the live Cookies holds no login.
    public func saveCurrentDesktop() throws -> Bool {
        try assertClosed(claude)
        guard let id = currentAccount(), CookieDB.hasClaudeLogin(paths.liveCookies) else { return false }
        _ = try saveDesktop(id, now: ticker.now())
        return true
    }

    /// Puts a backup's Cookies and config.json back, re-checking that Claude is closed before each write.
    func restoreDesktopFiles(fromBackup id: String) throws {
        let dir = store.backupDir(id)
        let cookies = dir.appending(path: "Cookies")
        try assertClosed(claude)
        // Never delete a live file the backup can't replace.
        if FileOps.exists(cookies) {
            try FileOps.copyAtomically(cookies, to: paths.liveCookies)
            try FileOps.removeIfPresent(paths.liveCookiesJournal)
        }
        try assertClosed(claude)
        try FileOps.copyAtomically(dir.appending(path: "config.json"), to: paths.liveConfig)
        try FileOps.removeIfPresent(paths.liveConfigJournal)
    }

    /// Step 10: config.json still names the account, and main.log has no sign-in failure since launch.
    /// Step 10, with a hard ceiling. Runs on its own thread with a wall-clock (ticker) deadline, so
    /// it can't stall when Swift's cooperative pool is busy: the old loop's only clock was
    /// `Task.sleep` on that pool, and blocking work elsewhere (a Keychain prompt under a lock, a
    /// launchctl wait) could starve it so the 60 s check never came round. Reads only what main.log
    /// gained since the launch offset.
    func verifyLaunch(target: String, logOffset: UInt64) async -> LaunchVerdict {
        let ticker = self.ticker, timeout = verifyTimeout, paths = self.paths
        let current: @Sendable () -> String? = { ClaudeConfig.currentAccount(paths.liveConfig) }
        return await withCheckedContinuation { (cont: CheckedContinuation<LaunchVerdict, Never>) in
            Self.verifyQueue.async {
                let start = ticker.now()
                var verdict = LaunchVerdict.pending
                while true {
                    let now = ticker.now()
                    if let id = current(), id != target { verdict = .failure("config.json changed account"); break }
                    let v = LaunchLog.verdict(mainLog: paths.mainLog, from: logOffset, target: target, now: now)
                    if v != .pending { verdict = v; break }
                    if now.timeIntervalSince(start) >= timeout { break }
                    ticker.sleepBlocking(seconds: 0.5)
                }
                if verdict == .success, let id = current(), id != target { verdict = .failure("config.json changed account") }
                cont.resume(returning: verdict)
            }
        }
    }

    static let verifyQueue = DispatchQueue(label: "claude-accounts.verify", qos: .userInitiated)

    // MARK: Interrupted operations

    /// At startup: if a switch, rollback or add was interrupted mid-write and Claude isn't running,
    /// put its backup back (Cookies and config.json). Returns a message for the panel, or nil.
    public func recoverInterrupted() async -> String? {
        guard let f = store.state().inFlight else { return nil }
        // Before the restore step the live files were never touched: nothing to undo.
        if f.step == "backup" || f.step == "save" {
            try? setInFlight(nil)
            store.log("interrupted \(f.kind.rawValue) at step \(f.step): live files untouched; cleared")
            return nil
        }
        if await quitter.isRunning(claude) {
            return "A switch was interrupted (backup \(f.backupID)). Claude is open, so nothing was restored."
        }
        guard store.isVerified(f.backupID) else {
            store.log("recovery refused: backup \(f.backupID) is missing or incomplete")
            return "A switch was interrupted, but backup \(f.backupID) is incomplete, so nothing was changed."
        }
        do {
            try restoreDesktopFiles(fromBackup: f.backupID)
            try setInFlight(nil)
            store.log("recovered interrupted \(f.kind.rawValue) at step \(f.step) from backup \(f.backupID)")
            return "An interrupted switch was undone: backup \(f.backupID) was restored. Open Claude when you're ready."
        } catch {
            store.log("recovery from \(f.backupID) failed: \(error)")
            return "An interrupted switch couldn't be undone automatically: \(error). Backup \(f.backupID) holds the old login."
        }
    }

    // MARK: Rollback

    /// Restores a backup the same way as a switch: quit, swap, relaunch. The live login is saved to
    /// its slot (if it holds one) and the current files are backed up first, so a rollback can
    /// itself be undone.
    public func rollback(_ backupID: String, chrome plan: ChromePlan = .ifClosed,
                         progress: @escaping @Sendable (SwitchPhase) -> Void = { _ in }) async throws -> SwitchOutcome {
        step("rollback to \(backupID): requested")
        return try await exclusively { try await self.rollbackUnlocked(backupID, chrome: plan, progress: progress) }
    }

    func rollbackUnlocked(_ backupID: String, chrome plan: ChromePlan,
                          progress: @escaping @Sendable (SwitchPhase) -> Void) async throws -> SwitchOutcome {
        progress(.checking)
        guard let m = store.manifest(backupID) else { throw EngineError.missing("backup \(backupID)") }
        guard m.hasDesktop, FileOps.exists(store.backupDir(backupID).appending(path: "config.json")) else {
            throw EngineError.missing("backup \(backupID) has no desktop files")
        }
        try await quitClaudeOrAbort(progress: progress)
        return try await afterQuit("rollback") { () throws -> SwitchOutcome in
            let now = self.ticker.now()
            try self.assertClosed(self.claude)
            try FileOps.removeIfPresent(self.paths.liveConfigJournal)
            progress(.saving)
            let current = self.currentAccount()
            // After a half-swap the live cookie may not belong to the account config.json names.
            if let current, self.store.account(current) != nil, self.store.state().inFlight == nil {
                _ = try self.saveDesktop(current, now: now)
            }
            let pre = try self.store.makeBackup(reason: "before rollback of \(backupID)", from: current,
                                                to: m.fromAccount, protecting: [backupID], now: now)
            try self.setInFlight(InFlight(kind: .rollback, backupID: backupID, from: current, to: m.fromAccount,
                                          step: "restore", preBackupID: pre.id))
            progress(.restoring)
            do {
                try self.restoreDesktopFiles(fromBackup: backupID)
            } catch {
                self.store.log("rollback to \(backupID) failed: \(error); pre-rollback backup \(pre.id)")
                throw EngineError.rollbackFailed(backupID: backupID, preBackupID: pre.id)
            }
            try self.setInFlight(nil)
            self.store.log("rolled back desktop to \(backupID)")
            var chrome = ChromeOutcome.notRequested
            if let cid = m.chromeBackupID, plan != .skip {
                if await self.quitter.isRunning(self.chromeApp) {
                    try self.store.updateState { $0.pendingChrome = .backup(cid) }
                    chrome = .deferred
                } else {
                    chrome = await self.restoreChromeBackup(cid)
                }
            }
            progress(.opening)
            let logOffset = LaunchLog.offset(self.paths.mainLog)
            try await self.controller.open(appAt: self.claude.appURL)
            progress(.verifying)
            let verdict: LaunchVerdict
            if let from = m.fromAccount {
                verdict = await self.verifyLaunch(target: from, logOffset: logOffset)
            } else {
                verdict = .pending
            }
            progress(.done)
            self.step("rollback to \(backupID): \(verdict); done")
            return SwitchOutcome(backupID: pre.id, target: m.fromAccount ?? "", verdict: verdict, chrome: chrome,
                                 syncWarning: nil, registeredOutgoing: nil)
        }
    }

    // MARK: Add account

    /// Steps 1–2 of Add account: quit, save the current account, remove the live login locally (no
    /// server logout), drop the oauth caches and relaunch to the sign-in screen. `completeAdd()`
    /// registers the new uuid once it appears. `reauth` marks a "Sign in again" for a known account.
    public func beginAdd(label: String, reauth: String? = nil, chrome plan: ChromePlan = .skip,
                         progress: @escaping @Sendable (SwitchPhase) -> Void = { _ in }) async throws {
        step("add: requested")
        try await exclusively { try await self.beginAddUnlocked(label: label, reauth: reauth, chrome: plan, progress: progress) }
    }

    func beginAddUnlocked(label: String, reauth: String?, chrome plan: ChromePlan,
                          progress: @escaping @Sendable (SwitchPhase) -> Void) async throws {
        progress(.checking)
        do { try ClaudeConfig.checkShape(paths.liveConfig) } catch { step("add aborted: \(error)"); throw error }
        let current = currentAccount()
        progress(.syncingChats)
        step("sync: start")
        let w = await sync.run(arguments: [], timeout: syncTimeout)
        step(w.map { "sync: failed (\($0))" } ?? "sync: done")
        if Task.isCancelled { step("add aborted: cancelled"); throw EngineError.cancelled }
        try await quitClaudeOrAbort(progress: progress)
        try await afterQuit("add") { () throws -> Void in
            let now = self.ticker.now()
            try self.assertClosed(self.claude)
            try FileOps.removeIfPresent(self.paths.liveConfigJournal)
            progress(.saving)
            let bid = self.store.newBackupID(now: now)
            try self.setInFlight(InFlight(kind: .add, backupID: bid, from: current, to: nil, step: "backup"))
            self.step("backup: start")
            _ = try self.store.makeBackup(id: bid, reason: "add account", from: current, to: nil, now: now)
            self.step("backup: \(bid)")
            if let current { _ = try self.saveDesktop(current, now: now) }
            progress(.restoring)
            self.setStep("remove live login")
            try self.assertClosed(self.claude)
            try FileOps.removeIfPresent(self.paths.liveCookies)
            // From here the live files are half-changed: any failure is a half-swap. No relaunch;
            // in-flight stays set for startup recovery and the panel's Restore Backup.
            do {
                try FileOps.removeIfPresent(self.paths.liveCookiesJournal)
                try self.assertClosed(self.claude)
                try self.rewriteConfig(self.paths.liveConfig, nil)
                try FileOps.removeIfPresent(self.paths.liveConfigJournal)
            } catch {
                self.step("add: restore failed after removing the live login: \(error); backup \(bid)")
                throw EngineError.restoreFailed(backupID: bid)
            }
            try self.store.updateState {
                $0.pendingAddLabel = label
                $0.pendingAddFrom = current
                $0.pendingAddReauth = reauth
                $0.inFlight = nil
            }
            self.store.log("add account: live login removed locally; waiting for sign-in")
            if plan != .skip {
                try self.store.updateState {
                    $0.pendingChrome = .seed
                    $0.chromeSignInFor = nil
                }
                if await self.quitter.isRunning(self.chromeApp) == false {
                    _ = try? await self.applyPendingChrome(reopen: true)
                } else if plan == .restartNow {
                    _ = await self.restartChromeApplyingPending(target: nil, progress: progress)
                }
            }
            progress(.opening)
            self.step("relaunch: Claude")
            try await self.controller.open(appAt: self.claude.appURL)
            self.scheduleBrowserPaneLog()
            self.step("add: Claude reopened at sign-in; done")
            progress(.waitingForSignIn)
        }
    }

    /// Registers the newly signed-in account once the live Cookies holds a login again. Safe to
    /// poll. A sign-in that lands on an account already saved here is reported, never relabelled,
    /// and the add stays pending (unless it was a "Sign in again" for that very account).
    @discardableResult
    public func completeAdd() throws -> AddResult {
        let st = store.state()
        guard let label = st.pendingAddLabel, let uuid = currentAccount() else { return .waiting }
        // Claude writes lastKnownAccountUuid at its login-state transition, which only follows a
        // successful sign-in. A changed uuid is enough; the cookie row reaches disk up to ~30 s later
        // (Chromium flushes in batches) and is only needed where a login is saved, after the quit.
        let changed = uuid != st.pendingAddFrom
        // Unchanged uuid (signing back in to the same account): the add removed the live cookie, so
        // a session row on disk is the evidence of a sign-in.
        guard changed || CookieDB.hasClaudeLogin(paths.liveCookies) else { return .waiting }
        let known = store.account(uuid)
        if let known, st.pendingAddReauth != uuid {
            return .signedInAsKnown(known)
        }
        if known == nil, changed == false {
            // The previous account had no saved entry; still not a new account.
            let a = try store.register(uuid, label: nil, now: ticker.now())
            return .signedInAsKnown(a)
        }
        let account = try known ?? store.register(uuid, label: label, now: ticker.now())
        try store.updateState {
            $0.pendingAddLabel = nil
            $0.pendingAddFrom = nil
            $0.pendingAddReauth = nil
            if $0.pendingChrome == .seed || $0.pendingChrome == .saveSignedIn { $0.chromeSignInFor = uuid }
        }
        try store.updateAccounts { list in
            if let i = list.firstIndex(where: { $0.id == uuid }) { list[i].lastUsedAt = ticker.now() }
        }
        step("add account: registered \(uuid)")
        store.writeSyncLabels()
        return .added(store.account(uuid) ?? account)
    }

    public func cancelPendingAdd() throws {
        try store.updateState {
            $0.pendingAddLabel = nil
            $0.pendingAddFrom = nil
            $0.pendingAddReauth = nil
        }
    }

    /// First run, or after an outside change: registers the live account if it's new.
    /// Writes only the app's own store. Returns the account if it was just registered.
    @discardableResult
    public func registerCurrentIfNeeded() throws -> Account? {
        let st = store.state()
        guard st.pendingAddLabel == nil, st.inFlight == nil else { return nil }
        guard let uuid = currentAccount(), store.account(uuid) == nil, CookieDB.hasClaudeLogin(paths.liveCookies) else { return nil }
        let a = try store.register(uuid, label: nil, now: ticker.now())
        store.log("registered current account \(uuid)")
        return a
    }

    // MARK: Chrome

    /// The user's own statement of which account Chrome is signed in as (the panel offers the current
    /// desktop account when Chrome's account is unknown). Never inferred from the extension.
    public func attestChromeAccount(_ id: String) throws {
        guard store.account(id) != nil else { throw EngineError.unknownAccount(id) }
        try store.updateState { $0.chromeAccount = id }
        store.log("chrome account set to \(id) by the user")
    }

    /// The account Chrome is signed in as, as far as the app can attest: the last one it restored
    /// (or the one being added). The extension reader is advisory only: when it names a different
    /// account, nothing is attributed. Returns the id to save as, or a warning.
    func outgoingChromeAccount() -> (id: String?, warning: String?) {
        guard let recorded = store.state().chromeAccount else {
            return (nil, "Chrome's current claude.ai login isn't attributed to an account, so it wasn't saved (it's in the backup).")
        }
        if let seen = ExtensionSettings.accountUuid(in: paths.chromeExtensionSettings), seen != recorded {
            return (nil, "Claude in Chrome reports a different account than expected, so Chrome's login wasn't saved (it's in the backup).")
        }
        return (recorded, nil)
    }

    /// What to do with the outgoing Chrome login before replacing it.
    enum OutgoingChrome: Equatable {
        /// Save it as this account's slot, then swap.
        case save(String)
        /// Nothing to lose (no claude.ai login, or it's already the target's): swap.
        case proceed
        /// Can't attribute or save it: leave Chrome untouched.
        case keep(label: String?)
    }

    /// Resolves a pending "sign in to Claude in Chrome": once the advisory reader reports the target,
    /// Chrome is attributed to it; if it reports a different known account, to that one instead.
    /// Returns that other account's id when it differs from the one awaited.
    @discardableResult
    public func resolveChromeAttribution() -> String? {
        let st = store.state()
        guard let awaiting = st.chromeAwaitingSignIn, st.chromeAccount == nil,
              let seen = ExtensionSettings.accountUuid(in: paths.chromeExtensionSettings),
              store.account(seen) != nil else { return nil }
        try? store.updateState {
            $0.chromeAccount = seen
            $0.chromeAwaitingSignIn = nil
        }
        step("chrome: attributed to \(seen) (extension reports it)")
        return seen == awaiting ? nil : seen
    }

    func label(_ id: String?) -> String? { id.flatMap { store.account($0)?.shortLabel } }

    func outgoingChromeDecision(target: String?) -> OutgoingChrome {
        resolveChromeAttribution()
        guard CookieDB.hasClaudeLogin(paths.chromeCookies) else { return .proceed }
        let seen = ExtensionSettings.accountUuid(in: paths.chromeExtensionSettings)
        guard let recorded = store.state().chromeAccount else { return .keep(label: label(seen)) }
        if let seen, seen != recorded { return .keep(label: label(seen) ?? label(recorded)) }
        if recorded == target { return .proceed }
        guard store.account(recorded) != nil else { return .keep(label: label(seen)) }
        return .save(recorded)
    }

    /// Saves the outgoing login, or says to keep Chrome as is. Never clears a login it didn't save.
    func prepareOutgoingChrome(target: String?) -> OutgoingChrome {
        let decision = outgoingChromeDecision(target: target)
        switch decision {
        case .proceed:
            return .proceed
        case .keep(let l):
            step("chrome: outgoing login can't be attributed; Chrome kept on \(l ?? "its current account")")
            return decision
        case .save(let id):
            do {
                try saveChrome(as: id)
                step("chrome: saved slot \(id)")
                return decision
            } catch EngineError.noChromeLogin {
                return .proceed
            } catch {
                step("chrome: saving \(id) failed (\(error)); Chrome kept")
                return .keep(label: label(id))
            }
        }
    }

    /// Back-compat for the deferred `.seed` path: saves if attributable, otherwise leaves it.
    func saveOutgoingChrome(except target: String?) throws {
        if case .keep = prepareOutgoingChrome(target: target) { throw EngineError.chromeKept }
    }

    /// Swaps Chrome's claude.ai rows and the extension settings to `target`. Chrome must be closed;
    /// it is re-checked before every write.
    func swapChromeNow(to target: String, backupID: String?) async -> ChromeOutcome {
        guard FileOps.exists(paths.slotChromeCookies(target)) else { return .notSetUp }
        guard quitter.journalsSettled(chromeApp) else { return .failed("Chrome's cookie journal isn't empty") }
        do { try assertClosed(chromeApp) } catch { return .failed("\(error)") }
        if case .keep(let l) = prepareOutgoingChrome(target: target) {
            notice(PanelCopy.chromeKept(l))
            return .kept(label: l)
        }
        let prior = store.state().chromeAccount
        var wrote = false
        do {
            try assertClosed(chromeApp)
            let cb = try store.makeChromeBackup(reason: "chrome", chromeAccount: store.state().chromeAccount, now: ticker.now())
            if let backupID { try store.link(chromeBackup: cb.id, toBackup: backupID) }
            // Unknown while files move: a retry after a partial swap must not attribute T's rows to anyone.
            try store.updateState { $0.chromeAccount = nil }
            try restoreChrome(target, wrote: &wrote)
            try store.updateState {
                $0.chromeAccount = target
                if $0.pendingChrome == .slot(target) { $0.pendingChrome = nil }
            }
            store.log("chrome switched to \(target)")
            return .switched(confirmed: false)
        } catch EngineError.chromeSchemaChanged {
            if wrote == false { try? store.updateState { $0.chromeAccount = prior } }
            notice(EngineError.chromeSchemaChanged.description)
            return .failed(EngineError.chromeSchemaChanged.description)
        } catch {
            // Nothing written: Chrome still holds `prior`'s login.
            if wrote == false { try? store.updateState { $0.chromeAccount = prior } }
            store.log("chrome swap failed: \(error)")
            notice("Chrome didn't switch: \(error). It will retry when Chrome next quits.")
            return .failed("\(error)")
        }
    }

    /// Saves the live Chrome claude.ai rows and extension settings as `id`'s Chrome slot, keeping
    /// the previous slot as `.prev`. Refuses when Chrome holds no claude.ai login.
    func saveChrome(as id: String) throws {
        guard FileOps.exists(paths.chromeCookies) else { throw EngineError.missing("Chrome Cookies") }
        guard CookieDB.hasClaudeLogin(paths.chromeCookies) else { throw EngineError.noChromeLogin }
        try assertClosed(chromeApp)
        let slot = paths.slotChromeCookies(id)
        let hosts = try CookieDB.familyHosts(paths.chromeCookies)
        try FileOps.ensureDirectory(slot.deletingLastPathComponent())
        try store.keepPrevious(slot)
        try store.keepPrevious(paths.slotChromeExtension(id))
        try CookieDB.exportFamilyRows(from: paths.chromeCookies, to: slot)
        if FileOps.isDirectory(paths.chromeExtensionSettings) {
            try FileOps.replaceDirectory(paths.slotChromeExtension(id), withCopyOf: paths.chromeExtensionSettings, privateMode: true)
        } else {
            try FileOps.removeDirectory(paths.slotChromeExtension(id))
        }
        let ext = ExtensionSettings.accountUuid(in: paths.slotChromeExtension(id))
        let expiry = CookieDB.sessionExpiry(slot)
        let schema = CookieDB.schemaVersion(slot)
        let now = ticker.now()
        try store.updateAccounts { list in
            if let i = list.firstIndex(where: { $0.id == id }) {
                list[i].chrome = ChromeSlot(savedAt: now, cookieExpiresAt: expiry, extensionAccountUuid: ext, hosts: hosts,
                                            schemaVersion: schema.version, lastCompatibleVersion: schema.lastCompatible)
            }
        }
        store.log("saved chrome slot \(id)")
    }

    func restoreChrome(_ id: String, wrote: inout Bool) throws {
        let staged = try CookieDB.stageImport(from: paths.slotChromeCookies(id), into: paths.chromeCookies)
        let ext = paths.slotChromeExtension(id)
        try commitChrome(stagedCookies: staged, extensionSource: FileOps.isDirectory(ext) ? ext : nil)
        wrote = true
    }

    /// Puts staged Chrome cookies and the extension folder in place as one unit. The folder is
    /// staged beside the profile first; Chrome is re-checked; then both renames happen. If the
    /// folder rename fails, the cookie rename is undone. `extensionSource` nil removes the folder.
    func commitChrome(stagedCookies: URL, extensionSource: URL?) throws {
        let fm = FileManager.default
        let liveExt = paths.chromeExtensionSettings
        let stageRoot = paths.chromeProfile
        let stagedExt = stageRoot.appending(path: ".ca-ext-staged-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let asideExt = stageRoot.appending(path: ".ca-ext-aside-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let undoCookies = FileOps.tempSibling(of: paths.chromeCookies)
        defer {
            try? fm.removeItem(at: stagedCookies)
            try? fm.removeItem(at: stagedExt)
            try? fm.removeItem(at: undoCookies)
        }
        if let extensionSource {
            try fm.copyItem(at: extensionSource, to: stagedExt)
        }
        try fm.copyItem(at: paths.chromeCookies, to: undoCookies)
        try assertClosed(chromeApp)
        try FileOps.replace(paths.chromeCookies, with: stagedCookies)
        do {
            if FileOps.exists(liveExt) { try fm.moveItem(at: liveExt, to: asideExt) }
            if extensionSource != nil {
                try fm.createDirectory(at: liveExt.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: stagedExt, to: liveExt)
            }
        } catch {
            if FileOps.exists(asideExt), FileOps.exists(liveExt) == false { try? fm.moveItem(at: asideExt, to: liveExt) }
            try? FileOps.replace(paths.chromeCookies, with: undoCookies)
            store.log("chrome commit undone: \(error)")
            throw error
        }
        try? fm.removeItem(at: asideExt)
    }

    func restoreChromeFiles(fromBackup id: String) throws {
        let dir = store.chromeBackupDir(id)
        let rows = dir.appending(path: "claude-cookies.sqlite")
        guard store.chromeManifest(id) != nil, FileOps.exists(rows) else { throw EngineError.missing("Chrome backup \(id)") }
        let staged = try CookieDB.stageImport(from: rows, into: paths.chromeCookies)
        let ext = dir.appending(path: "extension-settings", directoryHint: .isDirectory)
        try commitChrome(stagedCookies: staged, extensionSource: FileOps.isDirectory(ext) ? ext : nil)
        store.log("restored chrome from backup \(id)")
    }

    func restoreChromeBackup(_ id: String) async -> ChromeOutcome {
        do {
            try store.updateState { $0.chromeAccount = nil }
            try restoreChromeFiles(fromBackup: id)
            try store.updateState {
                $0.chromeAccount = self.store.chromeManifest(id)?.chromeAccount
                if $0.pendingChrome == .backup(id) { $0.pendingChrome = nil }
            }
            return .switched(confirmed: false)
        } catch {
            try? store.updateState { $0.pendingChrome = .backup(id) }
            notice(error as? EngineError == .chromeSchemaChanged ? EngineError.chromeSchemaChanged.description
                   : "Chrome's login wasn't rolled back: \(error). It will retry when Chrome next quits.")
            return .failed("\(error)")
        }
    }

    func handleRunningChrome(target: String, plan: ChromePlan,
                             progress: @escaping @Sendable (SwitchPhase) -> Void) async -> ChromeOutcome {
        guard FileOps.exists(paths.slotChromeCookies(target)) else { return .notSetUp }
        switch plan {
        case .skip, .ifClosed, .withClaude:
            return .notRequested
        case .whenNextQuits:
            try? store.updateState { $0.pendingChrome = .slot(target) }
            store.log("chrome swap to \(target) deferred until Chrome quits")
            return .deferred
        case .restartNow:
            try? store.updateState { $0.pendingChrome = .slot(target) }
            return await restartChromeApplyingPending(target: target, progress: progress)
        }
    }

    /// The panel's secondary "Restart Chrome now": quit Chrome politely, apply the pending swap,
    /// reopen it. Never force-quits; if Chrome won't quit, the swap stays pending.
    public func restartChromeNow(progress: @escaping @Sendable (SwitchPhase) -> Void = { _ in }) async -> ChromeOutcome {
        guard let pending = store.state().pendingChrome else { return .notRequested }
        var target: String?
        if case .slot(let t) = pending { target = t }
        return await restartChromeApplyingPending(target: target, progress: progress)
    }

    /// Quits Chrome politely, applies the pending change, reopens it, and looks for evidence the
    /// extension signed in as `target`. If Chrome won't quit, the change stays pending.
    func restartChromeApplyingPending(target: String?, progress: @escaping @Sendable (SwitchPhase) -> Void) async -> ChromeOutcome {
        progress(.quittingChrome)
        do {
            try await quitter.quitAndWait(chromeApp) { ev in
                if ev == .appIsAsking { progress(.chromeAsking) }
            }
        } catch {
            store.log("Chrome didn't quit (\(error)); swap stays pending")
            return .deferred
        }
        progress(.restoringChrome)
        let result: ChromeOutcome
        do {
            result = try await applyPendingChrome(reopen: false)
        } catch {
            result = .failed("\(error)")
        }
        progress(.openingChrome)
        let reopened = ticker.now()
        try? await controller.open(appAt: chromeApp.appURL)
        if case .switched = result, let target {
            return .switched(confirmed: await confirmChrome(target: target, reopenedAt: reopened))
        }
        return result
    }

    /// Applies `state.pendingChrome` now that Chrome is closed. The app calls this within a second
    /// of Chrome exiting; the CLI calls it on demand. On failure the change stays pending and the
    /// problem is left in `state.chromeNotice`.
    @discardableResult
    public func applyPendingChrome(reopen: Bool = false) async throws -> ChromeOutcome {
        guard let pending = store.state().pendingChrome else { return .notRequested }
        if await quitter.isRunning(chromeApp) { throw EngineError.chromeNotClosed }
        let settleStart = ticker.now()
        while quitter.journalsSettled(chromeApp) == false {
            if ticker.now().timeIntervalSince(settleStart) > 20 { throw EngineError.notClean("Chrome") }
            try? await ticker.sleep(seconds: 0.25)
        }
        var outcome = ChromeOutcome.notRequested
        switch pending {
        case .slot(let target):
            outcome = await swapChromeNow(to: target, backupID: nil)
            if case .switched = outcome {} else if outcome == .notSetUp {
                try store.updateState { $0.pendingChrome = nil }
            }
        case .seedTarget(let target):
            do {
                outcome = try seedChrome(for: target, backupID: nil)
                try store.updateState { $0.pendingChrome = nil }
            } catch {
                notice("Chrome wasn't cleared for sign-in: \(error). It will retry when Chrome next quits.")
                throw error
            }
        case .seed:
            do {
                try assertClosed(chromeApp)
                _ = try store.makeChromeBackup(reason: "chrome seed", chromeAccount: store.state().chromeAccount, now: ticker.now())
                try saveOutgoingChrome(except: nil)
                let staged = try CookieDB.stageRemove(paths.chromeCookies)
                try store.updateState { $0.chromeAccount = nil }
                try commitChrome(stagedCookies: staged, extensionSource: nil)
                try store.updateState { $0.pendingChrome = .saveSignedIn }
                store.log("chrome cleared for sign-in")
                outcome = .switched(confirmed: false)
            } catch {
                notice("Chrome wasn't cleared for sign-in: \(error). It will retry when Chrome next quits.")
                throw error
            }
        case .saveSignedIn:
            guard let id = store.state().chromeSignInFor else {
                store.log("chrome: the added account isn't registered yet; will save at next quit")
                return .deferred
            }
            if let seen = ExtensionSettings.accountUuid(in: paths.chromeExtensionSettings), seen != id {
                notice("Claude in Chrome reports a different account than the one just added, so Chrome's login wasn't saved.")
                try store.updateState {
                    $0.pendingChrome = nil
                    $0.chromeSignInFor = nil
                }
                return .failed("extension account mismatch")
            }
            guard CookieDB.hasClaudeLogin(paths.chromeCookies) else {
                store.log("chrome: no claude.ai login yet; will retry at next quit")
                return .deferred
            }
            try saveChrome(as: id)
            try store.updateState {
                $0.pendingChrome = nil
                $0.chromeSignInFor = nil
                $0.chromeAccount = id
            }
            outcome = .switched(confirmed: false)
        case .backup(let id):
            outcome = store.chromeManifest(id) == nil ? .failed("backup \(id) is gone") : await restoreChromeBackup(id)
            if store.chromeManifest(id) == nil { try store.updateState { $0.pendingChrome = nil } }
        }
        if reopen { try await controller.open(appAt: chromeApp.appURL) }
        return outcome
    }

    /// Evidence that the extension signed in after Chrome reopened: its storage was written after
    /// `reopenedAt` and it reports `target`. Without both, the switch stays unconfirmed.
    public func confirmChrome(target: String, reopenedAt: Date) async -> Bool {
        let start = ticker.now()
        while ticker.now().timeIntervalSince(start) < chromeVerifyTimeout {
            if let w = ExtensionSettings.lastWrite(in: paths.chromeExtensionSettings), w > reopenedAt,
               ExtensionSettings.accountUuid(in: paths.chromeExtensionSettings) == target {
                return true
            }
            try? await ticker.sleep(seconds: 1)
        }
        return false
    }
}

/// Starts Chrome's quit at most once, from whichever event comes first.
final class ChromeQuitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Bool, Never>?
    var task: Task<Bool, Never>? { lock.withLock { _task } }
    func startOnce(_ make: () -> Task<Bool, Never>) {
        lock.withLock { if _task == nil { _task = make() } }
    }
}
