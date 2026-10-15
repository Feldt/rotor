# Rotor

A menu bar app that switches the Claude desktop app between your Claude accounts. Sign in to each
account once; after that, one click swaps accounts in about 5–10 seconds with no sign-in. It can also
show each account's 5-hour usage, open extra Claude windows on other accounts side by side, and
(optionally) switch Claude in Chrome along with the desktop app. Design notes: [SPEC.md](SPEC.md).

**Autopilot** (optional): switches accounts automatically at the usage limit and resumes your chats
after every switch. See [autopilot/README.md](autopilot/README.md).

This is a personal tool shared as source, not an official Anthropic product. It works by quitting Claude,
swapping Claude's saved login files on your Mac and reopening it. Nothing leaves your Mac except the
usage check, which calls Anthropic's own usage endpoint with your own token.

## Quickest setup

Paste this into Claude Code (in the Claude desktop app) and it will do the install with you:

> Set up Rotor with its autopilot from https://github.com/Feldt/rotor. Follow SETUP.md.

## Before you start

- **macOS 26 (Tahoe)** or later.
- **Xcode 26** (or its Command Line Tools with Swift 6.2). Check with `swift --version`.
- The **Claude desktop app** in `/Applications`.
- **A switch quits Claude.** Any Claude Code session running in the desktop app stops when you switch.
  Finish or pause that work first.
- **Never press Sign out** in Claude (or in Claude in Chrome) for an account Rotor has saved. Signing out
  revokes that login on Anthropic's side, and Rotor can't bring it back. Use Rotor's sign-in-again instead.

## Install

```sh
cd Rotor
scripts/build-app.sh              # builds, signs and installs ~/Applications/Rotor.app
                                  # and links the command line tool to ~/.local/bin/rotor
open ~/Applications/Rotor.app
```

The build takes about a minute. It signs with your "Apple Development" certificate if you have one,
otherwise ad hoc (fine, see "Usage and the Keychain prompt" below). Rotor turns on Open at Login the first
time it runs; turn it off in Settings if you don't want that.

`rotor status` is a read-only report and safe at any time. ⌥⌘A opens the panel.

The menu bar shows a two-disc glyph. A small dot on it means something needs you: a login
expiring within 7 days, or a switch that wasn't confirmed. The panel lists accounts
(checkmark = open in a window; "5d" = login expires in 5 days; "Expired" = click to sign in again),
then Add Account…, Settings… and Quit.

## Uninstall

1. Quit Rotor (panel → Quit) and turn off Open at Login in its Settings first.
2. Delete `~/Applications/Rotor.app`, `~/.local/bin/rotor` and `~/.local/bin/claude-accounts`.
3. Saved logins live in `~/Library/Application Support/ClaudeAccounts`. Delete that folder only if you no
   longer want them; Claude keeps whichever account is loaded at the time.

## First run

1. The account Claude is signed in to now is registered automatically and shows a **Name** field
   in its row: type a label (e.g. `team@example.com`) and press Return. No local file holds the
   email, so labels are yours.
2. **Add Account…**: type a label in the new row, Return. Claude quits (chats are synced first), the
   current login is saved, and Claude reopens at its sign-in screen. Sign in; the panel registers
   the new account by itself. Repeat per account. Each account is signed in once.
3. Optional: Settings… → **Switch Chrome**. Confirm which account Chrome is signed in to now
   ("Chrome is signed in as …" → Confirm); nothing touches Chrome before that. By default Chrome
   restarts **with Claude**: both quit together, both come back on the new account. If Chrome won't
   quit within 20 s (its own dialog), Claude switches anyway and Chrome switches when you next quit
   it. An account without a saved Chrome login gets claude.ai cleared in Chrome (locally, no
   sign-out) and Chrome reopens on claude.ai/login: sign in once there. Turn on Chrome's
   "Continue where you left off" so tabs come back; otherwise the panel warns before a switch.
   "When Chrome Quits" in Settings keeps the old behaviour.

Click an account to open it: its usage (once a usage source exists) and, for another account, a
**Switch** button (~5–10 s; Claude quits and reopens). The thin ring around an avatar is that
account's 5-hour usage, amber from 80 %, red from 95 %, grey when it needs a refresh. No data, no ring.

### Usage and the Keychain prompt

Usage is read from Claude's own encrypted oauth token, which needs the "Claude Safe Storage" Keychain
item, so macOS asks once: choose **Always Allow**. If the build found an **Apple Development**
certificate, the signature stays the same across rebuilds and macOS won't ask again until that
certificate renews (yearly). If it signed ad hoc, macOS asks again after each rebuild; the self-signed
option under "Signing" below avoids that.
Settings → **Show Usage** (on by default) turns usage off entirely: no Keychain read, no network.
Tokens are never refreshed by this app; a grey ring ("Open to Refresh") clears after you switch to
that account once.

The very first signed build may also ask to let `codesign` use the key (Always Allow); the build
stops rather than retrying if that prompt is left waiting.

## Parallel windows

Settings → **Parallel Windows** (off by default) lets you open up to 3 extra Claude windows at once, each on a
different saved account, next to the main window. Click an account to expand its row: it then shows small
**Switch** and **Open** buttons (an account already in a window has **Show** and **Close**); collapsed rows show none.
Every account that is open somewhere has the checkmark.

- An account is in one place at a time; the main window counts.
- The first time an account gets its own window you sign in once inside it. Claude's sign-in link goes to the
  first Claude window, so the main window closes for about a minute (you are asked first)
  and reopens by itself afterwards. Later opens need no sign-in.
- Settings match the main window; scheduled tasks and other background jobs run only in the main window.
  Chats are the same in every window.
- Closing a window closes only that window. Windows never reopen at login, and one that quit to install an
  update comes back after the main window updates.
- Needs `scripts/build-app.sh` (it puts `sync-window-settings.py` and `mirror.py` in the app's Resources). Details: SPEC.md,
  "Parallel windows".


## Never

- **Never press Sign out** in Claude or in Claude in Chrome. It revokes that saved login on the
  server; the switcher can't bring it back. Use Sign in again instead.
- Don't force-quit Claude mid-switch. The app itself never force-quits anything; if Claude won't
  quit within 2 minutes, the switch aborts with nothing changed.

## Development

`swift test` runs the engine against fake trees. Every path is overridable (`CLAUDE_ACCOUNTS_ROOT`,
`CLAUDE_USERDATA_DIR`, `CHROME_PROFILE_DIR`, `SESSION_SYNC_DIR`, `CLAUDE_PROJECTS_DIR`,
`CLAUDE_LOGS_DIR`, `CLAUDE_APP_PATH`, `CHROME_APP_PATH`). `scripts/demo-panel.sh` opens the panel on
a dummy tree with a dry-run controller. CLI commands that write refuse real paths unless
`--real-data` is passed. `rotor usage` prints the cached `usage.json` with no Keychain or
network access; `rotor usage --refresh` fetches live and needs `--real-data`. `scripts/make-icon.sh` renders the icon from `scripts/render-icon.swift`;
`scripts/capture-panel.sh <state>` captures the demo panel over a system wallpaper. Panel host: `defaults write local.rotor.claude-accounts panelStyle panel`
switches to the NSPanel fallback.

## Updating

Settings… → About shows the running commit and build date and whether it's **Up to Date**,
**Update Available** (the folder's git HEAD moved; this copy ships without git history, so the version reads "unknown" and Update has nothing to compare until you `git init` and commit) or **Running an Old Copy** (not the one in
`~/Applications`). **Update** rebuilds from this repo with `scripts/build-app.sh`, installs the single
copy in `~/Applications` and restarts into it; a failed build keeps the current version running and
offers **Show Log** (`update.log` in the store). The build folder never keeps a launchable `.app`.

### Signing

`scripts/build-app.sh` signs with the first "Apple Development" identity in your Keychain (override with
`CLAUDE_ACCOUNTS_SIGN_ID`), never a Developer ID, and falls back to ad hoc only if none exists.

### Optional: a self-signed identity instead (not done for you)

macOS ties the Keychain "Always Allow" to the app's code signature, and ad-hoc signatures change on
every build, so each update asks again. A stable self-signed code-signing identity avoids that.
Creating one **adds a certificate and private key to your login keychain**, so it's your call:

1. Keychain Access → Certificate Assistant → Create a Certificate… Name: `Rotor Local`,
   Identity Type: Self Signed Root, Certificate Type: Code Signing.
2. Build with `CLAUDE_ACCOUNTS_SIGN_ID="Rotor Local" scripts/build-app.sh`.
3. Rebuild that way once and choose Always Allow; later rebuilds keep it.

To undo, delete the certificate and its key from Keychain Access and build without the variable again.
