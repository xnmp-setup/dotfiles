#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Emit one compact JSON status snapshot per second for the Quickshell bar."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict, deque
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from ghostty_status import (
    GhosttyDiscovery,
    GhosttyWindow,
    assign_ghostty_windows,
    is_ghostty_class,
)

JsonObject = dict[str, Any]
CommandRunner = Callable[[Sequence[str]], str]


@dataclass(frozen=True)
class CpuTimes:
    total: int
    idle: int


@dataclass(frozen=True)
class DiskCounters:
    reads: int
    writes: int
    busy_ms: int


@dataclass(frozen=True)
class DiskSample:
    timestamp: float
    counters: Mapping[str, DiskCounters]


@dataclass(frozen=True)
class AgentProcess:
    kind: str
    tty: str


@dataclass(frozen=True)
class BatteryStatus:
    is_laptop: bool
    percent: int | None
    state: str


@dataclass(frozen=True)
class WifiStatus:
    connected: bool
    ssid: str
    strength: int | None
    device: str


APP_ICONS: Mapping[str, str] = {
    "org.wezfurlong.wezterm": "org.wezfurlong.wezterm",
    "com.mitchellh.ghostty": "com.mitchellh.ghostty",
    "google-chrome": "google-chrome",
    "google-chrome-stable": "google-chrome",
    "chromium": "chromium",
    "obsidian": "obsidian",
    "dev.zed.zed": "dev.zed.Zed",
    "dev.zed.zed-dev": "dev.zed.Zed",
    "code": "visual-studio-code",
    "code-oss": "visual-studio-code",
    "firefox": "firefox",
}
WEZTERM_CLASS = "org.wezfurlong.wezterm"
PHYSICAL_DISK_EXCLUDES = ("loop", "ram", "zram", "dm-", "md")
CPU_HWMON_NAMES = frozenset({"coretemp", "k10temp", "zenpower"})
GPU_HWMON_NAMES = frozenset({"amdgpu", "nouveau", "nvidia"})
HOT_TEMPERATURE_C = 75
TITLE_PREFIX = re.compile(r"^(?:\[Z\]\s+)?(?:\[\d+/(\d+)\]\s+)?")
WEZTERM_WINDOW_TAG = re.compile(r"([\U000e0020-\U000e007e]+)\U000e007f$")
THEME_KEYS = (
    "accent",
    "accent_light",
    "background",
    "surface",
    "border",
    "text",
    "text_dim",
)
DEFAULT_PALETTE: Mapping[str, str] = {
    "accent": "#d4607a",
    "accent_light": "#e87898",
    "background": "#0a0e28",
    "surface": "#2a3352",
    "border": "#3c4268",
    "text": "#d8dce8",
    "text_dim": "#8088b4",
}
ICON_ROOTS = tuple(
    path
    for path in (
        Path.home() / ".local/share/icons/hicolor",
        Path("/usr/local/share/icons/hicolor"),
        Path("/usr/share/icons/hicolor"),
        Path("/run/current-system/sw/share/icons/hicolor"),
    )
    if path.is_dir()
)


def clamp_percent(value: float) -> int:
    return round(max(0.0, min(100.0, value)))


def parse_theme_palette(text: str) -> dict[str, str]:
    palette = dict(DEFAULT_PALETTE)
    for key in THEME_KEYS:
        match = re.search(rf"\b{key}\s*=\s*[\"']([0-9a-fA-F]{{6}})[\"']", text)
        if match:
            palette[key] = "#" + match.group(1).lower()
    return palette


def parse_cpu_times(text: str) -> CpuTimes | None:
    line = next((line for line in text.splitlines() if line.startswith("cpu ")), "")
    try:
        values = [int(value) for value in line.split()[1:]]
    except ValueError:
        return None
    if len(values) < 4:
        return None
    return CpuTimes(
        total=sum(values), idle=values[3] + (values[4] if len(values) > 4 else 0)
    )


def cpu_percent(previous: CpuTimes | None, current: CpuTimes | None) -> int | None:
    if previous is None or current is None:
        return None
    total_delta = current.total - previous.total
    idle_delta = current.idle - previous.idle
    if total_delta <= 0:
        return None
    return clamp_percent(100.0 * (total_delta - idle_delta) / total_delta)


def memory_percent(text: str) -> int | None:
    values: dict[str, int] = {}
    for line in text.splitlines():
        name, separator, rest = line.partition(":")
        if separator and name in {"MemTotal", "MemAvailable"}:
            try:
                values[name] = int(rest.split()[0])
            except (IndexError, ValueError):
                return None
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable")
    if total <= 0 or available is None:
        return None
    return clamp_percent(100.0 * (total - available) / total)


def parse_temperature(text: str) -> int | None:
    """Parse a Linux hwmon millidegree value and reject impossible readings."""
    try:
        value = float(text.strip()) / 1000.0
    except ValueError:
        return None
    if not 0 <= value <= 200:
        return None
    return round(value)


def hot_temperature(value: int | None) -> int | None:
    return value if value is not None and value >= HOT_TEMPERATURE_C else None


def summarize_batteries(rows: Sequence[Mapping[str, str]]) -> BatteryStatus:
    if not rows:
        return BatteryStatus(is_laptop=False, percent=None, state="")
    capacities: list[int] = []
    states: list[str] = []
    for row in rows:
        try:
            capacity = int(row.get("capacity", ""))
        except ValueError:
            capacity = -1
        if 0 <= capacity <= 100:
            capacities.append(capacity)
        state = row.get("status", "").strip()
        if state:
            states.append(state)
    percent = clamp_percent(sum(capacities) / len(capacities)) if capacities else None
    state = states[0] if len(set(states)) == 1 else "Mixed" if states else "Unknown"
    return BatteryStatus(is_laptop=True, percent=percent, state=state)


def split_nmcli_row(line: str) -> list[str]:
    """Split nmcli terse output while preserving escaped colons and backslashes."""
    fields: list[str] = []
    current: list[str] = []
    escaped = False
    for character in line:
        if escaped:
            current.append(character)
            escaped = False
        elif character == "\\":
            escaped = True
        elif character == ":":
            fields.append("".join(current))
            current = []
        else:
            current.append(character)
    if escaped:
        current.append("\\")
    fields.append("".join(current))
    return fields


def parse_wifi_status(text: str) -> WifiStatus:
    for line in text.splitlines():
        fields = split_nmcli_row(line)
        if len(fields) != 4 or fields[0] != "*":
            continue
        try:
            strength = clamp_percent(float(fields[2]))
        except ValueError:
            strength = None
        return WifiStatus(
            connected=True,
            ssid=fields[1],
            strength=strength,
            device=fields[3],
        )
    return WifiStatus(connected=False, ssid="", strength=None, device="")


def parse_nvidia_stats(text: str) -> tuple[int | None, int | None]:
    utilization: list[int] = []
    temperatures: list[int] = []
    for line in text.splitlines():
        fields = [field.strip() for field in line.split(",")]
        if len(fields) != 2:
            continue
        try:
            utilization.append(clamp_percent(float(fields[0])))
            temperature = int(fields[1])
        except ValueError:
            continue
        if 0 <= temperature <= 200:
            temperatures.append(temperature)
    return (
        max(utilization) if utilization else None,
        max(temperatures) if temperatures else None,
    )


def parse_diskstats(text: str, devices: Iterable[str]) -> dict[str, DiskCounters]:
    wanted = set(devices)
    result: dict[str, DiskCounters] = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 13 or fields[2] not in wanted:
            continue
        try:
            # Linux block stats: sectors read, sectors written, ms doing I/O.
            result[fields[2]] = DiskCounters(
                reads=int(fields[5]), writes=int(fields[9]), busy_ms=int(fields[12])
            )
        except ValueError:
            continue
    return result


def disk_busy_percent(
    old: DiskSample | None, new: DiskSample
) -> tuple[int | None, str]:
    if old is None or new.timestamp <= old.timestamp:
        return None, "Collecting a 30-second disk activity window"
    elapsed = new.timestamp - old.timestamp
    measurements: list[tuple[float, str, float, float]] = []
    for device, current in new.counters.items():
        previous = old.counters.get(device)
        if previous is None:
            continue
        busy = max(0, current.busy_ms - previous.busy_ms) / (elapsed * 1000.0) * 100.0
        # Kernel diskstats sectors are 512-byte units regardless of filesystem block size.
        read_mib = max(0, current.reads - previous.reads) * 512 / elapsed / 1024 / 1024
        write_mib = (
            max(0, current.writes - previous.writes) * 512 / elapsed / 1024 / 1024
        )
        measurements.append((busy, device, read_mib, write_mib))
    if not measurements:
        return None, "No physical disk activity data available"
    busy, device, read_mib, write_mib = max(measurements)
    window = min(30, round(elapsed))
    tooltip = (
        f"{device} was servicing I/O {clamp_percent(busy)}% of the last {window}s"
        f" · read {read_mib:.1f} MiB/s · write {write_mib:.1f} MiB/s"
    )
    return clamp_percent(busy), tooltip


def parse_tab_count(title: str) -> int:
    title = strip_wezterm_window_tag(title)
    match = TITLE_PREFIX.match(title)
    if not match or match.group(1) is None:
        return 1
    try:
        return max(1, int(match.group(1)))
    except ValueError:
        return 1


def title_body(title: str) -> str:
    return TITLE_PREFIX.sub("", strip_wezterm_window_tag(title), count=1)


def wezterm_window_id_from_title(title: str) -> int | None:
    match = WEZTERM_WINDOW_TAG.search(title)
    if not match:
        return None
    payload = "".join(chr(ord(character) - 0xE0000) for character in match.group(1))
    if not payload.startswith("wid:"):
        return None
    try:
        return int(payload.removeprefix("wid:"))
    except ValueError:
        return None


def strip_wezterm_window_tag(title: str) -> str:
    return WEZTERM_WINDOW_TAG.sub("", title)


def normalize_tty(tty: str) -> str:
    return tty if tty.startswith("/dev/") else f"/dev/{tty}"


def agent_counts_by_tty(processes: Iterable[AgentProcess]) -> dict[str, dict[str, int]]:
    counts: dict[str, dict[str, int]] = defaultdict(lambda: {"claude": 0, "codex": 0})
    for process in processes:
        if process.kind in {"claude", "codex"} and process.tty:
            counts[normalize_tty(process.tty)][process.kind] += 1
    return dict(counts)


def wezterm_windows(
    rows: Sequence[Mapping[str, Any]], tty_counts: Mapping[str, Mapping[str, int]]
) -> list[JsonObject]:
    grouped: dict[int, list[Mapping[str, Any]]] = defaultdict(list)
    for row in rows:
        try:
            grouped[int(row["window_id"])].append(row)
        except (KeyError, TypeError, ValueError):
            continue
    result: list[JsonObject] = []
    for window_id, panes in grouped.items():
        tab_ids = {pane.get("tab_id") for pane in panes}
        counts = {"claude": 0, "codex": 0}
        titles: set[str] = set()
        for pane in panes:
            for key in ("title", "window_title"):
                value = pane.get(key)
                if isinstance(value, str) and value:
                    titles.add(title_body(value))
            pane_counts = tty_counts.get(str(pane.get("tty_name", "")), {})
            for kind in counts:
                counts[kind] += int(pane_counts.get(kind, 0))
        result.append(
            {
                "windowId": window_id,
                "tabs": max(1, len(tab_ids)),
                "titles": sorted(titles, key=len, reverse=True),
                **counts,
            }
        )
    return result


def match_wezterm_window(
    title: str, windows: Sequence[Mapping[str, Any]]
) -> Mapping[str, Any] | None:
    tagged_id = wezterm_window_id_from_title(title)
    if tagged_id is not None:
        tagged = [window for window in windows if window.get("windowId") == tagged_id]
        return tagged[0] if len(tagged) == 1 else None
    tabs = parse_tab_count(title)
    body = title_body(title)
    candidates = [window for window in windows if int(window.get("tabs", 1)) == tabs]
    exact = [window for window in candidates if body in window.get("titles", [])]
    if len(exact) == 1:
        return exact[0]
    suffix = [
        window
        for window in candidates
        if any(
            body.endswith(candidate) or candidate.endswith(body)
            for candidate in window.get("titles", [])
        )
    ]
    return (
        suffix[0]
        if len(suffix) == 1
        else (candidates[0] if len(candidates) == 1 else None)
    )


def assign_wezterm_windows(
    clients: Sequence[Mapping[str, Any]],
    windows: Sequence[Mapping[str, Any]],
    previous_clients: Mapping[str, Mapping[str, Any]],
) -> dict[str, Mapping[str, Any]]:
    """Assign each mux window at most once, preferring stable title identities."""
    available = {
        int(window["windowId"]): window
        for window in windows
        if isinstance(window.get("windowId"), int)
    }
    assigned: dict[str, Mapping[str, Any]] = {}
    ordered = sorted(clients, key=lambda client: str(client.get("address", "")))

    def claim(client: Mapping[str, Any], window_id: int | None) -> bool:
        address = str(client.get("address", ""))
        if not address or window_id is None or window_id not in available:
            return False
        assigned[address] = available.pop(window_id)
        return True

    pending: list[Mapping[str, Any]] = []
    for client in ordered:
        title = str(client.get("title", ""))
        if claim(client, wezterm_window_id_from_title(title)):
            continue
        previous = previous_clients.get(str(client.get("address", "")), {})
        try:
            previous_id = int(previous.get("weztermWindowId"))
        except (TypeError, ValueError):
            previous_id = None
        if not claim(client, previous_id):
            pending.append(client)

    # Untagged legacy windows get a deterministic one-to-one fallback. It keeps
    # aggregate counts correct and stops two identical titles from consuming the
    # same mux window while WezTerm reloads the tagged title formatter.
    for client in pending:
        if not available:
            break
        title = str(client.get("title", ""))
        matched = match_wezterm_window(title, list(available.values()))
        if matched is not None:
            claim(client, int(matched["windowId"]))
            continue
        tabs = parse_tab_count(title)
        candidates = sorted(
            (
                window_id
                for window_id, window in available.items()
                if int(window.get("tabs", 1)) == tabs
            )
        )
        if candidates:
            claim(client, candidates[0])
    return assigned


def icon_name_for(app_class: str) -> str:
    normalized = app_class.casefold()
    if normalized.startswith(WEZTERM_CLASS):
        return APP_ICONS[WEZTERM_CLASS]
    return APP_ICONS.get(normalized, app_class or "application-x-executable")


@lru_cache(maxsize=128)
def resolve_icon(icon_name: str, roots: tuple[Path, ...] = ICON_ROOTS) -> str:
    """Return a stable local URL when an icon exists, otherwise its theme name."""
    if icon_name.startswith("/"):
        path = Path(icon_name)
        return path.as_uri() if path.is_file() else "application-x-executable"
    candidates: list[Path] = []
    for root in roots:
        for extension in ("svg", "png", "xpm"):
            candidates.extend(root.glob(f"*/apps/{icon_name}.{extension}"))
    if not candidates:
        for pixmaps in (Path("/usr/local/share/pixmaps"), Path("/usr/share/pixmaps")):
            for extension in ("svg", "png", "xpm"):
                candidate = pixmaps / f"{icon_name}.{extension}"
                if candidate.is_file():
                    candidates.append(candidate)
    if not candidates:
        return icon_name

    def score(path: Path) -> tuple[int, int]:
        if path.suffix == ".svg":
            return (0, 0)
        match = re.search(r"/(\d+)x\d+", str(path))
        size = int(match.group(1)) if match else 0
        return (1, abs(size - 64))

    return min(candidates, key=score).resolve().as_uri()


def icon_for(app_class: str) -> str:
    return resolve_icon(icon_name_for(app_class))


def is_wezterm_class(app_class: str) -> bool:
    return app_class.casefold().startswith(WEZTERM_CLASS)


def is_terminal_class(app_class: str) -> bool:
    normalized = app_class.casefold()
    return is_wezterm_class(normalized) or is_ghostty_class(normalized)


def build_workspaces(
    clients: Sequence[Mapping[str, Any]],
    monitors: Sequence[Mapping[str, Any]],
    wezterm: Sequence[Mapping[str, Any]],
    previous: Sequence[Mapping[str, Any]] = (),
    ghostty: Sequence[GhosttyWindow] = (),
) -> list[JsonObject]:
    monitor_names = {monitor.get("id"): monitor.get("name", "") for monitor in monitors}
    previous_clients = {
        str(client.get("address", "")): client
        for workspace in previous
        for client in workspace.get("clients", [])
        if isinstance(client, Mapping)
    }
    wezterm_clients = [
        client for client in clients if is_wezterm_class(str(client.get("class", "")))
    ]
    matched_wezterm = assign_wezterm_windows(wezterm_clients, wezterm, previous_clients)
    ghostty_clients = [
        client for client in clients if is_ghostty_class(str(client.get("class", "")))
    ]
    matched_ghostty = assign_ghostty_windows(ghostty_clients, ghostty, previous_clients)
    grouped: dict[tuple[int, str], list[JsonObject]] = defaultdict(list)
    for client in clients:
        workspace = client.get("workspace") or {}
        try:
            workspace_id = int(workspace.get("id", 0))
        except (TypeError, ValueError):
            continue
        if workspace_id <= 0 or not client.get("mapped", True):
            continue
        monitor_name = str(monitor_names.get(client.get("monitor"), ""))
        app_class = str(client.get("class", ""))
        app: JsonObject = {
            "address": str(client.get("address", "")),
            "class": app_class,
            "icon": icon_for(app_class),
            "terminal": is_terminal_class(app_class),
            "tabs": 1,
            "claude": 0,
            "codex": 0,
        }
        if is_wezterm_class(app_class):
            matched = matched_wezterm.get(app["address"])
            if matched:
                for field in ("tabs", "claude", "codex"):
                    app[field] = int(matched.get(field, app[field]))
                app["weztermWindowId"] = int(matched["windowId"])
            else:
                stale = previous_clients.get(app["address"])
                if stale:
                    for field in ("tabs", "claude", "codex"):
                        app[field] = int(stale.get(field, app[field]))
                else:
                    app["tabs"] = parse_tab_count(str(client.get("title", "")))
        elif is_ghostty_class(app_class):
            ghostty_window = matched_ghostty.get(app["address"])
            if ghostty_window:
                for field in ("tabs", "claude", "codex"):
                    app[field] = int(getattr(ghostty_window, field))
                app["ghosttyWindowId"] = ghostty_window.identity
            else:
                stale = previous_clients.get(app["address"])
                if stale:
                    for field in ("tabs", "claude", "codex"):
                        app[field] = int(stale.get(field, app[field]))
        grouped[(workspace_id, monitor_name)].append(app)

    result: list[JsonObject] = []
    for (workspace_id, monitor_name), apps in sorted(grouped.items()):
        result.append(
            {
                "id": workspace_id,
                "name": str(workspace_id),
                "monitor": monitor_name,
                "clients": apps,
                "claude": sum(app["claude"] for app in apps),
                "codex": sum(app["codex"] for app in apps),
            }
        )
    return result


def try_parse_json_array(text: str) -> list[Mapping[str, Any]] | None:
    try:
        value = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return None
    return value if isinstance(value, list) else None


def parse_json_array(text: str) -> list[Mapping[str, Any]]:
    return try_parse_json_array(text) or []


def run_command(command: Sequence[str]) -> str:
    try:
        return subprocess.run(
            command, check=False, capture_output=True, text=True, timeout=0.8
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


class StatusCollector:
    def __init__(
        self,
        *,
        proc_root: Path = Path("/proc"),
        sys_root: Path = Path("/sys"),
        runner: CommandRunner = run_command,
        clock: Callable[[], float] = time.monotonic,
        theme_path: Path | None = None,
    ) -> None:
        self.proc_root = proc_root
        self.sys_root = sys_root
        self.runner = runner
        self.clock = clock
        self.theme_path = theme_path or Path.home() / ".config/hypr/theme-colors.lua"
        self.previous_cpu: CpuTimes | None = None
        self.disk_history: deque[DiskSample] = deque()
        self.cached_workspaces: list[JsonObject] = []
        self.workspace_sample_at = float("-inf")
        self.cached_wifi = WifiStatus(False, "", None, "")
        self.wifi_sample_at = float("-inf")
        self.ghostty_discovery = GhosttyDiscovery(runner)

    def _read(self, path: Path) -> str:
        try:
            return path.read_text()
        except OSError:
            return ""

    def _physical_disks(self) -> list[str]:
        block_root = self.sys_root / "block"
        try:
            return sorted(
                path.name
                for path in block_root.iterdir()
                if not path.name.startswith(PHYSICAL_DISK_EXCLUDES)
            )
        except OSError:
            return []

    def _agent_processes(self) -> list[AgentProcess]:
        result: list[AgentProcess] = []
        try:
            pid_dirs = self.proc_root.iterdir()
        except OSError:
            return result
        for process_dir in pid_dirs:
            if not process_dir.name.isdigit():
                continue
            comm = self._read(process_dir / "comm").strip().casefold()
            kind = "codex" if comm == "codex" else "claude" if comm == "claude" else ""
            if not kind:
                continue
            try:
                tty = os.readlink(process_dir / "fd" / "0")
            except OSError:
                continue
            if tty.startswith("/dev/pts/"):
                result.append(AgentProcess(kind=kind, tty=tty))
        return result

    def _temperature_values(self, paths: Iterable[Path]) -> list[int]:
        values: list[int] = []
        for path in paths:
            value = parse_temperature(self._read(path))
            if value is not None:
                values.append(value)
        return values

    def _cpu_temperature(self) -> int | None:
        hwmon_root = self.sys_root / "class" / "hwmon"
        values: list[int] = []
        try:
            sensors = sorted(hwmon_root.glob("hwmon*"))
        except OSError:
            sensors = []
        for sensor in sensors:
            if self._read(sensor / "name").strip().casefold() in CPU_HWMON_NAMES:
                values.extend(self._temperature_values(sensor.glob("temp*_input")))
        if values:
            return max(values)

        thermal_root = self.sys_root / "class" / "thermal"
        try:
            zones = sorted(thermal_root.glob("thermal_zone*"))
        except OSError:
            zones = []
        for zone in zones:
            sensor_type = self._read(zone / "type").strip().casefold()
            if any(name in sensor_type for name in ("cpu", "x86_pkg", "soc_thermal")):
                values.extend(self._temperature_values([zone / "temp"]))
        return max(values) if values else None

    def _gpu_stats(self) -> tuple[int | None, int | None]:
        drm_root = self.sys_root / "class" / "drm"
        try:
            busy_paths = sorted(drm_root.glob("card*/device/gpu_busy_percent"))
            hwmon_paths = sorted(drm_root.glob("card*/device/hwmon/hwmon*"))
        except OSError:
            busy_paths = []
            hwmon_paths = []
        utilization: list[int] = []
        for path in busy_paths:
            try:
                utilization.append(clamp_percent(float(path.read_text().strip())))
            except (OSError, ValueError):
                continue
        temperatures: list[int] = []
        for sensor in hwmon_paths:
            name = self._read(sensor / "name").strip().casefold()
            if name in GPU_HWMON_NAMES:
                temperatures.extend(
                    self._temperature_values(sensor.glob("temp*_input"))
                )

        gpu = max(utilization) if utilization else None
        temperature = max(temperatures) if temperatures else None
        if gpu is None or temperature is None:
            nvidia_gpu, nvidia_temperature = parse_nvidia_stats(
                self.runner(
                    [
                        "nvidia-smi",
                        "--query-gpu=utilization.gpu,temperature.gpu",
                        "--format=csv,noheader,nounits",
                    ]
                )
            )
            gpu = gpu if gpu is not None else nvidia_gpu
            temperature = temperature if temperature is not None else nvidia_temperature
        return gpu, temperature

    def _batteries(self) -> BatteryStatus:
        power_root = self.sys_root / "class" / "power_supply"
        try:
            supplies = sorted(power_root.iterdir())
        except OSError:
            supplies = []
        rows = [
            {
                "capacity": self._read(supply / "capacity").strip(),
                "status": self._read(supply / "status").strip(),
            }
            for supply in supplies
            if self._read(supply / "type").strip().casefold() == "battery"
        ]
        return summarize_batteries(rows)

    def _wifi(self, now: float) -> WifiStatus:
        if now - self.wifi_sample_at < 5.0:
            return self.cached_wifi
        self.cached_wifi = parse_wifi_status(
            self.runner(
                [
                    "nmcli",
                    "--terse",
                    "--escape",
                    "yes",
                    "--fields",
                    "IN-USE,SSID,SIGNAL,DEVICE",
                    "device",
                    "wifi",
                    "list",
                    "--rescan",
                    "no",
                ]
            )
        )
        self.wifi_sample_at = now
        return self.cached_wifi

    def _workspaces(self, now: float) -> list[JsonObject]:
        if now - self.workspace_sample_at < 1.0:
            return self.cached_workspaces
        clients = try_parse_json_array(self.runner(["hyprctl", "-j", "clients"]))
        monitors = try_parse_json_array(self.runner(["hyprctl", "-j", "monitors"]))
        rows = try_parse_json_array(
            self.runner(["wezterm", "cli", "list", "--format", "json"])
        )
        if clients is None or monitors is None:
            return self.cached_workspaces
        tty_counts = agent_counts_by_tty(self._agent_processes())
        self.cached_workspaces = build_workspaces(
            clients,
            monitors,
            wezterm_windows(rows or [], tty_counts),
            previous=self.cached_workspaces,
            ghostty=self.ghostty_discovery.windows(clients),
        )
        self.workspace_sample_at = now
        return self.cached_workspaces

    def snapshot(self) -> JsonObject:
        now = self.clock()
        current_cpu = parse_cpu_times(self._read(self.proc_root / "stat"))
        cpu = cpu_percent(self.previous_cpu, current_cpu)
        self.previous_cpu = current_cpu

        disk_sample = DiskSample(
            timestamp=now,
            counters=parse_diskstats(
                self._read(self.proc_root / "diskstats"), self._physical_disks()
            ),
        )
        self.disk_history.append(disk_sample)
        while len(self.disk_history) > 1 and self.disk_history[1].timestamp <= now - 30:
            self.disk_history.popleft()
        io, io_tooltip = disk_busy_percent(
            self.disk_history[0] if len(self.disk_history) > 1 else None, disk_sample
        )
        battery = self._batteries()
        wifi = self._wifi(now) if battery.is_laptop else WifiStatus(False, "", None, "")
        gpu, gpu_temperature = self._gpu_stats()
        battery_tooltip = (
            f"Battery {battery.state.casefold()}"
            if battery.state
            else "Battery status unavailable"
        )
        wifi_tooltip = (
            f"{wifi.ssid} · {wifi.device}" if wifi.connected else "Wi-Fi disconnected"
        )
        return {
            "metrics": {
                "cpu": cpu,
                "ram": memory_percent(self._read(self.proc_root / "meminfo")),
                "io": io,
                "gpu": gpu,
                "ioTooltip": io_tooltip,
                "laptop": battery.is_laptop,
                "battery": battery.percent,
                "batteryTooltip": battery_tooltip,
                "wifi": wifi.strength,
                "wifiConnected": wifi.connected,
                "wifiTooltip": wifi_tooltip,
                "cpuTemp": hot_temperature(self._cpu_temperature()),
                "gpuTemp": hot_temperature(gpu_temperature),
            },
            "palette": parse_theme_palette(self._read(self.theme_path)),
            "workspaces": self._workspaces(now),
        }


def emit_stream(collector: StatusCollector, interval: float) -> None:
    while True:
        started = time.monotonic()
        print(json.dumps(collector.snapshot(), separators=(",", ":")), flush=True)
        time.sleep(max(0.0, interval - (time.monotonic() - started)))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--once", action="store_true", help="emit one snapshot and exit"
    )
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args(argv)
    collector = StatusCollector()
    if args.once:
        print(json.dumps(collector.snapshot(), separators=(",", ":")))
        return 0
    try:
        emit_stream(collector, max(0.2, args.interval))
    except BrokenPipeError:
        return 0
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
