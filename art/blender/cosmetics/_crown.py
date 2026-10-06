"""The Golden Crown cosmetic, shared by the game mesh (prop_Crown.py, lod="game") and the icons
(icons.py, lod="icon"): a chunky gold band with a two-tone rim, a pink velvet cap, five fat rounded
points tipped with pale-gold pearl bulbs (tilted a little outward) and five round cabochon gems on
the band, one under each point (cyan front, hot pink front sides, mint back sides).

Built with its base at z = 0, front (cyan gem, centre point) toward -Y, before any scaling:
band outer radius 0.8, about 1.75 wide and 0.85 tall. `mk(name, color, **kw)` makes a material.
"""

import math

import chadkit as ck

GOLD = (255, 204, 24)  # same bright gold as the Trophy prop
ANGLES = [-90 + 72 * k for k in range(5)]  # point / gem azimuths, front first
GEM_COLORS = ["CyanPop", "HotPink", "Mint", "Mint", "HotPink"]


def crown(mk, lod="icon"):
    """Returns the crown parts (list of mesh objects, unparented)."""
    hi = lod == "icon"
    gold = mk("CrownGold", ck.mix(GOLD, "White", 0.08) if hi else GOLD)
    rim = mk("CrownRim", ck.mix(GOLD, "GoldDeep", 0.55))
    pearl = mk("CrownPearl", ck.mix(GOLD, "White", 0.62))
    velvet = mk("CrownVelvet", "HotPink", roughness=0.5, coat=0.3)
    parts = []

    # Band: a solid rounded drum (the velvet cap covers its top). Game LOD paints the bevelled top
    # and bottom edges deep gold; the icon gets real raised rims instead.
    if hi:
        band = ck.lathe(ck.round_profile(0, 0.8, 0.0, 0.42, 0.09, 4), 64, gold, "Band")
    else:
        band = ck.lathe([(0, 0), (0.74, 0), (0.8, 0.07), (0.8, 0.34), (0.74, 0.42), (0, 0.42)], 20, gold,
                        "Band", smooth_angle=60)
        band.data.materials.append(rim)
        for p in band.data.polygons:
            if p.center.z < 0.06 or p.center.z > 0.36:
                p.material_index = 1
    parts.append(band)
    if hi:
        parts.append(ck.torus(0.8, 0.065, 64, 10, mat=rim, name="RimLo", location=(0, 0, 0.07)))
        parts.append(ck.torus(0.8, 0.065, 64, 10, mat=rim, name="RimHi", location=(0, 0, 0.37)))

    # Velvet cap.
    vprof = ([(0.7, 0.3), (0.69, 0.46), (0.57, 0.63), (0.33, 0.74), (0, 0.78)] if hi
             else [(0.7, 0.3), (0.6, 0.6), (0.3, 0.74), (0, 0.78)])
    parts.append(ck.lathe(vprof, 40 if hi else 10, velvet, "Velvet", smooth_angle=80))

    # Points: a fat cone narrowing to a neck, then a round pearl bulb.
    if hi:
        prof = [(0.22, 0.0), (0.215, 0.08), (0.17, 0.24), (0.125, 0.35)]
        for a in range(-60, 91, 15):
            r = math.radians(a)
            prof.append((max(0.0, 0.135 * math.cos(r)), 0.47 + 0.135 * math.sin(r)))
        pseg = 28
    else:
        prof = [(0.21, 0.0), (0.12, 0.33), (0.145, 0.43), (0.08, 0.53), (0.0, 0.55)]
        pseg = 6
    for a_deg in ANGLES:
        a = math.radians(a_deg)
        pt = ck.lathe(prof, pseg, gold, "Point", smooth_angle=70 if hi else 80)
        pt.data.materials.append(pearl)
        for p in pt.data.polygons:
            if p.center.z > 0.37:
                p.material_index = 1
        pt.location = (0.66 * math.cos(a), 0.66 * math.sin(a), 0.26)
        pt.rotation_euler = (0, math.radians(10), a)  # tip leans outward
        parts.append(pt)

    # Gems: flattened balls half sunk into the band under each point (local X = outward).
    for a_deg, col in zip(ANGLES, GEM_COLORS):
        a = math.radians(a_deg)
        size = 0.16 if a_deg == -90 else 0.125
        if hi:
            g = ck.sphere(size, 28, 14, mk("Gem" + col, col, roughness=0.12, coat=0.95), "Gem")
        else:
            g = ck.sphere(size, 6, 3, mk("Gem" + col, col), "Gem")
        g.location = (0.79 * math.cos(a), 0.79 * math.sin(a), 0.21)
        g.rotation_euler = (0, 0, a)
        g.scale = (0.5, 1.0, 1.0)
        parts.append(g)

    if hi:
        # Gloss streak on the band's front-left, toward the key light.
        n = (math.cos(math.radians(-128)), math.sin(math.radians(-128)), 0.15)
        parts.append(ck.gloss_streak([(0.815 * math.cos(math.radians(a)), 0.815 * math.sin(math.radians(a)), 0.23)
                                      for a in (-150, -140, -130, -120)], 0.1, n))
    return parts
