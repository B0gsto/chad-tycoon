#!/usr/bin/env bash
# Rebuilds the whole HUD icon set and its contact sheets.
# Usage (from anywhere): art/blender/icons/run_all.sh [Name ...]
set -euo pipefail
cd "$(dirname "$0")/../../.."
tools/blender-run.sh art/blender/icons/render.py -- "$@" 2>&1 | grep -E -i "error|traceback|CHAD_ICON" || true
python3 art/blender/icons/make_sheet.py
