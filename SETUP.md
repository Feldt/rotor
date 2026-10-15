# Setup guide for Claude Code

The fastest way to install Rotor is to paste this into Claude Code in the Claude desktop app:

> Set up Rotor with its autopilot from https://github.com/Feldt/rotor. Follow SETUP.md.

The rest of this file is the guide Claude follows. Each step that needs a person says so.

---

## For Claude: install steps

Work through these in order. Before each step, tell the user in one line what's happening. After
each step, check the result before moving on.

1. **Check the Mac.**
   - macOS 26 or later: `sw_vers -productVersion`.
   - Swift 6.2 or later: `swift --version`. If Swift is missing, ask the user to install Xcode from
     the App Store or run `xcode-select --install`, then wait for them.
   - The Claude desktop app is at `/Applications/Claude.app`.
2. **Get the code.**
   ```sh
   git clone https://github.com/Feldt/rotor ~/Rotor
   ```
   If `~/Rotor` already exists, run `git -C ~/Rotor pull` instead.
3. **Build and open Rotor.** The build takes about a minute.
   ```sh
   cd ~/Rotor && scripts/build-app.sh && open ~/Applications/Rotor.app
   ```
4. **The user adds their accounts.** Ask them to open Rotor (the two-disc icon in the menu bar),
   choose **Add Account…** and sign in to each Claude account they want to use. Wait until they say
   they're done. Then check with `~/.local/bin/rotor status`, which should list every account.
   - Warn them never to press **Sign out** in Claude for an account Rotor has saved. Rotor can't
     bring that login back.
   - Warn them that switching accounts restarts Claude. That includes this chat, and the autopilot
     resumes it afterwards.
5. **Install the autopilot.**
   ```sh
   ~/Rotor/autopilot/install.sh
   ```
6. **The user grants Accessibility.** The installer opens System Settings > Privacy & Security >
   Accessibility. Ask the user to turn on **RotorQuitHelper**. If it isn't in the list, they click
   **+** and pick `~/Applications/RotorQuitHelper.app`. Wait for them to confirm.
7. **The user restarts Claude.** Ask them to quit and reopen Claude once, so it loads the resume task.
   Tell them that about 3 minutes after Claude reopens, a chat called "Resume chats after account
   switch" will appear. It sends a message to each chat that was running. If it stops at a permission
   prompt, they should choose "always allow".
8. **Confirm it's running.** After the restart, the user can run (or ask Claude to run):
   ```sh
   tail -5 ~/.claude/rotor-autopilot/autopilot.log
   ```
   Every 30 minutes or so it logs an `ok:` line with the current account's usage.

Done. From now on Claude switches accounts by itself when one runs low, and picks up every chat
after each switch. For details see [autopilot/README.md](autopilot/README.md).
