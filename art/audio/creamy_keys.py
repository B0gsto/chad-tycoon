"""Soft but satisfying key strokes built on the owner's pick, soft-key
(PSE "Computer Keyboard 6", 9113877471): warmer, rounder, with a creamy
bottom-out "thock" and no harsh highs (lubed-linear-switch ASMR feel).

Usage: python3 art/audio/creamy_keys.py <raw dir> <out dir>
"""
import sys
import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from blend_keys import SR, load, trim, one_pole, env_decay, save, run  # noqa: E402

def pitch(x, factor):
    idx = np.arange(0, len(x) - 1, factor)
    return np.interp(idx, np.arange(len(x)), x)

def resonator(x, freq, q):
    # Two-pole band-pass (RBJ) for a short tonal "pop" / plate ring.
    w0 = 2 * np.pi * freq / SR
    alpha = np.sin(w0) / (2 * q)
    b0, b2 = alpha, -alpha
    a0, a1, a2 = 1 + alpha, -2 * np.cos(w0), 1 - alpha
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        out = (b0 * v + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, v, y1, out
        y[i] = out
    return y

def thump(n, f0, f1, ms):
    t = np.arange(n) / SR
    f = f1 + (f0 - f1) * np.exp(-t / 0.012)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env_decay(n, ms)

def main(raw, out):
    L = int(0.26 * SR)
    soft = trim(load(f"{raw}/9113877471.wav"), L)
    soft = np.pad(soft, (0, max(0, L - len(soft))))[:L]

    def finish(x, name, num):
        x = x * env_decay(len(x), 130)
        save(f"{out}/{num}-{name}.wav", x.copy())
        save(f"{out}/{num}-{name}-run.wav", run(x))

    # 19 creamy: soft key a touch lower and warmer + a round low thock.
    a = one_pole(pitch(soft, 0.9), 3200)[:L]
    a = np.pad(a, (0, L - len(a)))
    finish(a + 0.35 * thump(L, 220, 120, 45), "creamy-thock", 19)

    # 20 marbly: soft key + a short, rounded "marble" clack ring.
    b = one_pole(soft, 4500)
    finish(b + 0.5 * resonator(one_pole(soft, 6000), 1150, 6) * env_decay(L, 30), "marbly", 20)

    # 21 poppy: soft key + a gentle bubble pop (falling pitch), very satisfying on repeat.
    c = one_pole(soft, 3800)
    finish(c + 0.28 * thump(L, 700, 330, 28), "soft-pop", 21)

    # 22 deep creamy: lower, muted, cushioned bottom-out.
    d = one_pole(pitch(soft, 0.8), 2400)[:L]
    d = np.pad(d, (0, L - len(d)))
    finish(d + 0.45 * thump(L, 180, 95, 60) + 0.25 * resonator(d, 420, 3), "deep-creamy", 22)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
