-- Omarchy Catppuccin Latte palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#eff1f5" }
style.background2 = { common.color "#e6e9ef" }
style.background3 = { common.color "#ccd0da" }
style.text = { common.color "#4c4f69" }
style.caret = { common.color "#8839ef" }
style.accent = { common.color "#8839ef" }
style.dim = { common.color "#6c6f85" }
style.divider = { common.color "#bcc0cc" }
style.selection = { common.color "#ccd0da90" }
style.line_number = { common.color "#6c6f8580" }
style.line_number2 = { common.color "#4c4f69" }
style.line_highlight = { common.color "#ccd0da50" }
style.scrollbar = { common.color "#bcc0cc60" }
style.scrollbar2 = { common.color "#6c6f85a0" }

style.syntax["normal"] = { common.color "#4c4f69" }
style.syntax["symbol"] = { common.color "#4c4f69" }
style.syntax["comment"] = { common.color "#6c6f85" }
style.syntax["keyword"] = { common.color "#8839ef" }
style.syntax["keyword2"] = { common.color "#179299" }
style.syntax["number"] = { common.color "#fe640b" }
style.syntax["literal"] = { common.color "#8839ef" }
style.syntax["string"] = { common.color "#40a02b" }
style.syntax["operator"] = { common.color "#1e66f5" }
style.syntax["function"] = { common.color "#1e66f5" }

style.linter_warning = { common.color "#df8e1d" }
style.bracketmatch_color = { common.color "#179299" }
style.guide = { common.color "#ccd0da60" }
style.guide_width = 1
