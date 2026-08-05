-- Horizon Dark theme for Lite XL
-- Canonical Horizon palette: cinematic sunset-noir dark theme

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#1c1e26" }  -- editor background (bg)
style.background2 = { common.color "#232530" } -- sidebar / secondary background (bg2)
style.background3 = { common.color "#2e303e" } -- active tab / panels (bg3)
style.text = { common.color "#d5d8da" }        -- foreground text
style.caret = { common.color "#e95678" }
style.accent = { common.color "#e95678" }       -- accent (rose)
style.dim = { common.color "#6c6f93" }          -- inactive tabs, dimmed text
style.divider = { common.color "#2e303e" }
style.selection = { common.color "#2e303e90" }
style.line_number = { common.color "#6c6f9340" }
style.line_number2 = { common.color "#d5d8da" } -- active line number
style.line_highlight = { common.color "#2e303e30" }
style.scrollbar = { common.color "#2e303e60" }
style.scrollbar2 = { common.color "#2e303ea0" } -- hovered

style.syntax["normal"] = { common.color "#d5d8da" }
style.syntax["symbol"] = { common.color "#d5d8da" }   -- variables (default foreground)
style.syntax["comment"] = { common.color "#6c6f93" }   -- comments
style.syntax["keyword"] = { common.color "#ee64ac" }   -- keywords (magenta)
style.syntax["keyword2"] = { common.color "#26bbd9" }  -- types, classes (blue)
style.syntax["number"] = { common.color "#fab795" }    -- numbers (orange)
style.syntax["literal"] = { common.color "#fab795" }   -- literals, booleans
style.syntax["string"] = { common.color "#29d398" }    -- strings (green)
style.syntax["operator"] = { common.color "#59e1e3" }  -- operators (cyan)
style.syntax["function"] = { common.color "#26bbd9" }  -- functions (blue)

-- Plugins
style.linter_warning = { common.color "#fab795" }
style.bracketmatch_color = { common.color "#26bbd9" }
style.guide = { common.color "#2e303e40" }
style.guide_width = 1
