"""Contracts for the private native terminal and persistent session selection."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import socket
import threading
import tomllib
import unittest
from unittest.mock import patch

HELPER = Path(__file__).parents[1] / "dot_local/bin/executable_codex-global-voice"
loader = importlib.machinery.SourceFileLoader("global_voice", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
voice = importlib.util.module_from_spec(spec)
loader.exec_module(voice)


class GlobalVoiceTests(unittest.TestCase):
    def test_only_owned_running_capture_confirms_voice(self):
        client = {"id": 5, "type": "PipeWire:Interface:Client", "info": {"props": {
            "application.process.binary": "codex-voice-host", "application.process.id": 30}}}
        capture = {"type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {
            "client.id": 5, "media.class": "Stream/Input/Audio"}}}
        parents = {30: 20, 20: 10, 10: 1}
        self.assertTrue(voice.owned_capture([client, capture], 10, parents))
        self.assertFalse(voice.owned_capture([client, capture], 99, parents))
        capture["info"]["state"] = "suspended"
        self.assertFalse(voice.owned_capture([client, capture], 10, parents))
        capture["info"]["state"] = "running"
        capture["info"]["props"]["media.class"] = "Stream/Output/Audio"
        self.assertFalse(voice.owned_capture([client, capture], 10, parents))
        capture["info"]["props"]["media.class"] = "Stream/Input/Audio"
        self.assertFalse(voice.owned_capture([client, capture, None], 10, {30: 20, 20: 30}))

    def test_thread_is_persisted_privately_and_resumed_by_exact_id(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "private/thread-id"
            identifier = "01a1246f-333c-7ce0-a295-390b325296d8"
            voice.persist_thread(state, identifier)
            self.assertEqual(state.read_text().strip(), identifier)
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)
            with patch.object(voice, "persona_arguments", return_value=[]):
                command = voice.tui_command("/bin/codex", Path(directory), state.read_text().strip())
            self.assertEqual(command[-2:], ["resume", identifier])
            with self.assertRaises(ValueError):
                voice.persist_thread(state, "--last")
            self.assertEqual(state.read_text().strip(), identifier)

    def test_voice_launch_sets_base_persona_with_a_quoted_path(self):
        with tempfile.TemporaryDirectory(prefix='voice home "quoted"') as directory:
            home = Path(directory)
            persona = home / ".codex/global-voice"
            persona.mkdir(parents=True)
            (persona / "SOUL.md").write_text('Have opinions.\nJust help. 🌱\n')
            (persona / "VOICE.md").write_text('Delegate execution to the backend.\n')
            with patch.object(voice.Path, "home", return_value=home):
                command = voice.tui_command("/bin/codex", Path("/tmp/inbox"), "thread-id")
        overrides = [tomllib.loads(command[index + 1])
                     for index, argument in enumerate(command) if argument == "-c"]
        config = {key: value for override in overrides for key, value in override.items()}
        self.assertEqual(config["model_instructions_file"], str(home / ".codex/global-voice/SOUL.md"))
        self.assertEqual(config["experimental_realtime_ws_backend_prompt"],
                         'Have opinions.\nJust help. 🌱\n\nDelegate execution to the backend.')
        self.assertEqual(command[-2:], ["resume", "thread-id"])

    def test_missing_or_empty_persona_prevents_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            persona = home / ".codex/global-voice"
            persona.mkdir(parents=True)
            with patch.object(voice.Path, "home", return_value=home):
                with self.assertRaises(FileNotFoundError):
                    voice.tui_command("/bin/codex", Path("/tmp/inbox"), "thread-id")
                (persona / "SOUL.md").write_text('  \n')
                (persona / "VOICE.md").write_text('Delegate execution.')
                with self.assertRaises(RuntimeError):
                    voice.tui_command("/bin/codex", Path("/tmp/inbox"), "thread-id")
                (persona / "SOUL.md").write_text('Have opinions.')
                (persona / "VOICE.md").write_text('  \n')
                with self.assertRaises(RuntimeError):
                    voice.tui_command("/bin/codex", Path("/tmp/inbox"), "thread-id")

    def test_malformed_audio_inventory_and_process_ids_fail_closed(self):
        for malformed in (None, [], "bad", 12):
            inventory = [None,
                         {"id": 5, "type": "PipeWire:Interface:Client", "info": malformed},
                         {"type": "PipeWire:Interface:Node", "info": malformed}]
            self.assertFalse(voice.owned_capture(inventory, 10, {20: 10}))
        capture = {"type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {
            "application.process.binary": "codex-voice-host", "media.class": "Stream/Input/Audio"}}}
        for invalid_pid in (None, "not-a-pid", [], {}, "20.5"):
            capture["info"]["props"]["application.process.id"] = invalid_pid
            self.assertFalse(voice.owned_capture([capture], 10, {20: 10}))

    def test_toggle_requires_native_confirmation_and_reuses_one_process(self):
        # A real terminal child implements the observable native event contract.
        # It receives key bytes through the PTY; the test never mocks os.write.
        program = """
import os,sys,tty
from pathlib import Path
tty.setraw(0)
os.write(1,b'Context 0% used')
active=False
while True:
    data=os.read(0,1024)
    if b'\\x1b[19~' in data:
        active=not active
        Path(sys.argv[1]).write_text('on' if active else 'off')
        os.write(1,b'Voice conversation started' if active else b'Voice conversation ended: requested')
"""
        with tempfile.TemporaryDirectory() as directory:
            outcome = Path(directory) / "microphone"
            outcome.write_text("off")
            terminal = voice.NativeTerminal([sys.executable, "-u", "-c", program, str(outcome)],
                                            lambda: outcome.read_text() == "on")
            try:
                first = terminal.toggle()
                second = terminal.toggle()
                self.assertEqual(first["voice"], "on")
                self.assertEqual(second["voice"], "off")
                self.assertEqual(first["pid"], second["pid"])
                self.assertIsNone(terminal.process.poll())
            finally:
                terminal.close()
            self.assertIsNotNone(terminal.process.poll())

    def test_stale_socket_recovers_and_returns_live_service_status(self):
        with tempfile.TemporaryDirectory() as directory:
            control = Path(directory) / "control.sock"
            stale = socket.socket(socket.AF_UNIX)
            stale.bind(str(control))
            stale.close()  # Simulate a service that died without unlinking.
            requests = []
            threads = []

            def start_service(command, **_):
                requests.append(command)
                control.unlink()
                server = socket.socket(socket.AF_UNIX)
                server.bind(str(control))
                server.listen(1)
                def reply():
                    try:
                        connection, _ = server.accept()
                        with connection:
                            connection.recv(1024)
                            connection.sendall(b'{"voice":"off","ready":true}\n')
                    finally:
                        server.close()
                thread = threading.Thread(target=reply)
                thread.start()
                threads.append(thread)
                return voice.subprocess.CompletedProcess(command, 0)

            with patch.object(voice, "paths", return_value=(control, Path(directory) / "thread-id")), \
                 patch.object(voice.subprocess, "run", side_effect=start_service):
                self.assertEqual(voice.request("status"), {"voice": "off", "ready": True})
            for thread in threads:
                thread.join(timeout=2)
                self.assertFalse(thread.is_alive())
            self.assertEqual(requests, [["systemctl", "--user", "start", "codex-global-voice.service"]])


if __name__ == "__main__":
    unittest.main()
