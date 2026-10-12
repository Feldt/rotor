import Foundation

/// Launch at login through a user LaunchAgent (SMAppService is unverified for ad-hoc builds).
public enum LoginAgent {
    public static let label = "local.rotor.claude-accounts"

    public static func plistURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    public static func plist(executable: String) -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    public static var isInstalled: Bool { FileOps.exists(plistURL()) }

    /// Runs only when the user turns on "Open at login" in the panel.
    public static func install(executable: String) throws {
        let url = plistURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileOps.writeAtomically(plist(executable: executable), to: url, mode: 0o644)
        launchctl(["bootstrap", "gui/\(getuid())", url.path(percentEncoded: false)])
    }

    public static func uninstall() throws {
        let url = plistURL()
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try FileOps.removeIfPresent(url)
    }

    static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
