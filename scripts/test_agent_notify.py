#!/usr/bin/env python3
"""Behavioral tests for the agent notifier (dot_local/bin/executable_agent-notify).

Run: python3 scripts/test_agent_notify.py

The pure parts are tested through their return values; the command is run as
a subprocess against fake notify-send, hyprctl and agent-session-title on
PATH, and judged only by what those fakes observed.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[1] / "dot_local/bin/executable_agent-notify"


def load_module():
    loader = importlib.machinery.SourceFileLoader("agent_notify", str(SCRIPT))
    spec = importlib.util.spec_from_loader("agent_notify", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["agent_notify"] = module
    loader.exec_module(module)
    return module


an = load_module()
INTERACTIVE = {"CLAUDE_CODE_ENTRYPOINT": "cli"}


class PayloadParsing(unittest.TestCase):
    def test_malformed_and_non_object_payloads_are_empty(self):
        for text in (None, "", "   ", "{", "not json", "[1,2]", "42", '"s"', "null",
                     "[" * 100_000):
            self.assertEqual(an.parse_payload(text), {}, repr(text)[:40])

    def test_claude_stop_uses_the_payload_reply(self):
        event = an.claude_event({
            "hook_event_name": "Stop", "stop_hook_active": False,
            "last_assistant_message": "All done.", "cwd": "/w/repo",
            "session_id": "abc", "transcript_path": "/t.jsonl",
        }, INTERACTIVE)
        self.assertEqual((event.agent, event.kind, event.message, event.cwd, event.session_id),
                         ("claude", "done", "All done.", "/w/repo", "abc"))

    def test_claude_stop_reentry_and_headless_runs_are_silent(self):
        payload = {"hook_event_name": "Stop", "last_assistant_message": "x"}
        self.assertIsNone(an.claude_event({**payload, "stop_hook_active": True}, INTERACTIVE))
        self.assertIsNone(an.claude_event(payload, {"CLAUDE_CODE_ENTRYPOINT": "sdk-cli"}))

    def test_claude_notifications_other_than_permission_are_ignored(self):
        for kind in ("idle_prompt", "auth_success", "elicitation_dialog", None):
            payload = {"hook_event_name": "Notification", "notification_type": kind,
                       "message": "m"}
            self.assertIsNone(an.claude_event(payload, INTERACTIVE), kind)
        event = an.claude_event({"hook_event_name": "Notification",
                                 "notification_type": "permission_prompt",
                                 "message": "Claude needs your permission"}, INTERACTIVE)
        self.assertEqual((event.kind, event.message), ("attention", "Claude needs your permission"))

    def test_claude_missing_or_mistyped_fields_degrade_to_empty(self):
        event = an.claude_event({"hook_event_name": "Stop", "last_assistant_message": 7,
                                 "cwd": ["x"], "session_id": None}, INTERACTIVE)
        self.assertEqual((event.message, event.cwd, event.session_id), ("", "", ""))
        self.assertIsNone(an.claude_event({}, INTERACTIVE))
        self.assertIsNone(an.claude_event({"hook_event_name": "PreToolUse"}, INTERACTIVE))

    def test_codex_turn_complete_and_exclusions(self):
        payload = {"type": "agent-turn-complete", "thread-id": "t1", "cwd": "/w/x",
                   "client": "codex-tui", "last-assistant-message": "Shipped."}
        event = an.codex_event(payload)
        self.assertEqual((event.agent, event.kind, event.message, event.session_id),
                         ("codex", "done", "Shipped.", "t1"))
        self.assertIsNone(an.codex_event({**payload, "client": "codex_exec"}))
        self.assertIsNone(an.codex_event({**payload, "type": "approval-requested"}))
        self.assertIsNone(an.codex_event({}))
        self.assertEqual(an.codex_event({"type": "agent-turn-complete",
                                         "last-assistant-message": None}).message, "")

    def test_huge_fields_are_bounded(self):
        event = an.codex_event({"type": "agent-turn-complete",
                                "last-assistant-message": "word " * 1_000_000})
        self.assertLessEqual(len(event.message), an.RAW_LIMIT)


class MarkdownAndText(unittest.TestCase):
    def test_inline_markup_becomes_its_text(self):
        cases = {
            "**Done** and __bold__": "Done and bold",
            "*em* and _em_": "em and em",
            "~~gone~~ kept": "gone kept",
            "see [the docs](https://x.y/a_(b)) now": "see the docs now",
            "![diagram](img.png) here": "diagram here",
            "[ref link][1]\n\n[1]: https://example.com": "ref link",
            "<https://example.com/a>": "https://example.com/a",
            "run `**kwargs` or `a_b_c`": "run **kwargs or a_b_c",
            "``code with ` tick``": "code with ` tick",
        }
        for source, expected in cases.items():
            self.assertEqual(an.strip_markdown(source), expected, source)

    def test_plain_text_that_looks_like_markup_survives(self):
        for text in ("snake_case_name and __init__py", "2*3*4 = 24", "a * b * c",
                     "cost is $5_000", "C# and F#"):
            self.assertNotEqual(an.strip_markdown(text), "", text)
        self.assertEqual(an.strip_markdown("2*3*4 = 24"), "2*3*4 = 24")
        self.assertEqual(an.strip_markdown("snake_case_name"), "snake_case_name")

    def test_block_structure_flattens_to_one_line(self):
        text = ("# Summary\n\nFixed the bug.\n\n- first item\n- Second item\n"
                "1. numbered\n- [x] task\n\n> quoted\n\n---\n\n```py\nprint(1)\n```\n"
                "| a | b |\n|---|---|\n| 1 | 2 |\n")
        flat = an.strip_markdown(text)
        self.assertNotIn("\n", flat)
        for marker in ("#", "- ", "> ", "```", "---", "[x]", "|"):
            self.assertNotIn(marker, flat)
        self.assertTrue(flat.startswith("Summary · Fixed the bug."), flat)
        for kept in ("first item", "Second item", "numbered", "task", "quoted",
                     "print(1)", "a · b", "1 · 2"):
            self.assertIn(kept, flat)

    def test_terminal_escapes_and_control_characters_are_removed(self):
        self.assertEqual(an.strip_markdown("\x1b[31mred\x1b[0m\x00 \x07bell\r\nnext"),
                         "red bell next")
        # Bidi overrides and C1 controls could reorder or disguise toast text.
        self.assertEqual(an.strip_markdown("safe\u202egnp.exe\u2066x\u2069\x9b"), "safegnp.exex")

    def test_list_items_stay_separate_whatever_their_case(self):
        self.assertEqual(an.strip_markdown("Fixed **it**\n- item one\n- item two"),
                         "Fixed it · item one · item two")
        self.assertEqual(an.strip_markdown("## Notes\nlower case start"), "Notes · lower case start")

    def test_lone_surrogates_do_not_survive_parsing(self):
        event = an.codex_event(an.parse_payload(
            '{"type": "agent-turn-complete", "last-assistant-message": "a\\ud800b"}'))
        event.message.encode("utf-8")  # would raise on a surrogate

    def test_huge_input_is_fast_and_bounded(self):
        started = time.monotonic()
        flat = an.strip_markdown("**x** [a](b) `c` _d_ " * 500_000)
        self.assertLess(time.monotonic() - started, 2.0)
        self.assertLessEqual(len(flat), an.RAW_LIMIT)

    def test_truncate_on_word_boundary(self):
        self.assertEqual(an.truncate("short", 160), "short")
        text = "alpha beta gamma delta " * 20
        cut = an.truncate(text, 40)
        self.assertLessEqual(len(cut), 40)
        self.assertTrue(cut.endswith("…"))
        self.assertTrue(text.startswith(cut[:-1]))
        self.assertEqual(text[len(cut) - 1], " ")  # ends on a whole word
        self.assertEqual(an.truncate("x" * 500, 20), "x" * 19 + "…")
        self.assertEqual(an.truncate("anything", 0), "")
        self.assertEqual(an.truncate("one two, three", 9), "one two…")

    def test_pango_special_characters_are_escaped(self):
        self.assertEqual(an.pango_escape("<b>&'\"</b>"),
                         "&lt;b&gt;&amp;&apos;&quot;&lt;/b&gt;")

    def test_session_label_prefers_saved_title(self):
        self.assertEqual(an.session_label("  My  task ", "/w/repo"), "My task")
        self.assertEqual(an.session_label("", "/w/repo/"), "repo")
        self.assertEqual(an.session_label("", ""), "")
        self.assertEqual(an.session_label("", "/"), "")


class TranscriptReading(unittest.TestCase):
    def call(self, block_id, name, **args):
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": block_id, "name": name, "input": args}]}}

    def result(self, block_id):
        return {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": block_id}]}}

    def test_permission_detail_is_the_unanswered_tool_call(self):
        records = [self.call("1", "Bash", command="ls"), self.result("1"),
                   self.call("2", "Bash", command="git push origin main",
                             description="Push"),
                   {"type": "assistant", "message": {"content": "plain string"}}, {}]
        event = an.Event(agent="claude", kind="attention", message="Claude needs your permission")
        self.assertEqual(an.message_text(event, records), "Bash: git push origin main")

    def test_ambiguous_permission_subjects_fall_back(self):
        event = an.Event(agent="claude", kind="attention", message="Claude needs your permission")
        parallel = [self.call("1", "Bash", command="a"), self.call("2", "Bash", command="b")]
        subagent = [self.call("1", "Agent", prompt="Investigate the bug")]
        self.assertEqual(an.message_text(event, parallel), "Claude needs your permission")
        self.assertEqual(an.message_text(event, subagent), "Claude needs your permission")

    def test_permission_detail_falls_back_to_the_payload_message(self):
        event = an.Event(agent="claude", kind="attention", message="Claude  needs\nyour permission")
        self.assertEqual(an.message_text(event, []), "Claude needs your permission")
        answered = [self.call("1", "Bash", command="ls"), self.result("1")]
        self.assertEqual(an.message_text(event, answered), "Claude needs your permission")

    def test_tool_descriptions(self):
        describe = an.describe_tool_use
        self.assertEqual(describe({"name": "Edit", "input": {"file_path": "/a/b.py", "old_string": "x"}}),
                         "Edit: /a/b.py")
        self.assertEqual(describe({"name": "WebFetch", "input": {"url": "https://x"}}), "WebFetch: https://x")
        self.assertEqual(describe({"name": "mcp__s__t", "input": {"other": "value"}}), "mcp__s__t: value")
        self.assertEqual(describe({"name": "Tool", "input": {"n": 3}}), "Tool")
        self.assertEqual(describe({"name": "Bash", "input": "junk"}), "Bash")
        self.assertEqual(describe({}), "")

    def test_reply_falls_back_to_last_assistant_text(self):
        records = [
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "old"}]}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "**new** reply"}]}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "9"}]}},
        ]
        event = an.Event(agent="claude", kind="done", message="")
        self.assertEqual(an.message_text(event, records), "new reply")

    def test_transcript_tail_skips_bad_lines_and_missing_files(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "t.jsonl"
            path.write_text("not json\n" + json.dumps(self.call("1", "Bash", command="x")) + "\n[1]\n")
            self.assertEqual(len(an.read_transcript_tail(str(path))), 1)
            self.assertEqual(an.read_transcript_tail(str(Path(folder) / "none")), [])
            self.assertEqual(an.read_transcript_tail(""), [])


class ToastShape(unittest.TestCase):
    def test_toast_fields_and_markup(self):
        event = an.Event(agent="claude", kind="attention", message="")
        toast = an.build_toast(event, "a<b>", "rm -rf 'x' && echo <done>", "/i.svg")
        self.assertEqual((toast.app, toast.summary, toast.urgency, toast.category),
                         ("Claude", "Needs permission", "critical", "agent.attention"))
        self.assertEqual(toast.body, "<i>a&lt;b&gt;</i>\nrm -rf &apos;x&apos; &amp;&amp; echo &lt;done&gt;")

    def test_body_without_session_or_message(self):
        event = an.Event(agent="codex", kind="done", message="")
        self.assertEqual(an.build_toast(event, "", "", "").body, "")
        self.assertEqual(an.build_toast(event, "repo", "", "").body, "<i>repo</i>")
        self.assertEqual(an.build_toast(event, "", "long " * 100, "").body.count("…"), 1)

    def test_window_key_prefers_the_terminal_surface_and_separates_agents(self):
        ghostty = {"GHOSTTY_AGENT_STATE_DIR": "/tmp/g.1", "WEZTERM_PANE": "3"}
        self.assertNotEqual(an.window_key("claude", ghostty, "s"), an.window_key("codex", ghostty, "s"))
        self.assertIn("/tmp/g.1", an.window_key("claude", ghostty, "s"))
        wez = {"WEZTERM_PANE": "3", "WEZTERM_UNIX_SOCKET": "/run/wezterm/gui-sock-9"}
        self.assertEqual(an.window_key("codex", wez, "s"), "codex|wezterm|gui-sock-9|3")
        self.assertEqual(an.window_key("codex", {}, "s"), "codex|session|s")
        self.assertEqual(an.window_key("codex", {}, ""), "")
        self.assertRegex(an.record_filename("claude|ghostty|/tmp/../x y"), r"^[0-9a-f]{32}$")

    def test_terminal_fallback_is_one_plain_osc9_sequence(self):
        toast = an.Toast(app="Codex", summary="Finished", body="<i>repo</i>\nA &amp; &lt;b&gt;",
                         urgency="normal", category="agent.done")
        self.assertEqual(an.terminal_notification(toast),
                         "\x1b]9;Codex · Finished: repo — A & <b>\x07".encode())

    def test_record_needs_the_focused_window_to_host_the_hook(self):
        self.assertTrue(an.should_record(42, {7, 42}))
        for pid in (None, "42", 0, 1, 99):
            self.assertFalse(an.should_record(pid, {7, 42}), pid)
        self.assertIn(os.getpid(), an.ancestor_pids(os.getpid()))
        self.assertIn(os.getppid(), an.ancestor_pids(os.getpid()))

    def test_codex_mark_follows_theme_mode(self):
        self.assertEqual(an.codex_mark("light"), "openai-dark.svg")
        self.assertEqual(an.codex_mark("dark"), "openai.svg")
        self.assertEqual(an.codex_mark("unknown"), "openai.svg")


FAKE_NOTIFY_SEND = """#!/bin/sh
printf '%s\\0' "$@" >> "$FAKE_LOG/notify-send"
printf '\\n' >> "$FAKE_LOG/notify-send"
case " $* " in *--action=*) printf '%s\\n' "${FAKE_ACTION:-}";; esac
"""
FAKE_HYPRCTL = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_LOG/hyprctl"
case "$*" in
  "-j activewindow") [ -n "$FAKE_HANG" ] && sleep "$FAKE_HANG"
                     printf '{"address":"%s","pid":%s}\\n' "$FAKE_ACTIVE" "$FAKE_PID" ;;
  "-j clients") printf '[{"address":"%s"},{"address":"%s"}]\\n' "$FAKE_ACTIVE" "$FAKE_OTHER" ;;
  dispatch*) echo ok ;;
esac
"""
FAKE_TITLE = """#!/bin/sh
[ "$2" = "titled-session" ] && echo "Saved title"
"""


class CommandBehaviour(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.bin, self.log, self.run_dir = root / "bin", root / "log", root / "run"
        for folder in (self.bin, self.log, self.run_dir):
            folder.mkdir()
        # PATH is only the fakes; the ones that stall need a real sleep.
        (self.bin / "sleep").symlink_to(shutil.which("sleep"))
        self.data, self.state = root / "data", root / "state"
        assets = self.data / "quickshell-statusbar/quickshell/assets"
        assets.mkdir(parents=True)
        for name in ("claude.svg", "openai.svg", "openai-dark.svg"):
            (assets / name).write_text("<svg/>")
        (self.state / "desktop-theme").mkdir(parents=True)
        (self.state / "desktop-theme/current.json").write_text('{"mode": "light"}')
        self.env = {
            "PATH": str(self.bin), "HOME": str(root), "FAKE_LOG": str(self.log),
            "XDG_RUNTIME_DIR": str(self.run_dir), "XDG_DATA_HOME": str(self.data),
            "XDG_STATE_HOME": str(self.state), "HYPRLAND_INSTANCE_SIGNATURE": "test",
            "FAKE_ACTIVE": "0xactive", "FAKE_OTHER": "0xother",
            # The test runner is an ancestor of every command it runs, so it
            # stands in for the terminal the agent lives in.
            "FAKE_PID": str(os.getpid()),
            "CLAUDE_CODE_ENTRYPOINT": "cli", "GHOSTTY_AGENT_STATE_DIR": "/tmp/ghostty-agent-state.T",
        }

    def tearDown(self):
        self.tmp.cleanup()

    def install(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def run_cli(self, *args, stdin="", env=None):
        return subprocess.run([sys.executable, str(SCRIPT), *args], input=stdin, text=True,
                              capture_output=True, env={**self.env, **(env or {})}, timeout=30)

    def sent(self, wait=0.0):
        deadline = time.monotonic() + wait
        path = self.log / "notify-send"
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        time.sleep(0.1 if wait else 0)
        if not path.exists():
            return []
        # One call per record: each argument NUL-terminated, then a newline.
        return [record.split("\0") for record in path.read_text().split("\0\n") if record]

    def deliver(self, env=None, **fields):
        event = {"agent": "claude", "kind": "done", "message": "Done.", "cwd": "/w/repo",
                 "session_id": "sid", "window_key": "claude|ghostty|/tmp/ghostty-agent-state.T"}
        return self.run_cli("_deliver", json.dumps({**event, **fields}), env=env)

    def record(self, agent="claude", env=None):
        return self.run_cli("record", agent, stdin='{"session_id": "sid"}', env=env)

    def test_garbage_never_fails_the_hook(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        for args, stdin in ((["claude"], "{{{"), (["claude"], ""), (["codex"], ""),
                            (["codex", "[]"], ""), (["record"], "x"), (["_deliver", "{}"], ""),
                            (["bogus"], ""), ([], "")):
            done = self.run_cli(*args, stdin=stdin)
            self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""), args)
        self.assertEqual(self.sent(wait=0.5), [])

    def test_missing_tools_are_a_quiet_no_op(self):
        done = self.deliver()
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertEqual(self.record().returncode, 0)
        self.assertEqual(list(self.run_dir.iterdir()), [])

    def test_hook_entry_point_delivers_in_the_background(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        self.install("agent-session-title", FAKE_TITLE)
        payload = {"hook_event_name": "Stop", "stop_hook_active": False,
                   "session_id": "titled-session", "cwd": "/w/repo",
                   "last_assistant_message": "## Done\nShipped **v2** — see [notes](https://x)."}
        done = self.run_cli("claude", stdin=json.dumps(payload))
        self.assertEqual(done.returncode, 0)
        [argv] = self.sent(wait=5)
        self.assertIn("--app-name=Claude", argv)
        self.assertIn("--urgency=normal", argv)
        self.assertIn("--category=agent.done", argv)
        self.assertIn(f"--icon={self.data}/quickshell-statusbar/quickshell/assets/claude.svg", argv)
        self.assertEqual(argv[-2:], ["Finished", "<i>Saved title</i>\nDone · Shipped v2 — see notes."])
        self.assertNotIn("--wait", argv)  # no recorded window, nothing to focus

    def test_codex_entry_point_uses_theme_matched_mark(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        payload = {"type": "agent-turn-complete", "thread-id": "t", "cwd": "/w/proj",
                   "client": "codex-tui", "last-assistant-message": "Ok & <done>"}
        self.run_cli("codex", json.dumps(payload))
        [argv] = self.sent(wait=5)
        self.assertIn("--app-name=Codex", argv)
        self.assertTrue(any(a.endswith("/openai-dark.svg") for a in argv), argv)
        self.assertEqual(argv[-1], "<i>proj</i>\nOk &amp; &lt;done&gt;")

    def test_missing_icon_sends_without_one(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        (self.data / "quickshell-statusbar/quickshell/assets/claude.svg").unlink()
        self.deliver()
        [argv] = self.sent()
        self.assertFalse(any(a.startswith("--icon") for a in argv))

    def test_record_then_click_focuses_the_recorded_window(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        self.install("hyprctl", FAKE_HYPRCTL)
        self.record(env={"FAKE_ACTIVE": "0xother"})  # the prompt was typed there
        [record] = list((self.run_dir / "agent-notify").iterdir())
        self.assertEqual(stat.S_IMODE(record.stat().st_mode), 0o600)
        self.deliver(env={"FAKE_ACTION": "default"})
        [argv] = self.sent()
        self.assertIn("--action=default=Focus", argv)
        self.assertIn("--wait", argv)
        dispatches = [l for l in (self.log / "hyprctl").read_text().splitlines() if l.startswith("dispatch")]
        self.assertEqual(dispatches, ['dispatch hl.dsp.focus({ window = "address:0xother" })'])

    def test_no_toast_while_the_recorded_window_is_focused(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        self.install("hyprctl", FAKE_HYPRCTL)
        self.record()  # recorded 0xactive, which is still active
        self.deliver()
        self.assertEqual(self.sent(), [])

    def test_closed_window_gives_a_plain_toast(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        self.install("hyprctl", FAKE_HYPRCTL)
        self.record(env={"FAKE_ACTIVE": "0xgone"})
        self.deliver()
        [argv] = self.sent()
        self.assertNotIn("--wait", argv)

    def test_prompts_not_typed_in_the_terminal_keep_the_old_record(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        self.install("hyprctl", FAKE_HYPRCTL)
        self.record(env={"FAKE_ACTIVE": "0xother"})
        # A loop wakeup while a browser (not our ancestor) is focused...
        self.record(env={"FAKE_ACTIVE": "0xbrowser", "FAKE_PID": "999999999"})
        # ...and an injected prompt while the terminal is focused.
        self.run_cli("record", "claude", stdin='{"session_id": "sid", "source": "loop_wakeup"}')
        self.deliver(env={"FAKE_ACTION": "default"})
        dispatches = [l for l in (self.log / "hyprctl").read_text().splitlines() if l.startswith("dispatch")]
        self.assertEqual(dispatches, ['dispatch hl.dsp.focus({ window = "address:0xother" })'])

    def test_hook_returns_before_a_slow_notifier(self):
        self.install("notify-send", "#!/bin/sh\nsleep 5\n")
        started = time.monotonic()
        done = self.run_cli("codex", json.dumps({"type": "agent-turn-complete", "last-assistant-message": "x"}))
        self.assertEqual(done.returncode, 0)
        self.assertLess(time.monotonic() - started, 2.0)

    def test_hung_compositor_bounds_record(self):
        self.install("hyprctl", FAKE_HYPRCTL)
        started = time.monotonic()
        done = self.record(env={"FAKE_HANG": "30"})
        self.assertEqual(done.returncode, 0)
        self.assertLess(time.monotonic() - started, an.COMMAND_TIMEOUT_SECONDS + 2)
        self.assertFalse((self.run_dir / "agent-notify").exists())

    def test_osascript_is_used_without_notify_send(self):
        self.install("osascript", "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$FAKE_LOG/osascript\"\n")
        self.deliver(message="A &amp; <b>")
        args = (self.log / "osascript").read_text().split("\0")[:-1]
        self.assertEqual(args[-3:], ["Claude", "Finished", "repo — A &amp; <b>"])

    def test_huge_and_hostile_payloads_still_toast(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        # As large as Codex itself can pass (one argument is capped at 128 KiB).
        emoji = {"type": "agent-turn-complete", "last-assistant-message": "\U0001f600" * 30_000}
        self.run_cli("codex", json.dumps(emoji, ensure_ascii=False))
        [argv] = self.sent(wait=5)
        self.assertTrue(argv[-1].endswith("…"))
        (self.log / "notify-send").unlink()
        surrogate = '{"type": "agent-turn-complete", "last-assistant-message": "bad \\ud800 char"}'
        self.run_cli("codex", surrogate)
        [argv] = self.sent(wait=5)
        self.assertEqual(argv[-1], "bad \ufffd char".replace("\ufffd", "?"))

    def test_huge_stdin_is_drained(self):
        payload = json.dumps({"hook_event_name": "Stop", "last_assistant_message": "x" * (6 << 20)})
        done = self.run_cli("claude", stdin=payload)  # would raise BrokenPipeError if not drained
        self.assertEqual(done.returncode, 0)

    def test_records_are_per_agent_and_skip_headless_runs(self):
        self.install("hyprctl", FAKE_HYPRCTL)
        self.record(env={"CLAUDE_CODE_ENTRYPOINT": "sdk-cli"})
        self.assertFalse((self.run_dir / "agent-notify").exists())
        self.record("claude")
        self.record("codex")
        self.record("nonsense")
        self.assertEqual(len(list((self.run_dir / "agent-notify").iterdir())), 2)

    def test_permission_toast_reads_the_pending_tool_from_the_transcript(self):
        self.install("notify-send", FAKE_NOTIFY_SEND)
        transcript = Path(self.tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "1", "name": "Bash",
             "input": {"command": "git push origin feat/x"}}]}}) + "\n")
        payload = {"hook_event_name": "Notification", "notification_type": "permission_prompt",
                   "message": "Claude needs your permission", "cwd": "/w/keifu",
                   "transcript_path": str(transcript)}
        self.run_cli("claude", stdin=json.dumps(payload))
        [argv] = self.sent(wait=5)
        self.assertIn("--urgency=critical", argv)
        self.assertIn("--category=agent.attention", argv)
        self.assertEqual(argv[-2:], ["Needs permission", "<i>keifu</i>\nBash: git push origin feat/x"])


if __name__ == "__main__":
    unittest.main()
