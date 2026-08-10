#!/usr/bin/env -S uv run --script

"""Native-messaging host that streams set-theme's Dark Reader settings."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import select
import struct
import sys
from typing import BinaryIO

MAX_MESSAGE_BYTES = 1024 * 1024
POLL_SECONDS = 0.25


def default_state_file() -> Path:
    state_home = os.environ.get("XDG_STATE_HOME")
    if state_home:
        return Path(state_home) / "darkreader-theme-bridge" / "current.json"
    return Path.home() / ".local" / "state" / "darkreader-theme-bridge" / "current.json"


def read_settings(path: Path) -> tuple[bytes, dict[str, object]] | None:
    try:
        if path.stat().st_size > MAX_MESSAGE_BYTES:
            return None
        raw = path.read_bytes()
    except (FileNotFoundError, OSError):
        return None
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or not isinstance(value.get("theme"), dict):
        return None
    enabled = value.get("enabled")
    if enabled is not None and not isinstance(enabled, bool):
        return None
    return raw, value


def write_message(stream: BinaryIO, value: dict[str, object]) -> None:
    payload = json.dumps(value, separators=(",", ":")).encode()
    stream.write(struct.pack("=I", len(payload)))
    stream.write(payload)
    stream.flush()


def watch(path: Path, stdin: BinaryIO, stdout: BinaryIO) -> int:
    previous = b""
    while True:
        settings = read_settings(path)
        if settings is not None and settings[0] != previous:
            try:
                write_message(stdout, settings[1])
            except (BrokenPipeError, OSError):
                return 0
            previous = settings[0]

        readable, _, _ = select.select([stdin], [], [], POLL_SECONDS)
        if readable and stdin.read(1) == b"":
            return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--once",
        type=Path,
        help="write one native-messaging frame for tests and exit",
    )
    # Chrome appends the calling extension origin (and, on some platforms, a
    # parent-window flag) to the native host command line.
    args, _browser_arguments = parser.parse_known_args()
    return args


def main() -> int:
    args = parse_args()
    if args.once is not None:
        settings = read_settings(args.once)
        if settings is None:
            return 1
        write_message(sys.stdout.buffer, settings[1])
        return 0
    return watch(default_state_file(), sys.stdin.buffer, sys.stdout.buffer)


if __name__ == "__main__":
    raise SystemExit(main())
