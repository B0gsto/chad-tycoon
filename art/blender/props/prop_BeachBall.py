"""Beach ball (Prop_BeachBall, 2.6 studs across): six fat gores in coral, white, sunny, white,
blue and white with white polar caps, tipped over a little like the part-built BeachBall."""

import math
import os
import sys

import bmesh

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _props import ck, mat, ship  # noqa: E402

ck.reset_scene()
R = 1.3
cols = [mat("G0", "Coral"), mat("G1", "White"), mat("G2", "Sunny"), mat("G3", "Blue")]
bm = bmesh.new()
bmesh.ops.create_uvsphere(bm, u_segments=18, v_segments=12, radius=R)
ob = ck.mesh_object("BeachBall", bm, cols[0], (0, 0, R))
for m in cols[1:]:
    ob.data.materials.append(m)
gores = (0, 1, 2, 1, 3, 1)
for p in ob.data.polygons:
    c = p.center
    if abs(c.z) > R * 0.94:
        p.material_index = 1
        continue
    g = int((math.atan2(c.y, c.x) + math.pi) / (2 * math.pi) * 6 + 1e-4) % 6
    p.material_index = gores[g]
ck.shade_smooth(ob, 80)
ob.rotation_euler = (0.3, 0.2, 0.4)
ship([ob], "BeachBall", tri_budget=1200)
