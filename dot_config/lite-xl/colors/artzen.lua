-- Artzen palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#181c1f" }
style.background2 = { common.color "#2b2728" }
style.background3 = { common.color "#3b2b2c" }
style.text = { common.color "#fdf9f8" }
style.caret = { common.color "#da7a6f" }
style.accent = { common.color "#da7a6f" }
style.dim = { common.color "#b18d85" }
style.divider = { common.color "#b18d85" }
style.selection = { common.color "#3b2b2c90" }
style.line_number = { common.color "#b18d8580" }
style.line_number2 = { common.color "#fdf9f8" }
style.line_highlight = { common.color "#3b2b2c50" }
style.scrollbar = { common.color "#b18d8560" }
style.scrollbar2 = { common.color "#b18d85a0" }

style.syntax["normal"] = { common.color "#fdf9f8" }
style.syntax["symbol"] = { common.color "#fdf9f8" }
style.syntax["comment"] = { common.color "#b18d85" }
style.syntax["keyword"] = { common.color "#9a8c8a" }
style.syntax["keyword2"] = { common.color "#da7a6f" }
style.syntax["number"] = { common.color "#ca887f" }
style.syntax["literal"] = { common.color "#c4bcbb" }
style.syntax["string"] = { common.color "#9f6769" }
style.syntax["operator"] = { common.color "#d7b2ae" }
style.syntax["function"] = { common.color "#b97670" }

style.linter_warning = { common.color "#bb6d6c" }
style.bracketmatch_color = { common.color "#ecbeb9" }
style.guide = { common.color "#3b2b2c60" }
style.guide_width = 1
