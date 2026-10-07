"""Finishes the Cardio icon (system python3 + Pillow, after build.py):

    python3 art/blender/cardio/icon_post.py

art/out/cardio/Cardio_raw.png -> art/out/cardio/Cardio.png: a thick dark ink outline hugging the art, then the usual
white sticker outline and soft drop shadow around that.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "cardio")
INK = (46, 30, 96)
raw = os.path.join(OUT, "Cardio_raw.png")
mid = os.path.join(OUT, "Cardio_ink.png")
ck.sticker(raw, mid, outline=0.034, shadow=False, outline_rgb=INK)
ck.sticker(mid, os.path.join(OUT, "Cardio.png"), outline=0.03, shadow=True)
os.remove(mid)
print("icon", os.path.join(OUT, "Cardio.png"))
