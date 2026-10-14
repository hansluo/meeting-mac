#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python="${MEETING_FUNASR_PYTHON:-/opt/homebrew/bin/python3.12}"
uv="${MEETING_UV:-$HOME/.local/bin/uv}"
[[ "$(uname -m)" == arm64 ]] || { echo 'FunASR environment currently supports macOS arm64 only.' >&2; exit 1; }
[[ -x "$python" && -x "$uv" ]] || { echo 'Python 3.12 and uv are required.' >&2; exit 1; }
if [[ ! -x .venv/funasr/bin/python ]]; then
  "$uv" venv --python "$python" .venv/funasr
fi
"$uv" pip sync --python .venv/funasr/bin/python --require-hashes Runtime/FunASR/requirements.lock
printf '%s\n' 'Environment installed. No model weights downloaded. Import probe is separate from ASR verification.'
