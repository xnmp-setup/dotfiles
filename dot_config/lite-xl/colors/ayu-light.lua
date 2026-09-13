-- Omarchy Ayu Light palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#f8f9fa" }
style.background2 = { common.color "#f3f4f5" }
style.background3 = { common.color "#d3e1f5" }
style.text = { common.color "#5c6166" }
style.caret = { common.color "#3199e1" }
style.accent = { common.color "#3199e1" }
style.dim = { common.color "#8a9199" }
style.divider = { common.color "#c7c7c7" }
style.selection = { common.color "#d3e1f590" }
style.line_number = { common.color "#8a919980" }
style.line_number2 = { common.color "#5c6166" }
style.line_highlight = { common.color "#d3e1f550" }
style.scrollbar = { common.color "#c7c7c760" }
style.scrollbar2 = { common.color "#8a9199a0" }

style.syntax["normal"] = { common.color "#5c6166" }
style.syntax["symbol"] = { common.color "#5c6166" }
style.syntax["comment"] = { common.color "#8a9199" }
style.syntax["keyword"] = { common.color "#9e75c7" }
style.syntax["keyword2"] = { common.color "#46ba94" }
style.syntax["number"] = { common.color "#f07171" }
style.syntax["literal"] = { common.color "#9e75c7" }
style.syntax["string"] = { common.color "#6cbf43" }
style.syntax["operator"] = { common.color "#399ee6" }
style.syntax["function"] = { common.color "#3199e1" }

style.linter_warning = { common.color "#eca944" }
style.bracketmatch_color = { common.color "#46ba94" }
style.guide = { common.color "#d3e1f560" }
style.guide_width = 1
