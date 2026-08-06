# Hyprland status bar evidence

## Functional control inventory

Surface mode: Operate. The bar is a reserved top-edge instrument rail on every
Hyprland monitor.

| State | Contract |
| --- | --- |
| Visible | Show occupied workspaces only. Each workspace is one bounded control containing its current name and one icon per open window. Clicking it focuses that workspace. Long names are bounded and elided. |
| Active workspace | Distinguishable by stronger fill and a bottom accent, not color alone. |
| Rename workspace | Right-click any workspace and choose `Rename workspace`; no hover popup competes with the click target. The menu shows the `Alt+F2` shortcut reminder and dismisses on Escape, outside press, or focus moving to another application. `Alt+F2` edits the focused workspace. Renaming happens inline inside the workspace control, is prefilled and selected, submits with Enter, cancels with Escape or focus loss, limits names to 32 characters, and uses empty input to reset to the numeric ID. |
| Terminal window | Show the terminal icon and number of tabs for both WezTerm and Ghostty OS windows. WezTerm uses its pane-list API; Ghostty uses the GTK AT-SPI tab hierarchy. |
| Agent sessions | Show per-workspace running Claude and Codex session counts across WezTerm and Ghostty. Claude uses the supplied logo asset; Codex uses the actual OpenAI knot mark. Omit zero counts. Enumerate every active WezTerm GUI mux socket, namespace its window IDs by GUI process, and use stable one-to-one assignment so duplicate local IDs or visible titles cannot merge windows. |
| Clock | Center `HH:mm` and an abbreviated weekday/date. Read-only. |
| Telemetry | Show CPU, RAM, disk I/O busy-time, and GPU as percentages in fixed label/value columns. Disk I/O is the busiest physical disk's busy-time over the trailing 30 seconds; the tooltip carries the device and read/write rates. Values below 50% use normal text, 50–75% use Gruvbox yellow, and values above 75% use Gruvbox red. |
| AI quota | Append Claude Code and Codex as individual horizontal metric cells at the far right. Each shows consumed weekly quota and a live reset countdown inline; tooltips retain the exact reset time and secondary window. Claude's five-hour quota remains available in its tooltip. Values below 75% use normal text, 75–89% yellow, and 90%+ red. At the unsupported 1920 px maximum-telemetry extreme, the two cells compact to provider mark plus percentage and retain reset details in tooltips. |
| Laptop status | When a sysfs battery identifies the host as a laptop, append Wi-Fi signal/status and battery percentage. Disconnected/weak Wi-Fi and low battery use warning colors. Desktop hosts omit both cells. |
| Thermal warnings | Omit CPU/GPU temperature cells below 75°C. Show 75–84°C in yellow and 85°C+ in red. |
| Hidden | `Ctrl+Alt+U` toggles every bar off and releases its reserved space; the same key restores it. |
| F9 dropdown | The primary-monitor Ghostty scratchpad reads Hyprland's live top reservation when summoned: 40 px bar + 12 px gap while shown, original 12 px gap while hidden. |
| Empty/error | No empty workspace controls. Missing GPU support displays `GPU --`; malformed or unavailable data never crashes the shell. |
| Multi-monitor | Each monitor shows only workspaces assigned to that output. Required logical widths: 2560, 3440, and 3072 (3840 at 1.25 scale). |

No volume, weather, media, tray, power-menu, search, notifications, or invented
controls are in scope.

## Locked reference

Status: `REFERENCE_LOCKED` (the original blue reference below is superseded by
the user's explicit Gruvbox, segmented-grouping, and OpenAI-mark corrections)

- Current path: `.impeccable/references/status-bar-themed.png`
- Current SHA-256: `74659548f09c662b434a20049b186edb6ae72ea90a7b3c1f9cf589cac085fcde`
- Dimensions returned by the generator: `1932x814`
- Generated: 2026-08-06 (Australia/Sydney)
- Backend: built-in image generation; confirmed by the loaded imagegen skill as `gpt-image-2`
- `referencesUsed`: the preceding generated status-bar reference, the
  user-supplied Claude logo asset, and the locally installed OpenAI mark
- Threshold companion: `.impeccable/references/status-bar-thresholds.png`
  (`8d93602b656aa5fb6c6f70c9a12faa2071d2bde8d4749936d2381140fe605b90`),
  generated with `gpt-image-2` from the current themed reference.
- Conditional laptop/hot-state companion:
  `.impeccable/references/status-bar-laptop-hot.png`
  (`055ef4ba3237fb879508f23bbb76ed84e928fc793916f0db4dfbb5d40f5dcd3e`),
  generated with built-in `gpt-image-2`.

Current exact edit prompt:

> Edit this generated Hyprland top status-bar reference to reflect the user's
> approved thematic and grouping corrections. Preserve the exact functional
> inventory and straight-on desktop-bar composition: occupied workspaces only
> at left; one icon per open window; terminal tab badge; Claude and Codex
> counts; centered HH:mm and weekday/date; right CPU, RAM, IO, GPU percentages;
> no other controls. Restyle the bar in a precise dark Gruvbox palette:
> background #282828, raised surfaces #4b4840, borders #625d51, primary text
> #EBDBB2, active accent #FE8019, accent highlight #FEA45C. Make each workspace
> grouping markedly distinct: 8px gap between complete bounded groups, a
> dedicated 22px workspace-number tile inside each group, full border around
> each workspace, active workspace number tile filled orange plus orange outer
> border and bottom edge, inactive number tile dark and its group clearly
> bounded. Keep the supplied real Claude orange-square radial-burst mark.
> Replace the Codex hexagon/knot surrogate with the supplied actual OpenAI
> interwoven knot logo, cream colored, followed by its plain numeric count. App
> icons must be real icons with no missing-texture checkerboards. Bar height is
> 40 logical px, workspace groups 34px high, compact but optically spaced. No
> blue accent remains. No gradients, glow, glass, shadows, meters, charts,
> trays, volume, battery, network, weather, search, or invented controls.
> Output a clean straight-on UI reference screenshot with no desktop content,
> device frame, callouts, or annotations.

Threshold companion exact edit prompt:

> Edit only the telemetry values and their numeric colors in this approved
> Gruvbox Hyprland status-bar reference. Preserve every workspace, icon, logo,
> count, container, border, time, date, geometry, spacing, background, and label
> exactly. Set CPU to 62% and color only the numeric text `62%` Gruvbox yellow
> #FABD2F. Keep RAM at 42% and IO at 34% in the normal cream #EBDBB2. Set GPU
> to 81% and color only the numeric text `81%` Gruvbox red #FB4934. Labels CPU,
> RAM, IO, GPU remain their existing subdued color. No other color or content
> changes. This demonstrates the exact rule: below 50 normal, 50 through 75
> yellow, above 75 red. Add nothing and remove nothing.

Laptop/hot-state exact generation prompt:

> Create a high-detail UI design reference for a Hyprland top status bar,
> presented as one extremely wide, very short horizontal strip on a plain dark
> background. Gruvbox Dark theme: #282828 background, #ebdbb2 warm cream text,
> #fe8019 orange active accent, #fabd2f warning yellow, #fb4934 critical red,
> muted #625d51 separators. Height should feel exactly 40 logical pixels,
> compact and professional, crisp pixel-aligned edges, no gradients, no
> excessive rounded pills, no neon purple. Left: two strongly distinct occupied
> workspace containers, numbered 1 and 2, with clear full borders, spacing, and
> an orange active edge; each contains recognizable small app icons, a terminal
> tab count, the real Claude starburst mark with count, and the real OpenAI knot
> mark with count. Center: monospaced time 14:27. Right: fixed-width aligned
> metric cells CPU 42%, RAM 58% in yellow, IO 11%, GPU 73% in yellow, then
> conditional hot temperature cells CPU° 82° in yellow and GPU° 88° in red, then
> laptop-only WIFI 67% and BAT 18% in yellow. All numeric values are
> right-aligned in fixed columns so digit changes never shift labels. Workspace
> groupings must be unmistakably separated. Use Inter-like labels and
> JetBrains-Mono-like values. This is a UI reference image only: no monitor
> bezel, no desktop wallpaper, no explanatory annotations.

Original reference retained for provenance:

- Path: `.impeccable/references/status-bar-primary.png`
- SHA-256: `ac86b7e67acf58c5d6e603faf657cd7c4b4916e70ea0f8880cb3a49f5df46736`
- Dimensions returned by the generator: `1932x814`
- Generated: 2026-08-06 (Australia/Sydney)
- Backend: built-in image generation; confirmed by the loaded imagegen skill as `gpt-image-2`
- Supplied Claude asset: `dot_config/quickshell/statusbar/assets/claude.png`
- Claude asset SHA-256: `5b859fe27e305468d7a5d07ffed7bad4bf2b6039e87b601e79f6f786322586bc`
- OpenAI mark source: locally installed OpenClaw documentation asset
  `/home/chong/.nvm/versions/node/v25.6.0/lib/node_modules/openclaw/docs/assets/sponsors/openai.svg`,
  recolored to the bar's warm cream foreground and vendored as
  `dot_config/quickshell/statusbar/assets/openai.svg`.
- `referencesUsed`: the preceding generated status-bar reference and the user-supplied Claude logo asset

Final exact edit prompt:

> Make exactly one glyph replacement in the supplied status-bar image and preserve everything else.
>
> Inside active workspace 1, immediately after the orange square tile containing the white Claude radial-burst logo, there is an incorrect standalone WHITE FIVE-POINT STAR glyph. Replace only that standalone white star glyph with the plain numeral "2" in warm orange or white status-bar text. The orange square Claude logo itself must remain unchanged.
>
> The exact local sequence must become: blue terminal tab badge "6" → orange square actual Claude logo → numeral "2" → green/white Codex knot → numeral "1" → Chrome → Obsidian.
>
> There must be no standalone star glyph anywhere in workspace 1. Do not change the supplied Claude logo tile. Do not change any other icon, count, workspace container, border, active underline, time, date, telemetry, "IO 34%", geometry, color, or background. Add nothing.

The generator did not honor the requested 3440x1440 raster size. The fidelity
contract therefore treats the image as visual authority while fixing production
geometry explicitly below; this variance was recorded before implementation.

## Fidelity contract

- Bar: 40 logical px high; opaque reserved layer-shell surface.
- Outer rail and component colors follow the currently generated
  `~/.config/hypr/theme-colors.lua`; Cosmic Dusk is the complete fallback.
- Workspace controls: 34 px high, 6 px radius, 1 px border, 8 px inter-control gap.
- Active workspace: lifted theme surface, accent border, plus 2 px accent edge.
- Inactive workspace: darkened theme surface and theme border.
- App icons: 18 px. Claude/OpenAI session marks: 16 px. Count and metric text: 13 px.
- Workspace number: 15 px semibold. Clock: 18 px semibold with 13 px date.
- Primary, secondary, border, and accent colors derive from the Hyprland palette.
- Telemetry cells are 96 px wide and use separators rather than cards. Each has
  balanced 12–13 px outer gutters, a right-aligned 28 px label, a 4 px inner gap,
  and a fixed 38 px left-aligned value column using tabular monospaced numerals.
- Claude Code and Codex quota cells follow the same 40 px horizontal rail and
  18 px dividers as telemetry. Each full cell is 188 px wide: provider mark,
  right-aligned provider label, fixed percentage column, and bounded live reset
  countdown.
- Minimum pointer target is the full 34 px-high workspace control, a documented
  desktop-panel exception to the 44 px touch target.

## Candidate comparison

Both candidates use the same live data, interactions, assets, and 40 px reserved
PanelWindow. Set `STATUSBAR_CANDIDATE=instrument` to run Candidate A; Candidate B
(`segmented`) is the production default.

| Category | A: instrument | B: segmented | Evidence |
| --- | ---: | ---: | --- |
| Functional contract | Pass | Pass | 36 Python + 18 QML tests plus rename-helper integration; live IPC and event checks |
| Composition and geometry | 4/5 | 5/5 | `candidate-a-instrument-fixed.png`, final captures |
| Typography | 4/5 | 4/5 | Inter + JetBrains Mono at locked sizes |
| Material, color, and depth | 2/5 | 5/5 | A predates thematic correction; B consumes Hypr palette |
| Imagery and icon craft | 3/5 | 5/5 | B uses resolved app assets and actual Claude/OpenAI marks |
| Responsive and accessible | 4/5 | 5/5 | live 3440 and 3072 logical width captures; full-chip targets |

Selected: Candidate B. It makes workspace ownership structural through a
dedicated number tile, complete boundary, and inter-group gutter, and it follows
the active Hyprland theme.

## Final verification evidence

- 3440x40 logical capture: `.impeccable/captures/final-statusbar-3440x40.png`
  (`4ea7acd0b3b497bec92a2c7f060122c9301226b7ec5c55e2841e9100efe60476`)
- 3072x40 logical / 3840x50 physical capture:
  `.impeccable/captures/final-statusbar-3072x40.png`
  (`8db2d9fc4aa7c48ef11b8c20624bb9e1efaecd20dc0c3e69ee9dccfad11720cd`)
- Fixture-driven laptop/hot-state capture:
  `.impeccable/captures/laptop-hot-statusbar-3440x40.png`
  (`95f8219ed04273e0fb6f16ae9d3d19968e44d5b7a9e48362fe20b81734de88d9`)
- Inline AI-quota detail with laptop/hot telemetry:
  `.impeccable/captures/ai-usage-statusbar-detail.png`
  (`c4ac5dba0e4a1b841c82d4bc72b6cff0fef1f888d1827e7e6f16e942b1ed1d46`,
  1000x40 physical pixels). The fixture shows Claude's weekly quota at 40% used
  and Codex at 65% used, both in normal text with live reset countdowns.
- Immediate workspace-2 event capture:
  `.impeccable/captures/workspace-2-event-highlight.png`
  (`139febe707f2f9bb2110fbb8c025125533d276bc92c9064df2ac66d1ddbdad4d`)
- No-flicker sequence: six immediate alternating captures collapsed to exactly
  two hashes, one per active state; every frame retained both session marks.
- Fresh adversarial acceptance review: PASS; no blocking or major implementation
  defects after the duplicate-title, payload-boundary, and 2560-width fixes.
- Reserved-space check: both outputs changed from top 40 to 0 on IPC hide and
  returned to 40 on show.
- 2560-width contract: Qt 6 exercises the production `StatusLayout.js` geometry
  with the maximum eight telemetry cells at 96 px each and a conservative 180 px
  clock; telemetry clears the centered clock by at least 12 px. The workspace
  viewport is independently clipped at the clock's left edge.
- F9 reservation behavior: the reserved-aware scratchpad assertions pass for
  both a 40 px visible reservation (y=52) and a hidden reservation (y=12).
- Impeccable detector: no findings.
- Behavior tests: 36 Python tests plus 18 QML contract tests and the workspace
  rename integration suite passed. The Python
  suite covers Ghostty bulk AT-SPI parsing, tab and agent extraction, live-title
  compatibility, malformed/huge payloads, transient discovery failure, and
  duplicate-window assignment. The QML
  tests cover all color boundaries and prove the numeric column has identical
  coordinates for 5%, 55%, 100%, temperature, and disconnected Wi-Fi states.
  They also reject empty workspaces and bound malformed/huge metric payloads.
  The rename suite covers explicit workspace selection, Lua-safe Unicode/name
  encoding, reset, rejected dispatches, oversized/malformed input, malformed
  invocations, and single-instance locking. The QML suite verifies context-menu
  dismissal plus inline prefill/selection, persistent focus intent, Enter
  submission, Escape/focus-loss cancellation, immediate editor-width release,
  empty reset, and the 32-character bound. A live temporary rename
  was observed in Hyprland, the status stream, and the rendered chip before
  automatic restoration. The inline configuration, IPC registration, Hyprland
  focus-grab activation, active `TextInput` focus, and Escape dismissal were
  also verified live with a real Wayland key event. Pyrefly: 0 errors. Lua
  template: syntax valid.
- Current source-manifest SHA-256: `f9cb5803e260360bce4db001fc2f653d63f51fba075227e048e55ccf24cc1630`
  on Git base `1467683`.
  Reproduce it with:
  `sha256sum dot_config/quickshell/statusbar/*.qml dot_config/quickshell/statusbar/*.js dot_config/quickshell/statusbar/assets/* dot_claude/executable_statusline.sh dot_local/lib/ai_usage_stream.py dot_local/lib/ghostty_status.py dot_local/lib/hypr_status_stream.py dot_local/bin/executable_ai-usage-stream dot_local/bin/executable_hypr-status-stream dot_local/bin/executable_rename-hypr-workspace dot_config/hypr/scratchpad.lua dot_config/hypr/hyprland.lua.tmpl dot_config/hypr/desktop_test.lua dot_config/wezterm/wezterm_window_identity.lua dot_config/wezterm/wezterm_windowing.lua scripts/test_ai_usage_stream.py scripts/test_hypr_status_stream.py scripts/rename-hypr-workspace.test.sh scripts/tst_statusbar.qml .impeccable/fixtures/statusbar_ai_usage.py .impeccable/fixtures/statusbar_laptop_hot.py | sha256sum`.

## Discrepancy ledger

| Category | Reference | Deployed | Delta / disposition |
| --- | --- | --- | --- |
| Raster framing | Generator returned 1932x814 with unused lower canvas | Native layer-shell captures are 3440x40 and 3840x50 physical | Recorded generator variance; production honors exact 40 logical px contract |
| Dynamic content | Illustrative workspaces 1, 2, 4 and sample percentages | Current occupied workspaces and live telemetry | Expected real-data variance; control types and order match |
| Workspace structure | Segmented, bordered groups with number leaders | Same | Match |
| Brand marks | Supplied Claude and OpenAI marks | Vendored supplied/installed assets | Match |
| Color | Gruvbox values | Read live from `theme-colors.lua` | Match for current Gruvbox theme |
| Conditional status | Laptop and hot-temperature companion state | Fixture capture covers laptop/hot state; desktop capture correctly omits it | Match |
| Metric alignment | Reference uses right-aligned sample values | Production uses fixed left-start value columns inside wider cells | User-directed correction: labels stay close while values never shift as digit count changes |
