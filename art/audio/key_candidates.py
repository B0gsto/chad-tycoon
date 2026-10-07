#!/usr/bin/env python3
"""art/audio/key_candidates.py - build the CARDIO key-press audition set in art/audio/candidates/.

usage: python3 art/audio/key_candidates.py RAW_DIR

RAW_DIR holds Creator Store clips converted to 44.1 kHz mono wav, named <assetId>.wav (downloaded through Open Cloud
asset delivery). Each REAL entry trims one press out of its clip; each SYNTH entry models a press as filtered-noise
excitation driving modal resonances: a bottom-out impact (keycap + case body), a plate/spring ping and a quieter
upstroke. Every candidate is written as NN-name.wav (one press, onset at ~2 ms, equal loudness) and NN-name-run.wav
(8 presses at ~7/s with small timing, pitch and volume variation). Fixed seeds: reruns are identical.
"""
import os
import sys
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "candidates")
TARGET_DB = -23.0   # RMS over the loudest 60 ms
MAX_LEN = 0.33

# (number, name, source asset id, onset hint s, description)
REAL = [
    ("hard-key", 9113873775, 0.0, "Computer Keyboard 1 (PSE): hard single key press on a full-size board, slight ring"),
    ("office-key", 9113873832, 0.0, "Computer Keyboard 2 (PSE): hard key press, drier office keyboard"),
    ("apple-key", 9113140795, 0.0, "Apple Keyboard 5 (PSE): short crisp Apple keyboard button push"),
    ("closeup-click", 9116154737, 0.0, "Keyboard Typing 24 (PSE): close-up computer key click"),
    ("soft-key", 9113877471, 0.0, "Computer Keyboard 6 (PSE): single typing stroke, softer"),
    ("typewriter", 9120299710, 0.0, "Typewriter 8 (PSE): 1920s Remington single key stroke"),
    ("deep-click", 9116149382, 0.04, "Keyboard Rapid Typing 17 (PSE): Epson keyboard, deep clicking, one stroke"),
]


def biquad(x, kind, f0, q):
    w = 2 * np.pi * min(f0, SR * 0.45) / SR
    alpha, c = np.sin(w) / (2 * q), np.cos(w)
    b = {"bp": [alpha, 0.0, -alpha], "hp": [(1 + c) / 2, -(1 + c), (1 + c) / 2],
         "lp": [(1 - c) / 2, 1 - c, (1 - c) / 2]}[kind]
    a0, a1, a2 = 1 + alpha, -2 * c, 1 - alpha
    b0, b1, b2 = (v / a0 for v in b)
    a1, a2 = a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, xi in enumerate(x):
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, xi, y1, yi
        y[i] = yi
    return y


def hit(rng, n, at, burst_ms, modes, noises, glide=0.0):
    """One mechanical contact at `at` s: a noise burst (the impact) drives damped modes [(hz, tau, amp)] and
    band-passed noise layers [(kind, hz, q, amp, tau)]. `glide` bends mode pitch down from +glide at contact."""
    out = np.zeros(n)
    s = int(at * SR)
    if s >= n:
        return out
    m = n - s
    t = np.arange(m) / SR
    bl = max(2, int(burst_ms * SR / 1000))
    burst = rng.standard_normal(bl) * np.hanning(bl * 2)[bl:]  # sharp front, fast fall
    for hz, tau, amp in modes:
        f = hz * (1 + glide * np.exp(-t / 0.012))
        ir = np.sin(2 * np.pi * np.cumsum(f) / SR + rng.uniform(0, 6.28)) * np.exp(-t / tau)
        out[s:] += amp * np.convolve(burst, ir)[:m] / np.sqrt(bl)
    for kind, hz, q, amp, tau in noises:
        nz = biquad(rng.standard_normal(m), kind, hz, q) * np.exp(-t / tau) * np.clip(t / 0.0002, 0, 1)
        out[s:] += amp * nz / (np.abs(nz).max() + 1e-9)
    return out


def synth(spec, seed):
    rng = np.random.default_rng(seed)
    n = int(MAX_LEN * SR)
    x = np.zeros(n)
    for layer in spec:
        at, gain, burst, modes, noises = layer[:5]
        glide = layer[5] if len(layer) > 5 else 0.0
        h = hit(rng, n, at, burst, modes, noises, glide)
        x += gain * h / (np.abs(h).max() + 1e-9)
    return x


SYNTH = [
    ("clicky-blue", "Synth: clicky blue switch. Click-jacket snap, plate bottom-out, clicky upstroke", [
        (0.000, 0.9, 0.15, [(5200, 0.004, 1.0), (7400, 0.002, 0.5)], [("hp", 4000, 0.8, 1.0, 0.0012)]),
        (0.009, 1.0, 0.6, [(1150, 0.018, 1.0), (2550, 0.010, 0.6), (4100, 0.006, 0.35), (520, 0.03, 0.4)],
         [("bp", 1900, 1.2, 0.8, 0.007)]),
        (0.085, 0.38, 0.15, [(4800, 0.003, 1.0)], [("hp", 3500, 0.8, 0.8, 0.001)]),
        (0.090, 0.25, 0.4, [(1300, 0.012, 1.0), (2900, 0.006, 0.5)], []),
    ]),
    ("tactile-brown", "Synth: tactile brown switch. Soft bump scrape, muted plastic bottom-out, light upstroke", [
        (0.000, 0.25, 1.2, [(2100, 0.004, 1.0)], [("bp", 2500, 1.0, 1.0, 0.004)]),
        (0.011, 1.0, 0.7, [(780, 0.022, 1.0), (1650, 0.012, 0.65), (2950, 0.006, 0.3), (380, 0.03, 0.45)],
         [("bp", 1400, 1.0, 0.6, 0.008)]),
        (0.095, 0.22, 0.5, [(900, 0.012, 1.0), (2000, 0.006, 0.5)], [("bp", 1800, 1.0, 0.5, 0.004)]),
    ]),
    ("linear-thock", "Synth: lubed linear red switch. No click, rounded thock with a little plate ping", [
        (0.000, 1.0, 0.9, [(520, 0.035, 1.0), (1180, 0.016, 0.6), (2350, 0.008, 0.28), (3900, 0.004, 0.12)],
         [("lp", 1600, 0.7, 0.55, 0.006)], 0.05),
        (0.100, 0.18, 0.6, [(640, 0.015, 1.0), (1400, 0.008, 0.4)], []),
    ]),
    ("deep-custom", "Synth: deep custom board (foam, PBT caps). Low marbly thock, short and round", [
        (0.000, 1.0, 1.4, [(230, 0.045, 1.0), (410, 0.03, 0.75), (760, 0.016, 0.45), (1400, 0.008, 0.2)],
         [("lp", 900, 0.7, 0.6, 0.008)], 0.08),
        (0.004, 0.25, 0.3, [(2600, 0.005, 1.0)], []),
        (0.110, 0.15, 0.8, [(300, 0.02, 1.0), (620, 0.012, 0.5)], []),
    ]),
    ("bubble-pop", "Synth: cartoon bubbly key for a kid game. Soft tap plus a rising-then-dropping pitched pop", [
        (0.000, 0.55, 0.5, [(1500, 0.006, 1.0), (3100, 0.003, 0.4)], [("bp", 2200, 1.4, 0.6, 0.003)]),
        (0.006, 1.0, 1.0, [(620, 0.05, 1.0), (1240, 0.025, 0.28)], [], -0.35),
        (0.006, 0.4, 0.8, [(260, 0.04, 1.0)], [], 0.1),
    ]),
]


def read_wav(path):
    w = wave.open(path)
    x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(float) / 32768
    assert w.getframerate() == SR and w.getnchannels() == 1
    return x


def rms_env(x, ms=2):
    k = max(1, int(SR * ms / 1000))
    return np.sqrt(np.convolve(x * x, np.ones(k) / k, "same"))


def trim_real(x, hint):
    x = biquad(x, "hp", 60, 0.7)  # rumble
    e = rms_env(x)
    s0 = int(hint * SR)
    pk = e[s0:].max()
    onset = s0 + int(np.argmax(e[s0:] > pk * 0.06))
    start = max(0, onset - int(0.002 * SR))
    seg = x[start:start + int(MAX_LEN * SR)].copy()
    # end where the tail stays 45 dB under the peak (or MAX_LEN), then a fade
    es = rms_env(seg, 5)
    loud = np.nonzero(es > es.max() * 10 ** (-45 / 20))[0]
    end = min(len(seg), loud[-1] + int(0.01 * SR)) if len(loud) else len(seg)
    seg = seg[:end]
    seg[:int(0.0015 * SR)] *= np.linspace(0, 1, int(0.0015 * SR))
    f = min(len(seg) // 4, int(0.03 * SR))
    seg[-f:] *= np.linspace(1, 0, f) ** 2
    return seg


def finish(x):
    """Trim leading silence to ~2 ms, cut trailing silence, fade, normalize loudness, soft-limit peaks."""
    e = rms_env(x)
    on = int(np.argmax(e > e.max() * 0.03))
    x = x[max(0, on - int(0.002 * SR)):]
    es = rms_env(x, 5)
    loud = np.nonzero(es > es.max() * 10 ** (-50 / 20))[0]
    x = x[:min(len(x), loud[-1] + int(0.008 * SR), int(MAX_LEN * SR))].copy()
    f = min(len(x) // 4, int(0.02 * SR))
    x[-f:] *= np.linspace(1, 0, f) ** 2
    win = int(0.06 * SR)
    loudest = max(np.sqrt(np.mean(x[i:i + win] ** 2)) for i in range(0, max(1, len(x) - win), 64))
    x = x * (10 ** (TARGET_DB / 20) / (loudest + 1e-12))
    return np.where(np.abs(x) > 0.8, np.sign(x) * (0.8 + 0.19 * np.tanh((np.abs(x) - 0.8) / 0.19)), x)


def run_demo(x, seed):
    rng = np.random.default_rng(seed)
    step = SR / 7
    out = np.zeros(int(step * 8 + len(x) * 1.1) + SR // 10)
    for i in range(8):
        rate = 2 ** (rng.uniform(-0.6, 0.6) / 12)        # +/- 0.6 semitone
        idx = np.arange(0, len(x) - 1, rate)
        v = np.interp(idx, np.arange(len(x)), x) * 10 ** (rng.uniform(-2.5, 1.0) / 20)
        s = int(i * step + rng.uniform(-0.008, 0.008) * SR) + int(0.01 * SR)
        out[s:s + len(v)] += v
    return np.clip(out, -0.99, 0.99)


def write(path, x):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def main():
    raw = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    rows = []
    num = 1
    for name, aid, hint, desc in REAL:
        x = finish(trim_real(read_wav(os.path.join(raw, f"{aid}.wav")), hint))
        rows.append((num, name, desc, f"rbxassetid://{aid}", x))
        num += 1
    for k, (name, desc, spec) in enumerate(SYNTH):
        x = synth(spec, 100 + k)
        x = biquad(x, "hp", 90, 0.7)
        rows.append((num, name, desc, "synth (art/audio/key_candidates.py)", finish(x)))
        num += 1
    lines = ["# CARDIO key-press candidates", "",
             "Each `NN-name.wav` is one press (onset trimmed to ~2 ms, all normalized to the same loudness: "
             f"{TARGET_DB:.0f} dBFS RMS over the loudest 60 ms). `NN-name-run.wav` is 8 presses at ~7 per second "
             "with slight pitch/volume variation, as heard while running on the keyboard floor.", "",
             "Real recordings are Pro Sound Effects clips Roblox licensed for the Creator Store (free to use in-game; "
             "the asset id can go straight into Sounds.luau). The in-game sound would play the whole original clip, "
             "so for a long source either upload the trimmed wav or set a TimePosition/PlaybackRegion.", "",
             "| # | Name | What it is | Source | Duration |", "|---|---|---|---|---|"]
    for num, name, desc, src, x in rows:
        base = f"{num:02d}-{name}"
        write(os.path.join(OUT, base + ".wav"), x)
        write(os.path.join(OUT, base + "-run.wav"), run_demo(x, num))
        lines.append(f"| {num:02d} | {name} | {desc} | {src} | {len(x) / SR:.3f} s |")
        print(base, f"{len(x) / SR:.3f}s peak {20 * np.log10(np.abs(x).max()):.1f} dB")
    with open(os.path.join(OUT, "INDEX.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
