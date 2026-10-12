"""One native terminal, shared between the daemon and visible Zellij clients."""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid


def session_name(thread_id):
    return 'codex-global-voice-' + str(uuid.UUID(thread_id))


def process_identity(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return None if fields[0] == 'Z' else fields[19]
    except (OSError, IndexError): return None


def zellij_environment():
    return {key:value for key,value in os.environ.items()
            if key not in {'ZELLIJ','ZELLIJ_SESSION_NAME','ZELLIJ_PANE_ID','ZELLIJ_SESSION_UUID'}}


class PaneProcess:
    def __init__(self, record):
        self.pid = int(record['pid'])
        self.start = str(record['start'])
    def poll(self):
        return None if process_identity(self.pid) == self.start else 0


class SharedTerminal:
    def __init__(self, command, runtime, thread_id, voice_active,
                 config=None, runner=None):
        self.zellij = shutil.which('zellij')
        if not self.zellij: raise RuntimeError('Global voice requires the installed Zellij terminal workspace')
        self.session = session_name(thread_id)
        self.record = Path(runtime) / 'native.json'
        self.config = Path(config or Path.home()/'.config/codex-global-voice/zellij.kdl')
        runner = Path(runner or Path.home()/'.local/share/codex-global-voice/session_runner.py')
        self.cancelled = threading.Event()
        self.condition = threading.Condition()
        self._ready = False
        self._capture = voice_active
        record = self._record(thread_id)
        if record is None:
            existing = self.run(['action', 'list-panes', '--json'], check=False)
            if existing.returncode == 0:
                raise RuntimeError('Global voice terminal exists without a verified native owner; refusing to replace it')
            subprocess.run([self.zellij, '--config', str(self.config),
                '--layout-string', 'layout { pane; }', 'attach', '--create-background',
                '--close-on-exit', self.session, '--', sys.executable, str(runner),
                str(self.record), thread_id, *command], check=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20, env=zellij_environment())
            deadline = time.monotonic()+30
            while record is None:
                if time.monotonic() >= deadline:
                    self.run(['kill-session', self.session], scoped=False, check=False)
                    raise TimeoutError('Native Global voice pane did not start')
                self.cancelled.wait(.05)
                record = self._record(thread_id)
        self.process = PaneProcess(record)

    def _record(self, thread_id):
        try:
            record = json.loads(self.record.read_text())
            if record['thread'] == thread_id and PaneProcess(record).poll() is None:
                return record
        except (OSError, ValueError, KeyError, TypeError): pass
        return None

    def run(self, args, *, scoped=True, check=True):
        command = [self.zellij, '--config', str(self.config)]
        if scoped: command += ['--session', self.session]
        return subprocess.run([*command, *args], capture_output=True, text=True,
                              timeout=5, check=check, env=zellij_environment())

    @property
    def text(self):
        result = self.run(['action', 'dump-screen', '--pane-id', 'terminal_0', '--full'], check=False)
        return result.stdout if result.returncode == 0 else ''

    @property
    def ready(self):
        if not self._ready:
            result = self.run(['action', 'dump-screen', '--pane-id', 'terminal_0'], check=False)
            self._ready = bool(re.search(r'Context\s+[0-9.]+%\s+used|Ask Codex to do anything', result.stdout))
        return self._ready

    def voice_active(self): return self._capture(self.process.pid)

    def toggle(self):
        deadline=time.monotonic()+30
        while not self.ready:
            if self.process.poll() is not None: raise RuntimeError('Native Global voice terminal exited')
            if self.cancelled.is_set(): raise RuntimeError('Global voice is stopping')
            if time.monotonic()>=deadline: raise TimeoutError('Native Global voice terminal is not ready')
            self.cancelled.wait(.1)
        desired=not self.voice_active()
        self.run(['action','send-keys','--pane-id','terminal_0','F8'])
        deadline=time.monotonic()+20
        while not self.cancelled.is_set():
            if self.process.poll() is not None: raise RuntimeError('Native Global voice terminal exited while toggling')
            if self.voice_active()==desired:
                return {'voice':'on' if desired else 'off','pid':self.process.pid}
            if time.monotonic()>=deadline: raise TimeoutError('Native voice toggle was not confirmed; check microphone and speaker setup')
            self.cancelled.wait(.15)
        raise RuntimeError('Global voice is stopping')

    def close(self):
        self.cancelled.set()
        self.run(['kill-session',self.session], scoped=False,check=False)
        deadline = time.monotonic()+5
        while self.process.poll() is None and time.monotonic()<deadline:
            time.sleep(.05)
        if self.process.poll() is None:
            raise RuntimeError('Global voice owner did not stop; retaining its identity record')
        self.record.unlink(missing_ok=True)


def attach_command(thread_id):
    return ['zellij','--config',str(Path.home()/'.config/codex-global-voice/zellij.kdl'),
            'attach',session_name(thread_id)]
