> Historical working note from 2026-10-06. It no longer matches the game;
> see README.md for the current design.

# Addendum: gap-fix pass (read after FX_CONTRACT.md)

The first juice pass is in the working tree (uncommitted). An audit found these gaps. Five agents
fix them in parallel on DISJOINT files. Edit only your files. Don't commit, don't run
scripts/check.sh or rojo build into build/, and don't run preview/render.sh.

## New cross-module contract (server produces, client consumes)
- Effect `"Pad"` `{ name: string, padPos: Vector3, ok: boolean, reason: "money" | "locked" | nil }`
  is sent whenever a pad action is refused (ok=false). reason = "money" when the player can't afford it.
- Effect `"Buy"` gains `cost: number` (cash spent).
- Effect `"Cash"` gains `source: "Collect" | "Auto" | "Free" | "Purchase"`. padPos stays for Collect/Free.
  "Purchase" = developer-product cash pack (big celebration).
- Effect `"Merge"` already carries `count`/`summary` for batched merges. Client must show them.
- Notify `"Reward"` gains `tiers: {number}`: every tier newly discovered by that action (ascending).
  `tier` stays = newest. Popups shows ONE card plus a "+N more new Chads" strip with small icons.
- Client action `{ action = "ClaimFree" }` claims the free reward like the Free pad does.
- Converter board: the server shows the queue ETA ("Done in 1m 20s") and the process pads read
  "+12% speed" (the real growth), not "+N/sec".

## Sounds
`Sounds.play(name, pitchJitter?, pitchMult?)`. Sound names in use stay as defined in Sounds.luau.
The sound agent makes every name audible with verified asset ids.
