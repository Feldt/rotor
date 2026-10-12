import AppKit
import Darwin
import Foundation

public struct ProcInfo: Sendable, Equatable {
    public var pid: Int32
    public var path: String
    /// The full argv (argv[0] first), read for Claude.app processes only; empty when unknown.
    public var args: [String]
    /// Parent pid, read for Claude.app processes only; 0 when unknown.
    public var parentPID: Int32
    public init(pid: Int32, path: String, args: [String] = [], parentPID: Int32 = 0) {
        self.pid = pid
        self.path = path
        self.args = args
        self.parentPID = parentPID
    }
}

/// Lists running processes by executable path. Injected so tests can simulate any process table.
public protocol ProcessProbe: Sendable {
    func processes() -> [ProcInfo]
}

/// Asks apps to quit and opens them. Injected so tests never touch real apps.
public protocol AppController: Sendable {
    func isRunning(bundleID: String) async -> Bool
    /// A polite quit request (the app may show its own dialog or refuse). Never a force-kill.
    func requestQuit(bundleID: String) async
    func open(appAt url: URL) async throws
    /// Opens a URL in the given app (e.g. claude.ai/login in Chrome).
    func open(url: URL, inAppAt app: URL) async throws
    /// True while the app has a normal on-screen window (its quit dialog is one).
    func hasVisibleWindow(bundleID: String) async -> Bool

    // Per-instance operations, for when extra windows (other processes of the same bundle) run.
    /// A polite quit (Apple event) of exactly this process. Never a force-kill.
    func requestQuit(pid: Int32) async
    /// SIGTERM to exactly this process, which is how an extra window is closed. Never SIGKILL.
    func signalTerminate(pid: Int32) async
    func hasVisibleWindow(pid: Int32) async -> Bool
    /// `open -n -a <app> [--args …]`: always a new instance, even while others run.
    func launchNewInstance(appAt url: URL, arguments: [String]) async throws
}

extension AppController {
    public func requestQuit(pid: Int32) async {}
    public func signalTerminate(pid: Int32) async {}
    public func hasVisibleWindow(pid: Int32) async -> Bool { false }
    public func launchNewInstance(appAt url: URL, arguments: [String]) async throws {
        throw WindowError.launchUnsupported
    }
}

/// Time source, so tests can run two-minute waits instantly.
public protocol Ticker: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
    /// A blocking wait for code that runs on its own thread (never on the cooperative pool).
    func sleepBlocking(seconds: Double)
}

public struct SystemTicker: Ticker {
    public init() {}
    public func now() -> Date { Date() }
    public func sleepBlocking(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}

/// libproc-based process listing. Reads executable paths only.
public struct SystemProcessProbe: ProcessProbe {
    public init() {}
    public func processes() -> [ProcInfo] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        var out: [ProcInfo] = []
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            if len > 0 {
                let path = String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                // Arguments and parent are only needed to tell Claude's windows apart.
                if path.contains("/Claude.app/Contents/") {
                    out.append(ProcInfo(pid: pid, path: path, args: Self.arguments(of: pid), parentPID: Self.parent(of: pid)))
                } else {
                    out.append(ProcInfo(pid: pid, path: path))
                }
            }
        }
        return out
    }

    static func parent(of pid: pid_t) -> Int32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return Int32(info.pbi_ppid)
    }

    /// argv via `sysctl(KERN_PROCARGS2)`. Empty when the process is gone or unreadable.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        return parseProcArgs(Array(bytes.prefix(size)))
    }

    /// Layout: Int32 argc, exec path, NUL padding, argc NUL-terminated arguments, then the environment.
    static func parseProcArgs(_ b: [UInt8]) -> [String] {
        guard b.count > 4 else { return [] }
        let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 }
        while i < b.count, b[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc, i < b.count {
            var j = i
            while j < b.count, b[j] != 0 { j += 1 }
            out.append(String(decoding: b[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }
}

/// NSRunningApplication / NSWorkspace. `terminate()` sends the standard quit Apple event.
public struct SystemAppController: AppController {
    public init() {}

    public func isRunning(bundleID: String) async -> Bool {
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.isTerminated == false }
        }
    }

    public func requestQuit(bundleID: String) async {
        await MainActor.run {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                _ = app.terminate()
            }
        }
    }

    public func hasVisibleWindow(bundleID: String) async -> Bool {
        let pids = await MainActor.run {
            Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        }
        guard pids.isEmpty == false,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid) else { return false }
            return (w[kCGWindowLayer as String] as? Int) == 0
        }
    }

    public func open(appAt url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    public func open(url: URL, inAppAt app: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
    }

    public func requestQuit(pid: Int32) async {
        await MainActor.run { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
    }

    /// SIGTERM, exactly one pid. The caller has matched the pid by its exact arguments.
    public func signalTerminate(pid: Int32) async {
        guard pid > 1 else { return }
        _ = kill(pid, SIGTERM)
    }

    public func hasVisibleWindow(pid: Int32) async -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0
        }
    }

    /// `/usr/bin/open -n -a <app> [--args …]`. `open` returns once LaunchServices has started the app.
    public func launchNewInstance(appAt url: URL, arguments: [String]) async throws {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/open")
        var args = ["-n", "-a", url.path(percentEncoded: false)]
        if arguments.isEmpty == false { args += ["--args"] + arguments }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw WindowError.launchFailed("could not run open") }
        while p.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        if p.terminationStatus != 0 { throw WindowError.launchFailed("open exited \(p.terminationStatus)") }
    }
}

/// Makes every "Claude" call about the MAIN window only, while extra windows (other processes of
/// the same bundle) are running. Without it, `NSRunningApplication.terminate()` on the bundle id
/// would quit every window, `isRunning(bundleID:)` would stay true after the main window quit, and
/// `openApplication` would just activate an extra window instead of starting the main one.
/// With no extra window running it passes every call straight through, so single-window behaviour
/// is exactly as before.
public struct MainScopedController: AppController {
    public let base: AppController
    public let probe: ProcessProbe

    public init(base: AppController, probe: ProcessProbe) {
        self.base = base
        self.probe = probe
    }

    private func windowedMap(for bundleID: String) -> ClaudeProcessMap? {
        guard bundleID == Paths.claudeBundleID else { return nil }
        let m = ClaudeProcessMap(probe.processes())
        return m.hasWindows ? m : nil
    }

    public func isRunning(bundleID: String) async -> Bool {
        guard let m = windowedMap(for: bundleID) else { return await base.isRunning(bundleID: bundleID) }
        return m.mainPID != nil
    }

    public func requestQuit(bundleID: String) async {
        guard let m = windowedMap(for: bundleID) else { return await base.requestQuit(bundleID: bundleID) }
        if let pid = m.mainPID { await base.requestQuit(pid: pid) }
    }

    public func hasVisibleWindow(bundleID: String) async -> Bool {
        guard let m = windowedMap(for: bundleID) else { return await base.hasVisibleWindow(bundleID: bundleID) }
        guard let pid = m.mainPID else { return false }
        return await base.hasVisibleWindow(pid: pid)
    }

    public func open(appAt url: URL) async throws {
        if url.lastPathComponent == "Claude.app", windowedMap(for: Paths.claudeBundleID) != nil {
            try await base.launchNewInstance(appAt: url, arguments: [])
        } else {
            try await base.open(appAt: url)
        }
    }

    public func open(url: URL, inAppAt app: URL) async throws { try await base.open(url: url, inAppAt: app) }
    public func requestQuit(pid: Int32) async { await base.requestQuit(pid: pid) }
    public func signalTerminate(pid: Int32) async { await base.signalTerminate(pid: pid) }
    public func hasVisibleWindow(pid: Int32) async -> Bool { await base.hasVisibleWindow(pid: pid) }
    public func launchNewInstance(appAt url: URL, arguments: [String]) async throws {
        try await base.launchNewInstance(appAt: url, arguments: arguments)
    }
}

/// Runs the settings copy that makes an extra window's settings match the main window's.
public protocol WindowSettingsSync: Sendable {
    /// Returns nil on success, or a short failure description. Only called while the window is closed.
    func apply(from main: URL, to window: URL) async -> String?
}

public struct PythonWindowSettingsSync: WindowSettingsSync {
    let script: URL
    let timeout: Double
    public init(script: URL, timeout: Double = 60) {
        self.script = script
        self.timeout = timeout
    }

    /// The script in the app bundle's Resources, else `CLAUDE_ACCOUNTS_SETTINGS_SCRIPT`, else the repo copy.
    public static func defaultScript(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let r = Bundle.main.resourceURL?.appending(path: "sync-window-settings.py"), FileOps.exists(r) { return r }
        if let v = environment["CLAUDE_ACCOUNTS_SETTINGS_SCRIPT"], v.isEmpty == false {
            return URL(filePath: (v as NSString).expandingTildeInPath)
        }
        return URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "scripts/sync-window-settings.py")
    }

    public func apply(from main: URL, to window: URL) async -> String? {
        guard FileOps.exists(script) else { return "settings script not found" }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/python3")
        p.arguments = ["-I", script.path(percentEncoded: false),
                       "--from", main.path(percentEncoded: false), "--to", window.path(percentEncoded: false),
                       "--apply", "--extra-window"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "could not start the settings script" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline {
                p.terminate()
                return "settings sync timed out after \(Int(timeout)) s"
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return p.terminationStatus == 0 ? nil : "settings sync exited \(p.terminationStatus)"
    }
}

/// Runs the chat sync pass. Injected so tests never run the real mirror.py.
public protocol SyncRunner: Sendable {
    /// Returns nil on success, or a short failure description.
    func run(arguments: [String], timeout: Double) async -> String?
}

/// Where the app's bundled scripts live. The `rotor` command line tool (and its `claude-accounts` alias) lives inside the
/// app bundle but runs through a `~/.local/bin` symlink, where `Bundle.main` is that symlink's folder: not
/// a bundle, and with no Resources. Only a real `.app` has bundled resources.
public enum AppBundle {
    public static var resources: URL? { resources(bundleURL: Bundle.main.bundleURL, resourceURL: Bundle.main.resourceURL) }

    static func resources(bundleURL: URL, resourceURL: URL?) -> URL? {
        bundleURL.pathExtension == "app" ? resourceURL : nil
    }
}

public struct PythonSyncRunner: SyncRunner {
    /// Runs sync passes: the multi-folder mirror.py, so extra windows join the chat union.
    let script: URL
    /// The copy the launchd agent runs (`~/.claude/session-sync/mirror.py`). `--reload` and `--write-plist`
    /// rewrite and reload that agent, and mirror.py refuses unless the agent's plist runs the very file
    /// it is called as, so they must be run from this path and never from the bundled copy.
    let deployedScript: URL

    public init(script: URL, deployedScript: URL) {
        self.script = script
        self.deployedScript = deployedScript
    }

    /// The runner the app and the CLI use.
    public static func system(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment,
                              resources: URL? = AppBundle.resources) -> PythonSyncRunner {
        PythonSyncRunner(script: defaultScript(paths: paths, environment: environment, resources: resources),
                         deployedScript: paths.mirrorScript)
    }

    /// The multi-folder mirror.py that ships in the app bundle's Resources, else `CLAUDE_ACCOUNTS_MIRROR_SCRIPT`,
    /// else the deployed copy under `~/.claude/session-sync` (what the `rotor` command line tool
    /// uses: `AppBundle.resources` is nil there).
    public static func defaultScript(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment,
                                     resources: URL? = AppBundle.resources) -> URL {
        if let r = resources?.appending(path: "mirror.py"), FileOps.exists(r) { return r }
        if let v = environment["CLAUDE_ACCOUNTS_MIRROR_SCRIPT"], v.isEmpty == false {
            return URL(filePath: (v as NSString).expandingTildeInPath)
        }
        return paths.mirrorScript
    }

    /// Arguments that rewrite or reload the launchd agent.
    static let agentArguments: Set<String> = ["--reload", "--write-plist"]

    /// The file to run for these arguments: the deployed copy for anything that touches the agent, else `script`.
    func script(for arguments: [String]) -> URL {
        arguments.contains { Self.agentArguments.contains($0) } ? deployedScript : script
    }

    public func run(arguments: [String], timeout: Double) async -> String? {
        let script = script(for: arguments)
        guard FileOps.exists(script) else { return "mirror.py not found" }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/python3")
        p.arguments = [script.path(percentEncoded: false)] + arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "could not start mirror.py" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline {
                p.terminate()
                return "mirror.py timed out after \(Int(timeout)) s"
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return p.terminationStatus == 0 ? nil : "mirror.py exited \(p.terminationStatus)"
    }
}

/// For demos and screenshots (`CLAUDE_ACCOUNTS_DRY_CONTROLLER=1`): never quits or opens a real
/// app and reports every app as not running.
public struct DryRunAppController: AppController {
    public init() {}
    public func isRunning(bundleID: String) async -> Bool { false }
    public func requestQuit(bundleID: String) async {}
    public func open(appAt url: URL) async throws {}
    public func open(url: URL, inAppAt app: URL) async throws {}
    public func hasVisibleWindow(bundleID: String) async -> Bool { false }
    public func launchNewInstance(appAt url: URL, arguments: [String]) async throws {}
}

public struct EmptyProcessProbe: ProcessProbe {
    public init() {}
    public func processes() -> [ProcInfo] { [] }
}
