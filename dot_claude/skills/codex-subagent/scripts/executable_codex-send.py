#!/usr/bin/env python3
"""Send additional instructions to a running codex-run.sh -S DIR session."""
import argparse
import json
from pathlib import Path
import socket
import sys


def send(control, message):
    if not message.strip():
        raise ValueError("Message must not be empty")
    payload = {"message": message}
    state = json.loads((control / "session.json").read_text(encoding="utf-8"))
    if state.get("status") != "active":
        raise ValueError(f"Session is {state.get('status', 'unavailable')}; wait for startup or start a new -S session")
    payload["token"] = state["token"]
    encoded = (json.dumps(payload) + "\n").encode()
    if len(encoded) > 1024 * 1024:
        raise ValueError("Encoded message exceeds the 1 MiB limit")
    with socket.create_connection(("127.0.0.1", state["port"]), timeout=35) as connection:
        connection.sendall(encoded)
        with connection.makefile("rb") as stream:
            line = stream.readline(1024 * 1024)
    if not line:
        raise RuntimeError("Session disconnected; delivery is unknown. Do not automatically resend.")
    reply = json.loads(line)
    if "error" in reply:
        raise RuntimeError(reply["error"])
    if reply.get("accepted") is not True:
        raise RuntimeError("Session did not acknowledge the message")
    return reply


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("control", type=Path, help="directory passed to codex-run.sh -S")
    parser.add_argument("message", nargs="?", help="message, or read stdin when omitted")
    args = parser.parse_args()
    try:
        message = args.message if args.message is not None else sys.stdin.read()
        print(json.dumps(send(args.control, message)))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        parser.exit(1, f"codex-send: {error}\n")
