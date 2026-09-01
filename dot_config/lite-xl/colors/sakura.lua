-- Sakura palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#0d0509" }
style.background2 = { common.color "#230e18" }
style.background3 = { common.color "#230e18" }
style.text = { common.color "#f0eaed" }
style.caret = { common.color "#d9a56c" }
style.accent = { common.color "#d9a56c" }
style.dim = { common.color "#c6afba" }
style.divider = { common.color "#7a5c66" }
style.selection = { common.color "#230e1890" }
style.line_number = { common.color "#c6afba80" }
style.line_number2 = { common.color "#f0eaed" }
style.line_highlight = { common.color "#230e1850" }
style.scrollbar = { common.color "#7a5c6660" }
style.scrollbar2 = { common.color "#7a5c66a0" }

style.syntax["normal"] = { common.color "#f0eaed" }
style.syntax["symbol"] = { common.color "#f0eaed" }
style.syntax["comment"] = { common.color "#c6afba" }
style.syntax["keyword"] = { common.color "#d1b399" }
style.syntax["keyword2"] = { common.color "#e8c099" }
style.syntax["number"] = { common.color "#ff8e7c" }
style.syntax["literal"] = { common.color "#e3c5ab" }
style.syntax["string"] = { common.color "#f29b9a" }
style.syntax["operator"] = { common.color "#ebb97e" }
style.syntax["function"] = { common.color "#d9a56c" }

style.linter_warning = { common.color "#d4a882" }
style.bracketmatch_color = { common.color "#fbd2ab" }
style.guide = { common.color "#230e1860" }
style.guide_width = 1
