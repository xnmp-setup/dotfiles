# Global voice local wake routing

Implementation is opt-in: `CODEX_VOICE_WAKE=1` enables a dedicated private
app-server shared by the existing native TUI and a session-scoped control client.
Without this setting, the existing helper behavior remains unchanged.

The detector uses local Silero VAD and local Whisper base.en ASR. The recognizer
uses the GPU when available, with a CPU fallback, and primes its kernels before
arming capture. The endpoint pause is 800 ms to preserve complete instructions. It retains at most a
12-second utterance in memory. Only a leading spoken “Hey Codex” (including ASR
spellings “codecs” / “code x”) wakes the dedicated thread. Idle non-wake speech
is neither submitted nor saved. It never changes hardware mute/default devices.
Manual-on stays native continuous conversational voice; no automatic timeout.
A wake-origin activation sends the recognized remainder through one structured
`turn/start` request as ordinary text, with one explicit buffered speech delivery, without terminal injection or automatic
retry. Native voice startup happens after the local utterance ends.

A wake-origin session sleeps after 15 seconds of observed inactivity, only when
pending submission, scoped backend turns and realtime items are idle, and fresh
native speaker meters show silence. Local speech VAD resets the input timer. Native protocol has no playback-drained
signal: meter observation is a conservative silence heuristic, NOT a strict
playback-completion guarantee. Missing/stale meters or transport errors inhibit
automatic sleep. Manual toggle still works when automatic sleep is inhibited.

The local detector has a separate systemd service and capture identity; it is not
native “On Air”. False wake detections remain possible. ASR may misrecognize the
instruction; a live voice calibration test is needed to check recognition in the room.

Dependencies (private venv): faster-whisper 1.2.1; websockets 15.0.1; pyte 0.8.2; numpy and
onnxruntime; ffmpeg is not used to recognize microphone audio. The Silero model
is checksum-validated by the vendored detector. The Whisper model stays local.

Install with the dotfiles source, provision the private venv and model, then add
`Environment=CODEX_VOICE_WAKE=1` to a Global voice unit override. Restart the
Global voice unit only when idle. Start `codex-global-wake.service` for live
validation; enable its autostart only after a successful user wake test.

Rollback: stop/disable the wake service, remove that unit override, and restart
Global voice. This restores native-only behavior, without touching the saved
thread, microphone configuration, persona or authentication.

## Verified deployment (2026-10-12 Sydney)

The original thread was held by this active chat. With user approval, completed
history was forked to `01a12b0c-d541-7e81-9c03-f980d2975dba`, the dedicated
Global voice thread. `thread-id.before-wake` preserves the original selection.
The current chat was not terminated during that migration.

Live checks: a real delegated tool ran for over 20 seconds while voice remained
active. Native speech followed completion, followed by automatic idle sleep.
Local GPU ASR recognizes clean synthetic wake instructions and ignores ordinary
sentences. Speaker-to-microphone synthetic tests were unreliable; the user must
check wake recognition with their own voice. No end-to-end latency claim is made.
Meter reading uses a real terminal emulator for cursor-addressed updates. A
private headless resize/refresh probes UI responsiveness; stale data disables
automatic sleep. This is conservative activity monitoring, not a native
playback-drained API.

Use the private venv Python for the wake tests (pyte dependency). Other existing
helper tests use standard Python. No ambient recognition text/audio is logged.

## Work and latency safeguards

Backend work is tracked by turn ID independently of whether voice is listening.
Manual off/on does not forget running work. Backend progress retains ownership
until completion; completed IDs prevent late progress from resurrecting jobs.
Startup seeds current turn metadata without hydrating conversation content.
A completed job starts a fresh 15-second inactivity interval; pending input and
spoken output also inhibit sleep. Unknown transport/meter observations fail
closed by keeping the wake-origin session open.

On this RTX 3070, synthetic recognition warmed to about 0.1 seconds, compared
with about 1.6 seconds on CPU. This is local recognition latency, not end-to-end
reply latency: native WebRTC startup and model response still add time. CUDA
libraries live only in the private venv; no system GPU driver or microphone
settings are changed. GPU requirements are optional for CPU-only machines.

After chezmoi applies the files, run `scripts/setup_codex_global_wake.sh` to
provision private dependencies and the local Whisper model. Then enable the
wake unit. The detector has no hard dependency on the daemon's lifetime: it
reuses an attached owner too, and lock-aware recovery waits for startup rather
than starting a duplicate owner. An attached TUI automatically opts into the
installed private runtime unless `CODEX_VOICE_WAKE=0` is explicitly set.

The Silero model is distributed under the accompanying upstream license and
verified against the checksum in `speech_detector.py`. Whisper weights, cache
and venv are runtime artifacts and are not committed to the dotfiles repository.

## Latency follow-up (2026-10-12)

Wake turns are submitted immediately, before starting native voice. Codex works
while WebRTC connects. Initial wake input is a normal text turn, so the TUI does
not also independently speak it. A bounded reply buffer retains final output
until the owning turn completes and voice is ready, then an event-driven worker
queues one speech delivery. The original request is also supplied as quiet user
context once voice is ready; this does not initiate another execution. Commentary and reasoning are excluded. Ambiguous
acknowledgements are never retried; missing final output inhibits idle sleep.
Manual off cancels unsent speech without discarding running work ownership.
No dormant conversation audio is sent to keep a remote session warm.

The dedicated voice thread defaults to medium reasoning for faster interaction.
`CODEX_VOICE_REASONING_EFFORT=high` restores the previous reasoning budget.
This is a quality/latency tradeoff and changes the dedicated thread's subsequent
turn setting; other threads are unaffected.

Content-free wake-stage logs report backend start/completion, realtime startup,
voice readiness, speech queuing and first speech. The immediate-submit live
trace started backend work at27ms, with voice ready at2.1s. The final short-question test began speaking at3.5s after the wake match and
correctly asked the user how their day was going. Model and speech generation
latency remain, and endpointing/local recognition add time before the match. No near-instant guarantee is
made. A real20-second tool task stayed awake through work and speech, then
slept after15 quiet seconds.
