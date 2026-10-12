#!/usr/bin/env bash
# Renders six fixed views of the main player's plot (preview/render/shoot.mjs, PLOT_SHOTS) and
# joins them into one labelled contact sheet, for comparing plot layouts.
#
#   preview/plot-shots.sh <out-dir> [label]
#
# Writes <out-dir>/plot-*.png and <out-dir>/sheet.png. Runs in one heavy-job slot
# (tools/with-heavy.sh). Needs rojo + lune on PATH, Node 18+, Pillow, and CHROME pointing at a
# Chromium binary (defaults to Google Chrome on macOS when it is installed).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: preview/plot-shots.sh <out-dir> [label]}"
LABEL="${2:-plot}"
MAC_CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -z "${CHROME:-}" ] && [ -x "$MAC_CHROME" ]; then
	export CHROME="$MAC_CHROME"
fi
mkdir -p "$OUT"

tools/with-heavy.sh --quiet -- bash -c '
	set -euo pipefail
	rojo build chad.project.json -o build/ChadAuraTycoon.rbxlx >/dev/null
	lune run preview/export/export.luau chad >/dev/null
	PLOT_SHOTS=1 node preview/render/shoot.mjs chad | grep -E "plot-|rror" || true
'
cp preview/screenshots/chad/plot-*.png "$OUT/"
rm -f preview/screenshots/chad/plot-*.png
python3 preview/render/sheet.py "$OUT/sheet.png" "$LABEL" "$OUT"/plot-*.png
echo "sheet: $OUT/sheet.png"
