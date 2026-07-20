---
name: theme-desktop
description: Generate matching color themes for all desktop apps from a wallpaper image.
disable-model-invocation: true
argument-hint: <wallpaper-path> [theme-name]
---

# Desktop Theme Generator

Generate a cohesive color theme from a wallpaper image and apply it to all configured desktop apps.

## Arguments

- `$0` — Path to wallpaper image (required)
- `$1` — Theme name (optional, defaults to a name derived from the wallpaper)

If no arguments provided, ask the user for a wallpaper path.

## Steps

### 1. Analyze the wallpaper

Read the wallpaper image at the given path using the Read tool. Study its dominant colors, mood, and overall brightness.

### 2. Ask dark or light

Based on the wallpaper analysis, recommend whether a **dark** or **light** theme would best complement it (e.g. a dark moody wallpaper suits a dark theme, a bright airy wallpaper suits light). Present the recommendation and ask the user to confirm or choose the other option. Wait for their answer before proceeding.

### 3. Build the palette

Using the chosen mode (dark or light) and the wallpaper's colors, extract:

- **Dark mode**: dark shades from the image for backgrounds, light/bright tones for foreground text.
- **Light mode**: light/pale tones from the image for backgrounds, dark shades for foreground text.

For both modes, derive:
- 2-3 background shades
- A primary foreground color with good contrast against the background
- An accent color (most prominent vibrant color)
- 6-8 syntax/ANSI colors from the image's palette (red, green, yellow, blue, magenta, cyan, plus bright variants)
- Muted variants for UI elements (dimmed text, borders, selections)

The palette must be cohesive — all colors should feel like they belong to the same image. Ensure sufficient contrast for readability.

### 4. Generate theme files

Create theme files for all eleven apps using the palette. Read the existing themes/configs as format reference before writing.

#### Ghostty (`~/.config/ghostty/themes/{theme-name}`)

No file extension. Key-value format with 16 palette entries, background, foreground, cursor-color, cursor-text, selection-background, selection-foreground.

Reference: read any file in `~/.config/ghostty/themes/` for the exact format.

#### WezTerm (`~/.config/wezterm/wezterm.lua`, inline)

WezTerm has no per-theme files — schemes live inline in the `config.color_schemes` table in `wezterm.lua`. Add a new entry keyed by the Title Case theme name:

```lua
['Theme Name'] = {
  background = '#...', foreground = '#...',
  cursor_bg = '#...', cursor_fg = '#...', cursor_border = '#...',
  selection_bg = '#...', selection_fg = '#...',
  ansi = { black, red, green, yellow, blue, magenta, cyan, white },      -- palette 0-7
  brights = { brblack, brred, brgreen, bryellow, brblue, brmagenta, brcyan, brwhite }, -- palette 8-15
},
```

Map directly from the Ghostty palette (same 16 colors + background/foreground/cursor/selection). Insert the entry into the existing `config.color_schemes` table; do not duplicate the table.

Reference: read the `config.color_schemes` block in `~/.config/wezterm/wezterm.lua` for the exact format.

#### Tauri Explorer (`~/.config/tauri-explorer/themes/{theme-name}.css`)

CSS custom properties in a `[data-theme="{theme-name}"]` selector. Includes accent, text, background, surface, control, address bar, focus, status, shadow, mica, and opacity variables.

Reference: read any file in `~/.config/tauri-explorer/themes/` for the exact format.

#### Lite XL (`~/.config/lite-xl/colors/{theme-name}.lua`)

Lua module using `style.*` and `style.syntax[*]` with `common.color` for hex values.

Reference: read any file in `~/.config/lite-xl/colors/` for the exact format.

#### Micro (`~/.config/micro/colorschemes/{theme-name}.micro`)

`color-link` directives mapping element names to `"foreground,background"` hex pairs.

Reference: read any file in `~/.config/micro/colorschemes/` for the exact format.

#### VS Code (`~/.vscode/extensions/local.{theme-name}-0.0.1/`)

A local extension with `package.json` and `themes/{theme-name}-color-theme.json`. The theme JSON contains:
- `colors` object for UI elements (editor, sidebar, tabs, terminal, status bar, etc.)
- `semanticHighlighting: true` and `semanticTokenColors` for semantic token overrides (these take priority over textmate scopes — required to prevent language extensions from overriding theme colors)
- `tokenColors` array for textmate syntax scopes

Assign syntax roles following this mapping: blue-ish for functions, green-ish for keywords, cyan/teal-ish for strings, warm for numbers, orange-ish for classes, amber-ish for constants, violet/pink-ish for decorators/JSON keys. All colors must be derived from the wallpaper image — do NOT copy hex values from Solarized or any other existing theme. The wallpaper is the sole source of truth for the palette.

The `package.json` must include `"publisher": "local"` and a `"__metadata"` block. The directory must follow the `publisher.name-version` naming convention (e.g. `local.golden-hour-light-0.0.1`). Set `"uiTheme"` to `"vs"` for light themes or `"vs-dark"` for dark themes.

Reference: read any theme in `~/.vscode/extensions/` for the exact format.

#### Zed (`~/.config/zed/themes/{theme-name}.json`)

JSON theme file following the Zed v0.2.0 theme schema. The file contains:
- Top-level `name` and `author` fields
- A `themes` array with one entry containing `name`, `appearance` (`"dark"` or `"light"`), and `style`

The `style` object includes:
- UI colors: `background`, `border`, `border.variant`, `border.focused`, `elevated_surface.background`, `surface.background`, `element.*`, `ghost_element.*`, `drop_target.background`
- Text: `text`, `text.muted`, `text.placeholder`, `text.disabled`, `text.accent`
- Icons: `icon`, `icon.muted`, `icon.disabled`, `icon.placeholder`, `icon.accent`
- Chrome: `status_bar.background`, `title_bar.background`, `title_bar.inactive_background`, `toolbar.background`, `tab_bar.background`, `tab.inactive_background`, `tab.active_background`, `panel.background`, `panel.focused_border`, `pane.focused_border`
- Editor: `editor.foreground`, `editor.background`, `editor.gutter.background`, `editor.subheader.background`, `editor.active_line.background`, `editor.highlighted_line.background`, `editor.line_number`, `editor.active_line_number`, `editor.invisible`, `editor.wrap_guide`, `editor.document_highlight.*`
- Search: `search.match_background`, `search.active_match_background`
- Scrollbar: `scrollbar.thumb.*`, `scrollbar.track.*`
- Terminal: full 16-color ANSI palette with normal, bright, and dim variants, plus `terminal.background`, `terminal.foreground`, `terminal.bright_foreground`, `terminal.dim_foreground`
- Version control: `version_control.added`, `.modified`, `.deleted`, `.conflict_marker.*`
- Status colors: `error`, `warning`, `info`, `success`, `hint`, `conflict`, `created`, `deleted`, `hidden`, `ignored`, `modified`, `renamed`, `predictive`, `unreachable` — each with `.background` and `.border` variants
- `players` array (8 entries) for multiplayer cursors — each with `cursor`, `background`, and `selection` (use accent + syntax colors, selection at ~24% opacity)
- `syntax` object mapping token types to `{ color, font_style, font_weight }`: `attribute`, `boolean`, `comment`, `comment.doc`, `constant`, `constructor`, `embedded`, `emphasis`, `emphasis.strong`, `enum`, `function`, `hint`, `keyword`, `label`, `link_text`, `link_uri`, `namespace`, `number`, `operator`, `predictive`, `preproc`, `primary`, `property`, `punctuation`, `punctuation.bracket`, `punctuation.delimiter`, `punctuation.list_marker`, `punctuation.markup`, `punctuation.special`, `selector`, `string`, `string.escape`, `string.regex`, `string.special`, `tag`, `text.literal`, `title`, `type`, `variable`, `variable.special`, `variant`

All hex colors use 8-digit format with alpha (`#rrggbbaa`). Use `ff` alpha for opaque colors.

Reference: read any file in `~/.config/zed/themes/` for the exact format.

#### Chrome (`~/.local/share/chrome-themes/{theme-name}/`)

A Manifest V3 Chrome theme extension. Single `manifest.json` file containing a `"theme"` object with `colors`, `tints`, and `properties`. Colors use RGB arrays `[R, G, B]` or RGBA `[R, G, B, alpha]` where alpha is 0-1.

Map the palette to Chrome color keys:
- `frame` — tab strip / title bar background (use secondary background shade)
- `frame_inactive` — inactive window frame (slightly more muted)
- `frame_incognito` / `frame_incognito_inactive` — desaturated variants
- `toolbar` — address bar / bookmarks bar background (use primary background, alpha 0.95)
- `background_tab` — inactive tab background (use secondary background, alpha 0.95)
- `tab_text` — active tab text (use primary foreground)
- `tab_background_text` — inactive tab text (use muted foreground)
- `bookmark_text` — bookmarks bar text (use primary foreground)
- `ntp_background` — new tab page background (use lightest background shade)
- `ntp_text` — new tab page text (use primary foreground)
- `ntp_link` — new tab page links (use accent color)
- `ntp_header` — new tab page divider (use border color)
- `omnibox_background` — address bar field background (use lightest background shade)
- `omnibox_text` — address bar text (use primary foreground)
- `toolbar_button_icon` — nav button icons (use muted foreground)
- `button_background` — button accent (use accent color)

Reference: read any theme in `~/.local/share/chrome-themes/` for the exact format.

#### Dark Reader (`~/.local/share/chrome-themes/{theme-name}/darkreader-{theme-name}.json`)

A Dark Reader settings file that recolors the *content* of every web page (the Chrome theme above only styles the browser chrome). Write it alongside the Chrome theme extension. The file contains a single `"theme"` object — Dark Reader's import merges shallowly at the top level, so importing `{ "theme": {...} }` replaces the theme but **preserves** the user's per-site enable/disable lists, automation, and presets.

Because the merge is shallow and missing keys are not back-filled, the `theme` object must be **complete**. Use Dark Reader's defaults for everything except the colors and mode:

```json
{
  "theme": {
    "mode": 1,
    "brightness": 100,
    "contrast": 100,
    "grayscale": 0,
    "sepia": 0,
    "useFont": false,
    "fontFamily": "Open Sans",
    "textStroke": 0,
    "engine": "dynamicTheme",
    "stylesheet": "",
    "darkSchemeBackgroundColor": "#...",
    "darkSchemeTextColor": "#...",
    "lightSchemeBackgroundColor": "#...",
    "lightSchemeTextColor": "#...",
    "scrollbarColor": "",
    "selectionColor": "auto",
    "styleSystemControls": false,
    "lightColorScheme": "Default",
    "darkColorScheme": "Default",
    "immediateModify": false
  }
}
```

Map the palette:
- `mode` — `1` for a dark theme, `0` for a light theme
- `darkSchemeBackgroundColor` — primary background shade (dark)
- `darkSchemeTextColor` — primary foreground (light)
- `lightSchemeBackgroundColor` — primary background shade (light)
- `lightSchemeTextColor` — primary foreground (dark)
- `selectionColor` — accent color (or leave `"auto"`)
- `scrollbarColor` — a muted background/border shade (or leave `""` for auto)

Set **both** scheme color pairs so the theme looks right whichever mode the user runs Dark Reader in; `mode` selects the active pair. Use 6-digit `#rrggbb` hex.

**Note:** importing resets Dark Reader's brightness/contrast/font to the defaults above. If the user has customized those, tell them to instead export their current settings (⚙ → Manage Settings → Export), then only swap the `*SchemeColor`, `selectionColor`, `scrollbarColor`, and `mode` keys before re-importing.

#### Obsidian (`~/Vaults/Technical Vault/.obsidian/themes/{Theme Name}/`)

Directory containing `manifest.json` (name, version, minAppVersion, author) and `theme.css`. The CSS uses `.theme-light` or `.theme-dark` selector with Obsidian CSS custom properties:
- `--color-base-00` through `--color-base-100` (grayscale ramp)
- `--background-primary`, `--background-secondary`, etc.
- `--text-normal`, `--text-muted`, `--text-faint`, `--text-accent`
- `--interactive-normal`, `--interactive-hover`, `--interactive-accent`
- `--h1-color` through `--h6-color`
- `--code-background`, `--code-normal`
- Semantic colors: `--color-red`, `--color-green`, `--color-blue`, etc.

Only create in the Technical Vault, not the Personal Vault.

Reference: read any theme in `~/Vaults/Technical Vault/.obsidian/themes/` for the exact format.

#### Vicinae (`~/.local/share/vicinae/themes/{theme-name}.toml`)

TOML theme file for the Vicinae launcher. Contains:
- `[meta]` — `version = 1`, `name`, `description`, `variant` (`"dark"` or `"light"`)
- `[colors.core]` — `background`, `foreground`, `secondary_background`, `border`, `accent`
- `[colors.accents]` — `blue`, `green`, `magenta`, `orange`, `purple`, `red`, `yellow`, `cyan`
- `[colors.list.item.selection]` — `background` (use `{ name = "#hex", opacity = 0.45 }` format), `secondary_background`
- `[colors.list.item.hover]` — `background` (use `{ name = "#hex", opacity = 0.3 }` format)

Map the palette: `background` and `secondary_background` from background shades, `foreground` from primary text, `accent` from accent color, `border` from selection/border color, accents from the 16-color ANSI palette.

Reference: read any file in `~/.local/share/vicinae/themes/` or `/usr/share/vicinae/themes/` for the exact format. Validate with `vicinae theme check <file>`.

#### Powerlevel10k (`~/.config/p10k-themes/{theme-name}.zsh`)

Separate theme override file sourced after `~/.p10k.zsh`. Colors use 256-color indices (0–255). Map the theme palette to the closest 256-color index for each setting. The file overrides only color values — the base `~/.p10k.zsh` is not modified.

After creating the file, symlink it as the current theme:
```bash
ln -sf ~/.config/p10k-themes/{theme-name}.zsh ~/.config/p10k-themes/current.zsh
```

The file includes a `my_git_formatter()` function that overrides the hardcoded git status colors in p10k with theme-matched 256-color indices.

Reference: read any file in `~/.config/p10k-themes/` for the exact format and which settings to override.

### 5. Apply themes

Update each app's config to use the new theme:

- **Ghostty**: In `~/.config/ghostty/config`, update the `theme = ...` line
- **WezTerm**: In `~/.config/wezterm/wezterm.lua`, update the `config.color_scheme = '...'` line to the Title Case theme name (must match a key added to `config.color_schemes`)
- **Lite XL**: In `~/.config/lite-xl/init.lua`, update the `core.reload_module("colors....")` line
- **Micro**: In `~/.config/micro/settings.json`, update the `"colorscheme"` value
- **VS Code**: In `~/.config/Code/User/settings.json`, update `"workbench.colorTheme"` value
- **Zed**: In `~/.config/zed/settings.json`, update the `"theme"` object — set `"mode"` to `"light"` or `"dark"`, and update the corresponding key (`"light"` or `"dark"`) to the theme's display name (the `name` field inside the `themes` array entry, e.g. `"My Theme Dark"`)
- **Obsidian**: In `~/Vaults/Technical Vault/.obsidian/appearance.json`, update `"cssTheme"` and set `"theme": "moonstone"` for light or `"theme": "obsidian"` for dark. Update `"accentColor"` to the theme's accent hex.
- **Tauri Explorer**: In `~/.config/tauri-explorer/settings.json`, update the `"theme"` value to the new theme name (matching the CSS filename without extension).
- **Vicinae**: Run `vicinae theme set {theme-name}` to switch the active theme (updates `~/.config/vicinae/settings.json` automatically). For dark themes, this sets `theme.dark.name`; for light themes, `theme.light.name`.
- **Powerlevel10k**: Create `~/.config/p10k-themes/{theme-name}.zsh` and symlink it as `current.zsh`.
- **Chrome**: Do NOT edit settings — tell the user to load the theme manually via `chrome://extensions/` → Developer mode → Load unpacked → press `Ctrl+H` in the file picker to show hidden directories → navigate to `~/.local/share/chrome-themes/{theme-name}/`.
- **Dark Reader**: Cannot be applied from disk (settings live in the extension's storage). Tell the user to import manually: click the Dark Reader toolbar icon → ⚙ (Settings) → Manage Settings → Import Settings → select `~/.local/share/chrome-themes/{theme-name}/darkreader-{theme-name}.json`.

### 6. Align Tauri Explorer colors

Tauri Explorer applies internal compositing that shifts theme colors (typically darker and more yellow than the hex values specified). After the user has applied themes and can see both apps, run a calibration step:

1. Ask the user to take a screenshot showing both Ghostty and Tauri Explorer side by side.
2. Run the alignment script on the screenshot:
   ```bash
   uv run ~/.claude/skills/theme-desktop/scripts/align_colors.py \
       <screenshot_path> <current_tauri_bg_hex> --auto
   ```
   Or with manual regions if auto-detection picks the wrong areas:
   ```bash
   uv run ~/.claude/skills/theme-desktop/scripts/align_colors.py \
       <screenshot_path> <current_tauri_bg_hex> \
       --ref-region x1,y1,x2,y2 --target-region x1,y1,x2,y2
   ```
3. The script outputs compensated hex values for all background CSS properties. Update the Tauri Explorer theme file with these values.
4. Update `~/.config/tauri-explorer/settings.json` to re-trigger the theme if needed, then ask the user to confirm the match.

**Important**: Tauri Explorer background values must always be opaque hex (e.g. `#f0e5d6`), not rgba — rgba allows desktop bleed-through which dilutes the intended color.

### 7. Report

List the files created and configs updated. Note that:
- Ghostty applies on config reload (Ctrl+Shift+,)
- WezTerm applies on config reload (Ctrl+Shift+,)
- Lite XL and Micro apply on next launch
- VS Code: restart VS Code fully (not just reload window) for new extensions to load
- Zed: theme applies immediately; if not, restart Zed
- Obsidian: restart Obsidian or toggle theme in Appearance settings
- Tauri Explorer applies on next launch or window focus
- Powerlevel10k: run `source ~/.p10k.zsh` or open a new terminal
- Vicinae: theme applies on next launch or when the window is re-opened
- Chrome: load unpacked extension from `~/chrome-themes-{theme-name}/` via `chrome://extensions/`
- Dark Reader: import `darkreader-{theme-name}.json` via the extension's Settings → Manage Settings → Import Settings; applies immediately to all pages
- Claude Code: run `/theme` to sync with the new terminal theme (light or dark)
