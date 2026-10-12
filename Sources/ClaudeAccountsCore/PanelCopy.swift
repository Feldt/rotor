import Foundation

/// Every panel status line, kept to one line at the 260 pt panel (≈30 characters plus one action).
/// Full detail goes in the tooltip and switch.log.
public enum PanelCopy {
    public static let budget = 30

    public static let switching = "Switching…"
    public static let closingClaude = "Closing Claude…"
    public static let saving = "Saving…"
    public static let openingClaude = "Opening Claude…"
    public static let restartingChrome = "Restarting Chrome…"
    public static let waitingForClaude = "Waiting for Claude to close…"
    public static func waitingOn(_ n: Int) -> String { n == 1 ? "Waiting on 1 Claude process" : "Waiting on \(n) Claude processes" }
    public static let switchCancelled = "Switch cancelled"
    public static let claudeDidntClose = "Claude didn't close"
    public static let claudeReopened = "Claude reopened · cancelled"
    public static let notConfirmed = "Switch not confirmed"
    public static let switchFailed = "Switch failed"
    public static let restoreFailed = "Restore failed"
    public static let chromePending = "Chrome switches on quit"
    public static let signInChrome = "Sign in to Claude in Chrome"
    public static let chromeTabs = "Chrome tabs won't reopen"
    public static let chromeUpdate = "Chrome update · sign in once"
    public static let chromeNotSwitched = "Chrome didn't switch"
    public static let chromeUnconfirmed = "Chrome switched, unconfirmed"
    public static let keychainDenied = "Keychain access denied"
    public static let updateFailed = "Update failed"
    public static let waitingForSignIn = "Waiting for sign-in"
    public static let restartChrome = "Restart Chrome?"
    public static let somethingWrong = "Something went wrong"

    // MARK: Parallel windows

    public static let parallelWindows = "Parallel Windows"
    /// The small buttons on a row (shown only while Parallel Windows is on).
    public static let switchButton = "Switch"
    public static let openButton = "Open"
    public static let showButton = "Show"
    public static let closeButton = "Close"
    /// The row subtitles. Every other account keeps its normal row.
    public static let mainWindowSubtitle = "Main window"
    public static let windowOpenSubtitle = "Open in its own window"
    /// Shown when Open is pressed with all the extra windows in use.
    public static func capReached(_ n: Int) -> String { "Close a window first (\(n) at most)." }
    /// Only reachable through an error; a row never shows it.
    public static let windowNeedsSignIn = "Window needs sign-in"
    public static let openingWindow = "Opening window…"
    public static let closingWindow = "Closing window…"
    /// A window that quit to install an update comes back once the main window has updated.
    public static let reopeningWindow = "Reopening window…"
    public static let windowNotReopened = "A window didn't reopen"
    public static let windowReady = "Window ready"
    /// The window opened but a sync step reported a problem (details are in the log).
    public static let windowReadyCheckLog = "Window ready · see log"
    public static let windowClosed = "A window closed"
    public static let mainReopened = "Main window reopened"
    public static let signInCancelled = "Sign-in cancelled"
    public static let openClaudeYourself = "Open Claude yourself"
    public static let continueTitle = "Continue"

    /// The one-time sign-in confirmation: one line, whatever else is running.
    public static let windowSignInConfirm = "To sign this account in, your main Claude window closes for about a minute."

    /// The step line during a window's first sign-in.
    public static func signInStep(_ phase: FirstSignInPhase) -> String {
        switch phase {
        case .checking: "Checking…"
        case .syncingChats: "Syncing chats…"
        case .closingMain: "Closing main window…"
        case .mainAsking: "Claude is asking…"
        case .waitingForMain: waitingForClaude
        case .openingWindow: "Opening new window…"
        case .waitingForSignIn: "Sign in using the new window"
        case .reopeningMain: "Reopening main window…"
        case .done: windowReady
        case .rolledBack(let reopened): reopened ? "Cancelled · main reopened" : "Cancelled"
        }
    }

    /// Where the sign-in flow ends up after an interrupted run found at app start.
    public static func interruptedSignIn(note: String) -> String {
        note.contains("did not reopen") ? openClaudeYourself : (note.contains("was reopened") ? mainReopened : signInCancelled)
    }

    /// A short title for a window error; the full description goes in the tooltip.
    public static func title(for error: WindowError) -> String {
        switch error {
        case .invalidAccount: somethingWrong
        case .accountIsMain: "Already in the main window"
        case .accountInWindow: "Already in a window"
        case .capReached(let n): capReached(n)
        case .needsFirstSignIn: windowNeedsSignIn
        case .alreadySignedIn: "Window already signed in"
        case .launchFailed: "Window didn't open"
        case .windowStillRunning: "Window didn't close"
        case .windowClosedBeforeSignIn: "Window closed early"
        case .signInTimedOut: "Sign-in timed out"
        case .signedInAsOther: "Wrong account signed in"
        case .mainNotReopened: openClaudeYourself
        case .cancelled: "Cancelled"
        case .settingsNotApplied: "Settings didn't copy"
        case .closeOtherWindowsFirst: "Close other windows first"
        case .launchUnsupported: "Can't open windows here"
        }
    }

    public static func chromeKept(_ label: String?) -> String {
        guard let label else { return "Chrome kept as is" }
        let s = "Chrome kept on \(label)"
        return s.count <= budget ? s : "Chrome kept as is"
    }

    public static func chromeSignedInAs(_ label: String?) -> String {
        guard let label else { return "Chrome signed in elsewhere" }
        let s = "Chrome signed in as \(label)"
        return s.count <= budget ? s : "Chrome signed in elsewhere"
    }

    public static func signedInAgain(_ label: String) -> String {
        let s = "Signed in as \(label) again"
        return s.count <= budget ? s : "Same account again"
    }

    /// The step line while switching.
    public static func step(_ phase: SwitchPhase) -> String {
        switch phase {
        case .quittingClaude, .claudeAsking: closingClaude
        case .waitingForClaude: waitingForClaude
        case .waitingOn(let n): waitingOn(n)
        case .saving, .restoring: saving
        case .opening, .verifying: openingClaude
        case .quittingChrome, .chromeAsking, .restoringChrome, .openingChrome: restartingChrome
        default: switching
        }
    }

    /// A short title for an engine error; the full description goes in the tooltip.
    public static func title(for error: Error) -> String {
        if let w = error as? WindowError { return title(for: w) }
        guard let e = error as? EngineError else { return somethingWrong }
        switch e {
        case .cancelled: return switchCancelled
        case .stillRunning: return claudeDidntClose
        case .claudeReopened: return claudeReopened
        case .notClean: return "Claude didn't finish saving"
        case .shapeMismatch: return "Claude updated · paused"
        case .restoreFailed: return restoreFailed
        case .rollbackFailed: return "Rollback failed"
        case .noSavedLogin: return "No saved login"
        case .unknownAccount: return "Unknown account"
        case .alreadyCurrent: return "Already on that account"
        case .chromeSchemaChanged: return chromeUpdate
        case .chromeNotClosed: return "Chrome is still open"
        case .noChromeLogin: return "Chrome has no login"
        case .chromeKept: return "Chrome kept as is"
        case .missing: return "A file is missing"
        case .io, .sqlite: return somethingWrong
        case .busy: return "Chats are busy"
        case .refusedRealPaths: return "Refused real data"
        }
    }

    /// Every status line a window action can show (one line each, same budget).
    public static var windowLines: [String] {
        let phases: [FirstSignInPhase] = [.checking, .syncingChats, .closingMain, .mainAsking, .waitingForMain, .openingWindow,
                                          .waitingForSignIn, .reopeningMain, .done, .rolledBack(mainReopened: true),
                                          .rolledBack(mainReopened: false)]
        let errors: [WindowError] = [.invalidAccount("x"), .accountIsMain("x"), .accountInWindow("x"),
                                     .needsFirstSignIn("x"), .alreadySignedIn("x"), .launchFailed("x"), .windowStillRunning("x"),
                                     .windowClosedBeforeSignIn("x"), .signInTimedOut("x"), .signedInAsOther(expected: "x", actual: "y"),
                                     .mainNotReopened, .cancelled, .settingsNotApplied("x"), .closeOtherWindowsFirst, .launchUnsupported]
        return [windowNeedsSignIn, mainWindowSubtitle, windowOpenSubtitle, openingWindow, closingWindow, reopeningWindow, windowNotReopened, windowReady, windowReadyCheckLog, windowClosed, mainReopened, signInCancelled,
                openClaudeYourself]
            + phases.map { signInStep($0) } + errors.map { title(for: $0) }
    }

    /// Longer sentences that wrap over several lines (confirmations and the Settings footer).
    public static var sentences: [String] {
        [capReached(3), windowSignInConfirm]
    }

    /// Every fixed string, for the budget test.
    public static var all: [String] {
        [switching, closingClaude, saving, openingClaude, restartingChrome, waitingForClaude, waitingOn(1), waitingOn(12), switchCancelled, claudeDidntClose,
         claudeReopened, notConfirmed, switchFailed, restoreFailed, chromePending, chromeUpdate, chromeNotSwitched,
         chromeUnconfirmed, signInChrome, chromeTabs, keychainDenied, updateFailed, waitingForSignIn, restartChrome, somethingWrong,
         signedInAgain("a-really-long-label@example-company.com"), chromeKept(nil), chromeKept("team"),
         chromeKept("a-really-long-label-here"), chromeSignedInAs("team"), chromeSignedInAs("a-really-long-label-x")]
        + [EngineError.cancelled, .stillRunning("Claude"), .claudeReopened, .notClean("Claude"), .shapeMismatch("x"),
           .restoreFailed(backupID: "x"), .rollbackFailed(backupID: "x", preBackupID: "y"), .noSavedLogin("x"),
           .unknownAccount("x"), .alreadyCurrent, .chromeSchemaChanged, .chromeNotClosed, .noChromeLogin, .missing("x"),
           .io("x"), .sqlite("x"), .busy(3), .refusedRealPaths, .chromeKept].map { title(for: $0) }
        + windowLines
    }
}

// MARK: Account rows

/// One of the small buttons on an account row; the right-click menu offers the same actions.
public enum RowAction: Equatable, Hashable, Sendable { case switchTo, open, show, close }

/// What one account row knows about itself.
public struct RowFacts: Equatable, Sendable {
    public var isParallelOn: Bool
    /// This account is signed in to the main Claude window.
    public var isMain: Bool
    /// This account has an extra window open right now.
    public var hasOwnWindow: Bool
    public var isExpanded: Bool
    /// The row is still asking for a name (a new account).
    public var isBeingNamed: Bool
    /// A switch or window action is running for this account.
    public var isActive: Bool
    /// Any switch or window action is running.
    public var isSwitching: Bool

    public init(isParallelOn: Bool = false, isMain: Bool = false, hasOwnWindow: Bool = false, isExpanded: Bool = false,
                isBeingNamed: Bool = false, isActive: Bool = false, isSwitching: Bool = false) {
        self.isParallelOn = isParallelOn
        self.isMain = isMain
        self.hasOwnWindow = hasOwnWindow
        self.isExpanded = isExpanded
        self.isBeingNamed = isBeingNamed
        self.isActive = isActive
        self.isSwitching = isSwitching
    }
}

/// What one account row shows, decided from plain facts so it can be tested without any UI.
public struct RowPlan: Equatable, Sendable {
    /// A progress spinner replaces everything else on the row while its action runs.
    public var showsSpinner = false
    /// The buttons on the row: only an expanded row has any.
    public var buttons: [RowAction] = []
    /// The Parallel Windows buttons are mini; the single Switch button of the plain panel is not.
    public var usesMiniButtons = false
    /// The right-click menu, expanded or not. Empty means no menu at all.
    public var menu: [RowAction] = []
    /// The account is open somewhere: the main window or its own window.
    public var isOpenSomewhere = false
    public var showsCheckmark = false
    public var showsWindowIcon = false
    /// The "5d" / "Expired" mark; it gives way to buttons and the spinner.
    public var showsHealth = true
    public var subtitle: String?
    /// An expanded row with buttons has no room beside the name for its subtitle (measured: 73 pt
    /// of 124), so the subtitle becomes the first line of the expanded part instead.
    public var isSubtitleInDetail = false

    public init(for f: RowFacts) {
        showsSpinner = f.isActive && f.isSwitching
        // An account is in one place: if it is the main window's, a stale window entry is ignored.
        let hasWindow = f.hasOwnWindow && f.isMain == false
        isOpenSomewhere = f.isMain || hasWindow
        showsCheckmark = isOpenSomewhere && showsSpinner == false
        showsHealth = showsSpinner == false
        // A row that is still asking for a name has no buttons, menu, subtitle or window icon.
        guard f.isBeingNamed == false else { return }
        showsWindowIcon = hasWindow
        if f.isMain {
            subtitle = f.isParallelOn ? PanelCopy.mainWindowSubtitle : nil
        } else if hasWindow {
            subtitle = PanelCopy.windowOpenSubtitle
            // A window that outlives the setting can still be shown and closed.
            menu = [.show, .close]
        } else if f.isParallelOn {
            menu = [.switchTo, .open]
        }
        isSubtitleInDetail = subtitle != nil && f.isExpanded && menu.isEmpty == false
        // Buttons appear only once the row is expanded; the right-click menu is the shortcut that
        // needs no expanding.
        if showsSpinner == false, f.isExpanded {
            if menu.isEmpty == false {
                buttons = menu
                usesMiniButtons = true
            } else if f.isMain == false, f.isActive == false {
                // Setting off: the plain panel's single Switch button.
                buttons = [.switchTo]
            }
        }
        showsHealth = showsSpinner == false && buttons.isEmpty
    }
}
