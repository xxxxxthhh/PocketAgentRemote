#!/bin/zsh
# Full build: narration → frames (both layouts) → soundtrack → MP4s in out/.
#   ./make.sh            # everything
#   ./make.sh --no-vo    # reuse out/vo.wav + out/timing.js (visual-only changes)
set -e
cd "${0:A:h}"
export NODE_PATH="${NODE_PATH:-$PWD/node_modules}"
[[ "$1" == "--no-vo" ]] || python3 build_vo.py
for layout in landscape portrait; do
  node render.js --layout $layout --out out/video-$layout.mp4 | tail -1
done
python3 mix.py
for layout in landscape portrait; do
  ffmpeg -y -loglevel error -i out/video-$layout.mp4 -i out/mix.wav -c:v copy \
    -af loudnorm=I=-14:TP=-1.0:LRA=11 -c:a aac -b:a 192k -shortest -movflags +faststart \
    out/PocketAgentRemote-$layout.mp4
  echo "→ out/PocketAgentRemote-$layout.mp4"
done
