#!/usr/bin/env bash
# Builds the release place file that tools/deploy.py publishes.
# Usage: scripts/build-release.sh
# Runs scripts/check.sh first (format, lint, type-check, tests, XML build) and stops if it fails, then builds
# the binary place build/ChadAuraTycoon.rbxl (about 2.6x smaller than the .rbxlx; binary is what the Open
# Cloud publish uploads as application/octet-stream). Then: python3 tools/deploy.py check && ... publish
set -euo pipefail
cd "$(dirname "$0")/.."

if ! scripts/check.sh; then
	echo "build-release: scripts/check.sh failed; no release file built." >&2
	exit 1
fi

echo "== release build"
mkdir -p build
tmp="build/.ChadAuraTycoon.rbxl.tmp.$$.rbxl"
trap 'rm -f "$tmp"' EXIT
rojo build chad.project.json -o "$tmp"
mv -f "$tmp" build/ChadAuraTycoon.rbxl
trap - EXIT
ls -l build/ChadAuraTycoon.rbxl | awk '{ printf "Release place: build/ChadAuraTycoon.rbxl (%.2f MB)\n", $5 / 1e6 }'
echo "Next: python3 tools/deploy.py check && python3 tools/deploy.py publish"
