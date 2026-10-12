import Foundation

/// The app's own store: accounts.json, state.json, slots, backups and switch.log.
/// Directories are 0700, files 0600, every write atomic.
public final class AccountStore: @unchecked Sendable {
    public let paths: Paths
    public let keepBackups: Int
    private let lock = NSRecursiveLock()

    public init(paths: Paths, keepBackups: Int = 10) {
        self.paths = paths
        self.keepBackups = keepBackups
    }

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

    public func ensureLayout() throws {
        try FileOps.ensureDirectory(paths.storeRoot)
        try FileOps.ensureDirectory(paths.slotsDir)
        try FileOps.ensureDirectory(paths.backupsDir)
        try FileOps.ensureDirectory(paths.chromeBackupsDir)
    }

    // MARK: Accounts

    public func accounts() -> [Account] {
        lock.withLock {
            guard let data = try? Data(contentsOf: paths.accountsFile) else { return [] }
            return (try? Self.decoder.decode([Account].self, from: data)) ?? []
        }
    }

    public func account(_ id: String) -> Account? { accounts().first { $0.id == id } }

    public func saveAccounts(_ list: [Account]) throws {
        try lock.withLock {
            try ensureLayout()
            try FileOps.writeAtomically(try Self.encoder.encode(list), to: paths.accountsFile)
        }
    }

    @discardableResult
    public func updateAccounts<T>(_ body: (inout [Account]) throws -> T) throws -> T {
        try lock.withLock {
            var list = accounts()
            let r = try body(&list)
            try saveAccounts(list)
            return r
        }
    }

    /// Copies `url` (file or directory) to `<url>.prev` before it is overwritten.
    public func keepPrevious(_ url: URL) throws {
        let prev = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".prev")
        if FileOps.isDirectory(url) {
            try FileOps.replaceDirectory(prev, withCopyOf: url, privateMode: true)
        } else if FileOps.exists(url) {
            try FileOps.copyAtomically(url, to: prev)
        }
    }

    /// Adds an account if it isn't known yet; returns it either way.
    @discardableResult
    public func register(_ id: String, label: String?, now: Date) throws -> Account {
        try updateAccounts { list in
            if let i = list.firstIndex(where: { $0.id == id }) {
                if let label, label.isEmpty == false {
                    list[i].label = label
                    list[i].needsLabel = nil
                }
                return list[i]
            }
            let used = Set(list.map(\.colorIndex))
            let color = (0..<AccountPalette.count).first { used.contains($0) == false } ?? list.count % AccountPalette.count
            var a = Account(id: id, label: label ?? "Unnamed account", colorIndex: color, createdAt: now)
            if label == nil || label?.isEmpty == true { a.label = "Unnamed account"; a.needsLabel = true }
            list.append(a)
            return a
        }
    }

    public func setLabel(_ id: String, _ label: String) throws {
        try updateAccounts { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { throw EngineError.unknownAccount(id) }
            list[i].label = label
            list[i].needsLabel = nil
        }
    }

    /// Forgets an account and deletes its slot. Its login stays valid on the server.
    public func remove(_ id: String) throws {
        try updateAccounts { list in list.removeAll { $0.id == id } }
        let dir = paths.slotsDir.appending(path: id, directoryHint: .isDirectory)
        try FileOps.removeDirectory(dir)
    }

    // MARK: State

    public func state() -> StoreState {
        lock.withLock {
            guard let data = try? Data(contentsOf: paths.stateFile) else { return StoreState() }
            return (try? Self.decoder.decode(StoreState.self, from: data)) ?? StoreState()
        }
    }

    @discardableResult
    public func updateState<T>(_ body: (inout StoreState) throws -> T) throws -> T {
        try lock.withLock {
            var s = state()
            let r = try body(&s)
            try ensureLayout()
            try FileOps.writeAtomically(try Self.encoder.encode(s), to: paths.stateFile)
            return r
        }
    }

    // MARK: Log

    /// Appends one line: steps and outcomes only, never values.
    public func log(_ message: String, now: Date = Date()) {
        lock.withLock {
            try? ensureLayout()
            let url = paths.switchLog
            if let size = FileOps.size(url), size > 1_000_000 {
                let old = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            let line = "\(Self.logStamp.string(from: now)) \(message)\n"
            if FileOps.exists(url) == false {
                FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            }
        }
    }

    nonisolated(unsafe) static let logStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    // MARK: Backups

    static let backupStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    public func backupDir(_ id: String) -> URL {
        paths.backupsDir.appending(path: id, directoryHint: .isDirectory)
    }

    public func chromeBackupDir(_ id: String) -> URL {
        paths.chromeBackupsDir.appending(path: id, directoryHint: .isDirectory)
    }

    /// A fresh, unused backup id for `now` (unique across desktop and Chrome backups).
    public func newBackupID(now: Date) -> String {
        lock.withLock {
            var id = Self.backupStamp.string(from: now)
            var n = 1
            while FileOps.exists(backupDir(id)) || FileOps.exists(chromeBackupDir(id)) {
                n += 1
                id = Self.backupStamp.string(from: now) + "-\(n)"
            }
            return id
        }
    }

    /// Copies live `Cookies` and `config.json` into a new desktop backup. Call only while Claude is
    /// closed. Files are copied and fsynced first; the manifest (with their sizes) is written last,
    /// so a backup without a manifest is incomplete and never used.
    public func makeBackup(id preset: String? = nil, reason: String, from: String?, to: String?,
                           protecting: Set<String> = [], now: Date) throws -> BackupManifest {
        try lock.withLock {
            try ensureLayout()
            let id = preset ?? newBackupID(now: now)
            let dir = backupDir(id)
            try FileOps.ensureDirectory(dir)
            var sizes: [String: Int] = [:]
            if FileOps.exists(paths.liveCookies) {
                let dst = dir.appending(path: "Cookies")
                try FileOps.copyAtomically(paths.liveCookies, to: dst)
                try FileOps.fsync(dst)
                sizes["Cookies"] = FileOps.size(dst)
            }
            let cfg = dir.appending(path: "config.json")
            try FileOps.copyAtomically(paths.liveConfig, to: cfg)
            try FileOps.fsync(cfg)
            sizes["config.json"] = FileOps.size(cfg)
            var m = BackupManifest(id: id, createdAt: now, reason: reason, fromAccount: from, toAccount: to,
                                   hasDesktop: true, hasChrome: false)
            m.sizes = sizes
            try writeManifest(m, in: dir)
            try rotate(paths.backupsDir, protecting: protecting.union([id]))
            return m
        }
    }

    /// Records the Chrome backup that goes with a desktop backup, so a rollback restores both.
    public func link(chromeBackup cid: String, toBackup id: String) throws {
        try lock.withLock {
            guard var m = manifest(id) else { throw EngineError.missing("backup \(id)") }
            m.chromeBackupID = cid
            try writeManifest(m, in: backupDir(id))
        }
    }

    /// Copies the live Chrome claude.ai rows and extension settings into a new Chrome backup, kept
    /// apart from desktop backups with its own rotation. Chrome must be closed.
    public func makeChromeBackup(reason: String, chromeAccount: String?, now: Date) throws -> BackupManifest {
        try lock.withLock {
            try ensureLayout()
            let id = newBackupID(now: now)
            let dir = chromeBackupDir(id)
            try FileOps.ensureDirectory(dir)
            var sizes: [String: Int] = [:]
            if FileOps.exists(paths.chromeCookies) {
                let rows = dir.appending(path: "claude-cookies.sqlite")
                try CookieDB.exportFamilyRows(from: paths.chromeCookies, to: rows)
                try FileOps.fsync(rows)
                sizes["claude-cookies.sqlite"] = FileOps.size(rows)
            }
            if FileOps.isDirectory(paths.chromeExtensionSettings) {
                try FileOps.replaceDirectory(dir.appending(path: "extension-settings", directoryHint: .isDirectory),
                                             withCopyOf: paths.chromeExtensionSettings, privateMode: true)
            }
            var m = BackupManifest(id: id, createdAt: now, reason: reason, fromAccount: chromeAccount, toAccount: nil,
                                   hasDesktop: false, hasChrome: true)
            m.chromeAccount = chromeAccount
            m.sizes = sizes
            try writeManifest(m, in: dir)
            var protect: Set<String> = [id]
            if case .backup(let p) = state().pendingChrome { protect.insert(p) }
            for b in backups() { if let c = b.chromeBackupID { protect.insert(c) } }
            try rotate(paths.chromeBackupsDir, protecting: protect)
            return m
        }
    }

    func writeManifest(_ m: BackupManifest, in dir: URL) throws {
        let url = dir.appending(path: "manifest.json")
        try FileOps.writeAtomically(try Self.encoder.encode(m), to: url)
        try FileOps.fsync(url)
    }

    public func manifest(_ id: String) -> BackupManifest? { readManifest(backupDir(id)) }
    public func chromeManifest(_ id: String) -> BackupManifest? { readManifest(chromeBackupDir(id)) }

    func readManifest(_ dir: URL) -> BackupManifest? {
        guard let data = try? Data(contentsOf: dir.appending(path: "manifest.json")) else { return nil }
        return try? Self.decoder.decode(BackupManifest.self, from: data)
    }

    /// The manifest exists and every file it lists is present with the recorded size.
    public func isVerified(_ id: String) -> Bool {
        guard let m = manifest(id), let sizes = m.sizes, sizes["config.json"] != nil else { return false }
        return sizes.allSatisfy { name, size in FileOps.size(backupDir(id).appending(path: name)) == size }
    }

    /// Desktop backups, newest first. Incomplete ones (no manifest) are not listed.
    public func backups() -> [BackupManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.backupsDir.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasPrefix(".") == false }.sorted(by: >).compactMap { manifest($0) }
    }

    public func chromeBackups() -> [BackupManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.chromeBackupsDir.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasPrefix(".") == false }.sorted(by: >).compactMap { chromeManifest($0) }
    }

    /// Keeps the newest `keepBackups` in `dir`; never touches another directory.
    func rotate(_ dir: URL, protecting given: Set<String>) throws {
        var protecting = given
        if let f = state().inFlight {
            protecting.insert(f.backupID)
            if let p = f.preBackupID { protecting.insert(p) }
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix(".") == false }.sorted(by: >)
        for name in names.dropFirst(keepBackups) where protecting.contains(name) == false {
            try FileOps.removeDirectory(dir.appending(path: name, directoryHint: .isDirectory))
        }
    }

    // MARK: Session sync label map

    /// Writes `~/.claude/session-sync/accounts.json` (uuid → label) when that directory exists.
    public func writeSyncLabels() {
        guard FileOps.isDirectory(paths.sessionSync) else { return }
        var map: [String: String] = [:]
        for a in accounts() where a.needsLabel != true { map[a.id] = a.label }
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys]) else { return }
        if let existing = try? Data(contentsOf: paths.syncAccountsFile), existing == data { return }
        try? FileOps.writeAtomically(data, to: paths.syncAccountsFile, mode: 0o644)
    }
}

/// Number of avatar tints; the app maps indexes to system colours.
public enum AccountPalette {
    public static let count = 8
}
