#!/usr/bin/env bash
# Rebuilds the cosmetics icons and the Crown prop (Blender runs through the machine-wide heavy lock) and the sheets.
# Usage (from anywhere): art/blender/cosmetics/run_all.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
RUN=tools/blender-run.sh
S=art/blender/cosmetics/icons.py
"$RUN" "$S" -- CosSpeed CosDoubleJump CosTrailRainbow CosTrailStar CosTrailRookie CosCrown 2>&1 |
	grep -E -i "error|traceback|^ICON" &
"$RUN" "$S" -- CosAura CosAll CosStarter 2>&1 | grep -E -i "error|traceback|^ICON" &
wait
"$RUN" art/blender/cosmetics/prop_Crown.py 2>&1 | grep -E -i "error|traceback|^PROPS_STATS"
python3 art/blender/cosmetics/make_sheet.py
