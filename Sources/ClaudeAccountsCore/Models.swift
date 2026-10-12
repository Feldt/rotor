import Foundation

public struct DesktopSlot: Codable, Sendable, Equatable {
    public var savedAt: Date
    public var claudeVersion: String?
    public var cookieExpiresAt: Date?
}

public struct ChromeSlot: Codable, Sendable, Equatable {
    public var savedAt: Date
    public var cookieExpiresAt: Date?
    public var extensionAccountUuid: String?
    public var hosts: [String]?
    /// Chrome's Cookies `meta.version` / `last_compatible_version` when saved.
    public var schemaVersion: String?
    public var lastCompatibleVersion: String?
}

public struct Account: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var colorIndex: Int
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var desktop: DesktopSlot?
    public var chrome: ChromeSlot?
    /// Registered automatically; the panel asks for a label.
    public var needsLabel: Bool?

    public init(id: String, label: String, colorIndex: Int, createdAt: Date) {
        self.id = id
        self.label = label
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }

    /// "team" for "team@example.com"; the menu bar shows this.
    public var shortLabel: String {
        let base = label.split(separator: "@").first.map(String.init) ?? label
        return base.isEmpty ? "Claude" : base
    }

    public var initials: String {
        let base = shortLabel
        let parts = base.split(whereSeparator: { " ._-".contains($0) })
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(base.prefix(2)).uppercased()
    }
}

/// Where Chrome should end up and how. Persisted so a deferred swap survives a relaunch.
public enum PendingChrome: Codable, Sendable, Equatable {
    /// Load this account's Chrome slot when Chrome next quits.
    case slot(String)
    /// Clear claude.ai and the extension so a new account can sign in when Chrome next quits.
    case seed
    /// After a seeded sign-in, save Chrome under the account the extension reports when Chrome next quits.
    case saveSignedIn
    /// Restore the Chrome files in this backup when Chrome next quits.
    case backup(String)
    /// The target has no Chrome slot yet: clear claude.ai for its sign-in when Chrome next quits.
    case seedTarget(String)
}

public enum ChromeWhenRunning: String, Codable, Sendable {
    case restartNow, whenNextQuits
}

/// How Chrome follows a switch.
public enum ChromeMode: String, Codable, Sendable, CaseIterable {
    /// Quit and relaunch Chrome together with Claude (default).
    case withClaude
    /// Swap the next time Chrome quits.
    case whenChromeQuits
}

/// App-level settings and engine bookkeeping (the spec's accounts.json stays a plain array).
public struct StoreState: Codable, Sendable, Equatable {
    public var lastGoodClaudeVersion: String?
    public var chromeFollows: Bool = false
    public var chromeMode: ChromeMode?
    /// The user confirmed which account Chrome is signed in as (first enable). No Chrome swap before.
    public var chromeAttributionConfirmed: Bool?
    /// The target whose claude.ai login was cleared in Chrome; the panel asks to sign in until the
    /// extension reports it (advisory) or the next switch.
    public var chromeAwaitingSignIn: String?
    public var rememberedChromeChoice: ChromeWhenRunning?
    /// Account whose claude.ai login is in Chrome, as far as the app knows.
    public var chromeAccount: String?
    public var pendingChrome: PendingChrome?
    /// Label typed in Add account, applied when the new uuid appears.
    public var pendingAddLabel: String?
    /// Account that was current when Add account began.
    public var pendingAddFrom: String?
    /// The account just added, whose Chrome login is saved when Chrome next quits (`.saveSignedIn`).
    public var chromeSignInFor: String?
    /// Set when Add account is a "Sign in again" for this known account.
    public var pendingAddReauth: String?
    public var panelStyle: String?
    /// Open at Login was turned on once by default (first launch of the signed build). After that,
    /// The user's own choice in Settings sticks.
    public var loginItemDefaulted: Bool?
    /// "Show Usage" toggle (default on). Off means no Keychain read and no network at all.
    public var showUsage: Bool?
    /// A switch, rollback or add whose files may be half-moved. Written before the first
    /// destructive step, cleared after a successful restore.
    public var inFlight: InFlight?
    /// The pre-switch chat sync pass failed (cleared by the next good pass).
    public var lastSyncFailed: Bool?
    /// The last Chrome problem, for the panel's banner. Cleared when the user dismisses it.
    public var chromeNotice: String?
    /// "Extra Claude windows" toggle (default off).
    public var parallelWindowsEnabled: Bool?
    /// A window's first sign-in is in progress and the main window may be closed because of it.
    /// Written before the main window is quit and cleared once it is open again; at startup an
    /// interrupted one reopens the main window.
    public var pendingWindowSignIn: PendingWindowSignIn?

    public init() {}
}

public struct PendingWindowSignIn: Codable, Sendable, Equatable {
    public var accountID: String
    /// The main window was running when the flow began, so it must be reopened.
    public var reopenMain: Bool
    public var startedAt: Date

    public init(accountID: String, reopenMain: Bool, startedAt: Date) {
        self.accountID = accountID
        self.reopenMain = reopenMain
        self.startedAt = startedAt
    }
}

public struct InFlight: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case switchAccount, rollback, add }
    public var kind: Kind
    /// The backup that restores the pre-operation state (for a rollback: the backup being restored).
    public var backupID: String
    public var from: String?
    public var to: String?
    public var step: String
    /// For a rollback: the backup of the files as they were just before it.
    public var preBackupID: String?

    public init(kind: Kind, backupID: String, from: String?, to: String?, step: String, preBackupID: String? = nil) {
        self.kind = kind
        self.backupID = backupID
        self.from = from
        self.to = to
        self.step = step
        self.preBackupID = preBackupID
    }
}

public struct BackupManifest: Codable, Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var reason: String
    public var fromAccount: String?
    public var toAccount: String?
    public var hasDesktop: Bool
    public var hasChrome: Bool
    /// The account whose Chrome login the backup's Chrome files hold, if known.
    public var chromeAccount: String?
    /// Byte sizes of the backed-up files, written with the manifest after the files are synced.
    public var sizes: [String: Int]?
    /// For a desktop backup: the Chrome backup taken in the same switch.
    public var chromeBackupID: String?
}
