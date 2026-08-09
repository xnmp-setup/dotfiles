"""Tests for the Ghostty shell inventory used by Hyprland session restore.

Run: python3 -m unittest scripts/test_hypr_session_shells.py

Every test builds a fake /proc on disk rather than mocking the reader, so the
stat parsing, the symlink read and the traversal are all exercised together.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

_MODULE_PATH = (
    Path(__file__).resolve().parent.parent
    / "dot_local"
    / "bin"
    / "executable_hypr-session-shells"
)
_SPEC = importlib.util.spec_from_loader(
    "hypr_session_shells",
    importlib.machinery.SourceFileLoader("hypr_session_shells", str(_MODULE_PATH)),
)
shells_module = importlib.util.module_from_spec(_SPEC)
# dataclasses resolves annotations through sys.modules, so the module has to be
# registered before it is executed.
sys.modules["hypr_session_shells"] = shells_module
_SPEC.loader.exec_module(shells_module)


class FakeProc:
    """A directory shaped like /proc, one entry per process."""

    def __init__(self, root: Path) -> None:
        self.root = root

    def add(
        self,
        pid: int,
        comm: str,
        *,
        ppid: int = 1,
        pgrp: int | None = None,
        tty_nr: int = 34816,
        tpgid: int | None = None,
        cwd: str | None = None,
        cmdline: tuple[str, ...] = (),
        exe: str | None = None,
    ) -> None:
        pgrp = pid if pgrp is None else pgrp
        tpgid = pgrp if tpgid is None else tpgid
        entry = self.root / str(pid)
        entry.mkdir(parents=True, exist_ok=True)
        # Fields after the comm: state, ppid, pgrp, session, tty_nr, tpgid, then
        # filler so the real field offsets hold.
        tail = " ".join(str(value) for value in (ppid, pgrp, pgrp, tty_nr, tpgid))
        (entry / "stat").write_text(f"{pid} ({comm}) S {tail} " + " ".join("0" for _ in range(20)))
        (entry / "cmdline").write_bytes(b"".join(part.encode() + b"\0" for part in cmdline))
        if cwd is not None:
            target = self.root / "cwd-targets" / str(pid)
            target.mkdir(parents=True, exist_ok=True)
            os.symlink(cwd, entry / "cwd")
        if exe is not None:
            os.symlink(exe, entry / "exe")

    def collect(self):
        return shells_module.collect_shells(str(self.root))


class ProcFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.proc = FakeProc(Path(self._tmp.name))


class StatParsing(unittest.TestCase):
    def test_reads_the_fields_the_traversal_needs(self):
        stat = shells_module.parse_stat("7327 (zsh) S 5154 7327 7327 34816 8349 " + "0 " * 10)
        self.assertEqual(stat.pid, 7327)
        self.assertEqual(stat.comm, "zsh")
        self.assertEqual(stat.ppid, 5154)
        self.assertEqual(stat.pgrp, 7327)
        self.assertEqual(stat.tty_nr, 34816)
        self.assertEqual(stat.tpgid, 8349)

    def test_a_comm_containing_spaces_and_parens_does_not_shift_the_fields(self):
        # Process names are attacker-controlled in the sense that any program
        # can set one; splitting on whitespace from the left corrupts every
        # field after it.
        stat = shells_module.parse_stat("42 (my (weird) name) S 1 42 42 34816 99 " + "0 " * 10)
        self.assertEqual(stat.comm, "my (weird) name")
        self.assertEqual(stat.ppid, 1)
        self.assertEqual(stat.tpgid, 99)

    def test_malformed_input_is_rejected_rather_than_guessed(self):
        for text in ["", "not a stat line", "42 (zsh)", "42 (zsh) S 1 2", "x (zsh) S 1 2 3 4 5 6"]:
            with self.subTest(text=text):
                self.assertIsNone(shells_module.parse_stat(text))


class ForegroundResolution(ProcFixture):
    def test_a_shell_at_a_prompt_reports_no_command(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong")
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "")

    def test_the_foreground_group_leader_wins_over_the_deepest_descendant(self):
        # The tree that defeats a depth-first walk: `codex resume` is what the
        # user sees, but the deepest process is a test server the agent spawned.
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong/repo", tpgid=300)
        self.proc.add(300, "node", ppid=200, pgrp=300, cmdline=("node", "codex", "resume"))
        self.proc.add(400, "codex", ppid=300, pgrp=300, cmdline=("codex",))
        self.proc.add(500, "npm", ppid=400, pgrp=500, cmdline=("npm", "run", "test:e2e"))
        self.proc.add(600, "node", ppid=500, pgrp=500, cmdline=("node", "test-server.ts"))
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "cxr")

    def test_the_codex_node_launcher_uses_the_resume_alias(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong/repo", tpgid=300)
        self.proc.add(
            300,
            "node",
            ppid=200,
            pgrp=300,
            cmdline=(
                "node",
                "/home/chong/.nvm/versions/node/v25.6.0/bin/codex",
                "-c",
                "tui.terminal_title=[]",
            ),
        )
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "cxr")

    def test_codex_arguments_are_replaced_by_the_resume_alias(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong/repo", tpgid=300)
        self.proc.add(
            300,
            "node",
            ppid=200,
            pgrp=300,
            cmdline=(
                "/home/chong/.nvm/versions/node/v25.6.0/bin/node",
                "/home/chong/.nvm/versions/node/v25.6.0/bin/codex",
                "-c",
                "tui.terminal_title=[]",
                "resume",
                "thread-id",
            ),
        )
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "cxr")

    def test_a_native_claude_command_is_replaced_by_the_resume_alias(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong/repo", tpgid=300)
        self.proc.add(
            300,
            "claude",
            ppid=200,
            pgrp=300,
            cmdline=(
                "/home/chong/.local/bin/claude",
                "--permission-mode",
                "auto",
                "--model",
                "fable",
            ),
        )
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "ccr")

    def test_a_node_launched_claude_command_uses_the_same_resume_alias(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong/repo", tpgid=300)
        self.proc.add(
            300,
            "node",
            ppid=200,
            pgrp=300,
            cmdline=(
                "node",
                "/home/chong/.nvm/versions/node/v25.6.0/bin/claude",
                "--resume",
            ),
        )
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "ccr")

    def test_codex_override_text_is_not_removed_from_an_unrelated_command(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong/repo", tpgid=300)
        self.proc.add(
            300,
            "node",
            ppid=200,
            pgrp=300,
            cmdline=("node", "-c", "tui.terminal_title=[]"),
        )
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "node -c tui.terminal_title=[]")

    def test_background_helper_shells_are_not_mistaken_for_the_foreground(self):
        # quick-question.zsh parks helpers under every prompt; they are in their
        # own process groups and must not be reported.
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong", tpgid=300)
        self.proc.add(300, "vim", ppid=200, pgrp=300, cmdline=("vim", "notes.md"))
        self.proc.add(310, "zsh", ppid=200, pgrp=310, cmdline=("zsh",))
        self.proc.add(320, "tee", ppid=310, pgrp=310, cmdline=("tee", "--", "/tmp/stderr"))
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "vim notes.md")

    def test_a_group_whose_leader_already_exited_still_resolves(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong", tpgid=300)
        # No pid 300; only a surviving member of group 300.
        self.proc.add(305, "less", ppid=200, pgrp=300, cmdline=("less", "log.txt"))
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "less log.txt")

    def test_a_foreground_group_on_another_terminal_is_ignored(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/home/chong", tty_nr=34816, tpgid=300)
        self.proc.add(305, "less", ppid=200, pgrp=300, tty_nr=34817, cmdline=("less",))
        (shell,) = self.proc.collect()
        self.assertEqual(shell["command"], "")


class Traversal(ProcFixture):
    def test_every_surface_shell_is_reported_with_its_own_cwd(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        self.proc.add(210, "zsh", ppid=100, cwd="/b")
        self.proc.add(220, "zsh", ppid=100, cwd="/c")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/a", "/b", "/c"])

    def test_shells_under_other_terminals_are_not_collected(self):
        self.proc.add(100, "ghostty")
        self.proc.add(150, "wezterm-gui")
        self.proc.add(200, "zsh", ppid=100, cwd="/ghostty")
        self.proc.add(250, "zsh", ppid=150, cwd="/wezterm")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/ghostty"])

    def test_ghostty_helpers_without_a_terminal_are_not_surfaces(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        self.proc.add(210, "gpu-helper", ppid=100, cwd="/b")
        self.proc.add(220, "zsh", ppid=100, tty_nr=0, cwd="/c")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/a"])

    def test_more_than_one_ghostty_process_is_handled(self):
        # --gtk-single-instance can be off, or a second instance can exist on a
        # different display.
        self.proc.add(100, "ghostty")
        self.proc.add(101, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        self.proc.add(201, "zsh", ppid=101, cwd="/b")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/a", "/b"])

    def test_no_ghostty_means_no_shells(self):
        self.proc.add(200, "zsh", cwd="/a")
        self.assertEqual(self.proc.collect(), [])

    def test_a_shell_that_exited_mid_scan_is_dropped(self):
        # Its cwd symlink is gone, so a restored window would point nowhere.
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd=None)
        self.proc.add(210, "zsh", ppid=100, cwd="/b")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/b"])

    def test_a_deleted_working_directory_is_not_replayed(self):
        # The kernel renders a removed directory as "<path> (deleted)". Handing
        # that to ghostty as --working-directory reopens the window somewhere
        # arbitrary; the shell is better dropped.
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/tmp/gone (deleted)")
        self.proc.add(210, "zsh", ppid=100, cwd="/b")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/b"])

    def test_a_directory_really_named_deleted_survives(self):
        # The suffix is a rendering, not a reserved name: a directory that
        # exists under that name is still a working directory.
        real = Path(self._tmp.name) / "a dir (deleted)"
        real.mkdir()
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd=str(real))
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], [str(real)])

    def test_a_wrapped_ghostty_binary_is_still_ghostty(self):
        # NixOS puts a wrapper shim on PATH and runs `.ghostty-wrapped`, whose
        # 16 characters the kernel truncates to a 15-character comm. Matching on
        # comm alone finds no ghostty and loses every terminal in the session.
        self.proc.add(100, ".ghostty-wrappe", exe="/nix/store/abc/bin/.ghostty-wrapped")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/a"])

    def test_a_truncated_wrapper_comm_is_enough_when_exe_is_unreadable(self):
        # /proc/<pid>/exe is unreadable for a process running as another uid, so
        # on NixOS the only evidence left is the comm the kernel cut at 15
        # characters. Rejecting it loses every terminal in the session.
        self.proc.add(100, ".ghostty-wrappe")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/a"])

    def test_a_short_comm_that_is_merely_a_prefix_is_not_ghostty(self):
        # Only a comm at the truncation limit is ambiguous; a shorter one is a
        # complete name and "ghost" is not ghostty.
        self.proc.add(100, "ghost")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        self.assertEqual(self.proc.collect(), [])

    def test_a_process_whose_exe_is_unreadable_falls_back_to_comm(self):
        # /proc/<pid>/exe needs the same uid and is gone for a process exiting
        # mid-scan, so comm has to remain a usable answer.
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/a"])

    def test_the_exe_name_wins_over_a_misleading_comm(self):
        # A process can set its own comm; what it is executing is the fact.
        self.proc.add(100, "ghostty", exe="/usr/bin/kitty")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        self.assertEqual(self.proc.collect(), [])

    def test_an_unreadable_proc_entry_does_not_abort_the_scan(self):
        self.proc.add(100, "ghostty")
        self.proc.add(200, "zsh", ppid=100, cwd="/a")
        broken = Path(self.proc.root) / "999"
        broken.mkdir()
        (broken / "stat").write_text("garbage")
        self.assertEqual([shell["cwd"] for shell in self.proc.collect()], ["/a"])

    def test_a_missing_proc_yields_nothing(self):
        self.assertEqual(shells_module.collect_shells("/nonexistent-proc"), [])


class LuaRendering(unittest.TestCase):
    """The capture is consumed by `load()`, so Lua is the only judge of it.

    These assert on what Lua reads back rather than on the escaping shape:
    window titles and shell commands are arbitrary text written by other
    programs, and none of it may terminate the literal or smuggle in a second
    statement.
    """

    @staticmethod
    def evaluate(rendered, *expressions):
        import shutil
        import subprocess

        if shutil.which("lua") is None:
            raise unittest.SkipTest("lua is not installed")
        script = (
            "local c = load(io.read('a'))() "
            "print(table.concat({ %s }, '\\t'))" % ", ".join(expressions)
        )
        result = subprocess.run(
            ["lua", "-e", script], input=rendered, capture_output=True, text=True, check=True
        )
        return result.stdout.rstrip("\n").split("\t")

    def count(self, rendered):
        return int(self.evaluate(rendered, "#c")[0])

    def test_an_empty_inventory_is_still_a_valid_lua_chunk(self):
        self.assertEqual(self.count(shells_module.render([])), 0)

    def test_quotes_backslashes_and_control_characters_survive(self):
        nasty = '/tmp/a "b"\\c\nrm -rf /\x01\x7f'
        rendered = shells_module.render([{"pid": 1, "cwd": nasty, "command": ""}])
        # Byte length, because a newline in the value would corrupt a printed
        # comparison — and a truncation or an injected statement changes it.
        (length,) = self.evaluate(rendered, "#c[1].cwd")
        self.assertEqual(int(length), len(nasty.encode()))
        self.assertEqual(self.count(rendered), 1)

    def test_a_digit_after_a_control_escape_is_not_swallowed(self):
        # Unpadded, "\1" followed by "2" would decode as character 12.
        rendered = shells_module.render([{"pid": 1, "cwd": "\x0123", "command": ""}])
        (length,) = self.evaluate(rendered, "#c[1].cwd")
        self.assertEqual(int(length), 3)

    def test_non_ascii_paths_are_emitted_verbatim(self):
        rendered = shells_module.render(
            [{"pid": 1, "cwd": "/home/chong/Документы", "command": ""}]
        )
        self.assertIn("Документы", rendered)
        (value,) = self.evaluate(rendered, "c[1].cwd")
        self.assertEqual(value, "/home/chong/Документы")

    def test_the_inventory_round_trips(self):
        rendered = shells_module.render(
            [
                {"pid": 7, "cwd": '/tmp/a b"c', "command": "echo 'it'\\''s'"},
                {"pid": 8, "cwd": "/x", "command": ""},
            ]
        )
        self.assertEqual(self.count(rendered), 2)
        self.assertEqual(
            self.evaluate(rendered, "c[1].pid", "c[1].cwd", "c[1].command", "c[2].command"),
            ["7", '/tmp/a b"c', "echo 'it'\\''s'", ""],
        )


if __name__ == "__main__":
    unittest.main()
