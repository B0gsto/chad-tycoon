"""Proof icon: tall faceted gem (Rizz), saturated cyan crown fading to deep blue, white table and a bright gloss streak."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, icon  # noqa: E402
from mathutils import Vector  # noqa: E402

ck.reset_scene()
TOP, BOTTOM = 0.62, -1.18
body = ck.gradient_material("GemBody", [(0.0, ck.mix("BlueDeep", "Blue", 0.45)), (0.42, "Blue"), (0.72, "CyanPop"),
                                        (1.0, ck.mix("CyanPop", "White", 0.35))], lo=BOTTOM, hi=TOP,
                            roughness=0.18, coat=0.8)
table = ck.toy_material("GemTable", ck.mix("CyanPop", "White", 0.72), roughness=0.15, coat=0.8,
                        emission=0.25)

# Brilliant cut, taller than wide: blunt pavilion point, narrow table so the crown facets show.
gem = ck.lathe([(0, BOTTOM), (0.13, BOTTOM + 0.06), (0.86, 0.0), (0.86, 0.15), (0.5, TOP), (0, TOP)],
               segments=8, mat=body, name="Gem")
gem.data.materials.append(table)
for p in gem.data.polygons:
    p.material_index = 1 if p.center.z > TOP - 0.01 else 0
ck.shade_flat(gem)
ck.soften(gem, width=0.03, segments=2, limit_angle=10.0, weighted=True)
ck.shade_flat(gem)  # keep crisp facets between the soft bevels
gem.rotation_euler = (0.0, 0.0, 0.3927 / 2)
# Bright specular streak up the middle of the front-left crown facet (toward the key light).
# Facet centres sit between the lathe corners: corners at 45k + 11.25 degrees after the turn above.
fa = math.radians(-101.25)
fn = Vector((math.cos(fa), math.sin(fa), 0.0))
normal = Vector((fn.x * 0.62, fn.y * 0.62, 0.36)).normalized()
inset = math.cos(math.radians(22.5))  # facet centre distance / corner radius


def on_crown(t, lift=0.025):
    r, z = 0.86 + (0.5 - 0.86) * t, TOP * t
    return fn * (r * inset) + Vector((0, 0, z)) + normal * lift


streak = ck.gloss_streak([on_crown(t) for t in (0.14, 0.32, 0.5, 0.68, 0.84)], 0.12, normal)
ck.group([gem, streak], "GemIcon", rotation=(-10, 0, 0))
icon([gem, streak], "gem")
