"""Renders the HUD icon set (or a selection) in one Blender run:

    tools/blender-run.sh art/blender/icons/render.py                 # every icon
    tools/blender-run.sh art/blender/icons/render.py -- Coin Lock    # just these

Output: art/out/icons/<Name>.png (512 px, transparent, sticker outline + shadow) and the untouched
renders in art/out/icons/raw/.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import currency  # noqa: E402,F401
import glyphs  # noqa: E402,F401
import nav  # noqa: E402,F401
import special  # noqa: E402,F401
from _icons import REGISTRY, argv_names, render  # noqa: E402

names = argv_names()
unknown = [n for n in names if n not in REGISTRY]
if unknown:
    raise SystemExit("unknown icon(s): %s (known: %s)" % (", ".join(unknown), ", ".join(REGISTRY)))
render(names or None)
