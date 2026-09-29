// Renders index.html frame by frame with Playwright and pipes the frames into ffmpeg.
//   node render.js --layout landscape --from 0 --to 44 --out out/sample.mp4
//   node render.js --layout portrait --stills 2,10,30 --out out/stills
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { chromium } = require('playwright');

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1]]);
  return acc;
}, []));
const layout = args.layout || 'landscape';
const fps = +(args.fps || 30);
const W = layout === 'portrait' ? 1080 : 1920;
const H = layout === 'portrait' ? 1920 : 1080;

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  await page.goto('file://' + path.join(__dirname, 'index.html') + '?layout=' + layout);
  await page.evaluate(() => document.fonts.ready);
  const info = await page.evaluate(() => window.VIDEO);
  fs.mkdirSync(path.join(__dirname, 'out'), { recursive: true });
  fs.writeFileSync(path.join(__dirname, 'out', 'cues.json'), JSON.stringify(await page.evaluate(() => window.cuesAll()), null, 1));

  if (args.stills) {
    fs.mkdirSync(args.out, { recursive: true });
    for (const t of args.stills.split(',').map(Number)) {
      await page.evaluate((t) => window.seek(t), t);
      await page.screenshot({ path: path.join(args.out, `${layout}-${t.toFixed(2)}.png`) });
    }
    await browser.close();
    return;
  }

  const from = +(args.from || 0);
  const to = +(args.to || info.total);
  const n = Math.round((to - from) * fps);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', args.out], { stdio: ['pipe', 'inherit', 'inherit'] });
  const started = Date.now();
  for (let i = 0; i < n; i++) {
    await page.evaluate((t) => window.seek(t), from + i / fps);
    const buf = await page.screenshot({ type: 'jpeg', quality: 92 });
    if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once('drain', r));
    if (i % 300 === 0) console.log(`frame ${i}/${n}  ${((Date.now() - started) / 1000).toFixed(0)}s`);
  }
  ff.stdin.end();
  await new Promise((r) => ff.on('close', r));
  await browser.close();
  console.log(`done: ${n} frames → ${args.out}`);
})();
