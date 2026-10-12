#!/bin/zsh
# Installs the launch-at-login agent file (the fallback when Open at Login can't use SMAppService). It points at
# ~/Applications/Rotor.app. The label and file name keep the app's old name on purpose: see SPEC.md, "Naming".
# It does NOT load it; run the printed command yourself.
set -euo pipefail
cd "${0:A:h}"
DEST="$HOME/Library/LaunchAgents/local.rotor.claude-accounts.plist"
mkdir -p "${DEST:h}"
sed "s#__HOME__#$HOME#g" local.rotor.claude-accounts.plist > "$DEST"
plutil -lint "$DEST"
echo "Wrote $DEST. To enable now:"
echo "  launchctl bootstrap gui/$(id -u) \"$DEST\""
