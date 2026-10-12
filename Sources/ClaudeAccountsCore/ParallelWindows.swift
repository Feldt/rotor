import Foundation

// MARK: Errors

/// Why an extra window could not be opened, closed or signed in. Every case leaves the main window
/// either untouched or reopened; none of them force-kills anything.
public enum WindowError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The account id is not a plain uuid (it names a folder, so nothing else is allowed).
    case invalidAccount(String)
    /// This account is the main window's account. One account lives in one place.
    case accountIsMain(String)
    /// This account is already open in an extra window.
    case accountInWindow(String)
    /// Three extra windows are already open.
    case capReached(Int)
    /// The window has never been signed in; it needs its one real sign-in first.
    case needsFirstSignIn(String)
    /// The window already holds its own login; open it instead of signing in again.
    case alreadySignedIn(String)
    /// Claude did not start a window for that folder.
    case launchFailed(String)
    /// The window did not exit in time. It was asked politely and nothing was forced.
    case windowStillRunning(String)
    /// The window was closed before its sign-in finished.
    case windowClosedBeforeSignIn(String)
    /// Nobody signed in within the time allowed.
    case signInTimedOut(String)
    /// The window was signed in as a different account; its folder was removed.
    case signedInAsOther(expected: String, actual: String)
    /// The main window did not come back. Open Claude yourself.
    case mainNotReopened
    case cancelled
    /// The settings copy failed and the window's background jobs (scheduled tasks, remote control,
    /// keep-awake, auto-archive) are not known to be off, so it was not opened.
    case settingsNotApplied(String)
    /// Another extra window is open: macOS would hand the sign-in link to it, not to the new window.
    case closeOtherWindowsFirst
    /// The controller cannot start a second instance (dry run).
    case launchUnsupported

    public var description: String {
        switch self {
        case .invalidAccount(let s): "Not a valid account id: \(s)"
        case .accountIsMain: "That account is open in the main window. One account can be open in one place at a time."
        case .accountInWindow: "That account is open in its own window. Close that window first."
        case .capReached(let n): "\(n) extra windows are already open. Close one first."
        case .needsFirstSignIn: "This window has never been signed in. It needs one sign-in first."
        case .alreadySignedIn: "This window is already signed in"
        case .launchFailed: "Claude did not open the window"
        case .windowStillRunning: "The window didn't close; nothing was forced"
        case .windowClosedBeforeSignIn: "The window was closed before the sign-in finished"
        case .signInTimedOut: "Nobody signed in to the new window in time"
        case .signedInAsOther: "The new window was signed in as a different account, so it was removed"
        case .mainNotReopened: "The main Claude window didn't reopen. Open Claude yourself."
        case .cancelled: "Cancelled"
        case .settingsNotApplied(let why): "The settings could not be copied to the new window (\(why)), and its background jobs might still be on, so it was not opened."
        case .closeOtherWindowsFirst: "A first sign-in needs the other extra windows closed, because macOS hands the sign-in link to the first Claude window that is open."
        case .launchUnsupported: "This build can't open extra windows"
        }
    }
}

// MARK: Registry (windows.json)

/// One extra window. Matches the pinned `windows.json` contract exactly.
public struct WindowRecord: Codable, Sendable, Equatable {
    public var accountId: String
    /// Absolute path of the window's `--user-data-dir`.
    public var dataDir: String
    public var signedIn: Bool
    public var openedAt: Date?
    public var pid: Int32?

    public init(accountId: String, dataDir: String, signedIn: Bool, openedAt: Date? = nil, pid: Int32? = nil) {
        self.accountId = accountId
        self.dataDir = dataDir
        self.signedIn = signedIn
        self.openedAt = openedAt
        self.pid = pid
    }

    enum CodingKeys: String, CodingKey { case accountId, dataDir, signedIn, openedAt, pid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(String.self, forKey: .accountId)
        dataDir = try c.decode(String.self, forKey: .dataDir)
        signedIn = try c.decodeIfPresent(Bool.self, forKey: .signedIn) ?? false
        openedAt = try c.decodeIfPresent(Date.self, forKey: .openedAt)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
    }

    /// `openedAt` and `pid` are written as explicit `null` when absent, as the contract shows.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(dataDir, forKey: .dataDir)
        try c.encode(signedIn, forKey: .signedIn)
        if let openedAt { try c.encode(openedAt, forKey: .openedAt) } else { try c.encodeNil(forKey: .openedAt) }
        if let pid { try c.encode(pid, forKey: .pid) } else { try c.encodeNil(forKey: .pid) }
    }
}

public struct WindowRegistry: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var windows: [WindowRecord] = []

    public init(windows: [WindowRecord] = []) { self.windows = windows }

    public func record(_ accountId: String) -> WindowRecord? { windows.first { $0.accountId == accountId } }
}

/// Reads and writes `windows.json`. Only the engine writes; everyone else uses `read`, which
/// tolerates a missing or unreadable file by returning an empty registry.
public enum WindowRegistryStore {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func read(_ paths: Paths) -> WindowRegistry {
        guard let data = try? Data(contentsOf: paths.windowsFile),
              let reg = try? decoder.decode(WindowRegistry.self, from: data) else { return WindowRegistry() }
        return reg
    }

    /// Temp file + rename, 0600. The store root is created (0700) if needed.
    public static func write(_ registry: WindowRegistry, to paths: Paths) throws {
        try FileOps.ensureDirectory(paths.storeRoot)
        var reg = registry
        reg.version = 1
        try FileOps.writeAtomically(try encoder.encode(reg), to: paths.windowsFile)
    }
}

// MARK: Process map

/// A window's browser process, found by its exact arguments.
public struct LiveWindow: Sendable, Equatable {
    public var pid: Int32
    public var dataDir: String
    /// True when the arguments are exactly `<Claude executable> --user-data-dir=<dataDir>`: the only
    /// process the engine will ever signal.
    public var isExact: Bool
}

/// Splits the process table into the main window's processes and each extra window's. Pure: built
/// from a snapshot, so tests feed it any table.
public struct ClaudeProcessMap: Sendable {
    public static let userDataFlag = "--user-data-dir="
    public let processes: [ProcInfo]
    /// Browser processes started with `--user-data-dir=`.
    public let windows: [LiveWindow]
    private let parent: [Int32: Int32]
    private let browserByPID: [Int32: LiveWindow]
    /// Browser processes without a `--user-data-dir=`: the main window's.
    private let mainBrowserPIDs: Set<Int32>
    /// The folder that holds every extra window's data dir (`Paths.windowsRoot`), when known.
    private let windowsRoot: String?

    static func isBrowserProcess(_ p: ProcInfo) -> Bool { p.path.hasSuffix("/Claude.app/Contents/MacOS/Claude") }

    static func dataDirArgument(_ p: ProcInfo) -> String? {
        p.args.first { $0.hasPrefix(userDataFlag) }.map { String($0.dropFirst(userDataFlag.count)) }
    }

    public init(_ input: [ProcInfo], windowsRoot: String? = nil) {
        self.windowsRoot = windowsRoot
        let procs = input.map { p -> ProcInfo in
            var p = p
            while p.path.contains("//") { p.path = p.path.replacingOccurrences(of: "//", with: "/") }
            return p
        }
        processes = procs
        var par: [Int32: Int32] = [:]
        for p in procs where p.parentPID > 1 { par[p.pid] = p.parentPID }
        parent = par
        var found: [LiveWindow] = []
        for p in procs where Self.isBrowserProcess(p) {
            guard let dir = Self.dataDirArgument(p) else { continue }
            let exact = p.args.dropFirst().elementsEqual(["\(Self.userDataFlag)\(dir)"])
            found.append(LiveWindow(pid: p.pid, dataDir: dir, isExact: exact))
        }
        windows = found
        browserByPID = Dictionary(found.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        mainBrowserPIDs = Set(procs.filter { Self.isBrowserProcess($0) && Self.dataDirArgument($0) == nil }.map(\.pid))
    }

    public var hasWindows: Bool { windows.isEmpty == false }

    /// The data dir of the extra window this process belongs to, or nil for the main window's.
    /// Belonging is decided by the process tree first: a window's browser process and everything
    /// below it belong to that window whatever flag they carry, and everything below the main
    /// window's browser process belongs to the main window. Only a process with no such link (a
    /// helper reparented after its browser process went away) is placed by its flag.
    public func windowDataDir(of p: ProcInfo) -> String? {
        if let w = browserByPID[p.pid] { return w.dataDir }
        if mainBrowserPIDs.contains(p.pid) { return nil }
        var cur = p.pid
        for _ in 0..<16 {
            guard let up = parent[cur] else { break }
            if let w = browserByPID[up] { return w.dataDir }
            if mainBrowserPIDs.contains(up) { return nil }
            cur = up
        }
        // The main window's helpers carry the default folder flag too, so a flag alone proves nothing:
        // it names an extra window only if a live extra window uses that folder, or it sits in the
        // windows folder (a helper left behind by a window whose browser process is gone).
        if let dir = Self.dataDirArgument(p), isExtraWindowFolder(dir) { return dir }
        return nil
    }

    func isExtraWindowFolder(_ dir: String) -> Bool {
        if browserByPID.values.contains(where: { $0.dataDir == dir }) { return true }
        guard let windowsRoot else { return false }
        return ParallelWindows.isDirectChild(ParallelWindows.dirString(URL(filePath: dir)), of: windowsRoot)
    }

    /// The main window's browser process: the Claude executable with no `--user-data-dir`.
    public var mainPID: Int32? {
        processes.first { Self.isBrowserProcess($0) && Self.dataDirArgument($0) == nil }?.pid
    }

    /// The process to signal for the window using this folder: exact arguments only.
    public func exactWindowPID(dataDir: String) -> Int32? {
        windows.first { $0.isExact && $0.dataDir == dataDir }?.pid
    }

    /// Every process of that window (browser, helpers).
    public func processes(ofWindow dataDir: String) -> [ProcInfo] {
        processes.filter { windowDataDir(of: $0) == dataDir }
    }

    /// Our windows: exact, and inside `windowsRoot`.
    public func ourWindows(in paths: Paths) -> [LiveWindow] {
        let root = ParallelWindows.dirString(paths.windowsRoot)
        return windows.filter { $0.isExact && ParallelWindows.isDirectChild($0.dataDir, of: root) }
    }
}

// MARK: Rules

public enum ParallelWindows {
    /// Extra windows next to the main one.
    public static let maxExtraWindows = 3

    /// The `claude_desktop_config.json` preferences that start background jobs; the settings script
    /// switches them off in an extra window (to false).
    public static let backgroundJobKeys = ["ccdScheduledTasksEnabled", "coworkScheduledTasksEnabled",
                                           "ccRemoteControlDefaultEnabled", "keepAwakeEnabled", "ccAutoArchiveOnPrClose"]
    /// Whole-number preferences that start a background job unless they are 0 (the auto-archive sweeper's
    /// idle limit in days). The keep-awake options are not jobs: they only hold the Mac awake while a
    /// session in that window works.
    public static let backgroundJobDayKeys = ["ccAutoArchiveInactiveDays"]

    /// Every background-job preference in the window's own config is explicitly off: false, or 0 days.
    public static func backgroundJobsOff(in dataDir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dataDir.appending(path: "claude_desktop_config.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let prefs = root["preferences"] as? [String: Any] else { return false }
        return backgroundJobKeys.allSatisfy { (prefs[$0] as? Bool) == false }
            && backgroundJobDayKeys.allSatisfy { isZeroNumber(prefs[$0]) }
    }

    /// A JSON number 0 (not the boolean false, which Foundation also reads as an NSNumber).
    static func isZeroNumber(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber, String(cString: n.objCType) != "c" else { return false }
        return n.intValue == 0
    }

    /// Account ids name folders, so only uuid-like text is accepted.
    public static func isValidAccountID(_ id: String) -> Bool {
        guard id.count >= 8, id.count <= 64 else { return false }
        return id.allSatisfy { $0.isHexDigit || $0 == "-" } && id.hasPrefix("-") == false
    }

    static func dirString(_ url: URL) -> String {
        var s = url.standardizedFileURL.path(percentEncoded: false)
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func isDirectChild(_ path: String, of root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        let rest = path.dropFirst(prefix.count)
        return rest.isEmpty == false && rest.contains("/") == false
    }

    /// The command line of an extra window, for `open -n -a <app> --args …`.
    public static func launchArguments(dataDir: URL) -> [String] {
        ["\(ClaudeProcessMap.userDataFlag)\(dirString(dataDir))"]
    }

    /// The pinned rules for opening a window. `openElsewhere` are the accounts live in other extra
    /// windows (not counting `account` itself, which the caller handles as "already open").
    public static func checkOpen(account: String, mainAccount: String?, openWindows: [String]) throws {
        guard isValidAccountID(account) else { throw WindowError.invalidAccount(account) }
        if let mainAccount, mainAccount == account { throw WindowError.accountIsMain(account) }
        if openWindows.contains(account) { throw WindowError.accountInWindow(account) }
        if openWindows.count >= maxExtraWindows { throw WindowError.capReached(maxExtraWindows) }
    }

    /// The accounts live in our extra windows right now.
    public static func openAccounts(procs: [ProcInfo], paths: Paths) -> [String] {
        ClaudeProcessMap(procs, windowsRoot: dirString(paths.windowsRoot)).ourWindows(in: paths).map { URL(filePath: $0.dataDir).lastPathComponent }
    }

    /// True when `account` is signed in and running in an extra window: the main window may not
    /// switch to it.
    public static func isOpenInWindow(_ account: String, procs: [ProcInfo], paths: Paths) -> Bool {
        openAccounts(procs: procs, paths: paths).contains(account)
    }
}
