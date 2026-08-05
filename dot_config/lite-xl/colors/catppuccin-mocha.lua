-- Catppuccin Mocha theme for Lite XL
-- Ported from the canonical Catppuccin Mocha palette
-- https://github.com/catppuccin/catppuccin
--
-- Deep blue-grey/purple base with a soft mauve accent, following the
-- official Catppuccin style guide role mapping (base/mantle/surface for
-- backgrounds, text/subtext/overlay for foreground hierarchy).

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#1e1e2e" }  -- editor background (base)
style.background2 = { common.color "#181825" } -- sidebar / secondary background (mantle)
style.background3 = { common.color "#313244" } -- active tab / panels (surface0)
style.text = { common.color "#cdd6f4" }        -- foreground text (text)
style.caret = { common.color "#f5e0dc" }        -- cursor (rosewater)
style.accent = { common.color "#cba6f7" }       -- accent (mauve)
style.dim = { common.color "#7f849c" }          -- inactive tabs, dimmed text (overlay1)
style.divider = { common.color "#11111b" }      -- crust
style.selection = { common.color "#45475a40" }  -- surface1 + alpha
style.line_number = { common.color "#6c7086" }  -- overlay0
style.line_number2 = { common.color "#cdd6f4" } -- active line number (text)
style.line_highlight = { common.color "#11111b" } -- crust
style.scrollbar = { common.color "#585b7040" }  -- surface2 + alpha
style.scrollbar2 = { common.color "#585b7080" } -- hovered

style.syntax["normal"] = { common.color "#cdd6f4" }   -- text
style.syntax["symbol"] = { common.color "#cdd6f4" }   -- variables (text)
style.syntax["comment"] = { common.color "#6c7086" }   -- comments (overlay0)
style.syntax["keyword"] = { common.color "#cba6f7" }   -- keywords, storage (mauve)
style.syntax["keyword2"] = { common.color "#f9e2af" }  -- types, classes (yellow)
style.syntax["number"] = { common.color "#fab387" }    -- constants, numbers (peach)
style.syntax["literal"] = { common.color "#fab387" }   -- literals (peach)
style.syntax["string"] = { common.color "#a6e3a1" }    -- strings (green)
style.syntax["operator"] = { common.color "#89dceb" }  -- operators (sky)
style.syntax["function"] = { common.color "#89b4fa" }  -- functions (blue)

-- Plugins
style.linter_warning = { common.color "#cba6f7" }
style.bracketmatch_color = { common.color "#cba6f7" }
style.guide = { common.color "#45475a40" }
style.guide_width = 1
