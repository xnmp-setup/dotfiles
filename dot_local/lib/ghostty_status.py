"""Discover Ghostty tabs and coding-agent sessions through GTK's AT-SPI tree."""

from __future__ import annotations

import json
import re
import unicodedata
from collections import defaultdict, deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

CommandRunner = Callable[[Sequence[str]], str]

GHOSTTY_CLASS = "com.mitchellh.ghostty"
ATSPI_ROOT = "/org/a11y/atspi/accessible/root"
ATSPI_CACHE = "/org/a11y/atspi/cache"
ATSPI_FRAME_ROLE = 23
ATSPI_PANEL_ROLE = 39
MAX_ATSPI_NODES = 2048
MAX_GHOSTTY_TABS = 128
INVISIBLE_TAG = re.compile(r"([\U000e0020-\U000e007e]+)\U000e007f")
AGENT_GLYPHS: Mapping[str, frozenset[str]] = {
    "claude": frozenset({"✴", "✹", "✢", "✶", "✻", "✽"}),
    "codex": frozenset({"🔻", "⬣", "⬩", "⬦", "◈", "⬥"}),
}
AGENT_IDLE_GLYPHS = frozenset({"✴", "🔻"})
AGENT_ATTENTION_GLYPHS = frozenset({"✹", "⬣"})


@dataclass(frozen=True)
class AtspiNode:
    object_path: str
    parent_path: str
    index: int
    child_count: int
    name: str
    role: int


@dataclass(frozen=True)
class AgentActivity:
    kind: str
    state: str
    title: str


@dataclass(frozen=True)
class GhosttyWindow:
    identity: str
    index: int
    title: str
    width: int
    height: int
    tabs: int
    claude: int
    codex: int
    activities: tuple[AgentActivity, ...] = ()


def busctl_data(text: str) -> Any | None:
    try:
        value = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return None
    return value.get("data") if isinstance(value, Mapping) else None


def busctl_string(text: str) -> str:
    data = busctl_data(text)
    if not isinstance(data, list) or len(data) != 1:
        return ""
    return data[0] if isinstance(data[0], str) else ""


def ghostty_bus_names(text: str, pids: set[int]) -> list[str]:
    names: list[str] = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 2 or not fields[0].startswith(":"):
            continue
        try:
            pid = int(fields[1])
        except ValueError:
            continue
        if pid in pids:
            names.append(fields[0])
    return names


def parse_atspi_nodes(text: str) -> list[AtspiNode]:
    data = busctl_data(text)
    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], list):
        return []

    nodes: dict[str, AtspiNode] = {}
    for raw in data[0][:MAX_ATSPI_NODES]:
        if not isinstance(raw, list) or len(raw) < 9:
            continue
        identity, parent = raw[0], raw[2]
        if (
            not isinstance(identity, list)
            or len(identity) != 2
            or not isinstance(identity[1], str)
            or not isinstance(parent, list)
            or len(parent) != 2
            or not isinstance(parent[1], str)
        ):
            continue
        index, child_count, name, role = raw[3], raw[4], raw[6], raw[7]
        if not all(
            isinstance(value, int) and not isinstance(value, bool)
            for value in (index, child_count, role)
        ):
            continue
        object_path = identity[1]
        nodes[object_path] = AtspiNode(
            object_path=object_path,
            parent_path=parent[1],
            index=max(-1, index),
            child_count=max(0, child_count),
            name=name[:512] if isinstance(name, str) else "",
            role=role,
        )
    return list(nodes.values())


def parse_atspi_extents(text: str) -> tuple[int, int]:
    data = busctl_data(text)
    if (
        not isinstance(data, list)
        or len(data) != 1
        or not isinstance(data[0], list)
        or len(data[0]) != 4
    ):
        return (0, 0)
    values = data[0]
    if not all(
        isinstance(value, int) and not isinstance(value, bool) for value in values
    ):
        return (0, 0)
    return (max(0, values[2]), max(0, values[3]))


def invisible_tag_payloads(text: str) -> list[str]:
    return [
        "".join(chr(ord(character) - 0xE0000) for character in match.group(1))
        for match in INVISIBLE_TAG.finditer(text)
    ]


def strip_invisible_tags(text: str) -> str:
    return INVISIBLE_TAG.sub("", text)


def strip_invisible_metadata(text: str) -> str:
    return "".join(
        character
        for character in strip_invisible_tags(text)
        if unicodedata.category(character) != "Cf"
    )


def ghostty_agent_kind(title: str) -> str:
    tagged = [
        payload
        for payload in invisible_tag_payloads(title)
        if payload in {"claude", "codex"}
    ]
    if tagged:
        return tagged[-1]
    visible = strip_invisible_tags(title).lstrip()
    return next(
        (kind for kind, glyphs in AGENT_GLYPHS.items() if visible[:1] in glyphs),
        "",
    )


def ghostty_agent_state(title: str) -> str:
    visible = strip_invisible_metadata(title).lstrip()
    glyph = visible[:1]
    if glyph in AGENT_ATTENTION_GLYPHS:
        return "attention"
    if glyph in AGENT_IDLE_GLYPHS:
        return "idle"
    return (
        "working"
        if any(glyph in glyphs for glyphs in AGENT_GLYPHS.values())
        else ""
    )


def ghostty_activity(title: str) -> AgentActivity:
    kind = ghostty_agent_kind(title)
    visible = strip_invisible_metadata(title).lstrip()
    if kind and visible:
        visible = visible[1:].lstrip("\ufe0e\ufe0f ")
    fallback = (
        "Claude Code"
        if kind == "claude"
        else "Codex"
        if kind == "codex"
        else "Shell"
    )
    return AgentActivity(
        kind=kind or "process",
        state=ghostty_agent_state(title) if kind else "",
        title=(visible or fallback)[:160],
    )


def ghostty_windows(
    nodes: Sequence[AtspiNode],
    geometry: Mapping[str, tuple[int, int]],
) -> list[GhosttyWindow]:
    children: dict[str, list[AtspiNode]] = defaultdict(list)
    for node in nodes:
        children[node.parent_path].append(node)
    for siblings in children.values():
        siblings.sort(key=lambda node: (node.index, node.object_path))

    frames = sorted(
        (
            node
            for node in nodes
            if node.parent_path == ATSPI_ROOT and node.role == ATSPI_FRAME_ROLE
        ),
        key=lambda node: (node.index, node.object_path),
    )
    result: list[GhosttyWindow] = []
    for frame in frames:
        candidates: list[tuple[int, int, tuple[str, ...]]] = []
        pending: deque[tuple[AtspiNode, int]] = deque([(frame, 0)])
        visited: set[str] = set()
        while pending and len(visited) < MAX_ATSPI_NODES:
            node, depth = pending.popleft()
            if node.object_path in visited:
                continue
            visited.add(node.object_path)
            direct = children.get(node.object_path, [])
            if direct and all(
                child.role == ATSPI_PANEL_ROLE and child.name for child in direct
            ):
                titles = tuple(child.name for child in direct[:MAX_GHOSTTY_TABS])
                candidates.append((len(titles), -depth, titles))
            pending.extend((child, depth + 1) for child in direct)

        titles = max(candidates, default=(1, 0, (frame.name,)))[2]
        kinds = [ghostty_agent_kind(title) for title in titles]
        width, height = geometry.get(frame.object_path, (0, 0))
        result.append(
            GhosttyWindow(
                identity=frame.object_path,
                index=frame.index,
                title=frame.name,
                width=width,
                height=height,
                tabs=max(1, len(titles)),
                claude=kinds.count("claude"),
                codex=kinds.count("codex"),
                activities=tuple(ghostty_activity(title) for title in titles),
            )
        )
    return result


def assign_ghostty_windows(
    clients: Sequence[Mapping[str, Any]],
    windows: Sequence[GhosttyWindow],
    previous_clients: Mapping[str, Mapping[str, Any]],
) -> dict[str, GhosttyWindow]:
    """Assign AT-SPI tab groups to Hypr windows without reusing either side."""
    available = {window.identity: window for window in windows}
    assigned: dict[str, GhosttyWindow] = {}
    ordered = sorted(
        clients,
        key=lambda client: (
            str(client.get("stableId", "")),
            str(client.get("address", "")),
        ),
    )

    def claim(client: Mapping[str, Any], identity: str) -> bool:
        address = str(client.get("address", ""))
        if not address or identity not in available:
            return False
        assigned[address] = available.pop(identity)
        return True

    pending: list[Mapping[str, Any]] = []
    for client in ordered:
        previous = previous_clients.get(str(client.get("address", "")), {})
        identity = previous.get("ghosttyWindowId")
        if isinstance(identity, str) and claim(client, identity):
            continue
        pending.append(client)

    unmatched: list[Mapping[str, Any]] = []
    for client in pending:
        size = client.get("size")
        if (
            isinstance(size, list)
            and len(size) == 2
            and all(
                isinstance(value, int) and not isinstance(value, bool) for value in size
            )
        ):
            candidates = [
                window.identity
                for window in available.values()
                if (window.width, window.height) == (size[0], size[1])
            ]
            if len(candidates) == 1 and claim(client, candidates[0]):
                continue
        unmatched.append(client)

    pending = []
    for client in unmatched:
        title = strip_invisible_tags(str(client.get("title", "")))
        candidates = [
            window.identity
            for window in available.values()
            if strip_invisible_tags(window.title) == title
        ]
        if len(candidates) == 1 and claim(client, candidates[0]):
            continue
        pending.append(client)

    # GTK's accessibility root and Hyprland both retain creation order. This
    # final one-to-one fallback covers equal-size, equal-title windows; a later
    # unique geometry or title sample replaces it while the stable IDs persist.
    remaining = sorted(
        available.values(), key=lambda window: (window.index, window.identity)
    )
    for client, window in zip(pending, remaining):
        claim(client, window.identity)
    return assigned


def is_ghostty_class(app_class: str) -> bool:
    return app_class.casefold() == GHOSTTY_CLASS


class GhosttyDiscovery:
    """Thin AT-SPI transport; parsing and attribution remain pure functions."""

    def __init__(self, runner: CommandRunner) -> None:
        self.runner = runner
        self.a11y_bus_address = ""

    def _a11y_address(self) -> str:
        if self.a11y_bus_address:
            return self.a11y_bus_address
        address = busctl_string(
            self.runner(
                [
                    "busctl",
                    "--user",
                    "--json=short",
                    "call",
                    "org.a11y.Bus",
                    "/org/a11y/bus",
                    "org.a11y.Bus",
                    "GetAddress",
                ]
            )
        )
        if address.startswith("unix:") and len(address) <= 1024:
            self.a11y_bus_address = address
        return self.a11y_bus_address

    def windows(self, clients: Sequence[Mapping[str, Any]]) -> list[GhosttyWindow]:
        pids: set[int] = set()
        for client in clients:
            if not is_ghostty_class(str(client.get("class", ""))):
                continue
            try:
                pid = int(client.get("pid"))
            except (TypeError, ValueError):
                continue
            if pid > 0:
                pids.add(pid)
        if not pids:
            return []

        address = self._a11y_address()
        if not address:
            return []
        common = ["busctl", "--json=short", f"--address={address}"]
        names = ghostty_bus_names(
            self.runner(
                [
                    "busctl",
                    f"--address={address}",
                    "--no-pager",
                    "--no-legend",
                    "list",
                ]
            ),
            pids,
        )
        result: list[GhosttyWindow] = []
        for name in names:
            nodes = parse_atspi_nodes(
                self.runner(
                    [
                        *common,
                        "call",
                        name,
                        ATSPI_CACHE,
                        "org.a11y.atspi.Cache",
                        "GetItems",
                    ]
                )
            )
            geometry: dict[str, tuple[int, int]] = {}
            for node in nodes:
                if node.parent_path != ATSPI_ROOT or node.role != ATSPI_FRAME_ROLE:
                    continue
                geometry[node.object_path] = parse_atspi_extents(
                    self.runner(
                        [
                            *common,
                            "call",
                            name,
                            node.object_path,
                            "org.a11y.atspi.Component",
                            "GetExtents",
                            "u",
                            "0",
                        ]
                    )
                )
            result.extend(ghostty_windows(nodes, geometry))
        return result
