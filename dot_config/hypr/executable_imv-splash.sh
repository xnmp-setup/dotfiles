#!/bin/bash
# imv-splash.sh — launched at startup
# Watches for imv windows opening, dims background, and retiles on focus loss.

SOCKET="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

# Track watched imv addresses to avoid double-watching
declare -A WATCHED

handle_imv_open() {
    local addr="$1"

    # Dim inactive windows
    hyprctl --batch "\
        keyword decoration:dim_inactive true;\
        keyword decoration:dim_strength 0.4"

    # Background watcher: retile + restore dim on focus loss
    (
        socat -u "UNIX-CONNECT:${SOCKET}" - \
        | while IFS= read -r line; do
            if [[ "$line" == "closewindow>>"* ]]; then
                closed="0x${line#closewindow>>}"
                if [[ "$closed" == "$addr" ]]; then
                    hyprctl reload
                    break
                fi
                continue
            fi
            [[ "$line" != "activewindowv2>>"* ]] && continue
            focused="0x${line#activewindowv2>>}"
            if [[ "$focused" != "$addr" ]]; then
                hyprctl dispatch settiled "address:${addr}"
                hyprctl reload
                break
            fi
        done
    ) &
    disown
}

while true; do
    while IFS= read -r line; do
        # openwindow>>ADDR,WORKSPACE,CLASS,TITLE
        [[ "$line" != "openwindow>>"* ]] && continue
        data="${line#openwindow>>}"
        addr="0x${data%%,*}"
        rest="${data#*,}"
        rest="${rest#*,}"
        class="${rest%%,*}"

        [[ "$class" != "imv" ]] && continue
        [[ -n "${WATCHED[$addr]}" ]] && continue
        WATCHED[$addr]=1

        handle_imv_open "$addr"
    done < <(socat -u "UNIX-CONNECT:${SOCKET}" STDOUT)
    sleep 1
done
