import Foundation

// MARK: Busy chats

/// Heuristic from the transcripts: a chat looks busy when its `.jsonl` was modified in the last
/// `window` seconds and its tail isn't an `end_turn` assistant message followed by a
/// `stop_hook_summary`. Subagent transcripts and sessions not started by the desktop app
/// (`entrypoint` other than `claude-desktop`, e.g. terminal `cli`) are skipped: quitting the app
/// doesn't stop those. Informational only; Claude's own quit dialog is the authoritative signal.
public enum BusyCheck {
    public static func workingChats(projects: URL, now: Date, window: Double = 60) -> Int {
        guard let e = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for case let url as URL in e where url.pathExtension == "jsonl" {
            if url.pathComponents.contains("subagents") { continue }
            guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(mod) < window else { continue }
            let tail = FileOps.tail(url, maxBytes: 64 * 1024) ?? Data()
            if let ep = entrypoint(tail), ep != "claude-desktop" { continue }
            if isIdle(transcriptTail: tail) == false { n += 1 }
        }
        return n
    }

    /// The `entrypoint` recorded in the transcript's last entries, if any.
    public static func entrypoint(_ data: Data) -> String? {
        for line in data.split(separator: UInt8(ascii: "\n")).suffix(40).reversed() {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let ep = obj["entrypoint"] as? String { return ep }
        }
        return nil
    }

    /// Reads only `type`, `subtype` and `message.stop_reason` of the last entries.
    public static func isIdle(transcriptTail data: Data) -> Bool {
        let lines = data.split(separator: UInt8(ascii: "\n")).suffix(40)
        var sawStopSummary = false
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "system", obj["subtype"] as? String == "stop_hook_summary" {
                sawStopSummary = true
                continue
            }
            if type == "assistant" {
                let reason = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                return sawStopSummary && reason == "end_turn"
            }
            if type == "user" { return false }
        }
        return false
    }
}

// MARK: Chat sync status

public struct SyncStatus: Sendable, Equatable {
    public var lastPass: Date?
    public var unwatched: Int
    public var isAvailable: Bool

    public init(lastPass: Date?, unwatched: Int, isAvailable: Bool) {
        self.lastPass = lastPass
        self.unwatched = unwatched
        self.isAvailable = isAvailable
    }

    public func isStale(now: Date) -> Bool {
        guard let lastPass else { return true }
        return now.timeIntervalSince(lastPass) > 600
    }
    public func needsAttention(now: Date) -> Bool { isAvailable && (unwatched > 0 || isStale(now: now)) }

    /// Reads the last line of `sync.log`: `YYYY-MM-DD HH:MM:SS key=value …`.
    public static func read(_ log: URL) -> SyncStatus {
        guard let data = FileOps.tail(log, maxBytes: 8192),
              let text = String(data: data, encoding: .utf8),
              let last = text.components(separatedBy: "\n").last(where: { $0.count > 19 }) else {
            return SyncStatus(lastPass: nil, unwatched: 0, isAvailable: FileOps.exists(log))
        }
        let line: String = last
        let date = LogTime.parse(String(line.prefix(19)))
        var unwatched = 0
        if let r = line.range(of: "unwatched=") {
            unwatched = Int(line[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        return SyncStatus(lastPass: date, unwatched: unwatched, isAvailable: true)
    }
}

/// Chat sync is only surfaced when it's actually broken. "Unwatched" stores are normal (they wait
/// for the 5-minute poll) and never count.
public enum SyncHealth: Sendable, Equatable {
    case ok
    case broken(String)

    public static let agentLabel = "local.rotor.session-sync"

    public static func check(status: SyncStatus, agentLoaded: Bool, claudeRunning: Bool,
                             lastSyncFailed: Bool, now: Date) -> SyncHealth {
        guard status.isAvailable else { return .ok }  // sync not installed on this Mac: no UI
        if agentLoaded == false { return .broken("Sync agent not loaded") }
        if lastSyncFailed { return .broken("Last sync failed") }
        if claudeRunning, let last = status.lastPass, now.timeIntervalSince(last) > 30 * 60 {
            return .broken("Sync stalled")
        }
        if claudeRunning, status.lastPass == nil { return .broken("Sync stalled") }
        return .ok
    }

    /// `launchctl print` exits 0 only for a loaded job. Read only.
    public static func isAgentLoaded(label: String = agentLabel) -> Bool {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); return true }   // unknown: don't claim it's broken
        return p.terminationStatus == 0
    }
}

enum LogTime {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    static func parse(_ s: String) -> Date? { formatter.date(from: s) }
}

// MARK: Launch verification

public enum LaunchVerdict: Sendable, Equatable {
    case success
    case failure(String)
    case pending
}

/// Scans `main.log` lines stamped at or after the launch for the outcome of the login.
public enum LaunchLog {
    public static let successMarkers = ["claude.ai account active and logged in", "obtained new token"]
    public static let failureMarkers = ["not_logged_in", "user is logged out", "names a different account",
                                        "sign-in required", "signin_required", "login_required"]
    public static let midFlowMarker = "account changed mid-flow"
    /// A mid-flow account change fails the verify unless a success for the target follows within this.
    public static let midFlowGrace: TimeInterval = 10

    /// main.log's size now; verify reads only what's written after this.
    public static func offset(_ mainLog: URL) -> UInt64 { UInt64(FileOps.size(mainLog) ?? 0) }

    /// Bytes written to main.log since `offset`. After a rotation (file now smaller), reads the
    /// rotated file (main1.log) from the offset plus the new main.log from the start.
    static func newText(mainLog: URL, from offset: UInt64) -> String {
        func read(_ url: URL, from: UInt64) -> String {
            guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? h.close() }
            try? h.seek(toOffset: from)
            let data = (try? h.readToEnd()) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let size = UInt64(FileOps.size(mainLog) ?? 0)
        if size >= offset { return read(mainLog, from: offset) }
        let rotated = mainLog.deletingLastPathComponent().appending(path: "main1.log")
        return read(rotated, from: offset) + "\n" + read(mainLog, from: 0)
    }

    /// The verdict from main.log lines written since launch.
    /// Success: "claude.ai account active and logged in", "Initialization succeeded … accountId=<target>",
    /// or "obtained new token". Failure: not_logged_in, "User is logged out", "names a different
    /// account", or "account changed mid-flow" not followed by a success within 10 s.
    public static func verdict(text: String, target: String, now: Date) -> LaunchVerdict {
        let targetLower = target.lowercased()
        var midFlowAt: Date?
        var lastTime: Date?
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.count >= 19, let t = LogTime.parse(String(line.prefix(19))) { lastTime = t }
            let lower = line.lowercased()
            if successMarkers.contains(where: { lower.contains($0) }) { return .success }
            if lower.contains("initialization succeeded"), lower.contains("accountid=\(targetLower)") { return .success }
            if let m = failureMarkers.first(where: { lower.contains($0) }) { return .failure(m) }
            if lower.contains(midFlowMarker), midFlowAt == nil { midFlowAt = lastTime ?? now }
        }
        if let at = midFlowAt, now.timeIntervalSince(at) > midFlowGrace { return .failure(midFlowMarker) }
        return .pending
    }

    public static func verdict(mainLog: URL, from offset: UInt64, target: String, now: Date) -> LaunchVerdict {
        verdict(text: newText(mainLog: mainLog, from: offset), target: target, now: now)
    }
}

// MARK: Claude in Chrome's saved account

/// Finds the extension's `accountUuid` in its LevelDB without a LevelDB parser: scan the newest
/// files for the key and take the UUID that follows. Only the UUID is ever returned. Advisory
/// only: compacted tables can hold stale values, so the engine never attributes a login by it.
public enum ExtensionSettings {
    static let key = Array("accountUuid".utf8)
    static let uuidRegex = try! NSRegularExpression(
        pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: [.caseInsensitive])

    public static func accountUuid(in dir: URL) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else { return nil }
        func number(_ n: String) -> Int { Int(n.prefix { $0.isNumber }) ?? -1 }
        // Newest data last: .ldb tables by number, then the .log write-ahead file.
        let ordered = names.filter { $0.hasSuffix(".ldb") }.sorted { number($0) < number($1) }
            + names.filter { $0.hasSuffix(".log") && $0 != "LOG" }.sorted { number($0) < number($1) }
        var found: String?
        for name in ordered {
            guard let data = try? Data(contentsOf: dir.appending(path: name)) else { continue }
            if let u = lastUuid(after: key, in: [UInt8](data)) { found = u }
        }
        return found?.lowercased()
    }

    /// The newest modification time of any file in the extension's LevelDB.
    public static func lastWrite(in dir: URL) -> Date? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        return names.compactMap { FileOps.modified(dir.appending(path: $0)) }.max()
    }

    static func lastUuid(after key: [UInt8], in bytes: [UInt8]) -> String? {
        var result: String?
        var i = 0
        let end = bytes.count - key.count
        while i <= end {
            if bytes[i] == key[0], bytes[i..<(i + key.count)].elementsEqual(key) {
                let window = bytes[(i + key.count)..<min(bytes.count, i + key.count + 96)]
                let s = String(decoding: window.map { $0 < 0x20 || $0 > 0x7e ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
                if let m = uuidRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let r = Range(m.range, in: s) { result = String(s[r]) }
                i += key.count
            } else {
                i += 1
            }
        }
        return result
    }
}

// MARK: Chrome settings (read only)

public enum ChromePreferences {
    /// True when "On startup → Continue where you left off" is on (`session.restore_on_startup == 1`).
    public static func restoresTabs(_ prefs: URL) -> Bool {
        guard let data = try? Data(contentsOf: prefs),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = obj["session"] as? [String: Any] else { return false }
        return (session["restore_on_startup"] as? Int) == 1
    }
}

// MARK: Login health

public enum LoginHealth: Sendable, Equatable {
    case ok(days: Int)
    case expiringSoon(days: Int)
    case expired
    case unknown

    public static func of(_ expires: Date?, now: Date) -> LoginHealth {
        guard let expires else { return .unknown }
        let secs = expires.timeIntervalSince(now)
        if secs <= 0 { return .expired }
        let days = Int((secs / 86_400).rounded(.down))
        return days < 7 ? .expiringSoon(days: days) : .ok(days: days)
    }
}

public enum ClaudeApp {
    public static func version(_ p: Paths) -> String? {
        guard let data = try? Data(contentsOf: p.claudeInfoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}
