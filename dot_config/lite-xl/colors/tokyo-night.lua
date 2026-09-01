-- Tokyo Night theme for Lite XL
-- Canonical Tokyo Night palette: cool, night-city inspired dark theme

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#1A1B26" }  -- editor background (bg)
style.background2 = { common.color "#24283B" } -- sidebar / secondary background (bg2)
style.background3 = { common.color "#292E42" } -- active tab / panels (selection)
style.text = { common.color "#A9B1D6" }        -- foreground text
style.caret = { common.color "#7AA2F7" }
style.accent = { common.color "#7AA2F7" }       -- accent (blue)
style.dim = { common.color "#565F89" }          -- inactive tabs, dimmed text
style.divider = { common.color "#414868" }
style.selection = { common.color "#292E4290" }
style.line_number = { common.color "#565F8940" }
style.line_number2 = { common.color "#C0CAF5" } -- active line number
style.line_highlight = { common.color "#292E4230" }
style.scrollbar = { common.color "#41486860" }
style.scrollbar2 = { common.color "#414868a0" } -- hovered

style.syntax["normal"] = { common.color "#A9B1D6" }
style.syntax["symbol"] = { common.color "#A9B1D6" }   -- variables (default foreground)
style.syntax["comment"] = { common.color "#565F89" }   -- comments
style.syntax["keyword"] = { common.color "#AD8EE6" }   -- keywords (purple)
style.syntax["keyword2"] = { common.color "#449DAB" }  -- types, classes (cyan-blue)
style.syntax["number"] = { common.color "#EB927B" }    -- numbers (orange)
style.syntax["literal"] = { common.color "#BB9AF7" }   -- literals, booleans
style.syntax["string"] = { common.color "#9ECE6A" }    -- strings (green)
style.syntax["operator"] = { common.color "#0DB9D7" }  -- operators (light blue)
style.syntax["function"] = { common.color "#7AA2F7" }  -- functions (blue)

-- Plugins
style.linter_warning = { common.color "#E0AF68" }
style.bracketmatch_color = { common.color "#449DAB" }
style.guide = { common.color "#292E4240" }
style.guide_width = 1
