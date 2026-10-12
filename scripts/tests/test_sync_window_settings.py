"""Unit tests for scripts/sync-window-settings.py. Run:
    python3 -I -m unittest discover -s scripts/tests -v     (from the repo root)
Everything happens in temp folders that mimic a Claude data dir; the real folders are never touched.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sws", os.path.join(HERE, "..", "sync-window-settings.py"))
sws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sws)
REAL_LIST_PROCESSES = sws.list_processes

MAIN_ACCT = "66666666-7777-4888-8999-000000000000"
DEV_ACCT = "215367f8-1869-4a00-8a21-673f5e1926b2"


def write(path, data, mode=0o600):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    os.chmod(path, mode)


def wjson(path, obj, indent=2):
    write(path, json.dumps(obj, indent=indent) + "\n")


def rfile(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def rjson(path):
    with open(path) as f:
        return json.load(f)


def tree_hash(root):
    h = {}
    for dp, dn, fn in os.walk(root):
        for n in fn:
            p = os.path.join(dp, n)
            with open(p, "rb") as f:
                h[os.path.relpath(p, root)] = hashlib.sha256(f.read()).hexdigest()
    return h


def run(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = sws.main(argv, out=lambda s="": print(s))
    return code, buf.getvalue()


def leveldb_log(path, pairs):
    """Write a minimal LevelDB .log holding one WriteBatch of Puts (CRC left zero: the reader ignores it)."""
    def vi(n):
        out = bytearray()
        while n >= 0x80:
            out.append((n & 0x7F) | 0x80)
            n >>= 7
        out.append(n)
        return bytes(out)
    batch = struct.pack("<QI", 1, len(pairs))
    for k, v in pairs:
        batch += b"\x01" + vi(len(k)) + k + vi(len(v)) + v
    rec = b"\x00\x00\x00\x00" + struct.pack("<H", len(batch)) + b"\x01" + batch
    write(path, rec)


def ls_pairs(d):
    pre = b"_https://claude.ai\x00\x01"
    return [(pre + k.encode(), b"\x01" + v.encode()) for k, v in d.items()]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = os.path.join(self.tmp.name, "main")
        self.dst = os.path.join(self.tmp.name, "probe-1")
        self.make_src()
        self.make_dst()
        self.no_procs = lambda: []
        sws.list_processes = self.no_procs  # never look at the real process table

    def make_src(self):
        s = self.src
        wjson(f"{s}/claude_desktop_config.json", {
            "mcpServers": {"x": {"command": "foo"}},
            "coworkUserFilesPath": "/Users/x/Documents/Claude",
            "preferences": {
                "sidebarMode": "task", "keepAwakeEnabled": True, "storeReadCacheLatched": True,
                "bypassPermissionsOptInByAccount": {MAIN_ACCT: True, DEV_ACCT: True},
                "epitaxyPrefs": {"fastMode": True, "desktop-frame.paneStore.v1": {"state": {
                    "rowSplit": 0.5, "lastPrimaryCodeSession": {"id": "local_main"}}}},
            }})
        wjson(f"{s}/config.json", {
            "userThemeMode": "dark", "locale": "en-US", "windowControlsZoomFactor": 1.2,
            "lastKnownAccountUuid": MAIN_ACCT, "oauth:tokenCacheV2": "MAIN-SECRET",
            "updaterLastSeenVersion": "9.9.9", "first_launch_at": 1}, indent=1)
        wjson(f"{s}/Preferences", {
            "electron": {"media": {"device_id_salt": "MAINSALT"}},
            "spellcheck": {"dictionaries": ["en-US", "fr"]},
            "partition": {"per_host_zoom_levels": {"1111": {"claude.ai": -1.5, "about:blank": -1.5}}}})
        write(f"{s}/Cookies", "MAIN-COOKIES")
        write(f"{s}/ant-did", "MAIN-DID")
        wjson(f"{s}/window-state.json", {"x": 1, "y": 2, "width": 3, "height": 4})
        wjson(f"{s}/mcp-user-tool-toggles.json", {"v": 3, "owners": {MAIN_ACCT: ["a"], DEV_ACCT: ["srcdev"]}})
        wjson(f"{s}/extensions-installations.json", {"extensions": {"ext.one": {"id": "ext.one", "version": "1.0.8"}}})
        write(f"{s}/Claude Extensions/ext.one/manifest.json", "{\"name\":\"one\"}")
        write(f"{s}/Claude Extensions/ext.one/server/index.js", "main()")
        wjson(f"{s}/Claude Extensions Settings/ext.one.json", {"isEnabled": True})

    def make_dst(self):
        d = self.dst
        wjson(f"{d}/claude_desktop_config.json", {
            "preferences": {
                "sidebarMode": "chat", "keepAwakeEnabled": False, "storeReadCacheLatched": False,
                "targetOnlyPref": 1,
                "bypassPermissionsOptInByAccount": {MAIN_ACCT: True, DEV_ACCT: False},
                "epitaxyPrefs": {"fastMode": False, "desktop-frame.paneStore.v1": {"state": {
                    "rowSplit": 0.1, "lastPrimaryCodeSession": {"id": "local_probe"}}}},
            }})
        wjson(f"{d}/config.json", {
            "userThemeMode": "light", "locale": "de-DE", "windowControlsZoomFactor": 1.0,
            "lastKnownAccountUuid": DEV_ACCT, "oauth:tokenCacheV2": "DEV-SECRET",
            "updaterLastSeenVersion": "1.0.0", "first_launch_at": 99}, indent=1)
        wjson(f"{d}/Preferences", {
            "electron": {"media": {"device_id_salt": "PROBESALT"}},
            "spellcheck": {"dictionaries": ["en-US"]},
            "partition": {"per_host_zoom_levels": {
                "1111": {"claude.ai": -9.0},               # stale hand copy under the SOURCE's key
                "2222": {"claude.ai": 0.0, "keep.example": 1.0}}}})  # the target's own key
        write(f"{d}/Cookies", "DEV-COOKIES")
        write(f"{d}/ant-did", "DEV-DID")
        wjson(f"{d}/window-state.json", {"x": 10, "y": 20, "width": 30, "height": 40})

    def snapshot_files(self, names):
        out = {}
        for n in names:
            with open(os.path.join(self.dst, n), "rb") as f:
                out[n] = f.read()
        return out


class Classify(unittest.TestCase):
    def test_org_policy_and_latches_are_not_settings(self):
        for k in ("coworkHipaaRestricted", "orgWorkAcrossAppsDisabled", "storeReadCacheLatched", "installSourceLanding"):
            self.assertNotEqual(sws.classify_pref(k)[0], sws.SETTING, k)
        for k in ("sidebarMode", "keepAwakeEnabled", "launchPreviewStorage"):
            self.assertEqual(sws.classify_pref(k)[0], sws.SETTING, k)

    def test_config_keys(self):
        self.assertEqual(sws.classify_config("oauth:tokenCacheV2"), sws.ACCOUNT)
        self.assertEqual(sws.classify_config("userThemeMode"), sws.SETTING)
        self.assertEqual(sws.classify_config("updaterBannerStagedAt"), sws.RUNTIME)


class DryRun(Base):
    def test_dry_run_writes_nothing_and_never_prints_values(self):
        before_dst, before_src = tree_hash(self.dst), tree_hash(self.src)
        code, out = run(["--from", self.src, "--to", self.dst])
        self.assertEqual(code, 0)
        self.assertEqual(tree_hash(self.dst), before_dst)
        self.assertEqual(tree_hash(self.src), before_src)
        self.assertIn("preferences.sidebarMode", out)
        for secret in ("MAIN-SECRET", "DEV-SECRET", "dark", "MAINSALT"):
            self.assertNotIn(secret, out)
        self.assertFalse(os.path.exists(os.path.join(self.dst, sws.BACKUP_DIR)))

    def test_background_engines_are_listed(self):
        _, out = run(["--from", self.src, "--to", self.dst])
        self.assertIn("keepAwakeEnabled = on", out)


class Apply(Base):
    def apply(self):
        code, out = run(["--from", self.src, "--to", self.dst, "--apply"])
        self.assertEqual(code, 0, out)
        return out

    def test_settings_are_copied(self):
        self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")
        self.assertEqual(prefs["preferences"]["sidebarMode"], "task")
        self.assertIs(prefs["preferences"]["keepAwakeEnabled"], True)
        self.assertEqual(prefs["mcpServers"], {"x": {"command": "foo"}})
        self.assertNotIn("targetOnlyPref", prefs["preferences"])
        cfg = rjson(f"{self.dst}/config.json")
        self.assertEqual((cfg["userThemeMode"], cfg["locale"], cfg["windowControlsZoomFactor"]), ("dark", "en-US", 1.2))
        self.assertEqual(rjson(f"{self.dst}/Preferences")["spellcheck"]["dictionaries"], ["en-US", "fr"])
        self.assertEqual(rfile(f"{self.dst}/Claude Extensions/ext.one/server/index.js"), "main()")
        self.assertIn("ext.one", rjson(f"{self.dst}/extensions-installations.json")["extensions"])
        self.assertEqual(rjson(f"{self.dst}/Claude Extensions Settings/ext.one.json"), {"isEnabled": True})

    def test_account_device_runtime_never_copied(self):
        keep = ["Cookies", "ant-did", "window-state.json"]
        before = self.snapshot_files(keep)
        self.apply()
        self.assertEqual(self.snapshot_files(keep), before)
        cfg = rjson(f"{self.dst}/config.json")
        self.assertEqual(cfg["lastKnownAccountUuid"], DEV_ACCT)
        self.assertEqual(cfg["oauth:tokenCacheV2"], "DEV-SECRET")
        self.assertEqual(cfg["updaterLastSeenVersion"], "1.0.0")
        self.assertEqual(cfg["first_launch_at"], 99)
        self.assertEqual(rjson(f"{self.dst}/Preferences")["electron"]["media"]["device_id_salt"], "PROBESALT")
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        self.assertIs(prefs["storeReadCacheLatched"], False)            # install latch stays
        pane = prefs["epitaxyPrefs"]["desktop-frame.paneStore.v1"]["state"]
        self.assertEqual(pane["lastPrimaryCodeSession"], {"id": "local_probe"})  # per-window pointer stays
        self.assertEqual(pane["rowSplit"], 0.5)                                  # the rest of the pane store is copied

    def test_own_account_entries_are_kept(self):
        wjson(f"{self.dst}/mcp-user-tool-toggles.json", {"v": 3, "owners": {DEV_ACCT: ["dstdev"]}})
        self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        self.assertIs(prefs["bypassPermissionsOptInByAccount"][DEV_ACCT], False)  # target's own account entry
        self.assertIs(prefs["bypassPermissionsOptInByAccount"][MAIN_ACCT], True)
        toggles = rjson(f"{self.dst}/mcp-user-tool-toggles.json")
        self.assertEqual(toggles["owners"][MAIN_ACCT], ["a"])
        self.assertEqual(toggles["owners"][DEV_ACCT], ["dstdev"])                 # target's own account entry kept
        self.assertNotIn("srcdev", json.dumps(toggles))

    def test_zoom_goes_under_target_key(self):
        self.apply()
        zoom = rjson(f"{self.dst}/Preferences")["partition"]["per_host_zoom_levels"]
        self.assertEqual(zoom["2222"]["claude.ai"], -1.5)
        self.assertEqual(zoom["2222"]["about:blank"], -1.5)
        self.assertEqual(zoom["2222"]["keep.example"], 1.0)      # target-only host kept
        self.assertEqual(zoom["1111"], {"claude.ai": -9.0})       # stale key not touched
        self.assertEqual(set(zoom), {"1111", "2222"})             # no new key invented

    def test_zoom_without_own_key_is_reported_not_guessed(self):
        wjson(f"{self.dst}/Preferences", {"partition": {"per_host_zoom_levels": {"1111": {"claude.ai": -9.0}}}})
        code, out = run(["--from", self.src, "--to", self.dst, "--apply"])
        self.assertEqual(code, 0)
        self.assertIn("partition.per_host_zoom_levels", out.split("NOT copyable")[1])
        self.assertEqual(rjson(f"{self.dst}/Preferences")["partition"]["per_host_zoom_levels"], {"1111": {"claude.ai": -9.0}})
        code, out = run(["--from", self.src, "--to", self.dst, "--apply", "--zoom-key", "3333"])
        self.assertEqual(rjson(f"{self.dst}/Preferences")["partition"]["per_host_zoom_levels"]["3333"]["claude.ai"], -1.5)

    def test_source_is_never_written(self):
        before = tree_hash(self.src)
        self.apply()
        self.assertEqual(tree_hash(self.src), before)

    def test_backup_written_with_old_content(self):
        old_cfg = rfile(f"{self.dst}/config.json", "rb")
        old_prefs = rfile(f"{self.dst}/claude_desktop_config.json", "rb")
        write(f"{self.dst}/Claude Extensions/ext.one/manifest.json", "{\"name\":\"OLD\"}")
        out = self.apply()
        root = os.path.join(self.dst, sws.BACKUP_DIR)
        stamps = os.listdir(root)
        self.assertEqual(len(stamps), 1)
        b = os.path.join(root, stamps[0])
        self.assertEqual(rfile(f"{b}/config.json", "rb"), old_cfg)
        self.assertEqual(rfile(f"{b}/claude_desktop_config.json", "rb"), old_prefs)
        self.assertEqual(rfile(f"{b}/Claude Extensions/ext.one/manifest.json"), "{\"name\":\"OLD\"}")
        manifest = rjson(f"{b}/manifest.json")
        self.assertIn("config.json", manifest["replaced"])
        self.assertIn("extensions-installations.json", manifest["created"])
        self.assertIn("backup:", out)

    def test_written_files_are_0600_and_no_temp_left(self):
        self.apply()
        for rel in ("config.json", "claude_desktop_config.json", "Preferences", "extensions-installations.json"):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.dst, rel)).st_mode), 0o600, rel)
        leftovers = [n for n in os.listdir(self.dst) if n.startswith(".sync-tmp-")]
        self.assertEqual(leftovers, [])

    def test_indent_style_preserved(self):
        self.apply()
        self.assertTrue(rfile(f"{self.dst}/config.json").startswith("{\n \"")) # indent=1 like the original

    def test_second_apply_is_a_no_op(self):
        self.apply()
        before = tree_hash(self.dst)
        code, out = run(["--from", self.src, "--to", self.dst, "--apply"])
        self.assertEqual(code, 0)
        self.assertEqual(tree_hash(self.dst), before)  # no new backup dir either
        self.assertIn("none", out.split("SETTINGS seen")[0])


class Guard(Base):
    def test_refuses_while_target_running(self):
        sws.list_processes = lambda: [
            f"/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir={self.dst}"]
        before = tree_hash(self.dst)
        code, out = run(["--from", self.src, "--to", self.dst, "--apply"])
        self.assertEqual(code, 3)
        self.assertIn("refusing to apply", out)
        self.assertEqual(tree_hash(self.dst), before)
        self.assertFalse(os.path.exists(os.path.join(self.dst, sws.BACKUP_DIR)))

    def test_helper_process_also_blocks(self):
        sws.list_processes = lambda: [
            f"/Applications/Claude.app/.../Claude Helper --type=gpu-process --user-data-dir={self.dst} --gpu-preferences=x"]
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--apply"])[0], 3)

    def test_other_window_or_prefix_path_does_not_block(self):
        sws.list_processes = lambda: [
            f"/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir={self.src}",
            f"/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir={self.dst}0"]
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--apply"])[0], 0)

    def test_dry_run_and_check_allowed_while_running(self):
        sws.list_processes = lambda: [f"/x/MacOS/Claude --user-data-dir={self.dst}"]
        self.assertEqual(run(["--from", self.src, "--to", self.dst])[0], 0)
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--check"])[0], 1)

    def test_process_listing_failure_fails_closed(self):
        def boom():
            raise subprocess.CalledProcessError(1, "ps")
        sws.list_processes = boom
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--apply"])[0], 3)

    def test_real_process_table(self):
        # the guard must work against the real `ps`, not only the fake
        sws.list_processes = REAL_LIST_PROCESSES
        p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", f"--user-data-dir={self.dst}"])
        self.addCleanup(lambda: (p.kill(), p.wait()))
        time.sleep(0.5)
        code, out = run(["--from", self.src, "--to", self.dst, "--apply"])
        self.assertEqual(code, 3, out)

    def test_same_folder_refused(self):
        self.assertEqual(run(["--from", self.src, "--to", self.src, "--apply"])[0], 2)


class Check(Base):
    def test_check_fails_then_passes_after_apply(self):
        code, out = run(["--from", self.src, "--to", self.dst, "--check"])
        self.assertEqual(code, 1)
        self.assertIn("settings differ", out)
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--apply"])[0], 0)
        code, out = run(["--from", self.src, "--to", self.dst, "--check"])
        self.assertEqual(code, 0, out)
        self.assertIn("settings identical", out)

    def test_check_does_not_write(self):
        before = tree_hash(self.dst)
        run(["--from", self.src, "--to", self.dst, "--check"])
        self.assertEqual(tree_hash(self.dst), before)


class LocalStorage(Base):
    def make_ls(self, root, kv):
        leveldb_log(f"{root}/Local Storage/leveldb/000003.log", ls_pairs(kv))

    def test_setting_key_difference_is_reported_but_not_copyable(self):
        self.make_ls(self.src, {"epitaxy-editor-prefs": "{\"a\":1}", "dframe-store": "{\"state\":{}}"})
        self.make_ls(self.dst, {"epitaxy-editor-prefs": "{\"a\":2}", "dframe-store": "{\"state\":{}}"})
        run(["--from", self.src, "--to", self.dst, "--apply"])
        code, out = run(["--from", self.src, "--to", self.dst, "--check"])
        self.assertIn("epitaxy-editor-prefs", out.split("NOT copyable")[1])
        self.assertNotIn("dframe-store", out.split("NOT copyable")[1].split("Background")[0])
        self.assertEqual(code, 0)  # a key the script cannot write does not fail plain --check
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--check", "--strict"])[0], 1)

    def test_volatile_fields_and_account_keys_do_not_count(self):
        self.make_ls(self.src, {"LSS-persisted.starred-local-routines": "{\"timestamp\":1,\"v\":[]}", "ccd-sync-owner": "a",
                                "dframe-store": "{\"state\":{\"lastSidebarScopeKey\":\"x\"}}"})
        self.make_ls(self.dst, {"LSS-persisted.starred-local-routines": "{\"timestamp\":2,\"v\":[]}", "ccd-sync-owner": "b",
                                "dframe-store": "{\"state\":{\"lastSidebarScopeKey\":\"y\"}}"})
        run(["--from", self.src, "--to", self.dst, "--apply"])
        _, out = run(["--from", self.src, "--to", self.dst, "--check", "--strict"])
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--check", "--strict"])[0], 0, out)

    def test_local_storage_is_never_modified(self):
        self.make_ls(self.src, {"epitaxy-editor-prefs": "{\"a\":1}"})
        self.make_ls(self.dst, {"epitaxy-editor-prefs": "{\"a\":2}"})
        before = tree_hash(f"{self.dst}/Local Storage")
        run(["--from", self.src, "--to", self.dst, "--apply"])
        self.assertEqual(tree_hash(f"{self.dst}/Local Storage"), before)


ORG = "0f0f0f0f-1111-2222-3333-444444444444"
CARD_PRS = [
    {"prNumber": 7, "url": "https://github.com/o/r/pull/7", "repo": "o/r", "branch": "b1", "state": "OPEN", "autoFix": True},
    {"prNumber": 8, "url": "https://github.com/o/r/pull/8", "repo": "o/r", "branch": "b2", "state": "OPEN", "autoFix": False},
    {"prNumber": 9, "url": "https://github.com/o/r/pull/9", "repo": "o/r", "branch": "b3", "state": "OPEN", "dismissed": True},
]
ENGINE_KEYS = ["ccdScheduledTasksEnabled", "coworkScheduledTasksEnabled", "ccRemoteControlDefaultEnabled",
               "keepAwakeEnabled", "ccAutoArchiveOnPrClose"]
# The auto-archive sweeper's idle limit in days: the same sweeper, so 0 (never) in an extra window.
DAYS_KEY = "ccAutoArchiveInactiveDays"
# Keep-awake options only hold the Mac awake while a session in that window works: copied, not switched off.
KEEP_AWAKE_KEYS = {"ccKeepAwakeWhileWorking": True, "ccKeepAwakeOnBattery": False}


class ExtraWindow(Base):
    """--extra-window: background jobs are switched off in the target only."""

    def make_src(self):
        super().make_src()
        cfg = rjson(f"{self.src}/claude_desktop_config.json")
        for k in ENGINE_KEYS:
            cfg["preferences"][k] = True
        cfg["preferences"][DAYS_KEY] = 14
        cfg["preferences"].update(KEEP_AWAKE_KEYS)
        cfg["preferences"]["remoteToolsDeviceName"] = "Test Mac"
        wjson(f"{self.src}/claude_desktop_config.json", cfg)
        # a card store in the main folder that must never be read or written
        self.main_card = f"{self.src}/claude-code-sessions/{MAIN_ACCT}/{ORG}/local_main.json"
        wjson(self.main_card, {"sessionId": "local_main", "prs": copy_prs()})

    def make_dst(self):
        super().make_dst()
        self.store = f"{self.dst}/claude-code-sessions/{DEV_ACCT}/{ORG}"
        self.card = f"{self.store}/local_a.json"
        wjson(self.card, {
            "sessionId": "local_a", "title": "keep me", "cwd": "/x", "isStarred": True,
            "autoFixEnabled": True, "autoFixOwnPrs": True, "autoFixNextOwnPr": "b4",
            "autoFixNextOwnPrClick": {"unread": True}, "autoFixDelivered": {"7": 1}, "autoFixNoticeSent": True,
            "autoArchiveOnPrClose": True, "prs": copy_prs()})
        os.utime(self.card, ns=(1_700_000_000_123_456_789, 1_700_000_000_123_456_789))
        self.card_mtime = os.stat(self.card).st_mtime_ns
        self.plain = f"{self.store}/local_b.json"
        write(self.plain, json.dumps({"sessionId": "local_b", "title": "no prs"}, separators=(",", ":")))
        self.broken = f"{self.store}/local_broken.json"
        write(self.broken, "{ this is not json")
        self.other = f"{self.store}/archived-sessions.idx"
        write(self.other, "autoFix")

    EXTRA = ["--extra-window"]

    def apply(self, *more):
        code, out = run(["--from", self.src, "--to", self.dst, "--apply", "--extra-window", *more])
        self.assertEqual(code, 0, out)
        return out

    def test_each_background_job_is_off_in_the_target(self):
        self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        for k in ENGINE_KEYS:
            with self.subTest(k):
                self.assertIs(prefs[k], False)

    def test_auto_archive_after_inactivity_is_zero_in_the_target_only(self):
        self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        self.assertEqual(prefs[DAYS_KEY], 0)
        self.assertNotIsInstance(prefs[DAYS_KEY], bool)
        self.assertEqual(rjson(f"{self.src}/claude_desktop_config.json")["preferences"][DAYS_KEY], 14)

    def test_keep_awake_options_are_copied_not_switched_off(self):
        self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        for k, v in KEEP_AWAKE_KEYS.items():
            with self.subTest(k):
                self.assertIs(prefs[k], v)

    def test_jobs_are_switched_off_even_when_main_does_not_list_them(self):
        cfg = rjson(f"{self.src}/claude_desktop_config.json")
        for k in ENGINE_KEYS:
            cfg["preferences"].pop(k)
        wjson(f"{self.src}/claude_desktop_config.json", cfg)
        self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        for k in ENGINE_KEYS:
            with self.subTest(k):
                self.assertIs(prefs[k], False)

    def test_other_settings_still_match_main(self):
        self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        self.assertEqual(prefs["sidebarMode"], "task")
        self.assertNotIn("targetOnlyPref", prefs)
        self.assertEqual(rjson(f"{self.dst}/config.json")["userThemeMode"], "dark")

    def test_device_name_is_main_name_plus_window(self):
        out = self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        self.assertEqual(prefs["remoteToolsDeviceName"], "Test Mac (window)")
        self.assertNotIn("Test Mac", out)  # values are never printed

    def test_device_name_falls_back_to_the_computer_name_when_main_has_none(self):
        cfg = rjson(f"{self.src}/claude_desktop_config.json")
        cfg["preferences"].pop("remoteToolsDeviceName")
        wjson(f"{self.src}/claude_desktop_config.json", cfg)
        real = sws.default_device_name
        sws.default_device_name = lambda: "Studio"
        self.addCleanup(setattr, sws, "default_device_name", real)
        self.apply()
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        self.assertEqual(prefs["remoteToolsDeviceName"], "Studio (window)")

    def test_auto_fix_is_off_on_every_pr_of_every_card(self):
        self.apply()
        card = rjson(self.card)
        self.assertEqual([pr.get("autoFix") for pr in card["prs"]], [False, False, None])
        self.assertNotIn("autoFix", card["prs"][2])  # an absent flag is not invented
        self.assertEqual(card["prs"][0]["url"], "https://github.com/o/r/pull/7")
        self.assertIs(card["prs"][2]["dismissed"], True)

    def test_session_level_auto_fix_triggers_are_off(self):
        self.apply()
        card = rjson(self.card)
        self.assertIs(card["autoFixEnabled"], False)
        self.assertIs(card["autoFixOwnPrs"], False)
        self.assertNotIn("autoFixNextOwnPr", card)
        self.assertNotIn("autoFixNextOwnPrClick", card)
        self.assertIs(card["autoArchiveOnPrClose"], False)

    def test_everything_else_in_a_card_is_untouched(self):
        self.apply()
        card = rjson(self.card)
        self.assertEqual((card["sessionId"], card["title"], card["cwd"], card["isStarred"]),
                         ("local_a", "keep me", "/x", True))
        self.assertEqual(card["autoFixDelivered"], {"7": 1})   # history, not a trigger
        self.assertIs(card["autoFixNoticeSent"], True)

    def test_card_mtime_is_kept_so_chat_sync_does_not_treat_the_edit_as_newer(self):
        self.apply()
        self.assertEqual(os.stat(self.card).st_mtime_ns, self.card_mtime)

    def test_cards_without_auto_fix_and_foreign_files_are_not_rewritten(self):
        plain, broken, other = rfile(self.plain, "rb"), rfile(self.broken, "rb"), rfile(self.other, "rb")
        pm = os.stat(self.plain).st_mtime_ns
        out = self.apply()
        self.assertEqual(rfile(self.plain, "rb"), plain)
        self.assertEqual(rfile(self.broken, "rb"), broken)
        self.assertEqual(rfile(self.other, "rb"), other)
        self.assertEqual(os.stat(self.plain).st_mtime_ns, pm)
        self.assertIn("local_broken.json", out)  # reported, not fatal

    def test_card_format_and_mode_are_kept(self):
        before = rfile(self.card)
        self.apply()
        after = rfile(self.card)
        self.assertTrue(after.startswith("{\n  "))
        self.assertTrue(after.endswith("\n") == before.endswith("\n"))
        self.assertEqual(stat.S_IMODE(os.stat(self.card).st_mode), 0o600)

    def test_old_card_is_backed_up(self):
        old = rfile(self.card, "rb")
        self.apply()
        backups = os.listdir(f"{self.dst}/{sws.BACKUP_DIR}")
        self.assertEqual(len(backups), 1)
        self.assertEqual(rfile(f"{self.dst}/{sws.BACKUP_DIR}/{backups[0]}/claude-code-sessions/{DEV_ACCT}/{ORG}/local_a.json", "rb"), old)

    def test_second_apply_is_a_no_op(self):
        self.apply()
        snap = tree_hash(self.dst)
        out = self.apply()
        self.assertEqual(tree_hash(self.dst), snap)
        self.assertEqual(len(os.listdir(f"{self.dst}/{sws.BACKUP_DIR}")), 1)
        self.assertIn("0 item(s) to write", out)

    def test_main_folder_is_never_written_or_its_cards_read(self):
        before = tree_hash(self.src)
        mt = os.stat(self.main_card).st_mtime_ns
        run(["--from", self.src, "--to", self.dst, "--extra-window"])
        self.apply()
        self.apply()
        self.assertEqual(tree_hash(self.src), before)
        self.assertEqual(os.stat(self.main_card).st_mtime_ns, mt)
        self.assertEqual(rjson(self.main_card)["prs"][0]["autoFix"], True)

    def test_a_card_folder_that_links_into_main_is_never_followed(self):
        os.makedirs(f"{self.dst}/claude-code-sessions/{MAIN_ACCT}")
        os.symlink(f"{self.src}/claude-code-sessions/{MAIN_ACCT}/{ORG}", f"{self.dst}/claude-code-sessions/{MAIN_ACCT}/{ORG}")
        os.symlink(self.main_card, f"{self.store}/local_link.json")
        before = tree_hash(self.src)
        self.apply()
        self.assertEqual(tree_hash(self.src), before)
        self.assertEqual(rjson(self.main_card)["prs"][0]["autoFix"], True)

    def test_refuses_to_treat_the_real_main_folder_as_an_extra_window(self):
        real = sws.default_claude_dir
        sws.default_claude_dir = lambda: self.dst
        self.addCleanup(setattr, sws, "default_claude_dir", real)
        before = tree_hash(self.dst)
        code, out = run(["--from", self.src, "--to", self.dst, "--apply", "--extra-window"])
        self.assertEqual(code, 2)
        self.assertEqual(tree_hash(self.dst), before)

    def test_dry_run_writes_nothing_and_says_jobs_go_off(self):
        before = tree_hash(self.dst)
        code, out = run(["--from", self.src, "--to", self.dst, "--extra-window"])
        self.assertEqual(code, 0)
        self.assertEqual(tree_hash(self.dst), before)
        self.assertIn("keepAwakeEnabled = off", out)
        self.assertNotIn("keepAwakeEnabled = on", out)
        self.assertIn("ccAutoArchiveInactiveDays = off", out)
        self.assertIn("preferences.ccdScheduledTasksEnabled", out)

    def test_plain_run_without_the_flag_switches_nothing_off(self):
        card = rfile(self.card, "rb")
        code, _ = run(["--from", self.src, "--to", self.dst, "--apply"])
        self.assertEqual(code, 0)
        prefs = rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]
        for k in ENGINE_KEYS:
            self.assertIs(prefs[k], True)
        self.assertEqual(prefs["remoteToolsDeviceName"], "Test Mac")
        self.assertEqual(rfile(self.card, "rb"), card)

    def test_check_treats_the_switched_off_jobs_as_expected(self):
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--check", "--extra-window"])[0], 1)
        self.apply()
        code, out = run(["--from", self.src, "--to", self.dst, "--check", "--extra-window"])
        self.assertEqual(code, 0, out)
        self.assertIn("settings identical", out)

    def test_check_without_the_flag_still_sees_those_differences(self):
        self.apply()
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--check"])[0], 1)

    def test_check_with_the_flag_fails_when_a_job_is_turned_back_on(self):
        self.apply()
        cfg = rjson(f"{self.dst}/claude_desktop_config.json")
        cfg["preferences"]["keepAwakeEnabled"] = True
        wjson(f"{self.dst}/claude_desktop_config.json", cfg)
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--check", "--extra-window"])[0], 1)

    def test_check_with_the_flag_fails_when_a_card_has_auto_fix_on_again(self):
        self.apply()
        card = rjson(self.card)
        card["prs"][0]["autoFix"] = True
        wjson(self.card, card)
        self.assertEqual(run(["--from", self.src, "--to", self.dst, "--check", "--extra-window"])[0], 1)

    def test_refuses_while_the_window_is_running(self):
        sws.list_processes = lambda: [f"/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir={self.dst}"]
        before = tree_hash(self.dst)
        code, _ = run(["--from", self.src, "--to", self.dst, "--apply", "--extra-window"])
        self.assertEqual(code, 3)
        self.assertEqual(tree_hash(self.dst), before)

    def test_a_card_saved_after_it_was_read_is_not_overwritten(self):
        rep = sws.build_report(self.src, self.dst, None, True)
        newer = {"sessionId": "local_a", "title": "saved a moment ago", "prs": copy_prs()}
        wjson(self.card, newer)
        _, manifest = sws.apply_plans(self.dst, rep.plans)
        self.assertEqual(len(manifest["skipped"]), 1)
        self.assertEqual(rjson(self.card)["title"], "saved a moment ago")
        self.assertIs(rjson(self.card)["prs"][0]["autoFix"], True)

    def test_apply_reports_a_skipped_card_with_a_non_zero_exit(self):
        real = sws.apply_plans
        def racing(dst, plans):
            wjson(self.card, {"sessionId": "local_a", "prs": copy_prs()})
            return real(dst, plans)
        sws.apply_plans = racing
        self.addCleanup(setattr, sws, "apply_plans", real)
        code, out = run(["--from", self.src, "--to", self.dst, "--apply", "--extra-window"])
        self.assertEqual(code, 4)
        self.assertIn("NOT written", out)

    def test_a_window_with_no_cards_yet_is_fine(self):
        import shutil
        shutil.rmtree(f"{self.dst}/claude-code-sessions")
        self.apply()
        self.assertIs(rjson(f"{self.dst}/claude_desktop_config.json")["preferences"]["keepAwakeEnabled"], False)


def copy_prs():
    import copy
    return copy.deepcopy(CARD_PRS)


if __name__ == "__main__":
    unittest.main()
