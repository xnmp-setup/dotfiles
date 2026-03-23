#!/bin/sh
# Signal the indicator daemon to show (called by Claude hooks)
pid_file="/tmp/claude-indicator.pid"
[ -f "$pid_file" ] && kill -USR1 "$(cat "$pid_file")" 2>/dev/null
exit 0
