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
  render.py --rebuild <session>   discard turns.js + state, re-render from 0
  render.py --hook                read hook JSON from stdin (Stop hook)
  render.py --open <session>      print path to index.html (for opening)

Pure stdlib. Run with `python3` or `uv run`.
"""
from __future__ import annotations

import hashlib
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

# Claude mark (icons8 PNG), embedded as a data URI so it renders over file://
CLAUDE_ICON_DATA_URI = "data:image/png;base64,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"

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
    "<task-notification>",
)


def is_side_channel(text: str) -> bool:
    """True if a user string message is a CLI side-channel, not a typed prompt."""
    s = text.lstrip()
    return s.startswith(_SIDE_CHANNEL_TAGS)


def queued_prompt_text(rec: dict) -> str:
    """Text of a message the user typed while the assistant was still working.

    The CLI does NOT re-emit such a message as a `user` record — its only trace
    is a `queue-operation`/`enqueue` record carrying the typed text in `content`.
    Returns the text for a real typed enqueue, or '' for anything else (the
    `popAll`/`remove` lifecycle records, or harness-injected enqueues like a
    `<task-notification>` side-channel)."""
    if rec.get("type") != "queue-operation" or rec.get("operation") != "enqueue":
        return ""
    content = rec.get("content")
    if not isinstance(content, str) or not content.strip():
        return ""
    if is_side_channel(content):
        return ""
    return content


def is_compaction(rec: dict) -> bool:
    """True if this record is an auto-generated compaction summary (the message
    injected when a session is continued after running out of context)."""
    return rec.get("type") == "user" and bool(rec.get("isCompactSummary"))


def is_interrupt(rec: dict) -> bool:
    """True for the synthetic '[Request interrupted by user...]' user records.

    These are not prompts and don't start a turn — they record that the user
    stopped the assistant, and belong to the turn that was in progress."""
    if rec.get("type") != "user" or rec.get("isMeta"):
        return False
    msg = rec.get("message") or {}
    content = msg.get("content")
    if isinstance(content, list):
        content = " ".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    if not isinstance(content, str):
        return False
    return content.lstrip().startswith("[Request interrupted by user")


def is_turn_boundary(rec: dict) -> bool:
    """A 'real' user prompt that starts a new turn.

    Excludes meta records, tool_result-carrier user messages (those belong to
    the in-flight turn), and CLI side-channel messages (slash-command wrappers,
    bash `!` input/output, injected system reminders). A compaction summary IS
    a boundary (handled specially by the caller), but not a typed prompt.
    """
    if rec.get("type") != "user" or rec.get("isMeta"):
        return False
    if rec.get("isCompactSummary"):
        return False  # caller treats compaction as its own boundary kind
    if is_interrupt(rec):
        return False  # interrupts attach to the in-flight turn, not new ones
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
    is_compaction: bool = False
    compaction: str = ""  # the full compaction summary (markdown), when is_compaction
    # Ordered user-side messages in this turn: the primary prompt, plus any
    # unanswered follow-ups (queued/resent prompts that got no response) and
    # interrupts. Each: {"kind": "prompt"|"interrupt", "text": str}.
    messages: list[dict] = field(default_factory=list)
    has_response: bool = False  # True once any assistant block lands this turn
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

        # Interrupts ("[Request interrupted by user...]") are recorded as a
        # user-side message in the timeline, not as a response block.
        if rtype == "user" and is_interrupt(rec):
            self.messages.append({"kind": "interrupt", "text": _prompt_text(rec).strip()})
            return

        # A user string message that is a CLI side-channel (bash !, reminders,
        # slash-command wrappers) contributes no blocks.
        if rtype == "user":
            content = (rec.get("message") or {}).get("content")
            if isinstance(content, str) and is_side_channel(content):
                return

        if rtype == "assistant":
            self.has_response = True

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
            "isCompaction": self.is_compaction,
            "compaction": self.compaction,
            "messages": self.messages,
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
    b.is_compaction = d.get("is_compaction", False)
    b.compaction = d.get("compaction", "")
    b.messages = d.get("messages", [])
    b.has_response = d.get("has_response", False)
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
        "is_compaction": b.is_compaction,
        "compaction": b.compaction,
        "messages": b.messages,
        "has_response": b.has_response,
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


def write_pending(out_dir: Path, open_buf: "TurnBuf | None", title: str = "", sig: int = 0) -> None:
    """Overwrite pending.js with the single in-progress turn (or nothing) plus
    the resolved session title and a monotonic change signal.

    Distinct from turns.js: this file is rewritten every run, so re-running can
    never duplicate the current turn, and the title always reflects the latest
    /rename. The viewer concatenates pending onto the finalized turns.

    `sig` is the transcript byte offset — it increases on any new data, so the
    viewer can poll this file (re-injecting it as a <script>, which works over
    file://) and reload when the value changes."""
    pj = out_dir / "pending.js"
    pending = "null" if open_buf is None else json.dumps(open_buf.to_obj(), ensure_ascii=False)
    pj.write_text(
        f"window.__PENDING__ = {pending};\n"
        f"window.__TITLE__ = {json.dumps(title, ensure_ascii=False)};\n"
        f"window.__SIG__ = {sig};\n",
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


def _asset_version() -> str:
    """Short content hash of the shared assets. Stamped onto asset URLs in
    index.html (?v=...) so a code change forces the browser to refetch them —
    file:// otherwise caches linked CSS/JS aggressively, serving stale viewers."""
    h = hashlib.sha1()
    h.update(STYLE_CSS.encode("utf-8"))
    h.update(APP_JS.encode("utf-8"))
    h.update(INDEX_HTML.encode("utf-8"))
    return h.hexdigest()[:10]


def ensure_scaffold(out_dir: Path, session_id: str, write_assets: bool = True) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    # Shared assets are refreshed every run so CSS/JS edits propagate. The
    # background watcher passes write_assets=False: it runs whatever (possibly
    # stale) code it was spawned with, so rewriting assets would clobber fresh
    # ones written by a newer `html`/Stop-hook invocation. The watcher only
    # needs to refresh this session's data (pending.js), not the shared assets.
    if write_assets:
        write_shared_assets()
    tj = out_dir / "turns.js"
    if not tj.exists():
        tj.write_text("window.__TURNS__ = window.__TURNS__ || [];\n", encoding="utf-8")
    pj = out_dir / "pending.js"
    if not pj.exists():
        pj.write_text("window.__PENDING__ = null;\nwindow.__TITLE__ = \"\";\nwindow.__SIG__ = 0;\n", encoding="utf-8")
    # Skeleton holds no per-session mutable data (only the session id + links to
    # the shared assets), so rewriting it every run is idempotent — and lets
    # skeleton edits (title, icon, layout) propagate like the CSS/JS already do.
    # Guarded by write_assets (same reason): a stale watcher must not stamp an
    # old asset version into index.html. Always written if it's missing.
    idx = out_dir / "index.html"
    if write_assets or not idx.exists():
        idx.write_text(
            INDEX_HTML.replace("__SESSION_ID__", session_id)
            .replace("__ICON__", CLAUDE_ICON_DATA_URI)
            .replace("__ASSETV__", _asset_version()),
            encoding="utf-8",
        )


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
        # Bundle inlines every asset, so the cache-busting query string is moot —
        # drop it first so the exact-match replacements below still fire.
        INDEX_HTML.replace("?v=__ASSETV__", "")
        .replace("__SESSION_ID__", session_id)
        .replace("__ICON__", CLAUDE_ICON_DATA_URI)
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


def process(transcript: Path, flush: bool = False, write_assets: bool = True,
            rebuild: bool = False) -> dict:
    """Core incremental step. Returns a small summary dict.

    write_assets=False (used by the background watcher) skips rewriting the
    shared CSS/JS and index.html, so a watcher running stale code can't clobber
    assets written by a newer invocation.

    rebuild=True discards this session's accumulated output (turns.js + state)
    and regenerates every turn from byte 0. Needed because the normal path is
    append-only: a code change to the turn shape only affects turns rendered
    after it, so old sessions need a full re-render to pick it up."""
    session_id = session_id_of(transcript)
    out_dir = OUT_ROOT / session_id
    if rebuild:
        # Drop the append-only turn log and the incremental cursor so the
        # scaffold below recreates an empty turns.js and we re-read from 0.
        for stale in ("turns.js", "state.json"):
            (out_dir / stale).unlink(missing_ok=True)
    ensure_scaffold(out_dir, session_id, write_assets=write_assets)
    state = load_state(out_dir)

    records, new_offset = read_new_records(transcript, state["offset_bytes"])

    open_buf = _buf_from_state(state.get("open_turn"))
    next_n = state.get("next_n", 1)
    finalized: list[dict] = []

    title = state.get("title", "")
    for rec in records:
        # Session title: custom title (set via /rename) wins over the AI title;
        # latest occurrence wins. Captured continuously, independent of turns.
        if rec.get("type") == "custom-title" and rec.get("customTitle"):
            title = rec["customTitle"].strip()
        elif rec.get("type") == "ai-title" and rec.get("aiTitle"):
            # Only let an AI title fill an empty slot — never override a custom one.
            # (A later /rename emits a fresh custom-title, handled above.)
            if not title:
                title = rec["aiTitle"].strip()

        qtext = queued_prompt_text(rec)
        if qtext:
            # A message the user typed while the assistant was working. It is
            # answered within the in-flight turn, so it belongs to that turn —
            # not as a new turn. (No `user` record is ever emitted for it; the
            # enqueue record is its only trace.)
            if open_buf is not None and not open_buf.is_compaction:
                # Sidebar entry: lists the follow-up under the turn's snippet.
                open_buf.messages.append(
                    {"kind": "prompt", "text": qtext.strip(), "queued": True}
                )
                # Inline block: render it in the main stream at the point it was
                # injected (between the work before and after), so it reads in
                # chronological order rather than only in the pinned header.
                open_buf.blocks.append({"k": "queued", "text": qtext.strip()})
            continue

        if is_compaction(rec):
            # A compaction summary ends the prior turn and becomes its own
            # single-purpose turn (the collapsible "conversation compacted" card).
            if open_buf is not None:
                finalized.append(open_buf.to_obj())
            open_buf = TurnBuf(n=next_n)
            next_n += 1
            open_buf.is_compaction = True
            open_buf.compaction = _prompt_text(rec)
            open_buf.absorb(rec)
        elif is_turn_boundary(rec):
            ptext = _prompt_text(rec)
            # If the open turn never got an assistant response (e.g. a queued or
            # resent prompt, or an interrupted one), this new prompt is a
            # follow-up to it, not a new turn — fold it in so they group as one.
            if open_buf is not None and not open_buf.is_compaction and not open_buf.has_response:
                open_buf.messages.append({"kind": "prompt", "text": ptext.strip()})
                open_buf.absorb(rec)
            else:
                if open_buf is not None:
                    finalized.append(open_buf.to_obj())
                open_buf = TurnBuf(n=next_n)
                next_n += 1
                open_buf.prompt = ptext
                open_buf.messages.append({"kind": "prompt", "text": ptext.strip()})
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
    write_pending(out_dir, open_buf, title, sig=new_offset)

    state["offset_bytes"] = new_offset
    state["turns_emitted"] = state.get("turns_emitted", 0) + appended
    state["open_turn"] = _buf_to_state(open_buf)
    state["next_n"] = next_n
    state["title"] = title
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
# Live watcher: a short-lived, self-terminating background process.
#
# The recap (`away_summary`) lands in the transcript a few minutes AFTER the
# turn ends — long after the Stop hook's render has run, so it is missed until
# the next turn. There is no hook event for "recap written". To pick it up live
# without a server, the Stop hook spawns this detached watcher: it polls the
# transcript file size for a bounded window and re-runs process() whenever the
# file grows (which rewrites pending.js and bumps __SIG__, so the browser's own
# poller reloads). It then exits. A PID lockfile keeps a single watcher per
# session so repeated Stop hooks don't stack processes.
# ---------------------------------------------------------------------------

WATCH_WINDOW_S = 360      # give up after this long with no growth handled
WATCH_POLL_S = 2.0        # how often to stat the transcript
WATCH_IDLE_EXIT_S = 330   # exit early if the file hasn't grown for this long


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _acquire_watch_lock(out_dir: Path) -> bool:
    """Best-effort single-watcher lock. Returns True if we own it.

    Stores our PID in watch.lock; if an existing lock names a live PID we back
    off, otherwise we steal a stale lock."""
    lock = out_dir / "watch.lock"
    try:
        if lock.exists():
            try:
                existing = int(lock.read_text().strip() or "0")
            except (ValueError, OSError):
                existing = 0
            if existing and existing != os.getpid() and _pid_alive(existing):
                return False  # another live watcher owns it
        lock.write_text(str(os.getpid()))
        return True
    except OSError:
        return False


def _release_watch_lock(out_dir: Path) -> None:
    lock = out_dir / "watch.lock"
    try:
        if lock.exists() and lock.read_text().strip() == str(os.getpid()):
            lock.unlink()
    except OSError:
        pass


def watch(transcript: Path) -> int:
    """Poll the transcript and re-render on growth, for a bounded window."""
    import time

    session_id = session_id_of(transcript)
    out_dir = OUT_ROOT / session_id
    out_dir.mkdir(parents=True, exist_ok=True)
    if not _acquire_watch_lock(out_dir):
        return 0  # someone else is already watching this session

    try:
        try:
            last_size = transcript.stat().st_size
        except OSError:
            last_size = 0
        start = time.monotonic()
        last_change = start
        while True:
            time.sleep(WATCH_POLL_S)
            now = time.monotonic()
            if now - start > WATCH_WINDOW_S:
                break
            try:
                size = transcript.stat().st_size
            except OSError:
                continue
            if size != last_size:
                last_size = size
                last_change = now
                try:
                    # write_assets=False: don't let a watcher running stale code
                    # clobber shared CSS/JS. Only refresh this session's data.
                    process(transcript, write_assets=False)  # rewrites pending.js, bumps __SIG__
                except Exception:
                    pass  # never crash the watcher on a transient parse error
            elif now - last_change > WATCH_IDLE_EXIT_S:
                break
    finally:
        _release_watch_lock(out_dir)
    return 0


def spawn_watcher(transcript: Path) -> None:
    """Fire-and-forget a fully-detached `--watch` child. Never blocks the hook."""
    import subprocess
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--watch", str(transcript)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # detach from the hook's process group
        )
    except Exception:
        pass  # spawning is best-effort; the hook must never fail


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
<link rel="icon" type="image/png" href="__ICON__">
<link rel="stylesheet" href="../../assets/theme.css?v=__ASSETV__">
<link rel="stylesheet" href="../../assets/style.css?v=__ASSETV__">
</head>
<body>
<aside class="side">
  <div class="side-head">
    <div class="side-head-top">
      <button class="rail-btn toggle" id="toggleSide" data-tip="Toggle turns sidebar · Alt+M" aria-label="Toggle turns sidebar">
        <svg class="ico" viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="2" y="3" width="12" height="10" rx="2"/><line x1="6.5" y1="3.5" x2="6.5" y2="12.5"/></svg>
      </button>
      <img class="brand-icon" src="__ICON__" width="18" height="18" alt="" aria-hidden="true">
      <span class="brand-label" id="sessionTitle">Claude Transcript</span>
    </div>
    <div class="nav">
      <button class="rail-btn" id="first" data-tip="First turn · Home">⤒</button>
      <button class="rail-btn" id="prev" data-tip="Previous turn · ← or Ctrl+↑">‹</button>
      <span class="counter" id="counter">– / –</span>
      <button class="rail-btn" id="next" data-tip="Next turn · → or Ctrl+↓">›</button>
      <button class="rail-btn" id="last" data-tip="Last turn · End">⤓</button>
    </div>
    <div class="meta" id="hmeta"></div>
  </div>
  <div class="side-title">Turns</div>
  <div id="turnlist"></div>
  <div class="resizer" id="sideResizer" data-tip="Drag to resize · double-click to reset"></div>
</aside>
<main id="main" tabindex="-1"></main>
<aside class="toc">
  <div class="toc-head">
    <span class="toc-title">In this turn</span>
    <button class="rail-btn toggle" id="toggleToc" data-tip="Toggle this-turn sidebar · Alt+R" aria-label="Toggle this-turn sidebar">
      <svg class="ico" viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="2" y="3" width="12" height="10" rx="2"/><line x1="9.5" y1="3.5" x2="9.5" y2="12.5"/></svg>
    </button>
  </div>
  <div id="toc"></div>
  <div class="resizer left" id="tocResizer" data-tip="Drag to resize · double-click to reset"></div>
</aside>
<button class="rail-btn toggle corner-toggle" id="tocCornerToggle" data-tip="Show this-turn sidebar · Alt+R" aria-label="Show this-turn sidebar">
  <svg class="ico" viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="2" y="3" width="12" height="10" rx="2"/><line x1="9.5" y1="3.5" x2="9.5" y2="12.5"/></svg>
</button>

<script src="turns.js?v=__ASSETV__"></script>
<script src="pending.js?v=__ASSETV__"></script>
<script src="../../assets/app.js?v=__ASSETV__"></script>
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
    --side-w:270px; --toc-w:250px;
    display:grid; grid-template-columns:var(--side-w) 1fr var(--toc-w);
    grid-template-areas:"side main toc"; height:100vh; overflow:hidden;
    transition:grid-template-columns .15s ease;
  }
  /* While dragging a resizer, drop the transition so the column tracks the mouse. */
  body.resizing { transition:none; cursor:col-resize; user-select:none; }
  /* Collapsed left: shrinks to a thin icon rail. Collapsed right: removed
     entirely (0 width) — a floating corner button restores it, so main reclaims
     the full width. */
  body.side-collapsed { grid-template-columns:44px 1fr var(--toc-w); }
  body.toc-collapsed  { grid-template-columns:var(--side-w) 1fr 0; }
  body.side-collapsed.toc-collapsed { grid-template-columns:44px 1fr 0; }
  body.toc-collapsed aside.toc { display:none; }

  /* Sidebar head: holds title, nav (icons), and model/meta info. */
  .side-head { padding:10px 10px 8px; border-bottom:1px solid var(--border); }
  /* Brand row: hamburger + icon + session title (the prominent heading). */
  .side-head-top { display:flex; align-items:flex-start; gap:9px; margin-bottom:11px; }
  .side-head-top .toggle { flex-shrink:0; }
  .side-head .brand-label { font-weight:650; font-size:14.5px; line-height:1.35; color:var(--fg);
    white-space:normal; word-break:break-word; flex:1; min-width:0; align-self:center; }
  .brand-icon { flex-shrink:0; display:block; }
  .rail-btn {
    background:var(--panel2); color:var(--fg); border:1px solid var(--border); border-radius:6px;
    padding:5px 8px; font-size:13px; cursor:pointer; line-height:1; min-width:30px; text-align:center;
  }
  .rail-btn:hover:not(:disabled) { border-color:var(--accent); color:var(--accent); }
  .rail-btn:disabled { opacity:.3; cursor:default; }
  .nav { display:flex; align-items:center; gap:5px; }
  .counter { font-family:var(--mono); font-size:12px; color:var(--muted); min-width:54px; text-align:center; }
  .meta { color:var(--muted); font-size:11px; font-family:var(--mono); margin-top:10px;
    display:flex; flex-wrap:wrap; gap:5px 8px; align-items:center; }
  .meta .mi { white-space:nowrap; }
  .meta .mi.model { color:color-mix(in srgb, var(--accent) 70%, var(--fg)); }

  /* The toggle buttons are borderless ghost icons, not boxed rail buttons. */
  .rail-btn.toggle { background:none; border:none; padding:4px; min-width:0; color:var(--muted);
    display:inline-flex; align-items:center; justify-content:center; border-radius:6px; }
  .rail-btn.toggle:hover:not(:disabled) { background:var(--panel2); color:var(--accent); }
  .rail-btn.toggle .ico { display:block; }

  /* Rail (collapsed) mode: stack nav icons vertically, hide everything else. */
  body.side-collapsed .side-head { padding:10px 5px 8px; border-bottom:none; }
  body.side-collapsed .side-head-top { justify-content:center; margin-bottom:10px; }
  body.side-collapsed .brand-icon,
  body.side-collapsed .brand-label,
  body.side-collapsed .meta,
  body.side-collapsed .counter,
  body.side-collapsed .side-title,
  body.side-collapsed #turnlist { display:none; }
  body.side-collapsed .nav { flex-direction:column; gap:6px; align-items:center; }
  body.side-collapsed .rail-btn { width:32px; }

  main { grid-area:main; overflow-y:auto; padding:0 28px 80px; }
  main:focus { outline:none; }  /* programmatically focused for keyboard scroll; no ring */
  /* Pinned header: sticks to the top of the scrolling main pane. Holds the
     recap card and the prompt card, stacked. */
  .prompt-pin { position:sticky; top:0; z-index:20; background:var(--bg);
    padding:16px 0 10px; margin-bottom:8px; display:flex; flex-direction:column; gap:8px; }
  .prompt {
    background:color-mix(in srgb, var(--user) 12%, var(--panel)); border:1px solid color-mix(in srgb, var(--user) 35%, var(--border));
    border-left:3px solid var(--user); border-radius:8px; overflow:hidden;
    font-size:16px; line-height:1.5;
  }
  .prompt { cursor:pointer; }
  .prompt-head { display:flex; align-items:center; gap:8px; padding:14px 18px 9px; }
  .prompt .lbl { color:var(--accent); font-size:11px; font-weight:600; letter-spacing:.06em;
    text-transform:uppercase; flex:1; }
  .prompt .pcount { color:var(--muted); font-weight:600; text-transform:none; letter-spacing:0; }
  .prompt .chev { color:var(--muted); font-size:9px; transition:transform .12s; }
  .prompt:not(.collapsed) .chev { transform:rotate(90deg); }
  .pmsgs { padding:0 18px 20px; line-height:21px; }
  .pmsg { white-space:pre-wrap; word-break:break-word; }
  .pmsg + .pmsg { margin-top:9px; padding-top:9px; border-top:1px dashed color-mix(in srgb, var(--user) 30%, var(--border)); }
  .pmsg.interrupt { color:var(--muted); font-style:italic; }
  .pmsg-tag { display:inline-block; font-style:normal; font-size:10px; font-family:var(--mono);
    color:var(--tool); border:1px solid color-mix(in srgb, var(--tool) 40%, transparent);
    border-radius:9px; padding:0 6px; margin-right:7px; vertical-align:1px; }
  /* Collapsed AND overflowing: clip to exactly 3 whole lines (3 × 21px = 63px).
     overflow:hidden clips at the PADDING box, so the breathing room beneath must
     be margin (outside the clip) — padding here would just let a 4th line peek
     through. The margin sits between the clean 3-line cut and the card border.
     Content that already fits keeps its normal bottom padding (no tight crop). */
  .prompt.collapsed.overflowing .pmsgs { max-height:63px; overflow:hidden; padding-bottom:0; margin-bottom:14px; }
  .prompt.collapsed .pmsg + .pmsg { margin-top:0; padding-top:0; border-top:none; }
  /* "…" hint: only on the 3rd line when collapsed AND there's hidden overflow. */
  .pmsgs-fade { display:none; }
  .prompt.collapsed.overflowing .pmsgs-fade {
    display:block; position:absolute; right:0; bottom:14px; height:21px; padding:0 18px 0 28px;
    color:var(--muted); font-size:14px; line-height:21px; pointer-events:none;
    background:linear-gradient(to right, transparent, color-mix(in srgb, var(--user) 12%, var(--panel)) 42%);
  }
  .prompt { position:relative; }

  .block { margin:12px 0; border:1px solid var(--border); border-radius:8px; overflow:hidden; background:var(--panel); }
  .block.text { border:none; background:none; padding:2px 2px; }
  /* A message the user queued mid-turn, shown inline at its injection point.
     User-tinted (like the prompt card) so it reads as the user speaking, with
     an accent ⏳ tag. */
  .block.queued-block { border-color:color-mix(in srgb, var(--user) 35%, var(--border));
    border-left:3px solid var(--user); background:color-mix(in srgb, var(--user) 10%, var(--panel));
    padding:12px 16px; }
  .block.queued-block > .pmsg-tag { color:var(--accent);
    border:1px solid color-mix(in srgb, var(--accent) 40%, transparent);
    display:inline-block; font-size:10px; font-family:var(--mono); border-radius:9px;
    padding:0 6px; margin-bottom:8px; }
  .text-body { font-size:16px; line-height:1.62; }
  .text-body h1,.text-body h2,.text-body h3,.text-body h4,.text-body h5,.text-body h6 {
    margin:.7em 0 .35em; line-height:1.25; color:var(--accent2); font-weight:650; }
  .text-body h1 { font-size:1.35em; color:var(--accent); }
  .text-body h2 { font-size:1.2em; } .text-body h3 { font-size:1.05em; }
  .text-body h4,.text-body h5,.text-body h6 { font-size:1em; }
  .text-body p { margin:.5em 0; } .text-body ul,.text-body ol { margin:.4em 0 .4em 1.4em; }
  .text-body li { margin:.2em 0; }
  .text-body a { color:var(--accent); }
  .text-body hr { border:none; border-top:1px solid var(--border); margin:1.1em 0; }
  .text-body code { background:var(--panel2); padding:.12em .4em; border-radius:4px; font-family:var(--mono); font-size:.88em; }
  .text-body pre { background:color-mix(in srgb, var(--bg) 80%, #000); border:1px solid var(--border); border-radius:8px; padding:12px 14px;
    overflow-x:auto; } .text-body pre code { background:none; padding:0; }
  .text-body table { border-collapse:collapse; margin:.6em 0; font-size:15px; display:block; overflow-x:auto; max-width:100%; }
  .text-body th,.text-body td { border:1px solid var(--border); padding:6px 11px; text-align:left; vertical-align:top; }
  .text-body th { background:var(--panel2); font-weight:600; }
  .text-body tbody tr:nth-child(even) { background:color-mix(in srgb, var(--fg) 3%, transparent); }

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

  /* AskUserQuestion: a readable Q&A view — question, options (chosen one
     highlighted), and the user's actual answer. */
  .aq { display:flex; flex-direction:column; gap:14px; padding:4px 0; }
  .aq-card { border:1px solid var(--border); border-radius:8px; padding:12px 14px; background:var(--panel2); }
  .aq-header { font-size:10px; font-weight:600; letter-spacing:.06em; text-transform:uppercase;
    color:var(--tool); margin-bottom:5px; }
  .aq-question { font-size:14px; font-weight:600; line-height:1.4; margin-bottom:10px; }
  .aq-opts { display:flex; flex-direction:column; gap:6px; margin-bottom:11px; }
  .aq-opt { border:1px solid var(--border); border-radius:6px; padding:7px 10px; background:var(--panel); }
  .aq-opt.chosen { border-color:color-mix(in srgb, var(--accent) 55%, var(--border));
    background:color-mix(in srgb, var(--accent) 12%, var(--panel)); }
  .aq-opt-label { font-size:12.5px; font-weight:600; color:var(--muted); }
  .aq-opt.chosen .aq-opt-label { color:var(--accent); }
  .aq-opt-desc { font-size:11.5px; color:var(--muted); line-height:1.4; margin-top:2px; }
  .aq-answer { font-size:13.5px; line-height:1.45; padding:8px 11px; border-radius:6px;
    background:color-mix(in srgb, var(--user) 12%, var(--panel));
    border-left:3px solid var(--user); white-space:pre-wrap; word-break:break-word; }
  .aq-answer.none { background:var(--panel); border-left-color:var(--muted); color:var(--muted); font-style:italic; }
  .aq-answer-lbl { display:inline-block; font-size:10px; font-weight:600; letter-spacing:.05em;
    text-transform:uppercase; color:var(--user); margin-right:8px; font-style:normal; vertical-align:1px; }
  .aq-answer.none .aq-answer-lbl { color:var(--muted); }

  .sub { margin:8px 0; border:1px solid var(--border); border-radius:6px; background:var(--panel2); }
  .sub > summary { padding:7px 12px; font-size:12px; color:var(--muted); }
  .sub-body { padding:6px 12px 10px; }
  /* Grouped consecutive Edits/Reads: members stacked inside one collapsible. */
  .group-body { padding:8px 12px 12px; }
  .group-body .member { margin:6px 0; background:color-mix(in srgb, var(--bg) 60%, var(--panel)); }
  .group-body .member > summary { display:flex; align-items:center; gap:8px; color:var(--fg); }
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

  /* Recap card: the recap as a pin-card, tinted green to distinguish it from
     the (user-blue) prompt card. */
  #recapBox { background:color-mix(in srgb, var(--accent2) 9%, var(--panel));
    border:1px solid color-mix(in srgb, var(--accent2) 35%, var(--border)); border-left:3px solid var(--accent2); }
  #recapBox .recap-lbl { color:var(--accent2); }
  #recapBox.overflowing .pmsgs-fade {
    background:linear-gradient(to right, transparent, color-mix(in srgb, var(--accent2) 9%, var(--panel)) 42%); }
  .recap-body { font-size:13.5px; line-height:21px; color:color-mix(in srgb, var(--accent2) 22%, var(--fg)); }
  .recap-body p { margin:0; line-height:21px; }
  .recap-body p + p { margin-top:10px; }

  /* Compaction card: marks where the conversation was auto-summarized. */
  .compaction { border:1px solid color-mix(in srgb, var(--think) 35%, var(--border)); border-radius:8px;
    background:color-mix(in srgb, var(--think) 7%, var(--panel)); overflow:hidden; margin:4px 0 8px; }
  .compaction > summary { list-style:none; cursor:pointer; padding:13px 16px; display:flex; align-items:center; gap:10px;
    font-size:13.5px; user-select:none; }
  .compaction > summary::-webkit-details-marker { display:none; }
  .compaction > summary::before { content:"▶"; font-size:9px; color:var(--muted); transition:transform .12s; display:inline-block; }
  .compaction[open] > summary::before { transform:rotate(90deg); }
  .compaction .clbl { font-weight:700; color:var(--think); letter-spacing:.02em; }
  .compaction .cnote { color:var(--muted); font-size:12px; }
  .compaction .cbody { padding:6px 18px 18px; border-top:1px solid color-mix(in srgb, var(--think) 20%, var(--border)); }

  /* Compaction marker in the turn list (left sidebar). */
  .trow.compaction-row { border-color:color-mix(in srgb, var(--think) 30%, var(--border)); }
  .trow.compaction-row .mn { color:var(--think); }

  /* Left sidebar: fixed head + title, scrollable turn list. Collapses to a rail. */
  aside.side { grid-area:side; background:var(--panel); border-right:1px solid var(--border);
    overflow:hidden; display:flex; flex-direction:column; }
  .side-head { flex:0 0 auto; }
  .side-title { flex:0 0 auto; color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.08em; padding:10px 10px 8px; }
  #turnlist { flex:1 1 auto; overflow-y:auto; overflow-x:hidden; padding:0 8px 10px; }
  .trow { display:block; width:100%; text-align:left; background:none; border:1px solid transparent;
    border-radius:6px; padding:8px 9px; cursor:pointer; margin-bottom:4px; color:var(--fg); }
  .trow:hover { background:var(--panel2); }
  .trow.active { background:color-mix(in srgb, var(--accent) 16%, var(--panel)); border-color:color-mix(in srgb, var(--accent) 45%, var(--border)); }
  /* Header line: turn number on the left, the tool/think/text counts on the right. */
  .trow-head { display:flex; align-items:center; gap:8px; }
  .trow .mn { font-family:var(--mono); font-size:12.5px; color:var(--accent); flex-shrink:0; }
  .trow .msnip { font-size:13px; color:var(--muted); margin:4px 0 0; line-height:1.35;
    display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; }
  .trow .micons { display:flex; gap:8px; font-size:11px; font-family:var(--mono); color:var(--muted);
    margin-left:auto; }
  .trow .micons .i { display:inline-flex; align-items:center; gap:2px; }
  .trow .micons .i.think { color:color-mix(in srgb, var(--think) 60%, var(--muted)); }
  /* Follow-up prompts / interrupts grouped under the turn's primary snippet. */
  .trow .msubs { margin:0 0 5px; padding-left:7px; border-left:1px solid color-mix(in srgb, var(--user) 35%, var(--border)); }
  .trow .msub { font-size:12px; color:var(--muted); line-height:1.3; margin:2px 0;
    overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .trow .msub.interrupt { color:color-mix(in srgb, var(--tool) 55%, var(--muted)); font-style:italic; }
  .trow .msub.queued { color:color-mix(in srgb, var(--accent) 55%, var(--muted)); }

  /* Right: table of contents WITHIN the current turn */
  aside.toc { grid-area:toc; background:var(--panel); border-left:1px solid var(--border);
    overflow-y:auto; padding:10px 8px; display:flex; flex-direction:column; }
  .toc-head { display:flex; align-items:center; gap:6px; padding:0 4px 8px; }
  .toc-title { flex:1; color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.08em; }
  #toc { overflow-y:auto; }
  /* When the TOC is collapsed the whole column is gone; a single floating button
     in the top-right corner brings it back. Hidden while the TOC is open. */
  .corner-toggle { display:none; position:fixed; top:10px; right:12px; z-index:40;
    background:var(--panel2); border:1px solid var(--border); padding:5px; }
  .corner-toggle:hover { background:var(--panel2); border-color:var(--accent); color:var(--accent); }
  body.toc-collapsed .corner-toggle { display:inline-flex; }
  .toc-item { display:flex; align-items:center; gap:8px; width:100%; text-align:left; background:none;
    border:none; border-left:2px solid transparent; border-radius:0 4px 4px 0; padding:6px 8px;
    cursor:pointer; color:var(--muted); font-size:12px; }
  .toc-item:hover { background:var(--panel2); color:var(--fg); }
  .toc-item.active { color:var(--fg); border-left-color:var(--accent); background:color-mix(in srgb, var(--accent) 8%, transparent); }
  .toc-item .dot { width:7px; height:7px; border-radius:50%; flex-shrink:0; margin-top:5px; align-self:flex-start; }
  .toc-item .dot.think { background:var(--think); }
  .toc-item .dot.tool { background:var(--tool); }
  .toc-item .dot.text { background:var(--accent); }
  .toc-item .dot.queued { background:var(--user); }
  .toc-item { align-items:flex-start; }
  .tmeta { display:flex; flex-direction:column; gap:1px; overflow:hidden; }
  .toc-item .tlabel { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:var(--mono); font-size:13px; color:var(--fg); }
  .toc-item .tsub { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:12px; color:var(--muted); }
  .empty { color:var(--muted); padding:40px; text-align:center; font-size:14px; }
  .scroll-target { scroll-margin-top:84px; }  /* clear the sticky prompt header */

  /* Drag-to-resize handles, pinned to each sidebar's inner edge. */
  aside.side, aside.toc { position:relative; }
  .resizer { position:absolute; top:0; bottom:0; width:7px; cursor:col-resize; z-index:30; }
  .resizer { right:-4px; }          /* left sidebar: handle on its right edge */
  .resizer.left { left:-4px; right:auto; }  /* right sidebar: handle on its left edge */
  .resizer::after { content:""; position:absolute; top:0; bottom:0; left:50%; width:1px;
    background:transparent; transition:background .12s; }
  .resizer:hover::after, body.resizing .resizer::after { background:var(--accent); }
  /* A collapsed sidebar can't be resized — hide its handle. */
  body.side-collapsed #sideResizer, body.toc-collapsed #tocResizer { display:none; }

  /* Live-refresh pill: shown when new content arrives while browsing history. */
  .newpill { display:none; position:fixed; bottom:18px; left:50%; transform:translateX(-50%);
    z-index:50; background:var(--accent); color:var(--bg); border:none; border-radius:20px;
    padding:9px 16px; font-size:12.5px; font-weight:600; cursor:pointer;
    box-shadow:0 4px 16px color-mix(in srgb, var(--bg) 40%, #000); }
  .newpill:hover { filter:brightness(1.08); }

  /* Custom tooltip: shows instantly (no native title delay). A single shared
     element is positioned by JS near the hovered [data-tip] target. */
  #tooltip { position:fixed; z-index:200; pointer-events:none; opacity:0;
    background:var(--panel2); color:var(--fg); border:1px solid var(--border);
    border-radius:6px; padding:5px 9px; font-size:11.5px; line-height:1.3; white-space:nowrap;
    box-shadow:0 4px 14px color-mix(in srgb, var(--bg) 50%, #000); transition:opacity .08s; }
  #tooltip.show { opacity:1; }
  #tooltip .tip-key { color:var(--accent); font-family:var(--mono); font-size:11px; }
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

// ---- layout persistence (localStorage, works over file://) ----
// Collapse states + resized widths survive a refresh. Restored synchronously
// here (app.js runs at end of <body>, so <body> exists) to avoid a flash.
const LS_KEY = "transcript-viewer-layout";
function loadLayout(){
  try { return JSON.parse(localStorage.getItem(LS_KEY) || "{}") || {}; }
  catch(e){ return {}; }
}
function saveLayout(patch){
  try {
    const cur = loadLayout();
    localStorage.setItem(LS_KEY, JSON.stringify(Object.assign(cur, patch)));
  } catch(e){}
}
(function restoreLayout(){
  const L = loadLayout();
  document.body.classList.toggle("side-collapsed", !!L.sideCollapsed);
  document.body.classList.toggle("toc-collapsed", !!L.tocCollapsed);
  if (L.sideW) document.body.style.setProperty("--side-w", L.sideW);
  if (L.tocW)  document.body.style.setProperty("--toc-w", L.tocW);
})();
function toggleSideCollapsed(){
  const on = document.body.classList.toggle("side-collapsed");
  saveLayout({sideCollapsed:on});
}
function toggleTocCollapsed(){
  const on = document.body.classList.toggle("toc-collapsed");
  saveLayout({tocCollapsed:on});
}

// Session title (from /rename custom title, else the AI-generated title).
// It IS the heading next to the icon, replacing the "Claude Transcript" label;
// falls back to "Claude Transcript" when the session has no title.
const TITLE = (window.__TITLE__ || "").trim();
(function setTitle(){
  const el = $("sessionTitle");
  if (TITLE && el) el.textContent = TITLE;
  document.title = TITLE ? (TITLE + " · Claude Transcript") : "Claude Transcript";
})();

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
    // Thematic break: a line of 3+ -, *, or _ (optionally spaced), nothing else.
    // Checked before lists so a bare "---" becomes a rule, not a list/paragraph.
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(ln)){ out.push("<hr>"); i++; continue; }
    // GFM table: a header row containing a pipe, followed by a separator row
    // (only -, :, |, spaces, with at least one dash and one pipe).
    if (ln.indexOf("|")>=0 && i+1<lines.length
        && lines[i+1].indexOf("|")>=0 && /^[\s:|-]*-[\s:|-]*$/.test(lines[i+1])){
      const splitRow = (r)=>{
        let s = r.trim();
        if (s.startsWith("|")) s = s.slice(1);
        if (s.endsWith("|")) s = s.slice(0,-1);
        return s.split("|").map(c=>c.trim());
      };
      const headers = splitRow(ln);
      i += 2; // consume header + separator
      const rows = [];
      while (i<lines.length && lines[i].indexOf("|")>=0 && lines[i].trim()!==""){
        rows.push(splitRow(lines[i])); i++;
      }
      const thead = `<thead><tr>${headers.map(c=>`<th>${inline(c)}</th>`).join("")}</tr></thead>`;
      const tbody = `<tbody>${rows.map(r=>`<tr>${r.map(c=>`<td>${inline(c)}</td>`).join("")}</tr>`).join("")}</tbody>`;
      out.push(`<table>${thead}${tbody}</table>`);
      continue;
    }
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
    while (i<lines.length && lines[i].trim()!=="" && !/^(#{1,6}\s|```|\s*[-*]\s|\s*\d+\.\s)/.test(lines[i])
           && !/^\s*([-*_])(\s*\1){2,}\s*$/.test(lines[i])){ para.push(lines[i]); i++; }
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
      const qs=inp.questions;
      if(Array.isArray(qs)&&qs.length){
        const head = qs[0].header || qs[0].question || "";
        return qs.length>1 ? `${head} +${qs.length-1} more` : head;
      }
      return "";
    }
    default: return inp.description || inp.title || "";
  }
}

// Each rendered block gets an anchor id + a TOC entry {kind, label, sub}.
function tocLabel(b, idx){
  if (b.k==="text") return {kind:"text", label:"Response", sub:""};
  if (b.k==="thinking") return {kind:"think", label:"Thinking", sub:""};
  if (b.k==="tool") return {kind:"tool", label:b.name||"Tool", sub:toolAnnotation(b)};
  if (b.k==="queued") return {kind:"queued", label:"Queued msg", sub:(b.text||"").replace(/\s+/g," ").slice(0,40)};
  return {kind:"text", label:"Block", sub:""};
}

// Group a consecutive run of Read/Edit tool calls that all target the SAME file
// into one collapsible unit (e.g. read-then-edit-edit of one file). The run
// breaks on any other tool, a Read/Edit of a different file, or a non-tool block.
// Returns items: {type:"single", block, idx} or
// {type:"group", badge, label, sub, members:[{block,idx}], thought}.
function groupBlocks(blocks){
  const fileOf = (b)=>{ const i=b.input||{}; return i.file_path||i.path||""; };
  const isFileOp = (b)=> b && b.k==="tool" && (b.name==="Read" || b.name==="Edit");
  const base = (p)=>{ const parts=String(p).split("/"); return parts[parts.length-1]||p; };
  const out = [];
  let i = 0;
  while (i < blocks.length){
    const b = blocks[i];
    if (isFileOp(b) && fileOf(b)){
      const file = fileOf(b);
      const members = [{block:b, idx:i}];
      let j = i + 1;
      while (j < blocks.length && isFileOp(blocks[j]) && fileOf(blocks[j]) === file){
        members.push({block:blocks[j], idx:j});
        j++;
      }
      if (members.length > 1){
        const nR = members.filter(m=>m.block.name==="Read").length;
        const nE = members.filter(m=>m.block.name==="Edit").length;
        const parts = [];
        if (nR) parts.push(`${nR}× Read`);
        if (nE) parts.push(`${nE}× Edit`);
        const badge = (nR && nE) ? "READ/EDIT" : (nR ? "READ" : "EDIT");
        out.push({type:"group", badge, label:parts.join(" · "), sub:base(file),
                  members, thought: precededByThink(blocks, i)});
        i = j;
        continue;
      }
    }
    out.push({type:"single", block:b, idx:i});
    i++;
  }
  return out;
}

// True if the block at index i was immediately preceded by a thinking block.
// (Thinking always directly precedes the action it reasoned about.)
function precededByThink(blocks, i){
  return i>0 && blocks[i-1] && blocks[i-1].k==="thinking";
}
const THINK_MARK = `<span class="think-mark" title="preceded by thinking">✦</span>`;

// Pull {question: answer} pairs out of the AskUserQuestion tool result. Three
// observed result shapes:
//   - answered:  'Your questions have been answered: "Q1"="A1", "Q2"="A2"'
//   - clarify/rejected: a prose blob listing 'Questions asked:' with no answers
//   - raw array/other: handled by the caller's fallback.
// Returns a Map(question -> answer|null), or null if the string isn't parseable.
function parseAskAnswers(res){
  // Preferred shape: the structured result object carries an `answers` map
  // {question: answer} directly — no string parsing needed.
  if (res && typeof res==="object" && !Array.isArray(res) && res.answers && typeof res.answers==="object"){
    const m = new Map();
    for (const k of Object.keys(res.answers)) m.set(k, res.answers[k]);
    return m.size ? m : null;
  }
  let s = res;
  if (Array.isArray(res)) s = res.map(p=> (p && p.text) ? p.text : (typeof p==="string"?p:"")).join("\n");
  if (typeof s !== "string") return null;
  const out = new Map();
  if (s.includes("have been answered")){
    // Match each "..."="..." pair (answers may contain commas/escaped quotes).
    const re = /"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"/g;
    let m;
    while ((m = re.exec(s)) !== null){
      out.set(m[1].replace(/\\"/g,'"'), m[2].replace(/\\"/g,'"'));
    }
    return out.size ? out : null;
  }
  if (s.includes("Questions asked:")){
    // Clarify/reject path: '- "Question"\n  (No answer provided)'
    const re = /-\s+"((?:[^"\\]|\\.)*)"/g;
    let m;
    while ((m = re.exec(s)) !== null) out.set(m[1].replace(/\\"/g,'"'), null);
    return out.size ? out : null;
  }
  return null;
}

// Render an AskUserQuestion call as readable Q&A: each question, the options
// offered (the chosen one highlighted), and the user's actual answer.
function renderAskQuestion(b){
  const qs = (b.input && Array.isArray(b.input.questions)) ? b.input.questions : [];
  const answers = parseAskAnswers(
    (b.resultStructured!==null && b.resultStructured!==undefined) ? b.resultStructured : b.result
  );
  const ansFor = (q)=> answers ? (answers.has(q.question) ? answers.get(q.question) : null) : null;
  const cards = qs.map(q=>{
    const ans = ansFor(q);
    const opts = Array.isArray(q.options) ? q.options : [];
    // Mark the option whose label the user's answer matches (best-effort).
    const norm = (x)=> String(x||"").trim().toLowerCase();
    const chosen = ans ? opts.find(o=> norm(o.label)===norm(ans) || norm(ans).includes(norm(o.label))) : null;
    const optHtml = opts.map(o=>{
      const on = chosen && o===chosen;
      return `<div class="aq-opt${on?" chosen":""}">`
        + `<div class="aq-opt-label">${on?"✓ ":""}${esc(o.label||"")}</div>`
        + (o.description?`<div class="aq-opt-desc">${esc(o.description)}</div>`:"")
        + `</div>`;
    }).join("");
    const ansHtml = (ans!==null && ans!==undefined)
      ? `<div class="aq-answer"><span class="aq-answer-lbl">Answer</span>${esc(ans)}</div>`
      : `<div class="aq-answer none"><span class="aq-answer-lbl">No answer</span>(clarified or cancelled)</div>`;
    return `<div class="aq-card">`
      + (q.header?`<div class="aq-header">${esc(q.header)}</div>`:"")
      + `<div class="aq-question">${esc(q.question||"")}</div>`
      + (optHtml?`<div class="aq-opts">${optHtml}</div>`:"")
      + ansHtml
      + `</div>`;
  }).join("");
  return cards || `<div class="muted" style="padding:6px 0">(no questions)</div>`;
}

function renderBlock(b, idx, blocks){
  const aid = `b${idx}`;
  // Thinking blocks are not rendered in the main section at all; their presence
  // is surfaced as a marker on the action that follows.
  if (b.k==="thinking") return "";
  // A message the user queued mid-turn — rendered inline at its injection point
  // as a user bubble, distinct from assistant blocks.
  if (b.k==="queued") return `<div id="${aid}" class="block queued-block scroll-target">`
    + `<span class="pmsg-tag">⏳ queued</span><div class="text-body">${markdown(b.text||"")}</div></div>`;
  const thought = precededByThink(blocks, idx);
  const mark = thought ? THINK_MARK : "";
  if (b.k==="text") return `<div id="${aid}" class="block text scroll-target${thought?" thought":""}">${mark}<div class="text-body">${markdown(b.md)}</div></div>`;
  if (b.k==="tool"){
    // Collapsed summary uses the semantic annotation (e.g. Bash → its
    // description, not the raw command), matching the TOC label.
    const extra = toolAnnotation(b) || argSummary(b.input);
    const res = (b.resultStructured!==null && b.resultStructured!==undefined) ? b.resultStructured : b.result;
    let body = "";
    if (b.name==="AskUserQuestion"){
      // Purpose-built Q&A view instead of raw input/result JSON.
      body = `<div class="aq">${renderAskQuestion(b)}</div>`;
    } else {
      if (b.input!==null && b.input!==undefined) body += valueBlock("Input", b.input);
      if (res!==null && res!==undefined) body += valueBlock("Result", res);
      if (!body) body = `<div class="muted" style="padding:6px 0">(no payload)</div>`;
    }
    // The tool name IS the badge — no separate "TOOL" label (we know it's a tool).
    return `<details id="${aid}" class="block coll tool scroll-target"><summary><span class="badge tool">${esc(b.name)}</span>`
      + (extra?`<span class="sum-extra">${esc(extra)}</span>`:"")
      + (mark?`<span class="spacer-mark"></span>${mark}`:"")
      + `</summary><div class="block-body">${body}</div></details>`;
  }
  return "";
}

// Render a group of consecutive Edits/Reads as one collapsible unit. The anchor
// id is the FIRST member's id (so the TOC entry + scrollspy line up).
function renderGroup(g, blocks){
  const aid = `b${g.members[0].idx}`;
  const mark = g.thought ? THINK_MARK : "";
  const badgeKind = "tool";
  const inner = g.members.map((m)=>{
    const b = m.block;
    const extra = argSummary(b.input);
    const res = (b.resultStructured!==null && b.resultStructured!==undefined) ? b.resultStructured : b.result;
    let body = "";
    if (b.input!==null && b.input!==undefined) body += valueBlock("Input", b.input);
    if (res!==null && res!==undefined) body += valueBlock("Result", res);
    if (!body) body = `<div class="muted" style="padding:6px 0">(no payload)</div>`;
    return `<details class="sub member"><summary><span class="sum-name">${esc(b.name)}</span>`
      + (extra?`<span class="sum-extra">${esc(extra)}</span>`:"")
      + `</summary><div class="sub-body">${body}</div></details>`;
  }).join("");
  return `<details id="${aid}" class="block coll tool group scroll-target"><summary>`
    + `<span class="badge ${badgeKind}">${esc(g.badge)}</span>`
    + `<span class="sum-name">${esc(g.label)}</span>`
    + (g.sub?`<span class="sum-extra">${esc(g.sub)}</span>`:"")
    + (mark?`<span class="spacer-mark"></span>${mark}`:"")
    + `</summary><div class="block-body group-body">${inner}</div></details>`;
}

// A collapsible "pin card": a label header + a body that's capped to 3 lines
// when collapsed, with a "…" overflow hint and click-to-expand. Shared by the
// prompt header and the recap so they look and behave identically.
// `bodyId` lets wirePinCards() find the body to measure overflow; `extraCls`
// lets the body opt into markdown styling (text-body) for the recap.
function pinCard(opts){
  const {label, bodyHtml, bodyId, boxId, extraCls="", collapsed=true} = opts;
  return `<div class="prompt${collapsed?" collapsed":""} pin-card" id="${boxId}" data-tip="Expand / collapse · p">`
    + `<div class="prompt-head">`
    + `<span class="lbl">${label}</span><span class="chev">▶</span></div>`
    + `<div class="pmsgs ${extraCls}" id="${bodyId}">${bodyHtml}</div>`
    + `<div class="pmsgs-fade" aria-hidden="true">…</div></div>`;
}

// The pinned header: the turn's recap (if any) plus the user message(s), both
// sticky at the top of the main pane as collapsible cards. `messages` carries
// the primary prompt plus any folded-in follow-ups and interrupts; falls back
// to the legacy single `prompt` field.
function promptHeader(t){
  const all = (t.messages && t.messages.length)
    ? t.messages
    : [{kind:"prompt", text:t.prompt||""}];
  // Queued messages are rendered inline in the block stream at their injection
  // point, not in this pinned header — exclude them here to avoid duplication.
  const msgs = all.filter(m=>!m.queued);
  const rows = msgs.map(m=>{
    if (m.kind==="interrupt")
      return `<div class="pmsg interrupt"><span class="pmsg-tag">⎋ interrupted</span></div>`;
    return `<div class="pmsg">${esc(m.text||"")}</div>`;
  }).join("");
  const extra = msgs.length>1 ? ` <span class="pcount">+${msgs.length-1} more</span>` : "";

  let html = `<div class="prompt-pin" id="promptPin">`;
  if (t.recap){
    html += pinCard({
      label: `<span class="recap-lbl">✦ Recap</span>`,
      bodyHtml: markdown(t.recap),
      bodyId: "recapBody", boxId: "recapBox", extraCls: "text-body recap-body",
    });
  }
  html += pinCard({
    label: `User · Turn ${t.n}${extra}`,
    bodyHtml: rows, bodyId: "pmsgs", boxId: "promptBox",
    // Start expanded when the header holds more than the primary prompt (e.g.
    // interrupts or resent prompts), so they aren't hidden under the 3-line
    // collapse. Queued msgs render inline, so they don't count here.
    collapsed: msgs.length <= 1,
  });
  html += `</div>`;
  return html;
}

function wireCollapsible(box){
  if (!box) return;
  const body = box.querySelector(".pmsgs");
  // Mark as overflowing when the content is taller than the 3-line collapsed cap
  // (63px). This drives the clamp + the "…" hint. Measured against the cap
  // directly (not clientHeight) since the clamp itself is gated on this class.
  if (body && body.scrollHeight > 63 + 2) box.classList.add("overflowing");
  box.onclick = (e)=>{
    if (e.target.closest("a")) return;
    const sel = window.getSelection && window.getSelection();
    if (sel && String(sel).length) return;  // user is selecting text, not toggling
    box.classList.toggle("collapsed");
  };
}

function wirePromptHeader(){
  document.querySelectorAll(".prompt-pin .pin-card").forEach(wireCollapsible);
}

function renderTurn(t){
  const main = $("main");
  if (!t){ main.innerHTML = `<div class="empty">No turns yet.</div>`; return; }
  // A compaction turn is a single collapsible card holding the summary that the
  // CLI injected when the conversation was continued past its context window.
  if (t.isCompaction){
    main.innerHTML =
      `<details id="b0" class="compaction scroll-target" open><summary>`
      + `<span class="clbl">✦ Conversation compacted</span>`
      + `<span class="cnote">— summary of the earlier conversation</span>`
      + `</summary><div class="cbody text-body">${markdown(t.compaction||t.prompt||"")}</div></details>`;
    main.scrollTop = 0;
    setMeta(t);
    renderToc(t);
    return;
  }
  let html = "";
  // Pinned, collapsible header. Sticks to the top of the main pane: the turn's
  // recap (if any) and the user message(s), each collapsed to 3 lines with
  // click-to-expand.
  html += promptHeader(t);
  html += groupBlocks(t.blocks).map((it)=>{
    if (it.type==="group") return renderGroup(it, t.blocks);
    return renderBlock(it.block, it.idx, t.blocks);
  }).join("");
  main.innerHTML = html;
  wirePromptHeader();
  main.scrollTop = 0;
  setMeta(t);
  renderToc(t);
}

// Compact one-line-ish meta: clean model name · short date; branch only if it's
// a real branch (not a detached "HEAD").
function cleanModel(s){
  if (!s) return "";
  let m = String(s).split("/").pop();              // drop bedrock/vertex path
  m = m.replace(/^(us|eu|apac)\./,"")              // region prefix
       .replace(/^anthropic\./,"")                 // provider prefix
       .replace(/^@[a-z0-9-]+\//,"");              // @gateway/ prefix
  return m;
}
function fmtTs(s){
  if (!s) return "";
  return String(s).replace("T"," ").replace(/\.\d+Z?$/,"").replace("Z","").replace(/:\d{2}$/,"");
}
function setMeta(t){
  const bits = [];
  const model = cleanModel(t.model);
  if (model) bits.push(`<span class="mi model">${esc(model)}</span>`);
  if (t.branch && t.branch!=="HEAD") bits.push(`<span class="mi">⌥ ${esc(t.branch)}</span>`);
  if (t.ts) bits.push(`<span class="mi">${esc(fmtTs(t.ts))}</span>`);
  $("hmeta").innerHTML = bits.join("");
}

// Right column: a table of contents of the blocks WITHIN the current turn.
function renderToc(t){
  const toc = $("toc");
  if (t && t.isCompaction){
    toc.innerHTML = `<button class="toc-item active" data-aid="b0"><span class="dot think"></span>`
      + `<span class="tmeta"><span class="tlabel">Compaction</span><span class="tsub">summary</span></span></button>`;
    toc.querySelector(".toc-item").addEventListener("click", ()=>{
      const el = $("b0"); if (el){ el.open = true; el.scrollIntoView({behavior:"smooth", block:"start"}); }
    });
    return;
  }
  if (!t || !t.blocks.length){ toc.innerHTML = `<div class="muted" style="padding:8px;font-size:12px">No blocks.</div>`; return; }
  toc.innerHTML = groupBlocks(t.blocks).map((it)=>{
    let kind, label, sub, aid, thought;
    if (it.type==="group"){
      kind = "tool"; label = it.label; sub = it.sub;
      aid = `b${it.members[0].idx}`; thought = it.thought;
    } else {
      const b = it.block;
      // Thinking blocks are never listed; the action they precede is marked.
      if (b.k==="thinking") return "";
      const tl = tocLabel(b, it.idx);
      kind = tl.kind; label = tl.label; sub = tl.sub;
      aid = `b${it.idx}`; thought = precededByThink(t.blocks, it.idx);
    }
    const subHtml = sub? `<span class="tsub">${esc(sub)}</span>` : "";
    const mark = thought ? `<span class="think-mark" title="preceded by thinking">✦</span>` : "";
    return `<button class="toc-item" data-aid="${aid}"><span class="dot ${kind}"></span>`
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
  blocks.forEach((el)=>{ if (el.offsetTop - 88 <= top) activeAid = el.id; });  // offset for sticky header
  const toc = $("toc");
  let activeEl = null;
  toc.querySelectorAll(".toc-item").forEach((el)=>{
    const on = el.dataset.aid===activeAid;
    el.classList.toggle("active", on);
    if (on) activeEl = el;
  });
  // Keep the highlighted TOC entry visible when it scrolls out of the column.
  // The SCROLL CONTAINER is the <aside class="toc"> wrapper (it has overflow-y),
  // not the inner #toc div — so adjust the wrapper's scrollTop. Compare against
  // the wrapper's viewport rect.
  if (activeEl){
    const sc = toc.closest("aside.toc") || toc.parentElement || toc;
    const r = activeEl.getBoundingClientRect(), pr = sc.getBoundingClientRect();
    if (r.top < pr.top) sc.scrollTop -= (pr.top - r.top) + 8;
    else if (r.bottom > pr.bottom) sc.scrollTop += (r.bottom - pr.bottom) + 8;
  }
}

function renderTurnList(){
  const list = $("turnlist");
  list.innerHTML = TURNS.map((t,idx)=>{
    if (t.isCompaction){
      return `<button class="trow compaction-row ${idx===cur?'active':''}" data-i="${idx}">`
        + `<span class="mn">✦ #${t.n}</span>`
        + `<div class="msnip">Conversation compacted</div></button>`;
    }
    const c = t.counts||{};
    const icons = [];
    // Tool use first (far left), then thinking (muted ✦), then text responses.
    if (c.tool)     icons.push(`<span class="i" title="${c.tool} tool use${c.tool>1?'s':''}">🔧 ${c.tool}</span>`);
    if (c.thinking) icons.push(`<span class="i think" title="${c.thinking} thinking block${c.thinking>1?'s':''}">✦ ${c.thinking}</span>`);
    if (c.text)     icons.push(`<span class="i" title="${c.text} response block${c.text>1?'s':''}">¶ ${c.text}</span>`);
    // Follow-up prompts / interrupts that share this turn are listed beneath the
    // primary snippet, so a grouped turn reads as one unit in the sidebar.
    const msgs = t.messages||[];
    let sub = "";
    if (msgs.length>1){
      sub = `<div class="msubs">` + msgs.slice(1).map(m=>{
        if (m.kind==="interrupt") return `<div class="msub interrupt">⎋ interrupted</div>`;
        const snip = (m.text||"").replace(/\s+/g," ").slice(0,46);
        const mark = m.queued ? "⏳" : "↳";
        return `<div class="msub${m.queued?' queued':''}">${mark} ${esc(snip)}</div>`;
      }).join("") + `</div>`;
    }
    return `<button class="trow ${idx===cur?'active':''}" data-i="${idx}">`
      + `<div class="trow-head"><span class="mn">#${t.n}</span>`
      + `<div class="micons">${icons.join("")}</div></div>`
      + `<div class="msnip">${esc(t.snippet||'')}</div>`
      + sub
      + `</button>`;
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

// URL <-> turn sync. The query param `page` carries the TURN NUMBER (t.n, the
// "#21" shown in the UI), not the array index, so links are stable and human.
function turnIndexForPage(){
  try {
    const raw = new URLSearchParams(location.search).get("page");
    if (raw === null) return null;
    const n = parseInt(raw, 10);
    if (!Number.isFinite(n)) return null;
    const idx = TURNS.findIndex(t => t.n === n);
    return idx >= 0 ? idx : null;
  } catch(e){ return null; }
}
function syncUrl(){
  if (!TURNS.length || !TURNS[cur]) return;
  try {
    const url = new URL(location.href);
    url.searchParams.set("page", TURNS[cur].n);
    history.replaceState(null, "", url);  // replace (not push) so arrow-nav doesn't flood history
  } catch(e){}  // file:// can reject history API in some browsers — nav still works
}

function go(i){
  if (!TURNS.length) { renderTurn(null); renderToc(null); syncNav(); return; }
  cur = Math.max(0, Math.min(TURNS.length-1, i));
  renderTurn(TURNS[cur]);
  renderTurnList();
  syncNav();
  syncTocActive();
  syncUrl();
  // Move focus to the scroll container so Up/Down/PageUp/PageDown scroll the
  // turn body immediately — without this, after arrow-key turn nav the keyboard
  // focus stays on <body> and those keys do nothing until you click main.
  // preventScroll: we've already reset scrollTop in renderTurn.
  $("main").focus({preventScroll:true});
}

$("first").onclick = ()=>go(0);
$("prev").onclick  = ()=>go(cur-1);
$("next").onclick  = ()=>go(cur+1);
$("last").onclick  = ()=>go(TURNS.length-1);
$("toggleSide").onclick = toggleSideCollapsed;
$("toggleToc").onclick = toggleTocCollapsed;
$("tocCornerToggle").onclick = toggleTocCollapsed;

// Drag-to-resize the sidebars. Each handle drives a CSS var on <body>; the grid
// columns read those vars. `edge` is which screen edge the sidebar is anchored
// to: "left" sidebar grows as the mouse moves right, "right" as it moves left.
function makeResizer(handle, cssVar, edge, min, max, lsKey){
  if (!handle) return;
  handle.addEventListener("mousedown", (e)=>{
    e.preventDefault();
    document.body.classList.add("resizing");
    let last = null;
    const move = (ev)=>{
      const w = edge==="left" ? ev.clientX : (window.innerWidth - ev.clientX);
      const clamped = Math.max(min, Math.min(max, w));
      last = clamped + "px";
      document.body.style.setProperty(cssVar, last);
    };
    const up = ()=>{
      document.body.classList.remove("resizing");
      document.removeEventListener("mousemove", move);
      document.removeEventListener("mouseup", up);
      if (last) saveLayout({[lsKey]: last});  // persist the final width
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
  });
  // Double-click resets to the default width (and clears the saved override).
  handle.addEventListener("dblclick", ()=>{
    document.body.style.removeProperty(cssVar);
    saveLayout({[lsKey]: null});
  });
}
makeResizer($("sideResizer"), "--side-w", "left", 160, 560, "sideW");
makeResizer($("tocResizer"), "--toc-w", "right", 150, 520, "tocW");

// Custom tooltips: instant, no native-title delay. One shared element follows
// the hovered [data-tip] target, clamped to the viewport. Event-delegated so it
// covers dynamically-rendered elements (prompt cards) too.
(function tooltips(){
  const tip = document.createElement("div");
  tip.id = "tooltip"; document.body.appendChild(tip);
  let cur = null;
  function place(el){
    const txt = el.getAttribute("data-tip"); if (!txt) return;
    // Text after a "·" separator is the hotkey — color it distinctly.
    const sep = txt.indexOf("·");
    if (sep >= 0){
      tip.innerHTML = esc(txt.slice(0, sep).trim())
        + ` <span class="tip-key">${esc(txt.slice(sep+1).trim())}</span>`;
    } else {
      tip.textContent = txt;
    }
    tip.classList.add("show");
    const r = el.getBoundingClientRect();
    const tr = tip.getBoundingClientRect();
    let top = r.bottom + 6, left = r.left + r.width/2 - tr.width/2;
    if (top + tr.height > window.innerHeight - 4) top = r.top - tr.height - 6;  // flip above
    left = Math.max(6, Math.min(left, window.innerWidth - tr.width - 6));        // clamp x
    tip.style.top = top + "px"; tip.style.left = left + "px";
  }
  document.addEventListener("mouseover",(e)=>{
    const el = e.target.closest("[data-tip]");
    if (el===cur) return;
    cur = el;
    if (el) place(el); else tip.classList.remove("show");
  });
  document.addEventListener("mouseout",(e)=>{
    if (cur && !e.relatedTarget?.closest?.("[data-tip]")){ cur=null; tip.classList.remove("show"); }
  });
  // Hide on click/scroll so a stale tip doesn't linger after the layout shifts.
  document.addEventListener("click",()=>{ cur=null; tip.classList.remove("show"); }, true);
  window.addEventListener("scroll",()=>{ cur=null; tip.classList.remove("show"); }, true);
})();

$("main").addEventListener("scroll", syncTocActive, {passive:true});
document.addEventListener("keydown",(e)=>{
  if (e.target.tagName==="INPUT"||e.target.tagName==="TEXTAREA") return;
  // Modifier hotkeys: Alt+M / Alt+R toggle the sidebars, Ctrl+↑/↓ navigate turns.
  // Use e.code (physical key) for the Alt combos — on macOS, Alt+letter mutates
  // e.key into a special character ("µ" for Alt+M), so e.key checks never match.
  if (e.altKey && !e.ctrlKey && !e.metaKey && e.code==="KeyM"){
    e.preventDefault(); toggleSideCollapsed(); return;
  }
  if (e.altKey && !e.ctrlKey && !e.metaKey && e.code==="KeyR"){
    e.preventDefault(); toggleTocCollapsed(); return;
  }
  if (e.ctrlKey && !e.altKey && !e.metaKey && (e.key==="ArrowUp"||e.key==="ArrowDown")){
    e.preventDefault(); go(cur + (e.key==="ArrowDown" ? 1 : -1)); return;
  }
  if (e.altKey || e.ctrlKey || e.metaKey) return;  // leave other modified keys alone
  if (e.key==="ArrowLeft"){ go(cur-1); }
  else if (e.key==="ArrowRight"){ go(cur+1); }
  else if (e.key==="Home"){ go(0); }
  else if (e.key==="End"){ go(TURNS.length-1); }
  else if (e.key==="["){ toggleSideCollapsed(); }
  else if (e.key==="]"){ toggleTocCollapsed(); }
  else if (e.key==="p"){ const b=$("promptBox"); if (b) b.classList.toggle("collapsed"); }
});

renderTurnList();
// Open the turn named by ?page=<turn-number>, else the latest turn.
const _startIdx = turnIndexForPage();
go(_startIdx !== null ? _startIdx : (TURNS.length ? TURNS.length-1 : 0));

// ---- live auto-refresh (file:// friendly, no server) ----
// fetch() is blocked under file://, but injecting a <script> is not — the page
// already loads pending.js that way. We periodically re-inject a cache-busted
// pending.js and watch window.__SIG__ (the transcript byte offset, which only
// grows). When it advances: if you're viewing the LATEST turn, reload to follow
// (tail -f style); otherwise show a dismissible pill so history browsing isn't
// interrupted. Skipped for bundled snapshots (data is inlined, no sibling file).
(function liveRefresh(){
  const linked = !!document.querySelector('script[src="pending.js"]');
  if (!linked) return;                       // bundled/standalone — nothing to poll
  const POLL_MS = 2500;
  let lastSig = (typeof window.__SIG__ === "number") ? window.__SIG__ : 0;
  let busy = false;

  function pill(){
    let el = document.getElementById("newpill");
    if (el) return el;
    el = document.createElement("button");
    el.id = "newpill"; el.className = "newpill"; el.textContent = "↑ New content — click to update";
    el.onclick = ()=>location.reload();
    document.body.appendChild(el);
    return el;
  }
  function onSig(sig){
    if (sig === lastSig) return;
    lastSig = sig;
    // Follow only when parked on the latest turn AND scrolled near its end,
    // so an in-progress turn you're reading isn't yanked out from under you.
    const onLatest = (cur >= TURNS.length - 1);
    if (onLatest){
      // Drop ?page= so we land on the NEW latest turn after reload (a fresh
      // turn may have been appended), rather than pinning to the old one.
      try { const u=new URL(location.href); u.searchParams.delete("page"); history.replaceState(null,"",u); } catch(e){}
      location.reload();
    }
    else pill().style.display = "block";
  }
  function poll(){
    if (busy) return; busy = true;
    const s = document.createElement("script");
    s.src = "pending.js?_=" + Date.now();
    s.onload = ()=>{ busy = false; s.remove();
      onSig((typeof window.__SIG__ === "number") ? window.__SIG__ : lastSig); };
    s.onerror = ()=>{ busy = false; s.remove(); };
    document.head.appendChild(s);
  }
  setInterval(poll, POLL_MS);
})();
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

    if args[0] == "--watch":
        # Detached background child spawned by the Stop hook. Picks up the recap
        # (and any other late-arriving records) a few minutes after the turn.
        if len(args) < 2:
            return 0
        try:
            return watch(Path(args[1]).expanduser())
        except Exception:
            return 0  # never let the watcher surface an error

    if args[0] == "--hook":
        raw = sys.stdin.read()
        try:
            payload = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            payload = {}
        tp = payload.get("transcript_path")
        if not tp:
            return 0  # nothing to do; never block the hook
        transcript = Path(tp).expanduser()
        try:
            summary = process(transcript)
            print(json.dumps(summary))
        except Exception as e:  # never fail a Stop hook
            print(f"transcript-html: {e}", file=sys.stderr)
        # Spawn a detached watcher so the recap (which lands minutes later) is
        # picked up live. Singleton-locked, self-terminating — not a server.
        spawn_watcher(transcript)
        return 0

    flush = False
    open_only = False
    rebuild = False
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
        elif a in ("--rebuild", "-r"):
            rebuild = True
        elif a == "--bundle":
            bundle_dest = ""  # signal: bundle, dest decided below
            # optional next arg is the destination path (if it isn't a flag)
            if idx + 1 < len(args) and not args[idx + 1].startswith("-"):
                bundle_dest = args[idx + 1]
                skip.add(idx + 1)
        else:
            rest.append(a)

    if not rest:
        print("usage: render.py <sessionId|path> [--flush] [--open] [--rebuild] [--bundle [dest.html]]", file=sys.stderr)
        return 2

    transcript = resolve_transcript(rest[0])
    summary = process(transcript, flush=True if bundle_dest is not None else flush,
                      rebuild=rebuild)

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
