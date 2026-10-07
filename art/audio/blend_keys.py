"""Blend the owner's two favourite key sounds into ONE hybrid key stroke.

soft-key (PSE "Computer Keyboard 6", 9113877471) gives the round, satisfying body;
typewriter (PSE "Typewriter 8", 9120299710) gives the crisp mechanical snap. Each
hybrid takes the typewriter's attack (high frequencies, first few ms) and the soft
key's body (low/mid), onsets aligned, as a single cohesive hit.

Usage: python3 art/audio/blend_keys.py <raw dir with the two .wav files> <out dir>
"""
import sys, wave, struct
import numpy as np

SR = 44100

def load(path):
    w = wave.open(path)
    n, ch, sw, sr = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
    raw = w.readframes(n)
    w.close()
    assert sw == 2
    x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768
    if ch == 2:
        x = x.reshape(-1, 2).mean(axis=1)
    if sr != SR:
        t = np.arange(0, len(x) / sr, 1 / SR)
        x = np.interp(t, np.arange(len(x)) / sr, x)
    return x

def onset(x):
    env = np.abs(x)
    return int(np.argmax(env > env.max() * 0.15))

def one_pole(x, cutoff, high=False):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.zeros_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return x - y if high else y

def trim(x, length):
    s = max(0, onset(x) - int(0.002 * SR))
    return x[s:s + length]

def env_decay(n, ms):
    t = np.arange(n) / SR
    return np.exp(-t / (ms / 1000))

def save(path, x):
    x = x / (np.abs(x).max() + 1e-9) * 0.89
    fade = int(0.01 * SR)
    x[-fade:] *= np.linspace(1, 0, fade)
    w = wave.open(path, "w")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((x * 32767).astype("<i2").tobytes())
    w.close()

def run(x):
    step = SR // 7
    rng = np.random.default_rng(4)
    out = np.zeros(step * 8 + len(x) * 2)
    for i in range(8):
        rate = 1 + rng.uniform(-0.06, 0.06)
        idx = np.arange(0, len(x) - 1, rate)
        y = np.interp(idx, np.arange(len(x)), x) * rng.uniform(0.85, 1.0)
        out[i * step:i * step + len(y)] += y
    return out

def main(raw, out):
    soft = load(f"{raw}/9113877471.wav")
    typ = load(f"{raw}/9120299710.wav")
    L = int(0.24 * SR)
    soft = trim(soft, L)
    typ = trim(typ, L)
    soft = np.pad(soft, (0, L - len(soft)))
    typ = np.pad(typ, (0, L - len(typ)))
    body = one_pole(soft, 2500)            # round thock of the soft key
    snap = one_pole(typ, 1800, high=True)  # crisp clack of the typewriter
    blends = {
        # name: (body gain, snap gain, snap decay ms, whole-hit decay ms)
        "A-soft-with-snap": (1.0, 0.45, 25, 120),
        "B-balanced": (1.0, 0.8, 35, 110),
        "C-crisp-typewriter": (0.75, 1.0, 50, 100),
        "D-deep-thock-snap": (1.25, 0.6, 18, 140),
    }
    for i, (name, (bg, sg, sd, hd)) in enumerate(blends.items(), 15):
        hit = (bg * body + sg * snap * env_decay(L, sd)) * env_decay(L, hd)
        if name.startswith("D"):
            hit = one_pole(hit, 4000) + 0.3 * one_pole(hit, 300)
        save(f"{out}/{i}-blend-{name}.wav", hit.copy())
        save(f"{out}/{i}-blend-{name}-run.wav", run(hit))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
