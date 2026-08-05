-- Nord theme for Lite XL
-- Canonical Nord palette: arctic, north-bluish color scheme

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#2e3440" }  -- editor background (Polar Night)
style.background2 = { common.color "#3b4252" } -- sidebar / secondary background
style.background3 = { common.color "#434c5e" } -- active tab / panels
style.text = { common.color "#d8dee9" }        -- foreground text (Snow Storm)
style.caret = { common.color "#88c0d0" }
style.accent = { common.color "#88c0d0" }       -- accent (Frost)
style.dim = { common.color "#616e88" }          -- inactive tabs, dimmed text
style.divider = { common.color "#4c566a" }
style.selection = { common.color "#434c5e90" }
style.line_number = { common.color "#616e8840" }
style.line_number2 = { common.color "#d8dee9" } -- active line number
style.line_highlight = { common.color "#434c5e30" }
style.scrollbar = { common.color "#4c566a60" }
style.scrollbar2 = { common.color "#4c566aa0" } -- hovered

style.syntax["normal"] = { common.color "#d8dee9" }
style.syntax["symbol"] = { common.color "#d8dee9" }   -- variables (default foreground)
style.syntax["comment"] = { common.color "#616e88" }   -- comments
style.syntax["keyword"] = { common.color "#81a1c1" }   -- keywords (Frost blue)
style.syntax["keyword2"] = { common.color "#8fbcbb" }  -- types, classes (Frost teal)
style.syntax["number"] = { common.color "#b48ead" }    -- numbers (Aurora purple)
style.syntax["literal"] = { common.color "#81a1c1" }   -- literals, booleans
style.syntax["string"] = { common.color "#a3be8c" }    -- strings (Aurora green)
style.syntax["operator"] = { common.color "#4c566a" }  -- operators
style.syntax["function"] = { common.color "#88c0d0" }  -- functions (Frost cyan)

-- Plugins
style.linter_warning = { common.color "#ebcb8b" }
style.bracketmatch_color = { common.color "#88c0d0" }
style.guide = { common.color "#3b425240" }
style.guide_width = 1
