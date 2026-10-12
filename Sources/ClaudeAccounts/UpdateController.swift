import AppKit
import ClaudeAccountsCore
import Observation

/// The Settings "About" section: version, status, and Update / Restart into Latest. Checks only
/// when Settings opens; no timers.
@MainActor @Observable
final class UpdateController {
    enum Phase: Equatable { case idle, building, installing, restarting, failed(String) }

    var running = BuildInfo.from(plist: Bundle.main.infoDictionary ?? [:])
    var status: UpdateStatus = .unknown
    var phase: Phase = .idle
    let logURL: URL

    init(storeRoot: URL) {
        logURL = storeRoot.appending(path: "update.log")
    }

    var repo: URL? {
        running.repoPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Rotor")
    }

    func check() {
        if ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_STATE"] != nil {
            running = BuildInfo(commit: "f223157", date: "2026-10-08T15:38:53Z")
            status = .upToDate
            return
        }
        running = BuildInfo.from(plist: Bundle.main.infoDictionary ?? [:])
        status = Updater.status(
            runningPath: Bundle.main.bundleURL.path(percentEncoded: false),
            installedPath: Updater.installedPath.path(percentEncoded: false),
            running: running,
            installed: BuildInfo.from(bundleAt: Updater.installedPath),
            repoHead: repo.flatMap(Updater.repoHead))
    }

    var shortCommit: String { (running.commit ?? "unknown") + (running.dirty ? "+" : "") }

    var needsUpdate: Bool {
        switch status {
        case .updateAvailable, .oldCopy: true
        default: false
        }
    }

    /// Build date, plus for an old copy where it runs from and what's installed.
    var detailTooltip: String {
        var parts: [String] = []
        if let d = running.date.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            parts.append("Built \(d.formatted(date: .abbreviated, time: .shortened))")
        }
        if case .oldCopy(let reason) = status {
            parts.append("Old copy (\(reason)) at \(Bundle.main.bundleURL.path(percentEncoded: false))")
            if let installed = BuildInfo.from(bundleAt: Updater.installedPath)?.commit {
                parts.append("Installed: \(installed)")
            }
        }
        if case .updateAvailable(let head) = status { parts.append("Repo is at \(head)") }
        return parts.joined(separator: "\n")
    }

    /// One click does what's needed: restart into the installed copy if it's already the repo's
    /// HEAD, otherwise rebuild and restart.
    func performUpdate() {
        let installed = BuildInfo.from(bundleAt: Updater.installedPath)
        let head = repo.flatMap(Updater.repoHead)
        if case .oldCopy = status, let installed, Updater.sameCommit(installed.commit, head), installed.dirty == false {
            relaunch()
        } else {
            update()
        }
    }

    var versionLine: String {
        let commit = (running.commit ?? "unknown") + (running.dirty ? "+" : "")
        let date = running.date.flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown"
        return "Version \(commit) · built \(date)"
    }

    var phaseText: String? {
        switch phase {
        case .idle: nil
        case .building: "Building…"
        case .installing: "Installing…"
        case .restarting: "Restarting…"
        case .failed(let m): m
        }
    }

    /// Rebuild from the local repo, install, relaunch. The current version keeps running on failure.
    func update() {
        guard let repo, phase == .idle || phase.isFailed else { return }
        phase = .building
        let script = repo.appending(path: "scripts/build-app.sh").path(percentEncoded: false)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        guard let log = try? FileHandle(forWritingTo: logURL) else { phase = .failed(PanelCopy.updateFailed); return }
        let p = Process()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = ["-lc", "'\(script.replacingOccurrences(of: "'", with: "'\\''"))'"]
        p.currentDirectoryURL = repo
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard data.isEmpty == false else { return }
            try? log.write(contentsOf: data)
            if String(decoding: data, as: UTF8.self).contains("Installing") {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.phase = .installing } }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            try? log.close()
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        self?.relaunch()
                    } else {
                        self?.phase = .failed(PanelCopy.updateFailed)
                    }
                }
            }
        }
        do { try p.run() } catch { phase = .failed(PanelCopy.updateFailed) }
    }

    /// Relaunch from ~/Applications via a tiny detached helper, then quit.
    func relaunch() {
        phase = .restarting
        let dest = Updater.installedPath.path(percentEncoded: false).replacingOccurrences(of: "'", with: "'\\''")
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -a '\(dest)'"]
        try? p.run()
        NSApp.terminate(nil)
    }

    func showLog() { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
}

extension UpdateController.Phase {
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}
