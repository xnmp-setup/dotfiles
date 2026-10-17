"""Exercise the live-message commands against a deterministic app-server peer."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "dot_claude/skills/codex-subagent/scripts"
FAKE_CODEX = r'''#!/usr/bin/env python3
import json, os, sys
messages = []
def emit(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    with open(os.environ['REQUESTS'], 'a') as log:
        log.write(json.dumps(request) + '\n')
    method = request['method']
    if method == 'initialized': continue
    identifier = request['id']
    params = request.get('params', {})
    result = {}
    if method == 'thread/start': result = {'thread': {'id': 'thread-one'}}
    if method == 'turn/start':
        messages.append(params['input'][0]['text'])
        result = {'turn': {'id': 'turn-one'}}
    if method == 'turn/steer':
        text = params['input'][0]['text']
        if text == 'reject':
            emit({'id': identifier, 'error': {'code': -1, 'message': 'steering rejected'}})
            continue
        assert params['threadId'] == 'thread-one'
        assert params['expectedTurnId'] == 'turn-one'
        messages.append(text)
        result = {'turnId': 'turn-one'}
    emit({'id': identifier, 'result': result})
    if method == 'turn/start':
        emit({'method': 'item/completed', 'params': {'threadId': 'thread-one',
              'item': {'type': 'agentMessage', 'phase': 'commentary', 'text': 'working'}}})
    if method == 'turn/steer' and text == 'finish':
        emit({'method': 'item/completed', 'params': {'threadId': 'thread-one',
              'item': {'type': 'agentMessage', 'phase': 'final_answer', 'text': '\n'.join(messages)}}})
        emit({'method': 'turn/completed', 'params': {'threadId': 'thread-one',
              'turn': {'id': 'turn-one', 'status': 'completed'}}})
'''


class LiveMessageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-live test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / "codex"
        self.binary.write_text(FAKE_CODEX)
        self.binary.chmod(0o755)
        self.control = self.root / "control"
        self.output = self.root / "final"
        self.requests = self.root / "requests"
        self.env = {**os.environ, "REQUESTS": str(self.requests)}

    def start(self, wrapper=False):
        if wrapper:
            command = ["bash", str(SCRIPTS / "executable_codex-run.sh"),
                       "-S", str(self.control), "-l", str(self.root / "transcript"),
                       "-m", "test-model", "-e", "high", "-t", "60", "-i", "60", "original"]
            self.env["PATH"] = str(self.root) + os.pathsep + self.env["PATH"]
        else:
            command = [sys.executable, str(SCRIPTS / "codex-live.py"),
                       "--codex", str(self.binary), "--control", str(self.control),
                       "--output", str(self.output), "--workdir", str(self.root),
                       "--sandbox", "read-only", "original"]
        process = subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop, process)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            path = self.control / "session.json"
            if path.exists() and json.loads(path.read_text())["status"] == "active":
                return process
            if process.poll() is not None:
                self.fail(str(process.communicate()))
            time.sleep(.02)
        self.fail("live session did not become ready")

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
        try:
            process.communicate(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()

    def send(self, message):
        return subprocess.run([sys.executable, str(SCRIPTS / "executable_codex-send.py"),
                               str(self.control)], input=message, text=True,
                              capture_output=True, timeout=5)

    def test_wrapper_preserves_context_and_prints_only_final_answer(self):
        process = self.start(wrapper=True)
        reply = self.send('Also check "UTF-8": café\nsecond line')
        self.assertEqual(reply.returncode, 0, reply.stderr)
        self.assertTrue(json.loads(reply.stdout)["accepted"])
        self.assertEqual(self.send("finish").returncode, 0)
        stdout, stderr = process.communicate(timeout=8)
        self.assertEqual(process.returncode, 0, stderr.decode())
        self.assertEqual(stdout.decode(), 'original\nAlso check "UTF-8": café\nsecond line\nfinish\n')
        requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
        starts = [r for r in requests if r['method'] == 'thread/start']
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0]['params']['sandbox'], 'read-only')
        self.assertEqual(starts[0]['params']['approvalPolicy'], 'never')
        self.assertEqual(starts[0]['params']['model'], 'test-model')
        turns = [r for r in requests if r['method'] == 'turn/start']
        self.assertEqual(len(turns), 1)
        self.assertEqual(turns[0]['params']['effort'], 'high')
        self.assertNotEqual(self.send("too late").returncode, 0)

    def test_rejected_empty_and_oversize_messages_do_not_end_session(self):
        process = self.start()
        for message, error in [("reject", "steering rejected"), ("  ", "empty"),
                               ("x" * (1024 * 1024), "1 MiB")]:
            reply = self.send(message)
            self.assertNotEqual(reply.returncode, 0)
            self.assertIn(error, reply.stderr)
            self.assertIsNone(process.poll())
        self.assertEqual(self.send("finish").returncode, 0)
        process.communicate(timeout=5)
        self.assertEqual(self.output.read_text(), "original\nfinish\n")

    def test_control_is_private_and_rejects_wrong_token(self):
        process = self.start()
        self.assertEqual(self.control.stat().st_mode & 0o777, 0o700)
        state = json.loads((self.control / "session.json").read_text())
        with socket.create_connection(("127.0.0.1", state['port']), timeout=2) as client:
            client.sendall(b'{"token":"wrong","message":"finish"}\n')
            reply = json.loads(client.makefile('rb').readline())
        self.assertIn("token", reply['error'])
        self.assertIsNone(process.poll())
        self.assertEqual(self.send("finish").returncode, 0)

    def test_termination_closes_control_and_marks_session_ended(self):
        process = self.start()
        process.terminate()
        process.communicate(timeout=8)
        reply = self.send("too late")
        self.assertNotEqual(reply.returncode, 0)
        self.assertIn("failed", reply.stderr)


if __name__ == "__main__":
    unittest.main()
