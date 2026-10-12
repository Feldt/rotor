#!/usr/bin/env python3
"""CCD cross-account session mirror.
Unions all local_*.json sidebar cards across ALL account/org store partitions
under the sessions root, so the sidebar shows every chat under any login.
Stores are DISCOVERED at runtime (any <account-uuid>/<org-uuid>/ dir) — new
accounts (e.g. dev@example.com, 2026-08-10) join the pool automatically.
newest-mtime-wins, never-delete, atomic writes (temp+rename), self-locking,
idempotent: a converged tree costs one stat per card and reads nothing.

A pass works in this order (2026-10-06, after an hour-long pass hid new chats):
  1. adds     cards missing from a store, newest first, found from a names-only
              listing, so a new chat is everywhere within a second of the pass
              starting however many updates are queued behind it
  2. updates  copies whose size or mtime disagrees with the newest copy; only
              those are read, and a byte compare decides between rewriting the
              copy and just converging its mtime. Step 1 reruns every few
              seconds while this is going on.

Copies are written as APFS clones: each store holds every card as its own
regular file, but the 49 copies of a card share one set of blocks, so the
stores cost one copy's worth of disk rather than 49 (10 GB before 2026-10-06).
`du` counts every clone in full; `df` tells the truth.

The launchd agent has to list every store dir in WatchPaths to notice a save
there at once; a store it does not list waits for the 300 s poll. Every pass
reports that gap as unwatched=N, and --reload closes it.

  mirror.py             one pass (what launchd runs)
  mirror.py --dry-run   preview: writes nothing, takes no lock (-v lists actions)
  mirror.py --backup    snapshot the newest copy of every card + this script + the plist
  mirror.py --dedupe    swap byte-identical copies for clones of the newest one
  mirror.py --write-plist  rewrite the agent's WatchPaths for today's stores (reload separately)
  mirror.py --reload    the same, then bootout + bootstrap the agent
  mirror.py --no-clone  write byte copies instead of clones

Extra Claude windows (Rotor "parallel windows", 2026-10-09)
---------------------------------------------------------------------
Each extra window runs Claude with its own --user-data-dir and so has its own
<dataDir>/claude-code-sessions tree. The Rotor engine lists them in
~/Library/Application Support/ClaudeAccounts/windows.json
({"version":1,"windows":[{"accountId","dataDir","signedIn","openedAt","pid"}]};
a missing or unreadable file means no extra windows). Every <dataDir>/claude-code-sessions
store joins the union with the same newest-wins, never-delete rules, with two differences:

  * CI auto-fix is a per-PR flag in the card (prs[].autoFix, and the legacy session-level
    autoFixEnabled that the app turns into one). Background jobs run in the main window
    only, so a card written INTO a window root has both set to false (never deleted: the
    app re-derives autoFix when no PR record defines it). A card that a window wins and
    that is written over a main copy keeps the main copy's flags that were on, so using a
    chat in a window never switches the main window's auto-fix off.
  * Copies in different roles (main vs window) differ in bytes by design, so they count as
    converged on mtime alone; a converged tree still costs one stat per card.

The sidebar prefs (preferences.epitaxyPrefs: pins, sections, filters; SIDEBAR_PREF_KEYS)
go from the main window's claude_desktop_config.json to each window's, only while that
window is not running (a running app keeps its prefs in memory and would write its own
back). Each window has a record of the sidebar values it held when it was last in step with
the main window (SIDEBAR_BASE_NAME in its data dir: the main window's values as last pushed
to it, or the window's own when it was last read while it ran). They go the other way
whenever the main window is not running, and then only what the window changed since that
record, as a three-way merge (base = the record, ours = the main window, theirs = the window):
a pin the window added arrives, one it removed leaves, and a stale value the window never
touched cannot undo what the main window did since (a pin removed in the main window stays
removed). A window with no record yet is only pushed to. Process checks use `ps` and fail closed.

Test hooks: CCD_WINDOWS_JSON, CCD_MAIN_CONFIG, CCD_SYNC_PS_FILE (a file of `ps -axo args=` lines).
"""
import collections, copy, ctypes, fcntl, json, os, plistlib, re, shlex, shutil, subprocess, sys, time

ROOT = os.environ.get("CCD_SESSIONS_ROOT") or os.path.expanduser(
    "~/Library/Application Support/Claude/claude-code-sessions")
BASE = os.environ.get("CCD_SYNC_BASE") or os.path.expanduser("~/.claude/session-sync")
BACKUPS = os.path.expanduser("~/.claude/backups/ccd-session-sync")
PLIST = os.environ.get("CCD_SYNC_PLIST") or os.path.expanduser(
    "~/Library/LaunchAgents/local.rotor.session-sync.plist")
WINDOWS_JSON = os.environ.get("CCD_WINDOWS_JSON") or os.path.expanduser(
    "~/Library/Application Support/ClaudeAccounts/windows.json")
MAIN_CONFIG = os.environ.get("CCD_MAIN_CONFIG") or os.path.join(os.path.dirname(ROOT), "claude_desktop_config.json")
CLAUDE_EXE = "/Applications/Claude.app/Contents/MacOS/Claude"
# preferences.epitaxyPrefs keys that make up the sidebar. The first four are lists replaced
# whole when pushed; KEYED_PREFS are dicts keyed by account/org or group id, merged key by key.
# What goes back to the main window is a three-way merge (merge3).
SIDEBAR_PREF_KEYS = ("starred-local-code-sessions", "starred-cowork-spaces", "starred-session-groups",
                     "starred-local-routines", "dframe-local-slice", "dframe-code-sections",
                     "dframe-group-scopes", "ccd-sessions-filter")
KEYED_PREFS = ("dframe-code-sections", "dframe-group-scopes")
SIDEBAR_BASE_NAME = "ccd-sidebar-base.json"  # in a window's data dir: its sidebar values at the last sync
WINDOWS = []  # extra windows named by windows.json, set by main()
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TMP_RE = re.compile(r"^local_.*\.json\.tmp\.(\d+)$")
# Copies written before 2026-10-06 carry the source mtime rounded through a
# float, which lands within 1 µs of it. Nothing looser is trusted: two saves of
# a card are often the same size (only timestamps move) and can be milliseconds
# apart, and a pass that starts on the first save would otherwise never see the second.
MTIME_SLOP_NS = 1_000
ADD_RESCAN_SECS = float(os.environ.get("CCD_SYNC_ADD_RESCAN_SECS", 2.0))

ARGS = set(sys.argv[1:])
DRY = "--dry-run" in ARGS
VERBOSE = "-v" in ARGS
CLONE = "--no-clone" not in ARGS
N = collections.Counter()  # adds, updates, mtime_fixes, compares, deferred, tmp_removed, prefs_*


def is_card(name):
    return name.startswith("local_") and name.endswith(".json")


def load_windows():
    """The extra windows windows.json names: [{accountId, dataDir, root}] where root is
    <dataDir>/claude-code-sessions. Missing, unreadable or foreign-version files and
    entries that are not windows/<account uuid> dirs yield nothing: the engine owns the file."""
    try:
        with open(WINDOWS_JSON, "rb") as fh:
            reg = json.load(fh)
    except (OSError, ValueError):
        return []
    items = reg.get("windows") if isinstance(reg, dict) and reg.get("version", 1) == 1 else None
    out, seen = [], set()
    for w in items if isinstance(items, list) else []:
        data_dir = w.get("dataDir") if isinstance(w, dict) else None
        if not isinstance(data_dir, str) or not os.path.isabs(data_dir):
            continue
        data_dir = os.path.normpath(data_dir)
        if (data_dir in seen or not UUID_RE.match(os.path.basename(data_dir).lower())
                or os.path.realpath(data_dir) == os.path.realpath(os.path.dirname(ROOT))):
            continue
        seen.add(data_dir)
        account = w.get("accountId")
        out.append({"accountId": account if isinstance(account, str) else os.path.basename(data_dir),
                    "dataDir": data_dir, "root": os.path.join(data_dir, "claude-code-sessions")})
    return out


def is_window(store):
    """Main-root stores are named relative to ROOT; window stores by absolute path
    (os.path.join(ROOT, absolute) is that path, so every join below serves both)."""
    return os.path.isabs(store)


def discover_in(root, absolute):
    stores = []
    try:
        outers = sorted(os.listdir(root))
    except (FileNotFoundError, NotADirectoryError):
        return stores  # a root that is gone (a closed or removed window) has no stores
    for outer in outers:
        od = os.path.join(root, outer)
        if not (os.path.isdir(od) and UUID_RE.match(outer)):
            continue
        try:
            inners = sorted(os.listdir(od))
        except (FileNotFoundError, NotADirectoryError):
            continue
        for inner in inners:
            d = os.path.join(od, inner)
            if os.path.isdir(d) and UUID_RE.match(inner):
                stores.append(d if absolute else os.path.join(outer, inner))
    return stores


def discover_stores():
    stores = discover_in(ROOT, False)
    for w in WINDOWS:
        stores += discover_in(w["root"], True)
    return stores


def note(*what):
    if VERBOSE:
        print("  ", *what)


def sig(path, dir_fd=None):
    """(size, mtime_ns), the whole of what a converged copy is judged on."""
    try:
        st = os.stat(path, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    return (st.st_size, st.st_mtime_ns)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def listing(stores):
    """store -> card names, from readdir alone. Also sweeps temp files that a
    killed run left behind, but only once the pid in their name is gone."""
    out = {}
    for s in stores:
        d = os.path.join(ROOT, s)
        try:
            names = os.listdir(d)
        except (FileNotFoundError, NotADirectoryError):
            continue  # store removed since discovery
        out[s] = {n for n in names if is_card(n)}
        for n in names:
            m = TMP_RE.match(n) if ".tmp." in n else None
            if m and not pid_alive(int(m.group(1))):
                note("stale temp", os.path.join(s, n))
                N["tmp_removed"] += 1
                if not DRY:
                    try:
                        os.unlink(os.path.join(d, n))
                    except FileNotFoundError:
                        pass
    return out


def stat_scan(stores, names=None):
    """store -> {card: sig}, one fstatat per card against an open store dir."""
    sigs = {}
    for s in stores:
        try:
            fd = os.open(os.path.join(ROOT, s), os.O_RDONLY)
        except (FileNotFoundError, NotADirectoryError):
            continue
        try:
            cards = names[s] if names and s in names else [n for n in os.listdir(fd) if is_card(n)]
            sigs[s] = {n: g for n in cards for g in [sig(n, dir_fd=fd)] if g}
        finally:
            os.close(fd)
    return sigs


def winners(sigs):
    """card -> (sig, store) of its newest copy."""
    best = {}
    for s, cards in sigs.items():
        for n, g in cards.items():
            if n not in best or g[1] > best[n][0][1]:
                best[n] = (g, s)
    return best


def load_source(path):
    """(bytes, sig, mode) of a card that held still while it was read and
    parses as JSON; None otherwise, so a half-written or truncated newest copy
    is left for a later pass rather than pushed over 48 good ones."""
    for _ in range(3):
        try:
            with open(path, "rb") as fh:
                a = os.fstat(fh.fileno())
                data = fh.read()
                b = os.fstat(fh.fileno())
        except FileNotFoundError:
            return None
        if (a.st_size, a.st_mtime_ns) == (b.st_size, b.st_mtime_ns) and len(data) == b.st_size:
            try:
                json.loads(data)
            except ValueError:
                return None
            return data, (b.st_size, b.st_mtime_ns), b.st_mode & 0o777
        time.sleep(0.05)
    return None


def _prs_by_key(card):
    return {pr.get("url") or (pr.get("repo"), pr.get("prNumber")): pr
            for pr in card.get("prs") or [] if isinstance(pr, dict)}


def _dump_card(card):
    """Cards are compact JSON with raw UTF-8, as the app writes them."""
    return json.dumps(card, separators=(",", ":"), ensure_ascii=False).encode()


# The same card fields scripts/sync-window-settings.py switches off in an extra window's own cards.
SESSION_FLAGS_OFF = ("autoFixEnabled", "autoFixOwnPrs", "autoArchiveOnPrClose")
SESSION_LATCHES_DROP = ("autoFixNextOwnPr", "autoFixNextOwnPrClick")


def strip_autofix(data):
    """The copy of a card that belongs in a window root: every PR's autoFix and the
    session-level SESSION_FLAGS_OFF are false, the SESSION_LATCHES_DROP one-shots are gone. Set to false rather than removed, because the
    app turns autoFixEnabled into prs[].autoFix when no PR record defines one. Returns
    `data` itself when nothing was on, so such cards keep being cloned."""
    try:
        card = json.loads(data)
    except ValueError:
        return data
    if not isinstance(card, dict):
        return data
    changed = False
    for pr in card.get("prs") or []:
        if isinstance(pr, dict) and pr.get("autoFix"):
            pr["autoFix"], changed = False, True
    for flag in SESSION_FLAGS_OFF:
        if card.get(flag):
            card[flag], changed = False, True
    for latch in SESSION_LATCHES_DROP:
        if card.get(latch):
            del card[latch]
            changed = True
    return _dump_card(card) if changed else data


def keep_autofix(data, current):
    """A window's card about to replace a main copy (`current`, bytes or None): flags that
    are on in the main copy stay on. Returns `data` itself when there is nothing to keep."""
    if current is None:
        return data
    try:
        card, old = json.loads(data), json.loads(current)
    except ValueError:
        return data
    if not isinstance(card, dict) or not isinstance(old, dict):
        return data
    changed, olds = False, _prs_by_key(old)
    for key, pr in _prs_by_key(card).items():
        if olds.get(key, {}).get("autoFix") and not pr.get("autoFix"):
            pr["autoFix"], changed = True, True
    for key in SESSION_FLAGS_OFF + SESSION_LATCHES_DROP:
        if old.get(key) and not card.get(key):
            card[key], changed = old[key], True
    return _dump_card(card) if changed else data


def project(dst_store, src_store, data, dst_path):
    """The bytes dst_path should hold when `data` is the newest copy, held in src_store."""
    if is_window(dst_store):
        return strip_autofix(data)
    if is_window(src_store):
        try:
            with open(dst_path, "rb") as fh:
                current = fh.read()
        except (OSError, TypeError):  # no copy there yet (dst_path None) or it vanished
            current = None
        return keep_autofix(data, current)
    return data


def converged(store, g, win_store, w):
    """Is copy g of a card, in `store`, the newest copy w (in win_store) as that store should
    hold it? Copies in different roles differ in bytes by design, so for them mtime decides."""
    if abs(g[1] - w[1]) >= MTIME_SLOP_NS:
        return False
    return g[0] == w[0] or is_window(store) != is_window(win_store)


try:
    _clonefile = ctypes.CDLL(None, use_errno=True).clonefile
    _clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
except (AttributeError, OSError):
    _clonefile = None


def clonefile(src, dst):
    """APFS copy-on-write clone: its own inode, shared blocks. False where unsupported."""
    return _clonefile is not None and _clonefile(os.fsencode(src), os.fsencode(dst), 0) == 0


def install(src, data, ssig, mode, dst, replace, clone):
    """Atomically put the validated source at dst via temp + rename. An add
    links instead, so a card that appeared since the listing is not clobbered,
    and a replace backs off if the copy has meanwhile become the newer one.
    clone: False = bytes, True = clone with a bytes fallback, "only" = clone or nothing."""
    tmp = f"{dst}.tmp.{os.getpid()}"
    try:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        if not (clone and clonefile(src, tmp) and sig(tmp) == ssig):
            if clone == "only":
                return False
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
        os.utime(tmp, ns=(ssig[1], ssig[1]))
        if replace:
            now = sig(dst)
            if now is not None and now[1] > ssig[1]:
                return False
            os.replace(tmp, dst)
        else:
            os.link(tmp, dst)
        return True
    except (FileExistsError, FileNotFoundError):
        return False
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def judge(dst, data, ssig, converge):
    """How an existing copy stands against the source: 'same' bytes (its mtime
    is converged here, through the open fd, when asked), 'differs', 'newer'
    (written since the scan; it wins next pass) or 'gone'."""
    try:
        fh = open(dst, "rb")
    except FileNotFoundError:
        return "gone"
    with fh:
        st = os.fstat(fh.fileno())
        if st.st_mtime_ns > ssig[1]:
            return "newer"
        if st.st_size != len(data):
            return "differs"
        N["compares"] += 1
        if fh.read() != data:
            return "differs"
        if converge and st.st_mtime_ns != ssig[1]:
            os.utime(fh.fileno(), ns=(ssig[1], ssig[1]))
        return "same"


def add_missing(stores):
    """Give every store each card it lacks, newest card first."""
    names = listing(stores)
    held = collections.Counter(n for cards in names.values() for n in cards)
    todo = []
    for n, count in held.items():
        if count == len(names):
            continue
        have = [(sig(os.path.join(ROOT, s, n)), s) for s in names if n in names[s]]
        have = [(g, s) for g, s in have if g]
        if have:
            g, s = max(have, key=lambda x: x[0][1])
            todo.append((g[1], n, s, [t for t in names if n not in names[t]]))
    for _, n, s, missing in sorted(todo, reverse=True):
        src = os.path.join(ROOT, s, n)
        got = load_source(src)
        if got is None:
            note("deferred", n, "in", s)
            N["deferred"] += 1
            continue
        for t in missing:
            note("add", n, "->", t)
            data = project(t, s, got[0], None)
            if DRY or install(src, data, (len(data), got[1][1]), got[2], os.path.join(ROOT, t, n), False,
                              CLONE and data is got[0]):
                N["adds"] += 1
                names[t].add(n)
    return names


def update_stale(stores, names):
    """Bring every copy that disagrees with the newest one into line."""
    sigs = stat_scan(stores, names)
    best = winners(sigs)
    stale = collections.defaultdict(list)
    for s, cards in sigs.items():
        for n, g in cards.items():
            if not converged(s, g, best[n][1], best[n][0]):
                stale[n].append(s)
    last_adds = time.monotonic()
    for n in sorted(stale, key=lambda n: best[n][0][1], reverse=True):
        if not DRY and time.monotonic() - last_adds > ADD_RESCAN_SECS:
            add_missing(stores)
            last_adds = time.monotonic()
        src = os.path.join(ROOT, best[n][1], n)
        got = load_source(src)
        if got is None:
            note("deferred", n, "in", best[n][1])
            N["deferred"] += 1
            continue
        data, ssig, mode = got
        for s in stale[n]:
            dst = os.path.join(ROOT, s, n)
            want = project(s, best[n][1], data, dst)
            wsig = (len(want), ssig[1])
            verdict = judge(dst, want, wsig, converge=not DRY)
            if verdict == "same":
                N["mtime_fixes"] += 1
            elif verdict == "differs":
                note("update", n, "->", s)
                if DRY or install(src, want, wsig, mode, dst, True, CLONE and want is data):
                    N["updates"] += 1
    if not DRY and time.monotonic() - last_adds > ADD_RESCAN_SECS:
        add_missing(stores)
    return len(best)


def backup(stores):
    """The newest copy of every card (enough to refill any store), cloned
    where the filesystem allows so the snapshot costs no space until cards change."""
    dest = os.path.join(BACKUPS, time.strftime("%Y%m%d-%H%M%S") + "-preflight")
    os.makedirs(os.path.join(dest, "union"))
    sigs = stat_scan(stores)
    best = winners(sigs)
    for n in best:
        # newest copy that parses; the newest as it stands if none does
        ranked = sorted((s for s in sigs if n in sigs[s]), key=lambda s: sigs[s][n][1], reverse=True)
        s = next((s for s in ranked if load_source(os.path.join(ROOT, s, n))), ranked[0])
        src, dst = os.path.join(ROOT, s, n), os.path.join(dest, "union", n)
        if not clonefile(src, dst):
            shutil.copy2(src, dst)
    for extra in (os.path.realpath(__file__), PLIST):
        if os.path.exists(extra):
            shutil.copy2(extra, dest)
    with open(os.path.join(dest, "MANIFEST.txt"), "w") as fh:
        fh.write(f"root={ROOT}\nunion_cards={len(best)}\n")
        for s in stores:
            fh.write(f"{s} cards={len(sigs.get(s, ()))}\n")
    print(f"backed up union_cards={len(best)} from stores={len(stores)} to {dest}")


def dedupe(stores):
    """Swap each copy that is byte-identical to the newest one for an APFS
    clone of it. Every store keeps every card as its own file; only the blocks
    underneath become shared. Copies that differ are left to the normal pass."""
    sigs = stat_scan(stores)
    best = winners(sigs)
    shared = freed = 0
    for n, (_, ws) in best.items():
        src = os.path.join(ROOT, ws, n)
        got = load_source(src)
        if got is None:
            N["deferred"] += 1
            continue
        data, ssig, mode = got
        for s in sigs:
            dst = os.path.join(ROOT, s, n)
            if s == ws or n not in sigs[s] or judge(dst, data, ssig, converge=False) != "same":
                continue
            if DRY or install(src, data, ssig, mode, dst, True, "only"):
                shared += 1
                freed += ssig[0]
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} dedupe stores={len(stores)} union_cards={len(best)} "
          f"copies_shared={shared} logical_mb={freed / 1e6:.0f} dry_run={DRY}")


def watch_paths(stores):
    """What the agent must watch: the root (a new account appears there), every
    account dir (a new store appears there) and every store dir (cards); the same for each
    extra window's root; and the folder holding windows.json, so a new window is noticed."""
    main = [s for s in stores if not is_window(s)]
    accounts = sorted({s.split(os.sep)[0] for s in main})
    paths = [ROOT] + [os.path.join(ROOT, a) for a in accounts] + [os.path.join(ROOT, s) for s in main]
    for w in WINDOWS:
        if os.path.isdir(w["root"]):
            paths.append(w["root"])
    for s in stores:
        if is_window(s):
            paths += [os.path.dirname(s), s]
    if os.path.isdir(os.path.dirname(WINDOWS_JSON)):
        paths.append(os.path.dirname(WINDOWS_JSON))
    return list(dict.fromkeys(paths))


def agent_job():
    """The launchd job, but only if its plist is there and it is the one that runs this file."""
    try:
        with open(PLIST, "rb") as fh:
            job = plistlib.load(fh)
    except Exception:
        return None
    me = os.path.realpath(__file__)
    return job if any(os.path.realpath(a) == me for a in job.get("ProgramArguments", [])) else None


def unwatched(stores):
    """How many dirs the agent should be watching and is not."""
    job = agent_job()
    return 0 if job is None else len(set(watch_paths(stores)) - set(job.get("WatchPaths", [])))


def write_plist(stores):
    """Rewrite WatchPaths for today's stores; every other key of the agent is kept."""
    job = agent_job()
    job["WatchPaths"] = watch_paths(stores)
    tmp = f"{PLIST}.tmp.{os.getpid()}"
    with open(tmp, "wb") as fh:
        plistlib.dump(job, fh, sort_keys=False)
    os.replace(tmp, PLIST)
    return job


def reload_agent(job):
    """Make launchd read the plist again: bootout, then bootstrap until it
    takes (bootout returns before the teardown is finished). Run this from a
    terminal, never from the agent itself: bootout kills the job it is run from."""
    target = f"gui/{os.getuid()}"
    subprocess.run(["/bin/sh", "-c",
                    f"launchctl bootout {target}/{shlex.quote(job['Label'])} 2>/dev/null; "
                    f"for i in 1 2 3 4 5 6 7 8 9 10; do sleep 2; "
                    f"launchctl bootstrap {target} {shlex.quote(PLIST)} 2>/dev/null && break; done"], check=False)


def process_lines():
    """Argument strings of all processes (`ps -axo args=`); None when they cannot be listed."""
    try:
        fixture = os.environ.get("CCD_SYNC_PS_FILE")
        if fixture:
            with open(fixture) as fh:
                return fh.read().splitlines()
        return subprocess.run(["/bin/ps", "-axo", "args="], capture_output=True, text=True,
                              check=True, timeout=15).stdout.splitlines()
    except Exception:
        return None


def window_running(lines, data_dir):
    """True when Claude runs with exactly --user-data-dir=<data_dir>; fails closed."""
    if lines is None:
        return True
    prefix = f"{CLAUDE_EXE} --user-data-dir={data_dir}"
    return any(l == prefix or l.startswith(prefix + " ") for l in lines)


def main_running(lines):
    """True when the main window's Claude runs (its command line has no --user-data-dir); fails closed."""
    if lines is None:
        return True
    return any(l == CLAUDE_EXE or (l.startswith(CLAUDE_EXE + " ") and "--user-data-dir=" not in l) for l in lines)


def read_config(path):
    """(config dict, bytes, mtime_ns) or None when the file is missing or not a JSON object."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
            mtime = os.fstat(fh.fileno()).st_mtime_ns
        cfg = json.loads(raw)
    except (OSError, ValueError):
        return None
    return (cfg, raw, mtime) if isinstance(cfg, dict) else None


def write_config(path, cfg, raw):
    """Atomically rewrite a config in the style it was read in (indent 2 or compact)."""
    pretty = raw.startswith(b"{\n")
    ascii_only = all(b < 0x80 for b in raw)
    text = json.dumps(cfg, indent=2 if pretty else None, separators=None if pretty else (",", ":"),
                      ensure_ascii=ascii_only)
    if raw.endswith(b"\n"):
        text += "\n"
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        mode = 0o600
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def epitaxy_prefs(cfg, create=False):
    """cfg's preferences.epitaxyPrefs dict, or None when it has none (or, without `create`, may not be made)."""
    prefs = cfg.get("preferences")
    if not isinstance(prefs, dict):
        if "preferences" in cfg or not create:
            return None
        prefs = cfg["preferences"] = {}
    ep = prefs.get("epitaxyPrefs")
    if not isinstance(ep, dict):
        if "epitaxyPrefs" in prefs or not create:
            return None
        ep = prefs["epitaxyPrefs"] = {}
    return ep


def sidebar_values(cfg):
    """The SIDEBAR_PREF_KEYS part of cfg's epitaxyPrefs."""
    ep = epitaxy_prefs(cfg) or {}
    return {k: copy.deepcopy(ep[k]) for k in SIDEBAR_PREF_KEYS if k in ep}


def sidebar_apply(target, source):
    """Put source's sidebar prefs into target (both whole configs): what the main window pushes to a
    window. Lists and plain values replace; KEYED_PREFS dicts merge key by key, source winning.
    Returns True when target changed."""
    src = epitaxy_prefs(source)
    if src is None:
        return False
    ep = epitaxy_prefs(target, create=True)
    if ep is None:
        return False
    changed = False
    for key in SIDEBAR_PREF_KEYS:
        if key not in src:
            continue
        want = src[key]
        if key in KEYED_PREFS and isinstance(want, dict) and isinstance(ep.get(key), dict):
            want = {**ep[key], **want}
        if key not in ep or ep[key] != want:
            ep[key], changed = want, True
    return changed


_MISSING = object()


def merge3(base, ours, theirs):
    """Three-way merge of one pref value: base is what the window held when last in step, ours the
    main window's value now, theirs the window's. Only what the window changed since base is applied.
    Where both changed the same thing, dicts and lists merge member by member and anything else keeps
    ours. A list entry the window removed is removed, one it added is added; dict keys are never
    deleted, and a key the main window deleted stays deleted. _MISSING stands for "not there"."""
    if theirs == base:
        return ours  # the window did not touch it
    if ours == base or ours == theirs:
        return theirs
    if isinstance(ours, dict) and isinstance(theirs, dict):
        base_d = base if isinstance(base, dict) else {}
        out = dict(ours)
        for k, t in theirs.items():
            b = base_d.get(k, _MISSING)
            if t == b:
                continue
            if k in ours:
                out[k] = merge3(b, ours[k], t)
            elif k not in base_d:
                out[k] = t
        return out
    if isinstance(ours, list) and isinstance(theirs, list):
        base_l = base if isinstance(base, list) else []
        gone = [x for x in base_l if x not in theirs]
        new = [x for x in theirs if x not in base_l and x not in ours]
        return [x for x in ours if x not in gone] + new
    return ours


def sidebar_pull(target, source, base):
    """Merge what the window (`source`, a whole config) changed since `base` (its recorded sidebar
    values) into the main window's config `target`. Returns True when target changed."""
    src = epitaxy_prefs(source)
    if src is None:
        return False
    ep = epitaxy_prefs(target, create=True)
    if ep is None:
        return False
    changed = False
    for key in SIDEBAR_PREF_KEYS:
        if key not in src:
            continue
        want = merge3(base.get(key, _MISSING), ep.get(key, _MISSING), src[key])
        if want is not _MISSING and (key not in ep or ep[key] != want):
            ep[key], changed = want, True
    return changed


def load_sidebar_base(w):
    """The sidebar values recorded for window `w` (a dict), or None when there is no usable record."""
    try:
        with open(os.path.join(w["dataDir"], SIDEBAR_BASE_NAME), "rb") as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        return None
    values = rec.get("values") if isinstance(rec, dict) and rec.get("version") == 1 else None
    return values if isinstance(values, dict) else None


def save_sidebar_base(w, values, current):
    """Record `values` as window `w`'s sidebar at this sync (atomically; skipped when `current`, the
    record as loaded, already says so or on a dry run)."""
    if DRY or values == current:
        return
    path = os.path.join(w["dataDir"], SIDEBAR_BASE_NAME)
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "values": values}, fh)
        os.replace(tmp, path)
    except OSError:
        pass  # no record: the next pass only pushes, which loses nothing
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def sync_prefs():
    """Main window's sidebar prefs -> each window, and the window's own changes back (see the module docstring)."""
    main = read_config(MAIN_CONFIG)
    if main is None or not WINDOWS:
        return
    lines = process_lines()
    main_cfg, main_raw, _ = main
    for w in WINDOWS:
        path = os.path.join(w["dataDir"], "claude_desktop_config.json")
        win = read_config(path)
        if win is None:
            continue
        win_cfg, win_raw, _ = win
        base = load_sidebar_base(w)
        pulled = False
        if base is not None and not main_running(lines):
            pull = copy.deepcopy(main_cfg)
            if sidebar_pull(pull, win_cfg, base):  # what the window changed since the record goes to the main window
                note("prefs pull", w["accountId"])
                N["prefs_pulled"] += 1
                pulled = True
                if not DRY:
                    write_config(MAIN_CONFIG, pull, main_raw)
                    main = read_config(MAIN_CONFIG)
                    main_cfg, main_raw, _ = main if main else (pull, main_raw, 0)
                else:
                    main_cfg = pull
        push = copy.deepcopy(win_cfg)
        if not sidebar_apply(push, main_cfg):
            save_sidebar_base(w, sidebar_values(main_cfg), base)  # in step: the window has everything the main window has
            continue
        if window_running(lines, w["dataDir"]):
            N["prefs_deferred"] += 1
            note("prefs deferred, window running", w["accountId"])
            if pulled:
                save_sidebar_base(w, sidebar_values(win_cfg), base)  # what the window holds is now in the main window
            continue
        note("prefs push", w["accountId"])
        N["prefs_pushed"] += 1
        if not DRY:
            write_config(path, push, win_raw)
        save_sidebar_base(w, sidebar_values(main_cfg), base)


def main():
    WINDOWS[:] = load_windows()
    stores = discover_stores()
    if "--backup" in ARGS:
        return backup(stores)
    if ARGS & {"--write-plist", "--reload"}:
        if agent_job() is None:
            sys.exit(f"no launchd plist at {PLIST} that runs {os.path.realpath(__file__)}")
        job = write_plist(stores)
        if "--reload" in ARGS:
            reload_agent(job)
        return print(f"{job['Label']}: WatchPaths now {len(job['WatchPaths'])} paths for {len(stores)} stores"
                     f"{', agent reloaded' if '--reload' in ARGS else ' (not reloaded)'}")
    if not DRY:
        os.makedirs(BASE, exist_ok=True)
        lock = open(os.path.join(BASE, ".lock"), "a+")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(0)  # another run in progress
        lock.truncate(0)
        lock.write(f"{os.getpid()}\n")
        lock.flush()
    if "--dedupe" in ARGS:
        return dedupe(stores)
    t0 = time.monotonic()
    names = add_missing(stores)
    cards = update_stale(stores, names)
    sync_prefs()
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} stores={len(stores)} union_cards={cards} "
          f"pending_writes={N['adds'] + N['updates']} adds={N['adds']} updates={N['updates']} dry_run={DRY} "
          f"mtime_fixes={N['mtime_fixes']} compares={N['compares']} deferred={N['deferred']} "
          f"tmp_removed={N['tmp_removed']} unwatched={unwatched(stores)} windows={len(WINDOWS)} "
          f"prefs_pushed={N['prefs_pushed']} prefs_pulled={N['prefs_pulled']} prefs_deferred={N['prefs_deferred']} secs={time.monotonic() - t0:.1f}", flush=True)


if __name__ == "__main__":
    main()
