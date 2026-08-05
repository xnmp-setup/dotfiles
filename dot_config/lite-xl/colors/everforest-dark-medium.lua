-- Everforest Dark Medium theme for Lite XL
-- Canonical Everforest palette: warm, forest-inspired dark theme (medium contrast)

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#2d353b" }  -- editor background (bg0)
style.background2 = { common.color "#343f44" } -- sidebar / secondary background (bg1)
style.background3 = { common.color "#3d484d" } -- active tab / panels (bg2)
style.text = { common.color "#d3c6aa" }        -- foreground text
style.caret = { common.color "#a7c080" }
style.accent = { common.color "#a7c080" }       -- accent (green)
style.dim = { common.color "#859289" }          -- inactive tabs, dimmed text
style.divider = { common.color "#475258" }
style.selection = { common.color "#3d484d90" }
style.line_number = { common.color "#85928940" }
style.line_number2 = { common.color "#d3c6aa" } -- active line number
style.line_highlight = { common.color "#3d484d30" }
style.scrollbar = { common.color "#47525860" }
style.scrollbar2 = { common.color "#475258a0" } -- hovered

style.syntax["normal"] = { common.color "#d3c6aa" }
style.syntax["symbol"] = { common.color "#d3c6aa" }   -- variables (default foreground)
style.syntax["comment"] = { common.color "#859289" }   -- comments
style.syntax["keyword"] = { common.color "#e67e80" }   -- keywords (red)
style.syntax["keyword2"] = { common.color "#dbbc7f" }  -- types, classes (yellow)
style.syntax["number"] = { common.color "#d699b6" }    -- numbers (purple)
style.syntax["literal"] = { common.color "#e67e80" }   -- literals, booleans
style.syntax["string"] = { common.color "#83c092" }    -- strings (aqua)
style.syntax["operator"] = { common.color "#e69875" }  -- operators (orange)
style.syntax["function"] = { common.color "#a7c080" }  -- functions (green)

-- Plugins
style.linter_warning = { common.color "#dbbc7f" }
style.bracketmatch_color = { common.color "#7fbbb3" }
style.guide = { common.color "#3d484d40" }
style.guide_width = 1
