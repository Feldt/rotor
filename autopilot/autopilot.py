#!/usr/bin/env python3
"""Rotor autopilot: switch Claude accounts before the 5h/week limit and keep every chat going.

Runs every 2 minutes from launchd (local.rotor.autopilot). One pass:
  1. keep the "rotor-autoresume" scheduled task armed on disk (Claude reads scheduled tasks only at
     startup, so any Claude start - our switch, a manual switch, a crash - fires it within ~3 min)
  2. watchdog: queue a nudge (nudge.json) for chats that went silent after their turn ended, e.g.
     waiting on a background job or wakeup that died, or stopped on a usage limit while we have room
  3. refresh usage for every account (rotor usage --refresh --real-data)
  4. if the current account is at/over the limit, record the chats to resume in pending.json and
     rotor switch to the account with the most room (fresh saved logins first, back home as last resort)
The task, once fired, messages every chat the restart cut off (autopilot.py --targets), then stays
alive as the keeper that delivers watchdog nudges (autopilot.py --claim-nudges).

Flags: --dry-run (decide and log, change nothing), --force-switch (switch now), --to <account id>.
"""
import fcntl
import glob
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
DIR = os.path.join(HOME, ".claude", "rotor-autopilot")
LOG = os.path.join(DIR, "autopilot.log")
STATE = os.path.join(DIR, "state.json")
PENDING = os.path.join(DIR, "pending.json")
ROTOR = os.path.join(HOME, ".local", "bin", "rotor")
STORE = os.path.join(HOME, "Library", "Application Support", "ClaudeAccounts")
SESSIONS = os.path.join(HOME, "Library", "Application Support", "Claude", "claude-code-sessions")
PROJECTS = os.path.join(HOME, ".claude", "projects")
TASK_ID = "rotor-autoresume"
TASK_FILE = os.path.join(HOME, ".claude", "scheduled-tasks", TASK_ID, "SKILL.md")

FIVE_H_SWITCH = 0.99      # switch when the current account's 5h use reaches this
WEEK_SWITCH = 0.99        # ... or its weekly use reaches this
CAND_MAX_5H = 0.80        # a target must have at most this much 5h use
CAND_MAX_WEEK = 0.85      # ... and at most this much weekly use
USAGE_FRESH_S = 20 * 60   # ignore usage older than this
COOLDOWN_S = 10 * 60      # never switch twice within this
BUSY_WINDOW_S = 15 * 60   # a chat touched this recently and not at end of turn counts as working
LIMIT_WINDOW_S = 24 * 3600 # a chat that stopped on a usage limit this recently gets resumed
ACTIVE_WINDOW_S = 8 * 3600 # a switch kills every chat's background agents/workflows/wakeups: nudge all chats active this recently
STALL_S = 45 * 60          # watchdog: a chat (and its subagents/workflows) silent this long after its turn ended gets nudged
NUDGE = os.path.join(DIR, "nudge.json")
RESUME_DELAY_S = 150      # fire the resume task this long after arming (Claude relaunch + load)

DRY = "--dry-run" in sys.argv
FORCE = "--force-switch" in sys.argv
TO = sys.argv[sys.argv.index("--to") + 1] if "--to" in sys.argv else None


def log(msg):
    line = f"{datetime.now().astimezone().isoformat(timespec='seconds')} {'[dry] ' if DRY else ''}{msg}"
    print(line)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def run(args, timeout):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def current_account():
    out = run([ROTOR, "status"], 60).stdout
    for line in out.splitlines():
        if line.startswith("Current account:"):
            return line.split()[2]
    return None


def labels():
    return {a["id"]: a.get("label", a["id"]) for a in load(os.path.join(STORE, "accounts.json"), [])}


def usage_for(usage, acct, now):
    u = usage.get(acct) or {}
    fetched = iso(u.get("fetchedAt"))
    if not fetched or (now - fetched).total_seconds() > USAGE_FRESH_S or u.get("stale"):
        return None
    uu = u.get("usage") or {}
    if uu.get("needsRefresh"):
        return None
    five, week = uu.get("fiveHour") or {}, uu.get("weekly") or {}
    f, w = five.get("utilization"), week.get("utilization")
    # a window whose reset time has passed is back at zero even if the cache says otherwise
    if five.get("resetsAt") and iso(five["resetsAt"]) <= now:
        f = 0.0
    if week.get("resetsAt") and iso(week["resetsAt"]) <= now:
        w = 0.0
    if f is None or w is None:
        return None
    return f, w


def transcript_state(cli_id, now_ts):
    """'limit' (stopped on a usage limit), 'busy' (mid-turn), or None (idle / unknown)."""
    paths = glob.glob(os.path.join(PROJECTS, "*", f"{cli_id}.jsonl"))
    if not paths:
        return None
    p = max(paths, key=os.path.getmtime)
    age = now_ts - os.path.getmtime(p)
    if age > LIMIT_WINDOW_S:
        return None
    with open(p, "rb") as f:
        f.seek(0, 2)
        f.seek(max(0, f.tell() - 400_000))
        lines = f.read().decode("utf-8", "replace").splitlines()
    last = None
    for l in reversed(lines):
        try:
            d = json.loads(l)
        except Exception:
            continue
        if d.get("type") in ("assistant", "user") and not d.get("isSidechain"):
            last = d
            break
    if last is None:
        return None
    if last.get("type") == "assistant" and last.get("error") == "rate_limit":
        return "limit"
    if age > BUSY_WINDOW_S:
        return "active" if age <= ACTIVE_WINDOW_S else None
    m = last.get("message") or {}
    if last.get("type") == "assistant":
        content = m.get("content") or []
        has_tool = any(isinstance(c, dict) and c.get("type") == "tool_use" for c in content)
        if m.get("stop_reason") == "end_turn" and not has_tool:
            return "active"
        if last.get("isApiErrorMessage"):
            return "busy"  # other API error mid-turn
        return "busy"
    return "busy"  # last record is a user prompt or tool result: a turn is in flight


def account_session_files(acct):
    files = {}
    for path in glob.glob(os.path.join(SESSIONS, acct, "*", "local_*.json")):
        sid = os.path.basename(path)[:-5]
        if sid not in files or os.path.getmtime(path) > os.path.getmtime(files[sid]):
            files[sid] = path
    return files


def sessions_to_resume(acct):
    now_ts = time.time()
    out = []
    for sid, path in account_session_files(acct).items():
        d = load(path, {})
        if d.get("isArchived") or d.get("scheduledTaskId") or not d.get("cliSessionId"):
            continue
        st = transcript_state(d["cliSessionId"], now_ts)
        if st == "active" and said_idle(d["cliSessionId"]):
            continue
        if st:
            out.append({"sessionId": sid, "title": d.get("title", ""), "why": st, "done": False,
                        "message": SWITCH_MSG})
    return out


def tail_records(path, nbytes=600_000):
    with open(path, "rb") as f:
        f.seek(0, 2)
        f.seek(max(0, f.tell() - nbytes))
        lines = f.read().decode("utf-8", "replace").splitlines()
    out = []
    for l in lines:
        try:
            d = json.loads(l)
        except Exception:
            continue
        if d.get("type") in ("assistant", "user") and not d.get("isSidechain"):
            out.append(d)
    return out


def last_text(rec):
    c = (rec.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    return " ".join(b.get("text", "") for b in c or [] if isinstance(b, dict) and b.get("type") == "text")


def said_idle(cli_id):
    paths = glob.glob(os.path.join(PROJECTS, "*", f"{cli_id}.jsonl"))
    if not paths:
        return False
    recs = tail_records(max(paths, key=os.path.getmtime), 200_000)
    return bool(recs) and recs[-1].get("type") == "assistant" and last_text(recs[-1]).strip().strip(".*").upper() == "IDLE"


def claude_started_at():
    r = run(["/bin/sh", "-c", "ps -axo lstart=,comm= | grep '/Claude.app/Contents/MacOS/Claude$' | head -1 | cut -c1-24"], 20)
    try:
        return datetime.strptime(r.stdout.strip(), "%a %b %d %H:%M:%S %Y").timestamp()
    except ValueError:
        return 0


def cmd_targets():
    """Run by the resume task right after Claude starts: every chat the restart may have cut off."""
    cur = current_account()
    pend = load(PENDING, {}) or {}
    started = claude_started_at()
    fresh_start = time.time() - started < 15 * 60
    out = [s for s in pend.get("sessions", []) if not s.get("done")] if not pend.get("reported") else []
    if fresh_start and cur:
        seen = {s["sessionId"] for s in out}
        out += [s for s in sessions_to_resume(cur) if s["sessionId"] not in seen]
    if out or not pend.get("reported"):
        save(PENDING, {"switchId": pend.get("switchId") if not pend.get("reported") else
                       "start-" + datetime.now().strftime("%Y%m%d-%H%M%S"),
                       "from": pend.get("from"), "to": cur, "armedAt": time.time(), "sessions": out})
    log(f"resume task: Claude started {int((time.time() - started) / 60)} min ago; {len(out)} chats to message")
    print(f"{len(out)} chats queued in {PENDING}")


def cmd_claim_nudges():
    """Keeper chat polls this; exit 0 (printing the claimed file) when watchdog nudges are waiting."""
    try:
        os.rename(NUDGE, NUDGE + ".claimed")
    except OSError:
        sys.exit(1)
    print(NUDGE + ".claimed")


def newest_mtime(cli_id):
    """Newest write to the chat's transcript or anything its subagents/workflows write."""
    best = 0
    for p in glob.glob(os.path.join(PROJECTS, "*", f"{cli_id}.jsonl")):
        best = max(best, os.path.getmtime(p))
    for d in glob.glob(os.path.join(PROJECTS, "*", cli_id)):
        for root, _, fs in os.walk(d):
            for f in fs:
                try:
                    best = max(best, os.path.getmtime(os.path.join(root, f)))
                except OSError:
                    pass
    return best


def stalled_sessions(acct, can_work, state, skip):
    """Chats that went quiet after their turn ended (waiting on a job that died, a wakeup that
    never fired) or after a usage limit while we now have room. Each quiet stretch is nudged once;
    a chat that answers IDLE is left alone until something else writes to it."""
    now_ts = time.time()
    nudged = state.setdefault("nudged", {})
    out = []
    for sid, path in account_session_files(acct).items():
        d = load(path, {})
        cid = d.get("cliSessionId")
        if d.get("isArchived") or d.get("scheduledTaskId") or not cid or sid in skip:
            continue
        paths = glob.glob(os.path.join(PROJECTS, "*", f"{cid}.jsonl"))
        if not paths:
            continue
        tp = max(paths, key=os.path.getmtime)
        tm = os.path.getmtime(tp)
        if not (STALL_S <= now_ts - tm <= ACTIVE_WINDOW_S) or nudged.get(sid) == tm:
            continue
        recs = tail_records(tp)
        if not recs:
            continue
        last = recs[-1]
        if last.get("type") != "assistant":
            continue  # a turn is in flight (tool running / queued prompt): not ours to poke
        if last.get("error") == "rate_limit":
            if not can_work:
                continue
            why = "limit"
        else:
            m = last.get("message") or {}
            if m.get("stop_reason") != "end_turn" or any(
                    isinstance(c, dict) and c.get("type") == "tool_use" for c in m.get("content") or []):
                continue
            if last_text(last).strip().strip(".*").upper() == "IDLE":
                continue
            # A pending ScheduleWakeup is a legit wait until it is overdue.
            wake = None
            for r in recs:
                for c in (r.get("message") or {}).get("content") or []:
                    if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "ScheduleWakeup":
                        t = iso(r.get("timestamp"))
                        if t:
                            wake = t.timestamp() + float((c.get("input") or {}).get("delaySeconds") or 0)
            if wake and now_ts < wake + 10 * 60:
                continue
            if now_ts - newest_mtime(cid) < STALL_S:
                continue  # subagents/workflows are still writing
            why = "stalled"
        out.append({"sessionId": sid, "title": d.get("title", ""), "why": why, "done": False,
                    "message": NUDGE_MSG, "_tm": tm})
    return out


SWITCH_MSG = ("Rotor autopilot switched Claude to a fresh account (the old one hit its usage limit) and the app "
              "restarted, which interrupted you and killed any workflow, subagent, Monitor, background job or "
              "pending wakeup you had running. Check what you had in flight and resume or restart it, then "
              "continue exactly where you left off. If you are already working, ignore this and keep going. "
              "If your work was already finished or only waits on the user, reply with just the word IDLE and stop. "
              "Don't ask the user anything; they may be away.")
NUDGE_MSG = ("Rotor watchdog: this chat and its background work have been silent for over 45 minutes. If you "
             "were waiting on a workflow, subagent, Monitor, background job or wakeup that should have reported "
             "by now, it probably died (an account switch restarts the app and kills them, and wakeups can be "
             "lost): check it, resume or restart it, and keep working. If you stopped on a usage limit, continue "
             "now. If your work is truly finished or only waits on the user, reply with just the word IDLE and stop. "
             "Don't ask the user anything; they may be away.")


def arm_resume_task(target):
    """Upsert the resume task into every org dir of the target account, firing shortly."""
    fire_ms = int((time.time() + RESUME_DELAY_S) * 1000)
    # Every account: the app may land on another account than asked (a stale saved login) and
    # picks the org dir itself. A stray armed copy just finds nothing pending and stops.
    dirs = [d for d in glob.glob(os.path.join(SESSIONS, "*", "*")) if os.path.isdir(d)]
    if not dirs:
        log(f"warn: target {target} has no session dir yet; resume task not armed")
    for d in dirs:
        path = os.path.join(d, "scheduled-tasks.json")
        data = load(path, {"scheduledTasks": [], "recordedSkips": {}})
        tasks = [t for t in data.get("scheduledTasks", []) if t.get("id") != TASK_ID]
        tasks.append({
            "id": TASK_ID,
            "displayName": "Resume chats after account switch",
            "fireAt": fire_ms,
            "enabled": True,
            "filePath": TASK_FILE,
            "createdAt": int(time.time() * 1000),
            "cwd": HOME,
            "permissionMode": "bypassPermissions",
            "permissionModeCarried": True,
        })
        data["scheduledTasks"] = tasks
        if not DRY:
            save(path, data)
    return fire_ms


def main():
    os.makedirs(DIR, exist_ok=True)
    lock = open(os.path.join(DIR, ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | (0 if FORCE else fcntl.LOCK_NB))
    except OSError:
        return
    state = load(STATE, {})
    now = datetime.now(timezone.utc)

    # Report how the last resume went.
    pend = load(PENDING, None)
    if pend and not pend.get("reported"):
        left = [s for s in pend.get("sessions", []) if not s.get("done")]
        age = time.time() - pend.get("armedAt", 0)
        if not left:
            log(f"resume {pend.get('switchId')}: all {len(pend['sessions'])} chats resumed")
            pend["reported"] = True
            save(PENDING, pend)
        elif age > 10 * 60:
            # Claude's own relaunch auto-resume restarts chats that were mid-turn; the task covers
            # chats stopped on a limit. Anything unconfirmed rides along with the next switch.
            log(f"resume {pend.get('switchId')}: {len(left)} chats not confirmed after {int(age/60)} min "
                "(carried to the next switch): " + ", ".join(s["title"][:40] for s in left))
            pend["reported"] = True
            save(PENDING, pend)
            state["carry"] = left
            save(STATE, state)

    # Claude loads scheduled tasks only at startup; keeping the one-shot armed a little ahead means
    # every start (our switch, a manual switch, a crash) fires it within ~3 min.
    if not DRY:
        arm_resume_task(None)

    r = run([ROTOR, "usage", "--refresh", "--real-data"], 180)
    if r.returncode != 0:
        log(f"usage refresh failed rc={r.returncode}: {(r.stderr or r.stdout).strip()[:300]}")
    usage = load(os.path.join(STORE, "usage.json"), {})
    names = labels()
    cur = current_account()
    if not cur:
        log("no current account (Claude not signed in?)")
        return
    cu = usage_for(usage, cur, now)
    summary = " · ".join(
        f"{names.get(a, a)[:18]} {int(v[0]*100)}/{int(v[1]*100)}"
        for a in names for v in [usage_for(usage, a, now)] if v)
    can_work = cu is not None and cu[0] < FIVE_H_SWITCH and cu[1] < WEEK_SWITCH
    pend = load(PENDING, {}) or {}
    skip = set() if pend.get("reported") else {s["sessionId"] for s in pend.get("sessions", [])}
    queued = [s for f in (NUDGE, NUDGE + ".claimed") for s in (load(f, {}) or {}).get("sessions", []) if not s.get("done")]
    qage = time.time() - max([(load(f, {}) or {}).get("armedAt", 0) for f in (NUDGE, NUDGE + ".claimed")])
    if queued and qage > 15 * 60 and state.get("keeperWarnAt", 0) < time.time() - 3600:
        log(f"watchdog: {len(queued)} nudges undelivered for {int(qage/60)} min (keeper chat not running?)")
        state["keeperWarnAt"] = time.time()
        save(STATE, state)
    if not queued:
        stalled = stalled_sessions(cur, can_work, state, skip)
        if stalled:
            log(f"watchdog: nudging {len(stalled)} quiet chats: " +
                ", ".join(f"{s['title'][:30]}[{s['why']}]" for s in stalled))
            if not DRY:
                for s in stalled:
                    state["nudged"][s["sessionId"]] = s.pop("_tm")
                save(NUDGE, {"armedAt": time.time(), "sessions": stalled})
                save(STATE, state)
    if cu is None:
        log(f"current {names.get(cur, cur)}: no fresh usage; waiting. [{summary}]")
        return
    fallback = state.get("fallback", False)
    need = FORCE or fallback or cu[0] >= FIVE_H_SWITCH or cu[1] >= WEEK_SWITCH
    if not need:
        if state.get("lastSummaryAt", 0) < time.time() - 30 * 60:
            log(f"ok: {names.get(cur, cur)} at 5h {int(cu[0]*100)}% week {int(cu[1]*100)}%. [{summary}]")
            state["lastSummaryAt"] = time.time()
            save(STATE, state)
        return

    since = time.time() - state.get("lastSwitchAt", 0)
    if since < COOLDOWN_S and not FORCE:
        log(f"limit hit but last switch was {int(since)} s ago; waiting out the cooldown")
        return

    bad = {a: t for a, t in state.get("bad", {}).items() if t > time.time()}
    cands = []
    for a in names:
        if a == cur or a in bad or (TO and a != TO):
            continue
        v = usage_for(usage, a, now)
        if v and (TO or (v[0] <= CAND_MAX_5H and v[1] <= CAND_MAX_WEEK)):
            cands.append((v[0] + v[1] * 0.5, a, v))
    if not cands:
        if state.get("lastNoCandAt", 0) < time.time() - 30 * 60:
            log(f"{names.get(cur, cur)} at 5h {int(cu[0]*100)}% week {int(cu[1]*100)}% but no account has room. [{summary}]")
            state["lastNoCandAt"] = time.time()
            save(STATE, state)
        return
    # Logins Rotor saved long ago can be refused ("for your safety, log in again"); try fresh ones first.
    saved = {a["id"]: iso((a.get("desktop") or {}).get("savedAt")) for a in load(os.path.join(STORE, "accounts.json"), [])}
    def old_slot(a):
        t = saved.get(a)
        return 0 if t and (now - t).total_seconds() < 36 * 3600 else 1
    cands.sort(key=lambda c: (old_slot(c[1]), c[0]))
    chain = [c[1] for c in cands][:3] + [cur]  # last resort: back where we started, never a sign-in screen

    resume = sessions_to_resume(cur)
    seen = {s["sessionId"] for s in resume}
    for s0 in state.get("carry", []):
        if s0["sessionId"] not in seen:
            resume.append(dict(s0, done=False))
    switch_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    tv = usage_for(usage, chain[0], now)
    log(f"SWITCH {switch_id}: {names.get(cur, cur)} (5h {int(cu[0]*100)}% week {int(cu[1]*100)}%) -> "
        f"{names.get(chain[0], chain[0])} (5h {int(tv[0]*100)}% week {int(tv[1]*100)}%); "
        f"{len(resume)} chats to resume: " + ", ".join(f"{s['title'][:30]}[{s['why']}]" for s in resume))
    if DRY:
        log(f"would try in order: {[names.get(a, a) for a in chain]}")
        return
    save(PENDING, {"switchId": switch_id, "from": cur, "to": chain[0], "armedAt": time.time(),
                   "sessions": resume})
    state["lastSwitchAt"] = time.time()
    state["carry"] = []
    save(STATE, state)

    on = cur
    for target in chain:
        if target == on:
            break  # already here (the last-resort step when we never left)
        fire = arm_resume_task(target)
        res = switch_once(target)
        if res == "failed":
            pend = load(PENDING, {})
            pend["reported"] = True
            pend["switchFailed"] = True
            save(PENDING, pend)
            state["carry"] = resume
            state["lastSwitchAt"] = time.time() - COOLDOWN_S + 120  # retry in ~2 min
            save(STATE, state)
            return
        on = target
        if res == "stale":
            log(f"{names.get(target, target)}: saved login refused (session_stale_relogin); "
                "marking it bad for 24 h and moving on. Sign in to it again in Rotor when convenient.")
            state.setdefault("bad", {})[target] = time.time() + 24 * 3600
            save(STATE, state)
            continue
        pend = load(PENDING, {})
        pend["to"] = target
        pend["armedAt"] = time.time()
        save(PENDING, pend)
        log(f"on {names.get(target, target)}; resume task fires at "
            f"{datetime.fromtimestamp(fire/1000).astimezone().isoformat(timespec='seconds')}")
        return
    log("every candidate login was refused; staying put")


MAIN_LOG = os.path.join(HOME, "Library", "Logs", "Claude", "main.log")


def switch_once(target):
    """'ok', 'stale' (Claude reopened but the saved login was refused) or 'failed' (no switch)."""
    try:
        mark = os.path.getsize(MAIN_LOG)
    except OSError:
        mark = 0
    # Claude asks "still working, quit anyway?" while chats run; RotorQuitHelper clicks "Quit anyway".
    subprocess.run(["/usr/bin/open", "-g", "-n", os.path.join(HOME, "Applications", "RotorQuitHelper.app")])
    r = run([ROTOR, "switch", target, "--real-data"], 300)
    log(f"rotor switch -> {target} rc={r.returncode}: {(r.stdout + r.stderr).strip()[-200:]}")
    if r.returncode != 0:
        return "failed"
    deadline = time.time() + 90
    while time.time() < deadline:
        time.sleep(5)
        try:
            size = os.path.getsize(MAIN_LOG)
            with open(MAIN_LOG, "rb") as f:
                f.seek(mark if size >= mark else 0)
                text = f.read().decode("utf-8", "replace")
        except OSError:
            continue
        if "session_stale_relogin" in text:
            return "stale"
        if "Relaunch auto-resume: ran" in text:
            time.sleep(10)  # auth errors land within seconds of this; look once more
            with open(MAIN_LOG, "rb") as f:
                f.seek(mark if os.path.getsize(MAIN_LOG) >= mark else 0)
                if b"session_stale_relogin" in f.read():
                    return "stale"
            return "ok"
    return "ok"


if __name__ == "__main__":
    if "--targets" in sys.argv:
        cmd_targets()
        sys.exit(0)
    if "--claim-nudges" in sys.argv:
        cmd_claim_nudges()
        sys.exit(0)
    try:
        main()
    except Exception as e:
        log(f"error: {type(e).__name__}: {e}")
        raise
