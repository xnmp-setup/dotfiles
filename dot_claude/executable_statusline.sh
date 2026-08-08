#!/usr/bin/env bash
# Wrapper around ccstatusline that recolors the context bar based on usage %.
# ccstatusline reads JSON from stdin, so we tee stdin to it.

# Force a wide effective width so ccstatusline never truncates the line.
# Truncation clips the (last) context bar mid-draw and appends "...", which
# (a) breaks the rebuild_context_bar regex below and (b) strips the "(N%)"
# the color picker greps for. The bar width is fixed (16 chars) regardless of
# this value, so a large width only prevents truncation — no visual downside.
# CCSTATUSLINE_WIDTH is checked first in ccstatusline's width probe and wins.
#
# Capture stdin once (ccstatusline consumes it, but we also need the raw JSON to
# read the real session cost that Claude Code passes as cost.total_cost_usd).
INPUT=$(cat)

# Claude Code exposes subscription usage windows only to its status-line stdin.
# Persist that non-secret quota snapshot for the desktop bar; absent/malformed
# payloads leave the last good cache intact, and the reader expires old windows.
if [ -x "${HOME}/.local/bin/ai-usage-stream" ]; then
  printf '%s' "$INPUT" \
    | "${HOME}/.local/bin/ai-usage-stream" --capture-claude >/dev/null 2>&1 \
    || true
fi

OUTPUT=$(printf '%s' "$INPUT" | CCSTATUSLINE_WIDTH=1000 bunx -y ccstatusline@latest 2>/dev/null)

# Two costs from the statusline stdin JSON:
#   SESSION_COST  - cumulative session cost, the authoritative cost.total_cost_usd
#   LAST_MSG_COST - cost of the last user turn, priced from the transcript's token
#                   usage (Claude Code doesn't report a per-turn cost). "Last turn"
#                   = the most recent real user message and every assistant response
#                   (incl. subagents) after it. Rates are per 1M tokens; cache write
#                   is 1.25x input for 5m TTL and 2x for 1h; cache read is 0.1x.
COSTS=$(printf '%s' "$INPUT" | python3 -c '
import sys, json, os

PRICES = {
    "Opus":   {"in": 5.0,  "out": 25.0, "cw5": 6.25, "cw1h": 10.0, "cr": 0.5},
    "Sonnet": {"in": 3.0,  "out": 15.0, "cw5": 3.75, "cw1h": 6.0,  "cr": 0.3},
    "Haiku":  {"in": 1.0,  "out": 5.0,  "cw5": 1.25, "cw1h": 2.0,  "cr": 0.1},
    "Fable":  {"in": 10.0, "out": 50.0, "cw5": 12.5, "cw1h": 20.0, "cr": 1.0},
}

def family(model):
    lo = (model or "").lower()
    for name in ("Opus", "Sonnet", "Haiku", "Fable"):
        if name.lower() in lo:
            return name
    return "Opus"

def is_real_user(entry):
    # A human turn, not a tool_result carrier.
    if entry.get("type") != "user":
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") != "tool_result" for b in content)
    return False

def msg_cost(entry):
    msg = entry.get("message", {})
    u = msg.get("usage") or {}
    p = PRICES[family(msg.get("model"))]
    cc = u.get("cache_creation") or {}
    cc5 = cc.get("ephemeral_5m_input_tokens")
    cc1h = cc.get("ephemeral_1h_input_tokens")
    if cc5 is None and cc1h is None:
        cc5, cc1h = u.get("cache_creation_input_tokens", 0) or 0, 0
    return (
        (u.get("input_tokens", 0) or 0) * p["in"]
        + (u.get("output_tokens", 0) or 0) * p["out"]
        + (u.get("cache_read_input_tokens", 0) or 0) * p["cr"]
        + (cc5 or 0) * p["cw5"]
        + (cc1h or 0) * p["cw1h"]
    ) / 1e6

try:
    data = json.load(sys.stdin)
except Exception:
    print("\t"); sys.exit()

session_cost = data.get("cost", {}).get("total_cost_usd", "")
tpath = data.get("transcript_path", "")

last_cost = ""
if tpath and os.path.exists(tpath):
    try:
        entries = []
        for ln in open(tpath).read().splitlines():
            if ln.strip():
                try:
                    entries.append(json.loads(ln))
                except Exception:
                    pass
        # Last main-chain human turn marks the start of the current turn.
        start = None
        for i in range(len(entries) - 1, -1, -1):
            if not entries[i].get("isSidechain") and is_real_user(entries[i]):
                start = i
                break
        if start is not None:
            # Dedupe by message id: one assistant message is often logged on
            # several transcript lines (one per content block), but its usage is
            # billed once per API response. Summing raw lines multi-counts cost.
            seen, total = set(), 0.0
            for e in entries[start + 1:]:
                if e.get("type") != "assistant":
                    continue
                mid = e.get("message", {}).get("id") or e.get("requestId")
                if mid is not None:
                    if mid in seen:
                        continue
                    seen.add(mid)
                total += msg_cost(e)
            last_cost = total
    except Exception:
        pass

# --- countdown + cost to re-warm the cache on the NEXT message ---
# Claude Code writes a 1h prompt cache, refreshed on each use, so it survives as
# a block until ~1h after the last reply, then dies all at once. The re-warm
# cost is therefore FIXED (full cached context x 1h write rate) and only the
# *timing* is uncertain:
#   rewarm      = that fixed cost, charged on the next message once the cache dies
#   mins_left   = minutes until it dies (0 = already expired)
#   frac_cached = fraction of the 1h window still remaining (drives the color)
rewarm, mins_left, frac_cached, age_min = "", "", "", ""
try:
    import time as _time
    from datetime import datetime
    TTL = 3600.0
    last_asst = None
    for e in entries:
        if e.get("type") == "assistant" and e.get("message", {}).get("usage"):
            last_asst = e
    if last_asst is not None and last_asst.get("timestamp"):
        u = last_asst["message"]["usage"]
        cc = u.get("cache_creation") or {}
        cw_tok = (cc.get("ephemeral_5m_input_tokens", 0) or 0) + (cc.get("ephemeral_1h_input_tokens", 0) or 0)
        if cw_tok == 0:
            cw_tok = u.get("cache_creation_input_tokens", 0) or 0
        ctx = (u.get("cache_read_input_tokens", 0) or 0) + cw_tok
        rate = PRICES[family(last_asst["message"].get("model"))]["cw1h"]
        ts = datetime.fromisoformat(last_asst["timestamp"].replace("Z", "+00:00"))
        idle = _time.time() - ts.timestamp()
        rewarm = ctx * rate / 1e6
        mins_left = max(0.0, (TTL - idle) / 60.0)
        frac_cached = min(1.0, max(0.0, (TTL - idle) / TTL))
        age_min = idle / 60.0  # unclamped: real age of the last reply, drives the expiry banner
except Exception:
    pass

print(f"{session_cost}\t{last_cost}\t{rewarm}\t{mins_left}\t{frac_cached}\t{age_min}")
')
IFS=$'\t' read -r SESSION_COST LAST_MSG_COST REWARM MINS_LEFT FRAC_CACHED AGE_MIN <<< "$COSTS"

# The context-bar color is computed continuously (green->yellow->red) inside
# rebuild_context_bar from the fill proportion, so no threshold bucketing here.
echo "$OUTPUT" \
  | sed \
      -e 's|\.\.\./||g' \
  | SESSION_COST="$SESSION_COST" LAST_MSG_COST="$LAST_MSG_COST" \
    REWARM="$REWARM" MINS_LEFT="$MINS_LEFT" FRAC_CACHED="$FRAC_CACHED" AGE_MIN="$AGE_MIN" python3 -c '
import sys, re, os

FAMILIES = ("Opus", "Sonnet", "Haiku", "Fable")

def shorten_model(text):
    lo = text.lower()
    for name in FAMILIES:
        if name.lower() in lo:
            return name
    return text

BG_EMPTY = "238"  # gray bg for empty portion (lighter than 236, keeps contrast)
FG_ON_FILL = "0"  # black text on the bright filled portion

# Continuous context-bar color. The fill proportion maps to a smooth
# green -> yellow -> red gradient (truecolor RGB) instead of 3 discrete buckets.
# Fully red is reached exactly at the auto-compaction cutoff, so t = proportion /
# cutoff clamped to [0,1] and the fill colour aligns with the red cutoff line.
# Stops match the old ansi256 palette:
#   green  #87d787 (was 114) -> yellow #ffd75f (was 221) -> red #ff5f5f (203).
_GRADIENT = ((0.0, (135, 215, 135)), (0.5, (255, 215, 95)), (1.0, (255, 95, 95)))

def bar_color(proportion, cutoff=0.8):
    t = max(0.0, min(1.0, proportion / cutoff if cutoff else proportion))
    for i in range(len(_GRADIENT) - 1):
        t0, c0 = _GRADIENT[i]
        t1, c1 = _GRADIENT[i + 1]
        if t <= t1:
            s = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * s) for a, b in zip(c0, c1))
    return _GRADIENT[-1][1]

# Auto-compaction cutoff. Claude Code compacts when the used context reaches
# (window - 13000) tokens -- a FIXED ~13k output-token headroom, not a fixed
# percentage. So the cutoff as a fraction of the window varies with window size:
# 200k -> 93.5%, 1M -> 98.7%. (Verified in the CLI binary: c9l() triggers
# "compact" at used >= Wln() == window - 13000.) CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
# can only LOWER it. The 0.2 "precomputeBufferFraction" is a prep threshold, not
# the trigger, so it is intentionally ignored here.
COMPACT_RESERVE_TOKENS = 13000

# Usable budget before auto-compaction, when CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
# pulls the trigger below the native ceiling. The context window itself does not
# shrink -- the model still accepts the full 1M -- so the bar keeps measuring
# real tokens, but the number that matters day to day is how far you are from
# compaction, not from a ceiling you will never reach. Mirrors the CLI formula
# (verified in the binary): threshold = min(window * pct/100, window - 13000).
#
# Returns None when no override is set, leaving the bar exactly as it was, so
# this stays correct on a machine that does not set the variable.
#
# NOTE: no apostrophes anywhere in this block — it is a single-quoted shell
# string, so one would end it early.
def compact_budget_tokens(window_tokens):
    ov = os.environ.get("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "").strip()
    if not window_tokens or not ov or window_tokens <= COMPACT_RESERVE_TOKENS:
        return None
    try:
        pct = float(ov)
    except ValueError:
        return None
    if not 0 < pct <= 100:
        return None
    budget = min(window_tokens * pct / 100.0, window_tokens - COMPACT_RESERVE_TOKENS)
    return budget if budget > 0 else None

def compact_cutoff_fraction(window_tokens):
    """Fraction of the full window at which auto-compaction fires, or None if the
    window is unknown / too small to reason about."""
    if not window_tokens or window_tokens <= COMPACT_RESERVE_TOKENS:
        return None
    thresh = window_tokens - COMPACT_RESERVE_TOKENS
    ov = os.environ.get("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "").strip()
    if ov:
        try:
            pct = float(ov)
            if 0 < pct <= 100:
                thresh = min(thresh, window_tokens * pct / 100.0)
        except ValueError:
            pass
    return thresh / window_tokens

# Cache-read price per 1M tokens = input price x 0.1 (the 90% prompt-cache
# discount). Every model request (agent "step") re-sends the whole context as
# cached input, so the marginal cost of one step ~= context_tokens x cache_read.
# One user message can span many steps (each tool result triggers another).
#   Opus 4.8 $5/M, Sonnet 5 $3/M, Haiku 4.5 $1/M, Fable 5 $10/M input.
CACHE_READ_PRICE = {"Opus": 0.50, "Sonnet": 0.30, "Haiku": 0.10, "Fable": 1.00}

def parse_tokens(s):
    m = re.match(r"([0-9.]+)([kKmM]?)", s)
    if not m:
        return None
    val = float(m.group(1))
    suf = m.group(2).lower()
    if suf == "k":
        val *= 1e3
    elif suf == "m":
        val *= 1e6
    return val

def format_tokens(val):
    """Inverse of parse_tokens, matching the ccstatusline style: 400000 -> 400k,
    1000000 -> 1.0M."""
    if val >= 1e6:
        return f"{val / 1e6:.1f}M"
    return f"{round(val / 1e3)}k"

def format_cost(usd):
    if usd >= 1:
        return f"${usd:.2f}"
    cents = usd * 100
    if cents >= 10:
        return f"{round(cents)}c"
    if cents >= 1:
        return f"{cents:.1f}c"
    return "<1c"

def rebuild_context_bar(m):
    """Replace [████░░░░] Xk/Yk (N%) with a text-inside-bar using bg colors."""
    fg_code = m.group(1)  # the ansi256 fg color code number
    bar = m.group(2)      # e.g. ████████░░░░░░░░
    label = m.group(3)    # e.g. 203k/1.0M (20%)

    filled = bar.count("█")
    bar_width = filled + bar.count("░")
    if bar_width == 0:
        return m.group(0)

    proportion = filled / bar_width

    # Reformat label "203k/1.0M (20%)" -> "20% of 1.0M". Capture the window size
    # (the "/1.0M" total) in tokens so the cutoff marker can be placed correctly.
    window = None
    cutoff = None
    mm = re.search(r"([0-9.]+[kKmM]?)\s*/\s*([0-9.]+[kKmM]?)\s*\((\d+)%\)", label)
    if mm:
        used_txt, total, pct = mm.group(1), mm.group(2), mm.group(3)
        window = parse_tokens(total)
        # ccstatusline measures both the percentage and the ░/█ fill against the
        # native window. With an autocompact override that ceiling is no longer
        # the number that matters, so re-base both on the compaction budget:
        # 100% then means "compacting now" rather than "window full", and the
        # gradient below reaches full red at exactly that point.
        budget = compact_budget_tokens(window)
        used = parse_tokens(used_txt)
        if budget and used is not None:
            proportion = min(1.0, used / budget)
            pct = str(round(proportion * 100))
            total = format_tokens(budget)
            cutoff = 1.0  # proportion is already relative to compaction
        label = f"{pct}% of {total}"
    else:
        # Fallback: just shorten 1000k -> 1m if the format is unexpected.
        label = re.sub(r"(\d+)000k", r"\g<1>m", label)

    # Constant-width bar (20 chars), independent of label length.
    full_width = 20

    # Pad label to full width, centered
    text = label.center(full_width)

    # Split at the proportional fill point
    split = round(proportion * full_width)
    text_filled = text[:split]
    text_empty = text[split:]

    # Fill colour ramps to full red at the auto-compaction cutoff (fall back to
    # 0.8 of the window when the window size is unknown).
    r, g, b = bar_color(proportion, cutoff or compact_cutoff_fraction(window) or 0.8)

    # Filled: bg is the (continuous) bar color, text is black
    # Empty: grey bg, text in the bar color
    result = ""
    if text_filled:
        result += f"\x1b[48;2;{r};{g};{b};38;5;{FG_ON_FILL}m{text_filled}"
    if text_empty:
        result += f"\x1b[48;5;{BG_EMPTY};38;2;{r};{g};{b}m{text_empty}"
    result += "\x1b[0m"
    return result

SEP = " | "  # separator used by ccstatusline (can be NBSP or regular space)
NBSP_SEP = "\xa0|\xa0"

for line in sys.stdin:
    # capture current context tokens from the raw bar ("[████░░] 203k/1.0M ...")
    # before rebuild_context_bar reformats the label and drops the token count.
    ctx_tokens = None
    mt = re.search(r"\[[█░]+\]\s*([0-9.]+[kKmM]?)\s*/", line)
    if mt:
        ctx_tokens = parse_tokens(mt.group(1))
    # strip "no git" and the orphaned separator+color it leaves behind
    line = line.replace("⎇\xa0no\xa0git", "")
    line = re.sub(r"\x1b\[38;5;\d+m\x1b\[39m\xa0\|\xa0", "", line)
    # shorten model name to just the family and recolor orange
    # model uses color 30 (dark teal) from ccstatusline
    MODEL_COLORS = {"Opus": "208", "Sonnet": "216", "Haiku": "223", "Fable": "204"}
    def recolor_model(m2):
        name = shorten_model(m2.group(1))
        color = MODEL_COLORS.get(name, "208")
        return f"\x1b[38;5;{color}m{name}"
    line = re.sub(r"\x1b\[38;5;30m([^\x1b]+)", recolor_model, line)
    # remove separator: cwd | branch (after \e[49m, before \e[38;5;155m⎇)
    line = re.sub(r"(\x1b\[49m)\xa0\|\xa0(\x1b\[38;5;\d+m⎇)", r"\1 \2", line)
    # remove separator: model | bar (before \e[38;5;Nm[ where [ starts the bar)
    line = re.sub(r"\xa0\|\xa0(\x1b\[38;5;\d+m\[)", r" \1", line)
    # 1000k -> 1m (for parts outside the context bar)
    line = re.sub(r"(\d+)000k", r"\g<1>m", line)
    # rebuild context bar: match \e[38;5;Nm[████░░░░] Xk/Yk (N%)\e[39m
    line = re.sub(
        r"\x1b\[38;5;(\d+)m\[([█░]+)\]\s+([^\x1b]+)\x1b\[39m",
        rebuild_context_bar,
        line
    )
    # append estimated cached cost per step: context_tokens x cache_read_price.
    # model family is detected from the recolored model segment (its color code
    # is set only by recolor_model above, so this never false-matches cwd/branch).
    if ctx_tokens:
        mm = re.search(r"\x1b\[38;5;(?:208|216|223|204)m(Opus|Sonnet|Haiku|Fable)", line)
        if mm:
            price = CACHE_READ_PRICE.get(mm.group(1))
            if price:
                cost = ctx_tokens * price / 1e6
                seg = f" \x1b[38;5;245m~{format_cost(cost)}/step\x1b[0m"
                line = line.rstrip("\n") + seg + "\n"
    # cache re-warm countdown (⟳ COST in Nm): fixed cost to rebuild the prompt
    # cache once it expires, and how long until that happens. Color = proportion
    # of the 1h window still warm: muted green >=80%, amber >=50%, red <50%.
    rewarm = os.environ.get("REWARM", "").strip()
    mins_left = os.environ.get("MINS_LEFT", "").strip()
    fc = os.environ.get("FRAC_CACHED", "").strip()
    if rewarm and mins_left and fc:
        try:
            rv, ml, fcv = float(rewarm), float(mins_left), float(fc)
        except ValueError:
            rv = None
        # Only surface the countdown once the cache is within 45m of expiring —
        # earlier than that it is just noise (plenty of runway, always green).
        # Below 1m the cache is (about to be) dead and the cold notice further
        # down says so — showing both would just repeat the same fact twice.
        if rv is not None and 1 <= ml < 45:
            col = "203" if fcv < 0.5 else "179" if fcv < 0.8 else "108"
            when = f"in {int(round(ml))}m"
            seg = f"  \x1b[38;5;{col}m⟳{format_cost(rv)} {when}\x1b[0m"
            line = line.rstrip("\n") + seg + "\n"
    # append cost of the last user turn (blue, "+" = accrued this turn)
    last_cost = os.environ.get("LAST_MSG_COST", "").strip()
    if last_cost:
        try:
            usd = float(last_cost)
        except ValueError:
            usd = None
        if usd is not None:
            seg = f"  \x1b[38;5;111m+{format_cost(usd)}\x1b[0m"
            line = line.rstrip("\n") + seg + "\n"
    # append actual cumulative session cost on the far right (gold), from the
    # real total_cost_usd Claude Code reports — not the per-step estimate above.
    session_cost = os.environ.get("SESSION_COST", "").strip()
    if session_cost:
        try:
            usd = float(session_cost)
        except ValueError:
            usd = None
        if usd is not None:
            seg = f"  \x1b[38;5;220m{format_cost(usd)}\x1b[0m"
            line = line.rstrip("\n") + seg + "\n"
    # Expiry notice: if the last reply is over an hour old the 1h prompt cache is
    # dead, so the next message pays full re-warm. AGE_MIN is recomputed live at
    # every render (needs refreshInterval in settings, else the statusline freezes
    # while idle and this never fires). Printed as its own leading line so it is
    # not missed, but in a muted red — no blinking, no filled background.
    age_min = os.environ.get("AGE_MIN", "").strip()
    if age_min:
        try:
            am = float(age_min)
        except ValueError:
            am = None
        if am is not None and am > 60:
            rw = os.environ.get("REWARM", "").strip()
            try:
                cost_txt = f", next msg re-warms {format_cost(float(rw))}" if rw else ""
            except ValueError:
                cost_txt = ""
            notice = (
                f"\x1b[38;5;131m⚠ cache cold — last reply {int(round(am))}m ago"
                f"{cost_txt}\x1b[0m\n"
            )
            line = notice + line
    sys.stdout.write(line)
'
