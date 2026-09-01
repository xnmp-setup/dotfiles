-- Omarchy Ethereal palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#060b1e" }
style.background2 = { common.color "#131a3a" }
style.background3 = { common.color "#252e56" }
style.text = { common.color "#ffcead" }
style.caret = { common.color "#7d82d9" }
style.accent = { common.color "#7d82d9" }
style.dim = { common.color "#6d7db6" }
style.divider = { common.color "#6d7db6" }
style.selection = { common.color "#252e5690" }
style.line_number = { common.color "#6d7db680" }
style.line_number2 = { common.color "#ffcead" }
style.line_highlight = { common.color "#252e5650" }
style.scrollbar = { common.color "#6d7db660" }
style.scrollbar2 = { common.color "#6d7db6a0" }

style.syntax["normal"] = { common.color "#ffcead" }
style.syntax["symbol"] = { common.color "#ffcead" }
style.syntax["comment"] = { common.color "#6d7db6" }
style.syntax["keyword"] = { common.color "#c89dc1" }
style.syntax["keyword2"] = { common.color "#a3bfd1" }
style.syntax["number"] = { common.color "#eb8b54" }
style.syntax["literal"] = { common.color "#ead7e7" }
style.syntax["string"] = { common.color "#92a593" }
style.syntax["operator"] = { common.color "#dfeaf0" }
style.syntax["function"] = { common.color "#7d82d9" }

style.linter_warning = { common.color "#e9bb4f" }
style.bracketmatch_color = { common.color "#a3bfd1" }
style.guide = { common.color "#252e5660" }
style.guide_width = 1
