-- Omarchy Hackerman palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#0b0c16" }
style.background2 = { common.color "#151828" }
style.background3 = { common.color "#1f253a" }
style.text = { common.color "#ddf7ff" }
style.caret = { common.color "#82fb9c" }
style.accent = { common.color "#82fb9c" }
style.dim = { common.color "#6a6e95" }
style.divider = { common.color "#2d3450" }
style.selection = { common.color "#1f253a90" }
style.line_number = { common.color "#6a6e9580" }
style.line_number2 = { common.color "#ddf7ff" }
style.line_highlight = { common.color "#1f253a50" }
style.scrollbar = { common.color "#2d345060" }
style.scrollbar2 = { common.color "#2d3450a0" }

style.syntax["normal"] = { common.color "#ddf7ff" }
style.syntax["symbol"] = { common.color "#ddf7ff" }
style.syntax["comment"] = { common.color "#6a6e95" }
style.syntax["keyword"] = { common.color "#86a7df" }
style.syntax["keyword2"] = { common.color "#7cf8f7" }
style.syntax["number"] = { common.color "#50f7a3" }
style.syntax["literal"] = { common.color "#cddbf4" }
style.syntax["string"] = { common.color "#4fe88f" }
style.syntax["operator"] = { common.color "#a4ffec" }
style.syntax["function"] = { common.color "#829dd4" }

style.linter_warning = { common.color "#50f7d4" }
style.bracketmatch_color = { common.color "#7cf8f7" }
style.guide = { common.color "#1f253a60" }
style.guide_width = 1
