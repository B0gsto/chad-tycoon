# Assets: Blender -> Roblox pipeline

Blender scripts make PNGs and FBX meshes. `pipeline/upload.py` uploads them with the owner's Open Cloud key
(`~/RobloxProjects/.roblox-api-key`: never print, copy or log it) and pins the ids in `assets/pins.json`.
`pipeline/gen_assets.py` turns the pins into `src/shared/Assets.luau`. Asset ids are never typed by hand.

## Domains

One spec per domain in `art/assets/<domain>.json`. The Blender scripts live in `art/blender/<area>/` (many areas
have a `run_all.sh` and a `make_sheet.py` contact sheet).

| Domain | Entries | Kind | Made by | Used by |
|---|---|---|---|---|
| `brand` | Logo, LogoSmall, KeyArt, TitleCard | Image | `art/blender/brand/` | loading screen |
| `faces` | Happy, Proud, Shock, Awe, Sad, Idea, Fury, Smirk | Image | `art/blender/faces/` | intro cutscene avatar expressions |
| `hud` | Dumbbell, DumbbellGlow, MogRing* | Image | `art/blender/ui/hud_*.py`, `mog_ring.py` | HUD dumbbell, MOG TEST ring |
| `props` | 27 meshes (OrbBall, Crate, Converter, Vault, PalmTree, Crown, ...) | Model | `art/blender/props/`, `orbs/`, `cosmetics/` | `World/Props`, `Fx/Orbs`, `Cosmetics` (via `AssetModels`) |
| `ui` | atlas_1..3 (icon atlases with `cells`) | Image | `art/blender/icons/`, `icons_shop/`, `cosmetics/icons.py` + `tools/pack_atlas.py` | `Kit.icon` |
| `vfx` | CoinSpin, Confetti, Heart, Note, Puff, Ring, SoftDot, Sparkle, StarPop, Sweat | Image | `art/blender/vfx/` | `Fx/Sprites` |
| `proof` | sphere, cube | Image + Model | `art/proof/make_proof.py` | pipeline smoke test only |

Check the current list with `ls art/assets/`; the table above was taken from those files on 2026-10-06.

## Add an asset

1. Write a Blender script in `art/blender/<area>/` (the smallest example is `art/proof/make_proof.py`). Import
   `tools/blender/rbxkit.py` and export meshes with
   `rbxkit.export_fbx([obj], path)`. It writes 1 Blender unit = 1 stud, triangulated, sRGB vertex colours, and the
   same scene always gives the same bytes, so unchanged meshes never upload again. Keep each mesh under 20k triangles.
2. Run it headless: `tools/blender-run.sh art/<area>/<script>.py [-- args]`.
3. List the output in `art/assets/<domain>.json`:
   ```json
   { "domain": "props", "assets": [
     { "name": "dumbbell", "file": "art/out/props/dumbbell.fbx", "kind": "Model" },
     { "name": "coin", "file": "art/out/ui/coin.png", "kind": "Image" } ] }
   ```
   The key is `<domain>/<name>`, for example `props/dumbbell`.
4. Upload: `python3 pipeline/upload.py props`, or `--all` for every domain. Options:
   - `--check` makes no network calls and lists what would upload.
   - `--allow-pending` exits 0 while moderation is still pending.
   - `--poll-seconds N` sets how long to wait for moderation (default 300; 0 = do not wait).
   - `--route delivery|luau` forces one model download route (default tries both, in that order).
   - `--no-codegen` skips regenerating `Assets.luau`.
   - `--json` prints a machine-readable summary on stdout (logs go to stderr).

   Exit codes: 0 all approved, 1 error, 2 rejected, 3 still pending.
5. The upload regenerates `Assets.luau` itself. To run it by hand: `python3 pipeline/gen_assets.py`
   (`--check` reports whether the file is stale).
6. Commit `art/assets/*.json`, `art/out/atlas/*`, `assets/pins.json`, `assets/manifest.json`, `assets/models/*.rbxm` and `Assets.luau`.

## Icon atlases (UI icons)

Many small icons go up as a few 1024x1024 images instead of one upload each.

1. Render square RGBA PNGs into one folder, one file per icon. The file name is the icon name in PascalCase
   (`coin.png` or `Coin.png` gives `Coin`, `cash_rain.png` gives `CashRain`). Use the `Kit.ICONS` names
   (`Coin`, `Gem`, `Shop`, `Index`, `Ranking`, `Home`, `Free`, `Invite`, `Settings`, `Surge`, `Orb`, `Chad`, `Plus`,
   `Close`, `Check`, `Star`, `Music`, `Sound`, `Hash`, `Merge`, `Lock`, ...) so `Kit.icon` swaps the image in.
2. Pack: `python3 tools/pack_atlas.py ui art/out/ui/icons --write-spec` (more dirs or single `.png` files may follow).
   - Each atlas is a 5x5 grid of 204 px cells, so 25 icons per atlas. Icons are scaled to fit with 4 px of
     transparent padding (196 px of art) and centred. Order is sorted by name, so re-runs give identical bytes.
   - Writes `art/out/atlas/ui_1.png`, `ui_2.png`, ... and `art/out/atlas/ui.json`
     (`{ "art/out/atlas/ui_1.png": { "Coin": [0, 0, 204, 204], ... } }`). Stale `ui_<n>.png` files are deleted.
   - `--write-spec` upserts one entry per atlas, named `atlas_<n>`, into `art/assets/ui.json`. Without the flag,
     copy the cells into the spec yourself:
     ```json
     { "name": "atlas_1", "file": "art/out/atlas/ui_1.png", "kind": "Image",
       "cells": { "Coin": [0, 0, 204, 204], "Gem": [204, 0, 204, 204] } }
     ```
3. Upload as usual: `python3 pipeline/upload.py ui`. `gen_assets.py` reads the `cells` of every Image entry in
   `art/assets/*.json` (files in sorted order, so a later domain wins a name clash) and writes
   `Assets.Icons.Coin = { image = "rbxassetid://...", x = 0, y = 0, w = 204, h = 204 }`, plus `Assets.icon(name)`.
   Rejected or missing pins give no icons. `Kit.icon` then shows an ImageLabel with that `ImageRectOffset` /
   `ImageRectSize` and falls back to the shape icon for every other name.

Limits: 1024x1024 per atlas (the Roblox image limit), at most 25 icons per atlas, icons are shown at most 196 px
sharp. Icon names must be unique across all the packed folders.

## Preview (preview/render/shoot.mjs)

The preview runs the game under Lune and draws it with three.js, so it cannot fetch Roblox assets. It draws
pinned assets from the local files instead:

- Images: any ImageLabel / ImageButton (screen, SurfaceGui or BillboardGui) and any Decal / Texture whose image is
  `rbxassetid://<id>` of a pin in `assets/pins.json` is drawn from the pin's `source` PNG. `ImageRectOffset`,
  `ImageRectSize`, `ScaleType` (Stretch / Fit / Crop), `ImageColor3` and `ImageTransparency` are honoured; Decals use
  `Color3` and `Transparency`, Textures tile by `StudsPerTileU/V`. Unpinned ids draw as a dashed placeholder (GUI) or
  nothing (decal).
- Meshes: a MeshPart whose `MeshId` is a pin's `meshId` is drawn from `preview/web/models/<key with / as __>.glb`
  (`props/dumbbell` -> `props__dumbbell.glb`) when that file exists, with its own materials and vertex colours,
  scaled per axis so its bounds fill the part's `Size`. Without the GLB it is a plain box in the part's colour.
- Export the GLB from the same Blender object as the FBX: `rbxkit.export_glb([obj], path)` (Y up, vertex colours),
  front facing Blender -Y. The preview turns it 180 degrees about Y, which is how Roblox imports the FBX. If the FBX
  was written with `export_fbx(..., bake_z=True)`, turn the object the same way before exporting the GLB.
- `shoot.mjs` serves `/asset-index.json` (image id -> source PNG, mesh id -> GLB) and the files under `art/` and
  `assets/` at `/game/...`. The exporter passes `image`, `imageRect`, `imageColor`, `imageTransparency`,
  `scaleType` on GUI nodes, `meshId` on parts and a `decals` list per scene.

## What the upload does

- Files are content-addressed in `assets/manifest.json`, so identical bytes never upload twice.
- The creator comes from `deploy/target.json`.
- Each Model is downloaded back as `assets/models/<domain>__<name>.rbxm`. This is the only file that carries the
  MeshPart collision data. The run then measures it, and the pin records `meshId` and `size`.

## Use in game code

- `Assets.image("ui/coin"): string?`, `Assets.mesh("props/dumbbell"): Mesh?` (`{ id, model, size }`),
  `Assets.icon("Coin"): Icon?` (`{ image, x, y, w, h }`, an atlas cell), `Assets.has(key)`, and the raw
  `Assets.Images`, `Assets.Meshes` and `Assets.Icons` tables.
- `AssetModels.clone("props/dumbbell"): Instance?` returns a fresh clone of the downloaded Model with its MeshParts.
  It returns nil when the model is missing, so keep a part-built fallback.
- Rojo maps `assets/models` straight into `ReplicatedStorage.AssetModels` (see `chad.project.json`), so a normal
  `rojo build chad.project.json` includes every MeshPart with its collision data. No extra build step is needed.
  Keep `assets/models/.gitkeep`, because Rojo fails when that folder is missing.

## Developer products and passes

`tools/monetization.py` manages the universe's developer products and game passes (universe from
`deploy/target.json`, key handled exactly like `tools/assets.py`, never printed).

- `python3 tools/monetization.py list [--json]` lists every product and pass with id, price and sale state.
- `python3 tools/monetization.py ensure-product --name "Open Crate" --description "..." --price 30 [--icon x.png]`
  and `ensure-pass` (same flags, `--off-sale` to create it off sale). They reuse an item whose name matches exactly
  and never change an existing item's price, sale state or icon; otherwise they create it. Output is one JSON line
  with the id.
- Paste the id into `Theme.Monetization` in `src/themes/chad/Theme.luau` (`Id = 0` means not for sale yet).
- The key needs `developer-product:read/write` and `game-pass:read/write` with this universe added under each
  (https://create.roblox.com/dashboard/credentials).

## Locks (machine-wide, shared with the owner's other games)

- `tools/locks.py` keeps its locks in `/tmp/roblox-locks`. They are released when the holder dies.
- `heavy` has 2 slots for Blender, Xcode builds and renders across every project. `tools/blender-run.sh` takes a slot
  by itself and also refuses to start a third Blender. Wrap other heavy jobs in `tools/with-heavy.sh -- cmd`.
- `assets.ChadTycoon` is held by `pipeline/upload.py` for the whole run.
- `studio` is the one shared Roblox Studio (see `tools/studio.py`).
- When locks nest, take them in this order: studio, heavy, assets, gen. Use `tools/with-lock.sh <name> -- cmd` and
  check `python3 tools/locks.py status`.

## Other tools

- `python3 pipeline/doctor.py [--online]` checks the tools, the key file and the pins. With `--online` it also checks
  that Open Cloud accepts the key.
- `python3 tools/assets.py moderation <id>` and `python3 tools/assets.py refresh .` re-read moderation states.
- Studio captures: `tools/studio-open.py <place.rbxl> --tag NAME` opens a TestBench copy, and
  `tools/studio-window-shot.py --match TestBench-NAME.rbxl --out shot.png` captures it in the background. These need
  the Screen Recording and Accessibility permissions.
