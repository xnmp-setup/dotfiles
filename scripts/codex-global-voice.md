# Global Codex voice

Cmd/Super+Shift+V (or Ctrl+Alt+V) toggles native voice in the dedicated Global
voice thread. If no owner is running, the helper starts its user service
headlessly. There is no wake detector or automatic idle shutoff.

Run `cxv` in a zsh terminal to open the **same live session** interactively. It attaches
to the existing Zellij terminal instead of resuming another Codex owner, so
reports remain readable and running work and voice continue. Closing this
terminal detaches the viewer; it does not stop the headless session.

Inside the attached terminal, Alt+T opens Codex's transcript view. For Zellij scrollback,
press Ctrl+G then Ctrl+S, use PageUp/PageDown, and press Escape to return to live
output. Ctrl+G then Ctrl+D detaches. Other keys pass directly to Codex.

Commands:

- `codex-global-voice toggle`: toggle voice, starting headlessly if needed.
- `codex-global-voice show`: open the shared session in a Ghostty window.
- `codex-global-voice attach`: attach the current terminal to that shared session.
- `codex-global-voice status`: inspect voice, native owner PID and thread ID.
- `codex-global-voice inspect`: inspect recent terminal output.
- `systemctl --user stop codex-global-voice`: stop the native session and voice.

The saved thread ID is `~/.local/state/codex-global-voice/thread-id`; do not use
`resume --last`. Shared sessions use `codex-global-voice-<thread-id>`. A private
PID/start-time record under `$XDG_RUNTIME_DIR/codex-global-voice/native.json`
identifies the actual Codex pane for microphone ownership checks and prevents
PID reuse from being mistaken for a live owner. The control socket and owner
lock ensure shortcut invocations reuse the same runtime.

The shared display requires Zellij (the installed 0.45.1 supports detached
creation and pane-targeted keys) and the private configuration in
`~/.config/codex-global-voice/zellij.kdl`. It retains 100,000 scrollback lines in
memory without enabling session resurrection. If shared support is absent,
legacy native toggling remains available, but `show` reports that the owner
needs shared support. Install both the helper and its supporting files.

`~/.codex/global-voice/SOUL.md` supplies the session's base instructions;
`VOICE.md` supplies the native voice handoff protocol. Existing Codex
configuration, authentication, audio devices and saved history are retained.
Only the session's voice key is mapped to F8. No keys are sent to other apps.

Apply the helper, supporting files and unit with chezmoi. Run
`systemctl --user daemon-reload` after unit changes. When upgrading an old
unshared owner, restart the service once while idle; future opening/closing of
viewer windows does not require a restart. No enable-at-login step is needed.
