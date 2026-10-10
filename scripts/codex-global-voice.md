# Global Codex voice

`codex-global-voice toggle` starts the user service on demand and toggles native
Codex voice in its dedicated **Global voice** thread. The background TUI and
thread are reused. The thread ID lives in
`~/.local/state/codex-global-voice/thread-id`; do not use `resume --last` here.

The service uses `~/Documents/Inbox` as its workspace. Override
`CODEX_VOICE_WORKSPACE` in a systemd service override to choose another workspace.
Codex's existing authentication, model, audio device, and approval configuration
remain in effect. This TUI enables Fast mode; only its voice key is remapped to F8.

`~/.codex/global-voice/SOUL.md` supplies this session's base instructions via
`model_instructions_file`, replacing Codex's built-in coding-agent persona.
The helper sets this override for thread creation, background resume, and
interactive attach. Other Codex launches keep their existing base instructions.
Native spoken replies use a separate prompt. The helper injects the same persona
there through `experimental_realtime_ws_backend_prompt`, followed by the native
handoff protocol in `~/.codex/global-voice/VOICE.md` (pinned to Codex 0.162.0).
Keep that protocol compatible when upgrading Codex.
`~/Documents/Inbox/AGENTS.md` adds context for finding relevant personal materials.
Apply these files and the helper with chezmoi, then restart the service after
editing them so Codex reloads the instructions.

Commands:

- `codex-global-voice status`: inspect microphone state and persistent thread ID.
- `codex-global-voice inspect`: show recent terminal output to diagnose setup.
- `codex-global-voice attach`: run from a terminal to stop the background service
  and resume the exact same thread interactively for setup or approvals. Exit
  Codex afterward; the next global toggle resumes the background terminal.
  While attached, the hotkey cannot start a second background TUI.
- `systemctl --user stop codex-global-voice`: stop the private terminal and voice.

Errors and confirmed microphone transitions produce desktop notifications.
The helper confirms only its own native capture streams. It never sends keys
to another terminal, uses another active conversation, or implements its own
voice service. The small recent terminal buffer stays in memory; audio is handled
entirely by the installed Codex CLI.

After applying the helper and unit with chezmoi, run
`systemctl --user daemon-reload`. Bind Command/Super+Shift+V to
`~/.local/bin/codex-global-voice toggle` in Hyprland. No enable-at-login step is
required; the service starts on the first toggle.
