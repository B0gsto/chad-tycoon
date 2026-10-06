"""Completes chadkit's PALETTE with the Theme.World keys that point at Luau constants.

Theme.World now writes many colours as named constants (`Sunny = SUNNY`, `White = PURE_WHITE`,
`Pads = { Buy = BUTTER }`) declared once as `local SUNNY = rgb(...)`. chadkit's parser only reads
inline `rgb(...)` values, so those keys are missing from ck.PALETTE. fill() resolves them and adds
every missing key (existing entries are left alone), so scripts can keep using "Sunny", "Coral",
"Blue", "White", "Teal", "RedOrange", "Butter", ... Call it right after importing chadkit:

    import chadkit as ck
    import theme_palette
    theme_palette.fill(ck)
"""

import re


def resolve(path):
    """Theme.World as {key: (r, g, b)}, constants resolved, nested tables as dotted keys."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    consts = {}
    for m in re.finditer(r"^local\s+(\w+)\s*=\s*rgb\((\d+),\s*(\d+),\s*(\d+)\)", text, re.M):
        consts[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
    start = text.find("Theme.World = {")
    if start < 0:
        return {}
    out, stack = {}, []
    for line in text[start:].splitlines()[1:]:
        s = line.strip()
        if s.startswith("--") or not s:
            continue
        m = re.match(r"(\w+)\s*=\s*rgb\((\d+),\s*(\d+),\s*(\d+)\)", s)
        if m:
            out[".".join(stack + [m.group(1)])] = tuple(int(m.group(i)) for i in (2, 3, 4))
            continue
        m = re.match(r"(\w+)\s*=\s*([A-Z][A-Z0-9_]*)\s*,?\s*(--.*)?$", s)
        if m and m.group(2) in consts:
            out[".".join(stack + [m.group(1)])] = consts[m.group(2)]
            continue
        m = re.match(r"(\w+)\s*=\s*\{", s)
        if m:
            stack.append(m.group(1))
            continue
        if s.startswith("}"):
            if not stack:
                break
            stack.pop()
    return out


def fill(ck):
    """Adds every Theme.World key missing from ck.PALETTE (keeps the ones already there)."""
    try:
        world = resolve(ck.THEME_PATH)
    except OSError:
        world = {}
    for key, rgb in world.items():
        ck.PALETTE.setdefault(key, rgb)
    # Old fallback names still used by icon scripts, in case the theme drops them.
    for key, rgb in ck._FALLBACK.items():
        ck.PALETTE.setdefault(key, rgb)
    ck.PALETTE.setdefault("White", (255, 255, 255))
    return ck.PALETTE
