"""Builds the props-decor props in one Blender run (heavy-lock friendly).

    tools/blender-run.sh art/blender/props/build_decor.py [-- Kind Kind ...]

With no kinds given, builds every props-decor kind (KINDS); other prop_*.py files in this folder
belong to other prop sets and are not touched."""

import os
import runpy
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
KINDS = ["PalmTree", "PalmPlanter", "WaterCooler", "TowelStack", "Speaker", "Trophy", "BeachBall", "JuiceBar",
         "HubBench"]
kinds = argv or KINDS
failed = []
for kind in kinds:
    print("== props-decor:", kind, flush=True)
    try:
        runpy.run_path(os.path.join(HERE, "prop_%s.py" % kind), run_name="__main__")
    except Exception:
        traceback.print_exc()
        failed.append(kind)
if failed:
    print("PROPS_FAILED", failed)
    sys.exit(1)
