"""Proof prop: chunky toy palm tree (about 9 studs tall), low poly for repeated use on a plot.
A fat, gently curved trunk in bold orange / warm tan stripes, six thick wide upturned fronds in
bright lime with a lighter midrib band and emerald undersides, three bright coconuts."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, prop  # noqa: E402
from mathutils import Vector  # noqa: E402

ck.reset_scene()
stripe_a = ck.toy_material("TrunkOrange", "Orange")
stripe_b = ck.toy_material("TrunkTan", "Tan")
leaf = ck.toy_material("Leaf", "Lime")
band = ck.toy_material("LeafBand", ck.mix("Lime", "Sunny", 0.45))
under = ck.toy_material("LeafUnder", "Emerald")
nut = ck.toy_material("Coconut", ck.mix("Orange", "Coral", 0.45))

H = 6.0  # trunk height


def trunk_at(t):
    """Curved trunk centre line, t in 0..1 (leans toward +X)."""
    return Vector((1.1 * t * t, 0.15 * t, H * t))


parts = []
SEG = 4
for i in range(SEG):
    t0, t1 = i / SEG, (i + 1) / SEG + 0.02
    r = 1.15 - 0.3 * (i / (SEG - 1))
    ts = [t0, (t0 + t1) / 2, t1]
    parts.append(ck.sweep([trunk_at(t) for t in ts], [r * 0.86, r, r * 0.86], 8,
                          stripe_a if i % 2 == 0 else stripe_b, "Trunk%d" % i, smooth_angle=70))
top = trunk_at(1.0) + Vector((0, 0, 0.25))
parts.append(ck.sphere(0.95, 8, 4, under, "Crown", top))

# Fronds: thick flattened hexagonal sweeps that reach out and curve up to a round blunt tip. Ring
# vertex 0 sits on the blade edge, so the face between vertices 1 and 2 is the top midrib band.
US = (0.0, 0.2, 0.42, 0.64, 0.84, 1.0)
WID = (0.5, 0.98, 1.08, 0.96, 0.66, 0.0)
SIDES = 6
for k in range(6):
    a = 2 * math.pi * k / 6 + 0.25
    d = Vector((math.cos(a), math.sin(a), 0))
    reach, rise = (3.9, 0.7) if k % 2 == 0 else (3.4, 1.2)
    pts = [top + d * (0.3 + reach * u) + Vector((0, 0, 0.15 + rise * u + 1.3 * u ** 3)) for u in US]
    blade = ck.sweep(pts, WID, SIDES, leaf, "Leaf", flatten=0.4, smooth_angle=50)
    blade.data.materials.append(band)
    blade.data.materials.append(under)
    me = blade.data
    for p in me.polygons:
        if len(p.vertices) != 4:
            p.material_index = 2 if p.normal.z < 0 else 0
            continue
        js = sorted({v % SIDES for v in p.vertices})
        if js == [1, 2]:
            p.material_index = 1
        elif p.normal.z < -0.1:
            p.material_index = 2
    parts.append(blade)
for k in range(3):
    a = 2 * math.pi * k / 3 + 1.1
    parts.append(ck.sphere(0.52, 6, 4, nut, "Coconut",
                           top + Vector((0.8 * math.cos(a), 0.8 * math.sin(a), -0.75))))
obj, tris = prop(parts, "palm", "PalmTree", tri_budget=800)
