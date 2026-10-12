"""Record the native pane's identity before replacing this process with Codex."""
import json
import os
from pathlib import Path
import sys


def identity(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return fields[19]


def main():
    record, thread, *command = sys.argv[1:]
    if not command: raise SystemExit('Missing native terminal command')
    path = Path(record)
    temporary = path.with_suffix('.tmp')
    descriptor = os.open(temporary, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump({'pid': os.getpid(), 'start': identity(os.getpid()), 'thread': thread}, stream)
    temporary.replace(path)
    os.execvpe(command[0], command, os.environ)


if __name__ == '__main__': main()
