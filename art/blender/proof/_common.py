"""Shared setup for the proof scripts: puts art/blender/lib on sys.path and defines output paths."""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "proof")
ICONS = os.path.join(OUT, "icons")
PROPS = os.path.join(OUT, "props")
MESHES = os.path.join(OUT, "meshes")
for d in (ICONS, PROPS, MESHES):
    os.makedirs(d, exist_ok=True)


def icon(target, name, **kw):
    """Renders a proof icon to art/out/proof/icons/<name>.png."""
    return ck.render_icon(target, os.path.join(ICONS, name + ".png"), **kw)


def prop(target, name, fbx_name, tri_budget=800, **render_kw):
    """Finishes a prop for the game, exports FBX, writes a stats json, renders a beauty shot
    (props/<name>.png) and a Roblox-like preview of the shipped mesh (props/<name>_game.png)."""
    obj, tris = ck.finish_for_game(target, fbx_name, tri_budget=tri_budget)
    ck.export_fbx(obj, os.path.join(MESHES, fbx_name + ".fbx"))
    stats = {"name": fbx_name, "triangles": tris, "size_studs": [round(v, 3) for v in obj["chad_size"]]}
    with open(os.path.join(MESHES, fbx_name + ".json"), "w") as f:
        json.dump(stats, f, indent=1)
    ck.render_prop(obj, os.path.join(PROPS, name + ".png"), **render_kw)
    ck.render_prop(obj, os.path.join(PROPS, name + "_game.png"), size=320, samples=32, game=True, **render_kw)
    print("CHADKIT_STATS", json.dumps(stats))
    return obj, tris
