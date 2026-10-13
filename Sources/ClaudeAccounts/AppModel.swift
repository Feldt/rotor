import AppKit
import ClaudeAccountsCore
import Observation
import SwiftUI

/// A switch, rollback or add in progress.
struct Activity: Equatable {
    var accountID: String
    var phase: SwitchPhase
}

/// An extra-window action in progress (open, close, reopen after an update, or a window's first sign-in).
enum WindowOp: Equatable {
    case opening(String)
    case closing(String)
    /// Windows that quit to install an update are coming back (the first one's account).
    case reopening(String)
    case signingIn(String, FirstSignInPhase)

    var accountID: String {
        switch self {
        case .opening(let id), .closing(let id), .reopening(let id), .signingIn(let id, _): id
        }
    }
}

/// One extra window as the panel shows it.
struct WindowInfo: Equatable, Sendable {
    var accountID: String
    var signedIn: Bool
    var isOpen: Bool
    /// The window's own process, used only to bring it to the front.
    var pid: Int32?
}

/// The single compact line under the list: a few words and at most one action.
enum StatusLine: Equatable {
    case notConfirmed(backupID: String)
    case failed(backupID: String)
    case interrupted(backupID: String, detail: String)
    case signedInAsKnown(label: String)
    case waitingForSignIn
    case chrome(detail: String)
    case chromePending
    case confirmRestartChrome
    case chromeSignIn
    case chromeTabsWarning(target: String)
    /// A short title (≤ 30 chars) with the full detail for the tooltip. Stays until dismissed.
    case error(title: String, detail: String)
    /// Informational; dismisses itself after 8 s.
    case info(String)
    case keychainDenied
    /// "To sign this window in, your main Claude window closes for about a minute." with Continue.
    case confirmWindowSignIn(accountID: String)

    var isConfirmation: Bool {
        switch self {
        case .confirmWindowSignIn: true
        default: false
        }
    }

    var isProblem: Bool {
        switch self {
        case .notConfirmed, .failed, .interrupted, .chrome, .error, .keychainDenied: true
        default: false
        }
    }
}

@MainActor @Observable
final class AppModel {
    /// Debug timing for the open path (CLAUDE_ACCOUNTS_DEBUG_TIMING=1 logs it).
    enum OpenTiming {
        nonisolated(unsafe) static var requestedAt: CFAbsoluteTime?
        nonisolated(unsafe) static var mainThreadWork: CFAbsoluteTime = 0
    }

    let engine: SwitchEngine
    let windowEngine: WindowEngine
    let firstSignIn: FirstSignIn
    var store: AccountStore { engine.store }
    /// The extra windows the engine knows (open or waiting for their sign-in), by account id.
    var windows: [String: WindowInfo] = [:]
    var windowOp: WindowOp?
    /// Screenshot state only (dry-run controller): windows shown as open without any process.
    private var demoWindows: [String: WindowInfo] = [:]

    var accounts: [Account] = []
    var currentID: String?
    var liveExpiry: Date?
    var syncHealth = SyncHealth.ok
    var state = StoreState()
    var activity: Activity?
    var line: StatusLine? {
        didSet {
            guard case .info(let text) = line else { return }
            Task {
                try? await Task.sleep(for: .seconds(8))
                if case .info(let now) = self.line, now == text { self.line = nil }
            }
        }
    }
    /// The inline "+ Name" row before Return (pure UI; cancelling writes nothing).
    var addDraft = AddDraft()
    var isOpenAtLogin = LoginItem.isEnabled
    /// The one expanded row (usage and the Switch button), if any.
    var expandedID: String?
    var usage: [String: AccountUsage] = [:]
    @ObservationIgnored let usageProvider: UsageProvider
    var now = Date()

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var addTimer: Timer?
    @ObservationIgnored private var configWatch: DispatchSourceFileSystemObject?
    private var isApplyingChrome = false
    @ObservationIgnored private var usageTimer: Timer?
    @ObservationIgnored private var sleepObservers: [Any] = []
    @ObservationIgnored private var isAsleep = false

    var showUsage: Bool { state.showUsage ?? true }
    var keychainDenied = false
    @ObservationIgnored lazy var updater = UpdateController(storeRoot: engine.paths.storeRoot)

    /// Why Update can't run now, or nil.
    var updateBlockReason: String? {
        Updater.blockReason(isSwitching: isSwitching && activity?.accountID != "chrome" && activity?.accountID != "add",
                            isAdding: activity?.accountID == "add",
                            isChromeSwapping: activity?.accountID == "chrome" || isApplyingChromeNow,
                            hasInFlight: state.inFlight != nil)
    }
    var isApplyingChromeNow: Bool { isApplyingChrome }

    init(engine: SwitchEngine, usageProvider: UsageProvider = NoUsageProvider(), windowEngine: WindowEngine? = nil) {
        self.engine = engine
        // Switch and window actions share one gate, so only one of them runs at a time.
        let windowEngine = windowEngine ?? WindowEngine.system(paths: engine.paths, gate: engine.gate)
        self.windowEngine = windowEngine
        self.firstSignIn = FirstSignIn(windows: windowEngine)
        self.usageProvider = usageProvider
        refreshNow()
        if (try? engine.registerCurrentIfNeeded()) != nil { refreshNow() }
        if state.pendingAddLabel != nil {
            line = .waitingForSignIn
            watchForSignIn()
        }
        if state.inFlight != nil {
            Task {
                if let message = await engine.recoverInterrupted() {
                    self.refresh()
                    if let f = self.state.inFlight {
                        self.line = .interrupted(backupID: f.backupID, detail: message)
                    } else {
                        self.line = .info(message.count <= PanelCopy.budget ? message : "Interrupted switch undone")
                    }
                }
            }
        }
        if state.pendingWindowSignIn != nil {
            // A window's first sign-in was cut short (quit or crash): put the main window back.
            Task {
                if let note = await self.firstSignIn.recoverIfInterrupted() {
                    self.refresh()
                    let title = PanelCopy.interruptedSignIn(note: note)
                    self.line = title == PanelCopy.openClaudeYourself ? .error(title: title, detail: note) : .info(title)
                }
            }
        }
        // Pending Chrome changes are applied on a Chrome quit event only, never on a timer.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Paths.chromeBundleID else { return }
            MainActor.assumeIsolated { self?.chromeQuit() }
        }
        applyDemoState()
    }

    // MARK: Derived

    var current: Account? { accounts.first { $0.id == currentID } }
    /// True while a switch, add, rollback or window action runs (rows dim, Quit waits, the glyph spins).
    var isSwitching: Bool { (activity != nil && activity?.phase != .done) || windowOp != nil }
    /// The account the running action is about, if any.
    var activeAccountID: String? { windowOp?.accountID ?? activity?.accountID }
    var parallelEnabled: Bool { state.parallelWindowsEnabled == true }
    var openWindowCount: Int { windows.values.filter(\.isOpen).count }

    /// What an account's row shows right now: its buttons (only while expanded), checkmark, window
    /// icon and subtitle. The rules live in Core, where they are tested.
    func rowPlan(for a: Account, expanded: Bool? = nil) -> RowPlan {
        RowPlan(for: RowFacts(isParallelOn: parallelEnabled, isMain: a.id == currentID,
                              hasOwnWindow: windows[a.id]?.isOpen == true, isExpanded: expanded ?? (expandedID == a.id),
                              isBeingNamed: a.needsLabel == true, isActive: activeAccountID == a.id,
                              isSwitching: isSwitching))
    }

    var chromePending: Bool {
        switch state.pendingChrome {
        case .slot, .seedTarget: return true
        default: return false
        }
    }
    var chromeRestoresTabs = true
    var chromeExtensionAccount: String?
    /// The guess for "Chrome is signed in as" on first enable.
    var chromeGuess: String?
    var chromePlan: ChromePlan { ChromeFollow.plan(state) }

    /// A short "2h ago" for the 5h line when the current cache for `id` is stale, else nil.
    func staleAge(_ id: String) -> String? {
        guard let s = (usageProvider as? UsageService)?.stored(id), s.stale else { return nil }
        let secs = max(0, now.timeIntervalSince(s.fetchedAt))
        if secs < 90 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86_400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86_400))d ago"
    }

    func health(_ a: Account) -> LoginHealth {
        LoginHealth.of(a.id == currentID ? (liveExpiry ?? a.desktop?.cookieExpiresAt) : a.desktop?.cookieExpiresAt, now: now)
    }

    /// The menu bar dot: an expiring or expired login, broken chat sync, or a failed switch.
    var needsAttention: Bool {
        if syncHealth != .ok { return true }
        if line?.isProblem == true { return true }
        // Usage: only the current account at >= 95 % on the 5-hour window.
        if let id = currentID, let five = usage[id]?.fiveHour, five.utilization >= 0.95 { return true }
        return accounts.contains { a in
            switch health(a) {
            case .expiringSoon, .expired: true
            default: false
            }
        }
    }

    // MARK: Refresh (on panel open and after actions; no ticking timers)

    /// Everything the panel shows, read off the main thread.
    struct Snapshot: Sendable {
        var accounts: [Account]
        var state: StoreState
        var currentID: String?
        var liveExpiry: Date?
        var syncHealth: SyncHealth
        var usage: [String: AccountUsage]
        var chromeRestoresTabs: Bool
        var chromeExtensionAccount: String?
        var windows: [String: WindowInfo] = [:]
        /// Windows the registry thought were open whose process is gone (closed by hand or by an update).
        var vanishedWindows: [String] = []
    }

    nonisolated static func readSnapshot(engine: SwitchEngine, windowEngine: WindowEngine, provider: UsageProvider,
                                         showUsage: Bool) async -> Snapshot {
        let store = engine.store
        let now = Date()
        let accounts = store.accounts()
        let state = store.state()
        let claudeRunning = engine.quitter.requiredProcesses(engine.claude).isEmpty == false
        let health = SyncHealth.check(status: SyncStatus.read(engine.paths.syncLog),
                                      agentLoaded: SyncHealth.isAgentLoaded(), claudeRunning: claudeRunning,
                                      lastSyncFailed: state.lastSyncFailed == true, now: now)
        var usage: [String: AccountUsage] = [:]
        if state.showUsage ?? true, showUsage {
            for a in accounts { if let u = await provider.usage(for: a.id) { usage[a.id] = u } }
        }
        let follows = state.chromeFollows
        // Windows are read only when the feature is on or a window is already known, so a Mac that never
        // turns it on never looks at its process list for this.
        var windows: [String: WindowInfo] = [:]
        var vanished: [String] = []
        if state.parallelWindowsEnabled == true || windowEngine.registry().windows.isEmpty == false {
            vanished = windowEngine.reconcile().vanished
            for r in windowEngine.registry().windows {
                windows[r.accountId] = WindowInfo(accountID: r.accountId, signedIn: r.signedIn, isOpen: r.pid != nil, pid: r.pid)
            }
        }
        return Snapshot(accounts: accounts, state: state, currentID: engine.currentAccount(),
                        liveExpiry: engine.liveCookieExpiry(), syncHealth: health, usage: usage,
                        chromeRestoresTabs: follows ? ChromePreferences.restoresTabs(engine.paths.chromePreferences) : true,
                        chromeExtensionAccount: follows ? ExtensionSettings.accountUuid(in: engine.paths.chromeExtensionSettings) : nil,
                        windows: windows, vanishedWindows: vanished)
    }

    func apply(_ snap: Snapshot) {
        now = Date()
        if snap.accounts != accounts { accounts = snap.accounts }
        if snap.state != state { state = snap.state }
        if snap.currentID != currentID {
            let previous = currentID
            currentID = snap.currentID
            // A switch or add just changed accounts: the new one gets a fresh token from Claude and
            // the old one a freshly saved slot. Check both soon instead of waiting out any backoff.
            if previous != nil { retryUsageSoon([snap.currentID, previous].compactMap { $0 }) }
        }
        if snap.liveExpiry != liveExpiry { liveExpiry = snap.liveExpiry }
        if snap.syncHealth != syncHealth { syncHealth = snap.syncHealth }
        chromeRestoresTabs = snap.chromeRestoresTabs
        chromeExtensionAccount = snap.chromeExtensionAccount
        let shown = snap.windows.merging(demoWindows) { _, demo in demo }
        if shown != windows { windows = shown }
        if snap.vanishedWindows.isEmpty == false, windowOp == nil, line == nil { line = .info(PanelCopy.windowClosed) }
        // Once the extension reports an account after a sign-in, attribute Chrome to it (the target,
        // or tell the user if it's a different known account).
        if state.chromeAwaitingSignIn != nil, snap.chromeExtensionAccount != nil {
            let other = engine.resolveChromeAttribution()
            state = store.state()
            if line == .chromeSignIn, state.chromeAwaitingSignIn == nil { line = nil }
            if let other {
                line = .info(PanelCopy.chromeSignedInAs(accounts.first { $0.id == other }?.shortLabel))
            }
        }
        if snap.usage != usage {
            // New numbers cross-fade in; cached ones were already on screen.
            withAnimation(.easeOut(duration: 0.2)) { usage = snap.usage }
        }
        if line == nil, let n = state.chromeNotice { line = .chrome(detail: n) }
        if line == nil, chromePending { line = .chromePending }
        if line == nil, state.chromeAwaitingSignIn != nil { line = .chromeSignIn }
        if line == .chromeSignIn, state.chromeAwaitingSignIn == nil { line = nil }
        if line == .chromePending, chromePending == false { line = nil }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Re-reads files, sqlite and the usage cache in the background, then applies the result. Never
    /// blocks the main thread; coalesces bursts.
    func refresh() {
        guard refreshTask == nil else { refreshPending = true; return }
        let engine = engine, windowEngine = windowEngine, provider = usageProvider, show = showUsage
        refreshTask = Task {
            let snap = await Task.detached(priority: .userInitiated) {
                await AppModel.readSnapshot(engine: engine, windowEngine: windowEngine, provider: provider, showUsage: show)
            }.value
            self.apply(snap)
            self.refreshTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }
    @ObservationIgnored private var refreshPending = false

    /// Synchronous file read, only at launch (before any panel is shown). No semaphores and no
    /// waiting on Swift tasks from the main thread; usage arrives with the first background refresh.
    func refreshNow() {
        accounts = store.accounts()
        state = store.state()
        currentID = engine.currentAccount()
        liveExpiry = engine.liveCookieExpiry()
        refresh()
    }

    /// Re-reads the cached usage records (no Keychain, no network) with the rest of the snapshot.
    private func refreshUsage() { refresh() }

    /// Background schedule: every 15 min one account at a time, plus a debounced panel-open
    /// refresh of data older than 5 min. Nothing runs while asleep or when Show Usage is off.
    func startUsageScheduler() {
        guard let service = usageProvider as? UsageService else { return }
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAsleep = true }
        })
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = false
                // Resume with jitter so several machines don't fetch at once.
                DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 5...45)) { self?.tickUsage() }
            }
        })
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickUsage()
                if let self, self.parallelEnabled, self.isSwitching == false {
                    self.refresh()
                    self.reopenWindowsAfterUpdate()
                }
            }
        }
        // Always try the current account once at launch (unless rate-limited), through the queue.
        if showUsage { service.queueLaunch(currentID, now: Date()) }
        tickUsage()
    }

    /// Attempts these accounts ahead of any backoff, after Claude has had time to mint a token
    /// (and once more a little later in case it was slow).
    private func retryUsageSoon(_ ids: [String]) {
        for delay in [20.0, 60.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.showUsage, let service = self.usageProvider as? UsageService else { return }
                for id in ids { service.queueLaunch(id, now: Date()) }
                self.tickUsage()
            }
        }
    }

    private func tickUsage() {
        guard showUsage, isAsleep == false, let service = usageProvider as? UsageService else { return }
        let ids = accounts.map(\.id)
        Task {
            guard let id = service.due(ids, now: Date()) else { return }
            _ = await service.refresh(id)
            self.refreshUsage()
            self.keychainDenied = (service.tokens as? KeychainTokenSource)?.isKeychainDenied ?? false
            if self.keychainDenied, self.line == nil { self.line = .keychainDenied }
            // Drain anything else due (e.g. a panel round) at the 5 s spacing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { self.tickUsage() }
        }
    }

    /// Panel open: queue a round (at most one per 5 min) through the same spaced queue.
    /// Panel open: renders what's in memory. The refresh and any usage round run in the background.
    func panelOpened() {
        let t0 = CFAbsoluteTimeGetCurrent()
        refresh()
        if showUsage, let service = usageProvider as? UsageService {
            let ids = accounts.map(\.id)
            Task.detached(priority: .utility) {
                if service.queuePanelRound(ids, now: Date()).isEmpty == false {
                    await MainActor.run { self.tickUsage() }
                }
            }
        }
        OpenTiming.mainThreadWork = CFAbsoluteTimeGetCurrent() - t0
    }

    /// The panel closed: collapse any open row so it reopens to the plain list, without animation.
    func panelClosed() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            expandedID = nil
            addDraft.panelClosed()
            // A question left open would be stale when the panel comes back.
            if line?.isConfirmation == true { line = nil }
        }
    }

    /// × or Escape on the "+ Name" row: nothing starts, nothing is written.
    func cancelAddDraft() { addDraft.cancel() }

    /// Return on the "+ Name" row starts the add (the × goes away with the row).
    func submitAdd() {
        guard let label = addDraft.submit() else { return }
        beginAdd(label: label)
    }

    var isPanelOpen = false

    /// Set by the host so a Switch can close the panel.
    @ObservationIgnored var closePanel: (() -> Void)?

    /// Settings → Retry Keychain Access (shown only after a denial).
    func retryKeychain() {
        guard let service = usageProvider as? UsageService,
              let source = service.tokens as? KeychainTokenSource else { return }
        source.retryKeychain()
        keychainDenied = false
        if line == .keychainDenied { line = nil }
        tickUsage()
    }

    /// Polls for the new account only while an Add is waiting for sign-in.
    /// Watches Claude's support folder (config.json is replaced by rename, so the directory changes)
    /// and checks at once; a 2 s poll stays as a fallback.
    private func watchForSignIn() {
        addTimer?.invalidate()
        addTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSignIn() }
        }
        configWatch?.cancel()
        let fd = open(engine.paths.claudeUserData.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkSignIn() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatch = src
        checkSignIn()
    }

    private func stopSignInWatch() {
        addTimer?.invalidate()
        configWatch?.cancel()
        configWatch = nil
    }

    private func checkSignIn() {
        guard store.state().pendingAddLabel != nil else { stopSignInWatch(); return }
        switch (try? engine.completeAdd()) ?? .waiting {
        case .waiting: break
        case .added(let a):
            stopSignInWatch()
            line = nil
            refresh()
            // Show its usage right away.
            if showUsage, let service = usageProvider as? UsageService {
                service.queueLaunch(a.id, now: Date())
                tickUsage()
            }
            // Claude mints the new account's token a few seconds after sign-in; try again then.
            retryUsageSoon([a.id])
        case .signedInAsKnown(let a):
            let next = StatusLine.signedInAsKnown(label: a.shortLabel)
            if line != next { line = next }
        }
    }

    func chromeQuit() {
        guard store.state().pendingChrome != nil, isApplyingChrome == false else { return }
        isApplyingChrome = true
        let engine = engine
        Task {
            try? await Task.sleep(for: .seconds(1))
            if await engine.quitter.isRunning(engine.chromeApp) == false {
                do {
                    _ = try await engine.applyPendingChrome()
                } catch {
                    self.line = .chrome(detail: "\(error)")
                }
            }
            self.isApplyingChrome = false
            self.line = self.line == .chromePending ? nil : self.line
            self.refresh()
        }
    }

    // MARK: Actions

    /// A click expands the row (usage, and Switch for other accounts); it never switches by itself.
    func tap(_ a: Account) {
        guard isSwitching == false, a.needsLabel != true else { return }
        expandedID = expandedID == a.id ? nil : a.id
    }

    /// Switch is offered only in an expanded row, which doubles as the confirmation.
    func confirmSwitch(_ a: Account) {
        guard isSwitching == false, a.id != currentID else { return }
        // The row shows its spinner this frame; the menu bar glyph carries the progress after that.
        closePanelSoon()
        if a.desktop == nil || health(a) == .expired {
            signInAgain(a)
            return
        }
        let chromeRunning = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.chromeBundleID).isEmpty == false
        if ChromeFollow.tabsWarning(plan: chromePlan, isChromeRunning: chromeRunning, restoresTabs: chromeRestoresTabs) {
            line = .chromeTabsWarning(target: a.id)
            return
        }
        startSwitch(a.id)
    }

    private func closePanelSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.closePanel?()
        }
    }

    func signInAgain(_ a: Account) {
        beginAdd(label: a.label, reauth: a.id)
    }

    func startSwitch(_ id: String) {
        line = nil
        activity = Activity(accountID: id, phase: .checking)
        let plan = chromePlan
        let engine = engine
        task = Task {
            do {
                let o = try await engine.switchTo(id, chrome: plan, progress: self.progressSink())
                self.finish()
                switch o.verdict {
                case .failure: self.line = .failed(backupID: o.backupID)
                case .pending: self.line = .notConfirmed(backupID: o.backupID)
                case .success: break
                }
                if self.line == nil, case .failed(let why) = o.chrome { self.line = .chrome(detail: why) }
                if self.line == nil, o.chrome == .deferred { self.line = .chromePending }
                if case .kept(let l) = o.chrome {
                    self.line = .error(title: PanelCopy.chromeKept(l), detail: "Chrome's current claude.ai login couldn't be saved, so it was left as is")
                    try? self.store.updateState { $0.chromeNotice = nil }
                }
            } catch EngineError.cancelled {
                self.activity = nil
                self.line = .info(PanelCopy.switchCancelled)
            } catch EngineError.claudeReopened {
                self.activity = nil
                self.line = .info(PanelCopy.claudeReopened)
            } catch EngineError.restoreFailed(let bid) {
                self.activity = nil
                self.line = .interrupted(backupID: bid, detail: EngineError.restoreFailed(backupID: bid).description)
            } catch {
                self.activity = nil
                self.line = .error(title: PanelCopy.title(for: error), detail: "\(error)")
            }
            self.refresh()
        }
    }

    func cancelSwitch() {
        if case .signingIn(_, let phase) = windowOp {
            switch phase {
            case .reopeningMain, .done, .rolledBack: return
            default: task?.cancel()
            }
            return
        }
        guard let a = activity, a.phase.isInterruptible else { return }
        task?.cancel()
    }

    /// Whether the status line's Cancel applies right now.
    var canCancelAction: Bool {
        if case .signingIn(_, let phase) = windowOp {
            switch phase {
            case .reopeningMain, .done, .rolledBack: return false
            default: return true
            }
        }
        return activity?.phase.isInterruptible == true
    }

    func rollback(_ backupID: String) {
        line = nil
        activity = Activity(accountID: store.manifest(backupID)?.fromAccount ?? "", phase: .checking)
        let engine = engine
        task = Task {
            do {
                let o = try await engine.rollback(backupID, progress: self.progressSink())
                self.finish()
                if o.verdict != .success { self.line = .notConfirmed(backupID: o.backupID) }
            } catch EngineError.cancelled {
                self.activity = nil
            } catch EngineError.rollbackFailed(let bid, let pre) {
                self.activity = nil
                self.line = .interrupted(backupID: pre, detail: EngineError.rollbackFailed(backupID: bid, preBackupID: pre).description)
            } catch {
                self.activity = nil
                self.line = .error(title: PanelCopy.title(for: error), detail: "\(error)")
            }
            self.refresh()
        }
    }

    func beginAdd(label: String, reauth: String? = nil) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false, isSwitching == false else { return }
        line = nil
        activity = Activity(accountID: reauth ?? "add", phase: .checking)
        let plan: ChromePlan = chromePlan == .skip ? .skip : .ifClosed
        let engine = engine
        task = Task {
            do {
                try await engine.beginAdd(label: trimmed, reauth: reauth, chrome: plan, progress: self.progressSink())
                self.activity = nil
                self.line = .waitingForSignIn
                self.watchForSignIn()
            } catch EngineError.restoreFailed(let bid) {
                self.activity = nil
                self.line = .interrupted(backupID: bid, detail: EngineError.restoreFailed(backupID: bid).description)
            } catch EngineError.cancelled {
                self.activity = nil
            } catch {
                self.activity = nil
                self.line = .error(title: PanelCopy.title(for: error), detail: "\(error)")
            }
            self.refresh()
        }
    }

    // MARK: Extra windows

    /// Opens the account in its own window. At the cap it says so instead; a window that was never
    /// signed in asks first, because its one sign-in closes the main window for about a minute.
    func openWindow(_ a: Account) {
        guard parallelEnabled, isSwitching == false, a.id != currentID, a.needsLabel != true,
              windows[a.id]?.isOpen != true else { return }
        if openWindowCount >= ParallelWindows.maxExtraWindows {
            line = .info(PanelCopy.capReached(ParallelWindows.maxExtraWindows))
            return
        }
        if windows[a.id]?.signedIn == true {
            line = nil
            runOpen(a.id)
        } else if openWindowCount > 0 {
            line = .info(PanelCopy.title(for: .closeOtherWindowsFirst))
        } else {
            line = nil
            askWindowSignIn(a.id)
        }
    }

    /// Windows that quit to install an update come back once the main window is on the new version. This is
    /// a window action like Open: the rows dim and the status line says so, and it starts only when nothing
    /// else is running. The engine's gate backs that up: it skips a reopen while any other action runs, and
    /// makes a click on Switch or Open wait for a reopen that is running.
    func reopenWindowsAfterUpdate() {
        guard parallelEnabled, isSwitching == false, isCheckingReopen == false,
              state.pendingAddLabel == nil, state.pendingWindowSignIn == nil else { return }
        isCheckingReopen = true
        let windowEngine = windowEngine
        Task {
            let ready = await Task.detached { windowEngine.windowsReadyToReopen() }.value
            self.isCheckingReopen = false
            // Something may have started while the check ran: look again before taking the floor.
            guard let first = ready.first, self.parallelEnabled, self.isSwitching == false else { return }
            self.windowOp = .reopening(first)
            self.task = Task {
                let results = await windowEngine.reopenAfterUpdate()
                self.windowOp = nil
                if results.contains(where: { if case .failed = $0.outcome { true } else { false } }) {
                    self.line = .info(PanelCopy.windowNotReopened)
                }
                self.refresh()
            }
        }
    }
    @ObservationIgnored private var isCheckingReopen = false

    /// Brings an account's own window to the front (the panel closes; nothing else changes).
    func showWindow(_ id: String) {
        guard let pid = windows[id]?.pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
        closePanelSoon()
    }

    private func runOpen(_ id: String) {
        windowOp = .opening(id)
        closePanelSoon()
        let windowEngine = windowEngine
        task = Task {
            do {
                let r = try await windowEngine.open(id)
                self.windowOp = nil
                if r.warnings.isEmpty == false { self.line = .info(PanelCopy.windowReadyCheckLog) }
            } catch WindowError.needsFirstSignIn {
                self.windowOp = nil
                self.askWindowSignIn(id)
            } catch WindowError.cancelled {
                self.windowOp = nil
            } catch {
                self.windowOp = nil
                self.line = .error(title: PanelCopy.title(for: error), detail: "\(error)")
            }
            self.refresh()
        }
    }

    /// Shows the first-sign-in confirmation.
    private func askWindowSignIn(_ id: String) {
        line = .confirmWindowSignIn(accountID: id)
    }

    /// Continue on the confirmation.
    func continueWindowSignIn(_ id: String) {
        guard isSwitching == false else { return }
        line = nil
        windowOp = .signingIn(id, .checking)
        closePanelSoon()
        let first = firstSignIn
        task = Task {
            do {
                let o = try await first.run(id) { phase in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { if self.windowOp != nil { self.windowOp = .signingIn(id, phase) } }
                    }
                }
                self.windowOp = nil
                self.line = .info(o.warnings.isEmpty ? PanelCopy.windowReady : PanelCopy.windowReadyCheckLog)
            } catch WindowError.cancelled {
                var text = PanelCopy.signInCancelled
                if case .signingIn(_, let phase) = self.windowOp, case .rolledBack = phase { text = PanelCopy.signInStep(phase) }
                self.windowOp = nil
                self.line = .info(text)
            } catch {
                self.windowOp = nil
                self.line = .error(title: PanelCopy.title(for: error), detail: "\(error)")
            }
            self.refresh()
        }
    }

    /// Closes one window (only that window's own process).
    func closeWindow(_ id: String) {
        guard isSwitching == false else { return }
        line = nil
        windowOp = .closing(id)
        let windowEngine = windowEngine
        task = Task {
            do {
                try await windowEngine.close(id)
                self.windowOp = nil
            } catch WindowError.cancelled {
                self.windowOp = nil
            } catch {
                self.windowOp = nil
                self.line = .error(title: PanelCopy.title(for: error), detail: "\(error)")
            }
            self.refresh()
        }
    }

    func setParallelWindows(_ on: Bool) {
        try? store.updateState { $0.parallelWindowsEnabled = on }
        refresh()
    }

    func cancelAdd() {
        try? engine.cancelPendingAdd()
        addTimer?.invalidate()
        line = nil
        refresh()
    }

    func setLabel(_ id: String, _ label: String) {
        let t = label.trimmingCharacters(in: .whitespaces)
        guard t.isEmpty == false else { return }
        try? store.setLabel(id, t)
        store.writeSyncLabels()
        refresh()
    }

    func restartChromeNow() {
        line = nil
        activity = Activity(accountID: "chrome", phase: .quittingChrome)
        let engine = engine
        task = Task {
            let r = await engine.restartChromeNow(progress: self.progressSink())
            self.finish()
            switch r {
            case .deferred: self.line = .chromePending
            case .failed(let why): self.line = .chrome(detail: why)
            default: break
            }
            self.refresh()
        }
    }

    func repairSync() {
        let engine = engine
        Task {
            if let r = await engine.sync.run(arguments: ["--reload"], timeout: 60) {
                self.line = .error(title: "Repair failed", detail: r)
            } else {
                try? engine.store.updateState { $0.lastSyncFailed = false }
            }
            self.refresh()
        }
    }

    func dismissLine() {
        if case .chrome = line { try? store.updateState { $0.chromeNotice = nil } }
        line = nil
        refresh()
    }

    func attestChrome(_ id: String) {
        try? engine.attestChromeAccount(id)
        refresh()
    }

    func setChromeFollows(_ on: Bool) {
        try? store.updateState { $0.chromeFollows = on }
        if on, state.chromeAttributionConfirmed != true { loadChromeGuess() }
        refresh()
    }

    func setChromeMode(_ mode: ChromeMode) {
        try? store.updateState { $0.chromeMode = mode }
        refresh()
    }

    /// First enable: confirm which account Chrome is signed in as. Until then Chrome never swaps.
    func confirmChromeAccount(_ id: String) {
        try? engine.attestChromeAccount(id)
        try? store.updateState { $0.chromeAttributionConfirmed = true }
        refresh()
    }

    /// The advisory guess, read off the main thread.
    func loadChromeGuess() {
        let paths = engine.paths, accounts = accounts
        Task {
            let g = await Task.detached { ChromeFollow.guess(paths: paths, accounts: accounts) }.value
            self.chromeGuess = g ?? self.currentID
        }
    }

    func setShowUsage(_ on: Bool) {
        try? store.updateState { $0.showUsage = on }
        refresh()
        if on { tickUsage() } else { usage = [:] }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            // The user's choice sticks from here on.
            try? store.updateState { $0.loginItemDefaulted = true }
        } catch {
            line = .error(title: "Open at login failed", detail: "\(error)")
        }
        isOpenAtLogin = LoginItem.isEnabled
    }

    func showBackups() {
        try? store.ensureLayout()
        NSWorkspace.shared.open(engine.paths.backupsDir)
    }

    private func finish() {
        verifyFailsafe?.invalidate()
        activity?.phase = .done
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if self.activity?.phase == .done {
                withAnimation(.spring(duration: 0.35, bounce: 0.1)) { self.activity = nil }
            }
        }
    }

    private func progressSink() -> @Sendable (SwitchPhase) -> Void {
        { phase in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.activity != nil { self.activity?.phase = phase }
                    if phase == .opening { self.armVerifyFailsafe() }
                }
            }
        }
    }

    @ObservationIgnored private var verifyFailsafe: Timer?

    /// A main-run-loop timer independent of the engine: if a switch is still opening/verifying 35 s
    /// after relaunch, end the spinner with "Switch not confirmed" and Roll Back.
    private func armVerifyFailsafe() {
        verifyFailsafe?.invalidate()
        verifyFailsafe = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let a = self.activity, a.phase == .opening || a.phase == .verifying else { return }
                self.store.log("verify: UI ceiling reached; showing not confirmed")
                self.activity = nil
                if let bid = self.store.backups().first?.id { self.line = .notConfirmed(backupID: bid) }
                self.refresh()
            }
        }
    }

    /// Screenshot states for `scripts/demo-panel.sh`; only with the dry-run controller.
    private func applyDemoState() {
        let env = ProcessInfo.processInfo.environment
        guard env["CLAUDE_ACCOUNTS_DRY_CONTROLLER"] == "1", let s = env["CLAUDE_ACCOUNTS_DEMO_STATE"] else { return }
        if s == "switching", let target = accounts.first(where: { $0.id != currentID }) {
            activity = Activity(accountID: target.id, phase: .quittingClaude)
        }
        if s == "notConfirmed" { line = .notConfirmed(backupID: "demo") }
        if s == "expanded" { expandedID = accounts.first { $0.id != currentID }?.id }
        if s == "parallel" {
            try? store.updateState { $0.parallelWindowsEnabled = true }
            if let other = accounts.first(where: { $0.id != currentID }) {
                demoWindows[other.id] = WindowInfo(accountID: other.id, signedIn: true, isOpen: true, pid: nil)
            }
            refresh()
        }
    }
}
