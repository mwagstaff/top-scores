from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

STADIUM_IMAGES_ROOT = Path(__file__).resolve().parent.parent
VENV_ROOT = STADIUM_IMAGES_ROOT / ".venv"
VENV_PYTHON = STADIUM_IMAGES_ROOT / ".venv/bin/python"
REQUIRED_MODULES = ("openai", "PIL", "pydantic", "requests", "yaml", "stadium_images")


def ensure_collector_runtime() -> None:
    """Re-exec a collector command with its project virtual environment."""

    missing = [
        name for name in REQUIRED_MODULES if importlib.util.find_spec(name) is None
    ]
    if not missing:
        return

    if VENV_PYTHON.is_file() and Path(sys.prefix).resolve() != VENV_ROOT.resolve():
        script = Path(sys.argv[0]).resolve()
        os.execv(str(VENV_PYTHON), [str(VENV_PYTHON), str(script), *sys.argv[1:]])

    missing_text = ", ".join(missing)
    raise SystemExit(
        "The stadium image collector environment is not ready "
        f"(missing: {missing_text}).\n"
        "Run:\n"
        f"  cd {STADIUM_IMAGES_ROOT}\n"
        "  python3 -m venv .venv\n"
        "  .venv/bin/python -m pip install -e '.[test]'"
    )
