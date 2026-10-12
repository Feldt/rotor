import Foundation

/// Atomic, permission-aware file helpers. Every write goes to a temp file in the destination's
/// directory and is renamed into place, so a crash never leaves a half-written file.
public enum FileOps {
    static var fm: FileManager { .default }

    public static func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path(percentEncoded: false))
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }

    public static func size(_ url: URL) -> Int? {
        (try? fm.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? Int
    }

    public static func modified(_ url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    /// Creates `url` and any missing parents. With `privateMode`, every created level under the
    /// store gets 0700.
    public static func ensureDirectory(_ url: URL, privateMode: Bool = true) throws {
        if isDirectory(url) {
            if privateMode { try setMode(url, 0o700) }
            return
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: privateMode ? [.posixPermissions: 0o700] : nil)
        if privateMode { try setMode(url, 0o700) }
    }

    public static func setMode(_ url: URL, _ mode: Int) throws {
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
    }

    public static func mode(_ url: URL) -> Int? {
        ((try? fm.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? NSNumber)?.intValue
    }

    static func tempSibling(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))")
    }

    /// Writes data atomically with mode 0600 (or `mode`).
    public static func writeAtomically(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        let tmp = tempSibling(of: url)
        guard fm.createFile(atPath: tmp.path(percentEncoded: false), contents: data,
                            attributes: [.posixPermissions: mode]) else {
            throw EngineError.io("could not write \(url.lastPathComponent)")
        }
        try setMode(tmp, mode)
        try replace(url, with: tmp)
    }

    /// Copies a file atomically: copy to a temp sibling of the destination, chmod, rename.
    public static func copyAtomically(_ src: URL, to dst: URL, mode: Int = 0o600) throws {
        guard exists(src) else { throw EngineError.missing(src.lastPathComponent) }
        let tmp = tempSibling(of: dst)
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        try setMode(tmp, mode)
        try replace(dst, with: tmp)
    }

    /// rename(2) `tmp` over `dst`; atomic within one volume.
    static func replace(_ dst: URL, with tmp: URL) throws {
        if rename(tmp.path(percentEncoded: false), dst.path(percentEncoded: false)) != 0 {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw EngineError.io("rename to \(dst.lastPathComponent) failed: \(err)")
        }
    }

    /// Replaces directory `dst` with a copy of `src`. The copy is made beside `dst` first, the old
    /// directory is moved aside, the new one renamed in, and the old one removed.
    public static func replaceDirectory(_ dst: URL, withCopyOf src: URL, privateMode: Bool) throws {
        let parent = dst.deletingLastPathComponent()
        try ensureDirectory(parent, privateMode: privateMode)
        let tmp = tempSibling(of: dst)
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        if privateMode { try chmodTree(tmp) }
        let old = tempSibling(of: dst)
        if exists(dst) { try fm.moveItem(at: dst, to: old) }
        do {
            try fm.moveItem(at: tmp, to: dst)
        } catch {
            if exists(old) { try? fm.moveItem(at: old, to: dst) }
            throw error
        }
        if exists(old) { try fm.removeItem(at: old) }
    }

    /// Removes a directory by moving it aside first so the live name disappears in one step.
    public static func removeDirectory(_ url: URL) throws {
        guard exists(url) else { return }
        let old = tempSibling(of: url)
        try fm.moveItem(at: url, to: old)
        try fm.removeItem(at: old)
    }

    public static func removeIfPresent(_ url: URL) throws {
        if exists(url) { try fm.removeItem(at: url) }
    }

    /// Directories 0700, files 0600.
    public static func chmodTree(_ url: URL) throws {
        try setMode(url, isDirectory(url) ? 0o700 : 0o600)
        guard isDirectory(url), let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in e {
            try setMode(item, isDirectory(item) ? 0o700 : 0o600)
        }
    }

    /// Flushes a file's data to disk.
    public static func fsync(_ url: URL) throws {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        try h.synchronize()
    }

    /// Reads at most the last `maxBytes` of a file.
    public static func tail(_ url: URL, maxBytes: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        return try? h.readToEnd()
    }
}
