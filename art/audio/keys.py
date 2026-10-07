#!/usr/bin/env python3
"""art/audio/keys.py - synthesize the CARDIO keyboard-floor step sounds (mechanical key presses).

usage: python3 art/audio/keys.py [OUT_DIR]      (default art/out/audio; needs numpy, ffmpeg for .flac)

Writes key_click_1..4 (normal keys) and key_space (spacebar) as 44.1 kHz mono 16-bit .wav plus lossless .flac
(the uploaded file). Each press is one downstroke, no release, starting on the first sample:
  click  a ~1 ms high-passed noise tick + a short metallic ping (the switch leaf)
  clack  band-passed noise a few ms later (the keycap bottoming out on the plate)
  thock  damped low sines with a small pitch drop (keycap and case body)
The spacebar is lower and longer, with a second faint stabilizer rattle. Fixed seeds: reruns are byte-identical.
"""
import os
import subprocess
import sys
import wave

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
GAME_DIR = os.path.dirname(os.path.dirname(HERE))
TARGET_RMS_DB = -16.0  # over the first 45 ms, so the variants sound equally loud


def biquad(x, kind, f0, q):
    """RBJ cookbook biquad (bandpass constant-0-dB-peak, highpass or lowpass)."""
    w = 2 * np.pi * f0 / SR
    alpha = np.sin(w) / (2 * q)
    c = np.cos(w)
    if kind == "bp":
        b = [alpha, 0.0, -alpha]
    elif kind == "hp":
        b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]
    else:
        b = [(1 - c) / 2, 1 - c, (1 - c) / 2]
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


def env(n, start, attack, tau):
    t = (np.arange(n) - start) / SR
    e = np.where(t < 0, 0.0, np.exp(-np.maximum(t, 0) / tau))
    if attack > 0:
        e *= np.clip(t / attack, 0, 1)
    return e


def norm(x):
    return x / (np.abs(x).max() + 1e-12)


def press(seed, length, click_hz, clack_hz, clack_q, clack_at, thock_hz, thock_tau, mix, rattle=None):
    rng = np.random.default_rng(seed)
    n = int(SR * length)
    t = np.arange(n) / SR
    # click: high noise tick + metallic ping
    tick = biquad(rng.standard_normal(n), "hp", 3500, 0.7) * env(n, 0, 0.0002, 0.0007)
    ping = np.sin(2 * np.pi * click_hz * t + rng.uniform(0, 6.28)) * env(n, 0, 0.0003, 0.004)
    click = norm(tick) + 0.35 * norm(ping)
    # clack: plate bottom-out, band-passed noise
    s = int(SR * clack_at)
    clack = norm(biquad(rng.standard_normal(n), "bp", clack_hz, clack_q) * env(n, s, 0.0006, 0.009))
    clack += 0.4 * norm(biquad(rng.standard_normal(n), "bp", clack_hz * 2.1, 2.5) * env(n, s, 0.0004, 0.004))
    # thock: damped body sines with a little downward glide
    body = np.zeros(n)
    for k, (mult, amp, tau_mul) in enumerate(((1.0, 1.0, 1.0), (2.37, 0.45, 0.55), (3.9, 0.2, 0.35))):
        f = thock_hz * mult * (1 + 0.06 * np.exp(-t / 0.01))
        phase = 2 * np.pi * np.cumsum(f) / SR
        body += amp * np.sin(phase) * env(n, s, 0.0015, thock_tau * tau_mul)
    body = norm(body)
    out = mix[0] * click + mix[1] * clack + mix[2] * body
    if rattle:  # spacebar stabilizer wire: a faint second clack
        r_at, r_hz, r_amp = rattle
        r = int(SR * r_at)
        out += r_amp * norm(biquad(rng.standard_normal(n), "bp", r_hz, 3.0) * env(n, r, 0.0005, 0.006))
    out = biquad(out, "hp", 70, 0.7)  # no DC / sub rumble
    fade = int(SR * 0.012)
    out[-fade:] *= np.linspace(1, 0, fade) ** 2
    out = norm(out)
    rms = np.sqrt((out[: int(SR * 0.045)] ** 2).mean())
    return out * min(0.89, 10 ** (TARGET_RMS_DB / 20) / rms)  # even loudness, peak at most about -1 dBFS


VARIANTS = {
    # name: press(...) args. Small spreads in pitch / timing / balance keep rapid steps from sounding robotic.
    "key_click_1": dict(seed=11, length=0.11, click_hz=5200, clack_hz=2300, clack_q=1.6, clack_at=0.004,
                        thock_hz=320, thock_tau=0.022, mix=(0.6, 0.85, 0.7)),
    "key_click_2": dict(seed=23, length=0.10, click_hz=5900, clack_hz=2600, clack_q=1.8, clack_at=0.0035,
                        thock_hz=350, thock_tau=0.019, mix=(0.65, 0.9, 0.6)),
    "key_click_3": dict(seed=37, length=0.12, click_hz=4700, clack_hz=2050, clack_q=1.4, clack_at=0.005,
                        thock_hz=290, thock_tau=0.026, mix=(0.55, 0.8, 0.8)),
    "key_click_4": dict(seed=41, length=0.105, click_hz=5500, clack_hz=2450, clack_q=1.7, clack_at=0.0042,
                        thock_hz=335, thock_tau=0.021, mix=(0.62, 0.88, 0.65)),
    "key_space": dict(seed=53, length=0.17, click_hz=3800, clack_hz=1300, clack_q=1.2, clack_at=0.006,
                      thock_hz=165, thock_tau=0.05, mix=(0.4, 0.7, 0.9), rattle=(0.017, 2600, 0.22)),
}


def write_wav(path, x):
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(GAME_DIR, "art", "out", "audio")
    os.makedirs(out_dir, exist_ok=True)
    for name, kw in VARIANTS.items():
        x = press(**kw)
        wav = os.path.join(out_dir, name + ".wav")
        write_wav(wav, x)
        flac = os.path.join(out_dir, name + ".flac")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-map_metadata", "-1", "-fflags", "+bitexact",
                        "-flags:a", "+bitexact", "-c:a", "flac", flac], check=True)
        print(f"{name}: {len(x) / SR * 1000:.0f} ms, peak {20 * np.log10(np.abs(x).max()):.1f} dBFS -> {flac}")


if __name__ == "__main__":
    main()
