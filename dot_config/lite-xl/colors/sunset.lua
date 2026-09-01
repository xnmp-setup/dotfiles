-- Sunset palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#070605" }
style.background2 = { common.color "#211a14" }
style.background3 = { common.color "#302519" }
style.text = { common.color "#ffffff" }
style.caret = { common.color "#dda660" }
style.accent = { common.color "#dda660" }
style.dim = { common.color "#969596" }
style.divider = { common.color "#969596" }
style.selection = { common.color "#30251990" }
style.line_number = { common.color "#96959680" }
style.line_number2 = { common.color "#ffffff" }
style.line_highlight = { common.color "#30251950" }
style.scrollbar = { common.color "#96959660" }
style.scrollbar2 = { common.color "#969596a0" }

style.syntax["normal"] = { common.color "#ffffff" }
style.syntax["symbol"] = { common.color "#ffffff" }
style.syntax["comment"] = { common.color "#969596" }
style.syntax["keyword"] = { common.color "#ebd2a4" }
style.syntax["keyword2"] = { common.color "#fce7b0" }
style.syntax["number"] = { common.color "#efd5b4" }
style.syntax["literal"] = { common.color "#fdfbf8" }
style.syntax["string"] = { common.color "#f7ce6e" }
style.syntax["operator"] = { common.color "#f1e8e0" }
style.syntax["function"] = { common.color "#d0b59b" }

style.linter_warning = { common.color "#b2a295" }
style.bracketmatch_color = { common.color "#ffffff" }
style.guide = { common.color "#30251960" }
style.guide_width = 1
