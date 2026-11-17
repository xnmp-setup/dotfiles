-- Aurora palette.
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#0d1117" }
style.background2 = { common.color "#161b22" }
style.background3 = { common.color "#1f3a3d" }
style.text = { common.color "#e2e8f0" }
style.caret = { common.color "#5de5d5" }
style.accent = { common.color "#5de5d5" }
style.dim = { common.color "#6b7a90" }
style.divider = { common.color "#26303b" }
style.selection = { common.color "#1f3a3d90" }
style.line_number = { common.color "#6b7a9080" }
style.line_number2 = { common.color "#e2e8f0" }
style.line_highlight = { common.color "#1e252e80" }
style.scrollbar = { common.color "#26303b60" }
style.scrollbar2 = { common.color "#6b7a90a0" }

style.syntax["normal"] = { common.color "#e2e8f0" }
style.syntax["symbol"] = { common.color "#e2e8f0" }
style.syntax["comment"] = { common.color "#6b7a90" }
style.syntax["keyword"] = { common.color "#c084fc" }
style.syntax["keyword2"] = { common.color "#7eeee0" }
style.syntax["number"] = { common.color "#fbbf24" }
style.syntax["literal"] = { common.color "#fbbf24" }
style.syntax["string"] = { common.color "#4ade80" }
style.syntax["operator"] = { common.color "#94a3b8" }
style.syntax["function"] = { common.color "#60a5fa" }

style.linter_warning = { common.color "#fbbf24" }
style.bracketmatch_color = { common.color "#5de5d5" }
style.guide = { common.color "#26303b60" }
style.guide_width = 1
