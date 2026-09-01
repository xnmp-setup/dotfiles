-- Infernium Dark palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#1c1c1c" }
style.background2 = { common.color "#292522" }
style.background3 = { common.color "#d66938" }
style.text = { common.color "#e0e0e0" }
style.caret = { common.color "#e3884a" }
style.accent = { common.color "#e3884a" }
style.dim = { common.color "#767476" }
style.divider = { common.color "#767476" }
style.selection = { common.color "#d6693890" }
style.line_number = { common.color "#76747680" }
style.line_number2 = { common.color "#e0e0e0" }
style.line_highlight = { common.color "#d6693850" }
style.scrollbar = { common.color "#76747660" }
style.scrollbar2 = { common.color "#767476a0" }

style.syntax["normal"] = { common.color "#e0e0e0" }
style.syntax["symbol"] = { common.color "#e0e0e0" }
style.syntax["comment"] = { common.color "#767476" }
style.syntax["keyword"] = { common.color "#ba6435" }
style.syntax["keyword2"] = { common.color "#e99867" }
style.syntax["number"] = { common.color "#e99867" }
style.syntax["literal"] = { common.color "#e99867" }
style.syntax["string"] = { common.color "#767476" }
style.syntax["operator"] = { common.color "#cad1e0" }
style.syntax["function"] = { common.color "#aeb1c0" }

style.linter_warning = { common.color "#f7d383" }
style.bracketmatch_color = { common.color "#f7d383" }
style.guide = { common.color "#d6693860" }
style.guide_width = 1
