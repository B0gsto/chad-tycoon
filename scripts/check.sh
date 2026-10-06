#!/usr/bin/env bash
# Formats, lints, type-checks, tests and builds the game.
# Usage: scripts/check.sh   (expects rojo, selene, stylua, lune, luau-lsp on PATH;
#                            `rokit install` provides them from rokit.toml)
set -euo pipefail
cd "$(dirname "$0")/.."

# Roblox type definitions must match the installed luau-lsp release, so the cache is versioned.
LSP_VERSION="$(luau-lsp --version | tr -d '[:space:]')"
DEFS="${LUAU_DEFS:-.cache/globalTypes-$LSP_VERSION.d.luau}"
if [ ! -f "$DEFS" ]; then
	mkdir -p "$(dirname "$DEFS")"
	curl -fsSL -o "$DEFS.tmp" \
		"https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/$LSP_VERSION/scripts/globalTypes.d.luau"
	mv "$DEFS.tmp" "$DEFS"
fi

echo "== stylua"
stylua --check src tests scripts

echo "== selene"
selene src

echo "== luau-lsp"
for variant in chad; do
	rojo sourcemap "$variant.project.json" -o sourcemap.json
	luau-lsp analyze --sourcemap=sourcemap.json --definitions="$DEFS" \
		src/shared src/server src/client src/loader "src/themes/$variant"
done
rm -f sourcemap.json

echo "== tests"
lune run tests/run

echo "== build"
mkdir -p build
rojo build chad.project.json -o build/ChadAuraTycoon.rbxlx
echo "All checks passed."
