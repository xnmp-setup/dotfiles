#!/usr/bin/env -S uv run --script
"""Behavioral tests for the WezTerm agent lifecycle hook.

The hook itself stays with the WezTerm configuration; the status bar (now a
separate repository) only reads the runtime state files it writes.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class AgentHookStateTest(unittest.TestCase):
    def test_wezterm_hook_publishes_namespaced_state_atomically(self) -> None:
        script = Path(__file__).parents[1] / "dot_local/bin/executable_wezterm-agent-status"
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ)
            environment.pop("CLAUDECODE", None)
            environment.pop("CLAUDE_PID", None)
            environment.update(
                {
                    "TERM_PROGRAM": "WezTerm",
                    "WEZTERM_PANE": "7",
                    "WEZTERM_UNIX_SOCKET": "/run/user/1000/wezterm/gui-sock-42",
                    "WEZTERM_EXECUTABLE": "/bin/false-gui",
                    "XDG_RUNTIME_DIR": directory,
                }
            )
            path = Path(directory) / "wezterm-agent-state.gui-sock-42.7.codex"
            for state in ("working", "attention", "done"):
                completed = subprocess.run(
                    ["/bin/sh", str(script), state],
                    input="{}",
                    text=True,
                    capture_output=True,
                    check=False,
                    env=environment,
                    timeout=5,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(path.read_text(), state + "\n")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
