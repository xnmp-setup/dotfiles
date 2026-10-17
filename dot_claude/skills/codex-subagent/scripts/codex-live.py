#!/usr/bin/env python3
"""Drive a single app-server turn, with authenticated loopback live messages.

Uses only Python's standard library on Linux, macOS and WSL. Codex is an
external, authenticated dependency. The shell wrapper owns timeout enforcement.
"""
import argparse
import asyncio
import contextlib
import json
from pathlib import Path
import secrets
import signal

MESSAGE_LIMIT = 1024 * 1024


class LiveRun:
    def __init__(self, args):
        self.args = args
        self.pending = {}
        self.sequence = 0
        self.thread_id = None
        self.turn_id = None
        self.final = ""
        self.token = secrets.token_hex(32)
        self.finished = asyncio.get_running_loop().create_future()

    def write(self, value):
        self.process.stdin.write((json.dumps(value) + "\n").encode())

    async def rpc(self, method, params):
        self.sequence += 1
        identifier = self.sequence
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        try:
            self.write({"id": identifier, "method": method, "params": params})
            await self.process.stdin.drain()
            return await asyncio.wait_for(future, 30)
        finally:
            self.pending.pop(identifier, None)

    async def read(self):
        try:
            while True:
                line = await self.process.stdout.readline()
                if not line:
                    raise RuntimeError("Codex app-server exited before completing the turn")
                print(line.decode().rstrip(), flush=True)
                event = json.loads(line)
                if "method" not in event:
                    future = self.pending.get(event.get("id"))
                    if future is not None and not future.done():
                        if "error" in event:
                            future.set_exception(RuntimeError(str(event["error"])))
                        else:
                            future.set_result(event["result"])
                    continue
                if "id" in event:
                    # No UI is available for approval, elicitation or tools.
                    # Never auto-approve a server request.
                    self.write({"id": event["id"], "error": {
                        "code": -32601, "message": "Interactive requests are unavailable"}})
                    continue
                params = event.get("params", {})
                if params.get("threadId") != self.thread_id:
                    continue
                method = event["method"]
                if method == "turn/started":
                    self.turn_id = params["turn"]["id"]
                elif method == "item/completed":
                    item = params.get("item", {})
                    if item.get("type") == "agentMessage" and item.get("phase") in (None, "final_answer"):
                        self.final = item.get("text", "")
                elif method == "turn/completed" and not self.finished.done():
                    self.finished.set_result(params["turn"])
        except (OSError, ValueError, RuntimeError) as error:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(error)
            if not self.finished.done():
                self.finished.set_exception(error)

    def persist(self, status):
        data = {"status": status, "port": self.port, "token": self.token,
                "threadId": self.thread_id, "turnId": self.turn_id}
        temporary = self.args.control / "session.tmp"
        with temporary.open("w", encoding="utf-8") as stream:
            json.dump(data, stream)
        temporary.replace(self.args.control / "session.json")

    async def receive(self, reader, writer):
        try:
            request = json.loads(await asyncio.wait_for(reader.readline(), 5))
            token = request.get("token") if isinstance(request, dict) else None
            if not isinstance(token, str) or not secrets.compare_digest(token.encode(), self.token.encode()):
                raise ValueError("Invalid control token")
            message = request.get("message")
            if not isinstance(message, str) or not message.strip():
                raise ValueError("Message must not be empty")
            if self.finished.done() or self.turn_id is None:
                raise RuntimeError("No active turn; live messages require a running -S session")
            result = await self.rpc("turn/steer", {
                "threadId": self.thread_id, "expectedTurnId": self.turn_id,
                "input": [{"type": "text", "text": message}]})
            reply = {"accepted": True, "turnId": result["turnId"]}
        except (OSError, ValueError, RuntimeError, asyncio.TimeoutError) as error:
            reply = {"error": str(error) or "Timed out; delivery is unknown. Do not automatically resend."}
        try:
            writer.write((json.dumps(reply) + "\n").encode())
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    async def run(self):
        # Refuse reuse, including symlinks. The token stays inside this directory.
        self.args.control.mkdir(mode=0o700)
        self.port = None
        self.persist("starting")
        command = [self.args.codex, "app-server", "--listen", "stdio://",
                   "-c", 'web_search="live"' if self.args.search else 'web_search="disabled"']
        self.process = await asyncio.create_subprocess_exec(
            *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            limit=16 * MESSAGE_LIMIT)
        reader = asyncio.create_task(self.read())
        server = None
        status = "failed"
        try:
            await self.rpc("initialize", {"clientInfo": {"name": "claude_codex_subagent", "version": "1"}})
            self.write({"method": "initialized"})
            params = {"cwd": str(Path(self.args.workdir).resolve()),
                      "sandbox": self.args.sandbox, "approvalPolicy": "never"}
            if self.args.model:
                params["model"] = self.args.model
            self.thread_id = (await self.rpc("thread/start", params))["thread"]["id"]
            turn_params = {"threadId": self.thread_id,
                           "input": [{"type": "text", "text": self.args.prompt}]}
            if self.args.effort:
                turn_params["effort"] = self.args.effort
            self.turn_id = (await self.rpc("turn/start", turn_params))["turn"]["id"]
            server = await asyncio.start_server(self.receive, "127.0.0.1", 0, limit=MESSAGE_LIMIT)
            self.port = server.sockets[0].getsockname()[1]
            self.persist("active")
            turn = await self.finished
            status = turn["status"]
            if status != "completed":
                raise RuntimeError(f"Codex turn {status}: {turn.get('error')}")
            Path(self.args.output).write_text(self.final + "\n", encoding="utf-8")
        finally:
            if server:
                server.close()
                await server.wait_closed()
            self.persist(status)
            if self.process.returncode is None:
                self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), 5)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()
            reader.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await reader
            # Retrieve any early failure when startup itself raised.
            if self.finished.done() and not self.finished.cancelled():
                self.finished.exception()


async def main(args):
    task = asyncio.current_task()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, task.cancel)
    await LiveRun(args).run()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--sandbox", required=True)
    parser.add_argument("--model")
    parser.add_argument("--effort")
    parser.add_argument("--search", action="store_true")
    parser.add_argument("prompt")
    try:
        asyncio.run(main(parser.parse_args()))
    except (OSError, ValueError, RuntimeError, asyncio.TimeoutError, asyncio.CancelledError) as error:
        parser.exit(1, f"codex-live: {error or 'cancelled'}\n")
