#!/usr/bin/env bash
# Rebuilds the VFX sprites, the branding art and the sheets.
# Usage (from anywhere): art/blender/vfx/run_all.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
for s in art/blender/vfx/sprites.py art/blender/brand/brand.py; do
	echo "== $s"
	tools/blender-run.sh "$s" 2>&1 | grep -E -i "error|traceback|SPRITE_DONE|BRAND_DONE" || true
done
python3 art/blender/vfx/finish.py
python3 art/blender/brand/finish.py
python3 art/blender/vfx/make_sheet.py
