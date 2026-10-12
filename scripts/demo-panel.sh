#!/bin/zsh
# Launches the built app against a fake demo tree, with a dry-run app controller (it never quits or
# opens Claude or Chrome) and the panel opened.
# Usage: scripts/demo-panel.sh [normal|expiring|unnamed|switching|expanded|parallel] [menuBarExtra|panel]
set -euo pipefail
cd "${0:A:h}/.."
D="${TMPDIR:-/tmp}/claude-accounts-demo"
ENVS=("${(@f)$(./scripts/make-demo-tree.sh "$D" "${1:-normal}" | tr ' ' '\n')}")
mkdir -p "$D/apps/Claude.app" "$D/apps/Chrome.app"
for e in $ENVS; do export "$e"; done
export CLAUDE_APP_PATH="$D/apps/Claude.app" CHROME_APP_PATH="$D/apps/Chrome.app"
export CLAUDE_ACCOUNTS_DRY_CONTROLLER=1 CLAUDE_ACCOUNTS_OPEN_PANEL=1 CLAUDE_ACCOUNTS_PANEL_STYLE="${2:-menuBarExtra}" CLAUDE_ACCOUNTS_DEMO_STATE="${1:-normal}"
[[ "$CLAUDE_ACCOUNTS_ROOT" == "$D"/* ]] || { echo "demo env missing; refusing"; exit 1; }
exec "$(swift build -c release --show-bin-path)/ClaudeAccounts"
