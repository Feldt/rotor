import Foundation

public enum FirstSignInPhase: Sendable, Equatable {
    case checking, syncingChats
    /// The main window is being closed so the sign-in's `claude://` link reaches the new window.
    case closingMain
    case mainAsking
    case waitingForMain
    case openingWindow
    /// Waiting for the person to sign in inside the new window.
    case waitingForSignIn
    case reopeningMain
    case done
    /// The flow failed or was cancelled and was undone; says whether the main window is open again.
    case rolledBack(mainReopened: Bool)

    public var title: String {
        switch self {
        case .checking: "Checking"
        case .syncingChats: "Syncing chats"
        case .closingMain: "Closing the main window"
        case .mainAsking: "Claude is asking…"
        case .waitingForMain: "Waiting for Claude to close…"
        case .openingWindow: "Opening the new window"
        case .waitingForSignIn: "Sign in to Claude in the new window"
        case .reopeningMain: "Reopening the main window"
        case .done: "Done"
        case .rolledBack(let reopened): reopened ? "Cancelled; main window reopened" : "Cancelled"
        }
    }
}

public struct FirstSignInOutcome: Sendable, Equatable {
    public var accountId: String
    public var pid: Int32
    /// The main window was closed for the sign-in and is open again.
    public var mainReopened: Bool
    public var warnings: [String]
}

/// A window's one real sign-in. Claude's sign-in comes back through a `claude://` link that macOS hands
/// to the first Claude window, so the main window is closed while the new window signs in:
///
/// 1. checks (cap, one account in one place), 2. chat sync, 3. quit the main window (its own
/// "still working" dialog may ask), 4. open the new window (settings synced first), 5. wait until that
/// window's config.json names the target account, 6. reopen the main window.
///
/// Every failure or cancel after the main window was closed undoes the flow: the new window is closed,
/// a wrong-account folder is removed, and the main window is reopened. A saved login is never copied
/// into the window (it would trigger Claude's "sign in again for your security" banner), and the
/// device id is never touched.
public final class FirstSignIn: Sendable {
    public let windows: WindowEngine
    public var paths: Paths { windows.paths }
    public var store: AccountStore { windows.store }
    public var ticker: Ticker { windows.ticker }

    /// How long to wait for the person to sign in.
    public let signInTimeout: Double
    /// How long the main window may take to come back.
    public let reopenTimeout: Double
    /// A missing window is only "closed" after this long (Claude may relaunch itself once).
    public let windowGoneGrace: Double
    public let pollInterval: Double
    /// How long the main window may take to quit (Claude's own "still working" dialog can ask).
    public let mainQuitTimeout: Double

    public init(windows: WindowEngine, signInTimeout: Double = 600, reopenTimeout: Double = 30,
                windowGoneGrace: Double = 10, pollInterval: Double = 1, mainQuitTimeout: Double = 120) {
        self.mainQuitTimeout = mainQuitTimeout
        self.windows = windows
        self.signInTimeout = signInTimeout
        self.reopenTimeout = reopenTimeout
        self.windowGoneGrace = windowGoneGrace
        self.pollInterval = pollInterval
    }

    func step(_ message: String) { windows.step("first sign-in: \(message)") }

    /// Runs the flow. Cancel by cancelling the task. Waits for any action that is already running and
    /// holds every other one off until it ends.
    public func run(_ accountId: String,
                    progress: @escaping @Sendable (FirstSignInPhase) -> Void = { _ in }) async throws -> FirstSignInOutcome {
        progress(.checking)
        return try await windows.exclusively { try await self.runUnlocked(accountId, progress: progress) }
    }

    func runUnlocked(_ accountId: String,
                     progress: @escaping @Sendable (FirstSignInPhase) -> Void) async throws -> FirstSignInOutcome {
        step("\(accountId): requested")

        // Checks that change nothing.
        let dir = try windows.dataDir(accountId)
        try windows.checkCanOpen(accountId)
        let dirString = ParallelWindows.dirString(dir)
        // Nothing to sign in: it is open, or its own login is already there.
        if windows.windowIsRunning(accountId) { throw WindowError.accountInWindow(accountId) }
        if windows.isSignedIn(accountId) { throw WindowError.alreadySignedIn(accountId) }
        // The sign-in link goes to the first Claude window that is open. Another extra window would take it.
        if windows.liveWindows().isEmpty == false { throw WindowError.closeOtherWindowsFirst }

        // The folder and registry entry exist before the sync, so the chat sync fills the new window too.
        let existedBefore = FileOps.exists(dir)
        _ = try windows.prepare(accountId)
        var warnings: [String] = []
        progress(.syncingChats)
        if let w = await windows.runChatSync() { warnings.append(w) }
        if Task.isCancelled {
            await undo(accountId, createdDir: existedBefore == false, mainWasClosed: false, removeDir: false, progress: progress)
            throw WindowError.cancelled
        }

        // From here the main window may close. The marker lets the next launch reopen it after a crash.
        let mainWasRunning = windows.mainPID() != nil
        try? store.updateState {
            $0.pendingWindowSignIn = PendingWindowSignIn(accountID: accountId, reopenMain: mainWasRunning, startedAt: ticker.now())
        }

        var removeDir = false
        do {
            if mainWasRunning { try await closeMain(progress: progress) }

            progress(.openingWindow)
            let opened = try await windows.launch(accountId, warnings: &warnings)

            progress(.waitingForSignIn)
            try await waitForSignIn(accountId, dirString: dirString)
            try windows.updateRegistry { reg in
                if var r = reg.record(accountId) {
                    r.signedIn = true
                    windows.upsert(r, in: &reg)
                }
            }
            step("\(accountId): signed in")

            var reopened = false
            if mainWasRunning {
                progress(.reopeningMain)
                try await reopenMain()
                reopened = true
            }
            try? store.updateState { $0.pendingWindowSignIn = nil }
            windows.reconcile()
            // New chats and the window's cards flow both ways now that the window is signed in.
            if let w = await windows.runChatSync() { warnings.append(w) }
            progress(.done)
            return FirstSignInOutcome(accountId: accountId, pid: opened.pid, mainReopened: reopened, warnings: warnings)
        } catch {
            if case WindowError.signedInAsOther = error { removeDir = true }
            // Reopening must happen even when this task was cancelled.
            await undo(accountId, createdDir: existedBefore == false, mainWasClosed: mainWasRunning, removeDir: removeDir, progress: progress)
            if error is CancellationError { throw WindowError.cancelled }
            if case EngineError.cancelled = error { throw WindowError.cancelled }
            throw error
        }
    }

    /// Closes the main window and nothing else. Throws if it won't close; then it is still open.
    func closeMain(progress: @escaping @Sendable (FirstSignInPhase) -> Void) async throws {
        progress(.closingMain)
        step("quit main window")
        var quitter = windows.quitter
        quitter.quitTimeout = mainQuitTimeout
        try await quitter.quitAndWait(windows.mainApp) { [self] ev in
            switch ev {
            case .appIsAsking:
                step("main window is asking")
                progress(.mainAsking)
            case .waitingToFinish, .waitingOn:
                progress(.waitingForMain)
            default: break
            }
        }
        step("main window closed")
    }

    /// `open -n -a Claude` with no flags, then wait for the main process to appear.
    func reopenMain() async throws {
        step("reopen main window")
        if windows.mainPID() == nil {
            do { try await windows.controller.launchNewInstance(appAt: paths.claudeApp, arguments: []) } catch {
                throw WindowError.mainNotReopened
            }
        }
        let start = ticker.now()
        while windows.mainPID() == nil {
            if ticker.now().timeIntervalSince(start) > reopenTimeout { throw WindowError.mainNotReopened }
            try? await ticker.sleep(seconds: 0.25)
        }
    }

    /// Polls the new window's own config.json until `lastKnownAccountUuid` is the target.
    func waitForSignIn(_ accountId: String, dirString: String) async throws {
        let config = paths.windowConfig(accountId)
        let start = ticker.now()
        var goneSince: Date?
        while true {
            if Task.isCancelled { throw WindowError.cancelled }
            if let actual = ClaudeConfig.currentAccount(config) {
                if actual == accountId { return }
                throw WindowError.signedInAsOther(expected: accountId, actual: actual)
            }
            let now = ticker.now()
            if windows.processMap().exactWindowPID(dataDir: dirString) == nil {
                goneSince = goneSince ?? now
                if now.timeIntervalSince(goneSince!) > windowGoneGrace { throw WindowError.windowClosedBeforeSignIn(accountId) }
            } else {
                goneSince = nil
            }
            if now.timeIntervalSince(start) > signInTimeout { throw WindowError.signInTimedOut(accountId) }
            do { try await ticker.sleep(seconds: pollInterval) } catch { throw WindowError.cancelled }
        }
    }

    /// Puts things back: closes the new window, removes a wrong-account folder, reopens the main
    /// window if this flow closed it. Runs in its own task so a cancelled caller still finishes it.
    func undo(_ accountId: String, createdDir: Bool, mainWasClosed: Bool, removeDir: Bool,
              progress: @escaping @Sendable (FirstSignInPhase) -> Void) async {
        let reopened: Bool = await Task { [self] in
            step("\(accountId): undoing")
            if windows.windowIsRunning(accountId) {
                do { try await windows.closeUnlocked(accountId) } catch { step("\(accountId): new window did not close (\(error))") }
            }
            if removeDir {
                if let dir = try? windows.dataDir(accountId), windows.windowIsRunning(accountId) == false {
                    try? FileOps.removeDirectory(dir)
                    try? windows.updateRegistry { reg in reg.windows.removeAll { $0.accountId == accountId } }
                    step("\(accountId): removed the folder of the wrong account")
                }
            } else if createdDir {
                // An unsigned folder this flow created: leave nothing half-made behind.
                if let dir = try? windows.dataDir(accountId), ClaudeConfig.currentAccount(paths.windowConfig(accountId)) == nil,
                   windows.windowIsRunning(accountId) == false {
                    try? FileOps.removeDirectory(dir)
                    try? windows.updateRegistry { reg in reg.windows.removeAll { $0.accountId == accountId } }
                }
            }
            var mainOK = true
            if mainWasClosed {
                do { try await reopenMain() } catch {
                    mainOK = false
                    step("main window did not reopen: \(error)")
                }
            }
            if mainOK { try? store.updateState { $0.pendingWindowSignIn = nil } }
            windows.reconcile()
            return mainWasClosed ? mainOK : false
        }.value
        progress(.rolledBack(mainReopened: reopened))
    }

    /// At app start: if a first sign-in was interrupted (the app quit or crashed mid-flow), reopen the
    /// main window when it is closed, then clear the marker. Returns a note for the log, or nil.
    @discardableResult
    public func recoverIfInterrupted() async -> String? {
        (try? await windows.exclusively { await self.recoverUnlocked() }) ?? nil
    }

    func recoverUnlocked() async -> String? {
        guard let pending = store.state().pendingWindowSignIn else { return nil }
        var note = "an interrupted sign-in for \(pending.accountID) was cleared"
        if pending.reopenMain, windows.mainPID() == nil {
            do {
                try await reopenMain()
                note += "; the main window was reopened"
            } catch {
                note += "; the main window did not reopen"
                step(note)
                return note
            }
        }
        try? store.updateState { $0.pendingWindowSignIn = nil }
        windows.reconcile()
        step(note)
        return note
    }
}
