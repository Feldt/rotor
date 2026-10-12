#!/bin/zsh
# Builds Rotor.app (release), signs it and installs it to ~/Applications/Rotor.app.
# Also installs the rotor CLI to ~/.local/bin, with claude-accounts kept as an alias. Does not launch or
# quit anything. When it installs, a leftover ~/Applications/Claude Accounts.app (the app's old name) is
# moved to the Trash once Rotor.app is installed and verified; nothing is ever deleted.
#
# Only the visible name changed. The bundle identifier, data folder, Keychain items, LaunchAgent label and
# defaults domain keep their old names so nothing resets (SPEC.md, "Naming"). So does the bundled command
# line binary, `claude-accounts`: codesign derives its identifier from the file name, and macOS ties the
# Keychain "Always Allow" to that identifier.
set -euo pipefail
cd "${0:A:h}/.."

echo "Building…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Rotor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The app binary is named for the app (it shows as Rotor in Activity Monitor); the SwiftPM product keeps its name.
cp "$BIN/ClaudeAccounts" "$APP/Contents/MacOS/Rotor"
cp "$BIN/claude-accounts" "$APP/Contents/MacOS/claude-accounts"
[[ -f Resources/AppIcon.icns ]] || ./scripts/make-icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Parallel windows: the settings sync script the engine runs before each extra window opens.
cp scripts/sync-window-settings.py "$APP/Contents/Resources/sync-window-settings.py"
# The chat sync the engine runs on every switch and window open (it reads windows.json for extra windows).
cp scripts/session-sync/mirror.py "$APP/Contents/Resources/mirror.py"
VERSION="1.0.$(git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && COMMIT="$COMMIT-dirty"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPO="$PWD"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.rotor.claude-accounts</string>
  <key>CFBundleName</key><string>Rotor</string>
  <key>CFBundleDisplayName</key><string>Rotor</string>
  <key>CFBundleExecutable</key><string>Rotor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>CAGitCommit</key><string>${COMMIT}</string>
  <key>CABuildDate</key><string>${BUILD_DATE}</string>
  <key>CARepoPath</key><string>${REPO}</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Stable signing: your Apple Development identity (override with CLAUDE_ACCOUNTS_SIGN_ID), so the
# Keychain's "Always Allow" survives rebuilds. Never the company's Developer ID. Ad hoc only if none.
SIGN_ID="${CLAUDE_ACCOUNTS_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)"
fi
if [[ "$SIGN_ID" == *"Developer ID"* ]]; then
  echo "Refusing to sign with a Developer ID identity ($SIGN_ID)" >&2; exit 1
fi
[[ -z "$SIGN_ID" ]] && SIGN_ID="-"
echo "Signing with: $SIGN_ID"

# One attempt, with a watchdog: the first use of the key may show a Keychain prompt. If codesign
# fails or is still waiting after 60 s, stop (no retries).
sign() {
  codesign --force --sign "$SIGN_ID" "$1" &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    sleep 1; waited=$((waited + 1))
    if (( waited >= 60 )); then
      kill $pid 2>/dev/null
      echo "codesign is waiting (probably a Keychain prompt to allow codesign to use the key). Stopped; not retrying." >&2
      exit 3
    fi
  done
  wait $pid || { echo "codesign failed for $1; not retrying." >&2; exit 4; }
}
sign "$APP/Contents/MacOS/claude-accounts"
sign "$APP"
codesign --verify --strict "$APP"
echo "Designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

mkdir -p "$HOME/Applications"
DEST="$HOME/Applications/Rotor.app"
OLD="$HOME/Applications/Claude Accounts.app"   # the app's name before the rename
echo "Installing…"
# Exactly one installed copy. Stage beside it, then swap, so a failed copy never leaves none.
STAGE="$HOME/Applications/.Rotor.app.new"
rm -rf "$STAGE"
cp -R "$APP" "$STAGE"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
# The build-folder bundle is only an intermediate: remove it so it can't be launched by mistake.
rm -rf "$APP"

# Verify the installed copy before anything else changes: signature intact, the name and the binaries
# are what the install is meant to put there.
codesign --verify --strict "$DEST"
[[ "$(plutil -extract CFBundleName raw "$DEST/Contents/Info.plist")" == "Rotor" ]] \
  || { echo "Installed bundle is not named Rotor; leaving everything else as it is." >&2; exit 5; }
[[ -x "$DEST/Contents/MacOS/Rotor" && -x "$DEST/Contents/MacOS/claude-accounts" ]] \
  || { echo "Installed bundle is missing a binary; leaving everything else as it is." >&2; exit 5; }

mkdir -p "$HOME/.local/bin"
ln -sfn "$DEST/Contents/MacOS/claude-accounts" "$HOME/.local/bin/rotor"
ln -sfn "$DEST/Contents/MacOS/claude-accounts" "$HOME/.local/bin/claude-accounts"   # the old command keeps working
echo "Installed $DEST ($COMMIT, $BUILD_DATE)"
echo "CLI: $HOME/.local/bin/rotor (claude-accounts is an alias)"

# Only now retire the old name: to the Trash (recoverable), never deleted. Not touching it is safe too.
if [[ -d "$OLD" ]]; then
  if /usr/bin/trash -s "$OLD"; then
    echo "Moved the old $OLD to the Trash."
  else
    echo "Could not move $OLD to the Trash. Move it there yourself; Rotor is installed and works without that." >&2
  fi
  cat <<NOTE
Open at Login: macOS recorded it against the old app. Open Rotor once, then check Settings -> Open at Login is on
and System Settings -> General -> Login Items lists Rotor. If it still says Claude Accounts, or Rotor is not
listed, switch Open at Login off and on once in Rotor's Settings. Quit the old Claude Accounts first if it is running.
NOTE
fi
# A launch-at-login LaunchAgent made by scripts/install-login-agent.sh before the rename points at the old path.
AGENT="$HOME/Library/LaunchAgents/local.rotor.claude-accounts.plist"
if [[ -f "$AGENT" ]] && grep -q "Claude Accounts.app" "$AGENT"; then
  echo "Warning: $AGENT still points at the old app. Re-run scripts/install-login-agent.sh and bootstrap it again." >&2
fi
