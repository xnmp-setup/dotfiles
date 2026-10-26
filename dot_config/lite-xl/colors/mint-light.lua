-- Mint Light palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#f6fff8" }
style.background2 = { common.color "#eaf7ef" }
style.background3 = { common.color "#cdefdd" }
style.text = { common.color "#3b413c" }
style.caret = { common.color "#1c8564" }
style.accent = { common.color "#1c8564" }
style.dim = { common.color "#62766d" }
style.divider = { common.color "#c3ded0" }
style.selection = { common.color "#cdefdd90" }
style.line_number = { common.color "#62766d" }
style.line_number2 = { common.color "#3b413c" }
style.line_highlight = { common.color "#cdefdd50" }
style.scrollbar = { common.color "#c3ded060" }
style.scrollbar2 = { common.color "#8a9a92a0" }

style.syntax["normal"] = { common.color "#3b413c" }
style.syntax["symbol"] = { common.color "#3b413c" }
style.syntax["comment"] = { common.color "#62766d" }
style.syntax["keyword"] = { common.color "#93599f" }
style.syntax["keyword2"] = { common.color "#8f6d05" }
style.syntax["number"] = { common.color "#b05a22" }
style.syntax["literal"] = { common.color "#b05a22" }
style.syntax["string"] = { common.color "#3a8236" }
style.syntax["operator"] = { common.color "#5f6e67" }
style.syntax["function"] = { common.color "#2d75a0" }

style.linter_warning = { common.color "#b05a22" }
style.bracketmatch_color = { common.color "#1c8564" }
style.guide = { common.color "#cdefdd60" }
style.guide_width = 1
