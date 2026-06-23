-- Ayu Mirage theme for Lite XL
-- Ported from https://marketplace.visualstudio.com/items?itemName=teabyii.ayu
--
-- Punched-up variant: stock ayu-mirage is deliberately low-contrast, which
-- reads as "dull". Foreground text is brightened, the background darkened a
-- step, and each syntax color nudged up in brightness/saturation so code pops
-- without abandoning the ayu identity.

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#1f2430" }  -- editor background (darker for contrast)
style.background2 = { common.color "#191e2a" } -- sidebar / secondary background
style.background3 = { common.color "#242936" } -- active tab / panels
style.text = { common.color "#e6e3da" }        -- foreground text (brighter)
style.caret = { common.color "#ffcc66" }
style.accent = { common.color "#ffcc66" }       -- accent (golden yellow)
style.dim = { common.color "#707a8c" }          -- inactive tabs, dimmed text
style.divider = { common.color "#12151c" }
style.selection = { common.color "#409fff40" }
style.line_number = { common.color "#546072" }
style.line_number2 = { common.color "#e6e3da" } -- active line number
style.line_highlight = { common.color "#171b24" }
style.scrollbar = { common.color "#54607240" }
style.scrollbar2 = { common.color "#54607280" } -- hovered

style.syntax["normal"] = { common.color "#e6e3da" }
style.syntax["symbol"] = { common.color "#e6e3da" }   -- variables
style.syntax["comment"] = { common.color "#6c7986" }   -- comments (slightly lifted)
style.syntax["keyword"] = { common.color "#ffb86c" }   -- keywords, storage (orange)
style.syntax["keyword2"] = { common.color "#73d7f0" }  -- types, classes (cyan)
style.syntax["number"] = { common.color "#dcc8ff" }    -- constants, numbers (lavender)
style.syntax["literal"] = { common.color "#dcc8ff" }   -- literals (lavender)
style.syntax["string"] = { common.color "#c3f08a" }    -- strings (green)
style.syntax["operator"] = { common.color "#ffae84" }  -- operators (salmon)
style.syntax["function"] = { common.color "#ffe0a3" }  -- functions (gold)

-- Plugins
style.linter_warning = { common.color "#ffcc66" }
style.bracketmatch_color = { common.color "#ffcc66" }
style.guide = { common.color "#5c677340" }
style.guide_width = 1
