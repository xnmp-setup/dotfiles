# Status bar AI usage and workspace activity handover

Last updated: 2026-08-06, Australia/Sydney

## Executive status

The requested status-bar work is implemented, verified, merged into `main`,
applied with chezmoi, and running on both Wayland sessions.

- Implementation commit: `bdf090c feat(statusbar): add thematic workspace activity tooltips`
- This document is recorded in a separate follow-up documentation commit on
  `main`.
- Preceding related commits:
  - `9a7bfb4 fix(statusbar): count agents across WezTerm GUIs`
  - `1467683 fix(statusbar): show weekly Claude usage`
  - `975c148 feat(statusbar): add AI usage metrics`
- Feature branch: `codex/statusbar-ai-usage`, also at `bdf090c`
- Worktree retained at `/tmp/chezmoi-statusbar-ai-usage`
- Main checkout: `/home/chong/.local/share/chezmoi`
- No PR was created.

The final user-visible behavior is:

- Claude and Codex quota cells show percentage consumed, not percentage
  remaining.
- Claude uses its weekly window rather than its five-hour window in the inline
  cell.
- Both providers show a live reset countdown such as `5d 3h 41m`.
- Claude/Codex session counts cover every live WezTerm GUI instance and Ghostty
  window instead of only the first WezTerm socket.
- Status-bar tooltips use the active dark theme rather than the platform's
  yellow post-it appearance.
- Workspace hover opens immediately and shows the applications, window titles,
  terminal tabs/processes, and Claude/Codex state: `Running`, `Idle`, or
  `Awaiting input`.
- Ordinary metric and usage hints use a 90 ms guard to avoid flashing while the
  pointer crosses adjacent cells.

## Repository and runtime state

`main` was fast-forwarded from `9a7bfb4` to `bdf090c`, then received only this
handover document. The feature worktree is clean at `bdf090c` and was
deliberately not removed.

The main checkout contains unrelated untracked files that were present before
the merge and were not staged, edited, or removed:

```text
dot_config/systemd/user/io-pressure-monitor.service
dot_local/bin/executable_io-pressure
dot_local/lib/io_pressure_monitor.py
findtest.txt
log.txt
run1.raw
run2.raw
scripts/test_io_pressure_monitor.py
wraptest.txt
```

The merged files were applied to the live home configuration with `chezmoi
apply`. At the last runtime check, the deployed status bar was running as:

```text
wayland-1: instance g71n2qbcjt, PID 1074652
wayland-2: instance a32nlqbcjt, PID 1075798
```

Instance IDs and PIDs are ephemeral. Both processes reported `Configuration
Loaded`. Each logged only the existing, benign host-portal registration warning:

```text
Failed to register with host portal: Connection already associated with an application ID
```

## UI implementation

### Themed standard hints

`dot_config/quickshell/statusbar/ThemedToolTip.qml` is the shared tooltip for
CPU, RAM, I/O, GPU, temperatures, Wi-Fi, battery, and AI quota hints. It uses:

- the current `themeColors.surface` background;
- `themeColors.border` and `themeColors.text`;
- Inter at 12 px;
- a 6 px radius and 10 px padding;
- `Popup.Window`, allowing the popup to extend below the 40 px layer surface;
- a 90 ms delay and no timeout.

`MetricCell.qml` and `UsageCell.qml` use a `HoverHandler`. A live visual pass
found that their previous buttonless `MouseArea` did not reliably activate the
custom popup, even though the old attached platform tooltip worked. The
dedicated hover handler is the verified correction.

### Workspace inspection popup

`dot_config/quickshell/statusbar/WorkspaceToolTip.qml` is a structured popup,
not a large text blob. It has no intentional delay. It renders:

- workspace name;
- total windows and total Claude/Codex agents;
- application icon and friendly application name;
- terminal tab count or a normal window label;
- normal application window title;
- one line per terminal activity;
- Claude/OpenAI mark, activity title, and state for agent activities.

State presentation is:

| Internal state | User label | Color |
| --- | --- | --- |
| `working` | Running | theme accent-light |
| `attention` | Awaiting input | Gruvbox yellow `#fabd2f` |
| `idle` or `done` | Idle | theme dim text |

The popup bounds rendering to eight clients and eight activity rows per client,
with explicit `more` rows. The ingestion layer separately caps each client's
activity payload at 32 entries. `StatusSanitizer.js` validates types, accepted
agent kinds/states, string lengths, workspace counts, client counts, and
activity counts before QML consumes the data.

`WorkspaceChip.qml` suppresses the popup while inline rename is active or the
workspace context menu is open.

## Status data model

Each workspace client now includes the following fields in addition to the
existing address, class, icon, tab count, and aggregate agent counts:

```json
{
  "label": "WezTerm",
  "title": "chezmoi",
  "activities": [
    {"kind": "claude", "state": "working", "title": "status bar"},
    {"kind": "codex", "state": "attention", "title": "theme review"},
    {"kind": "process", "state": "", "title": "zsh"}
  ]
}
```

Supported activity kinds are `claude`, `codex`, and `process`. Supported agent
states are `working`, `attention`, and `idle`. The hook's `done` state is
normalized to `idle` before reaching QML.

Friendly labels currently cover WezTerm, Ghostty, Chrome/Chromium, Obsidian,
Zed, Visual Studio Code, Firefox, and Tauri Explorer. Unknown application
classes fall back to a title-cased final class component.

## Ghostty state detection

`dot_local/lib/ghostty_status.py` already received Ghostty tab titles through
the GTK AT-SPI hierarchy. It now converts each tab into an immutable
`AgentActivity` and strips both terminal identity tags and other Unicode format
metadata before showing titles.

Agent state comes from the existing title glyph contract:

| Agent | Idle | Awaiting input | Running animation |
| --- | --- | --- | --- |
| Claude | `✴` | `✹` | `✢`, `✶`, `✻`, `✽` |
| Codex | `🔻` | `⬣` | `⬩`, `⬦`, `◈`, `⬥` |

The invisible metadata remains authoritative for agent kind. The visible glyph
provides lifecycle state. Non-agent Ghostty tabs are emitted as ordinary
process activity rows.

## WezTerm state detection

The process collector still discovers agent processes by TTY and enumerates all
live WezTerm GUI mux sockets. Window IDs remain namespaced by GUI PID, and
one-to-one window matching prevents duplicate local IDs or titles from merging
OS windows.

WezTerm's CLI pane listing does not expose the relevant user variables, so the
existing agent status hook now mirrors lifecycle state into a small runtime
file:

```text
$XDG_RUNTIME_DIR/wezterm-agent-state.gui-sock-<gui-pid>.<pane-id>.<kind>
```

`dot_local/bin/executable_wezterm-agent-status` writes `working`, `attention`,
or `done` atomically with mode `0600`. The socket basename makes pane IDs unique
across simultaneous WezTerm GUIs. `dot_config/wezterm/wezterm_agent.lua` also
writes `done` when bare Escape clears a potentially stuck working state.

The collector reads a state record only when a currently live agent process
matches that pane's TTY. Therefore stale runtime files do not create phantom
agents. Missing, malformed, or `done` records display as `Idle`.

Relevant upstream contracts used in the design:

- [WezTerm CLI targeting with `WEZTERM_UNIX_SOCKET`](https://wezterm.org/cli/cli/index.html)
- [WezTerm `wezterm.procinfo.pid()`](https://wezterm.org/config/lua/wezterm.procinfo/pid.html)

## AI quota behavior

The related quota implementation predates the tooltip commit but is part of the
same delivered status-bar feature:

- `dot_local/lib/ai_usage_stream.py` emits normalized Claude and Codex usage.
- Inline percentages represent quota consumed.
- Claude inline selection prefers the seven-day/weekly window; its five-hour
  window remains available in the detailed hint.
- Reset timestamps are rendered as live countdowns by `UsageCell.qml`.
- Thresholds are based on consumed quota: normal below 75%, yellow at 75–89%,
  red at 90% and above.
- Claude and Codex remain separate cells laid out like the CPU/GPU notifier
  rail, with compact rendering only at the constrained 1920 px extreme.

## Verification completed

All of the following passed against the final source:

```text
Python behavioral tests:       37 passed
Qt 6 QML results:              22 passed (20 contract tests + init/cleanup)
WezTerm Lua tests:             39 passed
Workspace rename integration: passed
Pyrefly:                       0 errors
Shell syntax:                  passed
git diff --check:              passed
Impeccable UI detector:        []
```

Commands used or equivalent reproducible commands:

```sh
UV_CACHE_DIR=/tmp/chezmoi-uv-cache \
  uv run python -m unittest scripts.test_hypr_status_stream scripts.test_ai_usage_stream

QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input scripts/tst_statusbar.qml -o -,txt

lua dot_config/wezterm/wezterm_agent.test.lua
sh scripts/rename-hypr-workspace.test.sh
sh -n dot_local/bin/executable_wezterm-agent-status
git diff --check
```

Pyrefly was run from the already-installed uv archive because the managed
sandbox could read but not initialize the normal uv cache:

```sh
/home/chong/.cache/uv/archive-v0/G-5f_5bcmItiRNKy7Fpin/bin/pyrefly check \
  dot_local/lib/ghostty_status.py \
  dot_local/lib/hypr_status_stream.py \
  .impeccable/fixtures/statusbar_laptop_hot.py
```

The source-manifest hash and the full fidelity ledger are in
`.impeccable/status-bar-evidence.md`.

## Visual evidence

- `.impeccable/captures/workspace-tooltip-detail.png`
  - SHA-256: `38947edc2236039cb4af8fe15c9d594de393825aaa9a57b66efd3f33b84918d5`
  - Shows two windows and three agent tabs spanning Running, Awaiting input,
    and Idle.
- `.impeccable/captures/metric-tooltip-themed.png`
  - SHA-256: `10f5f9eafa0e23db1b6214d0b388820fdd6862537d09a663ec190f74b150ad61`
  - Shows the standard CPU hint using the same dark surface and border as the
    status bar.

The final visual pass used a fixture-driven temporary bar on `wayland-1`. The
temporary instance was stopped, the pointer was restored to its original
position, and both deployed live instances were then started from
`/home/chong/.config/quickshell/statusbar/shell.qml`.

## Deployment and restart procedure

The deployed targets are:

```text
~/.config/quickshell/statusbar/{MetricCell,UsageCell,WorkspaceChip,ThemedToolTip,WorkspaceToolTip}.qml
~/.config/quickshell/statusbar/StatusSanitizer.js
~/.config/wezterm/wezterm_agent.lua
~/.local/bin/wezterm-agent-status
~/.local/lib/ghostty_status.py
~/.local/lib/hypr_status_stream.py
```

To reapply after future changes, target these files explicitly; applying a
chezmoi directory argument did not recurse in this environment:

```sh
chezmoi apply \
  /home/chong/.config/quickshell/statusbar/MetricCell.qml \
  /home/chong/.config/quickshell/statusbar/UsageCell.qml \
  /home/chong/.config/quickshell/statusbar/WorkspaceChip.qml \
  /home/chong/.config/quickshell/statusbar/StatusSanitizer.js \
  /home/chong/.config/quickshell/statusbar/ThemedToolTip.qml \
  /home/chong/.config/quickshell/statusbar/WorkspaceToolTip.qml \
  /home/chong/.config/wezterm/wezterm_agent.lua \
  /home/chong/.local/bin/wezterm-agent-status \
  /home/chong/.local/lib/ghostty_status.py \
  /home/chong/.local/lib/hypr_status_stream.py
```

Each Wayland display has its own Quickshell process. Restart both deliberately:

```sh
WAYLAND_DISPLAY=wayland-1 qs kill -i <wayland-1-instance>
WAYLAND_DISPLAY=wayland-1 qs -d -p /home/chong/.config/quickshell/statusbar

WAYLAND_DISPLAY=wayland-2 qs kill -i <wayland-2-instance>
WAYLAND_DISPLAY=wayland-2 qs -d -p /home/chong/.config/quickshell/statusbar
```

Use `qs list --all` to resolve current instance IDs before killing anything.

## Caveats and future checks

1. WezTerm lifecycle state is hook-driven. A session that predates deployment
   and has not emitted another lifecycle event may initially show `Idle`; its
   next working/attention/done hook refreshes the runtime record.
2. If multiple nested agent processes share one pane TTY, each counted process
   receives the pane's current state and title. Aggregate counts remain correct,
   but the tooltip cannot distinguish nested agents beyond what the terminal
   exposes.
3. Workspace UI displays at most eight windows and eight activities per window.
   This is intentional bounding, with overflow disclosed by `more` rows.
4. The normal process title for a terminal pane is derived from the WezTerm pane
   title. It is descriptive, not a full process tree.
5. Quickshell instance IDs in this document are observational only; do not use
   them later without first checking `qs list --all`.
6. The feature worktree still exists. Remove it only after confirming no one
   needs it for follow-up work:

   ```sh
   git worktree remove /tmp/chezmoi-statusbar-ai-usage
   ```

No known functional defect remains from the requested scope at handover time.
