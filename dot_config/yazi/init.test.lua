-- Behavioral tests for the utility-pane layout in init.lua. Run: lua init.test.lua

local root = (arg[0]:match('(.*/)') or './')
local real_getenv = os.getenv
local real_require = require
local real_ui = ui

local passed, failed = 0, 0
local function eq(name, got, want)
	if got == want then
		passed = passed + 1
	else
		failed = failed + 1
		io.write(string.format('FAIL %s\n  got:  [%s]\n  want: [%s]\n', name, tostring(got), tostring(want)))
	end
end

local function load_init(utility_pane)
	local toggle_calls = {}
	os.getenv = function(name)
		if name == "YAZI_UTILITY_PANE" and utility_pane then return "1" end
		return real_getenv(name)
	end
	require = function(name)
		if name == "toggle-pane" then
			return { entry = function(_, action) toggle_calls[#toggle_calls + 1] = action end }
		end
		return { setup = function() end }
	end
	ui = { Border = { PLAIN = 'plain', ROUNDED = 'rounded' } }

	local ok, err = pcall(dofile, root .. 'init.lua')
	os.getenv = real_getenv
	require = real_require
	ui = real_ui
	if not ok then error(err) end
	return toggle_calls
end

eq('normal Yazi keeps parent pane', #load_init(false), 0)
local utility_calls = load_init(true)
eq('utility Yazi changes layout once', #utility_calls, 1)
eq('utility Yazi hides parent pane', utility_calls[1], 'min-parent')

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
