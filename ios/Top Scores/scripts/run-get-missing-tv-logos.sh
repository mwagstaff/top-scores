#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENV_DIR="$SCRIPT_DIR/.venv"
PY_SCRIPT="$SCRIPT_DIR/get_missing_tv_logos.py"

if [ ! -d "$VENV_DIR" ]; then
  echo "❌ Python venv not found at $VENV_DIR"
  echo "Create it with:"
  echo "  python3 -m venv .venv"
  echo "  source .venv/bin/activate"
  echo "  pip install requests"
  exit 1
fi

echo "==> Activating venv"
source "$VENV_DIR/bin/activate"

echo "==> Running logo fetch script"
python "$PY_SCRIPT"

echo "==> Done"