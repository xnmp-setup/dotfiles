-- Cosmic Dusk theme for Lite XL
-- Ported from Ghostty's Cosmic Dusk terminal theme

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#0e1330" }  -- editor background
style.background2 = { common.color "#0c1024" } -- sidebar / secondary background
style.background3 = { common.color "#161b40" } -- active tab / panels
style.text = { common.color "#d8dce8" }        -- foreground text
style.caret = { common.color "#d4607a" }
style.accent = { common.color "#7a8ae0" }       -- accent (bright blue)
style.dim = { common.color "#5a6088" }          -- inactive tabs, dimmed text
style.divider = { common.color "#2a3060" }
style.selection = { common.color "#2a306090" }
style.line_number = { common.color "#5a608840" }
style.line_number2 = { common.color "#d8dce8" } -- active line number
style.line_highlight = { common.color "#2a306030" }
style.scrollbar = { common.color "#2a306060" }
style.scrollbar2 = { common.color "#2a3060a0" } -- hovered

style.syntax["normal"] = { common.color "#d8dce8" }
style.syntax["symbol"] = { common.color "#8ac0e0" }   -- variables (bright cyan)
style.syntax["comment"] = { common.color "#3a4070" }   -- comments
style.syntax["keyword"] = { common.color "#6a7acc" }   -- keywords (blue)
style.syntax["keyword2"] = { common.color "#b09ac0" }  -- types, classes (magenta)
style.syntax["number"] = { common.color "#fbbf24" }    -- constants, numbers (yellow)
style.syntax["literal"] = { common.color "#d4607a" }   -- literals (red/rose)
style.syntax["string"] = { common.color "#69db7c" }    -- strings (green)
style.syntax["operator"] = { common.color "#8890a8" }  -- operators
style.syntax["function"] = { common.color "#ffd43b" }  -- functions (bright yellow)

-- Plugins
style.linter_warning = { common.color "#fbbf24" }
style.bracketmatch_color = { common.color "#7a8ae0" }
style.guide = { common.color "#2a306040" }
style.guide_width = 1
