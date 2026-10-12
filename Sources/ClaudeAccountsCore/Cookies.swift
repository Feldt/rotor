import Foundation

/// One cookie row's metadata. Values and encrypted blobs are never selected.
public struct CookieMeta: Sendable, Equatable {
    public var host: String
    public var name: String
    public var expires: Date?
    public var created: Date?
}

/// Chromium cookie timestamps: microseconds since 1601-01-01 UTC.
public enum ChromiumTime {
    static let offset: Double = 11_644_473_600
    public static func date(_ micros: Int64) -> Date? {
        micros <= 0 ? nil : Date(timeIntervalSince1970: Double(micros) / 1_000_000 - offset)
    }
    public static func micros(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + offset) * 1_000_000)
    }
}

/// Metadata-only reads and the claude.ai row copy for Chromium `Cookies` databases.
public enum CookieDB {
    /// Base domains whose rows move with an account in Chrome.
    public static let defaultFamily = ["claude.ai"]
    public static let sessionNames = ["sessionKeyV3", "sessionKey"]

    static func familyPredicate(_ family: [String]) -> (String, [SQLiteDB.Value]) {
        var parts: [String] = []
        var params: [SQLiteDB.Value] = []
        for d in family {
            parts.append("(host_key = ? OR host_key = ? OR host_key LIKE ?)")
            params += [.text(d), .text("." + d), .text("%." + d)]
        }
        return ("(" + parts.joined(separator: " OR ") + ")", params)
    }

    public static func metadata(_ url: URL, family: [String] = defaultFamily) throws -> [CookieMeta] {
        let db = try SQLiteDB(url, mode: .readOnlyImmutable)
        let (pred, params) = familyPredicate(family)
        return try db.query("SELECT host_key, name, expires_utc, creation_utc FROM cookies WHERE \(pred)", params)
            .map { r in
                CookieMeta(host: r[0].text ?? "", name: r[1].text ?? "",
                           expires: r[2].int.flatMap(ChromiumTime.date), created: r[3].int.flatMap(ChromiumTime.date))
            }
    }

    /// True when the database holds a `.claude.ai` row named `name`.
    /// True when the database holds a row with this exact host and name. For "signed in", use
    /// `hasClaudeLogin` (a fresh sign-in has `sessionKey` before any `sessionKeyV3`).
    public static func hasRow(_ url: URL, host: String, name: String) -> Bool {
        guard let db = try? SQLiteDB(url, mode: .readOnlyImmutable),
              let rows = try? db.query("SELECT count(*) FROM cookies WHERE host_key = ? AND name = ?", [.text(host), .text(name)])
        else { return false }
        return (rows.first?.first?.int ?? 0) > 0
    }

    /// Expiry of the login cookie: `sessionKeyV3`'s if present, else `sessionKey`'s.
    public static func sessionExpiry(_ url: URL, names: [String] = sessionNames) -> Date? {
        guard let db = try? SQLiteDB(url, mode: .readOnlyImmutable) else { return nil }
        for name in names {
            let rows = try? db.query("SELECT max(expires_utc) FROM cookies WHERE host_key = '.claude.ai' AND name = ?", [.text(name)])
            if let d = rows?.first?.first?.int.flatMap(ChromiumTime.date) { return d }
        }
        return nil
    }

    public static func columns(_ url: URL) throws -> [String] {
        let db = try SQLiteDB(url, mode: .readOnlyImmutable)
        return try columns(db, schema: "main")
    }

    static func columns(_ db: SQLiteDB, schema: String) throws -> [String] {
        try db.query("PRAGMA \(schema).table_info(cookies)").compactMap { $0[1].text }
    }

    /// The live hosts in the family, for the slot manifest.
    public static func familyHosts(_ url: URL, family: [String] = defaultFamily) throws -> [String] {
        Array(Set(try metadata(url, family: family).map(\.host))).sorted()
    }

    /// Copies every family row from `live` into a new sqlite at `dest` with the same schema. Blobs
    /// are copied inside SQLite and never read by this process. Returns the number of rows copied.
    @discardableResult
    public static func exportFamilyRows(from live: URL, to dest: URL, family: [String] = defaultFamily) throws -> Int {
        try FileOps.ensureDirectory(dest.deletingLastPathComponent())
        let src = try SQLiteDB(live, mode: .readOnlyImmutable)
        let ddl = try src.query(
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND type IN ('table','index') ORDER BY type DESC"
        ).compactMap { $0[0].text }
        guard ddl.contains(where: { $0.contains("CREATE TABLE cookies") }) else {
            throw EngineError.shapeMismatch("no cookies table")
        }
        let cols = try columns(src, schema: "main")
        let tmp = FileOps.tempSibling(of: dest)
        try? FileManager.default.removeItem(at: tmp)
        var count = 0
        do {
            let out = try SQLiteDB(tmp, mode: .create)
            try out.exec("PRAGMA journal_mode = DELETE")
            for stmt in ddl { try out.exec(stmt) }
            try out.run("ATTACH DATABASE ? AS src", [.text(SQLiteDB.uri(live, readOnly: true))])
            try out.exec("INSERT INTO main.meta SELECT * FROM src.meta")
            let (pred, params) = familyPredicate(family)
            let list = cols.map { "\"\($0)\"" }.joined(separator: ",")
            try out.exec("BEGIN")
            try out.run("INSERT INTO main.cookies (\(list)) SELECT \(list) FROM src.cookies WHERE \(pred)", params)
            try out.exec("COMMIT")
            count = Int(try out.query("SELECT count(*) FROM main.cookies").first?.first?.int ?? 0)
            try out.exec("DETACH DATABASE src")
        }
        try FileOps.setMode(tmp, 0o600)
        try FileOps.replace(dest, with: tmp)
        return count
    }

    /// `meta.version` and `meta.last_compatible_version`.
    public static func schemaVersion(_ url: URL) -> (version: String?, lastCompatible: String?) {
        guard let db = try? SQLiteDB(url, mode: .readOnlyImmutable),
              let rows = try? db.query("SELECT key, value FROM meta WHERE key IN ('version','last_compatible_version')")
        else { return (nil, nil) }
        var v: String?, c: String?
        for r in rows {
            let value = r[1].text ?? r[1].int.map(String.init)
            if r[0].text == "version" { v = value } else { c = value }
        }
        return (v, c)
    }

    /// Builds, beside `live`, a temp copy of it whose family rows are replaced by `slot`'s. `live`
    /// is not touched; the caller renames the temp into place (or deletes it). Refuses a slot whose
    /// columns or meta version differ.
    public static func stageImport(from slot: URL, into live: URL, family: [String] = defaultFamily) throws -> URL {
        let liveCols = try columns(live)
        let slotCols = try columns(slot)
        guard Set(liveCols) == Set(slotCols) else { throw EngineError.chromeSchemaChanged }
        let lv = schemaVersion(live), sv = schemaVersion(slot)
        guard lv.version == sv.version, lv.lastCompatible == sv.lastCompatible else { throw EngineError.chromeSchemaChanged }
        return try stage(live) { db in
            try db.run("ATTACH DATABASE ? AS slot", [.text(SQLiteDB.uri(slot, readOnly: true))])
            let (pred, params) = familyPredicate(family)
            let list = liveCols.map { "\"\($0)\"" }.joined(separator: ",")
            try db.exec("BEGIN IMMEDIATE")
            do {
                try db.run("DELETE FROM main.cookies WHERE \(pred)", params)
                try db.exec("INSERT INTO main.cookies (\(list)) SELECT \(list) FROM slot.cookies")
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
            try db.exec("DETACH DATABASE slot")
        }
    }

    /// Like `stageImport`, but the temp copy has the family rows deleted (to seed a new account).
    public static func stageRemove(_ live: URL, family: [String] = defaultFamily) throws -> URL {
        try stage(live) { db in
            let (pred, params) = familyPredicate(family)
            try db.run("DELETE FROM cookies WHERE \(pred)", params)
        }
    }

    static func stage(_ live: URL, _ edit: (SQLiteDB) throws -> Void) throws -> URL {
        let tmp = FileOps.tempSibling(of: live)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: live, to: tmp)
        do {
            try { try edit(try SQLiteDB(tmp, mode: .readWrite)) }()
            try? FileManager.default.removeItem(at: URL(filePath: tmp.path(percentEncoded: false) + "-journal"))
            try FileOps.fsync(tmp)
            return tmp
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Stage, run `beforeCommit` (re-check Chrome is closed; may throw to abort with `live`
    /// untouched), rename into place.
    public static func importFamilyRows(from slot: URL, into live: URL, family: [String] = defaultFamily,
                                        beforeCommit: () throws -> Void = {}) throws {
        let tmp = try stageImport(from: slot, into: live, family: family)
        do {
            try beforeCommit()
            try FileOps.replace(live, with: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Which login a Cookies file holds, by metadata: the session row's name and creation time,
    /// preferring `sessionKeyV3`, else `sessionKey`. Two fingerprints match only when both name and
    /// creation time agree; a V3 fingerprint never matches a `sessionKey` one (unknown, not a match).
    public struct SessionFingerprint: Sendable, Equatable {
        public var name: String
        public var created: Int64
    }

    public static func sessionFingerprint(_ url: URL) -> SessionFingerprint? {
        guard FileOps.exists(url), let db = try? SQLiteDB(url, mode: .readOnlyImmutable) else { return nil }
        for name in sessionNames {
            if let c = (try? db.query("SELECT creation_utc FROM cookies WHERE host_key = '.claude.ai' AND name = ?",
                                      [.text(name)]))?.first?.first?.int {
                return SessionFingerprint(name: name, created: c)
            }
        }
        return nil
    }

    /// True when the database holds a `.claude.ai` `sessionKey` or `sessionKeyV3` row.
    public static func hasClaudeLogin(_ url: URL) -> Bool {
        sessionNames.contains { hasRow(url, host: ".claude.ai", name: $0) }
    }

}
