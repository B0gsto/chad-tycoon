#!/usr/bin/env bash
# Regenerates the preview screenshots in preview/screenshots/<variant>/.
#
# Roblox can't run headless, so this runs the game's real server and client
# code under Lune (preview/export/export.luau), exports the generated world and
# UI, then renders them with three.js + the GUI renderer in headless Chromium
# (preview/render/shoot.mjs).
#
# Needs: rojo + lune on PATH, Node 18+, and a Chromium/headless_shell binary
# (set CHROME=/path/to/headless_shell if it isn't at the Playwright default).
set -euo pipefail
cd "$(dirname "$0")/.."

rojo build chad.project.json -o build/ChadAuraTycoon.rbxlx
rojo build bot.project.json -o build/BotFactoryTycoon.rbxlx
for variant in chad bot; do
	lune run preview/export/export.luau "$variant"
done
(cd preview/render && npm install --silent)
node preview/render/shoot.mjs chad bot
