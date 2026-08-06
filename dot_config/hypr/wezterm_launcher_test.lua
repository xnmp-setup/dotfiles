-- Behavioral tests for the Hyprland WezTerm launcher. Run: lua wezterm_launcher_test.lua
package.path = (arg[0]:match("^(.*)/") or ".") .. "/?.lua;" .. package.path

local launcher = require("wezterm_launcher")
local failures = 0

local function equal(label, got, want)
    if got == want then return end
    failures = failures + 1
    io.write(("FAIL %s\n  got:  [%s]\n  want: [%s]\n")
        :format(label, tostring(got), tostring(want)))
end

local prefix = "systemd-run --user --scope --quiet --collect"
    .. " --property=CPUWeight=1000 -- wezterm"
equal("GUI launch has high CPU weight", launcher.launch, prefix)
equal("new windows retain the GUI scope", launcher.new_window, prefix .. " start")

io.write(("2 checks, %d failures\n"):format(failures))
os.exit(failures == 0 and 0 or 1)
