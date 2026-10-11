#!/usr/bin/env bash
# Provision private dependencies after chezmoi installs the source files.
set -euo pipefail
task_root="$HOME/.local/share/codex-global-wake"
uv venv --allow-existing --python 3.12 "$task_root/venv"
uv pip install --python "$task_root/venv/bin/python" -r "$task_root/requirements.txt"
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
    uv pip install --python "$task_root/venv/bin/python" -r "$task_root/gpu-requirements.txt"
fi
"$task_root/venv/bin/python" - <<'PYTHON'
from pathlib import Path
import shutil
from faster_whisper import WhisperModel
root=Path.home()/'.local/share/codex-global-wake'
WhisperModel('base.en',device='cpu',compute_type='int8',cpu_threads=2,download_root=str(root/'cache'))
snapshot=next((root/'cache/models--Systran--faster-whisper-base.en/snapshots').iterdir())
shutil.copytree(snapshot,root/'model',dirs_exist_ok=True,symlinks=False)
PYTHON
systemctl --user daemon-reload
printf '%s\n' 'Local dependencies ready. Enable with: systemctl --user enable --now codex-global-wake.service'
