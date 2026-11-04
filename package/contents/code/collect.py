#!/usr/bin/env python3
"""Summarise Claude Code usage from local transcripts as JSON for the Plasma widget.

Reads ~/.claude/projects/**/*.jsonl (main sessions and subagents). Token counts come
from each assistant message's `usage`. Cost is estimated per model from Claude Code's
own `cost-state` snapshots: their cost divided by their token weight gives a $/token
rate, applied to every message, so no prices are hard-coded and the estimate stays
current between snapshots. Parsed files are cached by mtime/size in ~/.cache.

Remote machines: `--remote NAME:PATH` (repeatable) runs this same script on the SSH host
NAME against its Claude config dir PATH, in `--rows` mode, which returns only compact
per-request token counts (never transcript text). The last good result per host is
cached, so an unreachable host shows as stale instead of vanishing.
"""
import argparse
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

CLAUDE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser()
PROJECTS = CLAUDE_DIR / "projects"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "claude-usage-plasmoid.json"
CACHE_VERSION = 3
BLOCK = timedelta(hours=5)

# Relative price weights shared by Claude models (input = 1). Only ratios: the absolute
# rate per model is calibrated from Claude Code's own cost snapshots.
W_IN, W_CACHE_5M, W_CACHE_1H, W_CACHE_READ, W_OUT = 1.0, 1.25, 2.0, 0.1, 5.0


def parse_file(path, root):
    """Return {"msgs": [[id, ts, session, model, project, in, cw5m, cw1h, cr, out]],
    "costs": {session: {model: [usd, weight]}}} (each session's latest cost snapshot)."""
    msgs, costs, seen = [], {}, set()
    project = path.relative_to(root).parts[0]
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"usage"' not in line and '"cost-state"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            kind = o.get("type")
            if kind == "cost-state":
                sid, mu = o.get("sessionId"), o.get("modelUsage")
                if not sid or not isinstance(mu, dict):
                    continue
                snap = {}
                for model, v in mu.items():
                    usd = v.get("costUSD") or 0
                    # Snapshots don't split cache writes by TTL; Claude Code uses 1h caching.
                    w = ((v.get("inputTokens") or 0) * W_IN + (v.get("cacheCreationInputTokens") or 0) * W_CACHE_1H
                         + (v.get("cacheReadInputTokens") or 0) * W_CACHE_READ + (v.get("outputTokens") or 0) * W_OUT)
                    if usd > 0 and w > 0:
                        snap[model] = [float(usd), w]
                # Snapshots are cumulative per session; keep the latest (largest).
                if snap and sum(c for c, _ in snap.values()) >= sum(c for c, _ in costs.get(sid, {}).values()):
                    costs[sid] = snap
                continue
            if kind != "assistant":
                continue
            m = o.get("message") or {}
            u = m.get("usage") if isinstance(m, dict) else None
            ts = o.get("timestamp")
            if not u or not ts or m.get("model") == "<synthetic>":
                continue
            key = f"{m.get('id')}:{o.get('requestId')}"
            if key in seen:
                continue
            seen.add(key)
            cw = int(u.get("cache_creation_input_tokens") or 0)
            split = u.get("cache_creation") or {}
            cw1h = int(split.get("ephemeral_1h_input_tokens") or 0) if split else cw
            msgs.append([
                key, ts, o.get("sessionId") or "", m.get("model") or "unknown", project,
                int(u.get("input_tokens") or 0), max(0, cw - cw1h), cw1h,
                int(u.get("cache_read_input_tokens") or 0),
                int(u.get("output_tokens") or 0),
            ])
    return {"msgs": msgs, "costs": costs}


def load():
    try:
        cache = json.loads(CACHE.read_text())
        if cache.get("v") != CACHE_VERSION:
            raise ValueError
    except (OSError, ValueError):
        cache = {"v": CACHE_VERSION, "files": {}}
    files, fresh = {}, {}
    for p in PROJECTS.rglob("*.jsonl") if PROJECTS.is_dir() else []:
        try:
            st = p.stat()
        except OSError:
            continue
        sig = [st.st_mtime_ns, st.st_size]
        old = cache["files"].get(str(p))
        if old and old["sig"] == sig:
            files[str(p)] = old
        else:
            try:
                files[str(p)] = {"sig": sig, **parse_file(p, PROJECTS)}
                fresh[str(p)] = True
            except OSError:
                continue
    cache["files"] = files
    if fresh or len(files) != len(cache.get("files", {})):
        try:
            CACHE.parent.mkdir(parents=True, exist_ok=True)
            tmp = CACHE.with_suffix(".tmp")
            tmp.write_text(json.dumps(cache))
            tmp.replace(CACHE)
        except OSError:
            pass
    return files


def weight(r):
    return r[5] * W_IN + r[6] * W_CACHE_5M + r[7] * W_CACHE_1H + r[8] * W_CACHE_READ + r[9] * W_OUT


def tokens(r):
    return r[5] + r[6] + r[7] + r[8] + r[9]


def short_model(name):
    name = name.removeprefix("claude-")
    parts = name.split("-")
    # claude-opus-5-5 -> Opus 5.5 ; drop trailing date stamps like 20251001
    parts = [p for p in parts if not (p.isdigit() and len(p) == 8)]
    if parts and not parts[0].isdigit():
        return parts[0].capitalize() + (" " + ".".join(parts[1:]) if len(parts) > 1 else "")
    return name


def short_project(folder):
    # "-home-alice-proj" -> "proj", "-root-app" -> "app", "-home-alice" -> "~"
    rest = re.sub(r"^-(home-[^-]+|root)(?=-|$)", "", folder).strip("-")
    return rest or "~"


def snap_cost(snap):
    return sum(c for c, _ in snap.values())


def local_data():
    """All local messages (deduplicated) and each session's latest cost snapshot."""
    msgs, costs, seen = [], {}, set()
    for data in load().values():
        for r in data["msgs"]:
            if r[0] not in seen:
                seen.add(r[0])
                msgs.append(r)
        for sid, snap in data["costs"].items():
            if snap_cost(snap) >= snap_cost(costs.get(sid, {})):
                costs[sid] = snap
    return msgs, costs


def rows_mode(days):
    """Compact output for a remote caller: recent messages plus cost snapshots."""
    msgs, costs = local_data()
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S")
    json.dump({"ok": True, "msgs": [r for r in msgs if r[1] >= cutoff], "costs": costs},
              sys.stdout, separators=(",", ":"))


# ssh errors that just mean the machine is asleep, away or off: expected for laptops,
# so the widget shows "offline" quietly instead of a warning.
OFFLINE = re.compile(r"no route to host|timed out|connection refused|network is unreachable|"
                     r"could not resolve|name or service not known|host is down|connection reset|"
                     r"connection closed|temporary failure in name resolution", re.I)


def fetch_remote(spec):
    """Run this script on an SSH host in --rows mode. Returns (name, msgs, costs, status)."""
    name, _, path = spec.partition(":")
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    cache = CACHE.with_name(f"claude-usage-plasmoid-remote-{safe}.json")
    status = {"name": name, "ok": False, "stale": False, "offline": False, "error": ""}
    env = f"CLAUDE_CONFIG_DIR={shlex.quote(path)} " if path else ""
    cmd = ["ssh", "-C", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", name,
           f"{env}python3 -I - --rows --days 31"]
    try:
        with open(__file__, "rb") as script:
            res = subprocess.run(cmd, stdin=script, capture_output=True, timeout=30)
        data = json.loads(res.stdout or b"{}")
        if res.returncode != 0 or not data.get("ok"):
            raise RuntimeError((res.stderr.decode(errors="replace").strip().splitlines() or
                                [data.get("error") or f"ssh exited {res.returncode}"])[-1])
        status["ok"] = True
        try:
            cache.write_text(json.dumps({"fetched": time.time(), **data}))
        except OSError:
            pass
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as e:
        status["error"] = str(e) or type(e).__name__
        status["offline"] = isinstance(e, subprocess.TimeoutExpired) or bool(OFFLINE.search(status["error"]))
        try:
            data = json.loads(cache.read_text())
            status["stale"] = True
            status["fetched"] = datetime.fromtimestamp(data.get("fetched", 0), timezone.utc).isoformat()
        except (OSError, ValueError):
            data = {"msgs": [], "costs": {}}
    return name, data.get("msgs", []), data.get("costs", {}), status


def summarise(remotes=()):
    me = socket.gethostname().split(".")[0]
    msgs, costs = local_data()
    sources = [(me, msgs, costs, {"name": me, "ok": True, "stale": False, "error": "", "local": True})]
    if remotes:
        with ThreadPoolExecutor(max_workers=len(remotes)) as pool:
            sources += list(pool.map(fetch_remote, remotes))

    # Tag each message with its host; remote projects get a "host: " prefix.
    msgs, costs, seen = [], {}, set()
    for host, m_list, c_map, _ in sources:
        for r in m_list:
            if r[0] not in seen:
                seen.add(r[0])
                r = list(r[:10]) + [host]
                if host != me:
                    r[4] = f"{host}: {short_project(r[4])}"
                msgs.append(r)
        for sid, snap in c_map.items():
            if snap_cost(snap) >= snap_cost(costs.get(sid, {})):
                costs[sid] = snap

    # $ per unit of token weight, per model, calibrated from all sessions' snapshots.
    cal = defaultdict(lambda: [0.0, 0.0])
    for snap in costs.values():
        for model, (usd, w) in snap.items():
            cal[model][0] += usd; cal[model][1] += w
    rate = {m: usd / w for m, (usd, w) in cal.items() if w}
    any_rate = (sum(v[0] for v in cal.values()) / sum(v[1] for v in cal.values())) if cal else 0.0

    rows = []
    for r in msgs:
        try:
            ts = datetime.fromisoformat(r[1].replace("Z", "+00:00"))
        except ValueError:
            continue
        rows.append((ts, r, weight(r) * rate.get(r[3], any_rate)))
    rows.sort(key=lambda x: x[0])

    now = datetime.now(timezone.utc)
    local_midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)

    def bucket(start=None, end=None):
        b = {"input": 0, "cacheWrite": 0, "cacheRead": 0, "output": 0, "tokens": 0,
             "cost": 0.0, "messages": 0, "sessions": set()}
        models, projects, hosts = (defaultdict(lambda: [0, 0.0]) for _ in range(3))
        for ts, r, cost in rows:
            if (start and ts < start) or (end and ts >= end):
                continue
            tok = tokens(r)
            b["input"] += r[5]; b["cacheWrite"] += r[6] + r[7]; b["cacheRead"] += r[8]; b["output"] += r[9]
            b["tokens"] += tok; b["cost"] += cost; b["messages"] += 1; b["sessions"].add(r[2])
            models[short_model(r[3])][0] += tok; models[short_model(r[3])][1] += cost
            proj = r[4] if r[10] != me else short_project(r[4])
            projects[proj][0] += tok; projects[proj][1] += cost
            hosts[r[10]][0] += tok; hosts[r[10]][1] += cost
        b["sessions"] = len(b["sessions"])
        b["cost"] = round(b["cost"], 4)
        top = lambda d: [{"name": k, "tokens": v[0], "cost": round(v[1], 4)}
                         for k, v in sorted(d.items(), key=lambda kv: -kv[1][1] or -kv[1][0])[:5]]
        b["models"], b["projects"], b["hosts"] = top(models), top(projects), top(hosts)
        return b

    # Current 5-hour block: starts at the first message (floored to the hour) after the
    # previous block ended, the way Claude's rolling usage windows behave.
    block_start = block_end = None
    for ts, _, _ in rows:
        if block_end is None or ts >= block_end:
            block_start = ts.replace(minute=0, second=0, microsecond=0)
            block_end = block_start + BLOCK
    block = None
    if block_end and block_end > now:
        block = bucket(block_start)
        block["start"] = block_start.isoformat()
        block["end"] = block_end.isoformat()
        block["minutesLeft"] = int((block_end - now).total_seconds() // 60)

    # Daily totals for the last 7 local days (oldest first), for the popup's bar chart.
    days = []
    for i in range(6, -1, -1):
        d0 = local_midnight - timedelta(days=i)
        d = bucket(d0, d0 + timedelta(days=1))
        days.append({"date": d0.strftime("%a"), "tokens": d["tokens"], "cost": d["cost"]})

    return {
        "ok": True,
        "updated": now.isoformat(),
        "today": bucket(local_midnight),
        "block": block,
        "week": bucket(local_midnight - timedelta(days=6)),
        "month": bucket(local_midnight - timedelta(days=29)),
        "days": days,
        "lastActivity": rows[-1][0].isoformat() if rows else None,
        "hosts": [s for *_, s in sources],
    }


def fmt_tokens(n):
    for div, unit in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if n >= div:
            return f"{n / div:.{0 if n >= div * 10 else 1}f}{unit}"
    return str(n)


def text_line(out, period):
    """One-line summary matching the panel label, e.g. '21M · $11.60 · ⟳ 2h52'."""
    if not out.get("ok"):
        return f"Claude usage: error ({out.get('error', 'unknown')})"
    b = out.get(period) or {"tokens": 0, "cost": 0.0}
    cost = b["cost"]
    parts = [fmt_tokens(b["tokens"]), f"${cost:.0f}" if cost >= 100 else f"${cost:.2f}"]
    blk = out.get("block")
    if blk:
        m = blk["minutesLeft"]
        parts.append(f"⟳ {m // 60}h{m % 60:02d}" if m >= 60 else f"⟳ {m}m")
    bad = [h["name"] for h in out.get("hosts", []) if not h.get("ok", True) and not h.get("offline")]
    if bad:
        parts.append("⚠ " + ", ".join(bad))
    return " · ".join(parts)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Summarise Claude Code usage as JSON, or as one line with --text.")
    ap.add_argument("--remote", action="append", default=[], metavar="HOST:PATH",
                    help="SSH host and its Claude config dir, e.g. server:~/.claude")
    ap.add_argument("--text", action="store_true",
                    help="print a one-line summary instead of JSON (for status lines and terminals)")
    ap.add_argument("--period", choices=["block", "today", "week", "month"], default="today",
                    help="totals shown by --text (default: today)")
    ap.add_argument("--rows", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--days", type=int, default=31, help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.rows:
        try:
            rows_mode(args.days)
        except Exception as e:
            json.dump({"ok": False, "error": f"{type(e).__name__}: {e}"}, sys.stdout)
        sys.exit(0)
    t0 = time.monotonic()
    try:
        out = summarise(args.remote)
    except Exception as e:  # the widget shows this instead of going blank
        out = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    out["elapsedMs"] = int((time.monotonic() - t0) * 1000)
    if args.text:
        # Windows consoles may default to a legacy code page; ⟳ and · need UTF-8.
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        print(text_line(out, args.period))
    else:
        json.dump(out, sys.stdout, separators=(",", ":"))
