#!/usr/bin/env bash
# Rebuilds every badge (one Blender run through the machine-wide heavy lock) and the contact sheet.
# Usage (from anywhere): art/blender/badges/run_all.sh [Name ...]
set -euo pipefail
cd "$(dirname "$0")/../../.."
tools/blender-run.sh art/blender/badges/badges.py -- "$@" 2>&1 | grep -E -i "error|traceback|^BADGE" || true
python3 art/blender/badges/compose.py --sheet
