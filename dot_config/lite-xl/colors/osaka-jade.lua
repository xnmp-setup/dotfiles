-- Osaka Jade palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#111c18" }
style.background2 = { common.color "#23372b" }
style.background3 = { common.color "#32473b" }
style.text = { common.color "#c1c497" }
style.caret = { common.color "#509475" }
style.accent = { common.color "#509475" }
style.dim = { common.color "#81b8a8" }
style.divider = { common.color "#53685b" }
style.selection = { common.color "#32473b90" }
style.line_number = { common.color "#81b8a880" }
style.line_number2 = { common.color "#c1c497" }
style.line_highlight = { common.color "#32473b50" }
style.scrollbar = { common.color "#53685b60" }
style.scrollbar2 = { common.color "#53685ba0" }

style.syntax["normal"] = { common.color "#c1c497" }
style.syntax["symbol"] = { common.color "#c1c497" }
style.syntax["comment"] = { common.color "#81b8a8" }
style.syntax["keyword"] = { common.color "#d2689c" }
style.syntax["keyword2"] = { common.color "#2dd5b7" }
style.syntax["number"] = { common.color "#a2734b" }
style.syntax["literal"] = { common.color "#75bbb3" }
style.syntax["string"] = { common.color "#549e6a" }
style.syntax["operator"] = { common.color "#acd4cf" }
style.syntax["function"] = { common.color "#509475" }

style.linter_warning = { common.color "#459451" }
style.bracketmatch_color = { common.color "#8cd3cb" }
style.guide = { common.color "#32473b60" }
style.guide_width = 1
