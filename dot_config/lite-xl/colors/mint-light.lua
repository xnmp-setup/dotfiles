-- Mint Light palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#f6fff8" }
style.background2 = { common.color "#eaf7ef" }
style.background3 = { common.color "#cdefdd" }
style.text = { common.color "#3b413c" }
style.caret = { common.color "#2e9c79" }
style.accent = { common.color "#2e9c79" }
style.dim = { common.color "#8a9a92" }
style.divider = { common.color "#c3ded0" }
style.selection = { common.color "#cdefdd90" }
style.line_number = { common.color "#8a9a9280" }
style.line_number2 = { common.color "#3b413c" }
style.line_highlight = { common.color "#cdefdd50" }
style.scrollbar = { common.color "#c3ded060" }
style.scrollbar2 = { common.color "#8a9a92a0" }

style.syntax["normal"] = { common.color "#3b413c" }
style.syntax["symbol"] = { common.color "#3b413c" }
style.syntax["comment"] = { common.color "#8a9a92" }
style.syntax["keyword"] = { common.color "#3e9b78" }
style.syntax["keyword2"] = { common.color "#2fa893" }
style.syntax["number"] = { common.color "#c07a3e" }
style.syntax["literal"] = { common.color "#9b6fa8" }
style.syntax["string"] = { common.color "#2fa893" }
style.syntax["operator"] = { common.color "#5f6e67" }
style.syntax["function"] = { common.color "#3e8ca6" }

style.linter_warning = { common.color "#c07a3e" }
style.bracketmatch_color = { common.color "#2fa893" }
style.guide = { common.color "#cdefdd60" }
style.guide_width = 1
