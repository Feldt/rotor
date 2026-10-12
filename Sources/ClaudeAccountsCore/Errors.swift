import Foundation

public enum EngineError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A required file is absent.
    case missing(String)
    case io(String)
    case sqlite(String)
    /// Live files don't have the expected shape (e.g. after a Claude update).
    case shapeMismatch(String)
    /// The app is still running after the wait; nothing was changed.
    case stillRunning(String)
    /// The app exited but its files never settled.
    case notClean(String)
    case cancelled
    case unknownAccount(String)
    case noSavedLogin(String)
    case alreadyCurrent
    case busy(Int)
    case refusedRealPaths
    case chromeNotClosed
    /// Claude came back while files were being moved; stopped before the next write.
    case claudeReopened
    /// Restoring the target failed; Claude was left closed. The backup restores the old state.
    case restoreFailed(backupID: String)
    /// A rollback failed partway. `preBackupID` holds the files as they were before it.
    case rollbackFailed(backupID: String, preBackupID: String)
    /// Chrome's cookie database version differs from the slot's.
    case chromeSchemaChanged
    /// The live Chrome profile holds no claude.ai login.
    case noChromeLogin
    /// The outgoing Chrome login couldn't be saved, so Chrome was left as it was.
    case chromeKept

    public var description: String {
        switch self {
        case .missing(let s): "Missing \(s)"
        case .io(let s): s
        case .sqlite(let s): "Database error: \(s)"
        case .shapeMismatch(let s): "Claude updated; switching paused (\(s))"
        case .stillRunning(let s): "\(s) didn't quit; nothing was changed"
        case .notClean(let s): "\(s) didn't finish writing its files; nothing was changed"
        case .cancelled: "Cancelled; nothing was changed"
        case .unknownAccount(let s): "Unknown account \(s)"
        case .noSavedLogin(let s): "No saved login for \(s)"
        case .alreadyCurrent: "Already on that account"
        case .busy(let n): "\(n) chats are working"
        case .refusedRealPaths: "Refusing to touch real data without --real-data"
        case .chromeNotClosed: "Chrome must be closed"
        case .claudeReopened: "Claude reopened during the switch; stopped before the next change"
        case .restoreFailed(let id): "Couldn't load the account; Claude is left closed. Backup \(id) restores the previous login"
        case .rollbackFailed(let id, let pre): "Rollback to \(id) failed partway; backup \(pre) holds the files from just before it"
        case .chromeSchemaChanged: "Chrome updated, sign in to the extension once"
        case .noChromeLogin: "Chrome has no claude.ai login to save"
        case .chromeKept: "Chrome's login couldn't be saved, so Chrome was left as it was"
        }
    }
}
