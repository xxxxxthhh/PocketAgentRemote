"""Kokoro TTS worker, run inside promo/.venv. Reads a JSON job list, writes one 24 kHz WAV per line.

    .venv/bin/python tts_kokoro.py jobs.json      # [{"text", "path", "voice", "speed"}]
"""
import json, sys, warnings
warnings.filterwarnings("ignore")
import numpy as np
import soundfile as sf
from kokoro import KPipeline

pipe = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
for job in json.load(open(sys.argv[1])):
    audio = [np.asarray(a) for _, _, a in pipe(job["text"], voice=job["voice"], speed=job.get("speed", 1.0))]
    sf.write(job["path"], np.concatenate(audio), 24000)
    print("ok", job["path"], flush=True)
