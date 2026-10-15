#!/bin/bash
# Installs Rotor autopilot: automatic account switching at the usage limit + automatic chat resume.
# Safe to re-run (it updates files in place and keeps the quit helper's Accessibility grant).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/.claude/rotor-autopilot"
HELPER="$HOME/Applications/RotorQuitHelper.app"
TASK_DIR="$HOME/.claude/scheduled-tasks/rotor-autoresume"
AGENTS="$HOME/Library/LaunchAgents"
UID_N="$(id -u)"

[ -x "$HOME/.local/bin/rotor" ] || { echo "Rotor's command line tool is missing. Build Rotor first: scripts/build-app.sh"; exit 1; }
[ -d /Applications/Claude.app ] || { echo "Claude desktop app not found in /Applications."; exit 1; }

mkdir -p "$DIR" "$TASK_DIR" "$AGENTS" "$HOME/Applications"
cp "$SRC/autopilot.py" "$SRC/quitter.applescript" "$DIR/"
sed "s#__HOME__#$HOME#g" "$SRC/resume-task.md" > "$TASK_DIR/SKILL.md"

# Claude asks "Claude is still working - quit anyway?" while chats run. This tiny helper app clicks
# "Quit anyway" during a switch. It only loads quitter.applescript, so later updates keep its
# Accessibility grant. Built once; never rebuilt if it exists (a rebuild would drop the grant).
NEW_HELPER=0
if [ ! -d "$HELPER" ]; then
  TMP="$(mktemp -d)"
  printf 'run script (POSIX file "%s/quitter.applescript")\n' "$DIR" > "$TMP/main.applescript"
  osacompile -o "$HELPER" "$TMP/main.applescript"
  plutil -replace CFBundleIdentifier -string local.rotor.quithelper "$HELPER/Contents/Info.plist"
  plutil -replace CFBundleName -string RotorQuitHelper "$HELPER/Contents/Info.plist"
  plutil -replace LSUIElement -bool true "$HELPER/Contents/Info.plist"
  codesign --force --sign - "$HELPER"
  rm -rf "$TMP"
  NEW_HELPER=1
fi

cat > "$AGENTS/local.rotor.autopilot.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.rotor.autopilot</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-I</string><string>$DIR/autopilot.py</string>
  </array>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.err</string>
</dict></plist>
PL
# Keeps the Mac awake (display may sleep) so switches and resumes happen overnight.
cat > "$AGENTS/local.rotor.awake.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.rotor.awake</string>
  <key>ProgramArguments</key><array><string>/usr/bin/caffeinate</string><string>-ims</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
for L in local.rotor.autopilot local.rotor.awake; do
  launchctl bootout "gui/$UID_N/$L" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_N" "$AGENTS/$L.plist"
done

# Claude Code: when a chat stops on a usage limit, wait for the reset and continue by itself.
/usr/bin/python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
try:
    d = json.load(open(p))
except FileNotFoundError:
    d = {}
d["autoContinueAtUsageLimit"] = True
json.dump(d, open(p, "w"), indent=2)
PY

echo "Rotor autopilot installed. Log: $DIR/autopilot.log"
if [ "$NEW_HELPER" = 1 ]; then
  open -g "$HELPER"   # makes macOS list it under Accessibility
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  echo
  echo "ONE STEP LEFT: in System Settings > Privacy & Security > Accessibility, turn on RotorQuitHelper"
  echo "(click + and pick ~/Applications/RotorQuitHelper.app if it isn't listed)."
fi
echo "Then quit and reopen Claude once so it loads the resume task."
