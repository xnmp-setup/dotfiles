#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "dot_local/lib/ai_usage_stream.py"
SPEC = importlib.util.spec_from_file_location("ai_usage_stream", MODULE_PATH)
assert SPEC and SPEC.loader
usage = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = usage
SPEC.loader.exec_module(usage)

NOW = 1_800_000_000


class ParsingTest(unittest.TestCase):
    def test_claude_uses_five_hour_primary_and_weekly_secondary(self) -> None:
        parsed = usage.parse_claude_status(
            {
                "rate_limits": {
                    "five_hour": {
                        "used_percentage": 23.5,
                        "resets_at": NOW + 300,
                    },
                    "seven_day": {
                        "used_percentage": 41.2,
                        "resets_at": NOW + 86_400,
                    },
                }
            }
        )
        self.assertEqual(parsed.primary, usage.UsageWindow(76, NOW + 300, 300))
        self.assertEqual(
            parsed.secondary, usage.UsageWindow(59, NOW + 86_400, 10_080)
        )

    def test_codex_ignores_notifications_and_prefers_named_codex_bucket(self) -> None:
        lines = [
            json.dumps({"id": 0, "result": {"userAgent": "test"}}),
            json.dumps({"method": "remoteControl/status/changed", "params": {}}),
            json.dumps(
                {
                    "id": 1,
                    "result": {
                        "rateLimits": None,
                        "rateLimitsByLimitId": {
                            "codex": {
                                "primary": {
                                    "usedPercent": 65,
                                    "windowDurationMins": 10_080,
                                    "resetsAt": NOW + 600,
                                },
                                "secondary": None,
                            }
                        },
                    },
                }
            ),
        ]
        parsed = usage.parse_codex_messages(lines)
        self.assertEqual(parsed.primary, usage.UsageWindow(65, NOW + 600, 10_080))
        self.assertIsNone(parsed.secondary)

    def test_malformed_null_and_huge_values_are_rejected_or_bounded(self) -> None:
        self.assertIsNone(usage.parse_claude_status(None))
        self.assertIsNone(usage.parse_codex_messages(["not json", "x" * 1_048_577]))
        parsed = usage.parse_codex_result(
            {
                "rateLimits": {
                    "primary": {
                        "usedPercent": 90_000,
                        "resetsAt": usage.MAX_RESET_TIMESTAMP + 1,
                    }
                }
            }
        )
        self.assertIsNone(parsed)


class CacheTest(unittest.TestCase):
    def payload(self, primary_reset: int, secondary_reset: int) -> str:
        return json.dumps(
            {
                "rate_limits": {
                    "five_hour": {
                        "used_percentage": 18,
                        "resets_at": primary_reset,
                    },
                    "seven_day": {
                        "used_percentage": 52,
                        "resets_at": secondary_reset,
                    },
                }
            }
        )

    def test_capture_is_atomic_private_and_expired_windows_disappear(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested/claude.json"
            self.assertTrue(
                usage.capture_claude_status(
                    self.payload(NOW + 60, NOW + 600), path, observed_at=NOW
                )
            )
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            current = usage.read_claude_cache(path, now=NOW)
            self.assertEqual(current.primary.percent, 82)
            self.assertEqual(current.primary.window_minutes, 300)
            after_primary_reset = usage.read_claude_cache(path, now=NOW + 61)
            self.assertIsNone(after_primary_reset.primary)
            self.assertEqual(after_primary_reset.secondary.percent, 48)
            self.assertIsNone(usage.read_claude_cache(path, now=NOW + 601))

    def test_absent_rate_limits_do_not_overwrite_last_good_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "claude.json"
            self.assertTrue(
                usage.capture_claude_status(
                    self.payload(NOW + 60, NOW + 600), path, observed_at=NOW
                )
            )
            before = path.read_text()
            self.assertFalse(usage.capture_claude_status("{}", path, observed_at=NOW))
            self.assertEqual(path.read_text(), before)


class CollectorTest(unittest.TestCase):
    def test_transient_codex_failure_retains_last_good_until_its_reset(self) -> None:
        fetched = iter(
            [
                usage.ProviderUsage(
                    primary=usage.UsageWindow(65, NOW + 600, 10_080)
                ),
                None,
            ]
        )
        clocks = {"wall": float(NOW), "mono": 0.0}
        with tempfile.TemporaryDirectory() as directory:
            collector = usage.UsageCollector(
                claude_cache_path=Path(directory) / "missing.json",
                codex_fetcher=lambda: next(fetched),
                wall_clock=lambda: clocks["wall"],
                monotonic_clock=lambda: clocks["mono"],
                codex_refresh_interval=300,
            )
            self.assertEqual(collector.snapshot()["codex"]["percent"], 65)
            clocks.update(wall=NOW + 301, mono=301)
            self.assertEqual(collector.snapshot()["codex"]["percent"], 65)
            clocks.update(wall=NOW + 601, mono=302)
            self.assertIsNone(collector.snapshot()["codex"]["percent"])

    def test_app_server_request_sequence_is_initialized_before_rate_limit_read(self) -> None:
        requests = usage.codex_requests()
        self.assertEqual(requests[0]["method"], "initialize")
        self.assertEqual(requests[1], {"method": "initialized", "params": {}})
        self.assertEqual(requests[2]["method"], "account/rateLimits/read")


if __name__ == "__main__":
    unittest.main()
