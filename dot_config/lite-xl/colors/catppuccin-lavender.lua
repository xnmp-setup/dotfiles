-- Omarchy Catppuccin Lavender palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#f8f8fb" }
style.background2 = { common.color "#f0f4f3" }
style.background3 = { common.color "#e9e7f0" }
style.text = { common.color "#484453" }
style.caret = { common.color "#756681" }
style.accent = { common.color "#756681" }
style.dim = { common.color "#706d79" }
style.divider = { common.color "#d5d1df" }
style.selection = { common.color "#e9e7f090" }
style.line_number = { common.color "#706d7980" }
style.line_number2 = { common.color "#484453" }
style.line_highlight = { common.color "#e9e7f050" }
style.scrollbar = { common.color "#d5d1df60" }
style.scrollbar2 = { common.color "#706d79a0" }

style.syntax["normal"] = { common.color "#484453" }
style.syntax["symbol"] = { common.color "#484453" }
style.syntax["comment"] = { common.color "#706d79" }
style.syntax["keyword"] = { common.color "#756681" }
style.syntax["keyword2"] = { common.color "#327179" }
style.syntax["number"] = { common.color "#965837" }
style.syntax["literal"] = { common.color "#756681" }
style.syntax["string"] = { common.color "#497045" }
style.syntax["operator"] = { common.color "#4962a0" }
style.syntax["function"] = { common.color "#4962a0" }

style.linter_warning = { common.color "#865e22" }
style.bracketmatch_color = { common.color "#327179" }
style.guide = { common.color "#e9e7f060" }
style.guide_width = 1
