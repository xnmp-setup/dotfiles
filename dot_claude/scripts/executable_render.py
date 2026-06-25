#!/usr/bin/env python3
"""Incremental Claude Code transcript -> HTML viewer.

Renders a session transcript (JSONL) into a self-contained, offline HTML viewer
that shows one turn at a time, with Prev/Next nav, an IDE-style minimap, and
collapsible thinking / tool-use / JSON blocks.

Design: append-only. Each run reads only the NEW bytes of the transcript since
the last run (tracked in state.json), finalizes any turns that are now complete,
and APPENDS them to turns.js (one `window.__TURNS__.push({...})` per turn).
index.html is written once and never regenerated.

Entrypoints
-----------
  render.py <sessionId|path>      incremental build/refresh (on-demand CLI)
  render.py --flush <session>     also emit the in-progress (latest) turn
  render.py --hook                read hook JSON from stdin (Stop hook)
  render.py --open <session>      print path to index.html (for opening)

Pure stdlib. Run with `python3` or `uv run`.
"""
from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

HOME = Path(os.path.expanduser("~"))
PROJECTS_DIR = HOME / ".claude" / "projects"
ROOT = HOME / ".claude" / "transcript-html"
OUT_ROOT = ROOT / "sessions"
ASSETS_DIR = ROOT / "assets"  # shared style.css / theme.css / app.js
PROMPT_SNIPPET_LEN = 80

# ---------------------------------------------------------------------------
# Domain: turn segmentation (pure functions over parsed JSONL records)
# ---------------------------------------------------------------------------


def _content_blocks(rec: dict) -> list:
    """Normalize a record's message.content into a list of block dicts."""
    msg = rec.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


# Wrapper tags that mark CLI side-channel messages (slash commands, bash `!`
# runs, injected reminders) — these are NOT real user prompts.
_SIDE_CHANNEL_TAGS = (
    "<bash-input>", "<bash-stdout>", "<bash-stderr>",
    "<system-reminder>", "<command-message>", "<command-name>",
    "<command-args>", "<local-command-stdout>", "<local-command-caveat>",
)


def is_side_channel(text: str) -> bool:
    """True if a user string message is a CLI side-channel, not a typed prompt."""
    s = text.lstrip()
    return s.startswith(_SIDE_CHANNEL_TAGS)


def is_turn_boundary(rec: dict) -> bool:
    """A 'real' user prompt that starts a new turn.

    Excludes meta records, tool_result-carrier user messages (those belong to
    the in-flight turn), and CLI side-channel messages (slash-command wrappers,
    bash `!` input/output, injected system reminders).
    """
    if rec.get("type") != "user" or rec.get("isMeta"):
        return False
    msg = rec.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content.strip() != "" and not is_side_channel(content)
    if isinstance(content, list):
        has_text = any(isinstance(b, dict) and b.get("type") == "text" for b in content)
        has_tool_result = any(
            isinstance(b, dict) and b.get("type") == "tool_result" for b in content
        )
        if not (has_text and not has_tool_result):
            return False
        # Exclude if the only text is a side-channel wrapper.
        joined = " ".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
        return not is_side_channel(joined)
    return False


def _prompt_text(rec: dict) -> str:
    msg = rec.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


@dataclass
class TurnBuf:
    """Accumulator for a single turn, spanning many JSONL records."""

    n: int
    prompt: str = ""
    ts: str = ""
    branch: str = ""
    cwd: str = ""
    model: str = ""
    recap: str = ""
    blocks: list[dict] = field(default_factory=list)
    # map tool_use_id -> index into blocks, to attach results later
    _tool_index: dict[str, int] = field(default_factory=dict)
    # structured results keyed by tool_use_id (from top-level toolUseResult)
    _structured: dict[str, Any] = field(default_factory=dict)

    def absorb(self, rec: dict) -> None:
        rtype = rec.get("type")
        if rtype == "assistant":
            msg = rec.get("message") or {}
            if not self.model and msg.get("model"):
                self.model = msg["model"]
        if not self.ts and rec.get("timestamp"):
            self.ts = rec["timestamp"]
        if not self.branch and rec.get("gitBranch"):
            self.branch = rec["gitBranch"]
        if not self.cwd and rec.get("cwd"):
            self.cwd = rec["cwd"]

        # Capture the per-turn recap (away_summary system record).
        if rtype == "system" and rec.get("subtype") == "away_summary":
            content = (rec.get("content") or "").strip()
            # Strip the trailing "(disable recaps in /config)" hint.
            content = re.sub(r"\s*\(disable recaps in /config\)\s*$", "", content)
            if content:
                self.recap = content

        # Stash any structured tool result for later attachment.
        tur = rec.get("toolUseResult")
        if tur is not None:
            # The result record references the tool via tool_result block id.
            for b in _content_blocks(rec):
                if b.get("type") == "tool_result" and b.get("tool_use_id"):
                    self._structured[b["tool_use_id"]] = tur

        if rtype not in ("assistant", "user"):
            return

        # A user string message that is a CLI side-channel (bash !, reminders,
        # slash-command wrappers) contributes no blocks.
        if rtype == "user":
            content = (rec.get("message") or {}).get("content")
            if isinstance(content, str) and is_side_channel(content):
                return

        for b in _content_blocks(rec):
            bt = b.get("type")
            if bt == "text":
                txt = b.get("text", "")
                # Only assistant text becomes a block. User text is the prompt
                # itself (already shown in the prompt header) — avoid duplicating it.
                if txt.strip() and rtype == "assistant":
                    self.blocks.append({"k": "text", "md": txt})
            elif bt == "thinking":
                self.blocks.append({"k": "thinking", "text": b.get("thinking", "")})
            elif bt == "tool_use":
                self._tool_index[b.get("id", "")] = len(self.blocks)
                self.blocks.append(
                    {
                        "k": "tool",
                        "name": b.get("name", "tool"),
                        "input": b.get("input", {}),
                        "result": None,
                        "resultStructured": None,
                    }
                )
            elif bt == "tool_result":
                tid = b.get("tool_use_id", "")
                idx = self._tool_index.get(tid)
                content = b.get("content")
                if idx is not None:
                    self.blocks[idx]["result"] = content
                    if tid in self._structured:
                        self.blocks[idx]["resultStructured"] = self._structured[tid]
                else:
                    # orphan result (tool_use was in a prior, already-flushed turn)
                    self.blocks.append(
                        {
                            "k": "tool",
                            "name": "(result)",
                            "input": None,
                            "result": content,
                            "resultStructured": self._structured.get(tid),
                        }
                    )

    def counts(self) -> dict:
        c = {"thinking": 0, "tool": 0, "text": 0}
        for b in self.blocks:
            if b["k"] in c:
                c[b["k"]] += 1
        return c

    def to_obj(self) -> dict:
        prompt = self.prompt.strip().replace("\n", " ")
        snippet = prompt[:PROMPT_SNIPPET_LEN] + ("…" if len(prompt) > PROMPT_SNIPPET_LEN else "")
        return {
            "n": self.n,
            "ts": self.ts,
            "prompt": prompt,
            "snippet": snippet or f"(turn {self.n})",
            "branch": self.branch,
            "cwd": self.cwd,
            "model": self.model,
            "recap": self.recap,
            "blocks": self.blocks,
            "counts": self.counts(),
        }


# ---------------------------------------------------------------------------
# IO: incremental state + append-only emit
# ---------------------------------------------------------------------------


def resolve_transcript(arg: str) -> Path:
    """Accept a path, or a sessionId to be found under ~/.claude/projects/."""
    p = Path(arg).expanduser()
    if p.is_file():
        return p
    # search projects for <sessionId>.jsonl
    matches = list(PROJECTS_DIR.glob(f"*/{arg}.jsonl"))
    if matches:
        # newest if multiple
        return max(matches, key=lambda m: m.stat().st_mtime)
    raise FileNotFoundError(f"No transcript for: {arg}")


def session_id_of(transcript: Path) -> str:
    return transcript.stem


def encode_project_dir(cwd: Path) -> str:
    """Claude stores transcripts under ~/.claude/projects/<encoded-cwd>/, where the
    cwd path has every '/' (and '.') replaced by '-'."""
    return str(cwd).replace("/", "-").replace(".", "-")


def newest_transcript_for_cwd(cwd: Path) -> Path:
    """Find the most recently modified transcript for the given working directory."""
    proj = PROJECTS_DIR / encode_project_dir(cwd)
    candidates = list(proj.glob("*.jsonl")) if proj.is_dir() else []
    if not candidates:
        raise FileNotFoundError(f"No transcripts found for cwd: {cwd} (looked in {proj})")
    return max(candidates, key=lambda m: m.stat().st_mtime)


def open_in_browser(path: Path) -> None:
    import subprocess
    if sys.platform == "darwin":
        subprocess.run(["open", str(path)], check=False)
    elif sys.platform.startswith("linux"):
        subprocess.run(["xdg-open", str(path)], check=False)
    else:
        import webbrowser
        webbrowser.open(path.as_uri())


def load_state(out_dir: Path) -> dict:
    sf = out_dir / "state.json"
    if sf.is_file():
        return json.loads(sf.read_text())
    return {
        "offset_bytes": 0,
        "turns_emitted": 0,
        "open_turn": None,  # serialized TurnBuf-in-progress
        "next_n": 1,
    }


def save_state(out_dir: Path, state: dict) -> None:
    (out_dir / "state.json").write_text(json.dumps(state, ensure_ascii=False))


def _buf_from_state(d: dict | None) -> TurnBuf | None:
    if not d:
        return None
    b = TurnBuf(n=d["n"])
    b.prompt = d.get("prompt", "")
    b.ts = d.get("ts", "")
    b.branch = d.get("branch", "")
    b.cwd = d.get("cwd", "")
    b.model = d.get("model", "")
    b.recap = d.get("recap", "")
    b.blocks = d.get("blocks", [])
    b._tool_index = d.get("_tool_index", {})
    b._structured = d.get("_structured", {})
    return b


def _buf_to_state(b: TurnBuf | None) -> dict | None:
    if b is None:
        return None
    return {
        "n": b.n,
        "prompt": b.prompt,
        "ts": b.ts,
        "branch": b.branch,
        "cwd": b.cwd,
        "model": b.model,
        "recap": b.recap,
        "blocks": b.blocks,
        "_tool_index": b._tool_index,
        "_structured": b._structured,
    }


def read_new_records(transcript: Path, offset: int) -> tuple[list[dict], int]:
    """Read JSONL records starting at byte offset; return (records, new_offset).

    Only consumes complete lines; a trailing partial line leaves the offset at
    its start so it is re-read once complete.
    """
    records: list[dict] = []
    with open(transcript, "rb") as f:
        f.seek(offset)
        data = f.read()
    # Keep offset at the start of any trailing partial line.
    consumed = len(data)
    if data and not data.endswith(b"\n"):
        last_nl = data.rfind(b"\n")
        if last_nl == -1:
            return [], offset  # no complete line yet
        consumed = last_nl + 1
        data = data[:consumed]
    for line in data.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records, offset + consumed


def append_turns(out_dir: Path, objs: Iterable[dict]) -> int:
    """Append finalized turn objects to turns.js. Returns count appended."""
    n = 0
    with open(out_dir / "turns.js", "a", encoding="utf-8") as f:
        for obj in objs:
            f.write("window.__TURNS__.push(")
            f.write(json.dumps(obj, ensure_ascii=False))
            f.write(");\n")
            n += 1
    return n


def write_pending(out_dir: Path, open_buf: "TurnBuf | None") -> None:
    """Overwrite pending.js with the single in-progress turn (or nothing).

    Distinct from turns.js: this file is rewritten every run, so re-running can
    never duplicate the current turn. The viewer concatenates pending onto the
    finalized turns."""
    pj = out_dir / "pending.js"
    if open_buf is None:
        pj.write_text("window.__PENDING__ = null;\n", encoding="utf-8")
        return
    pj.write_text(
        "window.__PENDING__ = " + json.dumps(open_buf.to_obj(), ensure_ascii=False) + ";\n",
        encoding="utf-8",
    )


def write_shared_assets() -> str:
    """Write the shared style.css, theme.css and app.js. Rewritten every run so
    edits to CSS/JS or a WezTerm theme switch propagate to all sessions at once.
    Returns the resolved scheme name."""
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    theme, scheme_name = resolve_theme()
    (ASSETS_DIR / "theme.css").write_text(
        THEME_CSS.replace("__THEME_VARS__", theme_css_vars(theme)), encoding="utf-8"
    )
    (ASSETS_DIR / "style.css").write_text(STYLE_CSS, encoding="utf-8")
    (ASSETS_DIR / "app.js").write_text(APP_JS, encoding="utf-8")
    return scheme_name


def ensure_scaffold(out_dir: Path, session_id: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    write_shared_assets()  # shared assets refreshed every run
    tj = out_dir / "turns.js"
    if not tj.exists():
        tj.write_text("window.__TURNS__ = window.__TURNS__ || [];\n", encoding="utf-8")
    pj = out_dir / "pending.js"
    if not pj.exists():
        pj.write_text("window.__PENDING__ = null;\n", encoding="utf-8")
    idx = out_dir / "index.html"
    if not idx.exists():
        # Skeleton is write-once; it only references the shared assets.
        idx.write_text(INDEX_HTML.replace("__SESSION_ID__", session_id), encoding="utf-8")


def build_bundle(out_dir: Path, session_id: str, dest: Path) -> Path:
    """Inline theme.css, style.css, the session's turns.js data, and app.js into
    a single self-contained HTML file at `dest`. Portable — no sibling assets."""
    theme, _ = resolve_theme()
    theme_css = THEME_CSS.replace("__THEME_VARS__", theme_css_vars(theme))
    turns_js = (out_dir / "turns.js").read_text(encoding="utf-8") if (out_dir / "turns.js").exists() else "window.__TURNS__=[];"
    pending_js = (out_dir / "pending.js").read_text(encoding="utf-8") if (out_dir / "pending.js").exists() else "window.__PENDING__=null;"

    # When inlining JS, any literal "</script>" inside string data (e.g. a
    # transcript discussing HTML) would close the inline <script> early. Escape
    # the sequence; the JS string value is unchanged ("<\/script>" === "</script>").
    def safe_js(s: str) -> str:
        return s.replace("</", "<\\/")

    html = (
        INDEX_HTML.replace("__SESSION_ID__", session_id)
        .replace(
            '<link rel="stylesheet" href="../../assets/theme.css">',
            f"<style>\n{theme_css}\n{STYLE_CSS}\n</style>",
        )
        .replace('<link rel="stylesheet" href="../../assets/style.css">', "")
        .replace(
            '<script src="turns.js"></script>',
            f"<script>\n{safe_js(turns_js)}</script>",
        )
        .replace(
            '<script src="pending.js"></script>',
            f"<script>\n{safe_js(pending_js)}</script>",
        )
        .replace(
            '<script src="../../assets/app.js"></script>',
            f"<script>\n{safe_js(APP_JS)}</script>",
        )
    )
    dest.write_text(html, encoding="utf-8")
    return dest


def process(transcript: Path, flush: bool = False) -> dict:
    """Core incremental step. Returns a small summary dict."""
    session_id = session_id_of(transcript)
    out_dir = OUT_ROOT / session_id
    ensure_scaffold(out_dir, session_id)
    state = load_state(out_dir)

    records, new_offset = read_new_records(transcript, state["offset_bytes"])

    open_buf = _buf_from_state(state.get("open_turn"))
    next_n = state.get("next_n", 1)
    finalized: list[dict] = []

    for rec in records:
        if is_turn_boundary(rec):
            if open_buf is not None:
                finalized.append(open_buf.to_obj())
            open_buf = TurnBuf(n=next_n)
            next_n += 1
            open_buf.prompt = _prompt_text(rec)
            open_buf.absorb(rec)
        elif open_buf is not None:
            open_buf.absorb(rec)
        # records before the first real prompt (session meta) are ignored

    # Finalized turns are appended to turns.js — append-only and immutable.
    appended = append_turns(out_dir, finalized) if finalized else 0

    # The in-progress (not-yet-finalized) turn is written to a SEPARATE file
    # that is OVERWRITTEN each run — never appended — so repeated runs (e.g.
    # several `html` invocations) can never duplicate the current turn.
    # `flush` is retained for API compatibility but no longer affects output:
    # the open turn is always shown, sourced from pending.js.
    write_pending(out_dir, open_buf)

    state["offset_bytes"] = new_offset
    state["turns_emitted"] = state.get("turns_emitted", 0) + appended
    state["open_turn"] = _buf_to_state(open_buf)
    state["next_n"] = next_n
    save_state(out_dir, state)

    return {
        "session_id": session_id,
        "out_dir": str(out_dir),
        "index": str(out_dir / "index.html"),
        "appended": appended,
        "turns_total": state["turns_emitted"],
        "offset": new_offset,
    }


# ---------------------------------------------------------------------------
# Theme: resolve the WezTerm color scheme into CSS variables.
# ---------------------------------------------------------------------------

WEZTERM_CONFIG_CANDIDATES = [
    HOME / ".config" / "wezterm" / "wezterm.lua",
    HOME / ".wezterm.lua",
]

# Bundled palettes for builtin schemes we can't query without the wezterm CLI.
# (ansi order: black,red,green,yellow,blue,magenta,cyan,white)
BUILTIN_SCHEMES: dict[str, dict] = {
    "Horizon Dark (Gogh)": {
        "background": "#1C1E26", "foreground": "#FDF0ED", "cursor_bg": "#FDF0ED",
        "selection_bg": "#2E303E",
        "ansi": ["#16161C", "#E95678", "#29D398", "#FAB795", "#26BBD9", "#EE64AE", "#59E3E3", "#FADAD1"],
        "brights": ["#232530", "#EC6A88", "#3FDAA4", "#FBC3A7", "#3FC6DE", "#F075B7", "#6BE6E6", "#FDF0ED"],
    },
}

# Final fallback if nothing resolves (the original GitHub-dark palette).
DEFAULT_THEME = {
    "bg": "#0d1117", "panel": "#161b22", "panel2": "#1c232c", "border": "#30363d",
    "fg": "#e6edf3", "muted": "#8b949e", "accent": "#58a6ff", "accent2": "#7ee787",
    "user": "#1f6feb", "think": "#a371f7", "tool": "#d29922",
    "json_key": "#7ee787", "json_str": "#a5d6ff", "json_num": "#79c0ff", "json_bool": "#ff7b72",
    "scrollthumb": "#30363d", "scrollthumb_hover": "#484f58",
}


def _read_active_scheme_name(text: str) -> str | None:
    m = re.search(r'^\s*config\.color_scheme\s*=\s*[\'"]([^\'"]+)[\'"]', text, re.MULTILINE)
    return m.group(1) if m else None


def _parse_inline_scheme(text: str, name: str) -> dict | None:
    """Parse an inline `['Name'] = { background='#..', ansi={...}, ... }` block."""
    key = re.escape(name)
    m = re.search(r"\[\s*['\"]" + key + r"['\"]\s*\]\s*=\s*\{", text)
    if not m:
        return None
    # Walk braces to find the block end.
    start = m.end() - 1
    depth, i = 0, start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    block = text[start : i + 1]

    def field(fname: str) -> str | None:
        fm = re.search(fname + r"\s*=\s*['\"](#[0-9a-fA-F]{3,8})['\"]", block)
        return fm.group(1) if fm else None

    def arr(fname: str) -> list[str]:
        am = re.search(fname + r"\s*=\s*\{([^}]*)\}", block)
        if not am:
            return []
        return re.findall(r"['\"](#[0-9a-fA-F]{3,8})['\"]", am.group(1))

    sc = {
        "background": field("background"),
        "foreground": field("foreground"),
        "cursor_bg": field("cursor_bg"),
        "selection_bg": field("selection_bg"),
        "ansi": arr("ansi"),
        "brights": arr("brights"),
    }
    return sc if sc["background"] else None


def _mix(hex1: str, hex2: str, t: float) -> str:
    """Linear blend of two #rrggbb colors; t=0 -> hex1, t=1 -> hex2."""
    def rgb(h):
        h = h.lstrip("#")
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))
    a, b = rgb(hex1), rgb(hex2)
    c = tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))
    return "#%02x%02x%02x" % c


def _scheme_to_theme(sc: dict) -> dict:
    """Map a WezTerm scheme (bg/fg/ansi/brights) onto our CSS variable names."""
    bg = sc.get("background") or "#0d1117"
    fg = sc.get("foreground") or "#e6edf3"
    ansi = sc.get("ansi") or []
    br = sc.get("brights") or ansi
    def a(i, default):
        return (ansi[i] if i < len(ansi) else None) or default
    def b(i, default):
        return (br[i] if i < len(br) else None) or default
    # ansi: 0 black,1 red,2 green,3 yellow,4 blue,5 magenta,6 cyan,7 white
    accent = b(4, "#58a6ff")     # bright blue
    accent2 = b(2, "#7ee787")    # bright green
    return {
        "bg": bg,
        "panel": _mix(bg, fg, 0.05),
        "panel2": _mix(bg, fg, 0.10),
        "border": _mix(bg, fg, 0.16),
        "fg": fg,
        "muted": _mix(bg, fg, 0.55),
        "accent": accent,
        "accent2": accent2,
        "user": a(4, "#1f6feb"),
        "think": b(5, "#a371f7"),   # magenta
        "tool": a(3, "#d29922"),    # yellow
        "json_key": b(2, "#7ee787"),
        "json_str": b(6, "#a5d6ff"),  # cyan
        "json_num": b(4, "#79c0ff"),
        "json_bool": a(1, "#ff7b72"),  # red
        "scrollthumb": _mix(bg, fg, 0.20),
        "scrollthumb_hover": _mix(bg, fg, 0.38),
    }


def resolve_theme() -> tuple[dict, str]:
    """Return (theme_vars, scheme_name). Reads the WezTerm config; parses an
    inline scheme, else a bundled builtin, else the default palette."""
    for cfg in WEZTERM_CONFIG_CANDIDATES:
        if not cfg.is_file():
            continue
        try:
            text = cfg.read_text(errors="ignore")
        except OSError:
            continue
        name = _read_active_scheme_name(text)
        if not name:
            continue
        sc = _parse_inline_scheme(text, name) or BUILTIN_SCHEMES.get(name)
        if sc:
            return _scheme_to_theme(sc), name
        return DEFAULT_THEME, name + " (unresolved)"
    return DEFAULT_THEME, "default"


def theme_css_vars(theme: dict) -> str:
    return (
        f"--bg:{theme['bg']}; --panel:{theme['panel']}; --panel2:{theme['panel2']}; "
        f"--border:{theme['border']}; --fg:{theme['fg']}; --muted:{theme['muted']}; "
        f"--accent:{theme['accent']}; --accent2:{theme['accent2']}; --user:{theme['user']}; "
        f"--think:{theme['think']}; --tool:{theme['tool']}; --json-key:{theme['json_key']}; "
        f"--json-str:{theme['json_str']}; --json-num:{theme['json_num']}; --json-bool:{theme['json_bool']}; "
        f"--scrollthumb:{theme['scrollthumb']}; --scrollthumb-hover:{theme['scrollthumb_hover']};"
    )


# ---------------------------------------------------------------------------
# Viewer (single self-contained HTML; CSS + JS inline; no network deps)
# ---------------------------------------------------------------------------

# Per-session markup skeleton. Tiny + write-once. Links the SHARED assets
# (theme.css, style.css, app.js) that live one directory up and are rewritten
# on every run, so editing CSS/JS or switching themes updates all sessions.
INDEX_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Transcript · __SESSION_ID__</title>
<link rel="stylesheet" href="../../assets/theme.css">
<link rel="stylesheet" href="../../assets/style.css">
</head>
<body>
<header>
  <button class="hamburger" id="toggleSide" title="Toggle turns sidebar">☰</button>
  <span class="title">Transcript</span>
  <span class="meta" id="hmeta"></span>
  <span class="spacer"></span>
  <span class="nav">
    <button id="first">⤒ First</button>
    <button id="prev">‹ Prev</button>
    <span class="counter" id="counter">– / –</span>
    <button id="next">Next ›</button>
    <button id="last">Last ⤓</button>
  </span>
</header>
<aside class="side">
  <div class="side-title">Turns</div>
  <div id="turnlist"></div>
</aside>
<main id="main"></main>
<aside class="toc">
  <div class="toc-title">In this turn</div>
  <div id="toc"></div>
</aside>

<script src="turns.js"></script>
<script src="pending.js"></script>
<script src="../../assets/app.js"></script>
</body>
</html>
"""

# Theme CSS: the :root variables, regenerated from the WezTerm scheme each run.
THEME_CSS = r""":root {
  __THEME_VARS__
  --mono:"SFMono-Regular",ui-monospace,"JetBrains Mono",Menlo,Consolas,monospace;
}
"""

# Structural CSS: shared across all sessions, rewritten each run.
STYLE_CSS = r"""  * { box-sizing:border-box; }
  html,body { margin:0; height:100%; }

  /* Scrollbars */
  * { scrollbar-width:thin; scrollbar-color:var(--scrollthumb) transparent; }
  ::-webkit-scrollbar { width:10px; height:10px; }
  ::-webkit-scrollbar-track { background:transparent; }
  ::-webkit-scrollbar-thumb { background:var(--scrollthumb); border-radius:6px;
    border:2px solid transparent; background-clip:padding-box; }
  ::-webkit-scrollbar-thumb:hover { background:var(--scrollthumb-hover); background-clip:padding-box; }
  ::-webkit-scrollbar-corner { background:transparent; }
  body {
    background:var(--bg); color:var(--fg); font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    display:grid; grid-template-columns:260px 1fr 250px; grid-template-rows:auto 1fr;
    grid-template-areas:"top top top" "side main toc"; height:100vh; overflow:hidden;
    transition:grid-template-columns .15s ease;
  }
  body.side-collapsed { grid-template-columns:0 1fr 250px; }
  header {
    grid-area:top; display:flex; align-items:center; gap:14px; padding:10px 16px;
    background:var(--panel); border-bottom:1px solid var(--border); z-index:5;
  }
  .hamburger {
    background:var(--panel2); color:var(--fg); border:1px solid var(--border); border-radius:6px;
    padding:6px 10px; font-size:14px; cursor:pointer; line-height:1;
  }
  .hamburger:hover { border-color:var(--accent); color:var(--accent); }
  header .title { font-weight:600; font-size:14px; }
  header .meta { color:var(--muted); font-size:12px; font-family:var(--mono); }
  header .spacer { flex:1; }
  .nav button {
    background:var(--panel2); color:var(--fg); border:1px solid var(--border);
    border-radius:6px; padding:6px 12px; font-size:13px; cursor:pointer; margin-left:6px;
  }
  .nav button:hover:not(:disabled) { border-color:var(--accent); color:var(--accent); }
  .nav button:disabled { opacity:.35; cursor:default; }
  .counter { font-family:var(--mono); font-size:13px; color:var(--muted); min-width:78px; text-align:center; }

  main { grid-area:main; overflow-y:auto; padding:22px 28px 80px; }
  .turn-head { margin-bottom:18px; }
  .prompt {
    background:color-mix(in srgb, var(--user) 12%, var(--panel)); border:1px solid color-mix(in srgb, var(--user) 35%, var(--border));
    border-left:3px solid var(--user); border-radius:8px; padding:14px 16px;
    white-space:pre-wrap; word-break:break-word; font-size:14px; line-height:1.5;
  }
  .prompt .lbl { color:var(--accent); font-size:11px; font-weight:600; letter-spacing:.06em;
    text-transform:uppercase; display:block; margin-bottom:6px; }

  .block { margin:12px 0; border:1px solid var(--border); border-radius:8px; overflow:hidden; background:var(--panel); }
  .block.text { border:none; background:none; padding:2px 2px; }
  .text-body { font-size:14px; line-height:1.62; }
  .text-body h1,.text-body h2,.text-body h3 { margin:.7em 0 .35em; line-height:1.25; }
  .text-body h1 { font-size:1.35em; } .text-body h2 { font-size:1.2em; } .text-body h3 { font-size:1.05em; }
  .text-body p { margin:.5em 0; } .text-body ul,.text-body ol { margin:.4em 0 .4em 1.4em; }
  .text-body li { margin:.2em 0; }
  .text-body a { color:var(--accent); }
  .text-body code { background:var(--panel2); padding:.12em .4em; border-radius:4px; font-family:var(--mono); font-size:.88em; }
  .text-body pre { background:color-mix(in srgb, var(--bg) 80%, #000); border:1px solid var(--border); border-radius:8px; padding:12px 14px;
    overflow-x:auto; } .text-body pre code { background:none; padding:0; }

  details.coll { border-radius:8px; }
  details.coll > summary {
    list-style:none; cursor:pointer; padding:10px 14px; display:flex; align-items:center; gap:10px;
    font-size:13px; user-select:none;
  }
  details.coll > summary::-webkit-details-marker { display:none; }
  details.coll > summary::before {
    content:"▶"; font-size:9px; color:var(--muted); transition:transform .12s; display:inline-block;
  }
  details.coll[open] > summary::before { transform:rotate(90deg); }
  .badge { font-family:var(--mono); font-size:10px; padding:1px 7px; border-radius:10px; font-weight:600; letter-spacing:.04em; }
  .badge.think { background:color-mix(in srgb, var(--think) 15%, transparent); color:var(--think); border:1px solid color-mix(in srgb, var(--think) 40%, transparent); }
  .badge.tool  { background:color-mix(in srgb, var(--tool) 15%, transparent);  color:var(--tool);  border:1px solid color-mix(in srgb, var(--tool) 40%, transparent); }
  /* Marker for an action that was preceded by (omitted) thinking.
     Sits in the left gutter (absolute) so it never consumes its own line. */
  .think-mark { color:var(--think); font-size:11px; flex-shrink:0; cursor:help;
    text-shadow:0 0 6px color-mix(in srgb, var(--think) 60%, transparent); }
  .block.text { position:relative; }
  .block.text > .think-mark { position:absolute; left:-16px; top:3px; }
  /* In a tool summary the marker is inline-trailing; spacer pushes it right. */
  .spacer-mark { flex:1; }
  .sum-name { font-family:var(--mono); color:var(--fg); }
  .sum-extra { color:var(--muted); font-family:var(--mono); font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  details.think { background:color-mix(in srgb, var(--think) 6%, transparent); border-color:color-mix(in srgb, var(--think) 25%, transparent); }
  details.tool  { background:color-mix(in srgb, var(--tool) 5%, transparent); border-color:color-mix(in srgb, var(--tool) 22%, transparent); }
  .block-body { padding:4px 14px 14px; }
  .think-text { white-space:pre-wrap; font-family:var(--mono); font-size:12.5px; line-height:1.55; color:color-mix(in srgb, var(--think) 55%, var(--fg)); }

  .sub { margin:8px 0; border:1px solid var(--border); border-radius:6px; background:var(--panel2); }
  .sub > summary { padding:7px 12px; font-size:12px; color:var(--muted); }
  .sub-body { padding:6px 12px 10px; }
  pre.raw { white-space:pre-wrap; word-break:break-word; font-family:var(--mono); font-size:12px;
    line-height:1.5; margin:0; color:color-mix(in srgb, var(--fg) 88%, var(--bg)); max-height:480px; overflow:auto; }

  /* JSON tree */
  .jt { font-family:var(--mono); font-size:12.5px; line-height:1.55; }
  .jt details { margin:0; }
  .jt details > summary { list-style:none; cursor:pointer; }
  .jt details > summary::-webkit-details-marker { display:none; }
  .jt details > summary::before { content:"▶"; font-size:8px; color:var(--muted); margin-right:6px; display:inline-block; transition:transform .1s; }
  .jt details[open] > summary::before { transform:rotate(90deg); }
  .jt .ind { padding-left:16px; border-left:1px solid var(--border); margin-left:4px; }
  .jt .k { color:var(--json-key); }
  .jt .s { color:var(--json-str); white-space:pre-wrap; word-break:break-word; }
  .jt .n { color:var(--json-num); }
  .jt .b { color:var(--json-bool); }
  .jt .muted { color:var(--muted); }

  /* Recap box */
  .recap {
    background:color-mix(in srgb, var(--accent2) 9%, var(--panel)); border:1px solid color-mix(in srgb, var(--accent2) 35%, var(--border));
    border-left:3px solid var(--accent2); border-radius:8px; padding:12px 15px; margin-bottom:16px;
    font-size:13.5px; line-height:1.55; color:color-mix(in srgb, var(--accent2) 25%, var(--fg));
  }
  .recap .lbl { color:var(--accent2); font-size:10.5px; font-weight:700; letter-spacing:.08em;
    text-transform:uppercase; display:flex; align-items:center; gap:6px; margin-bottom:6px; }

  /* Left sidebar: list of turns (collapsible) */
  aside.side { grid-area:side; background:var(--panel); border-right:1px solid var(--border);
    overflow-y:auto; overflow-x:hidden; padding:10px 8px; }
  body.side-collapsed aside.side { display:none; }
  .side-title { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.08em; padding:4px 8px 8px; }
  .trow { display:block; width:100%; text-align:left; background:none; border:1px solid transparent;
    border-radius:6px; padding:8px 9px; cursor:pointer; margin-bottom:4px; color:var(--fg); }
  .trow:hover { background:var(--panel2); }
  .trow.active { background:color-mix(in srgb, var(--accent) 16%, var(--panel)); border-color:color-mix(in srgb, var(--accent) 45%, var(--border)); }
  .trow .mn { font-family:var(--mono); font-size:11px; color:var(--accent); }
  .trow .msnip { font-size:11.5px; color:var(--muted); margin:3px 0 5px; line-height:1.35;
    display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; }
  .trow .micons { display:flex; gap:8px; font-size:10px; font-family:var(--mono); color:var(--muted); }
  .trow .micons .i { display:inline-flex; align-items:center; gap:2px; }

  /* Right: table of contents WITHIN the current turn */
  aside.toc { grid-area:toc; background:var(--panel); border-left:1px solid var(--border);
    overflow-y:auto; padding:10px 8px; }
  .toc-title { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.08em; padding:4px 8px 8px; }
  .toc-item { display:flex; align-items:center; gap:8px; width:100%; text-align:left; background:none;
    border:none; border-left:2px solid transparent; border-radius:0 4px 4px 0; padding:6px 8px;
    cursor:pointer; color:var(--muted); font-size:12px; }
  .toc-item:hover { background:var(--panel2); color:var(--fg); }
  .toc-item.active { color:var(--fg); border-left-color:var(--accent); background:color-mix(in srgb, var(--accent) 8%, transparent); }
  .toc-item .dot { width:7px; height:7px; border-radius:50%; flex-shrink:0; margin-top:5px; align-self:flex-start; }
  .toc-item .dot.think { background:var(--think); }
  .toc-item .dot.tool { background:var(--tool); }
  .toc-item .dot.text { background:var(--accent); }
  .toc-item { align-items:flex-start; }
  .tmeta { display:flex; flex-direction:column; gap:1px; overflow:hidden; }
  .toc-item .tlabel { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:var(--mono); font-size:11.5px; color:var(--fg); }
  .toc-item .tsub { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:10.5px; color:var(--muted); }
  .empty { color:var(--muted); padding:40px; text-align:center; font-size:14px; }
  .scroll-target { scroll-margin-top:14px; }
"""

# Viewer logic: shared across all sessions, rewritten each run.
APP_JS = r"""// Finalized turns (append-only) plus the single in-progress turn (overwritten
// each run), if present and not already finalized.
const TURNS = (window.__TURNS__ || []).slice();
if (window.__PENDING__ && !TURNS.some(t => t.n === window.__PENDING__.n)) {
  TURNS.push(window.__PENDING__);
}
let cur = 0;
const $ = (id) => document.getElementById(id);

// ---- escaping ----
const esc = (s) => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// ---- markdown-lite ----
function inline(s){
  s = esc(s);
  s = s.replace(/`([^`]+)`/g, (_,c)=>`<code>${c}</code>`);
  s = s.replace(/\*\*([^*]+)\*\*/g, (_,c)=>`<strong>${c}</strong>`);
  s = s.replace(/(?<![*])\*([^*\n]+)\*(?![*])/g, (_,c)=>`<em>${c}</em>`);
  s = s.replace(/\[([^\]]+)\]\((https?:[^)]+)\)/g, (_,t,u)=>`<a href="${u}" target="_blank" rel="noopener">${t}</a>`);
  return s;
}
function markdown(src){
  const lines = String(src).split("\n");
  let out = [], i = 0;
  while (i < lines.length){
    let ln = lines[i];
    // fenced code
    const fence = ln.match(/^```(\w*)\s*$/);
    if (fence){
      let buf = []; i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])){ buf.push(lines[i]); i++; }
      i++; // closing fence
      out.push(`<pre><code>${esc(buf.join("\n"))}</code></pre>`);
      continue;
    }
    const h = ln.match(/^(#{1,6})\s+(.*)$/);
    if (h){ const lv=h[1].length; out.push(`<h${lv}>${inline(h[2])}</h${lv}>`); i++; continue; }
    // unordered list
    if (/^\s*[-*]\s+/.test(ln)){
      let items=[];
      while (i<lines.length && /^\s*[-*]\s+/.test(lines[i])){ items.push(`<li>${inline(lines[i].replace(/^\s*[-*]\s+/,''))}</li>`); i++; }
      out.push(`<ul>${items.join("")}</ul>`); continue;
    }
    // ordered list
    if (/^\s*\d+\.\s+/.test(ln)){
      let items=[];
      while (i<lines.length && /^\s*\d+\.\s+/.test(lines[i])){ items.push(`<li>${inline(lines[i].replace(/^\s*\d+\.\s+/,''))}</li>`); i++; }
      out.push(`<ol>${items.join("")}</ol>`); continue;
    }
    if (ln.trim()===""){ i++; continue; }
    // paragraph (gather consecutive non-empty, non-special lines)
    let para=[ln]; i++;
    while (i<lines.length && lines[i].trim()!=="" && !/^(#{1,6}\s|```|\s*[-*]\s|\s*\d+\.\s)/.test(lines[i])){ para.push(lines[i]); i++; }
    out.push(`<p>${inline(para.join(" "))}</p>`);
  }
  return out.join("\n");
}

// ---- JSON tree ----
function jsonNode(val, key){
  const keyHtml = key!==undefined ? `<span class="k">${esc(key)}</span><span class="muted">: </span>` : "";
  if (val===null) return `<div>${keyHtml}<span class="muted">null</span></div>`;
  const t = typeof val;
  if (t==="string"){
    // Long / multi-line strings become their own collapsible node.
    if (val.length>140 || val.indexOf("\n")>=0){
      const firstLine = val.split("\n")[0];
      const preview = (firstLine.length>60?firstLine.slice(0,60)+"…":firstLine) || "…";
      const lc = val.split("\n").length;
      const meta = `<span class="muted"> str· ${val.length} ch${lc>1?` · ${lc} lines`:""}</span>`;
      return `<details><summary>${keyHtml}<span class="s">"${esc(preview)}"</span>${meta}</summary>`
        + `<div class="ind"><pre class="raw">${esc(val)}</pre></div></details>`;
    }
    return `<div>${keyHtml}<span class="s">"${esc(val)}"</span></div>`;
  }
  if (t==="number") return `<div>${keyHtml}<span class="n">${esc(val)}</span></div>`;
  if (t==="boolean") return `<div>${keyHtml}<span class="b">${val}</span></div>`;
  if (Array.isArray(val)){
    if (val.length===0) return `<div>${keyHtml}<span class="muted">[]</span></div>`;
    const open = val.length<=20 ? "open" : "";
    let kids = val.map((v,idx)=>jsonNode(v, idx)).join("");
    return `<details ${open}><summary>${keyHtml}<span class="muted">[${val.length}]</span></summary><div class="ind">${kids}</div></details>`;
  }
  if (t==="object"){
    const ks = Object.keys(val);
    if (ks.length===0) return `<div>${keyHtml}<span class="muted">{}</span></div>`;
    const open = ks.length<=20 ? "open" : "";
    let kids = ks.map(k=>jsonNode(val[k], k)).join("");
    return `<details ${open}><summary>${keyHtml}<span class="muted">{${ks.length}}</span></summary><div class="ind">${kids}</div></details>`;
  }
  return `<div>${keyHtml}<span class="muted">${esc(String(val))}</span></div>`;
}
function jsonTree(val){ return `<div class="jt">${jsonNode(val)}</div>`; }

// render a value that may be JSON-ish or a plain string
function valueBlock(label, val){
  if (val===null || val===undefined) return "";
  let parsed = val, isStruct = (typeof val==="object");
  if (typeof val==="string"){
    const s=val.trim();
    if ((s.startsWith("{")&&s.endsWith("}"))||(s.startsWith("[")&&s.endsWith("]"))){
      try { parsed = JSON.parse(s); isStruct=true; } catch(e){}
    }
  }
  const body = isStruct ? jsonTree(parsed) : `<pre class="raw">${esc(typeof val==="string"?val:JSON.stringify(val,null,2))}</pre>`;
  return `<details class="sub" open><summary>${esc(label)}</summary><div class="sub-body">${body}</div></details>`;
}

function argSummary(input){
  if (!input || typeof input!=="object") return "";
  const ks = Object.keys(input);
  if (!ks.length) return "";
  // prefer common single-string args
  for (const k of ["command","file_path","path","query","prompt","pattern","description"]){
    if (typeof input[k]==="string") { const v=input[k].replace(/\n/g," "); return v.length>70? v.slice(0,70)+"…" : v; }
  }
  return ks.join(", ");
}

// A short human annotation of what a tool call did, from its input.
function toolAnnotation(b){
  const inp = b.input || {};
  const base = (p)=>{ if(typeof p!=="string") return ""; const parts=p.split("/"); return parts[parts.length-1]||p; };
  switch (b.name){
    case "Bash": return inp.description || (inp.command? String(inp.command).split("\n")[0] : "");
    case "Read": return base(inp.file_path||inp.path||"");
    case "Edit": return base(inp.file_path||"");
    case "Write": return base(inp.file_path||"");
    case "Glob": return inp.pattern || "";
    case "Grep": return inp.pattern || "";
    case "Task": case "Agent": return inp.description || inp.subagent_type || "";
    case "TaskCreate": return inp.subject || "";
    case "TaskUpdate": return (inp.status? inp.status : "") + (inp.taskId? ` #${inp.taskId}` : "");
    case "AskUserQuestion": {
      const qs=inp.questions; if(Array.isArray(qs)&&qs.length) return qs[0].header || qs[0].question || `${qs.length} question(s)`; return "";
    }
    default: return inp.description || inp.title || "";
  }
}

// Each rendered block gets an anchor id + a TOC entry {kind, label, sub}.
function tocLabel(b, idx){
  if (b.k==="text") return {kind:"text", label:"Response", sub:""};
  if (b.k==="thinking") return {kind:"think", label:"Thinking", sub:""};
  if (b.k==="tool") return {kind:"tool", label:b.name||"Tool", sub:toolAnnotation(b)};
  return {kind:"text", label:"Block", sub:""};
}

// True if the block at index i was immediately preceded by a thinking block.
// (Thinking always directly precedes the action it reasoned about.)
function precededByThink(blocks, i){
  return i>0 && blocks[i-1] && blocks[i-1].k==="thinking";
}
const THINK_MARK = `<span class="think-mark" title="preceded by thinking">✦</span>`;

function renderBlock(b, idx, blocks){
  const aid = `b${idx}`;
  // Thinking blocks are not rendered in the main section at all; their presence
  // is surfaced as a marker on the action that follows.
  if (b.k==="thinking") return "";
  const thought = precededByThink(blocks, idx);
  const mark = thought ? THINK_MARK : "";
  if (b.k==="text") return `<div id="${aid}" class="block text scroll-target${thought?" thought":""}">${mark}<div class="text-body">${markdown(b.md)}</div></div>`;
  if (b.k==="tool"){
    const extra = argSummary(b.input);
    const res = (b.resultStructured!==null && b.resultStructured!==undefined) ? b.resultStructured : b.result;
    let body = "";
    if (b.input!==null && b.input!==undefined) body += valueBlock("Input", b.input);
    if (res!==null && res!==undefined) body += valueBlock("Result", res);
    if (!body) body = `<div class="muted" style="padding:6px 0">(no payload)</div>`;
    return `<details id="${aid}" class="block coll tool scroll-target"><summary><span class="badge tool">TOOL</span>`
      + `<span class="sum-name">${esc(b.name)}</span>`
      + (extra?`<span class="sum-extra">${esc(extra)}</span>`:"")
      + (mark?`<span class="spacer-mark"></span>${mark}`:"")
      + `</summary><div class="block-body">${body}</div></details>`;
  }
  return "";
}

function renderTurn(t){
  const main = $("main");
  if (!t){ main.innerHTML = `<div class="empty">No turns yet.</div>`; return; }
  let html = "";
  if (t.recap){
    html += `<div class="recap"><span class="lbl">✦ Recap</span>${esc(t.recap)}</div>`;
  }
  html += `<div class="turn-head"><div class="prompt"><span class="lbl">User · Turn ${t.n}</span>${esc(t.prompt)}</div></div>`;
  html += t.blocks.map((b,i)=>renderBlock(b,i,t.blocks)).join("");
  main.innerHTML = html;
  main.scrollTop = 0;
  const m = [];
  if (t.model) m.push(t.model.split("/").pop());
  if (t.branch) m.push("⌥ "+t.branch);
  if (t.ts) m.push(t.ts.replace("T"," ").replace(/\.\d+Z?$/,"").replace("Z",""));
  $("hmeta").textContent = m.join("   ");
  renderToc(t);
}

// Right column: a table of contents of the blocks WITHIN the current turn.
function renderToc(t){
  const toc = $("toc");
  if (!t || !t.blocks.length){ toc.innerHTML = `<div class="muted" style="padding:8px;font-size:12px">No blocks.</div>`; return; }
  toc.innerHTML = t.blocks.map((b,i)=>{
    // Thinking blocks are never listed; instead the action they precede is marked.
    if (b.k==="thinking") return "";
    const {kind,label,sub} = tocLabel(b,i);
    const subHtml = sub? `<span class="tsub">${esc(sub)}</span>` : "";
    const mark = precededByThink(t.blocks, i) ? `<span class="think-mark" title="preceded by thinking">✦</span>` : "";
    return `<button class="toc-item" data-aid="b${i}"><span class="dot ${kind}"></span>`
      + `<span class="tmeta"><span class="tlabel">${esc(label)}${mark}</span>${subHtml}</span></button>`;
  }).join("");
  toc.querySelectorAll(".toc-item").forEach(el=>{
    el.addEventListener("click", ()=>{
      const target = document.getElementById(el.dataset.aid);
      if (!target) return;
      if (target.tagName==="DETAILS") target.open = true;
      target.scrollIntoView({behavior:"smooth", block:"start"});
    });
  });
}

// Scrollspy: highlight the TOC entry for the block nearest the top of main.
// Matches by anchor id (data-aid), since some blocks have no TOC entry.
function syncTocActive(){
  const main = $("main");
  const blocks = [...main.querySelectorAll(".scroll-target")];
  if (!blocks.length) return;
  const top = main.scrollTop;
  let activeAid = blocks[0].id;
  blocks.forEach((el)=>{ if (el.offsetTop - 18 <= top) activeAid = el.id; });
  $("toc").querySelectorAll(".toc-item").forEach((el)=>el.classList.toggle("active", el.dataset.aid===activeAid));
}

function renderTurnList(){
  const list = $("turnlist");
  list.innerHTML = TURNS.map((t,idx)=>{
    const c = t.counts||{};
    const icons = [];
    if (c.thinking) icons.push(`<span class="i">🧠 ${c.thinking}</span>`);
    if (c.tool)     icons.push(`<span class="i">🔧 ${c.tool}</span>`);
    if (c.text)     icons.push(`<span class="i">¶ ${c.text}</span>`);
    return `<button class="trow ${idx===cur?'active':''}" data-i="${idx}">`
      + `<span class="mn">#${t.n}</span>`
      + `<div class="msnip">${esc(t.snippet||'')}</div>`
      + `<div class="micons">${icons.join("")}</div></button>`;
  }).join("");
  list.querySelectorAll(".trow").forEach(el=>{
    el.addEventListener("click", ()=>{ go(parseInt(el.dataset.i,10)); });
  });
  const active = list.querySelector(".trow.active");
  if (active) active.scrollIntoView({block:"nearest"});
}

function syncNav(){
  $("counter").textContent = TURNS.length ? `${cur+1} / ${TURNS.length}` : "– / –";
  $("first").disabled = $("prev").disabled = (cur<=0);
  $("last").disabled = $("next").disabled = (cur>=TURNS.length-1);
}

function go(i){
  if (!TURNS.length) { renderTurn(null); renderToc(null); syncNav(); return; }
  cur = Math.max(0, Math.min(TURNS.length-1, i));
  renderTurn(TURNS[cur]);
  renderTurnList();
  syncNav();
  syncTocActive();
}

$("first").onclick = ()=>go(0);
$("prev").onclick  = ()=>go(cur-1);
$("next").onclick  = ()=>go(cur+1);
$("last").onclick  = ()=>go(TURNS.length-1);
$("toggleSide").onclick = ()=>document.body.classList.toggle("side-collapsed");
$("main").addEventListener("scroll", syncTocActive, {passive:true});
document.addEventListener("keydown",(e)=>{
  if (e.target.tagName==="INPUT"||e.target.tagName==="TEXTAREA") return;
  if (e.key==="ArrowLeft"){ go(cur-1); }
  else if (e.key==="ArrowRight"){ go(cur+1); }
  else if (e.key==="Home"){ go(0); }
  else if (e.key==="End"){ go(TURNS.length-1); }
  else if (e.key==="["){ document.body.classList.toggle("side-collapsed"); }
});

renderTurnList();
go(TURNS.length ? TURNS.length-1 : 0);  // open on latest turn
"""


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    args = argv[1:]
    if not args:
        print(__doc__)
        return 0

    if args[0] in ("--current", "--open-current"):
        # Resolve the newest transcript for the cwd, refresh it, and open it.
        cwd_arg = args[1] if len(args) > 1 else os.getcwd()
        transcript = newest_transcript_for_cwd(Path(cwd_arg).expanduser())
        summary = process(transcript, flush=True)
        open_in_browser(Path(summary["index"]))
        print(summary["index"])
        return 0

    if args[0] == "--hook":
        raw = sys.stdin.read()
        try:
            payload = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            payload = {}
        tp = payload.get("transcript_path")
        if not tp:
            return 0  # nothing to do; never block the hook
        try:
            summary = process(Path(tp).expanduser())
            print(json.dumps(summary))
        except Exception as e:  # never fail a Stop hook
            print(f"transcript-html: {e}", file=sys.stderr)
        return 0

    flush = False
    open_only = False
    bundle_dest: str | None = None
    rest = []
    skip = set()
    for idx, a in enumerate(args):
        if idx in skip:
            continue
        if a in ("--flush", "-f"):
            flush = True
        elif a == "--open":
            open_only = True
        elif a == "--bundle":
            bundle_dest = ""  # signal: bundle, dest decided below
            # optional next arg is the destination path (if it isn't a flag)
            if idx + 1 < len(args) and not args[idx + 1].startswith("-"):
                bundle_dest = args[idx + 1]
                skip.add(idx + 1)
        else:
            rest.append(a)

    if not rest:
        print("usage: render.py <sessionId|path> [--flush] [--open] [--bundle [dest.html]]", file=sys.stderr)
        return 2

    transcript = resolve_transcript(rest[0])
    summary = process(transcript, flush=True if bundle_dest is not None else flush)

    if bundle_dest is not None:
        session_id = summary["session_id"]
        dest = Path(bundle_dest).expanduser() if bundle_dest else Path.cwd() / f"{session_id}-bundle.html"
        out = build_bundle(OUT_ROOT / session_id, session_id, dest)
        print(str(out))
        return 0

    if open_only:
        print(summary["index"])
    else:
        print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
