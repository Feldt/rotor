import Foundation

/// What `build-app.sh` stamps into Info.plist.
public struct BuildInfo: Sendable, Equatable {
    /// Short commit hash, without the dirty suffix.
    public var commit: String?
    public var dirty: Bool
    /// ISO 8601 build time.
    public var date: String?
    /// The repo it was built from.
    public var repoPath: String?

    public init(commit: String?, dirty: Bool = false, date: String?, repoPath: String? = nil) {
        self.commit = commit
        self.dirty = dirty
        self.date = date
        self.repoPath = repoPath
    }

    public static func from(plist: [String: Any]) -> BuildInfo {
        let raw = plist["CAGitCommit"] as? String
        let dirty = raw?.hasSuffix("-dirty") ?? false
        let commit = raw.map { $0.replacingOccurrences(of: "-dirty", with: "") }
        return BuildInfo(commit: commit, dirty: dirty, date: plist["CABuildDate"] as? String,
                         repoPath: plist["CARepoPath"] as? String)
    }

    public static func from(bundleAt url: URL) -> BuildInfo? {
        guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return from(plist: plist)
    }
}

public enum UpdateStatus: Sendable, Equatable {
    case upToDate
    case updateAvailable(head: String)
    case oldCopy(reason: String)
    case unknown

    public var title: String {
        switch self {
        case .upToDate: "Up to Date"
        case .updateAvailable: "Update Available"
        case .oldCopy: "Running an Old Copy"
        case .unknown: "Version Unknown"
        }
    }
}

public enum Updater {
    public static let installedPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications/\(Product.bundleName)", directoryHint: .isDirectory)

    public static func samePath(_ a: String, _ b: String) -> Bool {
        func norm(_ p: String) -> String {
            URL(filePath: p).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return norm(a) == norm(b)
    }

    /// Hashes may differ in length (`git rev-parse --short` vs a full ref); compare by prefix.
    public static func sameCommit(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, a.isEmpty == false, b.isEmpty == false else { return false }
        let n = min(a.count, b.count)
        return a.lowercased().prefix(n) == b.lowercased().prefix(n)
    }

    /// The status for the Settings About section. Pure: every input is injected.
    public static func status(runningPath: String, installedPath: String, running: BuildInfo,
                              installed: BuildInfo?, repoHead: String?) -> UpdateStatus {
        if samePath(runningPath, installedPath) == false {
            return .oldCopy(reason: "not running from ~/Applications")
        }
        if let installed, sameCommit(installed.commit, running.commit) == false,
           let iDate = installed.date, let rDate = running.date, iDate > rDate {
            return .oldCopy(reason: "a newer copy is installed")
        }
        guard running.commit != nil else { return .unknown }
        if let repoHead, sameCommit(repoHead, running.commit) == false {
            return .updateAvailable(head: String(repoHead.prefix(7)))
        }
        return .upToDate
    }

    /// Why Update is unavailable right now (shown as its tooltip), or nil when it can run.
    public static func blockReason(isSwitching: Bool, isAdding: Bool, isChromeSwapping: Bool,
                                   hasInFlight: Bool) -> String? {
        if isSwitching { return "A switch is in progress" }
        if isAdding { return "Adding an account" }
        if isChromeSwapping { return "Chrome is switching" }
        if hasInFlight { return "An interrupted switch needs attention first" }
        return nil
    }

    /// The repo's HEAD commit, read from `.git` without running git. Nil if unreadable.
    public static func repoHead(_ repo: URL) -> String? {
        let git = repo.appending(path: ".git", directoryHint: .isDirectory)
        guard let head = try? String(contentsOf: git.appending(path: "HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard head.hasPrefix("ref: ") else { return head.isEmpty ? nil : head }  // detached
        let ref = String(head.dropFirst(5))
        if let loose = try? String(contentsOf: git.appending(path: ref), encoding: .utf8) {
            let h = loose.trimmingCharacters(in: .whitespacesAndNewlines)
            if h.isEmpty == false { return h }
        }
        guard let packed = try? String(contentsOf: git.appending(path: "packed-refs"), encoding: .utf8) else { return nil }
        for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
            return String(line.split(separator: " ")[0])
        }
        return nil
    }
}
