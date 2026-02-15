-- Rapture theme for Lite XL
-- Ported from https://marketplace.visualstudio.com/items?itemName=pustur.rapture-vscode

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#111e2a" }  -- editor background
style.background2 = { common.color "#0d1721" } -- sidebar / secondary background
style.background3 = { common.color "#162736" } -- active tab / panels
style.text = { common.color "#c0c9e5" }        -- foreground text
style.caret = { common.color "#ffffff" }
style.accent = { common.color "#7afde1" }       -- accent (aqua/teal)
style.dim = { common.color "#6e93bb" }          -- inactive tabs, dimmed text
style.divider = { common.color "#304b66" }
style.selection = { common.color "#7afde130" }
style.line_number = { common.color "#92beee40" }
style.line_number2 = { common.color "#c0c9e5" } -- active line number
style.line_highlight = { common.color "#7afde10c" }
style.scrollbar = { common.color "#42618540" }
style.scrollbar2 = { common.color "#42618580" } -- hovered

style.syntax["normal"] = { common.color "#c0c9e5" }
style.syntax["symbol"] = { common.color "#8aafd1" }   -- variables (Shade #4)
style.syntax["comment"] = { common.color "#304b66" }   -- comments (Shade #1)
style.syntax["keyword"] = { common.color "#fff09b" }   -- keywords, storage (Yellow)
style.syntax["keyword2"] = { common.color "#64e0ff" }  -- types, classes (Cyan)
style.syntax["number"] = { common.color "#ff4fa1" }    -- constants, numbers (Magenta)
style.syntax["literal"] = { common.color "#ff4fa1" }   -- literals (Magenta)
style.syntax["string"] = { common.color "#7afde1" }    -- strings (Aqua)
style.syntax["operator"] = { common.color "#fff09b" }  -- operators (Yellow)
style.syntax["function"] = { common.color "#6c9bf5" }  -- functions (Blue)

-- Plugins
style.linter_warning = { common.color "#e6a42a" }
style.bracketmatch_color = { common.color "#7afde1" }
style.guide = { common.color "#304b6640" }
style.guide_width = 1
