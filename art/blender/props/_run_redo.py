"""Runs several prop scripts in one Blender session (one heavy slot):

    tools/blender-run.sh art/blender/props/_run_redo.py -- prop_PalmTree.py ../cosmetics/prop_Crown.py

Paths are relative to this folder. Each script resets the scene itself."""

import os
import runpy
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
failed = []
for rel in args:
    path = os.path.normpath(os.path.join(HERE, rel))
    print("REDO_RUN", path)
    try:
        runpy.run_path(path, run_name="__main__")
    except Exception:
        traceback.print_exc()
        failed.append(rel)
print("REDO_DONE failed=%s" % failed)
