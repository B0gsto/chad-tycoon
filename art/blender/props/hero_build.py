"""Builds the props-hero meshes in one Blender session (one heavy slot for all of them):

    tools/blender-run.sh art/blender/props/hero_build.py [-- giga_statue crate ...]

With no names it builds every hero prop. Then build the sheet with system python3:
    python3 art/blender/props/hero_sheet.py
"""

import os
import runpy
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ALL = ["crate", "trophy_podium", "converter", "vault", "crate_cracker", "giga_statue"]
names = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ALL
failed = []
for name in names or ALL:
    print("== hero", name, flush=True)
    try:
        runpy.run_path(os.path.join(HERE, name + ".py"), run_name="__main__")
    except Exception:
        traceback.print_exc()
        failed.append(name)
if failed:
    print("HERO_FAILED", failed)
    sys.exit(1)
