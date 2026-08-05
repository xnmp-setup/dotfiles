# Desktop Theme Switcher

Makes Chrome follow `set-theme <slug>` instead of needing a manual visit to
`chrome://extensions/` after every theme change.

## Moving parts

| Piece | Lives at | Role |
| --- | --- | --- |
| Theme extensions | `~/.local/share/chrome-themes/<slug>/` | One unpacked MV3 theme per slug. Its manifest `name` is the Title Case theme name (`golden-hour-light` → `Golden Hour Light`). |
| This extension | `~/.local/share/chrome-themes/theme-switcher/` | Holds a native-messaging port; on each `{title}` it finds the installed extension with `type === "theme"` and that name and calls `chrome.management.setEnabled(id, true)`. Chrome disables the previous theme itself. |
| Native host | `~/.local/bin/chrome-theme-switcher-host` | python3, stdlib only. Spawned by the browser. Polls the state file (1 s, no inotify — portable) and pushes `{title}` on change, plus a periodic ping so the MV3 service worker is not torn down for being idle. |
| Host manifest | `<browser profile>/NativeMessagingHosts/com.chong.theme_switcher.json` | Written by `set-theme.sh` for every Chromium-family profile dir that exists (Chrome, Chromium, Vivaldi, Edge, Brave; Linux and macOS paths). Idempotent. |
| State file | `~/.local/state/chrome-theme-switcher/current` | Two lines: Title Case name, then slug. Written by `set-theme.sh`. |

The extension's ID is pinned to `fnicgaoklanobahpnhaadhhedpaibnoo` by the `key`
in `manifest.json`, so `allowed_origins` in the host manifest is valid on every
machine. Regenerating that key changes the ID and requires updating
`scripts/set-theme.sh`.

## One-time setup per machine

1. `chezmoi apply` (ships the extension and the host script).
2. Run `set-theme <any-slug>` once — this writes the host manifest into each
   browser profile that exists and creates the state file.
3. In the browser: `chrome://extensions/` → enable **Developer mode** →
   **Load unpacked**:
   - `~/.local/share/chrome-themes/theme-switcher`
   - each theme dir you want available, e.g.
     `~/.local/share/chrome-themes/golden-hour-light`
     (Ctrl+H in the GTK file picker shows hidden folders.)
4. Restart the browser once so it picks up the new host manifest.

Themes must be *installed* before they can be switched to —
`chrome.management.setEnabled` can only enable something already there. A
`set-theme` for a theme that was never loaded is a no-op (logged as a warning
in the switcher's service-worker console).

## Not covered

Dark Reader stays manual: its settings live in the browser's extension
LevelDB, which cannot be edited safely from a script. `set-theme` generates
`~/.local/share/darkreader-themes/<slug>.json` for you to import through the
Dark Reader UI.
