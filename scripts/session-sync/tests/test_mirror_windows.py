"""Tests for scripts/session-sync/mirror.py with extra Claude windows. Run from the repo root:
    python3 -I -m unittest discover -s scripts/session-sync/tests -v
Everything happens in temp trees; the real Claude folders, ~/.claude and launchd are never touched.
Passes run as a subprocess with the CCD_* environment pointing at the temp tree.
"""
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.environ.get("MIRROR_UNDER_TEST") or os.path.join(HERE, "..", "mirror.py")
EXE = "/Applications/Claude.app/Contents/MacOS/Claude"

ACCT_A = "11111111-1111-4111-8111-111111111111"
ORG_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
ACCT_B = "22222222-2222-4222-8222-222222222222"
ORG_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
ACCT_W = "33333333-3333-4333-8333-333333333333"
ORG_W = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
ACCT_W2 = "44444444-4444-4444-8444-444444444444"
ORG_W2 = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"


def slurp(path, mode="rb"):
    with open(path, mode) as fh:
        return fh.read()


def load_module():
    old = sys.argv
    sys.argv = ["mirror.py"]
    try:
        spec = importlib.util.spec_from_file_location("mirror_under_test", MIRROR)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.argv = old
    return mod


def card_bytes(card):
    return json.dumps(card, separators=(",", ":"), ensure_ascii=False).encode()


def pr(number, auto_fix=None, **extra):
    rec = {"repo": "o/r", "prNumber": number, "url": f"https://github.com/o/r/pull/{number}", "state": "OPEN"}
    if auto_fix is not None:
        rec["autoFix"] = auto_fix
    rec.update(extra)
    return rec


class Tree:
    """A temp Claude data dir (main) plus a ClaudeAccounts dir with windows.json."""

    def __init__(self, test):
        self.tmp = tempfile.mkdtemp(prefix="mirror-test-")
        test.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.main_dir = os.path.join(self.tmp, "Claude")
        self.root = os.path.join(self.main_dir, "claude-code-sessions")
        self.accounts_dir = os.path.join(self.tmp, "ClaudeAccounts")
        self.windows_json = os.path.join(self.accounts_dir, "windows.json")
        self.ps_file = os.path.join(self.tmp, "ps.txt")
        self.plist = os.path.join(self.tmp, "agent.plist")
        self.base = os.path.join(self.tmp, "base")
        self.windows = []
        os.makedirs(self.root)
        os.makedirs(self.accounts_dir)
        self.set_processes([])

    # layout
    def main_store(self, acct, org):
        d = os.path.join(self.root, acct, org)
        os.makedirs(d, exist_ok=True)
        return d

    def window_dir(self, acct):
        return os.path.join(self.accounts_dir, "windows", acct)

    def window_store(self, acct, org):
        d = os.path.join(self.window_dir(acct), "claude-code-sessions", acct, org)
        os.makedirs(d, exist_ok=True)
        return d

    def register(self, *accts, extra=()):
        self.windows = [{"accountId": a, "dataDir": self.window_dir(a), "signedIn": True,
                         "openedAt": None, "pid": None} for a in accts] + list(extra)
        with open(self.windows_json, "w") as fh:
            json.dump({"version": 1, "windows": self.windows}, fh)

    def set_processes(self, lines):
        with open(self.ps_file, "w") as fh:
            fh.write("\n".join(lines) + "\n")

    # cards
    @staticmethod
    def put(store, name, card, mtime):
        path = os.path.join(store, name)
        with open(path, "wb") as fh:
            fh.write(card if isinstance(card, bytes) else card_bytes(card))
        os.utime(path, (mtime, mtime))
        return path

    @staticmethod
    def read(store, name):
        with open(os.path.join(store, name), "rb") as fh:
            return json.loads(fh.read())

    @staticmethod
    def raw(store, name):
        with open(os.path.join(store, name), "rb") as fh:
            return fh.read()

    # running
    def env(self):
        env = dict(os.environ)
        env.update(CCD_SESSIONS_ROOT=self.root, CCD_SYNC_BASE=self.base, CCD_WINDOWS_JSON=self.windows_json,
                   CCD_SYNC_PLIST=self.plist, CCD_SYNC_PS_FILE=self.ps_file,
                   CCD_MAIN_CONFIG=os.path.join(self.main_dir, "claude_desktop_config.json"))
        env.pop("PYTHONPATH", None)
        return env

    def run(self, *args):
        out = subprocess.run([sys.executable, "-I", MIRROR, *args], env=self.env(), capture_output=True,
                             text=True, timeout=120)
        self.last = out
        if out.returncode != 0:
            raise AssertionError(f"mirror.py {args} exited {out.returncode}\n{out.stdout}\n{out.stderr}")
        return dict(re.findall(r"(\w+)=(\S+)", out.stdout.strip().splitlines()[-1])) if out.stdout.strip() else {}

    # prefs
    def write_config(self, data_dir, prefs, extra=None, indent=2):
        os.makedirs(data_dir, exist_ok=True)
        cfg = dict(extra or {"mcpServers": {}})
        cfg["preferences"] = prefs
        path = os.path.join(data_dir, "claude_desktop_config.json")
        with open(path, "w") as fh:
            fh.write(json.dumps(cfg, indent=indent))
        return path

    @staticmethod
    def read_json(path):
        with open(path) as fh:
            return json.load(fh)


class CardMirroring(unittest.TestCase):
    def setUp(self):
        self.t = Tree(self)
        self.a = self.t.main_store(ACCT_A, ORG_A)
        self.b = self.t.main_store(ACCT_B, ORG_B)
        self.w = self.t.window_store(ACCT_W, ORG_W)
        self.t.register(ACCT_W)
        self.now = time.time() - 1000

    def test_two_roots_mirror_both_ways(self):
        self.t.put(self.a, "local_one.json", {"sessionId": "one", "title": "from main"}, self.now)
        self.t.put(self.w, "local_two.json", {"sessionId": "two", "title": "from window"}, self.now + 5)
        stats = self.t.run()
        self.assertEqual(stats["windows"], "1")
        self.assertEqual(stats["stores"], "3")
        for store in (self.a, self.b, self.w):
            self.assertEqual(self.t.read(store, "local_one.json")["title"], "from main")
            self.assertEqual(self.t.read(store, "local_two.json")["title"], "from window")
        self.assertEqual(self.t.run()["pending_writes"], "0")  # converged: nothing to do

    def test_newest_wins_between_main_and_window(self):
        for store in (self.a, self.b, self.w):
            self.t.put(store, "local_x.json", {"sessionId": "x", "title": "old"}, self.now)
        self.t.run()
        self.t.put(self.w, "local_x.json", {"sessionId": "x", "title": "edited in window"}, self.now + 50)
        self.t.run()
        self.assertEqual(self.t.read(self.a, "local_x.json")["title"], "edited in window")
        self.assertEqual(self.t.read(self.b, "local_x.json")["title"], "edited in window")
        self.t.put(self.a, "local_x.json", {"sessionId": "x", "title": "edited in main"}, self.now + 90)
        stats = self.t.run()
        self.assertEqual(stats["updates"], "2")
        self.assertEqual(self.t.read(self.w, "local_x.json")["title"], "edited in main")
        self.assertEqual(self.t.run()["pending_writes"], "0")

    def test_older_window_copy_never_overwrites_newer_main(self):
        self.t.put(self.a, "local_x.json", {"sessionId": "x", "title": "new"}, self.now + 100)
        self.t.put(self.w, "local_x.json", {"sessionId": "x", "title": "old"}, self.now)
        self.t.run()
        self.assertEqual(self.t.read(self.w, "local_x.json")["title"], "new")

    def test_never_deletes(self):
        self.t.put(self.w, "local_gone.json", {"sessionId": "gone"}, self.now)
        self.t.run()
        os.unlink(os.path.join(self.w, "local_gone.json"))  # the window dropped it
        self.t.run()
        self.assertTrue(os.path.exists(os.path.join(self.a, "local_gone.json")))
        self.assertTrue(os.path.exists(os.path.join(self.w, "local_gone.json")))  # refilled, not deleted elsewhere

    def test_card_byte_identical_when_no_flags(self):
        self.t.put(self.a, "local_n.json", {"sessionId": "n", "title": "café", "prs": [pr(1, False)]}, self.now)
        self.t.run()
        self.assertEqual(self.t.raw(self.w, "local_n.json"), self.t.raw(self.a, "local_n.json"))

    def test_existing_behaviour_without_windows_json(self):
        os.unlink(self.t.windows_json)
        self.t.put(self.a, "local_m.json", {"sessionId": "m"}, self.now)
        stats = self.t.run()
        self.assertEqual(stats["windows"], "0")
        self.assertEqual(stats["stores"], "2")
        self.assertTrue(os.path.exists(os.path.join(self.b, "local_m.json")))
        self.assertFalse(os.path.exists(os.path.join(self.w, "local_m.json")))  # a window not listed is left alone


class AutoFix(unittest.TestCase):
    def setUp(self):
        self.t = Tree(self)
        self.a = self.t.main_store(ACCT_A, ORG_A)
        self.b = self.t.main_store(ACCT_B, ORG_B)
        self.w = self.t.window_store(ACCT_W, ORG_W)
        self.w2 = self.t.window_store(ACCT_W2, ORG_W2)
        self.t.register(ACCT_W, ACCT_W2)
        self.now = time.time() - 1000

    def flags(self, store, name):
        card = self.t.read(store, name)
        return [p.get("autoFix") for p in card.get("prs", [])], card.get("autoFixEnabled")

    def test_stripped_only_in_window_roots(self):
        card = {"sessionId": "s", "title": "t", "autoFixEnabled": True,
                "prs": [pr(1, True), pr(2, False), pr(3)], "other": {"autoFix": True}}
        self.t.put(self.a, "local_s.json", card, self.now)
        self.t.run()
        self.assertEqual(self.flags(self.b, "local_s.json"), ([True, False, None], True))
        for window in (self.w, self.w2):
            self.assertEqual(self.flags(window, "local_s.json"), ([False, False, None], False))
            self.assertTrue(self.t.read(window, "local_s.json")["other"]["autoFix"])  # only PR records are touched
            self.assertEqual(self.t.read(window, "local_s.json")["title"], "t")
        self.assertEqual(self.flags(self.a, "local_s.json"), ([True, False, None], True))  # the source is untouched

    def test_no_flapping_after_strip(self):
        self.t.put(self.a, "local_s.json", {"sessionId": "s", "prs": [pr(1, True)]}, self.now)
        self.t.run()
        for _ in range(2):
            stats = self.t.run()
            self.assertEqual((stats["pending_writes"], stats["compares"]), ("0", "0"))

    def test_update_into_window_strips_again(self):
        self.t.put(self.a, "local_s.json", {"sessionId": "s", "title": "1", "prs": [pr(1, True)]}, self.now)
        self.t.run()
        self.t.put(self.a, "local_s.json", {"sessionId": "s", "title": "2", "prs": [pr(1, True)]}, self.now + 60)
        self.t.run()
        self.assertEqual(self.t.read(self.w, "local_s.json")["title"], "2")
        self.assertEqual(self.flags(self.w, "local_s.json"), ([False], None))

    def test_window_win_does_not_switch_main_autofix_off(self):
        self.t.put(self.a, "local_s.json", {"sessionId": "s", "title": "1", "prs": [pr(1, True), pr(2, False)]}, self.now)
        self.t.run()
        # the window edits its (stripped) copy; it is now the newest
        edited = self.t.read(self.w, "local_s.json")
        edited["title"] = "edited in window"
        self.t.put(self.w, "local_s.json", edited, self.now + 80)
        self.t.run()
        for main in (self.a, self.b):
            self.assertEqual(self.t.read(main, "local_s.json")["title"], "edited in window")
            self.assertEqual(self.flags(main, "local_s.json")[0], [True, False])  # main's flag survived
        self.assertEqual(self.flags(self.w, "local_s.json")[0], [False, False])
        self.assertEqual(self.flags(self.w2, "local_s.json")[0], [False, False])
        stats = self.t.run()
        self.assertEqual((stats["pending_writes"], stats["compares"]), ("0", "0"))

    def test_card_born_in_window_reaches_main_as_is(self):
        self.t.put(self.w, "local_new.json", {"sessionId": "new", "prs": [pr(9, False)]}, self.now)
        self.t.run()
        self.assertEqual(self.t.raw(self.a, "local_new.json"), self.t.raw(self.w, "local_new.json"))

    def test_unit_strip_and_keep(self):
        mod = load_module()
        plain = card_bytes({"sessionId": "s", "prs": [pr(1, False), pr(2)]})
        self.assertIs(mod.strip_autofix(plain), plain)  # nothing on: same object, so it can be cloned
        self.assertEqual(mod.strip_autofix(b"not json"), b"not json")
        on = card_bytes({"sessionId": "s", "n": "café  ", "prs": [pr(1, True)], "autoFixEnabled": True})
        out = mod.strip_autofix(on)
        self.assertEqual(json.loads(out)["prs"][0]["autoFix"], False)
        self.assertEqual(json.loads(out)["autoFixEnabled"], False)
        self.assertEqual(out, card_bytes(json.loads(out)))  # still the app's compact UTF-8 form
        kept = mod.keep_autofix(out, on)
        self.assertEqual(json.loads(kept)["prs"][0]["autoFix"], True)
        self.assertIs(mod.keep_autofix(out, None), out)
        self.assertIs(mod.keep_autofix(out, b"garbage"), out)

    def test_unit_strip_and_keep_all_flags(self):
        mod = load_module()
        on = card_bytes({"sessionId": "s", "prs": [pr(1, True)], "autoFixEnabled": True, "autoFixOwnPrs": True,
                         "autoArchiveOnPrClose": True, "autoFixNextOwnPr": True, "autoFixNextOwnPrClick": True,
                         "autoFixDelivered": True})
        out = json.loads(mod.strip_autofix(on))
        for k in ("autoFixEnabled", "autoFixOwnPrs", "autoArchiveOnPrClose"):
            self.assertIs(out[k], False, k)
        self.assertNotIn("autoFixNextOwnPr", out)
        self.assertNotIn("autoFixNextOwnPrClick", out)
        self.assertIs(out["autoFixDelivered"], True)  # history, not a trigger
        kept = json.loads(mod.keep_autofix(mod.strip_autofix(on), on))
        for k in ("autoFixEnabled", "autoFixOwnPrs", "autoArchiveOnPrClose", "autoFixNextOwnPr", "autoFixNextOwnPrClick"):
            self.assertIs(kept[k], True, k)


class Registry(unittest.TestCase):
    def setUp(self):
        self.t = Tree(self)
        self.a = self.t.main_store(ACCT_A, ORG_A)
        self.now = time.time() - 1000

    def test_missing_windows_json(self):
        self.t.put(self.a, "local_x.json", {"sessionId": "x"}, self.now)
        stats = self.t.run()
        self.assertEqual((stats["windows"], stats["stores"]), ("0", "1"))

    def test_unreadable_or_foreign_windows_json(self):
        self.t.put(self.a, "local_x.json", {"sessionId": "x"}, self.now)
        for content in ("{not json", "[]", '{"version":2,"windows":[{"dataDir":"/x"}]}', '{"version":1}',
                        '{"version":1,"windows":"nope"}', '{"version":1,"windows":[1,null,{"dataDir":5}]}'):
            with open(self.t.windows_json, "w") as fh:
                fh.write(content)
            self.assertEqual(self.t.run()["windows"], "0", content)

    def test_entries_that_are_not_window_dirs_are_ignored(self):
        w = self.t.window_store(ACCT_W, ORG_W)
        elsewhere = os.path.join(self.t.tmp, "elsewhere", "claude-code-sessions", ACCT_W, ORG_W)
        os.makedirs(elsewhere)
        self.t.register(ACCT_W, extra=[
            {"accountId": "x", "dataDir": os.path.join(self.t.tmp, "elsewhere")},  # name is not an account uuid
            {"accountId": "y", "dataDir": "relative/dir"},
            {"accountId": "z", "dataDir": self.t.main_dir.replace("Claude", ACCT_B)},  # absent dir: harmless
        ])
        self.t.put(self.a, "local_x.json", {"sessionId": "x"}, self.now)
        stats = self.t.run()
        self.assertEqual(stats["stores"], "2")
        self.assertTrue(os.path.exists(os.path.join(w, "local_x.json")))
        self.assertFalse(os.path.exists(os.path.join(elsewhere, "local_x.json")))

    def test_window_not_signed_in_yet_gets_nothing_created(self):
        os.makedirs(os.path.join(self.t.window_dir(ACCT_W), "claude-code-sessions"))
        self.t.register(ACCT_W)
        self.t.put(self.a, "local_x.json", {"sessionId": "x"}, self.now)
        self.t.run()
        self.assertEqual(os.listdir(os.path.join(self.t.window_dir(ACCT_W), "claude-code-sessions")), [])

    def test_window_dir_disappears(self):
        w = self.t.window_store(ACCT_W, ORG_W)
        self.t.register(ACCT_W)
        self.t.put(w, "local_w.json", {"sessionId": "w"}, self.now)
        self.assertEqual(self.t.run()["stores"], "2")
        self.assertTrue(os.path.exists(os.path.join(self.a, "local_w.json")))
        shutil.rmtree(self.t.window_dir(ACCT_W))  # closed and removed, windows.json still lists it
        self.t.put(self.a, "local_later.json", {"sessionId": "later"}, self.now + 10)
        stats = self.t.run()
        self.assertEqual((stats["stores"], stats["windows"]), ("1", "1"))
        self.assertTrue(os.path.exists(os.path.join(self.a, "local_w.json")))  # nothing deleted from main
        self.assertFalse(os.path.exists(self.t.window_dir(ACCT_W)))  # and not recreated by us
        self.assertEqual(self.t.run()["pending_writes"], "0")

    def test_window_dir_disappears_mid_pass(self):
        # the store vanishes between discovery and the writes: install()/judge() must shrug
        mod = load_module()
        w = self.t.window_store(ACCT_W, ORG_W)
        mod.ROOT = self.t.root
        mod.BASE = self.t.base
        shutil.rmtree(self.t.window_dir(ACCT_W))
        self.t.put(self.a, "local_x.json", {"sessionId": "x"}, self.now)
        got = mod.load_source(os.path.join(self.a, "local_x.json"))
        ok = mod.install(os.path.join(self.a, "local_x.json"), got[0], got[1], got[2], os.path.join(w, "local_x.json"), False, True)
        self.assertFalse(ok)
        self.assertEqual(mod.judge(os.path.join(w, "local_x.json"), got[0], got[1], True), "gone")

    def test_watch_paths_include_window_roots(self):
        w = self.t.window_store(ACCT_W, ORG_W)
        self.t.register(ACCT_W)
        job = {"Label": "com.test.mirror", "ProgramArguments": ["/usr/bin/python3", os.path.realpath(MIRROR)],
               "WatchPaths": [self.t.root]}
        with open(self.t.plist, "wb") as fh:
            plistlib.dump(job, fh)
        self.t.run("--write-plist")
        with open(self.t.plist, "rb") as fh:
            paths = plistlib.load(fh)["WatchPaths"]
        wroot = os.path.join(self.t.window_dir(ACCT_W), "claude-code-sessions")
        for want in (self.t.root, os.path.join(self.t.root, ACCT_A), os.path.join(self.t.root, ACCT_A, ORG_A),
                     wroot, os.path.join(wroot, ACCT_W), w, self.t.accounts_dir):
            self.assertIn(want, paths)
        self.assertEqual(len(paths), len(set(paths)))
        # the pass reports no unwatched dir now that the plist lists them
        self.assertEqual(self.t.run()["unwatched"], "0")

    def test_agent_arguments_work_only_from_the_file_the_agent_runs(self):
        # Why the app runs --reload / --write-plist from the deployed copy and never from the bundled one.
        # (Only --write-plist here: --reload would also call launchctl.)
        deployed = os.path.join(self.t.tmp, "deployed", "mirror.py")
        os.makedirs(os.path.dirname(deployed))
        shutil.copy(MIRROR, deployed)
        with open(self.t.plist, "wb") as fh:
            plistlib.dump({"Label": "com.test.mirror", "ProgramArguments": ["/usr/bin/python3", deployed],
                           "WatchPaths": []}, fh)
        bundled = subprocess.run([sys.executable, "-I", MIRROR, "--write-plist"], env=self.t.env(),
                                 capture_output=True, text=True)
        self.assertNotEqual(bundled.returncode, 0)
        self.assertIn("no launchd plist", bundled.stderr)
        from_deployed = subprocess.run([sys.executable, "-I", deployed, "--write-plist"], env=self.t.env(),
                                       capture_output=True, text=True)
        self.assertEqual(from_deployed.returncode, 0, from_deployed.stderr)
        with open(self.t.plist, "rb") as fh:
            self.assertIn(self.t.root, plistlib.load(fh)["WatchPaths"])

    def test_dry_run_writes_nothing(self):
        w = self.t.window_store(ACCT_W, ORG_W)
        self.t.register(ACCT_W)
        self.t.put(self.a, "local_x.json", {"sessionId": "x", "prs": [pr(1, True)]}, self.now)
        stats = self.t.run("--dry-run")
        self.assertEqual(stats["adds"], "1")
        self.assertEqual(os.listdir(w), [])


class SidebarPrefs(unittest.TestCase):
    MAIN_PREFS = {
        "epitaxyPrefs": {
            "starred-local-code-sessions": ["local_1", "local_2"],
            "starred-session-groups": ["g1"],
            "dframe-local-slice": {"pinnedOrder": ["p1", "p2"], "homeProjectsPinnedOrder": []},
            "dframe-code-sections": {f"{ACCT_A}/{ORG_A}": {"sections": [{"id": "s1"}], "prefsSeeded": True}},
            "ccd-sessions-filter": {"state": {"selectedProjects": ["x"]}, "version": 1},
            "fastMode": True,
            "desktop-frame.paneStore.v1": {"state": {"lastPrimaryCodeSession": {"id": "MAIN"}}, "version": 1},
        },
        "menuBarEnabled": True,
    }

    def setUp(self):
        self.t = Tree(self)
        self.a = self.t.main_store(ACCT_A, ORG_A)
        self.w = self.t.window_store(ACCT_W, ORG_W)
        self.t.register(ACCT_W)
        self.main_cfg = self.t.write_config(self.t.main_dir, json.loads(json.dumps(self.MAIN_PREFS)))
        self.win_dir = self.t.window_dir(ACCT_W)
        self.win_prefs = {
            "epitaxyPrefs": {
                "starred-local-code-sessions": ["local_old"],
                "dframe-code-sections": {f"{ACCT_W}/{ORG_W}": {"sections": [{"id": "own"}]}},
                "fastMode": False,
                "desktop-frame.paneStore.v1": {"state": {"lastPrimaryCodeSession": {"id": "WINDOW"}}, "version": 1},
            },
            "menuBarEnabled": False,
        }
        self.win_cfg = self.t.write_config(self.win_dir, self.win_prefs, extra={"mcpServers": {"keep": {}}})
        past = time.time() - 500
        os.utime(self.main_cfg, (past, past))  # main older than the window by default; tests change it
        os.utime(self.win_cfg, (past + 100, past + 100))
        self.main_proc = EXE
        self.win_proc = f"{EXE} --user-data-dir={self.win_dir}"

    def ep(self, path):
        return self.t.read_json(path)["preferences"]["epitaxyPrefs"]

    def test_main_to_window_when_window_closed_and_main_newer(self):
        later = time.time()
        os.utime(self.main_cfg, (later, later))
        self.t.set_processes([self.main_proc])
        stats = self.t.run()
        self.assertEqual(stats["prefs_pushed"], "1")
        ep, main_ep = self.ep(self.win_cfg), self.ep(self.main_cfg)
        self.assertEqual(ep["starred-local-code-sessions"], ["local_1", "local_2"])
        self.assertEqual(ep["starred-session-groups"], ["g1"])
        self.assertEqual(ep["dframe-local-slice"], main_ep["dframe-local-slice"])
        self.assertEqual(ep["ccd-sessions-filter"], main_ep["ccd-sessions-filter"])
        self.assertEqual(ep["dframe-code-sections"][f"{ACCT_A}/{ORG_A}"], main_ep["dframe-code-sections"][f"{ACCT_A}/{ORG_A}"])
        self.assertIn(f"{ACCT_W}/{ORG_W}", ep["dframe-code-sections"])  # keyed dicts merge, window-only keys stay
        # everything else in the window is left exactly as it was
        cfg = self.t.read_json(self.win_cfg)
        self.assertEqual(ep["fastMode"], False)
        self.assertEqual(ep["desktop-frame.paneStore.v1"]["state"]["lastPrimaryCodeSession"], {"id": "WINDOW"})
        self.assertEqual(cfg["preferences"]["menuBarEnabled"], False)
        self.assertEqual(cfg["mcpServers"], {"keep": {}})
        # the main config was not written
        self.assertEqual(self.t.read_json(self.main_cfg)["preferences"], self.MAIN_PREFS)
        self.assertEqual(self.t.run()["prefs_pushed"], "0")  # converged

    def test_window_running_is_not_written(self):
        later = time.time()
        os.utime(self.main_cfg, (later, later))
        before = slurp(self.win_cfg)
        self.t.set_processes([self.main_proc, self.win_proc, f"{EXE} --user-data-dir={self.win_dir}-other"])
        stats = self.t.run()
        self.assertEqual((stats["prefs_pushed"], stats["prefs_deferred"]), ("0", "1"))
        self.assertEqual(slurp(self.win_cfg), before)
        self.t.set_processes([self.main_proc, f"{EXE} --user-data-dir={self.win_dir}-other"])  # a neighbour's dir is not ours
        self.assertEqual(self.t.run()["prefs_pushed"], "1")

    def test_window_newer_with_main_running_main_wins(self):
        self.t.set_processes([self.main_proc])
        self.assertGreater(os.stat(self.win_cfg).st_mtime, os.stat(self.main_cfg).st_mtime)
        stats = self.t.run()
        self.assertEqual((stats["prefs_pulled"], stats["prefs_pushed"]), ("0", "1"))
        self.assertEqual(self.t.read_json(self.main_cfg)["preferences"], self.MAIN_PREFS)
        self.assertEqual(self.ep(self.win_cfg)["starred-local-code-sessions"], ["local_1", "local_2"])

    def test_window_newer_with_main_closed_window_wins(self):
        # First pass: the window has no record yet, so only main is pushed; its own pin is not taken over.
        self.t.set_processes([])  # nothing runs
        stats = self.t.run()
        self.assertEqual((stats["prefs_pulled"], stats["prefs_pushed"]), ("0", "1"))
        self.assertEqual(self.t.read_json(self.main_cfg)["preferences"], self.MAIN_PREFS)
        self.assertEqual(self.ep(self.win_cfg)["starred-local-code-sessions"], ["local_1", "local_2"])
        # The window then pins something of its own: that arrives in main (added to its pins, not replacing them).
        win = self.t.read_json(self.win_cfg)
        win["preferences"]["epitaxyPrefs"]["starred-local-code-sessions"] = ["local_1", "local_2", "local_old"]
        win["preferences"]["epitaxyPrefs"]["dframe-code-sections"][f"{ACCT_W}/{ORG_W}"] = {"sections": [{"id": "own-edited"}]}
        with open(self.win_cfg, "w") as fh:
            json.dump(win, fh, indent=2)
        later = time.time() + 5
        os.utime(self.win_cfg, (later, later))
        stats = self.t.run()
        self.assertEqual(stats["prefs_pulled"], "1")
        main_ep = self.ep(self.main_cfg)
        self.assertEqual(main_ep["starred-local-code-sessions"], ["local_1", "local_2", "local_old"])
        self.assertEqual(main_ep["dframe-code-sections"][f"{ACCT_W}/{ORG_W}"], {"sections": [{"id": "own-edited"}]})
        self.assertIn(f"{ACCT_A}/{ORG_A}", main_ep["dframe-code-sections"])  # merged, not replaced
        self.assertEqual(main_ep["fastMode"], True)  # only sidebar keys travel
        self.assertEqual(main_ep["desktop-frame.paneStore.v1"]["state"]["lastPrimaryCodeSession"], {"id": "MAIN"})
        self.assertEqual(self.t.read_json(self.main_cfg)["preferences"]["menuBarEnabled"], True)
        # and both sides now agree
        self.assertEqual(self.ep(self.win_cfg)["starred-local-code-sessions"], ["local_1", "local_2", "local_old"])
        stats = self.t.run()
        self.assertEqual((stats["prefs_pulled"], stats["prefs_pushed"]), ("0", "0"))

    def test_unknown_process_state_fails_closed(self):
        os.unlink(self.t.ps_file)  # CCD_SYNC_PS_FILE unreadable: nothing can be told, so nothing is written
        before = (slurp(self.win_cfg), slurp(self.main_cfg))
        stats = self.t.run()
        self.assertEqual((stats["prefs_pushed"], stats["prefs_pulled"]), ("0", "0"))
        self.assertEqual((slurp(self.win_cfg), slurp(self.main_cfg)), before)

    def test_missing_configs_are_skipped(self):
        os.unlink(self.win_cfg)
        self.assertEqual(self.t.run()["prefs_pushed"], "0")
        self.t.write_config(self.win_dir, self.win_prefs)
        os.unlink(self.main_cfg)
        self.assertEqual(self.t.run()["prefs_pushed"], "0")

    def test_style_and_mode_are_kept(self):
        later = time.time()
        os.utime(self.main_cfg, (later, later))
        os.chmod(self.win_cfg, 0o600)
        raw = slurp(self.win_cfg, "r")
        self.assertTrue(raw.startswith("{\n"))
        self.t.run()
        new = slurp(self.win_cfg, "r")
        self.assertEqual(new, json.dumps(json.loads(new), indent=2))
        self.assertEqual(os.stat(self.win_cfg).st_mode & 0o777, 0o600)

    def test_dry_run_leaves_prefs_alone(self):
        later = time.time()
        os.utime(self.main_cfg, (later, later))
        before = slurp(self.win_cfg)
        stats = self.t.run("--dry-run")
        self.assertEqual(stats["prefs_pushed"], "1")
        self.assertEqual(slurp(self.win_cfg), before)


class SidebarThreeWay(unittest.TestCase):
    """Windows' sidebar prefs go back to main as a three-way merge against a record of what each window
    held when it was last in step: nothing a window did not change can undo what main did since."""
    PINS = "starred-local-code-sessions"
    SECTIONS = "dframe-code-sections"
    FILTER = "ccd-sessions-filter"
    KEY_A = f"{ACCT_A}/{ORG_A}"
    KEY_W = f"{ACCT_W}/{ORG_W}"

    def setUp(self):
        self.t = Tree(self)
        self.t.main_store(ACCT_A, ORG_A)
        self.t.window_store(ACCT_W, ORG_W)
        self.t.register(ACCT_W)
        self.win_dir = self.t.window_dir(ACCT_W)
        self.main_cfg = self.t.write_config(self.t.main_dir, {"epitaxyPrefs": {
            self.PINS: ["a", "b"],
            self.SECTIONS: {self.KEY_A: {"sections": [{"id": "s1"}]}},
            self.FILTER: {"state": {"selectedProjects": ["x"]}, "version": 1}}})
        self.win_cfg = self.t.write_config(self.win_dir, {"epitaxyPrefs": {self.PINS: ["old"]}})
        self.edit(self.main_cfg, {}, 600)
        self.edit(self.win_cfg, {}, 500)
        self.main_proc = EXE
        self.win_proc = f"{EXE} --user-data-dir={self.win_dir}"
        self.record = os.path.join(self.win_dir, "ccd-sidebar-base.json")

    def edit(self, path, changes, age):
        """Set (or, for None, delete) epitaxyPrefs keys in a config and give the file an mtime `age` s ago."""
        cfg = self.t.read_json(path)
        ep = cfg["preferences"]["epitaxyPrefs"]
        for k, v in changes.items():
            if v is None:
                ep.pop(k, None)
            else:
                ep[k] = v
        with open(path, "w") as fh:
            json.dump(cfg, fh, indent=2)
        past = time.time() - age
        os.utime(path, (past, past))

    def ep(self, path):
        return self.t.read_json(path)["preferences"]["epitaxyPrefs"]

    def first_sync(self):
        """The window is closed and main is open: main is pushed to it and the window's record is made."""
        self.t.set_processes([self.main_proc])
        self.assertEqual(self.t.run()["prefs_pushed"], "1")
        self.assertEqual(self.ep(self.win_cfg)[self.PINS], ["a", "b"])
        self.assertTrue(os.path.exists(self.record))

    def test_first_run_without_a_record_only_pushes_main(self):
        # The window's file is newer and main is closed, but nothing says what the window changed.
        self.t.set_processes([])
        stats = self.t.run()
        self.assertEqual((stats["prefs_pulled"], stats["prefs_pushed"]), ("0", "1"))
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a", "b"])
        self.assertEqual(self.ep(self.win_cfg)[self.PINS], ["a", "b"])
        rec = self.t.read_json(self.record)
        self.assertEqual(rec["values"][self.PINS], ["a", "b"])
        self.assertEqual(os.stat(self.record).st_mode & 0o777, 0o600)
        self.assertEqual(self.t.run()["prefs_pushed"], "0")  # converged, record unchanged

    def test_running_window_without_a_record_is_left_alone(self):
        self.t.set_processes([self.win_proc])  # the repro: window running, main closed (mid-switch)
        before = (slurp(self.win_cfg), slurp(self.main_cfg))
        stats = self.t.run()
        self.assertEqual((stats["prefs_pulled"], stats["prefs_pushed"], stats["prefs_deferred"]), ("0", "0", "1"))
        self.assertEqual((slurp(self.win_cfg), slurp(self.main_cfg)), before)
        self.assertFalse(os.path.exists(self.record))

    def test_pin_removed_in_main_stays_removed(self):
        self.first_sync()
        self.edit(self.main_cfg, {self.PINS: ["a"]}, 100)  # unpinned b in main
        self.edit(self.win_cfg, {}, 50)  # the running window's file is newer, with its stale [a, b]
        self.t.set_processes([self.win_proc])  # main is closed (mid-switch), the window runs
        stats = self.t.run()
        self.assertEqual(stats["prefs_pulled"], "0")
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a"])
        self.t.set_processes([self.main_proc])  # the window closes: now it gets main's pins
        self.assertEqual(self.t.run()["prefs_pushed"], "1")
        self.assertEqual(self.ep(self.win_cfg)[self.PINS], ["a"])
        self.assertEqual(self.t.read_json(self.record)["values"][self.PINS], ["a"])
        self.t.set_processes([])
        self.assertEqual(self.t.run()["prefs_pulled"], "0")
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a"])

    def test_pin_added_in_window_arrives(self):
        self.first_sync()
        self.edit(self.win_cfg, {self.PINS: ["a", "b", "c"]}, 0)
        self.t.set_processes([])
        self.assertEqual(self.t.run()["prefs_pulled"], "1")
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a", "b", "c"])
        self.assertEqual(self.t.run()["prefs_pulled"], "0")
        self.assertEqual(self.t.read_json(self.record)["values"][self.PINS], ["a", "b", "c"])

    def test_pin_removed_in_window_leaves_main_too(self):
        self.first_sync()
        self.edit(self.win_cfg, {self.PINS: ["b"]}, 0)
        self.t.set_processes([])
        self.t.run()
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["b"])

    def test_both_sides_changed_keeps_main_and_adds_the_windows(self):
        self.first_sync()
        self.edit(self.main_cfg, {self.PINS: ["a", "m"]}, 100)  # main unpinned b, pinned m
        self.edit(self.win_cfg, {self.PINS: ["a", "b", "w"]}, 0)  # the window (stale) pinned w
        self.t.set_processes([])
        self.t.run()
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a", "m", "w"])
        self.assertEqual(self.ep(self.win_cfg)[self.PINS], ["a", "m", "w"])

    def test_stale_window_values_never_overwrite_main(self):
        self.first_sync()
        self.edit(self.main_cfg, {self.SECTIONS: {self.KEY_A: {"sections": [{"id": "main-new"}]}},
                                  self.FILTER: {"state": {"selectedProjects": ["y"]}, "version": 1}}, 100)
        self.edit(self.win_cfg, {}, 0)  # newer file, but its sidebar values are the ones pushed
        self.t.set_processes([])
        stats = self.t.run()
        self.assertEqual(stats["prefs_pulled"], "0")
        ep = self.ep(self.main_cfg)
        self.assertEqual(ep[self.SECTIONS][self.KEY_A], {"sections": [{"id": "main-new"}]})
        self.assertEqual(ep[self.FILTER]["state"]["selectedProjects"], ["y"])

    def test_only_what_the_window_changed_is_taken(self):
        self.first_sync()
        self.edit(self.main_cfg, {self.SECTIONS: {self.KEY_A: {"sections": [{"id": "main-new"}]}}}, 100)
        # the window changed its own account's sections and the filter, and still holds the old KEY_A sections
        self.edit(self.win_cfg, {self.SECTIONS: {self.KEY_A: {"sections": [{"id": "s1"}]}, self.KEY_W: {"sections": [{"id": "own"}]}},
                                 self.FILTER: {"state": {"selectedProjects": ["z"]}, "version": 1}}, 0)
        self.t.set_processes([])
        self.assertEqual(self.t.run()["prefs_pulled"], "1")
        ep = self.ep(self.main_cfg)
        self.assertEqual(ep[self.SECTIONS][self.KEY_A], {"sections": [{"id": "main-new"}]})
        self.assertEqual(ep[self.SECTIONS][self.KEY_W], {"sections": [{"id": "own"}]})
        self.assertEqual(ep[self.FILTER]["state"]["selectedProjects"], ["z"])

    def test_main_running_is_never_written(self):
        self.first_sync()
        self.edit(self.win_cfg, {self.PINS: ["a", "b", "c"]}, 0)
        before = slurp(self.main_cfg)
        self.t.set_processes([self.main_proc])
        stats = self.t.run()
        self.assertEqual(stats["prefs_pulled"], "0")
        self.assertEqual(slurp(self.main_cfg), before)

    def test_deferred_push_after_a_pull_keeps_the_pull_from_repeating(self):
        # The window runs (its file is read, not written), main is closed: the pull happens once. Main then
        # re-pins what the window had removed; the window's unchanged file must not remove it again.
        self.first_sync()
        self.edit(self.win_cfg, {self.PINS: ["a"]}, 0)  # window unpinned b
        self.t.set_processes([self.win_proc])
        self.assertEqual(self.t.run()["prefs_pulled"], "1")
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a"])
        self.edit(self.main_cfg, {self.PINS: ["a", "b"]}, 5)  # main pins b again
        self.edit(self.win_cfg, {}, 0)
        self.assertEqual(self.t.run()["prefs_pulled"], "0")
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a", "b"])

    def test_every_window_is_pulled_in_one_pass(self):
        w2 = os.path.join(self.t.accounts_dir, "windows", ACCT_W2)
        self.t.window_store(ACCT_W2, ORG_W2)
        self.t.register(ACCT_W, ACCT_W2)
        w2_cfg = self.t.write_config(w2, {"epitaxyPrefs": {self.PINS: ["old"]}})
        self.t.set_processes([self.main_proc])
        self.t.run()
        self.assertEqual(self.ep(w2_cfg)[self.PINS], ["a", "b"])
        self.edit(self.win_cfg, {self.PINS: ["a", "b", "c1"]}, 0)
        self.edit(w2_cfg, {self.PINS: ["a", "b", "c2"]}, 0)
        self.t.set_processes([])
        self.assertEqual(self.t.run()["prefs_pulled"], "2")
        self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a", "b", "c1", "c2"])

    def test_dry_run_records_nothing(self):
        self.t.set_processes([self.main_proc])
        self.t.run("--dry-run")
        self.assertFalse(os.path.exists(self.record))

    def test_unusable_record_means_push_only(self):
        self.first_sync()
        for junk in (b"", b"{", b'{"version": 2, "values": {}}', b'{"version": 1, "values": []}'):
            with open(self.record, "wb") as fh:
                fh.write(junk)
            self.edit(self.win_cfg, {self.PINS: ["a", "b", "c"]}, 0)
            self.t.set_processes([])
            self.assertEqual(self.t.run()["prefs_pulled"], "0")
            self.assertEqual(self.ep(self.main_cfg)[self.PINS], ["a", "b"])

    def test_unit_merge3(self):
        mod = load_module()
        M = mod._MISSING
        merge3 = mod.merge3
        self.assertEqual(merge3(["a", "b"], ["a"], ["a", "b"]), ["a"])  # window untouched: main's
        self.assertEqual(merge3(["a"], ["a"], ["a", "c"]), ["a", "c"])  # main untouched: window's
        self.assertEqual(merge3(["a", "b"], ["a", "m"], ["b", "w"]), ["m", "w"])  # main dropped b, window dropped a
        self.assertEqual(merge3(5, 6, 7), 6)  # scalars: main wins a conflict
        self.assertEqual(merge3(5, 5, 7), 7)
        self.assertEqual(merge3(M, ["x"], ["y"]), ["x", "y"])  # both added
        self.assertEqual(merge3(M, M, ["y"]), ["y"])
        self.assertIs(merge3("v", M, "w"), M)  # main deleted it: stays deleted
        self.assertEqual(merge3({"k": 1}, {"k": 1, "m": 2}, {"k": 1}), {"k": 1, "m": 2})  # window dropping a key changes nothing
        self.assertEqual(merge3({"k": 1}, {"k": 2}, {"k": 3, "n": 4}), {"k": 2, "n": 4})
        self.assertEqual(merge3({"k": 1}, {}, {"k": 3}), {})  # main deleted the key


if __name__ == "__main__":
    unittest.main()
