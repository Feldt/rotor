import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper. Read-only opens use `immutable=1` so a live database another process
/// holds is never locked or written (no -journal / -wal is created).
final class SQLiteDB {
    private var handle: OpaquePointer?

    enum Mode { case readOnlyImmutable, readWrite, create }

    init(_ url: URL, mode: Mode) throws {
        let path = url.path(percentEncoded: false)
        var flags: Int32 = SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let name: String
        switch mode {
        case .readOnlyImmutable:
            flags |= SQLITE_OPEN_READONLY
            name = "file:\(SQLiteDB.uriEscape(path))?mode=ro&immutable=1"
        case .readWrite:
            flags |= SQLITE_OPEN_READWRITE
            name = "file:\(SQLiteDB.uriEscape(path))"
        case .create:
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            name = "file:\(SQLiteDB.uriEscape(path))"
        }
        if mode != .create, FileOps.exists(url) == false { throw EngineError.missing(url.lastPathComponent) }
        let rc = sqlite3_open_v2(name, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw EngineError.sqlite("\(url.lastPathComponent): \(msg)")
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    static func uriEscape(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    static func uri(_ url: URL, readOnly: Bool) -> String {
        let p = uriEscape(url.path(percentEncoded: false))
        return readOnly ? "file:\(p)?mode=ro&immutable=1" : "file:\(p)"
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw EngineError.sqlite(msg)
        }
    }

    enum Value { case int(Int64), text(String), null }

    /// Runs a query and returns rows of non-blob values. Callers only select metadata columns.
    func query(_ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw EngineError.sqlite(errorMessage) }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw EngineError.sqlite(errorMessage) }
            var row: [Value] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func run(_ sql: String, _ params: [Value] = []) throws {
        _ = try query(sql, params)
    }
}

extension SQLiteDB.Value {
    var int: Int64? { if case .int(let v) = self { v } else { nil } }
    var text: String? { if case .text(let v) = self { v } else { nil } }
}
