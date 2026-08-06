#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Stream Claude Code and Codex quota windows for the Quickshell status bar."""

from __future__ import annotations

import argparse
import json
import math
import os
import select
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

MAX_INPUT_BYTES = 1_048_576
MAX_CACHE_BYTES = 65_536
MAX_RESET_TIMESTAMP = 4_102_444_800  # 2100-01-01 UTC
DEFAULT_STREAM_INTERVAL = 30.0
DEFAULT_CODEX_REFRESH_INTERVAL = 300.0

JsonObject = dict[str, Any]
CodexFetcher = Callable[[], "ProviderUsage | None"]


@dataclass(frozen=True)
class UsageWindow:
    percent: int
    resets_at: int
    window_minutes: int | None = None


@dataclass(frozen=True)
class ProviderUsage:
    primary: UsageWindow | None = None
    secondary: UsageWindow | None = None


def bounded_percent(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    numeric = float(value)
    if not math.isfinite(numeric):
        return None
    return int(max(0.0, min(100.0, numeric)) + 0.5)


def bounded_integer(
    value: object, minimum: int, maximum: int
) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    numeric = float(value)
    if not math.isfinite(numeric):
        return None
    integer = int(numeric)
    return integer if minimum <= integer <= maximum else None


def usage_window(
    raw: object,
    *,
    percent_key: str,
    reset_key: str,
    default_window_minutes: int | None = None,
    percent_is_remaining: bool = False,
) -> UsageWindow | None:
    if not isinstance(raw, Mapping):
        return None
    percent = bounded_percent(raw.get(percent_key))
    resets_at = bounded_integer(raw.get(reset_key), 1, MAX_RESET_TIMESTAMP)
    window_minutes = bounded_integer(raw.get("windowDurationMins"), 1, 525_600)
    if percent is None or resets_at is None:
        return None
    if percent_is_remaining:
        percent = 100 - percent
    return UsageWindow(
        percent=percent,
        resets_at=resets_at,
        window_minutes=window_minutes or default_window_minutes,
    )


def parse_claude_status(data: object) -> ProviderUsage | None:
    if not isinstance(data, Mapping):
        return None
    limits = data.get("rate_limits")
    if not isinstance(limits, Mapping):
        return None
    primary = usage_window(
        limits.get("five_hour"),
        percent_key="used_percentage",
        reset_key="resets_at",
        default_window_minutes=300,
        percent_is_remaining=True,
    )
    secondary = usage_window(
        limits.get("seven_day"),
        percent_key="used_percentage",
        reset_key="resets_at",
        default_window_minutes=10_080,
        percent_is_remaining=True,
    )
    return ProviderUsage(primary=primary, secondary=secondary) if primary or secondary else None


def parse_codex_result(result: object) -> ProviderUsage | None:
    if not isinstance(result, Mapping):
        return None
    limits: object = result.get("rateLimits")
    by_id = result.get("rateLimitsByLimitId")
    if isinstance(by_id, Mapping) and isinstance(by_id.get("codex"), Mapping):
        limits = by_id["codex"]
    if not isinstance(limits, Mapping):
        return None
    primary = usage_window(
        limits.get("primary"),
        percent_key="usedPercent",
        reset_key="resetsAt",
    )
    secondary = usage_window(
        limits.get("secondary"),
        percent_key="usedPercent",
        reset_key="resetsAt",
    )
    return ProviderUsage(primary=primary, secondary=secondary) if primary or secondary else None


def parse_codex_messages(lines: Sequence[str]) -> ProviderUsage | None:
    for line in lines:
        if len(line) > MAX_INPUT_BYTES:
            continue
        try:
            message = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(message, Mapping) and message.get("id") == 1:
            return parse_codex_result(message.get("result"))
    return None


def provider_payload(usage: ProviderUsage | None) -> JsonObject:
    def field(window: UsageWindow | None, name: str) -> object:
        return getattr(window, name) if window is not None else None

    return {
        "percent": field(usage.primary if usage else None, "percent"),
        "resetsAt": field(usage.primary if usage else None, "resets_at"),
        "windowMinutes": field(usage.primary if usage else None, "window_minutes"),
        "secondaryPercent": field(usage.secondary if usage else None, "percent"),
        "secondaryResetsAt": field(usage.secondary if usage else None, "resets_at"),
        "secondaryWindowMinutes": field(
            usage.secondary if usage else None, "window_minutes"
        ),
    }


def provider_from_payload(raw: object) -> ProviderUsage | None:
    if not isinstance(raw, Mapping):
        return None
    primary_raw = {
        "percent": raw.get("percent"),
        "resetsAt": raw.get("resetsAt"),
        "windowDurationMins": raw.get("windowMinutes"),
    }
    primary = usage_window(
        primary_raw,
        percent_key="percent",
        reset_key="resetsAt",
    )
    secondary_raw = {
        "percent": raw.get("secondaryPercent"),
        "resetsAt": raw.get("secondaryResetsAt"),
        "windowDurationMins": raw.get("secondaryWindowMinutes"),
    }
    secondary = usage_window(
        secondary_raw,
        percent_key="percent",
        reset_key="resetsAt",
    )
    return ProviderUsage(primary=primary, secondary=secondary) if primary or secondary else None


def default_claude_cache_path() -> Path:
    runtime_root = os.environ.get("XDG_RUNTIME_DIR", "").strip()
    if runtime_root:
        return Path(runtime_root) / "statusbar-ai-usage" / "claude.json"
    cache_root = os.environ.get("XDG_CACHE_HOME", "").strip()
    root = Path(cache_root) if cache_root else Path.home() / ".cache"
    return root / "statusbar-ai-usage" / "claude.json"


def write_claude_cache(
    usage: ProviderUsage,
    path: Path,
    *,
    observed_at: float | None = None,
) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "observedAt": int(observed_at if observed_at is not None else time.time()),
        "usage": provider_payload(usage),
    }
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=".claude-usage-",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            json.dump(payload, temporary, separators=(",", ":"))
            temporary.write("\n")
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        if temporary_name:
            try:
                Path(temporary_name).unlink(missing_ok=True)
            except OSError:
                pass


def capture_claude_status(
    text: str,
    path: Path,
    *,
    observed_at: float | None = None,
) -> bool:
    if len(text.encode("utf-8")) > MAX_INPUT_BYTES:
        return False
    try:
        data = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return False
    usage = parse_claude_status(data)
    if usage is None:
        return False
    try:
        write_claude_cache(usage, path, observed_at=observed_at)
    except OSError:
        return False
    return True


def expire_provider(usage: ProviderUsage | None, now: float) -> ProviderUsage | None:
    if usage is None:
        return None
    primary = usage.primary if usage.primary and usage.primary.resets_at > now else None
    secondary = usage.secondary if usage.secondary and usage.secondary.resets_at > now else None
    return ProviderUsage(primary=primary, secondary=secondary) if primary or secondary else None


def read_claude_cache(path: Path, *, now: float | None = None) -> ProviderUsage | None:
    try:
        if path.stat().st_size > MAX_CACHE_BYTES:
            return None
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return None
    if not isinstance(raw, Mapping) or raw.get("version") != 1:
        return None
    usage = provider_from_payload(raw.get("usage"))
    return expire_provider(usage, now if now is not None else time.time())


def codex_requests() -> list[JsonObject]:
    return [
        {
            "method": "initialize",
            "id": 0,
            "params": {
                "clientInfo": {
                    "name": "quickshell_statusbar",
                    "title": "Quickshell Status Bar",
                    "version": "1.0.0",
                }
            },
        },
        {"method": "initialized", "params": {}},
        {"method": "account/rateLimits/read", "id": 1},
    ]


def run_codex_app_server(
    requests: Sequence[Mapping[str, object]],
    *,
    timeout: float = 12.0,
    command: Sequence[str] | None = None,
) -> list[str]:
    executable = os.environ.get("CODEX_BIN", "codex")
    argv = list(command or (executable, "app-server"))
    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except OSError:
        return []
    lines: list[str] = []
    try:
        if process.stdin is None or process.stdout is None:
            return []
        for request in requests:
            process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select(
                [process.stdout], [], [], max(0.0, deadline - time.monotonic())
            )
            if not ready:
                break
            line = process.stdout.readline()
            if not line:
                break
            lines.append(line.rstrip("\n"))
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(message, Mapping) and message.get("id") == 1:
                break
    except (OSError, ValueError):
        return lines
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1.0)
    return lines


def fetch_codex_usage() -> ProviderUsage | None:
    return parse_codex_messages(run_codex_app_server(codex_requests()))


class UsageCollector:
    def __init__(
        self,
        *,
        claude_cache_path: Path | None = None,
        codex_fetcher: CodexFetcher = fetch_codex_usage,
        wall_clock: Callable[[], float] = time.time,
        monotonic_clock: Callable[[], float] = time.monotonic,
        codex_refresh_interval: float = DEFAULT_CODEX_REFRESH_INTERVAL,
    ) -> None:
        self.claude_cache_path = claude_cache_path or default_claude_cache_path()
        self.codex_fetcher = codex_fetcher
        self.wall_clock = wall_clock
        self.monotonic_clock = monotonic_clock
        self.codex_refresh_interval = codex_refresh_interval
        self.cached_codex: ProviderUsage | None = None
        self.last_codex_attempt = float("-inf")

    def snapshot(self) -> JsonObject:
        monotonic_now = self.monotonic_clock()
        if monotonic_now - self.last_codex_attempt >= self.codex_refresh_interval:
            fresh = self.codex_fetcher()
            if fresh is not None:
                self.cached_codex = fresh
            self.last_codex_attempt = monotonic_now
        now = self.wall_clock()
        return {
            "claude": provider_payload(read_claude_cache(self.claude_cache_path, now=now)),
            "codex": provider_payload(expire_provider(self.cached_codex, now)),
        }


def emit_stream(collector: UsageCollector, interval: float) -> None:
    while True:
        started = time.monotonic()
        print(json.dumps(collector.snapshot(), separators=(",", ":")), flush=True)
        time.sleep(max(0.0, interval - (time.monotonic() - started)))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-claude", action="store_true")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--interval", type=float, default=DEFAULT_STREAM_INTERVAL)
    parser.add_argument(
        "--codex-refresh-interval",
        type=float,
        default=DEFAULT_CODEX_REFRESH_INTERVAL,
    )
    parser.add_argument("--claude-cache", type=Path, default=None)
    args = parser.parse_args(argv)
    cache_path = args.claude_cache or default_claude_cache_path()
    if args.capture_claude:
        text = sys.stdin.read(MAX_INPUT_BYTES + 1)
        return 0 if capture_claude_status(text, cache_path) else 1

    collector = UsageCollector(
        claude_cache_path=cache_path,
        codex_refresh_interval=max(30.0, args.codex_refresh_interval),
    )
    if args.once:
        print(json.dumps(collector.snapshot(), separators=(",", ":")))
        return 0
    try:
        emit_stream(collector, max(5.0, args.interval))
    except BrokenPipeError:
        return 0
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
