import Foundation
import Testing
@testable import ClaudeAccountsCore

@Suite("Add draft row")
struct AddDraftTests {
    @Test("× / Escape cancels: row gone, text gone, nothing written, Claude untouched")
    func cancel() throws {
        let w = try FakeWorld()
        let engine = w.makeEngine()
        try w.setUpTwoAccounts(store: engine.store)
        let stateBefore = w.digest(w.paths.stateFile)
        var d = AddDraft()
        d.open()
        d.name = "gamma@example.com"
        d.cancel()
        #expect(d.isOpen == false)
        #expect(d.name.isEmpty)
        #expect(w.digest(w.paths.stateFile) == stateBefore)
        #expect(engine.store.state().pendingAddLabel == nil)
        #expect(w.app(Paths.claudeBundleID).quitRequests == 0)
    }

    @Test("closing the panel drops an empty row but keeps a typed name")
    func panelClose() {
        var empty = AddDraft()
        empty.open()
        empty.panelClosed()
        #expect(empty.isOpen == false)
        var typed = AddDraft()
        typed.open()
        typed.name = "team"
        typed.panelClosed()
        #expect(typed.isOpen)
        #expect(typed.name == "team")
    }

    @Test("Return submits a trimmed label and closes the row; blank does nothing")
    func submit() {
        var d = AddDraft()
        d.open()
        d.name = "  "
        #expect(d.submit() == nil)
        #expect(d.isOpen)
        d.name = " team@example.com "
        #expect(d.submit() == "team@example.com")
        #expect(d.isOpen == false)
    }
}
