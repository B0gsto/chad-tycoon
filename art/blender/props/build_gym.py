"""Builds gym props in one Blender session (props-gym):

    tools/blender-run.sh art/blender/props/build_gym.py [-- Kind Kind ...]

With no kinds given, builds all of them. Each prop script also runs on its own."""

import os
import runpy
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
KINDS = {
    "Dumbbell": "prop_Dumbbell.py",
    "DumbbellRack": "prop_DumbbellRack.py",
    "Barbell": "prop_Barbell.py",
    "Bench": "prop_Bench.py",
    "Kettlebell": "prop_Kettlebell.py",
    "Treadmill": "prop_Treadmill.py",
    "PunchBag": "prop_PunchBag.py",
    "YogaBall": "prop_YogaBall.py",
}
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
failed = []
for kind in argv or list(KINDS):
    print("== props-gym", kind)
    try:
        runpy.run_path(os.path.join(HERE, KINDS[kind]), run_name="__main__")
    except Exception:
        traceback.print_exc()
        failed.append(kind)
if failed:
    raise SystemExit("props-gym failed: " + ", ".join(failed))
