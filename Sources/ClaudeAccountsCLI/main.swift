import ClaudeAccountsCore
import Foundation

// rotor (also installed as `claude-accounts`): `status` is read-only and safe on real data. Every other
// command that writes refuses real paths unless --real-data is passed.

let argv = Array(CommandLine.arguments.dropFirst())
let flags = Set(argv.filter { $0.hasPrefix("--") })
let positional = argv.filter { $0.hasPrefix("--") == false }
let paths = Paths.fromEnvironment()

func out(_ s: String = "") { print(s) }
func fail(_ s: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(Product.cli): \(s)\n".utf8))
    exit(code)
}

func guardWrites() {
    if paths.touchesRealData(), flags.contains("--real-data") == false {
        fail("refusing to touch real data. Override every path with CLAUDE_ACCOUNTS_ROOT, CLAUDE_USERDATA_DIR, CHROME_PROFILE_DIR and SESSION_SYNC_DIR, or pass --real-data.", code: 2)
    }
}

func flagValue(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

func chromePlan() -> ChromePlan {
    switch flagValue("--chrome") {
    case nil: return .skip
    case "restart": return .restartNow
    case "when-quits": return .whenNextQuits
    case "if-closed": return .ifClosed
    case let v?: fail("unknown --chrome \(v) (restart | when-quits | if-closed)")
    }
}

let relative = RelativeDateTimeFormatter()
let day: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func describe(_ health: LoginHealth, _ date: Date?) -> String {
    let d = date.map { day.string(from: $0) } ?? "?"
    switch health {
    case .ok(let n): return "expires \(d) (in \(n) days)"
    case .expiringSoon(let n): return "expires \(d) (in \(n) days, SOON)"
    case .expired: return "EXPIRED \(d)"
    case .unknown: return "expiry unknown"
    }
}

func resolve(_ engine: SwitchEngine, _ arg: String) -> Account {
    let list = engine.store.accounts()
    if let a = list.first(where: { $0.id == arg || $0.label == arg || $0.shortLabel == arg }) { return a }
    let pref = list.filter { $0.id.hasPrefix(arg) }
    if pref.count == 1 { return pref[0] }
    fail("no account matches \(arg)")
}

@MainActor func status() async {
    let engine = SwitchEngine.system(paths: paths)
    let now = Date()
    let store = engine.store
    let accounts = store.accounts()
    let state = store.state()
    let running = await engine.quitter.isRunning(engine.claude)
    let chromeRunning = await engine.quitter.isRunning(engine.chromeApp)

    out("\(Product.name) status (read only)")
    out("Claude \(ClaudeApp.version(paths) ?? "not found") · \(running ? "running" : "not running") · last good switch on \(state.lastGoodClaudeVersion ?? "none yet")")
    let current = engine.currentAccount()
    let label = current.flatMap { id in accounts.first { $0.id == id }?.label } ?? "not registered"
    out("Current account: \(current ?? "none") (\(label))")
    let hasLogin = CookieDB.hasClaudeLogin(paths.liveCookies)
    let exp = engine.liveCookieExpiry()
    out("  Live login: \(hasLogin ? "session cookie present" : "no session cookie") · \(describe(.of(exp, now: now), exp))")
    if let keys = try? ClaudeConfig.keyNames(paths.liveConfig) {
        let oauth = keys.filter { ClaudeConfig.oauthKeys.contains($0) }.count
        out("  config.json: \(keys.count) keys · oauth caches present: \(oauth) · journal: \(FileOps.exists(paths.liveConfigJournal) ? "present" : "none")")
    }
    do {
        try engine.checkLiveShape()
        out("  Shape check: ok")
    } catch {
        out("  Shape check: \(error)")
    }

    out("Accounts (\(accounts.count)):")
    if accounts.isEmpty { out("  none saved yet; the app registers the current account on first run") }
    for a in accounts {
        let mark = a.id == current ? "*" : " "
        let desk = a.desktop.map { "desktop saved \(day.string(from: $0.savedAt)), \(describe(.of($0.cookieExpiresAt, now: now), $0.cookieExpiresAt))" }
            ?? (a.id == current ? "desktop live (saved on next switch away)" : "desktop not saved")
        let chrome = a.chrome.map { "chrome saved \(day.string(from: $0.savedAt))" } ?? "Chrome: not set up"
        let used = a.lastUsedAt.map { "used \(relative.localizedString(for: $0, relativeTo: now))" } ?? "never used via switch"
        out(" \(mark) \(a.label) [\(a.id)] · \(desk) · \(chrome) · \(used)")
    }

    let ext = ExtensionSettings.accountUuid(in: paths.chromeExtensionSettings)
    let hosts = (try? CookieDB.familyHosts(paths.chromeCookies)) ?? []
    let rows = (try? CookieDB.metadata(paths.chromeCookies))?.count ?? 0
    out("Chrome: \(chromeRunning ? "running" : "not running") · extension account \(ext ?? "none") · claude.ai rows \(rows) in \(hosts.joined(separator: ", ")) · restore tabs on startup: \(ChromePreferences.restoresTabs(paths.chromePreferences) ? "on" : "off")")
    out("  Chrome follows switches: \(state.chromeFollows ? "yes" : "no") · pending change: \(state.pendingChrome.map { "\($0)" } ?? "none")")

    let sync = SyncStatus.read(paths.syncLog)
    if sync.isAvailable {
        let ago = sync.lastPass.map { relative.localizedString(for: $0, relativeTo: now) } ?? "never"
        out("Chats: last sync pass \(ago) · unwatched \(sync.unwatched)\(sync.needsAttention(now: now) ? " · needs repair" : "")")
    } else {
        out("Chats: sync log not found")
    }
    out(BrowserPane.line(BrowserPane.read(paths)))
    out("Chats that look busy (desktop sessions, last 60 s, not at end of turn): \(engine.busyChats())")
    if let f = state.inFlight { out("INTERRUPTED \(f.kind.rawValue) at step \(f.step); backup \(f.backupID)") }
    if let n = state.chromeNotice { out("Chrome notice: \(n)") }
    out("Backups: \(store.backups().count) · store \(FileOps.exists(paths.storeRoot) ? paths.storeRoot.path(percentEncoded: false) : "not created yet")")
    if let pending = state.pendingAddLabel { out("Add account in progress: \(pending)") }
}

func progressPrinter() -> @Sendable (SwitchPhase) -> Void {
    { phase in print("  · \(phase.title)") }
}

@MainActor func run() async {
    switch positional.first {
    case nil, "help", "-h":
        out("""
        usage: \(Product.cli) <command>   (claude-accounts is an alias)
          status                      read-only report (safe on real data)
          backups                     list backups (read only)
          switch <account> [--chrome restart|when-quits|if-closed]
          rollback <backup-id>
          add <label> [--chrome restart|when-quits|if-closed]
          complete-add                register the account signed in after `add`
          save                        save the current account's slot (Claude must be closed)
          label <account> <label>
          apply-chrome                apply a pending Chrome change (Chrome must be closed)
          usage                       print cached usage.json (no Keychain, no network)
          usage --refresh             refresh usage from Anthropic (needs --real-data)
        Commands that write refuse real paths unless --real-data is passed.
        """)
    case "status":
        await status()
    case "backups":
        let store = AccountStore(paths: paths)
        for b in store.backups() {
            out("\(b.id)  \(b.reason)  \(b.fromAccount ?? "?") -> \(b.toAccount ?? "?")\(b.hasChrome ? "  +chrome" : "")")
        }
    case "switch":
        guardWrites()
        guard positional.count >= 2 else { fail("switch needs an account") }
        let engine = SwitchEngine.system(paths: paths)
        let target = resolve(engine, positional[1])
        let busy = engine.busyChats()
        if busy > 0 { out("\(busy) chats look busy; Claude will ask before quitting.") }
        do {
            let o = try await engine.switchTo(target.id, chrome: chromePlan(), progress: progressPrinter())
            out("switched to \(target.label): \(o.verdict) · chrome \(o.chrome) · backup \(o.backupID)")
            if o.verdict != .success { out("Switch not confirmed. Roll back with: \(Product.cli) rollback \(o.backupID)") }
        } catch { fail("\(error)") }
    case "rollback":
        guardWrites()
        guard positional.count >= 2 else { fail("rollback needs a backup id") }
        let engine = SwitchEngine.system(paths: paths)
        do {
            let o = try await engine.rollback(positional[1], chrome: chromePlan() == .skip ? .ifClosed : chromePlan(), progress: progressPrinter())
            out("rolled back: \(o.verdict) · chrome \(o.chrome)")
        } catch { fail("\(error)") }
    case "add":
        guardWrites()
        guard positional.count >= 2 else { fail("add needs a label") }
        let engine = SwitchEngine.system(paths: paths)
        do {
            try await engine.beginAdd(label: positional[1], chrome: chromePlan(), progress: progressPrinter())
            out("Sign in to Claude now, then run: \(Product.cli) complete-add")
        } catch { fail("\(error)") }
    case "complete-add":
        guardWrites()
        let engine = SwitchEngine.system(paths: paths)
        do {
            switch try engine.completeAdd() {
            case .added(let a): out("registered \(a.label) [\(a.id)]")
            case .signedInAsKnown(let a): out("You signed in as \(a.label) again. Run add again to sign in to a different account, or cancel.")
            case .waiting: out("still waiting for sign-in")
            }
        } catch { fail("\(error)") }
    case "save":
        guardWrites()
        let engine = SwitchEngine.system(paths: paths)
        if await engine.quitter.isRunning(engine.claude) { fail("quit Claude first; save copies files only while it's closed") }
        guard let id = engine.currentAccount() else { fail("config.json names no account") }
        do {
            _ = try engine.store.makeBackup(reason: "save", from: id, to: id, now: Date())
            if try engine.saveCurrentDesktop() == false { fail("live Cookies has no session cookie") }
            out("saved \(id)")
        } catch { fail("\(error)") }
    case "label":
        guardWrites()
        guard positional.count >= 3 else { fail("label needs an account and a label") }
        let engine = SwitchEngine.system(paths: paths)
        let a = resolve(engine, positional[1])
        do {
            try engine.store.setLabel(a.id, positional[2])
            engine.store.writeSyncLabels()
        } catch { fail("\(error)") }
    case "usage":
        let store = AccountStore(paths: paths)
        if flags.contains("--refresh") {
            guardWrites()
            let engine = SwitchEngine.system(paths: paths)
            let tokens = KeychainTokenSource(paths: paths, currentAccount: { engine.currentAccount() },
                                             isAddInProgress: { engine.store.state().pendingAddLabel != nil })
            let service = UsageService(paths: paths, http: SecureHTTPClient(), tokens: tokens,
                                       log: { store.log($0) })
            for a in store.accounts() { out("\(a.label): \(await service.refresh(a.id))") }
        } else {
            let service = UsageService(paths: paths, http: OfflineHTTPClient(),
                                       tokens: NoTokenSource(), log: { _ in })
            let snap = service.cachedSnapshot()
            if snap.isEmpty { out("no cached usage") }
            for a in store.accounts() {
                guard let s = snap[a.id] else { continue }
                let five = s.usage.fiveHour.map { "5h \(Int($0.utilization*100))%" } ?? "5h -"
                let week = s.usage.weekly.map { "week \(Int($0.utilization*100))%" } ?? "week -"
                let flagsStr = [s.usage.needsRefresh ? "needs-refresh" : nil, s.stale ? "stale" : nil].compactMap { $0 }.joined(separator: ",")
                out("\(a.label): \(five) · \(week) · fetched \(day.string(from: s.fetchedAt))\(flagsStr.isEmpty ? "" : " · " + flagsStr)")
            }
        }
    case "apply-chrome":
        guardWrites()
        let engine = SwitchEngine.system(paths: paths)
        do { out("chrome: \(try await engine.applyPendingChrome())") } catch { fail("\(error)") }
    case let other?:
        fail("unknown command \(other)")
    }
}

await run()
