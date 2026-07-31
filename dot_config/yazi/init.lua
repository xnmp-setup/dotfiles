require("no-status"):setup()
require("full-border"):setup {
	-- Available values: ui.Border.PLAIN, ui.Border.ROUNDED
	type = ui.Border.ROUNDED,
}

-- The compact WezTerm shelf has less horizontal space than a full terminal.
-- Hide only its parent Miller column; ordinary Yazi sessions keep the default.
if os.getenv("YAZI_UTILITY_PANE") == "1" then
	require("toggle-pane"):entry("min-parent")
end
