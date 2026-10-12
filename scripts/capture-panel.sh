#!/bin/zsh
# Opens the demo panel in a given state and captures it to docs/panel-<state>.png.
# Uses only the fake demo tree (scripts/demo-panel.sh). usage: scripts/capture-panel.sh <state>
set -euo pipefail
cd "${0:A:h}/.."
STATE="${1:-normal}"
pkill -f "release/ClaudeAccounts" 2>/dev/null || true
sleep 0.5
(./scripts/demo-panel.sh "$STATE" > /tmp/claude-accounts-demo.log 2>&1 &)
sleep 3.5
PID=$(pgrep -f "release/ClaudeAccounts" | head -1)
RECT=$(swift - "$PID" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
// Front-to-back list of on-screen windows.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
func bounds(_ w: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary)! }
var best: CGRect = .zero
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = bounds(w)
    if b.width < 420, b.height > 40, b.width * b.height > best.width * best.height { best = b }
}
// Safety: only capture our own window, on the main display, frontmost over its rect.
let main = CGDisplayBounds(CGMainDisplayID())
guard best.width > 0, main.contains(best) else { print("BLOCKED"); exit(1) }
for w in list {
    let b = bounds(w)
    guard b.intersects(best), (w[kCGWindowLayer as String] as? Int ?? 0) < 1000 else { continue }
    if (w[kCGWindowOwnerPID as String] as? Int32) == pid { break }
    print("BLOCKED"); exit(1)
}
let m: CGFloat = 20
print("\(Int(best.minX - m)),\(Int(best.minY - 2)),\(Int(best.width + 2 * m)),\(Int(best.height + m + 2))")
SWIFT
) || { pkill -f "release/ClaudeAccounts" || true; echo "refused: window not safely capturable"; exit 1; }
[[ "$RECT" == BLOCKED ]] && { pkill -f "release/ClaudeAccounts" || true; echo "refused"; exit 1; }
screencapture -x -R"$RECT" "docs/panel-$STATE.png"
pkill -f "release/ClaudeAccounts" || true
echo "docs/panel-$STATE.png ($RECT)"
