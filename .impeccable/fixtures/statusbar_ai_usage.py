#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Stable Claude Code and Codex quota fixture for visual verification."""

from __future__ import annotations

import json
import time


SNAPSHOT = {
    "claude": {
        "percent": 76,
        "resetsAt": 1_786_019_400,
        "windowMinutes": 300,
        "secondaryPercent": 59,
        "secondaryResetsAt": 1_786_161_402,
        "secondaryWindowMinutes": 10_080,
    },
    "codex": {
        "percent": 65,
        "resetsAt": 1_786_161_402,
        "windowMinutes": 10_080,
        "secondaryPercent": None,
        "secondaryResetsAt": None,
        "secondaryWindowMinutes": None,
    },
}


def main() -> None:
    encoded = json.dumps(SNAPSHOT, separators=(",", ":"))
    while True:
        print(encoded, flush=True)
        time.sleep(30)


if __name__ == "__main__":
    main()
