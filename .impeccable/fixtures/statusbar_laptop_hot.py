#!/usr/bin/env python3
"""Stable visual fixture for the conditional laptop and hot-temperature state."""

from __future__ import annotations

import json
import time


SNAPSHOT = {
    "metrics": {
        "cpu": 42,
        "ram": 58,
        "io": 11,
        "gpu": 73,
        "ioTooltip": "nvme0n1 was servicing I/O 11% of the last 30s",
        "laptop": True,
        "battery": 18,
        "batteryTooltip": "Battery discharging",
        "wifi": 67,
        "wifiConnected": True,
        "wifiTooltip": "studio:5g · wlan0",
        "cpuTemp": 82,
        "gpuTemp": 88,
    },
    "palette": {
        "accent": "#fe8019",
        "accent_light": "#fea45c",
        "background": "#282828",
        "surface": "#4b4840",
        "border": "#625d51",
        "text": "#ebdbb2",
        "text_dim": "#ebdbb2",
    },
    "workspaces": [
        {
            "id": 1,
            "name": "1",
            "monitor": "DP-2",
            "clients": [
                {
                    "address": "fixture-terminal",
                    "class": "org.wezfurlong.wezterm",
                    "icon": "file:///usr/share/icons/hicolor/128x128/apps/org.wezfurlong.wezterm.png",
                    "label": "WezTerm",
                    "title": "chezmoi",
                    "terminal": True,
                    "tabs": 3,
                    "claude": 2,
                    "codex": 1,
                    "activities": [
                        {"kind": "claude", "state": "working", "title": "status bar"},
                        {"kind": "codex", "state": "attention", "title": "theme review"},
                        {"kind": "claude", "state": "idle", "title": "dotfiles"},
                    ],
                },
                {
                    "address": "fixture-browser",
                    "class": "google-chrome",
                    "icon": "file:///usr/share/icons/hicolor/64x64/apps/google-chrome.png",
                    "label": "Google Chrome",
                    "title": "Status bar reference",
                    "terminal": False,
                    "tabs": 1,
                    "claude": 0,
                    "codex": 0,
                },
            ],
            "claude": 2,
            "codex": 1,
        },
        {
            "id": 6,
            "name": "6",
            "monitor": "DP-1",
            "clients": [
                {
                    "address": "fixture-editor",
                    "class": "dev.zed.Zed",
                    "icon": "file:///usr/share/icons/hicolor/48x48/apps/dev.zed.Zed.png",
                    "label": "Zed",
                    "title": "WorkspaceToolTip.qml",
                    "terminal": False,
                    "tabs": 1,
                    "claude": 0,
                    "codex": 0,
                }
            ],
            "claude": 0,
            "codex": 0,
        },
    ],
}


def main() -> None:
    encoded = json.dumps(SNAPSHOT, separators=(",", ":"))
    while True:
        print(encoded, flush=True)
        time.sleep(1)


if __name__ == "__main__":
    main()
