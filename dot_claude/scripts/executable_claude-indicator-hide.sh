#!/bin/sh
# Signal the indicator daemon to hide (called by Claude hooks)
pid_file="/tmp/claude-indicator.pid"
[ -f "$pid_file" ] && kill -USR2 "$(cat "$pid_file")" 2>/dev/null
exit 0
