# 介绍视频（promo）

PocketAgentRemote 的 107 秒介绍视频，横屏 1920×1080 与竖屏 1080×1920 两版，英文解说 + 字幕。
仓库里放的是压缩版 `docs/media/intro-720p.mp4`；完整画质用 `./make.sh` 生成到 `out/`。

整条流水线都是代码，没有剪辑软件、没有素材库：

```text
script.json ──build_vo.py──▶ out/vo.wav + out/timing.js   解说词 → 配音；场景起点对齐到 124 BPM 的半小节
index.html + video.js ──render.js──▶ out/video-*.mp4       动画页逐帧截图（Playwright）→ ffmpeg
out/cues.json ──mix.py──▶ out/mix.wav                      按键音效 + 配乐，都按页面自己的时间点合成
make.sh                                                    以上全部 + 混音 + 响度标准化（−14 LUFS）
```

## 准备（一次）

```bash
cd promo
npm install                               # Playwright 1.61.1
npx playwright install chromium           # 本机没有缓存对应浏览器时才需要
uv venv -p 3.12 .venv && uv pip install -p .venv/bin/python kokoro soundfile   # 配音模型，首次运行会下载约 330 MB
```

另需：`ffmpeg`、Python 3 带 `numpy` / `scipy`（混音用）。

## 生成

```bash
./make.sh            # 全部重做：配音 → 两种比例的画面 → 混音 → out/PocketAgentRemote-{landscape,portrait}.mp4
./make.sh --no-vo    # 只改了画面时用，沿用现有配音与时间轴
```

在 Apple Silicon 上整套约 4 分钟。

## 常改的地方

| 想改什么 | 改哪里 |
|---|---|
| 解说词 | `script.json` 的 `scenes[].lines`；画面按新配音的实际时长自动对齐 |
| 配音音色 / 语速 | `script.json` 的 `voice`（Kokoro 音色，如 `af_heart`、`af_bella`、`am_michael`、`am_puck`）/ `speed`；`python3 build_vo.py am_puck` 可临时试听 |
| 不装 Kokoro | `script.json` 的 `engine` 改成 `"say"`，用 macOS 自带语音（明显更机械） |
| 某个词读错 | `build_vo.py` 的 `SPOKEN` 表（按读音替换），或 Kokoro 的 `[词](/音标/)` 写法 |
| 画面、布局、动效 | `video.js`，每个场景一个对象；`?layout=portrait` 切竖屏，两种布局在同一处分支 |
| 配乐 / 音效 | `mix.py`：`track()` 是鼓 + 贝斯 + 方波琶音，`sfx()` 是每个键的 8-bit 音效 |
| 单帧预览 | `node render.js --layout portrait --stills 12,48 --out out/stills` |

在浏览器里直接打开 `index.html?t=48&layout=portrait` 也能看某一帧（需先跑过一次 `build_vo.py` 生成 `out/timing.js`）。

## 设计约定

- **每一帧都是 `seek(t)` 的纯函数**：没有定时器、没有 CSS transition，所以逐帧截图和实时播放完全一致，改哪帧重渲哪帧。
- **界面按真实参数还原**：浮层宽 420、圆角 16、行高 54、行字号 26，屏幕提示 520×64；文字全部取自源码里的英文原文
  （`New Chat`、`↑↓ Select    A Run    B Close`、`Switch App`、`Blocked: …`）。App 改了文案，这里要跟着改。
- **手柄是照产品图画的矢量版**，不含厂商宣传图；Codex / Claude / 微信等只用色块 + 字母示意，不用它们的图标。
- **全部声音都是生成的**：配音来自 Kokoro-82M（Apache-2.0），配乐和音效由 `mix.py` 用 numpy 合成，没有需要授权的素材。
