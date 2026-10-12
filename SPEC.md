# Rotor: spec

Rotor (called Claude Accounts until 2026-10-09; see "Naming") is a native macOS menu bar app that switches
the Claude desktop app, and optionally Claude in Chrome, between your Claude accounts. Each account is signed in once and never again. Personal tool for one Mac. The research notes behind these claims are not included in this copy (2026-10-08, Claude.app 2.26454.0,
macOS 26.6.2, Xcode 26.6).

## Goals

1. Switch accounts from the menu bar in ~5–10 s with no sign-in screen.
2. Durable: after one sign-in per account, logins stay valid for as long as each account is used at least
   once every ~4 weeks. The app warns a week before any saved login expires.
3. Claude in Chrome follows the switch without signing in again.
4. Minimal, sleek Liquid Glass UI in the macOS 26 design language.
5. Never lose chats: run a chat sync pass before each switch, and keep a backup and a one-click rollback for every switch.

Out of scope for v1: switching without restarting the app (needs modifying Anthropic's app, so ruled out),
usage per account (needs reading the saved logins; v2 opt-in), automatic switching.

## How a login works (findings this design relies on)

- **Desktop app.** The root credential is `~/Library/Application Support/Claude/Cookies`: the `.claude.ai`
  `sessionKey`/`sessionKeyV3` rows, Chromium `v10`-encrypted with the shared Keychain item "Claude Safe Storage".
  `config.json` names the account in `lastKnownAccountUuid`. `oauth:tokenCache` and `oauth:tokenCacheV2` are
  disposable: with a valid cookie and an empty cache the app silently mints a new token at launch (log line
  `obtained new token`). If the cookie's account differs from `lastKnownAccountUuid`, the app clears the
  oauth cache, resets MCP toggles and disconnects connectors. Keeping the two matched avoids that.
- **Sign out kills a login.** The app's Sign out button calls `/api/auth/logout`, which revokes the session on the
  server. The switcher never signs out; it quits the app and swaps files.
- **Expiry.** The cookie's `expires_utc` was creation + 28 days and did not move when the app re-stamped it 6 h
  later. Whether activity extends it is unknown, so the app records the expiry at every save and learns.
  A slot that isn't loaded gets no re-stamps.
- **Quitting.** A normal quit shows Claude's own "Claude is still working" dialog (Quit anyway / Wait for Claude / Cancel)
  when any session is mid-turn. Cleanup can take up to 75 s, with a watchdog force-exit at 15 s. Files are safe to touch once
  the main process and every `Application Support/Claude/claude-code/` child are gone, `config.json.journal`
  is absent and `Cookies-journal` is empty.
- **Journal.** `config.json.journal` is replayed at launch only if config.json's digest matches the journal's
  header, and a clean quit leaves none. The rule: after exit, delete any leftover journal, then write config.json.
- **No local email.** No non-secret local file maps account uuid to email, so the user labels each account.
- **Claude in Chrome** (extension `fcoeoabgfenejglbffodgkkbkcdhcgfn`, installed in Chrome profile `Default` only) runs
  its own OAuth. Its tokens live in `chrome.storage.session`, in memory only. At startup it silently re-authorises
  (`prompt=none`, `login_hint=<accountUuid>`) using the **claude.ai cookie of its Chrome profile**. On disk
  it keeps only `accountUuid`, `tokenOrg`, `lastActiveOrgHint` and consent in
  `Default/Local Extension Settings/<id>/` (LevelDB). If the profile's claude.ai cookie belongs to another account,
  the extension shows `account_mismatch`. It has no account picker, and nothing makes it follow the desktop app.

## Design

### Storage

`~/Library/Application Support/ClaudeAccounts/` (0700, files 0600):

```
accounts.json                     # [{id: account uuid, label, colorIndex, createdAt, lastUsedAt,
                                  #   desktop: {savedAt, claudeVersion, cookieExpiresAt},
                                  #   chrome:  {savedAt, cookieExpiresAt, extensionAccountUuid} | null}]
slots/<uuid>/desktop/Cookies      # copy of the app's Cookies file (stays encrypted; never decrypted)
slots/<uuid>/chrome/claude-cookies.sqlite   # only the claude.ai-family rows from Chrome's Cookies, blobs untouched
slots/<uuid>/chrome/extension-settings/     # copy of Default/Local Extension Settings/<ext id>/
backups/<timestamp>/              # pre-switch copies of live Cookies + config.json (+ Chrome bits); keep last 10
switch.log                        # steps and outcomes only, never values
```

Nothing is ever decrypted, printed or sent anywhere. The oauth caches are not stored: they're dropped on restore
and re-minted by the app. The Keychain is never touched.

### Desktop switch (to account T)

1. **Preflight.** T has a saved Cookies file. The live files have the expected shape: config.json is JSON with
   `lastKnownAccountUuid`, and the Cookies sqlite has a `.claude.ai` `sessionKeyV3` row (metadata query only).
   If the Claude version changed since the last good switch, rerun the shape check and record the new version;
   on any mismatch refuse with "Claude updated; switching paused" and change nothing. Current account C =
   `lastKnownAccountUuid`. If C == T, do nothing.
2. **Busy check (informational).** Heuristic: transcripts in `~/.claude/projects/**.jsonl` modified in the last 60 s
   whose tail is not an `end_turn` + `stop_hook_summary`. The CLI's `status` prints the count. A switch never asks
   about it and never waits on it: Claude's own quit dialog (step 4) is what asks. (Decision 2026-10-09: no
   busy-chat warning anywhere, including before an extra window's first sign-in or closing a window.)
3. **Chat sync.** Run `/usr/bin/python3 mirror.py` (60 s timeout): the copy bundled in the app's `Resources` (so extra
   windows join the union), else `CLAUDE_ACCOUNTS_MIRROR_SCRIPT`, else the deployed `~/.claude/session-sync/mirror.py`
   (which is what the `rotor` command line tool uses). A failure warns, not blocks.
4. **Quit Claude.** `NSRunningApplication.terminate()` on bundle id `com.anthropic.claudefordesktop`. If Claude shows
   its own "still working" dialog, the panel says "Claude is asking: choose Quit anyway in Claude, or Cancel
   here." Wait up to 120 s. If it's still running, abort with nothing changed. **Never force-kill.**
5. **Wait for a clean exit.** No process whose executable is inside `/Applications/Claude.app/` or under
   `~/Library/Application Support/Claude/claude-code/`, `Cookies-journal` absent or empty, then
   delete any leftover `config.json.journal`.
6. **Back up** live `Cookies` + `config.json` to `backups/<ts>/`.
7. **Save outgoing C.** If the live Cookies has a `sessionKeyV3` row, copy it atomically to `slots/C/desktop/Cookies`
   and record `cookieExpiresAt`. If C has no entry, create one labelled "Unnamed account" and ask for a label afterwards.
8. **Restore T.** Copy `slots/T/desktop/Cookies` over live `Cookies` (temp + rename, 0600, remove `Cookies-journal`).
   Edit config.json in place: set `lastKnownAccountUuid = T`, remove both `oauth:*` keys, keep every other key,
   and write it atomically. Make sure no journal remains.
9. **Relaunch** with `NSWorkspace.openApplication`.
10. **Verify** for up to 60 s: config.json still says T, and `~/Library/Logs/Claude/main.log` shows no
    `not_logged_in` / `different account` / sign-in-required lines after the launch time. An `obtained new token`
    line marks success. On failure show "Switch didn't take. Roll back?"; rollback restores `backups/<ts>/` the same
    way (quit, swap, relaunch).
11. Update `lastUsedAt`, and the menu bar label.

### Claude in Chrome follows the switch

Recommended approach: **swap Chrome's claude.ai login and the extension's saved account together, while Chrome
is closed.** This keeps the user's single Chrome profile with all its site logins. The rejected alternative was one
Chrome profile per account, which would leave the agent browsing without the user's logins.

- Saving (Chrome closed): export every Cookies row whose `host_key` is in the claude.ai family (exact list
  taken from the live DB's metadata) into the slot sqlite with the same schema, blobs untouched. Also copy
  `Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn/`.
- Restoring (Chrome closed): delete those rows from `Default/Cookies`, insert the slot's rows, and replace the extension
  settings dir with the slot copy. On next launch the extension silently signs in as T.
- Chrome must be closed for both. If Chrome isn't running at switch time, the swap happens immediately as
  part of the switch. If it is running, the switch never restarts Chrome on its own: it schedules the swap
  for the moment Chrome next exits (within a second, then leaves it closed), and the panel shows a quiet line,
  "Chrome switches when you next quit it". **Restart Chrome now** (graceful quit via Apple event, swap, reopen)
  stays available as a secondary action on that line and in the ⋯ menu. No modal choice.
  *(Changed 2026-10-08: default is "when Chrome next quits"; was a Restart-now / When-quits choice.)*
- Tabs come back after a restart only if Chrome's "On startup → Continue where you left off" is on. It's
  currently off (`session.restore_on_startup` unset). The app does not prompt about it in the panel; the
  Restart Chrome now confirmation carries one line saying tabs won't reopen unless that setting is on.
  You flip it yourself; the app never edits Chrome's settings.
  *(Changed 2026-10-08: the persistent prompt was dropped.)*
- Verify after relaunch: the extension's saved `accountUuid` (read from the LevelDB, not a secret) equals T.
- Chrome login for an account is seeded once, during Add account (below). An account without a Chrome slot
  switches the desktop app only, and the row says "Chrome: not set up".
- Untested risks: Chrome may change its cookie schema, and the app's "Claude Desktop wants to connect" pairing
  prompt may reappear once per account.

### Add account (one-time sign-in per account)

1. Add account… → The user types a label (e.g. `team@example.com`).
2. The app quits Claude (same safe steps), saves the current account, removes the live `Cookies`
   locally (no server logout), removes the `oauth:*` keys, and relaunches. Claude shows its sign-in screen.
3. The user signs in. The app watches `lastKnownAccountUuid` change and registers the new uuid under the label.
   It's saved on the next switch away.
4. Chrome (if enabled): with Chrome closed, the app removes the claude.ai rows and the extension settings dir, then
   reopens Chrome. The user signs in to claude.ai and then the extension, once. The app saves the Chrome slot the next time Chrome quits.
5. The account that's signed in on first run is registered the same way, with a label prompt.

Never press Sign out in Claude or in the extension: it kills that saved login on the server.

### Login health

- Each row shows "Expires in N days" (from `cookieExpiresAt`). It turns amber under 7 days and red when expired,
  with **Sign in again**, which runs Add account for that slot.
- Loading an account through a switch is the only refresh. The app never makes background requests with a saved login.

### Chat sync integration

- Run one sync pass before every switch (step 3).
- The footer reads the last line of `~/.claude/session-sync/sync.log`: "Chats synced 12 s ago", or a warning when
  `unwatched` > 0 or the last pass is older than 10 min. **Repair sync** runs `mirror.py --reload` from the deployed `~/.claude/session-sync/mirror.py`, never the bundled copy:
  mirror.py only rewrites and reloads the LaunchAgent whose plist runs the very file it was called as.
- The app writes `~/.claude/session-sync/accounts.json` (uuid → label) so sync logs and future tools can name accounts.

## UI

The menu bar label is a template SF Symbol plus a short label for the current account (e.g. "team"). It spins
`arrow.triangle.2.circlepath` while switching.

The panel is a `MenuBarExtra(.window)`, ~320 pt wide, with `GlassEffectContainer` and `.containerBackground(.clear, for: .window)`.
If the window material fights the glass, fall back to an `NSPanel` hosting SwiftUI. Decide from a screenshot.

```
╭──────────────────────────────────────╮
│  (TE)  team@example.com          ●    │  current: avatar, label, "Claude · Chrome"
│        Active · expires in 26 days   │
├──────────────────────────────────────┤
│  (ET)  me@example.com              │  rows: avatar (initials, tinted), label,
│        Used 2 h ago                  │  one quiet secondary line; hover = interactive glass
│  (CR)  creators@example.com      ◐    │  amber dot = expiring soon
│        Expires in 5 days             │
│  …                                   │
├──────────────────────────────────────┤
│  Chats synced 12 s ago          ⋯    │  ⋯ = Add account, Repair sync, Also switch Chrome,
╰──────────────────────────────────────╯      Open at login, Show backups, Quit
```

- Tapping a row switches. The row morphs into a progress capsule: Syncing chats → Quitting Claude → Saving →
  Restoring → Opening → Done. It's interruptible until "Saving".
- Typography: SF Pro, 13 pt labels and 11 pt secondary in `.secondary`, generous 10–12 pt row padding, 8 pt row gaps.
- Subtle spring motion. The system handles Reduce Transparency and Increase Contrast. No custom chrome.
- Global hotkey ⌥⌘A opens the panel.

## Build

- SwiftPM package at `the repo folder`. Targets: `ClaudeAccountsCore` (engine, no UI),
  `ClaudeAccounts` (SwiftUI app), `claude-accounts` (CLI, installed as `rotor` with `claude-accounts` as an alias:
  `status` is read-only and safe on real data; `switch` / `add` / `save` exist for parity but refuse real paths
  unless `--real-data` is passed).
- Every path comes from one `Paths` struct, overridable with `CLAUDE_ACCOUNTS_ROOT`, `CLAUDE_USERDATA_DIR`,
  `CHROME_PROFILE_DIR` and `SESSION_SYNC_DIR`, so tests run against fake trees.
- Tests (swift-testing) on fake trees:
  - save/restore round trip;
  - config edits keep other keys and drop the oauth keys;
  - journal handling;
  - refusal while the app "runs" (injected process probe);
  - refusal on shape mismatch;
  - backup rotation;
  - Chrome row export/import into a sqlite built from the real Chrome `Cookies` **schema only** (no data);
  - extension-dir swap;
  - rollback.
- `scripts/build-app.sh` builds `Rotor.app` (LSUIElement, bundle id `local.rotor.claude-accounts`,
  minimum macOS 26.0), signs it with your Apple Development identity (ad hoc only if there is none) and installs it to
  `~/Applications/Rotor.app`. The app binary is `Contents/MacOS/Rotor`; the CLI binary stays `Contents/MacOS/claude-accounts`.
  `~/.local/bin/rotor` and `~/.local/bin/claude-accounts` are both symlinks to that CLI binary. After the new app is
  installed and verified (signature, bundle name, binaries), a leftover `~/Applications/Claude Accounts.app` is moved to the
  Trash with `/usr/bin/trash`, never deleted; if that fails the script says so and carries on.
- Open at Login: `SMAppService.mainApp` first, with the user LaunchAgent (`scripts/install-login-agent.sh`) only as the
  fallback if registering throws. See "Naming" for what a rename does to it.
- The in-app Update and the "Running an Old Copy" check compare the running bundle with `~/Applications/Rotor.app`
  (`Updater.installedPath`); a copy still named `Claude Accounts.app` counts as an old copy.

## Naming

The product name is **Rotor** (2026-10-09; before that, Claude Accounts). Only what a person sees changed: the menu bar
item and its accessibility label, the Settings window title, the bundle's `CFBundleName` and `CFBundleDisplayName`, the
installed `Rotor.app` and its binary, the `rotor` command, CLI output, engine messages, README and this spec. One constant,
`Product` in `ClaudeAccountsCore`, holds the name for code. "Claude" is unchanged wherever it means Anthropic's Claude app.

Everything that macOS, the Keychain or an existing install keys on keeps the old name, so the rename resets nothing:

| Kept | Why |
| --- | --- |
| Bundle id `local.rotor.claude-accounts` | The defaults domain, the saved Login Items record, the code signature's designated requirement (and with it the Keychain "Always Allow" for "Claude Safe Storage") and any privacy grants hang on it. A new id is a new app to macOS. |
| `~/Library/Application Support/ClaudeAccounts/` (incl. `windows/`, `windows.json`) | Every saved login, backup, window dir and log lives there. `mirror.py` and the engine read the same path. |
| LaunchAgent label and file `local.rotor.claude-accounts` | The label is the agent's identity to `launchctl`. |
| `CLAUDE_ACCOUNTS_*` environment variables | Tests, demos and `scripts/` set them. |
| Swift package and target names (`ClaudeAccountsCore`, `ClaudeAccounts`, `ClaudeAccountsCLI`), the SwiftPM products, dispatch queue labels, `User-Agent: ClaudeAccounts/1.0` | Not visible to a person; renaming targets churns every file for no gain. |
| `Contents/MacOS/claude-accounts` (the CLI binary in the bundle) | codesign derives its identifier from the file name, so renaming it would make it a different program to the Keychain. `rotor` is a symlink to it. |
| The repo name and path (`the repo folder`) | The app finds its repo through `CARepoPath` in Info.plist. |

**Open at Login and the rename.** Verified on this Mac on 2026-10-09 (read only): Open at Login is registered through
`SMAppService.mainApp` (a Background Task Management record of type app, identifier
`2.local.rotor.claude-accounts`, URL `~/Applications/Claude%20Accounts.app/`, enabled), and no
LaunchAgent plist exists in `~/Library/LaunchAgents`. The record is keyed by bundle id but also stores the old URL and the
old display name. Whether macOS follows the record to `Rotor.app` by itself is unverified (it was not tried, to leave the
login item alone). The one step if it does not: open Rotor, then in Settings switch Open at Login off and on once, which
registers `Rotor.app` under the same identifier. Check System Settings, General, Login Items lists Rotor. The app never
re-registers by itself. A LaunchAgent made earlier by `install-login-agent.sh` would point at the old path
(`build-app.sh` warns); re-run the installer. Also quit a still-running old Claude Accounts before opening Rotor, since
both share one bundle id.

## Safety rules for anyone building this

- Never run a real switch, save or add, and never quit, launch or relaunch Claude.app or Chrome. The builder is
  itself a session inside Claude.app; quitting it kills every running session.
- Never read, print or copy secret values: cookie values, tokens, keys. Read metadata only (`host_key`, `name`,
  `expires_utc`, `lastKnownAccountUuid`, file sizes and mtimes). Never call `security … -w`.
- Real-data commands are limited to read-only `status`.

## Open questions, settled by the first live test

1. Does the restored desktop login come up signed in with no prompt? (Expected yes, from the code and logs.)
2. Does a saved slot still work after the live login re-stamped its cookie? Test this by switching away and back after 6 h or more.
3. Does Claude in Chrome sign in silently after the Chrome swap, and does the pairing prompt reappear?
4. Does the glass panel render as real glass in `MenuBarExtra`, or does it need the `NSPanel` fallback?

## Review changes (2026-10-08)

- Chrome attribution: `state.chromeAccount` (last restored, the account being added, or the user's own
  "Chrome is signed in as …") is the source of truth. The LevelDB reader is advisory: on disagreement the
  outgoing Chrome login is not saved (it stays in the backup) and the panel warns. Slots keep a `.prev` copy.
- Chrome swaps edit a temp copy and rename it in, re-checking Chrome is closed before each write; failures stay
  pending, retry at the next quit and show a banner. Slots record Cookies `meta.version`; a change refuses the
  import ("Chrome updated, sign in to the extension once"). Chrome is "switched (unconfirmed)" unless the
  extension writes its storage after reopening and reports the target account.
- Extension auth hosts (read from its JS): authorize at `claude.ai/oauth/authorize` (cookie-authenticated),
  token exchange at `platform.claude.com/v1/oauth/token` (PKCE code, no cookies). Only the claude.ai family moves.
- `state.inFlight` is written before the first destructive step and cleared after a successful restore; at
  startup an interrupted operation is undone from its backup if Claude is closed. A failed restore never relaunches.
- An unconfirmed launch shows "Switch not confirmed" with Roll back. All `oauth:` keys are dropped; an unknown
  one pauses switching. Busy chats are informational (desktop sessions only; subagents and terminal sessions skipped).

## Parallel windows

Up to 3 extra Claude windows run at once, each signed in to a different saved account, next to the main
window. Off by default: Settings → **Parallel Windows**. With the setting off the panel is exactly as before.

### Rules

- One account in one place at a time: the main window counts. An account open in a window cannot be switched to,
  and the main window's account cannot get a window.
- At most 3 extra windows. Pressing Open at the cap says "Close a window first (3 at most)."
- Windows never reopen at login or when the app starts. Reconciling at launch only marks windows whose process
  is gone ("vanished") or adopts ones found running; nothing is launched by itself.
- Closing a window never touches the main window: the engine signals only that window's exact pid (SIGTERM,
  waits, never force-kills) and never calls `NSRunningApplication.terminate` on the bundle id while extra
  windows run without scoping to a pid.
- Every setting matches the main window; background jobs (scheduled tasks, remote control, keep awake,
  auto-archive on PR close and of inactive chats, per-PR auto-fix / CI-monitor) run only in the main window. The
  keep-awake options (`ccKeepAwake*`) are copied as they are: they only hold the Mac awake while a session in that
  window works.
- Chats (chat cards, sidebar pins and groups) are the same in every window.
- Each extra window does ONE real sign-in of its own. A saved login copied into a window triggers Claude's "sign in
  again for your security" banner, so it is never done, and the device id (`ant-did`) is never copied.

### Data and registry

- Window data dir: `~/Library/Application Support/ClaudeAccounts/windows/<accountUuid>/` (0700).
- Registry: `~/Library/Application Support/ClaudeAccounts/windows.json`
  `{"version":1,"windows":[{"accountId","dataDir","signedIn","openedAt","pid"}]}`, written atomically by the engine
  only. Readers (the chat mirror) tolerate a missing file.
- Launch: `/usr/bin/open -n -a /Applications/Claude.app --args --user-data-dir=<dataDir>`. A window's process is the
  one whose args are exactly `/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=<dataDir>`.

### Open (account already signed in its window)

1. Checks: setting on, cap, one account in one place.
2. Settings sync, run while that window is closed, right before every launch:
   `/usr/bin/python3 -I sync-window-settings.py --from "~/Library/Application Support/Claude" --to <dataDir> --apply --extra-window`.
   Only SETTING items are copied; logins, cookies, device ids, updater state, window geometry and caches of the window
   stay. Every replaced file is first copied to `<dataDir>/.settings-sync-backup/<timestamp>/`.
   `--extra-window` switches background jobs off in the window only. If the copy fails the window opens (with a warning) only when its own `claude_desktop_config.json` already has those jobs explicitly off; otherwise the open is refused.
3. Chat sync pass, then launch with the line above and record the pid in the registry.

### First sign-in (an account that never had its own window)

Claude's sign-in returns through a `claude://` link that macOS hands to the first Claude window, so the main
window is closed for about a minute:

0. Refused while any other extra window is open (macOS would hand the sign-in link to that window).
1. Confirmation in the panel, one line: "To sign this account in, your main Claude window closes for about a minute."
2. Chat sync. 3. Quit the main window (its own "still working" dialog may ask). 4. Settings-sync and open the new
window at its sign-in screen. 5. Wait until that window's `config.json` `lastKnownAccountUuid` is the target account.
6. Reopen the main window.

Every failure or cancel after the main window was closed undoes the flow: the new window is closed, a wrong-account
folder is removed and the main window reopens. Later opens of the same account skip all of this.

### Updates

Claude cannot be stopped from updating per instance. An extra window may quit by itself to install an update and
cannot (the main window is still running). The engine reads the `update-attempt` marker in the window's data
dir: the window is shown as waiting for the update and **reopens** once the main window reaches the target version.
The reopen is a visible window action ("Reopening window…", rows dimmed) that the app starts only when nothing else is
running, and it is skipped, never queued, while a switch, open, close or sign-in runs (tried again 30 s later).
All of those actions, and rollback and add, go through one serial lock (`ActionGate`) shared by the switch and window
engines: a second one waits its turn (first come, first served) instead of overlapping.
Opening a window warns when the main window already has an update staged ("update the main window first").
Research: `research/2026-10-09-parallel-windows/UPDATES.md`.

### Chat sync

`scripts/session-sync/mirror.py` in this repo is the source of truth for `~/.claude/session-sync/mirror.py`. It reads
`windows.json` and mirrors `<dataDir>/claude-code-sessions` of every registered window together with the main
roots (newest wins, never delete). In window copies it strips per-PR auto-fix flags and syncs sidebar prefs.
The app bundle ships a copy (`Resources/mirror.py`) and the engine runs that one for its sync passes (switch, open, close;
then `CLAUDE_ACCOUNTS_MIRROR_SCRIPT`, then the deployed file). `--reload` and `--write-plist` always run the deployed file.
The background agent runs the deployed file too: copying the bundled one over `~/.claude/session-sync/mirror.py` is a
separate step by hand. Each window keeps a record of the sidebar values it
last had in step with the main window (`ccd-sidebar-base.json` in its data dir). When the main window is closed, only
what the window changed since that record goes back (a three-way merge): a pin added in a window arrives, one removed
in either window stays removed, and a stale value the window never touched cannot undo what the main window did. A
window with no record yet is only pushed to.

### Panel

With the setting on, clicking a row expands it in place and only the expanded row shows its small buttons (collapsed rows
show none): an account in the main window shows "Main window" and none; an account in its own window shows a window
icon, "Open in its own window", **Show** and **Close**; any other shows its normal subtitle with **Switch** (main
window, as before) and **Open** (own window). Every account that is open somewhere, the main window's and each extra
window's, shows the checkmark. No explanatory text in rows. Right-click offers the same actions. See `research/2026-10-09-parallel-windows/UX.md`.

### Files

- Engine (`ClaudeAccountsCore`): `ParallelWindows.swift` (paths, cap, process map, instance-scoped quit, registry model),
  `WindowEngine.swift` (open, close, reconcile, update reopen), `ActionGate.swift` (the one-action-at-a-time lock),
  `FirstSignIn.swift` (first sign-in flow),
  `System.swift` (settings and chat sync runners), `PanelCopy.swift` (text).
- App: `AppModel.swift`, `PanelView.swift`, `SettingsView.swift`.
- Scripts: `scripts/sync-window-settings.py` (bundled in the app's Resources by `scripts/build-app.sh`; the engine
  falls back to `CLAUDE_ACCOUNTS_SETTINGS_SCRIPT`, then the repo copy), `scripts/session-sync/mirror.py`.
- Tests: `swift test` (Parallel windows suites), `python3 -I -m unittest discover -s scripts/tests`,
  `python3 -I -m unittest discover -s scripts/session-sync/tests`.
- Research: `research/2026-10-09-parallel-windows/` (DESIGN, TEST-RESULTS, UPDATES, UX, settings-parity).

## Usage (per account)

Each row shows a 5-hour usage ring; the expanded row shows "5h" and "Week" lines with real reset
times. Data source and rules:

- **Token:** Claude.app's `oauth:tokenCacheV2` in config.json, an Electron safeStorage `v10` blob.
  The current account's is read from the live config (read-only); each saved account's raw,
  still-encrypted blob is copied to `slots/<uuid>/desktop/oauth-cache-v2` (0600, with `.prev`) at
  every save-outgoing, but only when the cookie guard and account attribution both pass.
- **Decrypt:** the "Claude Safe Storage" Keychain secret (one system prompt; "Always Allow") →
  PBKDF2-HMAC-SHA1(salt "saltysalt", 1003, 16 bytes) → AES-128-CBC, IV 16 spaces, PKCS7, after the
  `v10` prefix. The derived key lives in memory only. A `user:profile`-scoped, unexpired access
  token is selected; the refresh token is never used and tokens are never refreshed.
- **Fetch:** `GET https://api.anthropic.com/api/oauth/usage` with the bearer, `anthropic-beta:
  oauth-2025-04-20` and `User-Agent: ClaudeAccounts/1.0`. Reads `five_hour` and `seven_day`
  (`utilization`, `resets_at`); `utilization > 1` is treated as a percentage.
- **No refresh, no writes to Claude's files.** Expired token or 401/403 → `needsRefresh` (grey ring,
  "Open to Refresh"; switching refreshes it). 429 → honour `Retry-After` (cap 24 h, else 30 min),
  keep showing stale cache. Network error → keep cache, mark stale.
- **Schedule:** every 15 min, one account at a time, 5 s apart; a debounced panel-open refresh of
  data older than 5 min; paused while asleep, resumed on wake with jitter. The last numbers and
  `fetchedAt` live in `usage.json` (0600, not secret) so the panel shows instantly.
- **Settings:** "Show Usage" (default on). Off means no Keychain read and no network at all.
- **Logs** carry only status codes, timestamps and account uuids — never a token, key or value.
- **Hardening (review, 2026-10-08):** scheduling is by attempt with per-account exponential backoff
  (15 → 30 → 60 min, cap 6 h) on 5xx, network errors, a missing token or an unparseable 200 (which
  keeps the previous values, stale). `needsRefresh` accounts aren't polled until a switch makes them
  current or their slot blob changes. Panel opens queue at most one round per 5 min through the same
  5 s-spaced queue. A Keychain denial is cached for the process (Settings → Retry Keychain Access).
  `utilization` is a 0–100 percent: the app renders it via `Tl = max(0, min(100, floor(x)))` with
  no ×100. `resets_at` accepts fractional seconds. The HTTP session is ephemeral (no URL cache, no
  cookies), refuses redirects, and only reaches `https://api.anthropic.com`. Tokens tagged with
  another account are dropped. The live cache isn't read during an add.
- **Cache structure (asar, corrected 2026-10-08):** the value is `safeStorage.encryptString(
  JSON.stringify(cache)).toString("base64")`. The cache is an object keyed
  `[acct:<uuid>|]clientId:x:apiHost:scope`; account and scope live in the key, and each value is
  `{token, expiresAt(ms), …}` (field `token`, not `accessToken`). The app clears the cache on an
  identity change, so untagged entries are the live account's. Selection: drop entries tagged with
  another account, keep `user:profile`, prefer unexpired, then the Claude Code scope set, then the
  latest `expiresAt`; `ambiguous` only when tagged with two other accounts and none with the target.
  A missing token logs one reason: keychain-denied, keychain-missing, decrypt-failed,
  json-parse-failed, no-entries, no-profile-scope (counts and scope names), ambiguous (counts), or
  expired (minutes) — never a value.
