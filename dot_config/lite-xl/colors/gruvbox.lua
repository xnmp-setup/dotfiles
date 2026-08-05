-- Gruvbox Dark Medium theme for Lite XL
-- Canonical Gruvbox palette: classic retro-warm dark theme (medium contrast)

local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#282828" }  -- editor background (bg0)
style.background2 = { common.color "#3C3836" } -- sidebar / secondary background (bg1)
style.background3 = { common.color "#504945" } -- active tab / panels (bg2)
style.text = { common.color "#EBDBB2" }        -- foreground text
style.caret = { common.color "#FE8019" }
style.accent = { common.color "#FE8019" }       -- accent (orange)
style.dim = { common.color "#928374" }          -- inactive tabs, dimmed text
style.divider = { common.color "#665C54" }
style.selection = { common.color "#50494590" }
style.line_number = { common.color "#92837440" }
style.line_number2 = { common.color "#EBDBB2" } -- active line number
style.line_highlight = { common.color "#50494530" }
style.scrollbar = { common.color "#665C5460" }
style.scrollbar2 = { common.color "#665C54A0" } -- hovered

style.syntax["normal"] = { common.color "#EBDBB2" }
style.syntax["symbol"] = { common.color "#EBDBB2" }   -- variables (default foreground)
style.syntax["comment"] = { common.color "#928374" }   -- comments
style.syntax["keyword"] = { common.color "#FB4934" }   -- keywords (red)
style.syntax["keyword2"] = { common.color "#FABD2F" }  -- types, classes (yellow)
style.syntax["number"] = { common.color "#D3869B" }    -- numbers (purple)
style.syntax["literal"] = { common.color "#FB4934" }   -- literals, booleans
style.syntax["string"] = { common.color "#8EC07C" }    -- strings (aqua)
style.syntax["operator"] = { common.color "#FE8019" }  -- operators (orange)
style.syntax["function"] = { common.color "#83A598" }  -- functions (blue)

-- Plugins
style.linter_warning = { common.color "#FABD2F" }
style.bracketmatch_color = { common.color "#458588" }
style.guide = { common.color "#50494540" }
style.guide_width = 1
