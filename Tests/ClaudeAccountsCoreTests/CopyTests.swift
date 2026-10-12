import Testing
@testable import ClaudeAccountsCore

@Suite("Panel copy")
struct CopyTests {
    @Test("every status line fits the one-line budget")
    func budget() {
        for s in PanelCopy.all {
            #expect(s.count <= PanelCopy.budget, "\(s) is \(s.count) characters")
        }
    }

    @Test("signed-in-again falls back when the label is long")
    func signedInAgain() {
        #expect(PanelCopy.signedInAgain("team") == "Signed in as team again")
        #expect(PanelCopy.signedInAgain("a-very-long-label@example.com") == "Same account again")
    }
}

@Suite("Parallel windows copy")
struct WindowCopyTests {
    @Test("window status lines fit the one-line budget")
    func windowLinesFit() {
        for s in PanelCopy.windowLines {
            #expect(s.count <= PanelCopy.budget, "\(s) is \(s.count) characters")
            #expect(s.isEmpty == false)
        }
    }

    @Test("every window error and sign-in step has its own short title")
    func titles() {
        #expect(PanelCopy.title(for: WindowError.capReached(3)) == "Close a window first (3 at most).")
        #expect(PanelCopy.title(for: WindowError.signedInAsOther(expected: "a", actual: "b")) == "Wrong account signed in")
        // The generic entry point reaches window errors too.
        #expect(PanelCopy.title(for: WindowError.windowStillRunning("x")) == "Window didn't close")
        #expect(PanelCopy.title(for: WindowError.mainNotReopened) == "Open Claude yourself")
        #expect(Set(PanelCopy.windowLines).count > 15)
    }

    @Test("the first sign-in confirmation is one line: the main window closes for about a minute")
    func confirmation() {
        #expect(PanelCopy.windowSignInConfirm
            == "To sign this account in, your main Claude window closes for about a minute.")
        #expect(PanelCopy.windowSignInConfirm.contains("chat") == false)
    }

    @Test("sign-in steps follow the flow and say whether the main window is back")
    func steps() {
        #expect(PanelCopy.signInStep(.closingMain) == "Closing main window…")
        #expect(PanelCopy.signInStep(.waitingForSignIn) == "Sign in using the new window")
        #expect(PanelCopy.signInStep(.rolledBack(mainReopened: true)) == "Cancelled · main reopened")
        #expect(PanelCopy.signInStep(.rolledBack(mainReopened: false)) == "Cancelled")
    }

    @Test("an interrupted sign-in found at start reads as one of three short lines")
    func interrupted() {
        #expect(PanelCopy.interruptedSignIn(note: "an interrupted sign-in for x was cleared; the main window was reopened") == "Main window reopened")
        #expect(PanelCopy.interruptedSignIn(note: "an interrupted sign-in for x was cleared; the main window did not reopen") == "Open Claude yourself")
        #expect(PanelCopy.interruptedSignIn(note: "an interrupted sign-in for x was cleared") == "Sign-in cancelled")
    }

    @Test("row buttons and subtitles use the agreed short words")
    func rowWords() {
        #expect(PanelCopy.switchButton == "Switch")
        #expect(PanelCopy.openButton == "Open")
        #expect(PanelCopy.showButton == "Show")
        #expect(PanelCopy.closeButton == "Close")
        #expect(PanelCopy.mainWindowSubtitle == "Main window")
        #expect(PanelCopy.windowOpenSubtitle == "Open in its own window")
        #expect(PanelCopy.capReached(3) == "Close a window first (3 at most).")
    }

    @Test("a row says nothing about sign-in; the note lives only in the first-Open confirmation")
    func rowsStayQuiet() {
        // Row text is the two subtitles and the four buttons, each a few words.
        let rowText = [PanelCopy.mainWindowSubtitle, PanelCopy.windowOpenSubtitle, PanelCopy.switchButton,
                       PanelCopy.openButton, PanelCopy.showButton, PanelCopy.closeButton]
        for s in rowText {
            #expect(s.count <= 24, "\(s) is too long for a row")
            #expect(s.lowercased().contains("sign") == false)
        }
        #expect(PanelCopy.windowSignInConfirm.contains("sign this account in"))
    }

    @Test("no jargon in anything the user reads")
    func plain() {
        let banned = ["pid", "user-data", "data dir", "claude://", "SIGTERM", "registry", "config.json", "Electron", "uuid", "process"]
        for s in PanelCopy.windowLines + PanelCopy.sentences + [PanelCopy.openButton, PanelCopy.closeButton, PanelCopy.showButton, PanelCopy.windowOpenSubtitle, PanelCopy.mainWindowSubtitle] {
            for w in banned { #expect(s.lowercased().contains(w.lowercased()) == false, "\"\(s)\" contains \(w)") }
        }
    }

    @Test("long sentences stay short enough to read at a glance")
    func sentenceLength() {
        for s in PanelCopy.sentences { #expect(s.count <= 130, "\(s) is \(s.count) characters") }
    }
}

@Suite("Account rows")
struct AccountRowTests {
    /// The plan for one row, with only the facts a test cares about.
    private func plan(_ configure: (inout RowFacts) -> Void) -> RowPlan {
        var f = RowFacts()
        configure(&f)
        return RowPlan(for: f)
    }

    @Test("a collapsed row shows no buttons, whatever the setting or the account")
    func collapsedHasNoButtons() {
        for parallel in [false, true] {
            for main in [false, true] {
                for window in [false, true] {
                    let p = plan { $0.isParallelOn = parallel; $0.isMain = main; $0.hasOwnWindow = window; $0.isExpanded = false }
                    #expect(p.buttons.isEmpty, "parallel \(parallel), main \(main), window \(window)")
                }
            }
        }
    }

    @Test("an expanded account that is open nowhere offers Switch and Open")
    func expandedOtherAccount() {
        let p = plan { $0.isParallelOn = true; $0.isExpanded = true }
        #expect(p.buttons == [.switchTo, .open])
        #expect(p.usesMiniButtons)
        #expect(p.showsCheckmark == false)
        #expect(p.subtitle == nil)
        #expect(p.showsWindowIcon == false)
    }

    @Test("an expanded account in its own window offers Show and Close, with the window icon and subtitle")
    func expandedWindowAccount() {
        let p = plan { $0.isParallelOn = true; $0.hasOwnWindow = true; $0.isExpanded = true }
        #expect(p.buttons == [.show, .close])
        #expect(p.usesMiniButtons)
        #expect(p.showsWindowIcon)
        #expect(p.subtitle == "Open in its own window")
        // The buttons take the room beside the name, so the subtitle sits in the expanded part.
        #expect(p.isSubtitleInDetail)
    }

    @Test("a subtitle sits under the name unless the row shows buttons")
    func subtitlePlace() {
        let collapsed = plan { $0.isParallelOn = true; $0.hasOwnWindow = true }
        #expect(collapsed.subtitle == "Open in its own window" && collapsed.isSubtitleInDetail == false)
        let main = plan { $0.isParallelOn = true; $0.isMain = true; $0.isExpanded = true }
        #expect(main.subtitle == "Main window" && main.isSubtitleInDetail == false)
        // It stays put while the row's own action runs and the buttons give way to the spinner.
        let busy = plan { $0.isParallelOn = true; $0.hasOwnWindow = true; $0.isExpanded = true; $0.isActive = true; $0.isSwitching = true }
        #expect(busy.isSubtitleInDetail)
        let none = plan { $0.isParallelOn = true; $0.isExpanded = true }
        #expect(none.subtitle == nil && none.isSubtitleInDetail == false)
    }

    @Test("the main window's account says so and never has buttons")
    func mainAccount() {
        for expanded in [false, true] {
            let p = plan { $0.isParallelOn = true; $0.isMain = true; $0.isExpanded = expanded }
            #expect(p.buttons.isEmpty)
            #expect(p.menu.isEmpty)
            #expect(p.subtitle == "Main window")
            #expect(p.showsWindowIcon == false)
        }
    }

    @Test("every account open somewhere has the checkmark, collapsed or expanded; no other account does")
    func checkmarks() {
        for expanded in [false, true] {
            let main = plan { $0.isParallelOn = true; $0.isMain = true; $0.isExpanded = expanded }
            let window = plan { $0.isParallelOn = true; $0.hasOwnWindow = true; $0.isExpanded = expanded }
            let other = plan { $0.isParallelOn = true; $0.isExpanded = expanded }
            #expect(main.showsCheckmark && main.isOpenSomewhere, "main, expanded \(expanded)")
            #expect(window.showsCheckmark && window.isOpenSomewhere, "window, expanded \(expanded)")
            #expect(other.showsCheckmark == false && other.isOpenSomewhere == false, "other, expanded \(expanded)")
        }
    }

    @Test("a window still open after the setting is turned off keeps its checkmark and, expanded, its Show and Close")
    func windowOutlivesTheSetting() {
        let collapsed = plan { $0.hasOwnWindow = true }
        #expect(collapsed.buttons.isEmpty)
        #expect(collapsed.showsCheckmark)
        #expect(collapsed.menu == [.show, .close])
        let expanded = plan { $0.hasOwnWindow = true; $0.isExpanded = true }
        #expect(expanded.buttons == [.show, .close])
        #expect(expanded.usesMiniButtons)
    }

    @Test("with the setting off and no window anywhere, every row is exactly the plain panel")
    func settingOffIsThePlainPanel() {
        // The plain panel: an expanded row of another account has one Switch button; the main
        // window's account has the only checkmark; a spinner replaces the row's mark; no menu,
        // subtitle or window icon exists.
        let bools = [false, true]
        for main in bools { for expanded in bools { for active in bools { for switching in bools { for named in bools {
            let p = plan {
                $0.isMain = main; $0.isExpanded = expanded; $0.isActive = active; $0.isSwitching = switching; $0.isBeingNamed = named
            }
            let spinner = active && switching
            let switchButton = expanded && main == false && active == false && named == false
            let label = "main \(main), expanded \(expanded), active \(active), switching \(switching), named \(named)"
            #expect(p.showsSpinner == spinner, "\(label)")
            #expect(p.buttons == (switchButton ? [.switchTo] : []), "\(label)")
            #expect(p.usesMiniButtons == false, "\(label)")
            #expect(p.showsCheckmark == (main && spinner == false), "\(label)")
            #expect(p.showsHealth == (spinner == false && switchButton == false), "\(label)")
            #expect(p.menu.isEmpty && p.subtitle == nil && p.showsWindowIcon == false, "\(label)")
        } } } } }
    }

    @Test("the right-click menu works on a collapsed row and matches the buttons of the expanded one")
    func menuMatchesButtons() {
        for window in [false, true] {
            let collapsed = plan { $0.isParallelOn = true; $0.hasOwnWindow = window }
            let expanded = plan { $0.isParallelOn = true; $0.hasOwnWindow = window; $0.isExpanded = true }
            #expect(collapsed.menu == expanded.buttons)
            #expect(expanded.menu == expanded.buttons)
            #expect(collapsed.menu.isEmpty == false)
        }
    }

    @Test("while its action runs, a row shows only the spinner")
    func spinner() {
        let p = plan { $0.isParallelOn = true; $0.hasOwnWindow = true; $0.isExpanded = true; $0.isActive = true; $0.isSwitching = true }
        #expect(p.showsSpinner)
        #expect(p.buttons.isEmpty)
        #expect(p.showsCheckmark == false)
        #expect(p.showsHealth == false)
    }

    @Test("the login-expiry mark gives way to buttons, and returns with a collapsed row")
    func healthMark() {
        #expect(plan { $0.isParallelOn = true; $0.isExpanded = true }.showsHealth == false)
        #expect(plan { $0.isParallelOn = true }.showsHealth)
        #expect(plan { $0.isParallelOn = true; $0.isMain = true; $0.isExpanded = true }.showsHealth)
    }

    @Test("a row that is still asking for a name has no buttons, menu, subtitle or window icon, but keeps its checkmark")
    func namingRow() {
        let p = plan { $0.isParallelOn = true; $0.isExpanded = true; $0.isBeingNamed = true }
        #expect(p.buttons.isEmpty && p.menu.isEmpty)
        #expect(p.subtitle == nil && p.showsCheckmark == false && p.showsWindowIcon == false)
        // A new account is signed in to the main window while it waits for its name.
        let main = plan { $0.isParallelOn = true; $0.isMain = true; $0.isBeingNamed = true }
        #expect(main.showsCheckmark && main.isOpenSomewhere)
        #expect(main.subtitle == nil && main.showsHealth)
    }
}
