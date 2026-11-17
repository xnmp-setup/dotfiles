#!/usr/bin/env python3
"""Run the bundled imagegen CLI with an API key read from the system keyring."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys


DEFAULT_MODEL = "gpt-image-2.5-flare"
COMMANDS = {"generate", "generate-batch", "edit"}
CLI_PATH = Path(__file__).with_name("image_gen.py")


def _command_args(args: list[str]) -> list[str]:
    """Set the default model explicitly while preserving caller overrides."""
    if not args or args[0] not in COMMANDS:
        return args
    if any(arg == "--model" or arg.startswith("--model=") for arg in args[1:]):
        return args
    return [args[0], "--model", DEFAULT_MODEL, *args[1:]]


def _run_cli(args: list[str], *, env: dict[str, str] | None = None) -> int:
    try:
        return subprocess.run(
            [sys.executable, str(CLI_PATH), *_command_args(args)],
            env=env,
            check=False,
        ).returncode
    except OSError as error:
        print(f"Could not start imagegen CLI: {error}", file=sys.stderr)
        return 1


def main(args: list[str] | None = None) -> int:
    cli_args = list(sys.argv[1:] if args is None else args)
    if not cli_args or cli_args[0] in {"-h", "--help"}:
        print(
            "Usage: generate_with_keyring.py "
            "{generate|generate-batch|edit} [image_gen.py options]\n"
            "Reads service=openai from the system keyring for live API calls."
        )
        return 0 if cli_args else 2

    if not CLI_PATH.is_file():
        print(f"Bundled imagegen CLI is missing: {CLI_PATH}", file=sys.stderr)
        return 1

    # Dry runs and help requests do not need keyring access or an API key.
    if "--dry-run" in cli_args or any(arg in {"-h", "--help"} for arg in cli_args):
        return _run_cli(cli_args)

    secret_tool = shutil.which("secret-tool")
    if secret_tool is None:
        print(
            "Cannot access the OpenAI keyring item: secret-tool is unavailable.",
            file=sys.stderr,
        )
        return 1

    try:
        lookup = subprocess.run(
            [secret_tool, "lookup", "service", "openai"],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        print(
            "Could not retrieve the OpenAI keyring item (service=openai). "
            "Check that the keyring is available and unlocked.",
            file=sys.stderr,
        )
        return 1

    api_key = lookup.stdout.strip()
    if lookup.returncode != 0 or not api_key:
        print(
            "Could not retrieve the OpenAI keyring item (service=openai). "
            "Check that the item exists and the keyring is unlocked.",
            file=sys.stderr,
        )
        return 1

    child_env = os.environ.copy()
    child_env["OPENAI_API_KEY"] = api_key
    del api_key
    return _run_cli(cli_args, env=child_env)


if __name__ == "__main__":
    raise SystemExit(main())
