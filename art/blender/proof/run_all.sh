#!/usr/bin/env bash
# Rebuilds the whole proof set: icons, props (FBX + beauty shots) and the contact sheets.
# Usage (from anywhere): art/blender/proof/run_all.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
HEAVY=${HEAVY:-/tmp/claude-studio/heavy.sh}
for s in icon_coin icon_gem icon_orb icon_gift icon_trophy icon_cart prop_dumbbell prop_kettlebell prop_palm; do
	echo "== $s"
	"$HEAVY" "$BLENDER" --background --factory-startup -noaudio --python-exit-code 1 \
		--python "art/blender/proof/$s.py" 2>&1 | grep -E -i "error|traceback|CHADKIT_STATS" || true
done
python3 art/blender/proof/make_sheet.py
