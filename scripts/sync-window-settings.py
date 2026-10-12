#!/usr/bin/env -S python3 -I
"""Make a second Claude desktop window's SETTINGS identical to the main window's.

usage: sync-window-settings.py --from <main data dir> --to <window data dir> [--apply | --check] [--strict]
                               [--extra-window]

  (default)  dry run: prints, by key NAME only (never values), every SETTING that differs
             and what --apply would change. Writes nothing.
  --apply    performs those changes. Refuses while any process uses --to as its
             --user-data-dir. Never writes to --from. Every file or folder it replaces is
             first copied to <to>/.settings-sync-backup/<timestamp>/. Writes are atomic
             (temp file + rename, mode 0600).
  --check    like the dry run, but exits 1 when any copyable SETTING differs (0 when none).
  --strict   with --check, also exit 1 for SETTINGs this script can see but cannot write
             (Local Storage keys, a zoom level it cannot map to a partition key).
  --extra-window
             --to is an EXTRA window next to the main one. After the copy, background jobs are
             switched off in the target only: scheduled tasks (Code and Cowork), remote control,
             keep awake and auto-archive on PR close in claude_desktop_config.json; the remote
             device name becomes "<main name> (window)"; and in the target's own chat cards
             (claude-code-sessions/*/*/local_*.json) every per-PR auto-fix / CI-monitor flag and
             trigger is switched off. Card edits keep each card's modification time, so the chat
             sync (newest copy wins) never carries them back to the main window. --check treats
             these as the expected state. Refuses to treat the real main folder as an extra window.

Only SETTING items are ever copied. ACCOUNT, DEVICE, RUNTIME, CACHE and DATA items of the
target stay untouched (logins, cookies, device ids, updater state, window geometry, caches,
chat cards, ...). Python standard library only; run with -I.
"""
import argparse
import copy
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile

SETTING, ACCOUNT, DEVICE, RUNTIME, CACHE, DATA, UNCLASSIFIED = (
    "SETTING", "ACCOUNT", "DEVICE", "RUNTIME", "CACHE", "DATA", "UNCLASSIFIED")

BACKUP_DIR = ".settings-sync-backup"
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

# ---------------------------------------------------------------------------
# Classification tables
# ---------------------------------------------------------------------------

# claude_desktop_config.json "preferences": keys that are NOT copied (install- or window-bound).
PREF_NOT_SETTING = [
    (re.compile(r".*Latched$"), RUNTIME, "install-bound first-seen latch"),
    (re.compile(r"^installSourceLanding$"), RUNTIME, "install-bound"),
    (re.compile(r"^folderTccProbeResults$"), RUNTIME, "macOS permission probe cache"),
    (re.compile(r"^(coworkHipaaRestricted|orgWorkAcrossAppsDisabled|coworkProjectsToolProvenFor|coworkHasBound.*)$"),
     ACCOUNT, "org/account policy cache from the server"),
    (re.compile(r"^coworkLegacyRootGrantsPruned$"), RUNTIME, "one-time migration flag"),
]
# Nested paths inside a copied preference that are per-window pointers (kept as the target has them).
PREF_PRESERVE_PATHS = [
    ("epitaxyPrefs", "desktop-frame.paneStore.v1", "state", "lastPrimaryCodeSession"),
]
# Preference keys that start or run a background engine (flag only; they are still copied).
ENGINE_PREF_RE = re.compile(
    r"^(keepAwakeEnabled|ccKeepAwake.*|wakeScheduler.*|ccdScheduledTasksEnabled|"
    r"coworkScheduledTasksEnabled|ccRemoteControlDefaultEnabled|remoteControl.*|"
    r"ccAutoArchive.*|dockBounceEnabled|notificationLevels|notificationSound|"
    r"dispatchCodeTasksPermissionMode|remoteToolsDeviceName|menuBarEnabled)$")
ENGINE_NOTE = {
    "keepAwakeEnabled": "keep-awake (prevent-app-suspension)",
    "ccKeepAwakeWhileWorking": "keep-awake", "ccKeepAwakeOnBattery": "keep-awake",
    "ccdScheduledTasksEnabled": "Code scheduled tasks (read at launch)",
    "coworkScheduledTasksEnabled": "Cowork scheduled tasks (read at launch)",
    "ccRemoteControlDefaultEnabled": "remote control",
    "remoteToolsDeviceName": "remote-device name (registers per account)",
    "dispatchCodeTasksPermissionMode": "dispatch runs Code tasks",
    "ccAutoArchiveOnPrClose": "auto-archive on PR close",
    "ccAutoArchiveInactiveDays": "auto-archive inactive sessions",
    "dockBounceEnabled": "notifications", "notificationLevels": "notifications",
    "notificationSound": "notifications", "menuBarEnabled": "menu bar / quick entry",
}

# --extra-window: background jobs that run only in the main window, and the value that switches each off.
# ccAutoArchiveInactiveDays is the sweeper's idle limit in days (0 = never): the same sweeper that serves
# ccAutoArchiveOnPrClose archives every idle chat in the shared card stores, so it must run in one window only.
# ccKeepAwakeWhileWorking / ccKeepAwakeOnBattery are not here: they only hold the Mac awake while a session in
# that very window is working, which is wanted in every window (no job starts by itself).
EXTRA_WINDOW_PREFS_OFF = {"ccdScheduledTasksEnabled": False, "coworkScheduledTasksEnabled": False,
                          "ccRemoteControlDefaultEnabled": False, "keepAwakeEnabled": False,
                          "ccAutoArchiveOnPrClose": False, "ccAutoArchiveInactiveDays": 0}
DEVICE_NAME_KEY = "remoteToolsDeviceName"
DEVICE_NAME_SUFFIX = " (window)"
# Chat cards (claude-code-sessions/<acct>/<org>/local_*.json), field names read from the Claude app code:
#   prs[].autoFix        per-PR CI auto-fix / monitor flag (bool); the app wakes the session on CI events
#   autoFixEnabled       legacy session flag; on load it turns autoFix on for the branch's PRs
#   autoFixOwnPrs        session wish: arm auto-fix on every PR the session opens
#   autoFixNextOwnPr(+Click)  one-shot latches that arm auto-fix on the next PR the session opens
#   autoArchiveOnPrClose per-session override of the global auto-archive-on-PR-close job
# autoFixDelivered / autoFixNoticeSent are history, not triggers, and stay.
CARD_SESSION_FLAGS_OFF = ["autoFixEnabled", "autoFixOwnPrs", "autoArchiveOnPrClose"]
CARD_SESSION_LATCHES_DROP = ["autoFixNextOwnPr", "autoFixNextOwnPrClick"]
CARDS_ROOT = "claude-code-sessions"
CARD_NAME = re.compile(r"^local_.*\.json$")

# config.json: only these keys are copied.
CONFIG_SETTING_KEYS = ["userThemeMode", "windowControlsZoomFactor", "locale",
                       "bootFrameLayout", "bootSidebarPlaceholder"]
CONFIG_OTHER = [
    (re.compile(r"^(lastKnownAccountUuid|oauth:.*)$"), ACCOUNT),
    (re.compile(r"^(updater.*|first_launch_at|version_first_launch|hostGitConfinedInstall|"
                r"hasTrackedInitialActivation|lastSeenRequireCoworkFullVmSandbox|"
                r"windowSizeWasSignedIn|remote_marketplace_migration_done_v1|"
                r"planUsageLastTrayOpenAt)$"), RUNTIME),
    (re.compile(r"^(dxt:allowlist(Cache|Enabled|LastUpdated):.*|remote_uploads_migration_done_v1_.*)$"), CACHE),
]

# Chromium Preferences top-level keys.
CHROMIUM_PREFS_COPIED = ["spellcheck"]
CHROMIUM_PREFS_OTHER = {"electron": DEVICE, "migrated_user_scripts_toggle": RUNTIME,
                        "partition": SETTING}  # partition: per-host zoom handled specially

# Top-level entries of a data dir. (regex, class, how handled, note)
INVENTORY = [
    (r"claude_desktop_config\.json$", SETTING, "copied (top-level keys + preferences, minus latches/pointers)", ""),
    (r"config\.json$", SETTING, "copied: 5 UI keys only", "oauth:*, lastKnownAccountUuid, updater* stay per window"),
    (r"Preferences$", SETTING, "copied: spellcheck + per-host zoom (mapped to target's own partition key)", "electron.* is device identity"),
    (r"developer_settings\.json$", SETTING, "copied if present in source", "allowDevTools"),
    (r"mcp-user-tool-toggles\.json$", SETTING, "copied; target account's own entry kept", "owners keyed by account"),
    (r"extensions-installations\.json$", SETTING, "copied (per extension id; target-only ids kept)", ""),
    (r"Claude Extensions$", SETTING, "copied per installed extension id", "extension code + node_modules"),
    (r"Claude Extensions Settings$", SETTING, "copied per extension id", ""),
    (r"Local Storage$", SETTING, "COMPARED ONLY: LevelDB cannot be written safely here", "mixed settings, account keys, session state"),
    (r"Cookies(-journal)?$|Session Storage$|IndexedDB$|WebStorage$|Partitions$", ACCOUNT, "never copied", "logins / per-account web state"),
    (r"bridge-state\.json$|cowork-enabled-cli-ops\.json$|buddy-tokens\.json$", ACCOUNT, "never copied", "account:device keyed"),
    (r"chrome-import-sites\.json$", ACCOUNT, "never copied", "bookkeeping for cookies seeded into Partitions jars"),
    (r"ant-did$|ant-device-registry\.json$|ccd-ids\.json$|remote-control-state\.json$", DEVICE, "never copied", "device identity / salts"),
    (r"Local State$|window-state\.json$|vm-support-probe\.json$|simulator-builds$", RUNTIME, "never copied", ""),
    (r"Network Persistent State$|TransportSecurity$|SharedStorage$|Conversions(-journal)?$|InterestGroups$|"
     r"DIPS(-wal)?$|Trust Tokens(-journal)?$|VideoDecodeStats$|shared_proto_db$|blob_storage$|Shared Dictionary$|"
     r"declarative_performance_observer\.db(-journal)?$", RUNTIME, "never copied", "Chromium runtime state"),
    (r"Cache$|Code Cache$|GPUCache$|DawnGraphiteCache$|DawnWebGPUCache$|fcache$|ca-bundle\.pem$|"
     r"extensions-blocklist\.json$|claude-code$|sentry$|Crashpad$|.*\.bak$|.*\.tmp-.*|\.Q6L2.*", CACHE, "never copied", "regenerated / server-fetched"),
    (r"claude-code-sessions$|local-agent-mode-sessions$|spaces-present$|side-session-notes$|pending-uploads$|"
     r"scratch-workspaces$|plan-usage-history\.json$|git-worktrees\.json.*|git-shadow$|worktree-dep-seed$|"
     r"\.settings-sync-backup$|.*\.before-sync$|Local Storage\.bak-.*", DATA, "never copied", "chat cards, per-account state, worktree records"),
]
INVENTORY = [(re.compile(p), c, h, n) for p, c, h, n in INVENTORY]

# Local Storage (origin https://claude.ai) key classes. First match wins.
LS_RULES = [
    ("SETTING", re.compile(
        r"^(epitaxy-editor-prefs|default-model|spa:locale|claudeai\.lastChatLook\.v1|ccd-sessions-filter|"
        r"epitaxy\.sessionRailSections|dframe-store|dframe-store\.backup\.v1|dframe-unpinned-epitaxy-project-ids|"
        r"LSS-customStyles:.*|LSS-persisted\.(cc-landing-worktree-enabled|epitaxy-files-tree-width|"
        r"epitaxy-default-transcript-view-nudge|epitaxy-auto-default-notice-seen\..*|dframe-code-sections|"
        r"dframe-local-slice|dframe-group-scopes|starred-.*)|persisted\.(ccd-session-presets\..*|epitaxy-split-suggestion))$")),
    ("UI-STATE", re.compile(r"^(epitaxy\.sidePaneStore\.v1|desktop-frame\.paneStore\.v1|epitaxy\.terminalPromptLines\.v1|"
                            r"epitaxy\.terminalTabs\.v1|epitaxy\.dismissedPrMap|composer-draft:.*|epitaxy-session-result:.*|"
                            r"epitaxy-unread-v1|code-session-pills|branch-status-cache|session-.*|diff-annotations)$")),
]
LS_VOLATILE_JSON_KEYS = {"timestamp", "lastSidebarScopeKey", "sidebarRowCountsByScope", "lastPrimaryCodeSession"}


def classify_pref(key):
    for rx, cls, why in PREF_NOT_SETTING:
        if rx.match(key):
            return cls, why
    return SETTING, ""


def classify_config(key):
    if key in CONFIG_SETTING_KEYS:
        return SETTING
    for rx, cls in CONFIG_OTHER:
        if rx.match(key):
            return cls
    return UNCLASSIFIED


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def load_json(path):
    """Return (obj, text) or (None, None) when the file is missing. Raises on invalid JSON."""
    if not os.path.isfile(path):
        return None, None
    text = read_text(path)
    return json.loads(text), text


def detect_indent(text):
    if text is None:
        return 2
    m = re.match(r"\{\r?\n([ \t]+)\S", text)
    if not m:
        return None  # compact
    ind = m.group(1)
    return "\t" if ind.startswith("\t") else len(ind)


def dump_json(obj, indent, trailing_newline=False):
    if indent is None:
        s = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    else:
        s = json.dumps(obj, indent=indent, ensure_ascii=False)
    return (s + ("\n" if trailing_newline else "")).encode("utf-8")


def leaf_diffs(desired, current, path=()):
    """Yield (path, ADD|REMOVE|CHANGE) turning `current` into `desired`."""
    if isinstance(desired, dict) and isinstance(current, dict):
        for k in sorted(set(desired) | set(current), key=str):
            if k not in current:
                yield path + (k,), "ADD"
            elif k not in desired:
                yield path + (k,), "REMOVE"
            else:
                yield from leaf_diffs(desired[k], current[k], path + (k,))
    elif desired != current:
        yield path, "CHANGE"


def get_path(obj, path):
    for p in path:
        if not isinstance(obj, dict) or p not in obj:
            return False, None
        obj = obj[p]
    return True, obj


def set_path(obj, path, present, value):
    """Make obj[path] equal (present, value). Missing parents are created only when setting."""
    parents = obj
    for p in path[:-1]:
        if not isinstance(parents, dict) or p not in parents:
            if not present:
                return
            parents.setdefault(p, {})
        parents = parents[p]
        if not isinstance(parents, dict):
            return
    if present:
        parents[path[-1]] = copy.deepcopy(value)
    else:
        parents.pop(path[-1], None)


def keep_own_account(desired, current, own):
    """Where a dict is keyed by account, the target's own account entry is the target's."""
    if not own or not isinstance(desired, dict) or not isinstance(current, dict):
        return
    for k in list(set(desired) | set(current)):
        if isinstance(k, str) and k.startswith(own) and k in current:
            desired[k] = copy.deepcopy(current[k])
        elif k in desired and k in current:
            keep_own_account(desired[k], current[k], own)


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_signature(root):
    """{relative path: sha256 | 'dir' | 'link:<target>'} for a folder."""
    sig = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        for d in dirnames:
            p = os.path.join(dirpath, d)
            rel = os.path.normpath(os.path.join(rel_dir, d))
            sig[rel] = ("link:" + os.readlink(p)) if os.path.islink(p) else "dir"
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            rel = os.path.normpath(os.path.join(rel_dir, fn))
            sig[rel] = ("link:" + os.readlink(p)) if os.path.islink(p) else sha_file(p)
    return sig


def own_account_of(to_dir):
    try:
        cfg, _ = load_json(os.path.join(to_dir, "config.json"))
    except (OSError, ValueError):
        return None
    if isinstance(cfg, dict):
        v = cfg.get("lastKnownAccountUuid")
        if isinstance(v, str) and re.fullmatch(UUID, v):
            return v
    return None


# ---------------------------------------------------------------------------
# Process guard
# ---------------------------------------------------------------------------

def list_processes():
    """Return the argument string of every process (fail closed on error)."""
    out = subprocess.run(["ps", "-axo", "args="], capture_output=True, text=True, check=True)
    return out.stdout.splitlines()


def default_claude_dir():
    return os.path.expanduser("~/Library/Application Support/Claude")


def processes_using(to_dir):
    """Command lines of processes whose --user-data-dir is `to_dir`
    (the main process looks like '.../MacOS/Claude --user-data-dir=<to>')."""
    variants = {to_dir.rstrip("/"), os.path.realpath(to_dir).rstrip("/")}
    pats = [re.compile(r"--user-data-dir=" + re.escape(v) + r"(?=\s|$)") for v in variants]
    hits = []
    uses_default = os.path.realpath(to_dir) == os.path.realpath(default_claude_dir())
    for line in list_processes():
        if any(p.search(line) for p in pats):
            hits.append(line)
        elif uses_default and "Claude.app/Contents/MacOS/Claude" in line and "--user-data-dir=" not in line:
            hits.append(line)
    return hits


# ---------------------------------------------------------------------------
# Local Storage (LevelDB) reader: read-only, pure Python
# ---------------------------------------------------------------------------

def _varint(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        if c < 0x80:
            return r, i
        s += 7


def _snappy(b):
    n, i = _varint(b, 0)
    out = bytearray()
    while i < len(b):
        t = b[i]
        i += 1
        k = t & 3
        if k == 0:
            ln = t >> 2
            if ln >= 60:
                nb = ln - 59
                ln = int.from_bytes(b[i:i + nb], "little")
                i += nb
            ln += 1
            out += b[i:i + ln]
            i += ln
        else:
            if k == 1:
                ln = 4 + ((t >> 2) & 7)
                off = ((t >> 5) << 8) | b[i]
                i += 1
            elif k == 2:
                ln = (t >> 2) + 1
                off = int.from_bytes(b[i:i + 2], "little")
                i += 2
            else:
                ln = (t >> 2) + 1
                off = int.from_bytes(b[i:i + 4], "little")
                i += 4
            for _ in range(ln):
                out.append(out[-off])
    if len(out) != n:
        raise ValueError("bad snappy block")
    return bytes(out)


def _block(data, off, size):
    raw = data[off:off + size]
    return _snappy(raw) if data[off + size] == 1 else raw


def _block_entries(blk):
    nr = struct.unpack("<I", blk[-4:])[0]
    end = len(blk) - 4 - 4 * nr
    i = 0
    key = b""
    while i < end:
        sh, i = _varint(blk, i)
        ns, i = _varint(blk, i)
        vl, i = _varint(blk, i)
        key = key[:sh] + blk[i:i + ns]
        i += ns
        yield key, blk[i:i + vl]
        i += vl


def _read_table(path):
    with open(path, "rb") as f:
        d = f.read()
    foot = d[-48:]
    _, p = _varint(foot, 0)
    _, p = _varint(foot, p)
    io, p = _varint(foot, p)
    isz, p = _varint(foot, p)
    for _, h in _block_entries(_block(d, io, isz)):
        o, q = _varint(h, 0)
        s, q = _varint(h, q)
        for k, v in _block_entries(_block(d, o, s)):
            tag = struct.unpack("<Q", k[-8:])[0]
            yield k[:-8], tag >> 8, (v if (tag & 0xFF) == 1 else None)


def _read_log(path):
    with open(path, "rb") as f:
        d = f.read()
    i = 0
    cur = b""
    while i + 7 <= len(d):
        room = 32768 - (i % 32768)
        if room < 7:
            i += room
            continue
        ln = int.from_bytes(d[i + 4:i + 6], "little")
        t = d[i + 6]
        i += 7
        if t == 0 and ln == 0:
            continue
        chunk = d[i:i + ln]
        i += ln
        if t == 1:
            rec = chunk
        elif t == 2:
            cur = chunk
            continue
        elif t == 3:
            cur += chunk
            continue
        elif t == 4:
            rec = cur + chunk
        else:
            break
        if len(rec) < 12:
            continue
        seq = struct.unpack("<Q", rec[:8])[0]
        cnt = struct.unpack("<I", rec[8:12])[0]
        j = 12
        try:
            for n in range(cnt):
                ty = rec[j]
                j += 1
                kl, j = _varint(rec, j)
                k = rec[j:j + kl]
                j += kl
                if ty == 1:
                    vl, j = _varint(rec, j)
                    yield k, seq + n, rec[j:j + vl]
                    j += vl
                else:
                    yield k, seq + n, None
        except IndexError:
            break  # torn tail of a live log


def read_local_storage(ls_dir, origin="https://claude.ai"):
    """{key name: raw value bytes} for one origin of a Chromium Local Storage LevelDB. Read-only."""
    db = os.path.join(ls_dir, "leveldb")
    best = {}
    for fn in sorted(os.listdir(db)):
        p = os.path.join(db, fn)
        try:
            if fn.endswith((".ldb", ".sst")):
                it = _read_table(p)
            elif fn.endswith(".log"):
                it = _read_log(p)
            else:
                continue
            for k, s, v in it:
                if k not in best or s > best[k][0]:
                    best[k] = (s, v)
        except (OSError, IndexError, ValueError, struct.error):
            continue  # a file compacted away under us, or a torn tail: skip it
    prefix = ("_" + origin).encode() + b"\x00"
    out = {}
    for k, (_, v) in best.items():
        if k.startswith(prefix) and v is not None and len(k) > len(prefix):
            out[k[len(prefix) + 1:].decode("latin1")] = v
    return out


def _ls_text(v):
    if not v:
        return ""
    return v[1:].decode("utf-16le", "replace") if v[0] == 0 else v[1:].decode("latin1", "replace")


def _strip_volatile(o):
    if isinstance(o, dict):
        return {k: _strip_volatile(v) for k, v in o.items() if k not in LS_VOLATILE_JSON_KEYS}
    if isinstance(o, list):
        return [_strip_volatile(v) for v in o]
    return o


def ls_equal(a, b):
    if a == b:
        return True
    try:
        return _strip_volatile(json.loads(_ls_text(a))) == _strip_volatile(json.loads(_ls_text(b)))
    except ValueError:
        return False


def classify_ls(key):
    for cls, rx in LS_RULES:
        if rx.match(key):
            return cls
    return "OTHER"


# ---------------------------------------------------------------------------
# Plans
# ---------------------------------------------------------------------------

class Plan:
    """One change to the target: a file write, or a folder replace."""

    def __init__(self, rel, kind, diffs, payload, keep_stat=None):
        self.rel = rel          # path relative to the target data dir
        self.kind = kind        # "file" | "dir"
        self.diffs = diffs      # [(display name, ADD|REMOVE|CHANGE)]
        self.payload = payload  # bytes for file, source folder for dir
        # a file edited in place keeps its modification time and mode; it is only written if it
        # still has this (size, mtime_ns, mode) when applying, so a newer save is never overwritten
        self.keep_stat = keep_stat


class Report:
    def __init__(self):
        self.plans = []
        self.rows = []       # (store, name, status) for every SETTING compared
        self.cannot = []     # (store, name, why): SETTINGs seen but not writable
        self.notes = []
        self.errors = []
        self.engines = []    # (key, note, state)
        self.ui_state = []   # Local Storage UI/session-state keys that differ (not settings)
        self.extra_window = False

    def compared(self, store, name, same):
        self.rows.append((store, name, same))


def _bool_state(v):
    if isinstance(v, int) and not isinstance(v, bool):  # a day count: 0 = never
        return "on" if v else "off"
    return "on" if v is True else "off" if v is False else "set"


def default_device_name():
    """This Mac's name, for a window whose main window has no remote device name set."""
    try:
        out = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True, timeout=5)
        name = out.stdout.strip()
        if out.returncode == 0 and name:
            return name
    except (OSError, subprocess.SubprocessError):
        pass
    return platform.node().split(".")[0] or "Mac"


def apply_extra_window_prefs(sp, dprefs, rep):
    """Switch the background jobs off in the target's preferences (in place)."""
    for k, off in EXTRA_WINDOW_PREFS_OFF.items():
        dprefs[k] = off
    main_name = sp.get(DEVICE_NAME_KEY)
    if not isinstance(main_name, str) or not main_name.strip():
        main_name = default_device_name()
        rep.notes.append(f"preferences.{DEVICE_NAME_KEY}: main window has none, used this Mac's name as the base")
    dprefs[DEVICE_NAME_KEY] = main_name + DEVICE_NAME_SUFFIX


def plan_claude_desktop_config(src, dst, rep, own, extra=False):
    rel = "claude_desktop_config.json"
    s, _ = load_json(os.path.join(src, rel))
    d, dtext = load_json(os.path.join(dst, rel))
    if s is None:
        rep.notes.append(f"{rel}: missing in source, skipped")
        return
    cur = d if isinstance(d, dict) else {}
    desired = copy.deepcopy(s)
    sp = s.get("preferences", {}) if isinstance(s.get("preferences"), dict) else {}
    dp = cur.get("preferences", {}) if isinstance(cur.get("preferences"), dict) else {}
    dprefs = copy.deepcopy(sp)
    for k in set(sp) | set(dp):
        cls, why = classify_pref(k)
        if cls != SETTING:
            if k in dp:
                dprefs[k] = dp[k]
            else:
                dprefs.pop(k, None)
            rep.notes.append(f"{rel} preferences.{k}: {cls} ({why}), kept as the target has it")
    for path in PREF_PRESERVE_PATHS:
        present, val = get_path(dp, path)
        set_path(dprefs, path, present, val)
    keep_own_account(dprefs, dp, own)
    if extra:
        apply_extra_window_prefs(sp, dprefs, rep)
    desired["preferences"] = dprefs
    diffs = []
    for path, kind in leaf_diffs(desired, cur):
        diffs.append((".".join(str(p) for p in path), kind))
    extra_keys = set(EXTRA_WINDOW_PREFS_OFF) | {DEVICE_NAME_KEY} if extra else set()
    for k in sorted(set(sp) | set(dp) | extra_keys):
        if classify_pref(k)[0] == SETTING:
            rep.compared(rel, "preferences." + k, desired["preferences"].get(k) == dp.get(k) and (k in dp) == (k in desired["preferences"]))
    for k in sorted(set(s) - {"preferences"}):
        rep.compared(rel, k, s.get(k) == cur.get(k) and k in cur)
    shown = dprefs if extra else sp
    for k in sorted(shown):
        if ENGINE_PREF_RE.match(k):
            rep.engines.append((k, ENGINE_NOTE.get(k, "background engine"), _bool_state(shown[k])))
    if diffs:
        indent = detect_indent(dtext) if dtext is not None else 2
        rep.plans.append(Plan(rel, "file", diffs, dump_json(desired, indent, trailing_newline=bool(dtext and dtext.endswith("\n")))))


def switch_card_off(card):
    """Return (new card, [(field, CHANGE|REMOVE)]) with every auto-fix trigger off. Never adds a key."""
    new = copy.deepcopy(card)
    diffs = []
    prs = new.get("prs")
    if isinstance(prs, list):
        for i, pr in enumerate(prs):
            if isinstance(pr, dict) and pr.get("autoFix"):
                pr["autoFix"] = False
                diffs.append((f"prs[{i}].autoFix", "CHANGE"))
    for k in CARD_SESSION_FLAGS_OFF:
        if new.get(k):
            new[k] = False
            diffs.append((k, "CHANGE"))
    for k in CARD_SESSION_LATCHES_DROP:
        if new.get(k):
            del new[k]
            diffs.append((k, "REMOVE"))
    return new, diffs


def plan_cards_off(src, dst, rep):
    """--extra-window: switch auto-fix off in the TARGET's own cards. The cards are read where they
    are (the target's copies), never from --from, and never through a link into --from."""
    top = os.path.join(dst, CARDS_ROOT)
    if not os.path.isdir(top):
        return
    if os.path.islink(top) or _under(src, top):
        rep.notes.append(f"{CARDS_ROOT}: is a link or lives inside the source folder, cards not touched")
        return
    for dirpath, dirnames, filenames in os.walk(top, followlinks=False):
        dirnames.sort()
        for fn in sorted(filenames):
            if not CARD_NAME.match(fn):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, dst)
            if os.path.islink(path) or _under(src, path):
                rep.notes.append(f"{rel}: is a link, left alone")
                continue
            try:
                text = read_text(path)
                st = os.stat(path)
                card = json.loads(text)
            except (OSError, ValueError):
                rep.notes.append(f"{rel}: unreadable or not JSON, auto-fix could not be checked")
                continue
            if not isinstance(card, dict):
                continue
            new, diffs = switch_card_off(card)
            if diffs:
                rep.plans.append(Plan(rel, "file", diffs,
                                      dump_json(new, detect_indent(text), trailing_newline=text.endswith("\n")),
                                      keep_stat=(st.st_size, st.st_mtime_ns, st.st_mode & 0o777)))


def plan_config_json(src, dst, rep):
    rel = "config.json"
    s, _ = load_json(os.path.join(src, rel))
    d, dtext = load_json(os.path.join(dst, rel))
    if s is None or d is None:
        rep.notes.append(f"{rel}: missing in {'source' if s is None else 'target'}, skipped")
        return
    desired = copy.deepcopy(d)
    diffs = []
    for k in CONFIG_SETTING_KEYS:
        if k in s:
            same = k in d and d[k] == s[k]
            rep.compared(rel, k, same)
            if not same:
                diffs.append((k, "CHANGE" if k in d else "ADD"))
                desired[k] = copy.deepcopy(s[k])
        elif k in d:
            rep.compared(rel, k, False)
            diffs.append((k, "REMOVE"))
            desired.pop(k)
    for k in sorted(set(s) | set(d)):
        if classify_config(k) == UNCLASSIFIED:
            rep.notes.append(f"{rel} key {k}: UNCLASSIFIED, not copied (decide whether it is a setting)")
    if diffs:
        rep.plans.append(Plan(rel, "file", diffs, dump_json(desired, detect_indent(dtext), trailing_newline=dtext.endswith("\n"))))


def plan_chromium_prefs(src, dst, rep, zoom_key):
    rel = "Preferences"
    s, _ = load_json(os.path.join(src, rel))
    d, dtext = load_json(os.path.join(dst, rel))
    if s is None or d is None:
        rep.notes.append(f"{rel}: missing in {'source' if s is None else 'target'}, skipped")
        return
    desired = copy.deepcopy(d)
    diffs = []
    for k in CHROMIUM_PREFS_COPIED:
        same = (k in s) == (k in d) and s.get(k) == d.get(k)
        rep.compared(rel, k, same)
        if not same:
            diffs.append((k, "REMOVE" if k not in s else "ADD" if k not in d else "CHANGE"))
            if k in s:
                desired[k] = copy.deepcopy(s[k])
            else:
                desired.pop(k, None)
    # per-host zoom: each window files its levels under its OWN partition-hash key
    zp = ("partition", "per_host_zoom_levels")
    _, szoom = get_path(s, zp)
    _, dzoom = get_path(d, zp)
    szoom = szoom if isinstance(szoom, dict) else {}
    dzoom = dzoom if isinstance(dzoom, dict) else {}
    if szoom:
        levels = {}
        for key in sorted(szoom):
            if isinstance(szoom[key], dict):
                levels.update(szoom[key])
        own = [zoom_key] if zoom_key else sorted(k for k in dzoom if k not in szoom)
        if not own:
            rep.cannot.append((rel, "partition.per_host_zoom_levels",
                               "target has no partition key of its own yet (open the window, zoom once, rerun) or pass --zoom-key"))
        for key in own:
            cur = dzoom.get(key) if isinstance(dzoom.get(key), dict) else {}
            for host in sorted(levels):
                same = host in cur and cur[host] == levels[host]
                rep.compared(rel, f"zoom.{host}", same)
                if not same:
                    diffs.append((f"partition.per_host_zoom_levels.<target key>.{host}", "ADD" if host not in cur else "CHANGE"))
                    desired.setdefault("partition", {}).setdefault("per_host_zoom_levels", {}).setdefault(key, {})[host] = levels[host]
        stale = sorted(k for k in dzoom if k in szoom)
        if stale:
            rep.notes.append(f"{rel}: target holds zoom under {len(stale)} key(s) that belong to the source window (stale hand copy, harmless, left alone)")
    for k in sorted(set(s) | set(d)):
        if k not in CHROMIUM_PREFS_COPIED and k not in CHROMIUM_PREFS_OTHER:
            rep.notes.append(f"{rel} key {k}: UNCLASSIFIED, not copied")
    if diffs:
        rep.plans.append(Plan(rel, "file", diffs, dump_json(desired, detect_indent(dtext), trailing_newline=dtext.endswith("\n"))))


def plan_whole_json(rel, src, dst, rep, own, label):
    s, _ = load_json(os.path.join(src, rel))
    d, dtext = load_json(os.path.join(dst, rel))
    if s is None:
        if d is not None:
            rep.notes.append(f"{rel}: only the target has it, left alone")
        return
    cur = d if isinstance(d, dict) else {}
    desired = copy.deepcopy(s)
    keep_own_account(desired, cur, own)
    diffs = [(".".join(str(p) for p in path), kind) for path, kind in leaf_diffs(desired, cur)]
    rep.compared(rel, label, not diffs)
    if diffs:
        rep.plans.append(Plan(rel, "file", diffs, dump_json(desired, detect_indent(dtext) if dtext else 2,
                                                              trailing_newline=bool(dtext and dtext.endswith("\n")))))


def plan_extensions(src, dst, rep):
    inst_rel = "extensions-installations.json"
    s, _ = load_json(os.path.join(src, inst_rel))
    d, dtext = load_json(os.path.join(dst, inst_rel))
    ids = set()
    if isinstance(s, dict):
        ids |= set((s.get("extensions") or {}).keys())
    src_ext = os.path.join(src, "Claude Extensions")
    if os.path.isdir(src_ext):
        ids |= {n for n in os.listdir(src_ext) if os.path.isdir(os.path.join(src_ext, n))}
    if isinstance(s, dict):
        cur = d if isinstance(d, dict) else {}
        desired = copy.deepcopy(cur)
        for k, v in s.items():
            if k != "extensions":
                desired[k] = copy.deepcopy(v)
        desired.setdefault("extensions", {})
        for eid, rec in (s.get("extensions") or {}).items():
            desired["extensions"][eid] = copy.deepcopy(rec)
        diffs = [(".".join(str(p) for p in path), kind) for path, kind in leaf_diffs(desired, cur)]
        for eid in sorted(ids):
            have = (cur.get("extensions") or {})
            rep.compared(inst_rel, f"extensions.{eid}", eid in have and have[eid] == desired["extensions"].get(eid))
        extra = sorted(set((cur.get("extensions") or {})) - set((s.get("extensions") or {})))
        if extra:
            rep.notes.append(f"{inst_rel}: target-only extension(s) {', '.join(extra)} kept (uninstall is not synced)")
        if diffs:
            rep.plans.append(Plan(inst_rel, "file", diffs, dump_json(desired, detect_indent(dtext) if dtext else 2,
                                                                       trailing_newline=bool(dtext and dtext.endswith("\n")))))
    for eid in sorted(ids):
        sd = os.path.join(src, "Claude Extensions", eid)
        dd = os.path.join(dst, "Claude Extensions", eid)
        if os.path.isdir(sd):
            ssig = tree_signature(sd)
            dsig = tree_signature(dd) if os.path.isdir(dd) else None
            same = ssig == dsig
            rep.compared("Claude Extensions", eid, same)
            if not same:
                rep.plans.append(Plan(os.path.join("Claude Extensions", eid), "dir",
                                      [(f"Claude Extensions/{eid}", "ADD" if dsig is None else "CHANGE")], sd))
        sf = os.path.join(src, "Claude Extensions Settings", eid + ".json")
        df = os.path.join(dst, "Claude Extensions Settings", eid + ".json")
        if os.path.isfile(sf):
            with open(sf, "rb") as f:
                sb = f.read()
            db = None
            if os.path.isfile(df):
                with open(df, "rb") as f:
                    db = f.read()
            rep.compared("Claude Extensions Settings", eid, sb == db)
            if sb != db:
                rep.plans.append(Plan(os.path.join("Claude Extensions Settings", eid + ".json"), "file",
                                      [(f"Claude Extensions Settings/{eid}.json", "ADD" if db is None else "CHANGE")], sb))


def compare_local_storage(src, dst, rep):
    store = "Local Storage"
    sdir, ddir = os.path.join(src, "Local Storage"), os.path.join(dst, "Local Storage")
    if not (os.path.isdir(os.path.join(sdir, "leveldb")) and os.path.isdir(os.path.join(ddir, "leveldb"))):
        rep.notes.append("Local Storage: missing in source or target, not compared")
        return
    try:
        s, d = read_local_storage(sdir), read_local_storage(ddir)
    except Exception as e:  # noqa: BLE001 - any read problem must not break the run
        rep.notes.append(f"Local Storage: could not read ({type(e).__name__}), not compared")
        return
    for k in sorted(set(s) | set(d)):
        cls = classify_ls(k)
        if cls == "SETTING":
            same = k in s and k in d and ls_equal(s[k], d[k])
            if k in s or k in d:
                rep.compared(store, k, same)
            if not same:
                kind = "only in target" if k not in s else "only in source" if k not in d else "differs"
                rep.cannot.append((store, k, f"{kind}; LevelDB write unsupported"))
        elif cls == "UI-STATE" and not (k in s and k in d and ls_equal(s[k], d[k])):
            rep.ui_state.append(k)


def scan_inventory(src, dst, rep):
    for root, label in ((src, "source"), (dst, "target")):
        try:
            names = sorted(os.listdir(root))
        except OSError:
            continue
        for n in names:
            if not any(rx.match(n) for rx, *_ in INVENTORY):
                rep.notes.append(f"{label} top-level entry {n!r}: UNCLASSIFIED, not copied (new in this app version?)")


def build_report(src, dst, zoom_key=None, extra=False):
    rep = Report()
    rep.extra_window = extra
    own = own_account_of(dst)
    steps = [
        lambda: plan_claude_desktop_config(src, dst, rep, own, extra),
        lambda: plan_config_json(src, dst, rep),
        lambda: plan_chromium_prefs(src, dst, rep, zoom_key),
        lambda: plan_whole_json("developer_settings.json", src, dst, rep, own, "developer_settings"),
        lambda: plan_whole_json("mcp-user-tool-toggles.json", src, dst, rep, own, "mcp-user-tool-toggles"),
        lambda: plan_extensions(src, dst, rep),
        lambda: compare_local_storage(src, dst, rep),
        lambda: scan_inventory(src, dst, rep),
    ]
    if extra:
        steps.append(lambda: plan_cards_off(src, dst, rep))
    for step in steps:
        try:
            step()
        except (OSError, ValueError) as e:
            rep.errors.append(f"{type(e).__name__}: {e}")
    return rep


# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

def _under(root, path):
    r = os.path.realpath(root)
    p = os.path.realpath(path)
    return p == r or p.startswith(r + os.sep)


def atomic_write(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".sync-tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def make_backup_root(dst):
    base = os.path.join(dst, BACKUP_DIR)
    os.makedirs(base, mode=0o700, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    root = os.path.join(base, stamp)
    n = 1
    while os.path.exists(root):
        n += 1
        root = os.path.join(base, f"{stamp}-{n}")
    os.makedirs(root, mode=0o700)
    return root


def apply_plans(dst, plans):
    backup = make_backup_root(dst)
    manifest = {"replaced": [], "created": [], "skipped": []}
    for pl in plans:
        target = os.path.join(dst, pl.rel)
        if not _under(dst, target):
            raise RuntimeError(f"refusing to write outside the target: {pl.rel}")
        if pl.keep_stat is not None:
            try:
                st = os.stat(target)
                now = (st.st_size, st.st_mtime_ns, st.st_mode & 0o777)
            except OSError:
                now = None
            if now != pl.keep_stat:
                manifest["skipped"].append(pl.rel)   # saved by someone since we read it: rerun
                continue
        existed = os.path.lexists(target)
        if existed:
            bk = os.path.join(backup, pl.rel)
            os.makedirs(os.path.dirname(bk), mode=0o700, exist_ok=True)
            if os.path.isdir(target) and not os.path.islink(target):
                shutil.copytree(target, bk, symlinks=True)
            else:
                shutil.copy2(target, bk)
            manifest["replaced"].append(pl.rel)
        else:
            manifest["created"].append(pl.rel)
        if pl.kind == "file":
            atomic_write(target, pl.payload)
            if pl.keep_stat is not None:
                os.chmod(target, pl.keep_stat[2])
                os.utime(target, ns=(pl.keep_stat[1], pl.keep_stat[1]))
        else:
            os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
            tmp = target + ".sync-new"
            old = target + ".sync-old"
            for leftover in (tmp, old):
                if os.path.exists(leftover):
                    shutil.rmtree(leftover)
            shutil.copytree(pl.payload, tmp, symlinks=True)
            if existed:
                os.rename(target, old)
            os.rename(tmp, target)
            if existed:
                shutil.rmtree(old)
    atomic_write(os.path.join(backup, "manifest.json"), json.dumps(manifest, indent=2).encode())
    return backup, manifest


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def print_report(rep, out, apply_mode, verbose=False):
    verb = "changed" if apply_mode else "would change"
    out(f"SETTINGS that differ ({verb}):")
    if not rep.plans:
        out("  none")
    card_prefix = CARDS_ROOT + os.sep
    cards = [pl for pl in rep.plans if pl.rel.startswith(card_prefix)]
    for pl in rep.plans:
        if pl in cards and not verbose:
            continue
        out(f"  {pl.rel}  [{'folder' if pl.kind == 'dir' else 'file'}]")
        shown = pl.diffs[:60]
        for name, kind in shown:
            out(f"    {kind:<6} {name}")
        if len(pl.diffs) > len(shown):
            out(f"    ... +{len(pl.diffs) - len(shown)} more")
    if cards and not verbose:
        fields = {}
        for pl in cards:
            for name, kind in pl.diffs:
                key = re.sub(r"\[\d+\]", "[]", name)
                fields[(key, kind)] = fields.get((key, kind), 0) + 1
        out(f"  {CARDS_ROOT}/*/*/local_*.json  [{len(cards)} chat card(s), modification times kept]")
        for (name, kind), n in sorted(fields.items()):
            out(f"    {kind:<6} {name}  x{n}")
    out("")
    out("SETTINGS seen but NOT copyable by this script:")
    if not rep.cannot:
        out("  none")
    for store, name, why in rep.cannot:
        out(f"  {store}: {name}  ({why})")
    out("")
    out("Background jobs switched OFF in this window (they run only in the main window):" if getattr(rep, "extra_window", False)
        else "Background engines (copied, so BOTH windows run them):")
    if not rep.engines:
        out("  none found")
    for key, note, state in sorted(set(rep.engines)):
        out(f"  {key} = {state}  [{note}]")
    out("")
    if rep.ui_state:
        out(f"Local Storage: {len(rep.ui_state)} UI/session-state key(s) differ (pane layout, drafts, dismissed PRs, "
            f"session results). Not settings, not copied." + ("" if verbose else " Use -v to list the names."))
        if verbose:
            for k in rep.ui_state:
                out(f"  {k}")
        out("")
    if rep.notes:
        out("Notes:")
        for n in rep.notes:
            out(f"  {n}")
        out("")
    for e in rep.errors:
        out(f"ERROR: {e}")


def summary_line(rep):
    total = len(rep.rows)
    same = sum(1 for _, _, s in rep.rows if s)
    n_changes = sum(len(p.diffs) for p in rep.plans)
    stores = {}
    for st, _, ok in rep.rows:
        a = stores.setdefault(st, [0, 0])
        a[0] += 1
        a[1] += 1 if ok else 0
    per = "; ".join(f"{st} {a[1]}/{a[0]}" for st, a in sorted(stores.items()))
    return (f"per store (identical/compared): {per}\n"
            f"summary: {total} SETTINGs compared, {same} identical, {total - same} differ; "
            f"{len(rep.plans)} item(s) to write ({n_changes} key-level changes); "
            f"{len(rep.cannot)} not copyable; {len(rep.errors)} error(s)")


def main(argv=None, out=print):
    ap = argparse.ArgumentParser(prog="sync-window-settings.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("--from", dest="src", required=True, help="main window data dir (read only)")
    ap.add_argument("--to", dest="dst", required=True, help="second window data dir")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="write the changes (default is a dry run)")
    mode.add_argument("--check", action="store_true", help="exit 1 if any copyable SETTING differs")
    ap.add_argument("--strict", action="store_true", help="with --check: also fail on SETTINGs the script cannot copy")
    ap.add_argument("-v", "--verbose", action="store_true", help="also list UI-state key names")
    ap.add_argument("--extra-window", action="store_true",
                    help="--to is an extra window: switch background jobs off in it (see top of file)")
    ap.add_argument("--zoom-key", help="target partition-hash key for per-host zoom (default: the key only the target has)")
    args = ap.parse_args(argv)

    src, dst = os.path.abspath(args.src), os.path.abspath(args.dst)
    if not os.path.isdir(src) or not os.path.isdir(dst):
        out("error: --from and --to must both be existing folders")
        return 2
    if os.path.realpath(src) == os.path.realpath(dst):
        out("error: --from and --to are the same folder")
        return 2

    if args.extra_window and os.path.realpath(dst) == os.path.realpath(default_claude_dir()):
        out("error: --extra-window would switch background jobs off in the MAIN window's own folder; refused")
        return 2

    if args.apply:
        try:
            using = processes_using(dst)
        except (OSError, subprocess.SubprocessError) as e:
            out(f"refusing to apply: could not list processes ({type(e).__name__})")
            return 3
        if using:
            out(f"refusing to apply: {len(using)} Claude process(es) are using {dst}. Quit that window first.")
            return 3

    rep = build_report(src, dst, args.zoom_key, args.extra_window)
    mode_name = "APPLY" if args.apply else "CHECK" if args.check else "DRY RUN"
    out(f"{mode_name}: {src}  ->  {dst}")
    out("")
    print_report(rep, out, args.apply, args.verbose)

    if rep.errors:
        out(summary_line(rep))
        return 2

    if args.apply and rep.plans:
        try:
            backup, manifest = apply_plans(dst, rep.plans)
        except (OSError, RuntimeError, shutil.Error) as e:
            out(f"ERROR while applying: {type(e).__name__}: {e}")
            return 2
        out(f"backup: {backup}  ({len(manifest['replaced'])} replaced, {len(manifest['created'])} created)")
        if manifest["skipped"]:
            out(f"{len(manifest['skipped'])} chat card(s) changed while syncing and were NOT written; run again: "
                + ", ".join(manifest["skipped"][:5]) + (" ..." if len(manifest["skipped"]) > 5 else ""))
            out(summary_line(rep))
            return 4
    out(summary_line(rep))
    if args.check:
        bad = bool(rep.plans) or (args.strict and bool(rep.cannot))
        out("CHECK: " + ("settings differ" if bad else "settings identical"))
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
