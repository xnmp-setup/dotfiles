"""Local wake policy and RPC control for one private native voice runtime.

No audio crosses this client. Native speech meters and scoped generation/work
ownership conservatively gate inactivity; unknown observations inhibit sleep.
"""
from __future__ import annotations
import contextlib
from collections import deque
import json
import queue
import re
import threading
import time

class WakeState:
    def __init__(self):
        self.mode = 'off'
        self.pending = set()
        self.turns = set()
        self.finished_turns = set()
        self.items = set()
        self.playing = 0
        self.healthy = False
        self.last_input = time.monotonic()
        self.session_id = None
        self.wake_started = None
        self.reported_stages = set()

    def can_sleep(self, now):
        return (self.mode == 'wake' and self.healthy and not self.pending and
                not self.turns and not self.items and not self.playing and
                now - self.last_input >= 15)

    def report_stage(self, stage):
        if self.wake_started is not None and stage not in self.reported_stages:
            self.reported_stages.add(stage)
            print(f"wake-stage stage={stage} ms={round((time.monotonic()-self.wake_started)*1000)}", flush=True)

    def activity(self):
        self.last_input = time.monotonic()


def instruction(text):
    if not isinstance(text, str) or len(text) > 8192:
        return None
    # Whisper's common transcription spellings of the same spoken phrase.
    match = re.match(r'^[\s\"“”]*h(?:ey|ay)[\s,.!?]*(?:codex|codecs|code\s+x)\b[\s,:.]*((?:[!?-].*)|.*)$', text, re.I | re.S)
    return match[1].strip() if match else None


class Rpc:
    def __init__(self, endpoint):
        from websockets.sync.client import unix_connect
        self.socket = unix_connect(str(endpoint), uri='ws://localhost/', max_size=32*1024*1024)
        self.write_lock = threading.Lock()
        self.pending = {}
        self.counter = 0
        self.events = queue.Queue(maxsize=1024)
        self.closed = False
        self.last_error = None
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.call('initialize', {'clientInfo': {'name':'codex_global_wake','version':'1'},
                               'capabilities': {'experimentalApi':True}})
        self.send({'method':'initialized'})

    def send(self, message):
        data = json.dumps(message, ensure_ascii=False)
        with self.write_lock:
            self.socket.send(data)

    def call(self, method, params, timeout=30):
        with self.write_lock:
            self.counter += 1
            identifier = self.counter
            result = queue.Queue(maxsize=1)
            self.pending[identifier] = result
            try:
                self.socket.send(json.dumps({'id':identifier,'method':method,'params':params}))
            except Exception as error:
                self.pending.pop(identifier, None)
                raise RuntimeError('Voice runtime send failed; request was not retried') from error
        try:
            try:
                reply = result.get(timeout=timeout)
            except queue.Empty as error:
                raise TimeoutError('Voice runtime acknowledgement timed out; request was not retried') from error
            if 'error' in reply:
                raise RuntimeError(str(reply['error']))
            return reply.get('result')
        finally:
            self.pending.pop(identifier, None)

    def read(self):
        try:
            while True:
                message = json.loads(self.socket.recv())
                if 'id' in message and 'method' not in message:
                    target = self.pending.get(message['id'])
                    if target:
                        target.put_nowait(message)
                elif message.get('method') in {'turn/started', 'turn/completed',
                        'thread/realtime/started', 'thread/realtime/item/started',
                        'thread/realtime/item/completed', 'thread/realtime/item/added', 'thread/realtime/error',
                        'thread/realtime/closed'}:
                    self.events.put_nowait(message)
        except Exception as error:
            self.last_error = type(error).__name__
            self.closed = True
            for target in list(self.pending.values()):
                with contextlib.suppress(queue.Full):
                    target.put_nowait({'error':'Voice runtime connection closed'})

    def close(self):
        self.closed = True
        self.socket.close()
        self.reader.join(timeout=1)


class Activity:
    """Session-scoped ownership; unknown observations prohibit automatic sleep."""
    def __init__(self, thread_id):
        self.thread_id = thread_id
        self.lock = threading.RLock()
        self.active_turns = set()
        self.finished_turns = set()
        self.finished_order = deque(maxlen=4096)
        self.realtime_ready = threading.Event()
        self.reset()

    def reset(self):
        # Native work ownership outlives listening mode changes. In particular,
        # manual off/on must not make an already running job invisible.
        with self.lock:
            self.realtime_ready.clear()
            self.state = WakeState()
            self.state.turns = self.active_turns
            self.state.finished_turns = self.finished_turns

    def finish(self, turn_id):
        if turn_id not in self.finished_turns:
            if len(self.finished_order) == self.finished_order.maxlen:
                self.finished_turns.discard(self.finished_order.popleft())
            self.finished_order.append(turn_id)
            self.finished_turns.add(turn_id)
        self.active_turns.discard(turn_id)

    def event(self, event):
        p = event.get('params', {})
        if p.get('threadId') != self.thread_id:
            return
        method = event.get('method')
        if method == 'thread/realtime/started':
            self.realtime_ready.set()
        with self.lock:
            if method == 'turn/started':
                self.state.report_stage('backend_started')
                if p['turn']['id'] not in self.finished_turns:
                    self.active_turns.add(p['turn']['id'])
                self.state.pending.discard('request')
                return
            if method == 'turn/completed':
                self.state.report_stage('backend_completed')
                self.finish(p['turn']['id'])
                self.state.activity()
                return
            if self.state.mode != 'wake': return
            if method == 'thread/realtime/started':
                self.state.session_id = p.get('realtimeSessionId')
                if not self.state.session_id: self.state.healthy = False
            elif method in ('thread/realtime/item/started', 'thread/realtime/item/completed', 'thread/realtime/item/added'):
                item = p['item']
                if self.state.session_id and item.get('realtimeSessionId') != self.state.session_id:
                    return
                if item.get('type') == 'bemItemPromoted':
                    # Backend progress identifies its owning turn. If completion
                    # is not known, conservatively retain that work ownership.
                    turn_id = item['turnId']
                    if turn_id not in self.state.finished_turns:
                        self.state.turns.add(turn_id)
                    self.state.pending.discard('request')
                    return
                if item.get('type') != 'transcriptSegment': return
                if item.get('role') == 'user':
                    self.state.activity()
                elif item.get('role') == 'assistant':
                    if method.endswith('/started'):
                        self.state.report_stage('speech_started')
                        self.state.items.add(item['id'])
                    else:
                        self.state.items.discard(item['id'])
                        self.state.activity()
                    self.state.pending.discard('request')
            elif method in ('thread/realtime/error','thread/realtime/closed'):
                self.state.healthy = False

    def consume(self, rpc, stop):
        while not stop.is_set() and not rpc.closed:
            try: self.event(rpc.events.get(timeout=.2))
            except queue.Empty: pass
            except (KeyError, TypeError, ValueError):
                with self.lock: self.state.healthy = False
        with self.lock: self.state.healthy = False


def meter(text):
    matches = list(re.finditer(r'mic\s+([▁▂▃▄▅▆▇█]+)\s+codex\s+([▁▂▃▄▅▆▇█]+)', text))
    if not matches: return None
    m = matches[-1]
    return (any(c != '▁' for c in m[1]), any(c != '▁' for c in m[2]))

class TerminalMeter:
    """Read the current rendered footer, including cursor-addressed updates."""
    def __init__(self):
        import pyte
        self.screen = pyte.Screen(160, 40)
        self.stream = pyte.ByteStream(self.screen)

    def feed(self, data):
        self.stream.feed(data)
        return meter(' '.join(self.screen.display))

    def resize(self, columns):
        self.screen.resize(lines=40, columns=columns)
