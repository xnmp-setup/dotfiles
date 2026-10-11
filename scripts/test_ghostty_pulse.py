#!/usr/bin/env python3
"""Behavioral tests for the Enter flash pulse.

Run: python3 scripts/test_ghostty_pulse.py

ghostty-pulse (dot_local/bin/executable_ghostty-pulse) is run against a plain
file standing in for the terminal device and judged by the escape sequences it
wrote. The zsh trigger (dot_config/zsh/ghostty-command-pulse.zsh) is driven in
a real interactive zsh through zsh/zpty with a fake pulse binary, and judged by
which keystrokes made it fire.
"""

from __future__ import annotations

import os
import pty
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PULSE = ROOT / "dot_local/bin/executable_ghostty-pulse"
ZSH_MODULE = ROOT / "dot_config/zsh/ghostty-command-pulse.zsh"

OSC_SET = re.compile(rb"\x1b\]4;254;#17e7([0-9a-f]{2})\x1b\\")
OSC_RESET = b"\x1b]104;254\x1b\\"
TOKEN = re.compile(rb"\x1b\]4;254;#17e7[0-9a-f]{2}\x1b\\|\x1b\]104;254\x1b\\")


def amplitudes(data: bytes) -> list[int]:
    return [int(m.group(1), 16) for m in OSC_SET.finditer(data)]


def increases(values: list[int]) -> int:
    return sum(1 for a, b in zip(values, values[1:]) if b > a)


@unittest.skipUnless(shutil.which("zsh"), "zsh not installed")
class PulseCommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.tty = self.tmp / "tty"
        self.tty.touch()
        self.env = {**os.environ, "XDG_RUNTIME_DIR": str(self.tmp / "run")}
        (self.tmp / "run").mkdir()

    def run_pulse(self, *args: str, **kwargs) -> subprocess.CompletedProcess:
        return subprocess.run(["zsh", str(PULSE), *args], env=kwargs.pop("env", self.env),
                              capture_output=True, timeout=10, **kwargs)

    def wait_for_reset(self, timeout: float = 3.0) -> bytes:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            data = self.tty.read_bytes()
            if data.endswith(OSC_RESET):
                return data
            time.sleep(0.02)
        return self.tty.read_bytes()

    def test_envelope_starts_bright_fades_out_and_restores_the_entry(self):
        started = time.monotonic()
        result = self.run_pulse(str(self.tty))
        elapsed = time.monotonic() - started
        data = self.tty.read_bytes()

        self.assertEqual(result.returncode, 0)
        values = amplitudes(data)
        self.assertEqual(len(values), 33)
        self.assertEqual(values[0], 0xFF)
        self.assertEqual(values[-1], 0x00)
        self.assertEqual(increases(values), 0, "brightness must only fall")
        self.assertTrue(data.endswith(OSC_RESET))
        self.assertEqual(data.count(OSC_RESET), 1)
        self.assertEqual(b"".join(TOKEN.findall(data)), data, "only protocol bytes are written")
        self.assertGreater(elapsed, 0.25, "envelope is a ~320 ms animation, not a burst")

    def test_newer_pulse_supersedes_older_without_interleaving(self):
        first = subprocess.Popen(["zsh", str(PULSE), str(self.tty)], env=self.env)
        time.sleep(0.12)
        second = subprocess.Popen(["zsh", str(PULSE), str(self.tty)], env=self.env)
        self.assertEqual(first.wait(timeout=5), 0)
        self.assertEqual(second.wait(timeout=5), 0)
        data = self.tty.read_bytes()

        values = amplitudes(data)
        # Exactly one restart (the second pulse's bright start); interleaved
        # envelopes would oscillate many times.
        self.assertEqual(increases(values), 1)
        # Only the surviving pulse restores the entry, and it does so last.
        self.assertEqual(data.count(OSC_RESET), 1)
        self.assertTrue(data.endswith(OSC_RESET))
        # The second pulse plays its complete envelope.
        restart = next(i for i, (a, b) in enumerate(zip(values, values[1:])) if b > a) + 1
        self.assertEqual(len(values) - restart, 33)

    def test_hook_returns_without_waiting_for_the_envelope(self):
        env = {**self.env, "GHOSTTY_AGENT_TTY": str(self.tty)}
        payload = b'{"prompt": "' + b"x" * 1_000_000 + b'"}'
        started = time.monotonic()
        result = self.run_pulse("--hook", env=env, input=payload)
        elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 0)
        self.assertEqual((result.stdout, result.stderr), (b"", b""))
        self.assertLess(elapsed, 0.25, "a hook must not block its agent for the envelope")

    def run_agent_in_pty(self, nested: bool) -> bytes:
        """Run the hook from a stand-in agent that owns a real terminal.

        The pty child is a session leader in the terminal's foreground group,
        like an agent launched from the prompt. With nested=True it fires the
        hook from a grandchild in its own session, as `claude -p` run from
        Claude's Bash tool does.
        """
        pid, master = pty.fork()
        if pid == 0:
            try:
                env = {**self.env, "GHOSTTY_AGENT_TTY": os.ttyname(0)}
                hook = ["zsh", str(PULSE), "--hook"]
                quiet = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, env=env)
                if nested:
                    relay = "import subprocess,sys; subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL)"
                    subprocess.run([sys.executable, "-c", relay, *hook],
                                   start_new_session=True, **quiet)
                else:
                    subprocess.run(hook, **quiet)
                time.sleep(0.8)  # stay in the foreground while the pulse plays
            finally:
                os._exit(0)
        output = b""
        while True:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
        os.waitpid(pid, 0)
        os.close(master)
        return output

    def test_hook_from_foreground_agent_flashes_its_terminal(self):
        data = self.run_agent_in_pty(nested=False)
        self.assertEqual(len(amplitudes(data)), 33)
        self.assertTrue(data.endswith(OSC_RESET))

    def test_hook_from_nested_agent_does_not_flash_parent_terminal(self):
        data = self.run_agent_in_pty(nested=True)
        self.assertEqual(amplitudes(data), [])
        self.assertNotIn(OSC_RESET, data)

    def test_interrupted_pulse_still_restores_the_entry(self):
        proc = subprocess.Popen(["zsh", str(PULSE), str(self.tty)], env=self.env)
        time.sleep(0.1)
        proc.terminate()
        proc.wait(timeout=5)
        data = self.tty.read_bytes()
        self.assertGreater(len(amplitudes(data)), 0)
        self.assertTrue(data.endswith(OSC_RESET), "a killed pulse must not leave the window tinted")

    def test_unreadable_owner_record_still_restores_the_entry(self):
        owner = self.tmp / "run" / ("ghostty-pulse." + re.sub(r"[^A-Za-z0-9]", "_", str(self.tty)))
        owner.mkdir()
        result = self.run_pulse(str(self.tty))
        data = self.tty.read_bytes()
        self.assertEqual(result.returncode, 0)
        self.assertTrue(data == b"" or data.endswith(OSC_RESET))

    def test_hook_outside_ghostty_wrapper_is_a_silent_no_op(self):
        env = {k: v for k, v in self.env.items() if k != "GHOSTTY_AGENT_TTY"}
        result = self.run_pulse("--hook", env=env, input=b"{}")
        time.sleep(0.4)
        self.assertEqual(result.returncode, 0)
        self.assertEqual((result.stdout, result.stderr), (b"", b""))
        self.assertEqual(self.tty.read_bytes(), b"")

    def test_unwritable_terminal_is_ignored(self):
        result = self.run_pulse(str(self.tmp / "missing-dir" / "tty"))
        self.assertEqual(result.returncode, 0)
        self.assertEqual((result.stdout, result.stderr), (b"", b""))

    def test_missing_argument_is_a_usage_error(self):
        result = self.run_pulse()
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"usage", result.stderr)


@unittest.skipUnless(shutil.which("zsh"), "zsh not installed")
class ZleTriggerTest(unittest.TestCase):
    """Drive an interactive zsh through zpty and record when the pulse fires."""

    def fired_count(self, keystrokes: list[str]) -> tuple[int, list[str]]:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        fired = tmp / "fired"
        finish_log = tmp / "user-finish"
        fake = tmp / "ghostty-pulse"
        fake.write_text(f'#!/bin/sh\necho "$1" >> {fired}\n')
        fake.chmod(0o755)

        # Mirrors .zshrc: the module is sourced first, then .zshrc defines its
        # own zle-line-finish with `zle -N`, which must keep working too.
        rc = textwrap.dedent(f"""
            autoload -Uz add-zsh-hook
            source {ZSH_MODULE}
            __GHOSTTY_COMMAND_PULSE_BIN={fake}
            function zle-line-finish() {{ print -r -- finished >> {finish_log} }}
            zle -N zle-line-finish
            PS1='%% '
        """)
        (tmp / ".zshrc").write_text(rc)
        writes = "\n".join(f"zpty -w -n t {k}; sleep 0.25" for k in keystrokes)
        driver = textwrap.dedent(f"""
            zmodload zsh/zpty
            zpty -b t 'ZDOTDIR={tmp} zsh -i'
            sleep 0.6
        """) + writes + "\nsleep 0.3\nzpty -d t\n"
        subprocess.run(["zsh", "-f"], input=driver.encode(), timeout=30,
                       env={**os.environ, "ZDOTDIR": str(tmp)}, capture_output=True)
        count = len(fired.read_text().splitlines()) if fired.exists() else 0
        user = finish_log.read_text().splitlines() if finish_log.exists() else []
        return count, user

    def test_fires_on_every_enter_including_empty_lines(self):
        count, user_finish = self.fired_count(["$'echo hi\\r'", "$'\\r'", "$'\\r'"])
        self.assertEqual(count, 3)
        self.assertEqual(len(user_finish), 3, ".zshrc's own zle-line-finish still runs")

    def test_does_not_fire_on_ctrl_c(self):
        count, _ = self.fired_count(["$'partial'", "$'\\x03'", "$'more'", "$'\\x03'"])
        self.assertEqual(count, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
