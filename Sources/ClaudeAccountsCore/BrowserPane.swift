import Foundation

/// Diagnostics for Claude's in-app browser pane, which asks "Import cookies from your browser".
/// Read only: two preference values from claude_desktop_config.json (no other key is read out) and
/// the shared partition's cookie row count. Nothing here writes.
public enum BrowserPane {
    public static func configURL(_ p: Paths) -> URL { p.claudeUserData.appending(path: "claude_desktop_config.json") }
    public static func cookiesURL(_ p: Paths) -> URL {
        p.claudeUserData.appending(path: "Partitions/launch-preview-cowork-shared/Cookies")
    }

    public struct State: Sendable, Equatable {
        public var prompt: String?
        public var storage: String?
        public var cookies: Int?
    }

    public static func read(_ p: Paths) -> State {
        var prompt: String?, storage: String?
        if let data = try? Data(contentsOf: configURL(p)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prefs = obj["preferences"] as? [String: Any] {
            prompt = prefs["launchChromeImportPrompt"] as? String
            storage = prefs["launchPreviewStorage"] as? String
        }
        var cookies: Int?
        if let db = try? SQLiteDB(cookiesURL(p), mode: .readOnlyImmutable),
           let n = (try? db.query("SELECT count(*) FROM cookies"))?.first?.first?.int {
            cookies = Int(n)
        }
        return State(prompt: prompt, storage: storage, cookies: cookies)
    }

    /// `browser-pane: prompt=done storage=shared cookies=3017`
    public static func line(_ s: State) -> String {
        "browser-pane: prompt=\(s.prompt ?? "-") storage=\(s.storage ?? "-") cookies=\(s.cookies.map(String.init) ?? "-")"
    }
}
