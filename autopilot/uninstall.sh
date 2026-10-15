#!/bin/bash
# Stops Rotor autopilot. Leaves logs and the helper app in place (remove them by hand if you like).
UID_N="$(id -u)"
for L in local.rotor.autopilot local.rotor.awake; do
  launchctl bootout "gui/$UID_N/$L" 2>/dev/null || true
  mv "$HOME/Library/LaunchAgents/$L.plist" "$HOME/.Trash/" 2>/dev/null || true
done
/usr/bin/python3 - <<'PY'
import glob, json, os
for p in glob.glob(os.path.expanduser("~/Library/Application Support/Claude/claude-code-sessions/*/*/scheduled-tasks.json")):
    d = json.load(open(p))
    d["scheduledTasks"] = [t for t in d.get("scheduledTasks", []) if t.get("id") != "rotor-autoresume"]
    json.dump(d, open(p, "w"), indent=2)
PY
echo "Rotor autopilot stopped. Restart Claude to drop the resume task from memory."
