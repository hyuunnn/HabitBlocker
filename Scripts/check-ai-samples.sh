#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PYTHON="$HOME/Library/Application Support/com.hyun.habitblocker/runtime/bin/python3"

if [[ -x "$APP_PYTHON" ]]; then
  PYTHON="$APP_PYTHON"
else
  PYTHON="python3"
fi

"$PYTHON" "$ROOT_DIR/Scripts/laya_resident.py" --check
