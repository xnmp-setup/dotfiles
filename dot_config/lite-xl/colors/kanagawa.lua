-- Omarchy Kanagawa palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#1f1f28" }
style.background2 = { common.color "#223249" }
style.background3 = { common.color "#363646" }
style.text = { common.color "#dcd7ba" }
style.caret = { common.color "#dcd7ba" }
style.accent = { common.color "#dcd7ba" }
style.dim = { common.color "#727169" }
style.divider = { common.color "#54546d" }
style.selection = { common.color "#36364690" }
style.line_number = { common.color "#72716980" }
style.line_number2 = { common.color "#dcd7ba" }
style.line_highlight = { common.color "#36364650" }
style.scrollbar = { common.color "#54546d60" }
style.scrollbar2 = { common.color "#54546da0" }

style.syntax["normal"] = { common.color "#dcd7ba" }
style.syntax["symbol"] = { common.color "#dcd7ba" }
style.syntax["comment"] = { common.color "#727169" }
style.syntax["keyword"] = { common.color "#957fb8" }
style.syntax["keyword2"] = { common.color "#6a9589" }
style.syntax["number"] = { common.color "#c17158" }
style.syntax["literal"] = { common.color "#938aa9" }
style.syntax["string"] = { common.color "#76946a" }
style.syntax["operator"] = { common.color "#7fb4ca" }
style.syntax["function"] = { common.color "#7e9cd8" }

style.linter_warning = { common.color "#c0a36e" }
style.bracketmatch_color = { common.color "#7aa89f" }
style.guide = { common.color "#36364660" }
style.guide_width = 1
