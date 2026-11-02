"""Postbox's own new-mail sounds, made from nothing but sine waves and noise.

Every sound here is synthesized: additive sines, a little FM, and filtered
noise, each under an envelope. No samples from anywhere, so the files are
Postbox's own to ship under its licence.

Writes, from the repository root:
  Media/Sounds/<name>.ogg        what the addon plays (Vorbis, mono, 44.1 kHz)
  .dev/design/sounds/<name>.wav  the same, 16-bit, to listen to outside the game

Needs numpy and soundfile (soundfile bundles libsndfile, with Vorbis). Keep
them out of the system Python, in a virtual environment:
  py -3.12 -m venv .dev/tools/sound-venv
  .dev/tools/sound-venv/Scripts/python -m pip install numpy soundfile
  .dev/tools/sound-venv/Scripts/python .dev/tools/gen-sounds.py [--wav-dir DIR]

Loudness: each sound is brought to -16 LUFS (ITU-R BS.1770, K-weighted,
gated), unless that would take its peak over -3 dBFS, in which case the peak
decides. Short, soft sounds are peak-bound and land a little under -16; the
printout says where each one ended up. Seeded noise: the same files every run.
"""

import argparse
import os
import sys

import numpy as np
import soundfile as sf

SR = 44100
TARGET_LUFS = -16.0
PEAK_DBFS = -3.0
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


# ------------------------------------------------------------- building blocks

def timeline(seconds):
    return np.arange(int(round(seconds * SR))) / SR


def env_ad(t, attack, decay, start=0.0):
    """A soft attack (raised cosine) and an exponential decay (time constant
    `decay`), starting at `start`; zero before it."""
    x = t - start
    e = np.zeros_like(t)
    on = x >= 0
    xa = x[on]
    rise = np.where(xa < attack, 0.5 - 0.5 * np.cos(np.pi * np.clip(xa / attack, 0, 1)), 1.0)
    fall = np.exp(-np.maximum(xa - attack, 0) / decay)
    e[on] = rise * fall
    return e


def fade_out(y, seconds):
    n = int(seconds * SR)
    if n > 0:
        y[-n:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, n))
    return y


def one_pole_lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def biquad(x, b, a):
    b0, b1, b2 = b
    a0, a1, a2 = a
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        out = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, v
        y2, y1 = y1, out
        y[i] = out
    return y


def bandpass(x, centre, q):
    w = 2 * np.pi * centre / SR
    alpha = np.sin(w) / (2 * q)
    return biquad(x, (alpha, 0.0, -alpha), (1 + alpha, -2 * np.cos(w), 1 - alpha))


def partials(t, f0, spec, start=0.0, attack=0.004):
    """Additive tone: spec is [(ratio, gain, decay seconds), ...]."""
    y = np.zeros_like(t)
    x = np.maximum(t - start, 0)
    for ratio, gain, decay in spec:
        y += gain * np.sin(2 * np.pi * f0 * ratio * x) * env_ad(t, attack, decay, start)
    return y


# ------------------------------------------------------------- the sounds

def soft_chime(rng):
    """Two soft sine notes a fourth apart, E5 then A5, each with a quiet
    octave and a quieter twelfth that die away faster than the note."""
    t = timeline(0.78)
    spec = [(1.0, 1.0, 0.26), (2.0, 0.22, 0.12), (3.0, 0.06, 0.07)]
    y = partials(t, 659.26, spec, 0.0, 0.006)
    y += 0.9 * partials(t, 880.0, spec, 0.13, 0.006)
    return fade_out(one_pole_lowpass(y, 5000), 0.08)


def envelope(rng):
    """Paper: a slide of band-limited noise, grainy (the fibres catching),
    then the flap settling with a softer, lower whisper and a faint
    cardboard-like thump under it."""
    t = timeline(0.42)
    noise = rng.standard_normal(len(t))
    slide = bandpass(noise, 1800, 0.9) * env_ad(t, 0.035, 0.05, 0.0)
    grain = 0.6 + 0.4 * np.abs(one_pole_lowpass(rng.standard_normal(len(t)), 90)) * 6
    slide *= np.clip(grain, 0, 1.6)
    flap = 0.55 * bandpass(noise[::-1].copy(), 1100, 1.1) * env_ad(t, 0.012, 0.045, 0.16)
    thump = 0.35 * np.sin(2 * np.pi * 150 * np.maximum(t - 0.16, 0)) * env_ad(t, 0.003, 0.03, 0.16)
    y = slide + flap + thump
    # Noise is all peaks: a gentle saturation evens them out, so the sound
    # is not left far quieter than the others at the same peak.
    y = np.tanh(2.5 * y / np.max(np.abs(y)))
    return fade_out(one_pole_lowpass(one_pole_lowpass(y, 4000), 4000), 0.06)


def small_bell(rng):
    """A small FM bell (Chowning's inharmonic ratio), its brightness dying
    away faster than its body, struck lightly with a breath of noise."""
    t = timeline(0.8)
    fc, ratio = 1046.5, 1.4
    index = 1.6 * np.exp(-t / 0.12)
    body = np.sin(2 * np.pi * fc * t + index * np.sin(2 * np.pi * fc * ratio * t))
    y = body * env_ad(t, 0.003, 0.28)
    y += 0.25 * np.sin(2 * np.pi * fc * 0.5 * t) * env_ad(t, 0.004, 0.35)
    strike = bandpass(rng.standard_normal(len(t)), 4000, 1.5) * env_ad(t, 0.001, 0.008)
    y += 0.15 * strike
    return fade_out(one_pole_lowpass(y, 7000), 0.12)


def wood_tock(rng):
    """Two taps on a small wooden block: inharmonic body modes that die in
    tens of milliseconds, a pitch that drops a touch as each tap settles,
    the second a step higher and a little softer."""
    t = timeline(0.45)

    def tap(f0, start, gain):
        x = np.maximum(t - start, 0)
        sweep = 1 + 0.04 * np.exp(-x / 0.01)
        modes = [(1.0, 1.0, 0.045), (2.72, 0.32, 0.018), (4.1, 0.12, 0.01)]
        y = np.zeros_like(t)
        for ratio, g, decay in modes:
            phase = 2 * np.pi * f0 * ratio * np.cumsum(sweep) / SR
            phase -= phase[int(start * SR)] if start > 0 else 0
            y += g * np.sin(phase) * env_ad(t, 0.0015, decay, start)
        click = bandpass(rng.standard_normal(len(t)), 2500, 1.2) * env_ad(t, 0.0005, 0.004, start)
        return gain * (y + 0.12 * click)

    y = tap(620, 0.0, 1.0) + tap(830, 0.14, 0.85)
    return fade_out(one_pole_lowpass(y, 5000), 0.05)


SOUNDS = [
    ("soft-chime", soft_chime),
    ("envelope", envelope),
    ("small-bell", small_bell),
    ("wood-tock", wood_tock),
]


# ------------------------------------------------------------- loudness

def k_weight(x):
    # BS.1770 K-weighting at 44.1 kHz: a +4 dB high shelf from about 1.5 kHz
    # and the RLB high-pass at 38 Hz, as cookbook biquads (pyloudnorm's way).
    gain, fc, q = 4.0, 1500.0, 1 / np.sqrt(2)
    a = 10 ** (gain / 40)
    w = 2 * np.pi * fc / SR
    cw, alpha = np.cos(w), np.sin(w) / (2 * q)
    shelf_b = (a * ((a + 1) + (a - 1) * cw + 2 * np.sqrt(a) * alpha),
               -2 * a * ((a - 1) + (a + 1) * cw),
               a * ((a + 1) + (a - 1) * cw - 2 * np.sqrt(a) * alpha))
    shelf_a = ((a + 1) - (a - 1) * cw + 2 * np.sqrt(a) * alpha,
               2 * ((a - 1) - (a + 1) * cw),
               (a + 1) - (a - 1) * cw - 2 * np.sqrt(a) * alpha)
    fc, q = 38.0, 0.5
    w = 2 * np.pi * fc / SR
    cw, alpha = np.cos(w), np.sin(w) / (2 * q)
    hp_b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
    hp_a = (1 + alpha, -2 * cw, 1 - alpha)
    return biquad(biquad(x, shelf_b, shelf_a), hp_b, hp_a)


def lufs(x):
    """Integrated loudness, gated. A sound shorter than one 400 ms block is
    measured as one block over its own length padded to 400 ms."""
    y = k_weight(x)
    block, hop = int(0.4 * SR), int(0.1 * SR)
    if len(y) < block:
        y = np.concatenate([y, np.zeros(block - len(y))])
    powers = np.array([np.mean(y[i:i + block] ** 2) for i in range(0, len(y) - block + 1, hop)])
    loud = -0.691 + 10 * np.log10(np.maximum(powers, 1e-12))
    gated = powers[loud > -70]
    if len(gated) == 0:
        return -70.0
    rel = -0.691 + 10 * np.log10(np.mean(gated)) - 10
    gated = powers[(loud > -70) & (loud > rel)]
    return -0.691 + 10 * np.log10(np.mean(gated))


def normalise(y):
    y = y - np.mean(y)
    peak = np.max(np.abs(y))
    y = y / peak
    by_loudness = TARGET_LUFS - lufs(y)
    by_peak = PEAK_DBFS  # the peak is 0 dBFS now
    gain_db = min(by_loudness, by_peak)
    return y * 10 ** (gain_db / 20)


# ------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--wav-dir", default=os.path.join(ROOT, ".dev", "design", "sounds"))
    parser.add_argument("--ogg-dir", default=os.path.join(ROOT, "Media", "Sounds"))
    args = parser.parse_args()
    os.makedirs(args.wav_dir, exist_ok=True)
    os.makedirs(args.ogg_dir, exist_ok=True)

    for name, make in SOUNDS:
        rng = np.random.default_rng(sum(map(ord, name)))
        y = normalise(make(rng)).astype(np.float32)
        wav = os.path.join(args.wav_dir, name + ".wav")
        ogg = os.path.join(args.ogg_dir, name + ".ogg")
        sf.write(wav, y, SR, subtype="PCM_16")
        sf.write(ogg, y, SR, format="OGG", subtype="VORBIS")
        back, _ = sf.read(ogg, dtype="float32")
        peak = 20 * np.log10(np.max(np.abs(y)))
        print(f"{name:11s} {len(y) / SR:.2f} s  {lufs(y.astype(np.float64)):6.1f} LUFS  "
              f"peak {peak:5.1f} dBFS  ogg {os.path.getsize(ogg):6d} B ({20 * np.log10(np.max(np.abs(back))):5.1f} dBFS decoded)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
