"""Narration: one clip per line, measured, laid on one track, scenes snapped to the music's beat.

    python3 build_vo.py            # engine/voice from script.json (kokoro by default)
    python3 build_vo.py am_puck    # try another voice

Writes out/vo.wav (48 kHz mono) and out/timing.js (window.TIMING). Scene starts are rounded up
to the next half bar of `bpm`, so every cut lands on the beat mix.py plays; animations cue off
where the sentences actually land instead of guessed durations.
"""
import json, math, re, subprocess, wave, pathlib, sys
import numpy as np
from scipy.signal import resample_poly

ROOT = pathlib.Path(__file__).parent
OUT = ROOT / "out"
SR = 48000
SPOKEN = {"PocketAgentRemote": "Pocket Agent Remote", "D-pad": "D pad"}


def spoken(text, engine="say"):
    for k, v in SPOKEN.items():
        text = text.replace(k, v)
    if engine == "kokoro":
        # A lone capital A is the button, said "ay" — Kokoro otherwise reads it as the article.
        text = re.sub(r"\bA\b", "[A](/ˈA/)", text)
    return text


def load(path):
    with wave.open(str(path)) as w:
        sr = w.getframerate()
        data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    if sr != SR:
        data = resample_poly(data, SR, sr).astype(np.float32)
    # Engines pad both ends with silence; trim so cue times mean "the word starts here".
    idx = np.where(np.abs(data) > 0.01)[0]
    return data[max(0, idx[0] - 240): idx[-1] + 2400] if len(idx) else data


def synthesize(s, voice, jobs):
    if s["engine"] == "kokoro":
        spec = [{"text": spoken(t, "kokoro"), "path": str(p), "voice": voice, "speed": s["speed"]} for t, p in jobs]
        (OUT / "vo" / "jobs.json").write_text(json.dumps(spec))
        subprocess.run([str(ROOT / ".venv" / "bin" / "python"), str(ROOT / "tts_kokoro.py"), str(OUT / "vo" / "jobs.json")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        for t, p in jobs:
            subprocess.run(["say", "-v", voice, "-r", str(s["rate"]), "--file-format=WAVE",
                            f"--data-format=LEI16@{SR}", "-o", str(p), spoken(t)], check=True)


def main():
    s = json.loads((ROOT / "script.json").read_text())
    voice = sys.argv[1] if len(sys.argv) > 1 else (s["voice"] if s["engine"] == "kokoro" else s["sayVoice"])
    (OUT / "vo").mkdir(parents=True, exist_ok=True)
    jobs = [(text, OUT / "vo" / f"{sc['id']}-{i}.wav") for sc in s["scenes"] for i, text in enumerate(sc["lines"])]
    synthesize(s, voice, jobs)
    clips = {str(p): load(p) for _, p in jobs}

    beat = 60 / s["bpm"]
    half_bar = beat * 2
    snap = lambda x: math.ceil(x / half_bar - 1e-6) * half_bar
    t = 0.0
    scenes, pieces = [], []
    for sc in s["scenes"]:
        start = snap(t)
        cur = start + sc.get("lead", 0.3)
        lines = []
        for i, text in enumerate(sc["lines"]):
            if sc.get("onBeat"):
                cur = snap(cur)
            audio = clips[str(OUT / "vo" / f"{sc['id']}-{i}.wav")]
            dur = len(audio) / SR
            lines.append({"text": text, "start": round(cur, 3), "end": round(cur + dur, 3)})
            pieces.append((cur, audio))
            cur += dur + s["lineGap"]
        end = snap(cur - s["lineGap"] + s["sceneTail"])
        scenes.append({"id": sc["id"], "start": round(start, 3), "end": round(end, 3), "lines": lines})
        t = end
    total = t + beat * 4
    track = np.zeros(int(total * SR) + SR, dtype=np.float32)
    for at, a in pieces:
        i = int(at * SR)
        track[i:i + len(a)] += a
    with wave.open(str(OUT / "vo.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(track, -1, 1) * 32767).astype(np.int16).tobytes())
    timing = {"total": round(total, 3), "bpm": s["bpm"], "scenes": scenes}
    (OUT / "timing.js").write_text("window.TIMING = " + json.dumps(timing, indent=1) + ";\n")
    for sc in scenes:
        print(f"{sc['id']:9s} {sc['start']:6.2f} → {sc['end']:6.2f}  ({sc['end']-sc['start']:.1f}s)")
    print("total", round(total, 2), "voice", voice)


main()
