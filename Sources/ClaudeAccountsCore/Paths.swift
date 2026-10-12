import Foundation

/// Every file location the engine touches. Tests and the CLI build one pointing at a fake tree.
public struct Paths: Sendable, Equatable {
    /// `~/Library/Application Support/ClaudeAccounts`
    public var storeRoot: URL
    /// `~/Library/Application Support/Claude`
    public var claudeUserData: URL
    /// `~/Library/Application Support/Google/Chrome/Default`
    public var chromeProfile: URL
    /// `~/.claude/session-sync`
    public var sessionSync: URL
    /// `~/.claude/projects` (transcripts, read only)
    public var claudeProjects: URL
    /// `~/Library/Logs/Claude` (read only)
    public var claudeLogs: URL
    /// `/Applications/Claude.app`
    public var claudeApp: URL
    /// `/Applications/Google Chrome.app`
    public var chromeApp: URL

    public static let claudeBundleID = "com.anthropic.claudefordesktop"
    public static let chromeBundleID = "com.google.Chrome"
    public static let extensionID = "fcoeoabgfenejglbffodgkkbkcdhcgfn"

    public init(
        storeRoot: URL, claudeUserData: URL, chromeProfile: URL, sessionSync: URL,
        claudeProjects: URL, claudeLogs: URL, claudeApp: URL, chromeApp: URL
    ) {
        self.storeRoot = storeRoot
        self.claudeUserData = claudeUserData
        self.chromeProfile = chromeProfile
        self.sessionSync = sessionSync
        self.claudeProjects = claudeProjects
        self.claudeLogs = claudeLogs
        self.claudeApp = claudeApp
        self.chromeApp = chromeApp
    }

    /// The real locations on this Mac, ignoring the environment.
    public static func realDefaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Paths {
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return Paths(
            storeRoot: support.appending(path: "ClaudeAccounts", directoryHint: .isDirectory),
            claudeUserData: support.appending(path: "Claude", directoryHint: .isDirectory),
            chromeProfile: support.appending(path: "Google/Chrome/Default", directoryHint: .isDirectory),
            sessionSync: home.appending(path: ".claude/session-sync", directoryHint: .isDirectory),
            claudeProjects: home.appending(path: ".claude/projects", directoryHint: .isDirectory),
            claudeLogs: home.appending(path: "Library/Logs/Claude", directoryHint: .isDirectory),
            claudeApp: URL(filePath: "/Applications/Claude.app", directoryHint: .isDirectory),
            chromeApp: URL(filePath: "/Applications/Google Chrome.app", directoryHint: .isDirectory)
        )
    }

    /// Real defaults with `CLAUDE_ACCOUNTS_ROOT`, `CLAUDE_USERDATA_DIR`, `CHROME_PROFILE_DIR`,
    /// `SESSION_SYNC_DIR`, `CLAUDE_PROJECTS_DIR`, `CLAUDE_LOGS_DIR`, `CLAUDE_APP_PATH` and
    /// `CHROME_APP_PATH` applied.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Paths {
        var p = realDefaults(home: home)
        func dir(_ key: String) -> URL? {
            guard let v = env[key], v.isEmpty == false else { return nil }
            return URL(filePath: (v as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        if let v = dir("CLAUDE_ACCOUNTS_ROOT") { p.storeRoot = v }
        if let v = dir("CLAUDE_USERDATA_DIR") { p.claudeUserData = v }
        if let v = dir("CHROME_PROFILE_DIR") { p.chromeProfile = v }
        if let v = dir("SESSION_SYNC_DIR") { p.sessionSync = v }
        if let v = dir("CLAUDE_PROJECTS_DIR") { p.claudeProjects = v }
        if let v = dir("CLAUDE_LOGS_DIR") { p.claudeLogs = v }
        if let v = dir("CLAUDE_APP_PATH") { p.claudeApp = v }
        if let v = dir("CHROME_APP_PATH") { p.chromeApp = v }
        return p
    }

    /// True when any location that a switch writes to is a real one (not overridden).
    public func touchesRealData(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let real = Paths.realDefaults(home: home)
        func same(_ a: URL, _ b: URL) -> Bool {
            a.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == b.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return same(storeRoot, real.storeRoot) || same(claudeUserData, real.claudeUserData)
            || same(chromeProfile, real.chromeProfile) || same(sessionSync, real.sessionSync)
    }

    // MARK: Derived locations

    public var accountsFile: URL { storeRoot.appending(path: "accounts.json") }
    public var stateFile: URL { storeRoot.appending(path: "state.json") }
    public var slotsDir: URL { storeRoot.appending(path: "slots", directoryHint: .isDirectory) }
    public var backupsDir: URL { storeRoot.appending(path: "backups", directoryHint: .isDirectory) }
    public var chromeBackupsDir: URL { storeRoot.appending(path: "chrome-backups", directoryHint: .isDirectory) }
    public var usageFile: URL { storeRoot.appending(path: "usage.json") }
    public var switchLog: URL { storeRoot.appending(path: "switch.log") }

    // Parallel windows: one data dir per extra Claude window, and the registry the engine writes.
    /// `<storeRoot>/windows` (0700): one data dir per account.
    public var windowsRoot: URL { storeRoot.appending(path: "windows", directoryHint: .isDirectory) }
    /// `<storeRoot>/windows.json`: written atomically by the engine only; other tools read it.
    public var windowsFile: URL { storeRoot.appending(path: "windows.json") }
    /// `<storeRoot>/windows/<accountUuid>`
    public func windowDataDir(_ accountID: String) -> URL {
        windowsRoot.appending(path: accountID, directoryHint: .isDirectory)
    }
    public func windowConfig(_ accountID: String) -> URL { windowDataDir(accountID).appending(path: "config.json") }
    /// `/Applications/Claude.app/Contents/MacOS/Claude`: the browser process of every window.
    public var claudeExecutable: URL { claudeApp.appending(path: "Contents/MacOS/Claude") }

    public func slotDesktopCookies(_ id: String) -> URL {
        slotsDir.appending(path: "\(id)/desktop/Cookies")
    }
    public func slotOAuthCache(_ id: String) -> URL {
        slotsDir.appending(path: "\(id)/desktop/oauth-cache-v2")
    }
    public func slotChromeCookies(_ id: String) -> URL {
        slotsDir.appending(path: "\(id)/chrome/claude-cookies.sqlite")
    }
    public func slotChromeExtension(_ id: String) -> URL {
        slotsDir.appending(path: "\(id)/chrome/extension-settings", directoryHint: .isDirectory)
    }

    public var liveCookies: URL { claudeUserData.appending(path: "Cookies") }
    public var liveCookiesJournal: URL { claudeUserData.appending(path: "Cookies-journal") }
    public var liveConfig: URL { claudeUserData.appending(path: "config.json") }
    public var liveConfigJournal: URL { claudeUserData.appending(path: "config.json.journal") }
    public var claudeCodeDir: URL { claudeUserData.appending(path: "claude-code", directoryHint: .isDirectory) }
    public var mainLog: URL { claudeLogs.appending(path: "main.log") }
    public var claudeInfoPlist: URL { claudeApp.appending(path: "Contents/Info.plist") }

    public var chromeCookies: URL { chromeProfile.appending(path: "Cookies") }
    public var chromeCookiesJournal: URL { chromeProfile.appending(path: "Cookies-journal") }
    public var chromePreferences: URL { chromeProfile.appending(path: "Preferences") }
    public var chromeExtensionSettings: URL {
        chromeProfile.appending(path: "Local Extension Settings/\(Paths.extensionID)", directoryHint: .isDirectory)
    }

    public var mirrorScript: URL { sessionSync.appending(path: "mirror.py") }
    public var syncLog: URL { sessionSync.appending(path: "sync.log") }
    public var syncAccountsFile: URL { sessionSync.appending(path: "accounts.json") }
}
