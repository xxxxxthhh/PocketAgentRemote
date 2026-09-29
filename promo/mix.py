"""Soundtrack: narration + chiptune SFX at the page's own cue times + an upbeat synthesized track.

    python3 mix.py [from] [to]      → out/mix.wav (48 kHz stereo)

The track runs on the same beat grid build_vo.py snapped the scenes to (TIMING.bpm), so every
scene cut lands on a beat and gets an impact. Everything is generated: nothing to license.
"""
import json, pathlib, sys, wave
import numpy as np
from scipy.signal import butter, sosfilt

ROOT = pathlib.Path(__file__).parent
OUT = ROOT / "out"
SR = 48000
rng = np.random.default_rng(7)


def read_mono(path):
    with wave.open(str(path)) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def ts(dur):
    return np.arange(int(dur * SR)) / SR


def env(t, attack, decay):
    return np.minimum(1, t / max(attack, 1e-4)) * np.exp(-t / decay)


def filt(x, kind, f, order=2):
    return sosfilt(butter(order, f, btype=kind, fs=SR, output="sos"), x)


def square(freq_t, duty=0.5):
    ph = np.cumsum(freq_t) / SR % 1
    return np.where(ph < duty, 1.0, -1.0)


def saw(freq_t):
    return 2 * (np.cumsum(freq_t) / SR % 1) - 1


def hz(m):
    return 440 * 2 ** ((m - 69) / 12)


def add(buf, at, sig, gain=1.0):
    i = int(at * SR)
    if i >= len(buf) or i + len(sig) <= 0:
        return
    if i < 0:
        sig, i = sig[-i:], 0
    n = min(len(sig), len(buf) - i)
    buf[i:i + n] += sig[:n] * gain


# ---------- drums ----------
def kick():
    t = ts(0.35)
    f = 45 + 110 * np.exp(-t / 0.035)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * env(t, 0.001, 0.16)
    click = filt(rng.standard_normal(len(t)), "high", 3000) * env(t, 0.0003, 0.003) * 0.4
    return body + click


def clap():
    t = ts(0.25)
    n = filt(rng.standard_normal(len(t)), "band", [900, 3200])
    e = np.zeros(len(t))
    for d in (0, 0.012, 0.024):
        e += env(np.maximum(t - d, 0), 0.0005, 0.012) * (t >= d)
    e += env(np.maximum(t - 0.03, 0), 0.001, 0.09) * (t >= 0.03)
    return n * e * 0.8


def hat(open_=False):
    t = ts(0.3 if open_ else 0.06)
    return filt(rng.standard_normal(len(t)), "high", 7500) * env(t, 0.0005, 0.12 if open_ else 0.018)


def crash():
    t = ts(1.6)
    return filt(rng.standard_normal(len(t)), "high", 4000) * env(t, 0.001, 0.45)


def impact():
    t = ts(1.2)
    f = 30 + 70 * np.exp(-t / 0.08)
    sub = np.sin(2 * np.pi * np.cumsum(f) / SR) * env(t, 0.001, 0.45)
    return sub * 0.9 + crash()[: len(t)] * 0.25


def riser(dur):
    t = ts(dur)
    x = rng.standard_normal(len(t))
    out = np.zeros(len(t))
    blocks = 40
    for i in range(blocks):
        s, e = i * len(t) // blocks, (i + 1) * len(t) // blocks
        lo = 400 + 7000 * (i / blocks) ** 2
        out[s:e] = filt(x, "band", [lo, min(lo * 1.6, 20000)])[s:e]
    tone = np.sin(2 * np.pi * np.cumsum(200 + 1400 * (t / dur) ** 2) / SR) * 0.15
    return (out + tone) * (t / dur) ** 2


# ---------- SFX: 8-bit blips that match a retro controller ----------
def blip(f0, f1, dur, duty=0.5, gain=0.22):
    t = ts(dur)
    f = np.where(t < dur * 0.35, f0, f1)
    return square(f, duty) * env(t, 0.001, dur * 0.45) * gain


def sfx(kind, btn=None):
    if kind == "click":
        return {
            "up": blip(988, 1319, 0.08), "down": blip(784, 587, 0.08),
            "left": blip(698, 880, 0.08), "right": blip(880, 1175, 0.08),
            "a": np.concatenate([blip(988, 988, 0.05, 0.25), blip(1319, 1319, 0.2, 0.25)]),
            "b": blip(392, 262, 0.12, 0.5, 0.2),
        }.get(btn, blip(988, 1319, 0.08))
    if kind == "tick":
        return blip(1568, 1568, 0.03, 0.25, 0.12)
    if kind == "pop":
        t = ts(0.14)
        return np.sin(2 * np.pi * np.cumsum(500 + 900 * t / t[-1]) / SR) * env(t, 0.002, 0.04) * 0.3
    if kind == "chime":  # power-up arpeggio
        return np.concatenate([blip(hz(m), hz(m), 0.06, 0.25, 0.18) for m in (72, 76, 79, 84)] + [blip(hz(88), hz(88), 0.3, 0.25, 0.16)])
    if kind == "slam":
        t = ts(0.4)
        thump = np.sin(2 * np.pi * np.cumsum(60 + 120 * np.exp(-t / 0.03)) / SR) * env(t, 0.001, 0.12)
        return thump * 0.55 + filt(rng.standard_normal(len(t)), "band", [1500, 6000]) * env(t, 0.001, 0.05) * 0.25
    if kind == "whoosh":
        t = ts(0.45)
        x = rng.standard_normal(len(t))
        out = np.zeros(len(t))
        for i in range(18):
            s, e = i * len(t) // 18, (i + 1) * len(t) // 18
            lo = 500 + 4000 * i / 18
            out[s:e] = filt(x, "band", [lo, lo * 1.7])[s:e]
        return out * np.sin(np.pi * t / t[-1]) ** 2 * 0.22
    if kind == "impact":
        return impact() * 0.5
    raise ValueError(kind)


# ---------- the track ----------
PROG = [[57, 60, 64, 67], [53, 57, 60, 64], [48, 55, 60, 64], [55, 59, 62, 67]]  # Am7 F C G
ARP = [0, 1, 2, 3, 2, 1, 3, 2, 0, 2, 1, 3, 2, 3, 1, 2]


def track(total, bpm, drops, intro_end):
    """Drums + bass + chiptune arp. `drops` are scene cuts (impact + crash); before `intro_end`
    only the filtered arp and a riser play, so the hook builds into the first cut."""
    beat = 60 / bpm
    n = int(total * SR) + SR
    L = np.zeros(n); R = np.zeros(n)
    drums = np.zeros(n); bass = np.zeros(n); arpL = np.zeros(n); arpR = np.zeros(n)
    K, C, HC, HO = kick(), clap(), hat(), hat(True)
    bars = int(total / (beat * 4)) + 1
    kicks = []
    for bar in range(bars):
        chord = PROG[bar % 4]
        for b in range(4):
            t0 = (bar * 4 + b) * beat
            if t0 >= total:
                break
            full = t0 >= intro_end
            if full:
                add(drums, t0, K, 0.9); kicks.append(t0)
                if b in (1, 3):
                    add(drums, t0, C, 0.45)
                add(drums, t0 + beat / 2, HO, 0.12)
                for s in range(4):
                    if s != 2:
                        add(drums, t0 + s * beat / 4, HC, 0.1 if s else 0.14)
                # Offbeat bass, octave-jumping, the usual pump.
                for s, oct_ in ((0.5, 0), (0.75, 12)):
                    tt = ts(beat / 4 * 0.9)
                    f = np.full(len(tt), hz(chord[0] - 24 + oct_))
                    sig = filt(saw(f) * 0.6 + square(f) * 0.4, "low", 900) * env(tt, 0.002, 0.08)
                    add(bass, t0 + s * beat, sig, 0.32)
            # 16th-note square arp, alternating sides for width.
            for s in range(4):
                idx = ARP[(b * 4 + s) % 16]
                m = chord[idx] + 12
                tt = ts(beat / 4 * 0.95)
                sig = square(np.full(len(tt), hz(m)), 0.25) * env(tt, 0.001, 0.06)
                g = 0.07 if full else 0.05
                if s % 2:
                    add(arpR, t0 + s * beat / 4, sig, g); add(arpL, t0 + s * beat / 4, sig, g * 0.5)
                else:
                    add(arpL, t0 + s * beat / 4, sig, g); add(arpR, t0 + s * beat / 4, sig, g * 0.5)
    # Intro arp sits behind a low-pass that opens as the hook builds.
    cut = int(intro_end * SR)
    for a in (arpL, arpR):
        a[:cut] = filt(a[:cut], "low", 1800)
    # Sidechain: everything melodic ducks under each kick.
    pump = np.ones(n)
    kt = ts(beat)
    shape = 1 - 0.6 * np.exp(-kt / 0.07)
    for k in kicks:
        i = int(k * SR)
        m = min(len(shape), n - i)
        pump[i:i + m] = np.minimum(pump[i:i + m], shape[:m])
    for d in drops:
        add(drums, d, impact(), 0.55)
    add(drums, max(0, intro_end - 2 * beat * 4), riser(2 * beat * 4), 0.3)
    L = drums + (bass + arpL) * pump
    R = drums + (bass + arpR) * pump
    return L[: int(total * SR)], R[: int(total * SR)]


def main():
    timing = json.loads((OUT / "timing.js").read_text().split("=", 1)[1].rstrip().rstrip(";"))
    frm = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
    to = float(sys.argv[2]) if len(sys.argv) > 2 else timing["total"]
    n = int((to - frm) * SR)
    sl = slice(int(frm * SR), int(frm * SR) + n)

    vo = read_mono(OUT / "vo.wav")
    vo = np.pad(vo, (0, max(0, int(to * SR) - len(vo))))[sl]

    fx = np.zeros(int(to * SR) + SR)
    for c in json.loads((OUT / "cues.json").read_text()):
        if c["t"] < to:
            add(fx, c["t"], sfx(c["kind"], c.get("btn")))
    fx = fx[sl]

    scenes = timing["scenes"]
    drops = [s["start"] for s in scenes[1:]]
    mL, mR = track(to, timing["bpm"], drops, intro_end=scenes[1]["start"])
    mL, mR = mL[sl], mR[sl]
    # Duck the track under the voice so the words stay on top, but keep the energy.
    v_env = filt(np.abs(vo), "low", 4, 1)
    v_env = np.clip(v_env / (np.percentile(v_env, 99) + 1e-9), 0, 1)
    duck = 1 - 0.5 * v_env
    t = np.arange(n) / SR
    fade = np.minimum(1, (to - frm - t) / 1.5)
    mL, mR = mL * duck * fade, mR * duck * fade

    # Voice to a fixed speech level; the track sits ~9 dB under it while someone is talking and
    # comes back up between lines.
    speech = np.abs(vo) > 0.02
    vo_rms = np.sqrt(np.mean(vo[speech] ** 2)) if speech.any() else 1
    voice = vo * (10 ** (-14 / 20) / vo_rms)
    left, right = voice + fx + mL * 0.45, voice + fx + mR * 0.45
    peak = max(np.abs(left).max(), np.abs(right).max())
    if peak > 0.97:
        left, right = left / peak * 0.97, right / peak * 0.97
    st = np.stack([left, right], axis=1)
    with wave.open(str(OUT / "mix.wav"), "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(st, -1, 1) * 32767).astype(np.int16).tobytes())
    print(f"mix.wav {to - frm:.2f}s")


main()
