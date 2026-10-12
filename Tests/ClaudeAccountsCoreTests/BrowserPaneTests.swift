import Foundation
import Testing
@testable import ClaudeAccountsCore

@Suite("Browser pane diagnostics")
struct BrowserPaneTests {
    private func setUp(_ w: FakeWorld, rows: Int) throws {
        let cfg: [String: Any] = ["preferences": ["launchChromeImportPrompt": "done", "launchPreviewStorage": "shared",
                                                  "otherSecretish": "never-read"],
                                  "mcpServers": ["x": ["env": ["TOKEN": "SYNTHETIC-SECRET"]]]]
        try JSONSerialization.data(withJSONObject: cfg).write(to: BrowserPane.configURL(w.paths))
        let exp = Date().addingTimeInterval(86_400)
        try Fixture.makeCookiesDB(BrowserPane.cookiesURL(w.paths),
                                  rows: (0..<rows).map { DummyCookie(host: "site\($0).example", name: "n", blob: "b", expires: exp) })
    }

    @Test("reads the two preferences and the shared partition's row count, as one line")
    func line() throws {
        let w = try FakeWorld()
        try setUp(w, rows: 7)
        let s = BrowserPane.read(w.paths)
        #expect(BrowserPane.line(s) == "browser-pane: prompt=done storage=shared cookies=7")
    }

    @Test("logged before quit and after exit on a switch; claude_desktop_config.json untouched; no secrets")
    func loggedDuringSwitch() async throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        try setUp(w, rows: 3)
        let before = w.digest(BrowserPane.configURL(w.paths))
        _ = try await engine.switchTo(FakeWorld.b)
        let log = try String(contentsOf: w.paths.switchLog, encoding: .utf8)
        #expect(log.contains("browser-pane: prompt=done storage=shared cookies=3 (before quit)"))
        #expect(log.contains("browser-pane: prompt=done storage=shared cookies=3 (after exit)"))
        #expect(log.contains("SYNTHETIC-SECRET") == false)
        #expect(w.digest(BrowserPane.configURL(w.paths)) == before)
    }

    @Test("missing files log dashes")
    func missing() throws {
        let w = try FakeWorld()
        #expect(BrowserPane.line(BrowserPane.read(w.paths)) == "browser-pane: prompt=- storage=- cookies=-")
    }
}
