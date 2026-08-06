#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from collections.abc import Sequence
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "dot_local/lib/hypr_status_stream.py"
sys.path.insert(0, str(MODULE_PATH.parent))
import ghostty_status as ghostty

SPEC = importlib.util.spec_from_file_location("hypr_status_stream", MODULE_PATH)
assert SPEC and SPEC.loader
status = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = status
SPEC.loader.exec_module(status)


class MetricsTest(unittest.TestCase):
    def test_theme_palette_is_complete_when_generated_file_is_partial(self) -> None:
        palette = status.parse_theme_palette(
            'return { accent = "FE8019", text = "bad" }'
        )
        self.assertEqual(palette["accent"], "#fe8019")
        self.assertEqual(palette["text"], status.DEFAULT_PALETTE["text"])
        self.assertEqual(set(palette), set(status.THEME_KEYS))

    def test_cpu_uses_delta_and_counts_iowait_as_idle(self) -> None:
        old = status.parse_cpu_times("cpu  10 0 10 70 10 0 0 0\n")
        new = status.parse_cpu_times("cpu  20 0 20 120 20 0 0 0\n")
        self.assertEqual(status.cpu_percent(old, new), 25)

    def test_memory_uses_mem_available_and_rejects_malformed_input(self) -> None:
        self.assertEqual(
            status.memory_percent("MemTotal: 1000 kB\nMemAvailable: 250 kB\n"), 75
        )
        self.assertIsNone(status.memory_percent("MemTotal: nope\n"))

    def test_disk_busy_is_trailing_window_not_transfer_rate(self) -> None:
        old = status.DiskSample(10.0, {"nvme0n1": status.DiskCounters(100, 200, 1_000)})
        new = status.DiskSample(
            40.0, {"nvme0n1": status.DiskCounters(61_540, 30_920, 11_200)}
        )
        busy, tooltip = status.disk_busy_percent(old, new)
        self.assertEqual(busy, 34)
        self.assertIn("last 30s", tooltip)
        self.assertIn("read 1.0 MiB/s", tooltip)
        self.assertIn("write 0.5 MiB/s", tooltip)

    def test_disk_busy_clamps_devices_with_parallel_io(self) -> None:
        old = status.DiskSample(0, {"sda": status.DiskCounters(0, 0, 0)})
        new = status.DiskSample(1, {"sda": status.DiskCounters(0, 0, 2_000)})
        self.assertEqual(status.disk_busy_percent(old, new)[0], 100)

    def test_temperatures_are_hidden_until_hot_and_reject_impossible_values(
        self,
    ) -> None:
        self.assertEqual(status.parse_temperature("74999"), 75)
        self.assertIsNone(status.parse_temperature("not-a-sensor"))
        self.assertIsNone(status.parse_temperature("999000"))
        self.assertIsNone(status.hot_temperature(74))
        self.assertEqual(status.hot_temperature(75), 75)

    def test_battery_summary_detects_laptops_and_handles_malformed_capacity(
        self,
    ) -> None:
        desktop = status.summarize_batteries([])
        self.assertFalse(desktop.is_laptop)
        laptop = status.summarize_batteries(
            [
                {"capacity": "80", "status": "Discharging"},
                {"capacity": "broken", "status": "Discharging"},
            ]
        )
        self.assertTrue(laptop.is_laptop)
        self.assertEqual(laptop.percent, 80)
        self.assertEqual(laptop.state, "Discharging")

    def test_wifi_parser_preserves_escaped_ssids_and_ignores_inactive_rows(
        self,
    ) -> None:
        wifi = status.parse_wifi_status(
            " :neighbour:92:wlan0\n*:studio\\:5g:67:wlan0\n"
        )
        self.assertTrue(wifi.connected)
        self.assertEqual(wifi.ssid, "studio:5g")
        self.assertEqual(wifi.strength, 67)
        self.assertEqual(wifi.device, "wlan0")

    def test_nvidia_stats_keep_valid_gpus_when_another_row_is_malformed(self) -> None:
        gpu, temperature = status.parse_nvidia_stats("55, 79\nbroken, row\n120, 250\n")
        self.assertEqual(gpu, 100)
        self.assertEqual(temperature, 79)


class WorkspaceTest(unittest.TestCase):
    @staticmethod
    def invisible_tag(payload: str) -> str:
        return "".join(chr(0xE0000 + ord(character)) for character in payload) + chr(
            0xE007F
        )

    @classmethod
    def window_tag(cls, window_id: int) -> str:
        return cls.invisible_tag(f"wid:{window_id}")

    @staticmethod
    def atspi_item(
        object_path: str,
        parent_path: str,
        index: int,
        child_count: int,
        name: str,
        role: int,
    ) -> list[object]:
        reference = [":1.13", object_path]
        return [
            reference,
            [":1.13", ghostty.ATSPI_ROOT],
            [":1.13", parent_path],
            index,
            child_count,
            ["org.a11y.atspi.Accessible"],
            name,
            role,
            "",
            [0, 0],
        ]

    @staticmethod
    def atspi_cache(items: list[list[object]]) -> str:
        return json.dumps({"type": "a((so)(so)(so)iiassusau)", "data": [items]})

    def ghostty_fixture(
        self,
    ) -> tuple[str, list[ghostty.AtspiNode], list[ghostty.GhosttyWindow]]:
        items = [
            self.atspi_item(
                ghostty.ATSPI_ROOT, "/org/a11y/atspi/null", -1, 2, "Unnamed", 75
            ),
            self.atspi_item(
                "/frame/1",
                ghostty.ATSPI_ROOT,
                0,
                1,
                "❯ scratch",
                ghostty.ATSPI_FRAME_ROLE,
            ),
            self.atspi_item("/group/1", "/frame/1", 0, 1, "", 99),
            self.atspi_item(
                "/tab/1", "/group/1", 0, 0, "❯ scratch", ghostty.ATSPI_PANEL_ROLE
            ),
            self.atspi_item(
                "/frame/2",
                ghostty.ATSPI_ROOT,
                1,
                1,
                "🔻 repo",
                ghostty.ATSPI_FRAME_ROLE,
            ),
            self.atspi_item("/group/2", "/frame/2", 0, 4, "", 99),
            self.atspi_item(
                "/tab/2",
                "/group/2",
                0,
                0,
                "🔻 repo" + self.invisible_tag("codex"),
                ghostty.ATSPI_PANEL_ROLE,
            ),
            self.atspi_item(
                "/tab/3", "/group/2", 1, 0, " repo", ghostty.ATSPI_PANEL_ROLE
            ),
            self.atspi_item(
                "/tab/4",
                "/group/2",
                2,
                0,
                "✴ project" + self.invisible_tag("claude"),
                ghostty.ATSPI_PANEL_ROLE,
            ),
            self.atspi_item(
                "/tab/5", "/group/2", 3, 0, "◈ task", ghostty.ATSPI_PANEL_ROLE
            ),
        ]
        cache = self.atspi_cache(items)
        nodes = ghostty.parse_atspi_nodes(cache)
        windows = ghostty.ghostty_windows(
            nodes,
            {"/frame/1": (1600, 1008), "/frame/2": (1701, 1376)},
        )
        return cache, nodes, windows

    def test_wezterm_tabs_and_agent_ttys_map_to_one_hypr_window(self) -> None:
        tty_counts = status.agent_counts_by_tty(
            [
                status.AgentProcess("claude", "/dev/pts/2"),
                status.AgentProcess("codex", "/dev/pts/4"),
                status.AgentProcess("codex", "/dev/pts/5"),
            ]
        )
        rows = [
            {"window_id": 1, "tab_id": 2, "tty_name": "/dev/pts/2", "title": "task"},
            {"window_id": 1, "tab_id": 4, "tty_name": "/dev/pts/4", "title": "repo"},
            {
                "window_id": 1,
                "tab_id": 5,
                "tty_name": "/dev/pts/5",
                "title": "codex | repo",
            },
        ]
        windows = status.wezterm_windows(rows, tty_counts)
        workspaces = status.build_workspaces(
            [
                {
                    "mapped": True,
                    "hidden": False,
                    "address": "0x1",
                    "class": "org.wezfurlong.wezterm",
                    "title": "[2/3] codex | repo",
                    "workspace": {"id": 1},
                    "monitor": 0,
                }
            ],
            [{"id": 0, "name": "DP-2", "activeWorkspace": {"id": 1}}],
            windows,
        )
        self.assertEqual(len(workspaces), 1)
        self.assertEqual(workspaces[0]["claude"], 1)
        self.assertEqual(workspaces[0]["codex"], 2)
        self.assertEqual(workspaces[0]["clients"][0]["tabs"], 3)
        self.assertNotIn("active", workspaces[0])

    def test_multiple_wezterm_guis_keep_duplicate_window_ids_separate(self) -> None:
        clients = [
            {
                "mapped": True,
                "address": "0x1",
                "pid": 101,
                "class": "org.wezfurlong.wezterm",
                "title": "[1/2] chezmoi",
                "workspace": {"id": 1},
                "monitor": 0,
            },
            {
                "mapped": True,
                "address": "0x2",
                "pid": 202,
                "class": "org.wezfurlong.wezterm",
                "title": "ballast",
                "workspace": {"id": 2},
                "monitor": 0,
            },
        ]
        rows_by_socket = {
            "WEZTERM_UNIX_SOCKET=/run/test/wezterm/gui-sock-101": [
                {
                    "window_id": 0,
                    "tab_id": 1,
                    "tty_name": "/dev/pts/12",
                    "title": "chezmoi",
                },
                {
                    "window_id": 0,
                    "tab_id": 2,
                    "tty_name": "/dev/pts/13",
                    "title": "chezmoi",
                },
            ],
            "WEZTERM_UNIX_SOCKET=/run/test/wezterm/gui-sock-202": [
                {
                    "window_id": 0,
                    "tab_id": 1,
                    "tty_name": "/dev/pts/15",
                    "title": "ballast",
                }
            ],
        }

        def runner(command: Sequence[str]) -> str:
            return json.dumps(rows_by_socket.get(command[1], []))

        rows = status.query_wezterm_rows(clients, Path("/run/test"), runner)
        tty_counts = status.agent_counts_by_tty(
            [
                status.AgentProcess("codex", "/dev/pts/12"),
                status.AgentProcess("codex", "/dev/pts/13"),
                status.AgentProcess("claude", "/dev/pts/15"),
            ]
        )
        windows = status.wezterm_windows(rows, tty_counts)
        workspaces = status.build_workspaces(
            clients, [{"id": 0, "name": "DP-2"}], windows
        )

        self.assertEqual(workspaces[0]["codex"], 2)
        self.assertEqual(workspaces[0]["clients"][0]["tabs"], 2)
        self.assertEqual(workspaces[1]["claude"], 1)
        self.assertEqual(workspaces[1]["clients"][0]["tabs"], 1)
        self.assertEqual(
            [window["guiPid"] for window in windows],
            [101, 202],
        )

    def test_wezterm_gui_targets_reject_invalid_pids_and_are_bounded(self) -> None:
        invalid = [True, -1, float("nan"), float("inf"), 9_999_999_999]
        clients = [
            {"class": "org.wezfurlong.wezterm", "pid": pid}
            for pid in [*invalid, *range(1, 100)]
        ]
        targets = status.wezterm_list_targets(clients, Path("/run/test"))

        self.assertEqual(len(targets), status.MAX_WEZTERM_INSTANCES)
        self.assertEqual(targets[0][0], 1)
        self.assertEqual(targets[-1][0], status.MAX_WEZTERM_INSTANCES)

    def test_ghostty_tabs_and_agents_map_to_the_correct_hypr_window(self) -> None:
        _, _, windows = self.ghostty_fixture()
        self.assertEqual(
            [(window.tabs, window.claude, window.codex) for window in windows],
            [(1, 0, 0), (4, 1, 2)],
        )

        clients = [
            {
                "mapped": True,
                "address": "0xscratch",
                "stableId": "01",
                "pid": 42,
                "class": ghostty.GHOSTTY_CLASS,
                "title": "❯ scratch",
                "size": [1600, 1008],
                "workspace": {"id": -98},
                "monitor": 0,
            },
            {
                "mapped": True,
                "address": "0xmain",
                "stableId": "02",
                "pid": 42,
                "class": ghostty.GHOSTTY_CLASS,
                "title": "🔻 repo",
                "size": [1701, 1376],
                "workspace": {"id": 1},
                "monitor": 0,
            },
        ]
        monitor = {"id": 0, "name": "DP-2"}
        workspaces = status.build_workspaces(clients, [monitor], [], ghostty=windows)
        terminal = workspaces[0]["clients"][0]
        self.assertEqual(terminal["tabs"], 4)
        self.assertEqual(workspaces[0]["claude"], 1)
        self.assertEqual(workspaces[0]["codex"], 2)

        retained = status.build_workspaces(
            clients, [monitor], [], previous=workspaces, ghostty=[]
        )
        self.assertEqual(retained[0]["clients"][0]["tabs"], 4)
        self.assertEqual(retained[0]["claude"], 1)
        self.assertEqual(retained[0]["codex"], 2)

    def test_ghostty_atspi_payloads_are_bounded_and_reject_malformed_data(self) -> None:
        self.assertEqual(ghostty.parse_atspi_nodes("not json"), [])
        self.assertEqual(
            ghostty.parse_atspi_extents('{"data":[[0,0,-1,"wide"]]}'), (0, 0)
        )
        items = [
            self.atspi_item(f"/node/{index}", ghostty.ATSPI_ROOT, index, 0, "", 39)
            for index in range(ghostty.MAX_ATSPI_NODES + 10)
        ]
        self.assertEqual(
            len(ghostty.parse_atspi_nodes(self.atspi_cache(items))),
            ghostty.MAX_ATSPI_NODES,
        )

    def test_ghostty_agent_title_markers_and_live_glyphs_are_recognized(self) -> None:
        self.assertEqual(
            ghostty.ghostty_agent_kind("task" + self.invisible_tag("claude")),
            "claude",
        )
        self.assertEqual(ghostty.ghostty_agent_kind("⬦ Codex"), "codex")
        self.assertEqual(ghostty.ghostty_agent_kind("❯ shell"), "")

    def test_ghostty_bus_is_selected_by_hyprland_pid(self) -> None:
        listing = ":1.12 41 other user\n:1.13 42 ghostty user\n"
        self.assertEqual(ghostty.ghostty_bus_names(listing, {42}), [":1.13"])

    def test_duplicate_ghostty_windows_have_stable_one_to_one_assignment(self) -> None:
        windows = [
            ghostty.GhosttyWindow("/frame/1", 0, "same", 100, 100, 2, 1, 0),
            ghostty.GhosttyWindow("/frame/2", 1, "same", 100, 100, 3, 0, 2),
        ]
        clients = [
            {"address": "0xb", "stableId": "02", "title": "same"},
            {"address": "0xa", "stableId": "01", "title": "same"},
        ]
        assigned = ghostty.assign_ghostty_windows(clients, windows, {})
        self.assertEqual(assigned["0xa"].identity, "/frame/1")
        self.assertEqual(assigned["0xb"].identity, "/frame/2")

        retained = ghostty.assign_ghostty_windows(
            clients,
            windows,
            {
                "0xa": {"ghosttyWindowId": "/frame/2"},
                "0xb": {"ghosttyWindowId": "/frame/1"},
            },
        )
        self.assertEqual(retained["0xa"].identity, "/frame/2")
        self.assertEqual(retained["0xb"].identity, "/frame/1")

    def test_collector_reads_ghostty_windows_from_the_bulk_atspi_cache(self) -> None:
        cache, _, expected = self.ghostty_fixture()

        def runner(command: Sequence[str]) -> str:
            if command[-1] == "GetAddress":
                return json.dumps(
                    {"type": "s", "data": ["unix:path=/run/user/1000/at-spi/bus_0"]}
                )
            if command[-1] == "list":
                return ":1.13 42 ghostty user\n"
            if command[-1] == "GetItems":
                return cache
            if "GetExtents" in command:
                dimensions = {
                    "/frame/1": [0, 0, 1600, 1008],
                    "/frame/2": [0, 0, 1701, 1376],
                }
                return json.dumps({"type": "(iiii)", "data": [dimensions[command[-5]]]})
            return ""

        collector = status.StatusCollector(runner=runner)
        clients = [{"class": ghostty.GHOSTTY_CLASS, "pid": 42}]
        self.assertEqual(collector.ghostty_discovery.windows(clients), expected)

    def test_open_group_members_count_as_occupied_but_special_workspaces_do_not(
        self,
    ) -> None:
        clients = [
            {"class": "firefox", "workspace": {"id": 2}, "monitor": 0},
            {"class": "ghost", "workspace": {"id": -98}, "monitor": 0},
            {"class": "hidden", "workspace": {"id": 3}, "monitor": 0, "hidden": True},
        ]
        result = status.build_workspaces(clients, [{"id": 0, "name": "DP-2"}], [])
        self.assertEqual([workspace["id"] for workspace in result], [2, 3])

    def test_renamed_workspace_uses_hyprlands_live_name(self) -> None:
        clients = [
            {
                "class": "firefox",
                "workspace": {"id": 2, "name": "research notes"},
                "monitor": 0,
            },
            {
                "class": "ghostty",
                "workspace": {"id": 2, "name": "research notes"},
                "monitor": 0,
            },
        ]

        result = status.build_workspaces(clients, [{"id": 0, "name": "DP-2"}], [])

        self.assertEqual(result[0]["name"], "research notes")

    def test_missing_workspace_name_falls_back_to_numeric_id(self) -> None:
        clients = [{"class": "firefox", "workspace": {"id": 2}, "monitor": 0}]

        result = status.build_workspaces(clients, [{"id": 0, "name": "DP-2"}], [])

        self.assertEqual(result[0]["name"], "2")

    def test_duplicate_titles_do_not_guess_wrong_wezterm_window(self) -> None:
        windows = [
            {"tabs": 2, "titles": ["same"], "codex": 1},
            {"tabs": 2, "titles": ["same"], "codex": 5},
        ]
        self.assertIsNone(status.match_wezterm_window("[1/2] same", windows))

    def test_invisible_window_identity_maps_duplicate_titles_exactly(self) -> None:
        windows = [
            {"windowId": 11, "tabs": 2, "titles": ["same"], "claude": 1, "codex": 0},
            {"windowId": 22, "tabs": 2, "titles": ["same"], "claude": 0, "codex": 3},
        ]
        clients = [
            {
                "mapped": True,
                "address": "0x1",
                "class": "org.wezfurlong.wezterm",
                "title": "[1/2] same" + self.window_tag(22),
                "workspace": {"id": 1},
                "monitor": 0,
            },
            {
                "mapped": True,
                "address": "0x2",
                "class": "org.wezfurlong.wezterm",
                "title": "[1/2] same" + self.window_tag(11),
                "workspace": {"id": 2},
                "monitor": 0,
            },
        ]
        workspaces = status.build_workspaces(
            clients, [{"id": 0, "name": "DP-2"}], windows
        )
        self.assertEqual(workspaces[0]["codex"], 3)
        self.assertEqual(workspaces[1]["claude"], 1)
        self.assertEqual(workspaces[0]["clients"][0]["weztermWindowId"], 22)

    def test_legacy_duplicate_titles_are_assigned_one_to_one(self) -> None:
        windows = [
            {"windowId": 11, "tabs": 2, "titles": ["same"]},
            {"windowId": 22, "tabs": 2, "titles": ["same"]},
        ]
        clients = [
            {"address": "0x2", "title": "[1/2] same"},
            {"address": "0x1", "title": "[1/2] same"},
        ]
        assigned = status.assign_wezterm_windows(clients, windows, {})
        self.assertEqual({window["windowId"] for window in assigned.values()}, {11, 22})

    def test_transient_wezterm_failure_retains_last_good_counts(self) -> None:
        client = {
            "mapped": True,
            "address": "0x1",
            "class": "org.wezfurlong.wezterm",
            "title": "[1/4] changing spinner title",
            "workspace": {"id": 1},
            "monitor": 0,
        }
        monitor = {"id": 0, "name": "DP-2"}
        previous = status.build_workspaces(
            [client],
            [monitor],
            [
                {
                    "windowId": 1,
                    "tabs": 4,
                    "titles": ["changing spinner title"],
                    "claude": 2,
                    "codex": 3,
                }
            ],
        )
        current = status.build_workspaces([client], [monitor], [], previous)
        self.assertEqual(current[0]["clients"][0]["claude"], 2)
        self.assertEqual(current[0]["clients"][0]["codex"], 3)
        self.assertEqual(current[0]["clients"][0]["tabs"], 4)

    def test_dynamic_wezterm_classes_keep_terminal_semantics(self) -> None:
        app_class = "org.wezfurlong.wezterm.cpu-load-test"
        self.assertTrue(status.is_terminal_class(app_class))
        self.assertEqual(status.icon_name_for(app_class), "org.wezfurlong.wezterm")

    def test_icon_resolution_prefers_vector_then_nearest_raster(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            svg = root / "scalable/apps/example.svg"
            png = root / "64x64/apps/example.png"
            svg.parent.mkdir(parents=True)
            png.parent.mkdir(parents=True)
            svg.touch()
            png.touch()
            resolved = status.resolve_icon("example", (root,))
            self.assertEqual(resolved, svg.resolve().as_uri())

    def test_malformed_json_is_an_empty_collection(self) -> None:
        self.assertEqual(status.parse_json_array("null"), [])
        self.assertEqual(status.parse_json_array("not json"), [])


if __name__ == "__main__":
    unittest.main()
