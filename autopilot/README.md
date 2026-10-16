# Rotor autopilot

Keeps your Claude Code chats in the desktop app running around the clock across all your Claude
accounts. Nobody has to click anything.

- **Switches by itself.** Every 2 minutes it checks usage on every account Rotor knows. When the
  current account reaches 99% of its 5-hour or weekly limit, it switches to the
  account with the most room.
- **Resumes chats after a restart.** A switch restarts Claude, which stops every chat and kills its
  background agents, workflows, monitors and wakeups. About 3 minutes after any Claude start, a
  resume chat messages every chat active in the last 8 hours. Each one then restarts what it had
  running and carries on. A chat that was already done replies `IDLE` and is left alone.
- **Watchdog.** A chat can go quiet for 45 minutes after its turn ends, along with its subagents and
  workflows. That usually means it was waiting for something that died, so it gets a nudge. So does a
  chat that stopped on a usage limit, once there is room again.
- **Waits out the limits.** When every account is out of usage, it waits, and switches as soon as one
  resets.

## Setup (about 5 minutes)

1. **Build Rotor** and sign in to each of your Claude accounts in it once (see the main
   [README](../README.md)):
   ```sh
   scripts/build-app.sh
   open ~/Applications/Rotor.app
   ```
2. **Install the autopilot:**
   ```sh
   autopilot/install.sh
   ```
3. **Grant Accessibility.** The installer opens System Settings > Privacy & Security >
   Accessibility. Turn on **RotorQuitHelper**. This small helper clicks "Quit anyway" when Claude
   says it is still working during a switch.
4. **Quit and reopen Claude once.** This loads the resume task.

To check that it's running:
```sh
tail -f ~/.claude/rotor-autopilot/autopilot.log
```
About every 30 minutes you'll see a line like `ok: you@example.com at 5h 40% week 22%`.

## Good to know

- **Never press Sign out in Claude** for an account Rotor has saved, because Rotor can't bring that
  login back. If a saved login goes stale, Claude shows a "log in again" screen. The autopilot detects
  this, skips that account for 24 hours, and the log tells you to sign in to it again in Rotor.
- **Watch the first resume.** The resume chat sends messages to your other chats. If it stops at a
  permission prompt, choose "always allow" once.
- **Pick your chat folder.** The resume and keeper chats run in your home folder.
- **The Mac stays awake.** `caffeinate` keeps the Mac from sleeping (the display can still turn off),
  so all of this works overnight.
- **Change the thresholds** at the top of `autopilot.py`, then re-run `install.sh`.
- **Try it without switching:**
  ```sh
  python3 ~/.claude/rotor-autopilot/autopilot.py --dry-run
  ```
  This logs what it would do and changes nothing.
- **Force a switch now:**
  ```sh
  python3 ~/.claude/rotor-autopilot/autopilot.py --force-switch
  ```
- **Uninstall:**
  ```sh
  autopilot/uninstall.sh
  ```

## How it works

| Piece | Where | What it does |
|---|---|---|
| `autopilot.py` | `~/.claude/rotor-autopilot/` | Runs every 2 min from launchd (`local.rotor.autopilot`). It switches accounts, runs the watchdog, and keeps the resume task armed. |
| `rotor-autoresume` task | `~/.claude/scheduled-tasks/` plus each account's `scheduled-tasks.json` | Claude loads scheduled tasks only at startup. Keeping this one-shot task armed a little ahead means every start fires it. |
| Resume / keeper chat | a new chat after every start | Messages every chat the restart cut off (`autopilot.py --targets`). It then waits in the background for watchdog nudges (`autopilot.py --claim-nudges`) and delivers them. |
| `RotorQuitHelper.app` | `~/Applications/` | Clicks "Quit anyway" on Claude's quit sheet during a switch. |
| `local.rotor.awake` | launchd | Runs `caffeinate -ims`, so the Mac stays awake while plugged in. |

Everything stays on your Mac. The only network call is Rotor's usage check to Anthropic, made with
your own login.
