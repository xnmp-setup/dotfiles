#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Stable Claude Code and Codex quota fixture for visual verification."""

from __future__ import annotations

import json
import time


def snapshot(now: int) -> dict[str, object]:
    weekly_reset = now + 5 * 86_400 + 3 * 3_600 + 42 * 60
    hourly_reset = now + 3 * 3_600 + 42 * 60
    return {
        "claude": {
            "percent": 40,
            "resetsAt": weekly_reset,
            "windowMinutes": 10_080,
            "secondaryPercent": 11,
            "secondaryResetsAt": hourly_reset,
            "secondaryWindowMinutes": 300,
        },
        "codex": {
            "percent": 65,
            "resetsAt": weekly_reset,
            "windowMinutes": 10_080,
            "secondaryPercent": None,
            "secondaryResetsAt": None,
            "secondaryWindowMinutes": None,
        },
    }


def main() -> None:
    encoded = json.dumps(snapshot(int(time.time())), separators=(",", ":"))
    while True:
        print(encoded, flush=True)
        time.sleep(30)


if __name__ == "__main__":
    main()
