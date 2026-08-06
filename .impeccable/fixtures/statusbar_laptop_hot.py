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
                    "icon": "org.wezfurlong.wezterm",
                    "terminal": True,
                    "tabs": 3,
                    "claude": 2,
                    "codex": 1,
                },
                {
                    "address": "fixture-browser",
                    "class": "google-chrome",
                    "icon": "google-chrome",
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
                    "icon": "dev.zed.Zed",
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
