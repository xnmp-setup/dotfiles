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

local prefix = (os.getenv("HOME") or "") .. "/.local/bin/wezterm-hypr-launch"
equal("GUI launch uses the diagnostic wrapper", launcher.launch, prefix)
equal("new windows use the same wrapper", launcher.new_window, prefix .. " start")
equal("workspace windows select a single saved WezTerm window",
    launcher.restore_window, prefix .. " --restore-window")

io.write(("3 checks, %d failures\n"):format(failures))
os.exit(failures == 0 and 0 or 1)
