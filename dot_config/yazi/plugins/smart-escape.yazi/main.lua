--- @since 25.5.31
--- @sync entry

local function entry()
	local tab = cx.active
	if tab.mode.is_visual then
		ya.emit("escape", {})
	elseif #tab.selected > 0 then
		ya.emit("escape", {})
	elseif tab.finder then
		ya.emit("escape", {})
	else
		ya.emit("quit", {})
	end
end

return { entry = entry }
