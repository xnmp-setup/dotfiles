#!/usr/bin/env python3
"""Session cost report — no LLM call, pure transcript arithmetic.

Parses a Claude Code session transcript (JSONL) and reports per-turn cost,
broken into cache-read / cache-write / output / input, normalized per step,
plus a steps-per-turn overlay. Writes a self-contained HTML chart and prints a
terminal summary.

Usage:
    session_cost.py [transcript.jsonl]      # explicit path
    session_cost.py                         # newest transcript for $PWD

Run it from Claude Code without a model call via the `!` prefix:
    ! python ~/.claude/scripts/session_cost.py

Thinking output is NOT a separate slice: the API reports one combined
output_tokens (thinking + visible text), and with thinking display "omitted"
the transcript carries no thinking content to split on. "output" is the total.
"""
import glob
import html
import json
import os
import re
import select
import shutil
import subprocess
import sys
import termios
import time
import tty

# Price per 1M tokens. cache write: 1.25x input (5m TTL) / 2x input (1h TTL);
# cache read: 0.1x input.
PRICES = {
    "Opus":   {"in": 5.0,  "out": 25.0, "cw5": 6.25, "cw1h": 10.0, "cr": 0.5},
    "Sonnet": {"in": 3.0,  "out": 15.0, "cw5": 3.75, "cw1h": 6.0,  "cr": 0.3},
    "Haiku":  {"in": 1.0,  "out": 5.0,  "cw5": 1.25, "cw1h": 2.0,  "cr": 0.1},
    "Fable":  {"in": 10.0, "out": 50.0, "cw5": 12.5, "cw1h": 20.0, "cr": 1.0},
}
# component -> (label, colour). These four come from a message's usage; the
# turn's subagent cost is layered on top, coloured per base model (MODEL_HEX).
COMPONENTS = [
    ("cache_read",  "cache read",  "#5ab0a6"),
    ("cache_write", "cache write", "#9d7ce0"),
    ("output",      "output",      "#6c8cd5"),
    ("input",       "input",       "#9aa0ac"),
]
USAGE_KEYS = tuple(k for k, _, _ in COMPONENTS)
# Subagent segments coloured by base model, matching the statusline's ansi256
# palette (Opus 208, Sonnet 216, Haiku 223, Fable 204).
MODEL_HEX = {
    "Opus":   "#ff8700",
    "Sonnet": "#ffaf87",
    "Haiku":  "#ffd7af",
    "Fable":  "#ff5f87",
}
MODEL_ORDER = ("Opus", "Sonnet", "Haiku", "Fable")
STEPS_COLOUR = "#e05a6b"


def family(model):
    lo = (model or "").lower()
    for name in ("Opus", "Sonnet", "Haiku", "Fable"):
        if name.lower() in lo:
            return name
    return "Opus"


def is_open(path):
    """True if a live process holds the transcript open (i.e. session running).
    Uses lsof; returns None if lsof is unavailable."""
    try:
        r = subprocess.run(["lsof", "-t", "--", path],
                           capture_output=True, timeout=5)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None
    return r.returncode == 0 and bool(r.stdout.strip())


def first_prompt(path, limit=64):
    """First real user message, for labelling a session in the picker."""
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if is_real_user(e):
                    c = e.get("message", {}).get("content")
                    if isinstance(c, list):
                        c = " ".join(b.get("text", "") for b in c
                                     if isinstance(b, dict) and b.get("type") == "text")
                    c = " ".join((c or "").split())
                    # skip slash-command / caveat wrappers, keep looking
                    if c.startswith("<local-command") or c.startswith("<command-"):
                        continue
                    return c[:limit]
    except OSError:
        pass
    return "(no prompt)"


def _read_key(fd):
    """Decode one keypress from a raw-mode tty fd."""
    ch = os.read(fd, 1)
    if ch == b"\x1b":  # ESC alone, or start of an arrow sequence
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            return "QUIT"
        seq = os.read(fd, 2)
        return {b"[A": "UP", b"[B": "DOWN"}.get(seq, "")
    if ch in (b"\r", b"\n"):
        return "ENTER"
    if ch in (b"q", b"Q", b"\x03"):  # q / Ctrl-C
        return "QUIT"
    return {b"k": "UP", b"j": "DOWN"}.get(ch)


def pick_session(sessions, running):
    """Scrollable arrow-key picker drawn on /dev/tty (works even when stdout is
    redirected). Enter selects, Esc/q quits (returns None). Falls back to newest
    when no interactive terminal is available."""
    if not sys.stdin.isatty():
        return sessions[0]
    try:
        fd = os.open("/dev/tty", os.O_RDWR)
    except OSError:
        return sessions[0]

    rows = [(time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(s))),
             "  ● running" if s in running else "", first_prompt(s)) for s in sessions]
    n = len(sessions)
    cols, lines = shutil.get_terminal_size((100, 24))
    win = max(3, lines - 4)  # visible rows, leaving space for header/footer

    def draw(sel, top):
        out = ["\x1b[2J\x1b[H",
               "\x1b[1mSessions in this directory\x1b[0m"
               "  \x1b[2m↑/↓ move · Enter select · Esc quit\x1b[0m\r\n"]
        out.append(f"\x1b[2m  {top + 1}-{min(top + win, n)} of {n}\x1b[0m\r\n")
        for i in range(top, min(top + win, n)):
            ts, mark, prompt = rows[i]
            line = f"{ts}{mark}  {prompt}"[:cols - 4]
            out.append(f"\x1b[7m ▸ {line} \x1b[0m\r\n" if i == sel
                       else f"   {line}\r\n")
        os.write(fd, "".join(out).encode())

    old = termios.tcgetattr(fd)
    sel, top = 0, 0
    try:
        tty.setraw(fd)
        os.write(fd, b"\x1b[?1049h\x1b[?25l")  # alt screen, hide cursor
        while True:
            if sel < top:
                top = sel
            elif sel >= top + win:
                top = sel - win + 1
            draw(sel, top)
            key = _read_key(fd)
            if key == "UP":
                sel = (sel - 1) % n
            elif key == "DOWN":
                sel = (sel + 1) % n
            elif key == "ENTER":
                return sessions[sel]
            elif key == "QUIT":
                return None
    finally:
        os.write(fd, b"\x1b[?25h\x1b[?1049l")  # show cursor, restore screen
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        os.close(fd)


def find_transcript():
    if len(sys.argv) > 1:
        return sys.argv[1]
    enc = re.sub(r"[/.]", "-", os.getcwd())
    d = os.path.expanduser(f"~/.claude/projects/{enc}")
    sessions = sorted(glob.glob(os.path.join(d, "*.jsonl")),
                      key=os.path.getmtime, reverse=True)
    if not sessions:  # fall back to newest transcript across all projects
        allf = glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
        if not allf:
            sys.exit("no transcript found")
        return max(allf, key=os.path.getmtime)
    if len(sessions) == 1:
        return sessions[0]
    # one running session -> use it; else let the user choose from all
    running = [s for s in sessions if is_open(s)]
    if len(running) == 1:
        return running[0]
    return pick_session(sessions, set(running))


def load(path):
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def is_real_user(e):
    if e.get("type") != "user":
        return False
    c = e.get("message", {}).get("content")
    if isinstance(c, str):
        return True
    if isinstance(c, list):
        return any(isinstance(b, dict) and b.get("type") != "tool_result" for b in c)
    return False


def usage_cost(u, fam):
    p = PRICES[fam]
    cc = u.get("cache_creation") or {}
    cw5, cw1h = cc.get("ephemeral_5m_input_tokens"), cc.get("ephemeral_1h_input_tokens")
    if cw5 is None and cw1h is None:
        cw5, cw1h = u.get("cache_creation_input_tokens", 0) or 0, 0
    cw5, cw1h = cw5 or 0, cw1h or 0
    return {
        "cache_read":  (u.get("cache_read_input_tokens", 0) or 0) * p["cr"] / 1e6,
        "cache_write": (cw5 * p["cw5"] + cw1h * p["cw1h"]) / 1e6,
        "output":      (u.get("output_tokens", 0) or 0) * p["out"] / 1e6,
        "input":       (u.get("input_tokens", 0) or 0) * p["in"] / 1e6,
    }


def is_synthetic(e):
    """Harness-injected stub (e.g. the <synthetic> reply to a task-notification)
    or an API-error message — zero real usage, not a genuine model step."""
    return (e.get("isApiErrorMessage") is True
            or e.get("message", {}).get("model") == "<synthetic>")


def tool_use_ids(msg):
    """Task/tool_use block ids emitted by an assistant message."""
    c = msg.get("content")
    if not isinstance(c, list):
        return []
    return [b.get("id") for b in c
            if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id")]


def build_turns(entries):
    """Group assistant steps under the preceding main-chain human turn.

    Older transcripts logged subagent work inline (isSidechain); newer ones put
    it in sibling files (see load_subagents). Inline sidechains are folded into
    the turn's "subagent" component here; external ones are attributed later.
    """
    bounds = [i for i, e in enumerate(entries)
              if not e.get("isSidechain") and is_real_user(e)]
    bounds.append(len(entries))
    turns = []
    for k in range(len(bounds) - 1):
        s, e = bounds[k], bounds[k + 1]
        seen = set()
        comps = {c: 0.0 for c, _, _ in COMPONENTS}
        inline = {}  # model family -> {"cost": {...}, "steps": n} for old transcripts
        by_model = {}  # main-chain cost by model family (for the header chip)
        steps, tids = 0, set()
        for x in entries[s + 1:e]:
            if x.get("type") != "assistant" or is_synthetic(x):
                continue
            msg = x.get("message", {})
            # tool_use blocks stream across separate lines sharing one message.id,
            # so gather ids from every line even when usage is deduped below.
            if not x.get("isSidechain"):
                tids.update(tool_use_ids(msg))
            mid = msg.get("id") or x.get("requestId")
            if mid is not None:
                if mid in seen:
                    continue  # same response logged on several lines
                seen.add(mid)
            fam = family(msg.get("model"))
            c = usage_cost(msg.get("usage") or {}, fam)
            if x.get("isSidechain"):
                node = inline.setdefault(
                    fam, {"cost": {key: 0.0 for key in USAGE_KEYS}, "steps": 0})
                for key in USAGE_KEYS:
                    node["cost"][key] += c[key]
                node["steps"] += 1
            else:
                steps += 1
                by_model[fam] = by_model.get(fam, 0.0) + sum(c.values())
                for key in USAGE_KEYS:
                    comps[key] += c[key]
        # legacy inline sidechains become one subagent record per model
        subs = [{"label": f"inline subagent ({fam})", "type": "sidechain",
                 "model": fam, "cost": n["cost"], "steps": n["steps"],
                 "total": sum(n["cost"].values()), "children": []}
                for fam, n in inline.items()]
        turns.append({"num": k + 1, "steps": steps, "tids": sorted(tids),
                      "comps": comps, "subs": subs, "by_model": by_model})
    return turns


def load_subagents(main_path):
    """Map tool_use id -> aggregated subagent node for a session's sidechain
    files at <dir>/<session-id>/subagents/agent-*.jsonl.

    Each node: {"cost": {usage_key: usd}, "steps": int, "children": [tool ids]}
    keyed by the meta.json toolUseId that spawned it. Nested agents reference
    their parent by a toolUseId that lives inside the parent's transcript, so
    the tree is reconstructed via each node's own tool_use ids ("children").
    """
    base = main_path[:-6] if main_path.endswith(".jsonl") else main_path
    sub_dir = os.path.join(base, "subagents")
    nodes = {}
    for meta_path in sorted(glob.glob(os.path.join(sub_dir, "agent-*.meta.json"))):
        try:
            with open(meta_path) as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            continue
        tid = meta.get("toolUseId")
        jsonl = meta_path[:-len(".meta.json")] + ".jsonl"
        if not tid or not os.path.exists(jsonl):
            continue
        # gather per-message (= per-step): usage counted once, tool_use ids
        # unioned across the streamed lines that share a message id.
        msgs, order = {}, 0
        for x in load(jsonl):
            if x.get("type") != "assistant" or is_synthetic(x):
                continue
            msg = x.get("message", {})
            mid = msg.get("id") or x.get("requestId") or f"_{order}"
            d = msgs.get(mid)
            if d is None:
                d = {"order": order, "tids": set(), "comps": None, "model": None}
                msgs[mid] = d
                order += 1
            d["tids"].update(tool_use_ids(msg))
            if d["comps"] is None:
                fam = family(msg.get("model"))
                c = usage_cost(msg.get("usage") or {}, fam)
                d["comps"] = {k: c[k] for k in USAGE_KEYS}
                d["model"] = fam
        steps_detail = [{"comps": d["comps"], "model": d["model"],
                         "tids": sorted(d["tids"])}
                        for d in sorted(msgs.values(), key=lambda d: d["order"])]
        cost = {k: sum(s["comps"][k] for s in steps_detail) for k in USAGE_KEYS}
        children = sorted({c for s in steps_detail for c in s["tids"]})
        fam_cost = {}
        for s in steps_detail:
            fam_cost[s["model"]] = fam_cost.get(s["model"], 0.0) + sum(s["comps"].values())
        model = max(fam_cost, key=fam_cost.get) if fam_cost else "Opus"
        nodes[tid] = {
            "cost": cost, "steps": len(steps_detail), "children": children,
            "steps_detail": steps_detail, "model": model,
            "type": meta.get("agentType") or "agent",
            "desc": meta.get("description") or "",
        }
    return nodes


def _rolled_factory(nodes):
    """Memoized subtree rollup: cost, steps and cost-by-model for a subagent and
    all its descendants."""
    memo = {}

    def rolled(tid):
        if tid in memo:
            return memo[tid]
        node = nodes[tid]
        memo[tid] = {"cost": {k: 0.0 for k in USAGE_KEYS}, "steps": 0,
                     "by_model": {}, "total": 0.0}  # cycle guard
        cost = {k: node["cost"][k] for k in USAGE_KEYS}
        steps = node["steps"]
        by = {node["model"]: sum(node["cost"].values())}
        for cid in node["children"]:
            if cid in nodes:
                r = rolled(cid)
                for k in USAGE_KEYS:
                    cost[k] += r["cost"][k]
                steps += r["steps"]
                for m, v in r["by_model"].items():
                    by[m] = by.get(m, 0.0) + v
        res = {"cost": cost, "steps": steps, "by_model": by,
               "total": sum(cost.values())}
        memo[tid] = res
        return res

    return rolled


def build_nodes(turns, nodes):
    """Build the traversable tree of chart nodes keyed by 'root' (session turns)
    and each subagent's tool_use id (its own steps). Segments carry the rolled
    subtree total, coloured by the subtree's dominant model. Also annotates each
    turn with total/sub_total/sub_steps for the terminal summary."""
    rolled = _rolled_factory(nodes)

    def dominant(tid):
        by = rolled(tid)["by_model"]
        return max(by, key=by.get) if by else nodes[tid]["model"]

    def seg(tid):
        return {"id": tid, "label": nodes[tid]["desc"] or nodes[tid]["type"],
                "model": dominant(tid), "total": rolled(tid)["total"]}

    def submodel(child_ids):
        by = {}
        for cid in child_ids:
            if cid in nodes:
                for m, v in rolled(cid)["by_model"].items():
                    by[m] = by.get(m, 0.0) + v
        return by

    NODES = {}
    for tid, n in nodes.items():
        bars = [{"label": str(j + 1), "comps": st["comps"], "steps": 1,
                 "subs": [seg(c) for c in st["tids"] if c in nodes]}
                for j, st in enumerate(n["steps_detail"])]
        direct = [c for c in n["children"] if c in nodes]
        r = rolled(tid)
        NODES[tid] = {
            "title": n["type"], "subtitle": n["desc"], "model": dominant(tid),
            "kind": "step", "total": r["total"], "steps": n["steps"],
            "sub_steps": r["steps"] - n["steps"],
            "comp_tot": {k: sum(b["comps"][k] for b in bars) for k in USAGE_KEYS},
            "submodel": submodel(direct), "bars": bars,
        }

    bars, all_top = [], []
    for t in turns:
        direct = [tid for tid in t.get("tids", []) if tid in nodes]
        all_top.extend(direct)
        sub_total = sum(rolled(tid)["total"] for tid in direct)
        t["sub_total"] = sub_total
        t["sub_steps"] = sum(rolled(tid)["steps"] for tid in direct)
        t["total"] = sum(t["comps"].values()) + sub_total
        bars.append({"label": str(t["num"]),
                     "comps": {k: t["comps"][k] for k in USAGE_KEYS},
                     "steps": t["steps"], "subs": [seg(tid) for tid in direct]})
    # dominant model over the whole session = main-chain by-model + subagents
    overall = dict(submodel(all_top))
    for t in turns:
        for m, v in t.get("by_model", {}).items():
            overall[m] = overall.get(m, 0.0) + v
    NODES["root"] = {
        "title": "Session cost by turn", "subtitle": "",
        "model": max(overall, key=overall.get) if overall else None,
        "kind": "turn",
        "total": sum(sum(b["comps"].values()) for b in bars)
        + sum(rolled(tid)["total"] for tid in all_top),
        "steps": sum(t["steps"] for t in turns),
        "sub_steps": sum(rolled(tid)["steps"] for tid in all_top),
        "comp_tot": {k: sum(t["comps"][k] for t in turns) for k in USAGE_KEYS},
        "submodel": submodel(all_top), "bars": bars,
    }
    return NODES


def fmt(usd):
    if usd >= 1:
        return f"${usd:.2f}"
    c = usd * 100
    if c >= 10:
        return f"{round(c)}c"
    if c >= 1:
        return f"{c:.1f}c"
    return "<1c" if c > 0 else "0c"


_CSS = """
 /* Page-chrome colours live in CSS variables so Dark Reader (dynamic mode) can
    remap them. The chart's data colours (component/model/steps) stay fixed hex
    so the graph remains legible whatever theme is applied. */
 :root{color-scheme:dark;
   --bg1:#20202c;--bg2:#14141b;--panel:#1c1c26;--text:#e4e6eb;--muted:#9aa0ac;
   --axis2:#c7ccd6;--line:#ffffff14;--border:#ffffff12;--border2:#ffffff20;
   --track:#3a3a46;--note:#727888;--tipbg:#0d0d12f2;--tipbd:#ffffff22}
 *{box-sizing:border-box}
 body{margin:0;background:radial-gradient(1200px 600px at 20% -10%,var(--bg1),var(--bg2) 60%);
   color:var(--text);font-family:ui-sans-serif,system-ui,sans-serif;padding:32px 24px;-webkit-font-smoothing:antialiased}
 .wrap{max-width:960px;margin:0 auto}
 .head{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;flex-wrap:wrap;margin-bottom:18px}
 h2{margin:0;font-size:20px;font-weight:650;letter-spacing:-.01em}
 .sub{color:var(--muted);margin-top:4px;font-size:13px}
 .crumb{font-size:12px;color:var(--muted);margin-bottom:5px}
 .chip{font-size:11px;font-weight:600;padding:2px 9px;border-radius:20px;letter-spacing:.02em;white-space:nowrap}
 .cx{cursor:pointer} .cx:hover{color:var(--text);text-decoration:underline}
 .cs{margin:0 6px;opacity:.5}
 .big{text-align:right;line-height:1}
 .big .amt{font-size:32px;font-weight:700;letter-spacing:-.02em}
 .big .cap{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.08em;margin-top:4px}
 .panel{background:var(--panel);border:1px solid var(--border);border-radius:14px;padding:16px 18px;
   box-shadow:0 1px 0 #ffffff0a inset,0 8px 24px #0006}
 .bar{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap;margin-bottom:10px}
 .sw{width:11px;height:11px;border-radius:3px;display:inline-block;flex:none}
 .backbtn{background:var(--border);border:1px solid var(--border2);color:var(--axis2);font-size:12px;
   padding:4px 11px;border-radius:8px;cursor:pointer}
 .backbtn:hover{background:#ffffff1e;color:var(--text)}
 .row{display:flex;align-items:center;gap:9px} .row .lb{flex:1}
 .row b{font-variant-numeric:tabular-nums} .row .pct{color:var(--muted);width:48px;text-align:right;font-variant-numeric:tabular-nums}
 .grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-top:16px}
 @media(max-width:640px){.grid{grid-template-columns:1fr}}
 .card h3{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.06em;margin:0 0 12px;font-weight:600}
 .col{display:flex;flex-direction:column;gap:9px;font-size:14px}
 .kv{font-size:14px;line-height:2.05}
 .tot{display:flex;gap:9px;border-top:1px solid var(--line);padding-top:9px;margin-top:3px;font-weight:600}
 .tgl{display:inline-flex;align-items:center;gap:9px;cursor:pointer;font-size:13px;color:var(--axis2);user-select:none}
 .tgl input{display:none}
 .tr{width:38px;height:21px;border-radius:21px;background:var(--track);position:relative;transition:.15s;flex:none}
 .tr::after{content:"";position:absolute;top:2px;left:2px;width:17px;height:17px;border-radius:50%;background:var(--text);transition:.15s}
 .tgl input:checked + .tr{background:#5ab0a6}
 .tgl input:checked + .tr::after{transform:translateX(17px)}
 .mini{margin:2px 0 6px;cursor:pointer;display:none}
 .mini svg{display:block;width:100%;border-radius:6px;background:#00000030}
 .scroll{overflow-x:auto}
 svg rect{transition:opacity .1s} svg rect:hover{opacity:.82}
 svg rect.clk{cursor:pointer} svg rect.clk:hover{opacity:.66}
 /* SVG chrome routed through the same variables (data fills stay inline hex) */
 svg .gl{stroke:var(--line)} svg .axt{fill:var(--muted)} svg .axt2{fill:var(--axis2)} svg .sep{fill:var(--panel)}
 .tip{position:fixed;pointer-events:none;background:var(--tipbg);border:1px solid var(--tipbd);color:var(--text);
   font-size:12px;padding:5px 9px;border-radius:7px;display:none;z-index:20;max-width:340px;box-shadow:0 6px 20px #0009}
 .note{color:var(--note);font-size:12px;margin-top:18px;line-height:1.6}
"""

_SHELL = """
<div class="wrap">
<div class="head">
  <div><div id="crumb" class="crumb"></div>
    <div style="display:flex;align-items:center;gap:10px"><h2 id="title"></h2><span id="modelchip" class="chip"></span></div>
    <div id="subtitle" class="sub"></div></div>
  <div class="big"><div class="amt" id="total"></div><div class="cap" id="cap">total spend</div></div>
</div>
<div class="panel">
  <div class="bar">
    <div style="display:flex;align-items:center;gap:14px">
      <button id="back" class="backbtn" onclick="goBack()">&larr; back</button>
      <label class="tgl"><input type="checkbox" id="norm" checked onchange="setMode()"><span class="tr"></span><span id="normlbl">normalize by steps</span></label>
      <label class="tgl"><input type="checkbox" id="subs" checked onchange="toggleSubs()"><span class="tr"></span>show subagents</label>
    </div>
  </div>
  <div id="mini" class="mini"></div>
  <div id="scroll" class="scroll"><div id="chart"></div></div>
</div>
<div class="grid">
  <div class="panel card"><h3 id="bkTitle">cost breakdown</h3><div class="col" id="breakdown"></div></div>
  <div class="panel card"><h3>summary</h3><div class="kv" id="summary"></div></div>
</div>
<div class="note">Bars = cost per <b id="unitn">turn</b> (toggle: &divide; step count, or raw), stacked by component; subagent
segments coloured by base model. Hover for the exact cost; <b>click a subagent segment to open its own graph</b> (&larr; back to return).
<b>Zoom:</b> scroll to zoom around the cursor, drag across the minimap to select a range, double-click or Esc to reset; the minimap
shows the whole span with the current window highlighted (Esc again, once unzoomed, steps back up the tree). "output" includes thinking tokens &mdash; the API does not report them separately.</div>
</div>
<div id="tip" class="tip"></div>
"""

_JS = """
const COMPS=[["cache_read","cache read","#5ab0a6"],["cache_write","cache write","#9d7ce0"],["output","output","#6c8cd5"],["input","input","#9aa0ac"]];
const MODEL_HEX={Opus:"#ff8700",Sonnet:"#ffaf87",Haiku:"#ffd7af",Fable:"#ff5f87"};
const MODELS=["Opus","Sonnet","Haiku","Fable"], SUBHEX="#b083e0", STEPS="#e05a6b";
let stack=["root"], mode="per_step", showSubs=true;
let win=null, winKey=null, CH={padL:64,band:10,s0:0}, msel=null;

function fmt(u){if(u>=1)return "$"+u.toFixed(2);var c=u*100;if(c>=10)return Math.round(c)+"c";if(c>=1)return c.toFixed(1)+"c";return c>0?"<1c":"0c";}
function esc(s){return (""+(s==null?"":s)).replace(/[&<>\"]/g,function(m){return {"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;"}[m];});}
function mh(m){return MODEL_HEX[m]||SUBHEX;}
function cur(){return NODES[stack[stack.length-1]];}
function curKey(){return stack[stack.length-1];}
function tipEl(){return document.getElementById("tip");}
function contW(){return document.getElementById("scroll").clientWidth||900;}

function segsFor(bar,div){
  var out=COMPS.map(function(c){var raw=bar.comps[c[0]];return {color:c[2],v:raw/div,raw:raw,type:c[1],sub:false};});
  if(showSubs)bar.subs.forEach(function(s){out.push({color:mh(s.model),v:s.total/div,raw:s.total,type:s.model+" subagent \\u2014 "+s.label,sub:true,id:s.id});});
  return out;
}
function barTotal(b){var d=(mode==="per_step"&&b.steps)?b.steps:1;return segsFor(b,d).reduce(function(a,x){return a+x.v;},0);}
function ensureWin(node){var k=curKey();if(winKey!==k||!win){win={s:0,e:node.bars.length-1};winKey=k;}
  if(win.e>node.bars.length-1)win.e=node.bars.length-1; if(win.s<0)win.s=0; if(win.s>win.e)win.s=win.e;}

function render(){
  var node=cur();
  document.getElementById("title").textContent=node.title;
  var chip=document.getElementById("modelchip");
  if(node.model){var mc=mh(node.model);chip.textContent=node.model;chip.style.display="";
    chip.style.color=mc;chip.style.background=mc+"22";chip.style.border="1px solid "+mc+"66";}
  else chip.style.display="none";
  document.getElementById("subtitle").textContent=node.subtitle||"";
  document.getElementById("total").textContent=fmt(node.total);
  document.getElementById("cap").textContent=node.kind==="turn"?"total spend":"subtree spend";
  document.getElementById("unitn").textContent=node.kind;
  document.getElementById("back").style.display=stack.length>1?"":"none";
  document.getElementById("crumb").innerHTML=stack.map(function(k,i){return "<span class=\\"cx\\" onclick=\\"jump("+i+")\\">"+esc(i===0?"session":NODES[k].title)+"</span>";}).join("<span class=\\"cs\\">\\u203a</span>");
  var norm=document.getElementById("norm"), stepKind=node.kind!=="turn";
  norm.disabled=stepKind; norm.parentElement.style.opacity=stepKind?".4":"";
  norm.parentElement.style.cursor=stepKind?"default":"pointer";
  document.getElementById("normlbl").textContent=stepKind?"per step (already finest grain)":"normalize by steps";
  buildStats(node); redraw(node);
}
function redraw(node){drawChart(node);buildMini(node);}

function crow(c,l,amt,total){return "<div class=\\"row\\"><span class=\\"sw\\" style=\\"background:"+c+"\\"></span><span class=\\"lb\\">"+esc(l)+"</span><b>"+fmt(amt)+"</b><span class=\\"pct\\">"+(total?(amt/total*100).toFixed(1):"0.0")+"%</span></div>";}
function buildStats(node){
  var total=node.total||1e-12;
  var rows=COMPS.map(function(c){return crow(c[2],c[1],node.comp_tot[c[0]],total);});
  MODELS.forEach(function(m){if(node.submodel[m])rows.push(crow(mh(m),"subagent \\u00b7 "+m,node.submodel[m],total));});
  rows.push("<div class=\\"tot\\"><span style=\\"flex:1\\">total</span><b>"+fmt(node.total)+"</b><span style=\\"width:48px\\"></span></div>");
  document.getElementById("breakdown").innerHTML=rows.join("");
  var nb=node.bars.length, steps=node.steps, subs=node.sub_steps||0, unit=node.kind;
  var kv=(node.kind==="turn"?"turns":"steps")+"&nbsp;&nbsp;<b>"+nb+"</b><br>";
  if(node.kind==="turn")kv+="steps&nbsp;&nbsp;<b>"+steps+"</b><br>";
  if(subs)kv+="subagent steps&nbsp;&nbsp;<b>"+subs+"</b><br>";
  kv+="avg cost / "+unit+"&nbsp;&nbsp;<b>"+fmt(node.total/(nb||1))+"</b><br>";
  kv+="avg cost / step&nbsp;&nbsp;<b>"+fmt(node.total/(((node.kind==="turn"?steps:nb)+subs)||1))+"</b>";
  document.getElementById("summary").innerHTML=kv;
}

function drawChart(node){
  ensureWin(node);
  var bars=node.bars, turnKind=node.kind==="turn", s0=win.s, e0=win.e, m=e0-s0+1;
  var cont=contW(), padL=64,padR=turnKind?52:20,padT=16,padB=30,plotH=300;
  var band=(cont-padL-padR)/Math.max(1,m);
  var barW=Math.max(2,Math.min(band*0.66,44)), plotW=m*band, W=cont, H=padT+plotH+padB;
  CH={padL:padL,band:band,s0:s0};
  var heights=[]; for(var i=s0;i<=e0;i++)heights.push(barTotalDiv(bars[i]));
  var maxCost=Math.max.apply(null,heights.concat([1e-9]));
  var maxSteps=1; for(var i=s0;i<=e0;i++)maxSteps=Math.max(maxSteps,bars[i].steps);
  function yc(v){return padT+plotH*(1-v/maxCost);}
  function ys(v){return padT+plotH*(1-v/maxSteps);}
  var s=["<svg width=\\""+W+"\\" height=\\""+H+"\\" viewBox=\\"0 0 "+W+" "+H+"\\" font-family=\\"ui-sans-serif,system-ui,sans-serif\\">"];
  [0,.25,.5,.75,1].forEach(function(f){var y=padT+plotH*(1-f);
    s.push("<line x1=\\""+padL+"\\" y1=\\""+y.toFixed(1)+"\\" x2=\\""+(padL+plotW)+"\\" y2=\\""+y.toFixed(1)+"\\" class=\\"gl\\"/>");
    s.push("<text x=\\""+(padL-8)+"\\" y=\\""+(y+4).toFixed(1)+"\\" text-anchor=\\"end\\" font-size=\\"11\\" class=\\"axt\\">"+fmt(maxCost*f)+"</text>");
    if(turnKind)s.push("<text x=\\""+(padL+plotW+8)+"\\" y=\\""+(y+4).toFixed(1)+"\\" font-size=\\"11\\" fill=\\""+STEPS+"\\">"+Math.round(maxSteps*f)+"</text>");
  });
  var labelEvery=Math.max(1,Math.round(30/band));
  for(var i=s0;i<=e0;i++){
    var b=bars[i], k=i-s0, cx=padL+k*band+band/2, x=cx-barW/2, div=(mode==="per_step"&&b.steps)?b.steps:1;
    var segs=segsFor(b,div).filter(function(g){return g.v>0;}), acc=0;
    segs.forEach(function(g,j){
      var y0=yc(acc), y1=yc(acc+g.v), h=Math.max(0,y0-y1), r=(j===segs.length-1)?4:0;
      var tip=esc(g.type+" \\u00b7 "+fmt(g.raw)+(g.sub?" \\u00b7 click to open":""));
      var attr="data-tip=\\""+tip+"\\"";
      if(g.sub)attr+=" class=\\"clk\\" data-id=\\""+g.id+"\\"";
      s.push("<rect x=\\""+x.toFixed(1)+"\\" y=\\""+y1.toFixed(1)+"\\" width=\\""+barW.toFixed(1)+"\\" height=\\""+h.toFixed(1)+"\\" rx=\\""+r+"\\" fill=\\""+g.color+"\\" "+attr+"></rect>");
      if(r&&h>r)s.push("<rect x=\\""+x.toFixed(1)+"\\" y=\\""+(y1+r).toFixed(1)+"\\" width=\\""+barW.toFixed(1)+"\\" height=\\""+(h-r).toFixed(1)+"\\" fill=\\""+g.color+"\\" "+attr+"></rect>");
      if(j<segs.length-1&&h>1.5)s.push("<rect x=\\""+x.toFixed(1)+"\\" y=\\""+(y1-0.6).toFixed(1)+"\\" width=\\""+barW.toFixed(1)+"\\" height=\\"1.3\\" class=\\"sep\\" pointer-events=\\"none\\"></rect>");
      acc+=g.v;
    });
    if(k%labelEvery===0)s.push("<text x=\\""+cx.toFixed(1)+"\\" y=\\""+(padT+plotH+16)+"\\" text-anchor=\\"middle\\" font-size=\\"10\\" class=\\"axt\\">"+b.label+"</text>");
  }
  if(turnKind){
    var pts=[]; for(var i=s0;i<=e0;i++){var k=i-s0;pts.push((padL+k*band+band/2).toFixed(1)+","+ys(bars[i].steps).toFixed(1));}
    s.push("<polyline points=\\""+pts.join(" ")+"\\" fill=\\"none\\" stroke=\\""+STEPS+"\\" stroke-width=\\"2\\" opacity=\\"0.9\\"/>");
    for(var i=s0;i<=e0;i++){var k=i-s0,cx=padL+k*band+band/2;s.push("<circle cx=\\""+cx.toFixed(1)+"\\" cy=\\""+ys(bars[i].steps).toFixed(1)+"\\" r=\\"3\\" fill=\\""+STEPS+"\\" data-tip=\\""+esc("turn "+bars[i].label+": "+bars[i].steps+" steps")+"\\"></circle>");}
  }
  var mid=padT+plotH/2, yl=turnKind?(mode==="per_step"?"cost / step":"cost / turn"):"cost / step";
  s.push("<text x=\\"15\\" y=\\""+mid+"\\" font-size=\\"12\\" class=\\"axt2\\" transform=\\"rotate(-90 15 "+mid+")\\" text-anchor=\\"middle\\">"+yl+"</text>");
  if(turnKind)s.push("<text x=\\""+(W-13)+"\\" y=\\""+mid+"\\" font-size=\\"12\\" fill=\\""+STEPS+"\\" transform=\\"rotate(90 "+(W-13)+" "+mid+")\\" text-anchor=\\"middle\\">steps</text>");
  s.push("<text x=\\""+(padL+plotW/2).toFixed(0)+"\\" y=\\""+(H-6)+"\\" font-size=\\"12\\" class=\\"axt2\\" text-anchor=\\"middle\\">"+(turnKind?"turn":"step")+"</text>");
  s.push("</svg>");
  document.getElementById("chart").innerHTML=s.join("");
}
function barTotalDiv(b){var d=(mode==="per_step"&&b.steps)?b.steps:1;return segsFor(b,d).reduce(function(a,x){return a+x.v;},0);}

function buildMini(node){
  var mini=document.getElementById("mini"), n=node.bars.length;
  if(n<8){mini.style.display="none";mini.innerHTML="";return;}
  mini.style.display="block";
  var W=contW(), Hm=40, mb=W/n;
  var full=node.bars.map(barTotalDiv), maxC=Math.max.apply(null,full.concat([1e-9]));
  var s=["<svg width=\\""+W+"\\" height=\\""+Hm+"\\" viewBox=\\"0 0 "+W+" "+Hm+"\\" preserveAspectRatio=\\"none\\">"];
  node.bars.forEach(function(b,i){
    var div=(mode==="per_step"&&b.steps)?b.steps:1, acc=0;
    segsFor(b,div).filter(function(g){return g.v>0;}).forEach(function(g){
      var h=(g.v/maxC)*(Hm-5), y=Hm-3-(acc/maxC)*(Hm-5)-h;
      s.push("<rect x=\\""+(i*mb).toFixed(2)+"\\" y=\\""+y.toFixed(2)+"\\" width=\\""+Math.max(0.6,mb-0.35).toFixed(2)+"\\" height=\\""+h.toFixed(2)+"\\" fill=\\""+g.color+"\\"/>");
      acc+=g.v;
    });
  });
  var vx=win.s*mb, vw=(win.e-win.s+1)*mb;
  s.push("<rect x=\\"0\\" y=\\"0\\" width=\\""+vx.toFixed(1)+"\\" height=\\""+Hm+"\\" fill=\\"#0e0e14aa\\"/>");
  s.push("<rect x=\\""+(vx+vw).toFixed(1)+"\\" y=\\"0\\" width=\\""+(W-vx-vw).toFixed(1)+"\\" height=\\""+Hm+"\\" fill=\\"#0e0e14aa\\"/>");
  s.push("<rect x=\\""+vx.toFixed(1)+"\\" y=\\"0.5\\" width=\\""+vw.toFixed(1)+"\\" height=\\""+(Hm-1)+"\\" fill=\\"#ffffff10\\" stroke=\\"#ffffffcc\\" stroke-width=\\"1\\" rx=\\"3\\"/>");
  s.push("</svg>");
  mini.innerHTML=s.join("");
}

function miniBarAt(e){var mini=document.getElementById("mini"),r=mini.getBoundingClientRect(),n=cur().bars.length;
  return Math.max(0,Math.min(n-1,Math.floor(((e.clientX-r.left)/r.width)*n)));}
function showTip(e){
  var t=e.target, d=t&&t.getAttribute&&t.getAttribute("data-tip"), tip=tipEl();
  if(!d){tip.style.display="none";return;}
  tip.textContent=d; tip.style.display="block";
  var x=e.clientX+13,y=e.clientY+13,w=tip.offsetWidth;
  if(x+w>window.innerWidth-8)x=e.clientX-w-13;
  tip.style.left=x+"px"; tip.style.top=y+"px";
}
function goBack(){if(stack.length>1){stack.pop();render();}}
function jump(i){if(i<stack.length-1){stack=stack.slice(0,i+1);render();}}
function setMode(){if(document.getElementById("norm").disabled)return;mode=document.getElementById("norm").checked?"per_step":"total";render();}
function toggleSubs(){showSubs=document.getElementById("subs").checked;render();}
function resetZoom(){var node=cur();win={s:0,e:node.bars.length-1};redraw(node);}

(function(){
  var chart=document.getElementById("chart");
  chart.addEventListener("mousemove",showTip);
  chart.addEventListener("mouseleave",function(){tipEl().style.display="none";});
  chart.addEventListener("click",function(e){var id=e.target&&e.target.getAttribute&&e.target.getAttribute("data-id");if(id){stack.push(id);tipEl().style.display="none";render();}});
  chart.addEventListener("dblclick",resetZoom);
  chart.addEventListener("wheel",function(e){
    e.preventDefault(); var node=cur(); var r=chart.getBoundingClientRect();
    var pos=CH.s0+(e.clientX-r.left-CH.padL)/CH.band; var m=win.e-win.s+1;
    var f=e.deltaY>0?1.25:0.8, nm=Math.max(3,Math.min(node.bars.length,Math.round(m*f)));
    var ns=Math.round(pos-(pos-win.s)*(nm/m)); ns=Math.max(0,Math.min(node.bars.length-nm,ns));
    win={s:ns,e:ns+nm-1}; redraw(node);
  },{passive:false});
  var mini=document.getElementById("mini");
  mini.addEventListener("dblclick",resetZoom);
  mini.addEventListener("mousedown",function(e){e.preventDefault();msel={a:miniBarAt(e),moved:false};});
  window.addEventListener("mousemove",function(e){
    if(!msel)return; var b=miniBarAt(e); if(b!==msel.a)msel.moved=true;
    var node=cur(); win={s:Math.min(msel.a,b),e:Math.max(msel.a,b)}; redraw(node);
  });
  window.addEventListener("mouseup",function(e){
    if(!msel)return; var node=cur();
    if(!msel.moved){ var w=win.e-win.s+1, c=msel.a, s=Math.max(0,Math.min(node.bars.length-w,c-Math.floor(w/2))); win={s:s,e:s+w-1}; redraw(node); }
    msel=null;
  });
  document.addEventListener("keydown",function(e){if(e.key!=="Escape")return;
    var node=cur(); if(win&&(win.s>0||win.e<node.bars.length-1))resetZoom(); else goBack();});
  var rt; window.addEventListener("resize",function(){clearTimeout(rt);rt=setTimeout(function(){redraw(cur());},120);});
  render();
})();
"""


def render_html(nodes_tree, path):
    doc = ('<!doctype html><html><head><meta charset="utf-8">'
           '<meta name="color-scheme" content="dark light">'
           '<meta name="viewport" content="width=device-width,initial-scale=1">'
           '<title>Session cost</title>'
           '<style>' + _CSS + '</style></head><body>' + _SHELL
           + '<script>const NODES=' + json.dumps(nodes_tree) + ';\n' + _JS + '</script>'
           '</body></html>')
    with open(path, "w") as fh:
        fh.write(doc)


def main():
    path = find_transcript()
    if path is None:  # user quit the picker
        return
    entries = load(path)
    all_turns = build_turns(entries)
    turns = [t for t in all_turns if t["steps"] > 0]  # drop interrupts (0 steps)
    nodes_tree = build_nodes(turns, load_subagents(path))  # annotates turn totals
    dropped = len(all_turns) - len(turns)
    root = nodes_tree["root"]
    total = root["total"]
    tot_steps = root["steps"]
    sub_steps = root["sub_steps"]
    comp_tot = root["comp_tot"]
    sub_by_model = root["submodel"]

    print(f"transcript : {path}")
    tnote = f"  (+{dropped} interrupted, hidden)" if dropped else ""
    print(f"turns      : {len(turns)}{tnote}")
    sub_note = f"  (+{sub_steps} subagent)" if sub_steps else ""
    print(f"steps      : {tot_steps}{sub_note}")
    print(f"total cost : {fmt(total)}")
    print("by component:")
    for c, lbl, _ in COMPONENTS:
        share = (comp_tot[c] / total * 100) if total else 0
        print(f"  {lbl:<12}{fmt(comp_tot[c]):>8}  ({share:4.1f}%)")
    for m in MODEL_ORDER:
        if sub_by_model.get(m):
            share = (sub_by_model[m] / total * 100) if total else 0
            print(f"  {'sub ' + m:<12}{fmt(sub_by_model[m]):>8}  ({share:4.1f}%)")
    print(f"\n{'turn':>4} {'steps':>6} {'cost':>8} {'$/step':>8}")
    for t in turns:
        ps = fmt(t["total"] / t["steps"]) if t["steps"] else "-"
        print(f"{t['num']:>4} {t['steps']:>6} {fmt(t['total']):>8} {ps:>8}")

    out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "session_cost.html")
    render_html(nodes_tree, out)
    print(f"\nchart: {out}")
    if os.environ.get("SESSION_COST_OPEN", "1") == "1":
        os.system(f'(xdg-open "{out}" >/dev/null 2>&1 &)')


if __name__ == "__main__":
    main()
