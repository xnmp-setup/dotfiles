-- Night Owl theme for Lite XL
-- Canonical Night Owl palette: Sarah Drasner's deep-blue night coding theme

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#011627" }  -- editor background (bg1)
style.background2 = { common.color "#0B2942" } -- sidebar / secondary background (bg2)
style.background3 = { common.color "#1D3B53" } -- active tab / panels (bg3/selection)
style.text = { common.color "#D6DEEB" }        -- foreground text
style.caret = { common.color "#82AAFF" }
style.accent = { common.color "#82AAFF" }       -- accent (blue)
style.dim = { common.color "#637777" }          -- inactive tabs, dimmed text
style.divider = { common.color "#1E3A5C" }
style.selection = { common.color "#1D3B5390" }
style.line_number = { common.color "#63777740" }
style.line_number2 = { common.color "#D6DEEB" } -- active line number
style.line_highlight = { common.color "#1D3B5330" }
style.scrollbar = { common.color "#1E3A5C60" }
style.scrollbar2 = { common.color "#1E3A5Ca0" } -- hovered

style.syntax["normal"] = { common.color "#D6DEEB" }
style.syntax["symbol"] = { common.color "#D6DEEB" }   -- variables (default foreground)
style.syntax["comment"] = { common.color "#637777" }   -- comments
style.syntax["keyword"] = { common.color "#C792EA" }   -- keywords (purple)
style.syntax["keyword2"] = { common.color "#FFCB8B" }  -- types, classes (light orange)
style.syntax["number"] = { common.color "#F78C6C" }    -- numbers (orange)
style.syntax["literal"] = { common.color "#F78C6C" }   -- literals, booleans
style.syntax["string"] = { common.color "#ECC48D" }    -- strings (warm tan)
style.syntax["operator"] = { common.color "#7FDBCA" }  -- operators (cyan)
style.syntax["function"] = { common.color "#82AAFF" }  -- functions (blue)

-- Plugins
style.linter_warning = { common.color "#FFEB95" }
style.bracketmatch_color = { common.color "#21C7A8" }
style.guide = { common.color "#1D3B5340" }
style.guide_width = 1
