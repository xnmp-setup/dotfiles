-- Tokyo Night theme for Lite XL
-- Canonical Tokyo Night palette: cool, night-city inspired dark theme

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#1A1B26" }  -- editor background (bg)
style.background2 = { common.color "#24283B" } -- sidebar / secondary background (bg2)
style.background3 = { common.color "#33467C" } -- active tab / panels (selection)
style.text = { common.color "#C0CAF5" }        -- foreground text
style.caret = { common.color "#7AA2F7" }
style.accent = { common.color "#7AA2F7" }       -- accent (blue)
style.dim = { common.color "#565F89" }          -- inactive tabs, dimmed text
style.divider = { common.color "#414868" }
style.selection = { common.color "#33467C90" }
style.line_number = { common.color "#565F8940" }
style.line_number2 = { common.color "#C0CAF5" } -- active line number
style.line_highlight = { common.color "#33467C30" }
style.scrollbar = { common.color "#41486860" }
style.scrollbar2 = { common.color "#414868a0" } -- hovered

style.syntax["normal"] = { common.color "#C0CAF5" }
style.syntax["symbol"] = { common.color "#C0CAF5" }   -- variables (default foreground)
style.syntax["comment"] = { common.color "#565F89" }   -- comments
style.syntax["keyword"] = { common.color "#BB9AF7" }   -- keywords (purple)
style.syntax["keyword2"] = { common.color "#2AC3DE" }  -- types, classes (cyan-blue)
style.syntax["number"] = { common.color "#FF9E64" }    -- numbers (orange)
style.syntax["literal"] = { common.color "#BB9AF7" }   -- literals, booleans
style.syntax["string"] = { common.color "#9ECE6A" }    -- strings (green)
style.syntax["operator"] = { common.color "#89DDFF" }  -- operators (light blue)
style.syntax["function"] = { common.color "#7AA2F7" }  -- functions (blue)

-- Plugins
style.linter_warning = { common.color "#E0AF68" }
style.bracketmatch_color = { common.color "#7DCFFF" }
style.guide = { common.color "#33467C40" }
style.guide_width = 1
