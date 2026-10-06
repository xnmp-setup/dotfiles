-- Everforest Light Medium palette (sainnhe/everforest).
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#fdf6e3" }
style.background2 = { common.color "#f4f0d9" }
style.background3 = { common.color "#efebd4" }
style.text = { common.color "#5c6a72" }
style.caret = { common.color "#5c6a72" }
style.accent = { common.color "#8da101" }
style.dim = { common.color "#939f91" }
style.divider = { common.color "#e0dcc7" }
style.selection = { common.color "#eaedc8" }
style.line_number = { common.color "#a6b0a0" }
style.line_number2 = { common.color "#829181" }
style.line_highlight = { common.color "#f4f0d9" }
style.scrollbar = { common.color "#bdc3af80" }
style.scrollbar2 = { common.color "#939f91a0" }

style.syntax["normal"] = { common.color "#5c6a72" }
style.syntax["symbol"] = { common.color "#5c6a72" }
style.syntax["comment"] = { common.color "#939f91" }
style.syntax["keyword"] = { common.color "#f85552" }
style.syntax["keyword2"] = { common.color "#dfa000" }
style.syntax["number"] = { common.color "#df69ba" }
style.syntax["literal"] = { common.color "#df69ba" }
style.syntax["string"] = { common.color "#8da101" }
style.syntax["operator"] = { common.color "#f57d26" }
style.syntax["function"] = { common.color "#8da101" }

style.linter_warning = { common.color "#dfa000" }
style.bracketmatch_color = { common.color "#35a77c" }
style.guide = { common.color "#e0dcc7" }
style.guide_width = 1
