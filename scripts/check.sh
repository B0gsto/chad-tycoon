#!/usr/bin/env bash
# Formats, lints, type-checks, tests and builds both game variants.
# Usage: scripts/check.sh   (expects rojo, selene, stylua, lune, luau-lsp on PATH;
#                            `rokit install` provides them from rokit.toml)
set -euo pipefail
cd "$(dirname "$0")/.."

DEFS="${LUAU_DEFS:-.cache/globalTypes.d.luau}"
if [ ! -f "$DEFS" ]; then
	mkdir -p "$(dirname "$DEFS")"
	curl -fsSL -o "$DEFS" https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.53.0/scripts/globalTypes.d.luau
fi

echo "== stylua"
stylua --check src tests scripts

echo "== selene"
selene src

echo "== luau-lsp"
for variant in chad bot; do
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
rojo build bot.project.json -o build/BotFactoryTycoon.rbxlx
echo "All checks passed."
