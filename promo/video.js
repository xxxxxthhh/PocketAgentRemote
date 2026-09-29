// PocketAgentRemote intro video. Everything on screen is a pure function of `seek(t)`: no timers,
// no CSS transitions, so every frame renders the same way twice and the recorder can step freely.
(() => {
  const Q = new URLSearchParams(location.search);
  const PORTRAIT = Q.get('layout') === 'portrait';
  const W = PORTRAIT ? 1080 : 1920;
  const H = PORTRAIT ? 1920 : 1080;
  const TIMING = window.TIMING;
  document.body.classList.add(PORTRAIT ? 'portrait' : 'landscape');
  const stage = document.getElementById('stage');
  stage.style.width = W + 'px';
  stage.style.height = H + 'px';
  const caption = document.getElementById('caption');
  const sceneLayer = document.getElementById('scenes');
  const glow = document.getElementById('glow');
  const grid = document.getElementById('grid');
  const flash = document.getElementById('flash');
  const stripes = document.getElementById('stripes');
  const BEAT = 60 / TIMING.bpm;

  // ---------- math ----------
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const E = {
    lin: (t) => t,
    out: (t) => 1 - Math.pow(1 - t, 3),
    inOut: (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
    back: (t) => 1 + 2.70158 * Math.pow(t - 1, 3) + 1.70158 * Math.pow(t - 1, 2),
  };
  const prog = (t, a, b) => clamp((t - a) / (b - a));
  const tw = (t, a, b, from, to, e = E.out) => from + (to - from) * e(prog(t, a, b));
  const lerp = (a, b, k) => a + (b - a) * k;
  // In over `a…a+d`, out over `b…b+d`.
  const window01 = (t, a, b, d = 0.3) => Math.min(E.out(prog(t, a, a + d)), 1 - E.out(prog(t, b, b + d)));

  // ---------- DOM ----------
  function el(tag, cls, parent, html) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    (parent || stage).appendChild(e);
    return e;
  }
  // Centre `e` on (x, y).
  function place(e, x, y, s = 1, o = 1, extra = '') {
    e.style.transform = `translate(${x}px, ${y}px) translate(-50%, -50%) scale(${s}) ${extra}`;
    e.style.opacity = o;
    e.style.visibility = o <= 0.001 ? 'hidden' : 'visible';
  }
  const size = (e, w, h) => { e.style.width = w + 'px'; if (h != null) e.style.height = h + 'px'; };

  // ---------- presses ----------
  // A press is { btn, t, dur }. State is 0…1 per button: quick in, hold, quick out.
  function pressState(presses, t) {
    const s = {};
    for (const p of presses) {
      const a = Math.min(prog(t, p.t, p.t + 0.05), 1 - prog(t, p.t + p.dur, p.t + p.dur + 0.1));
      s[p.btn] = Math.max(s[p.btn] || 0, a);
    }
    return s;
  }
  const tap = (btn, t, dur = 0.14) => ({ btn, t, dur });

  // ---------- the controller (IINE Gamebrick, drawn from the product photos) ----------
  let ctrlSeq = 0;
  function controllerSVG(id) {
    const arm = { up: 'M116 62h68v64h-68z', down: 'M116 194h68v64h-68z', left: 'M52 126h64v68h-64z', right: 'M184 126h64v68h-64z' };
    const arrow = {
      up: 'M150 76l-20 26h40z', down: 'M150 244l-20-26h40z', left: 'M66 160l26-20v40z', right: 'M234 160l-26-20v40z',
    };
    const centre = { up: [150, 94], down: [150, 226], left: [84, 160], right: [216, 160], a: [370, 104], b: [370, 236] };
    const shocks = Object.keys(centre).map((k) =>
      `<circle class="s-${k}" cx="${centre[k][0]}" cy="${centre[k][1]}" r="40" fill="none" stroke="#fff3c4" stroke-width="6" opacity="0"/>`).join('');
    const glowArms = Object.keys(arm).map((k) =>
      `<path class="g-${k}" d="${arm[k]}" fill="#ffd778" opacity="0" filter="url(#${id}-soft)"/>`).join('');
    const arrows = Object.keys(arrow).map((k) =>
      `<path class="b-${k}" d="${arrow[k]}" fill="#3a3332"/>`).join('');
    const ab = (k, cy, label, ly) => `
      <rect x="318" y="${cy - 52}" width="104" height="104" rx="14" fill="#7a1518"/>
      <rect x="324" y="${cy - 46}" width="92" height="92" rx="11" fill="#8e1b1f"/>
      <circle class="g-${k}" cx="370" cy="${cy}" r="47" fill="none" stroke="#ffd778" stroke-width="7" opacity="0" filter="url(#${id}-soft)"/>
      <g class="b-${k}">
        <circle cx="370" cy="${cy + 4}" r="36" fill="#050404"/>
        <circle cx="370" cy="${cy}" r="36" fill="url(#${id}-btn)"/>
        <ellipse cx="358" cy="${cy - 14}" rx="14" ry="8" fill="#ffffff" opacity="0.08"/>
      </g>
      <text x="446" y="${ly}" font-family="-apple-system, sans-serif" font-weight="800" font-size="32" fill="#4a1414">${label}</text>`;
    return `
<svg viewBox="-12 -12 514 364" width="100%" style="display:block;overflow:visible">
  <defs>
    <linearGradient id="${id}-body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#c8302f"/><stop offset="1" stop-color="#861a1d"/></linearGradient>
    <linearGradient id="${id}-face" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ecce80"/><stop offset="1" stop-color="#c49a46"/></linearGradient>
    <radialGradient id="${id}-btn" cx=".38" cy=".32" r=".75"><stop offset="0" stop-color="#3b3434"/><stop offset="1" stop-color="#0d0b0b"/></radialGradient>
    <filter id="${id}-soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5"/></filter>
    <filter id="${id}-shadow" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="22" stdDeviation="22" flood-color="#000" flood-opacity=".55"/></filter>
  </defs>
  <g filter="url(#${id}-shadow)"><rect width="490" height="340" rx="34" fill="url(#${id}-body)"/></g>
  <rect x="1" y="1" width="488" height="338" rx="33" fill="none" stroke="#ffffff" stroke-opacity=".14" stroke-width="2"/>
  <rect x="16" y="16" width="458" height="308" rx="18" fill="url(#${id}-face)"/>
  <rect x="16" y="262" width="458" height="4" fill="#8c1a1e"/>
  <rect x="16" y="272" width="458" height="4" fill="#8c1a1e"/>
  <rect x="40" y="48" width="220" height="224" rx="24" fill="#241816"/>
  <rect x="46" y="54" width="208" height="212" rx="20" fill="#171212"/>
  <path d="M116 62h68v64h64v68h-64v64h-68v-64h-64v-68h64z" fill="#0c0a0a" transform="translate(0 4)"/>
  <path d="M116 62h68v64h64v68h-64v64h-68v-64h-64v-68h64z" fill="#151212" stroke="#2e2828" stroke-width="2"/>
  ${glowArms}
  ${arrows}
  <circle cx="150" cy="160" r="17" fill="#0a0808" stroke="#2c2626" stroke-width="2"/>
  ${ab('a', 104, 'A', 150)}
  ${ab('b', 236, 'B', 300)}
  <circle class="ring" cx="370" cy="104" r="54" fill="none" stroke="#f1d58c" stroke-width="7" stroke-linecap="round"
          transform="rotate(-90 370 104)" stroke-dasharray="339.3" stroke-dashoffset="339.3" opacity="0"/>
  <circle class="ring-b" cx="370" cy="236" r="54" fill="none" stroke="#f1d58c" stroke-width="7" stroke-linecap="round"
          transform="rotate(-90 370 236)" stroke-dasharray="339.3" stroke-dashoffset="339.3" opacity="0"/>
  ${shocks}
  <text x="44" y="306" font-family="-apple-system, sans-serif" font-weight="700" font-size="15" letter-spacing="2" fill="#7a1518" opacity=".7">PLAY MY WAY</text>
</svg>`;
  }
  function makeController(parent) {
    const id = 'c' + ctrlSeq++;
    const e = el('div', 'abs', parent, controllerSVG(id));
    const q = (s) => e.querySelector(s);
    const btns = ['up', 'down', 'left', 'right', 'a', 'b'];
    const parts = Object.fromEntries(btns.map((b) => [b, q('.b-' + b)]));
    const glows = Object.fromEntries(btns.map((b) => [b, q('.g-' + b)]));
    const ring = q('.ring');
    const ringB = q('.ring-b');
    const shock = Object.fromEntries(btns.map((b) => [b, q('.s-' + b)]));
    return {
      el: e,
      // One call per frame: glow + press depth from `presses`, a shockwave off each press start.
      update(presses, t, holdA = 0, holdB = 0) {
        this.set(pressState(presses, t), holdA, holdB);
        const since = {};
        for (const p of presses) if (t >= p.t && (since[p.btn] == null || t - p.t < since[p.btn])) since[p.btn] = t - p.t;
        for (const b of btns) {
          const k = since[b] == null ? 1 : clamp(since[b] / 0.4);
          const big = b === 'a' || b === 'b' ? 1 : 0.7;
          shock[b].setAttribute('r', (lerp(38, 120, E.out(k)) * big).toFixed(1));
          shock[b].setAttribute('opacity', (k >= 1 ? 0 : (1 - k) * 0.9).toFixed(3));
          shock[b].setAttribute('stroke-width', lerp(8, 1, k).toFixed(2));
        }
      },
      set(state, holdA = 0, holdB = 0) {
        for (const b of btns) {
          const a = state[b] || 0;
          glows[b].setAttribute('opacity', a.toFixed(3));
          if (b === 'a' || b === 'b') parts[b].setAttribute('transform', `translate(0 ${(a * 4).toFixed(2)})`);
          else parts[b].setAttribute('fill', a > 0.01 ? '#f1d58c' : '#3a3332');
        }
        ring.setAttribute('opacity', holdA > 0 ? 1 : 0);
        ring.setAttribute('stroke-dashoffset', (339.3 * (1 - holdA)).toFixed(1));
        ringB.setAttribute('opacity', holdB > 0 ? 1 : 0);
        ringB.setAttribute('stroke-dashoffset', (339.3 * (1 - holdB)).toFixed(1));
      },
    };
  }

  function makeWindow(parent, title) {
    const e = el('div', 'abs win', parent, `<div class="bar"><span></span><span></span><span></span><em>${title}</em></div><div class="body"></div>`);
    return { el: e, body: e.querySelector('.body'), title: e.querySelector('em') };
  }

  // ---------- scenes ----------
  // Each scene: build(root) once; cues(sc) → presses and sounds; render(t, sc) with global t.
  const SCENES = {};
  const L = (sc, i) => sc.lines[i].start;
  const LE = (sc, i) => sc.lines[i].end;

  function sectionTag(root, n, text) {
    const e = el('div', 'abs tag', root, `<b>${n}</b>${text}`);
    return (t, sc) => {
      const o = window01(t, sc.start + 0.1, sc.end - 0.4);
      e.style.transform = `translate(${PORTRAIT ? 64 : 88}px, ${PORTRAIT ? 110 : 76}px) translateX(${(1 - o) * -20}px)`;
      e.style.opacity = o;
    };
  }

  // Word-by-word pop: each word rises and overshoots into place, staggered.
  function kinetic(e, text, t, t0, { stagger = 0.07, dur = 0.38, rise = 60 } = {}) {
    if (e._text !== text) {
      e.innerHTML = text.split(' ').map((w, i, all) =>
        `<span style="display:inline-block;${i < all.length - 1 ? 'margin-right:0.26em' : ''}">${w}</span>`).join('');
      e._text = text;
      e._spans = [...e.children];
    }
    e._spans.forEach((sp, i) => {
      const a = t0 + i * stagger;
      const k = prog(t, a, a + dur);
      sp.style.transform = `translateY(${((1 - E.out(k)) * rise).toFixed(1)}px) scale(${lerp(1.4, 1, E.back(k)).toFixed(3)})`;
      sp.style.opacity = clamp(k * 3).toFixed(3);
    });
  }

  function headline(root, fontSize) {
    const e = el('div', 'abs headline', root);
    e.style.fontSize = fontSize + 'px';
    return e;
  }

  // 1 — Hook
  SCENES.hook = {
    hideCaption: () => true,
    build(root) {
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 640 : 560);
      this.codex = el('div', 'abs chip', root, '<i style="background:#e9e6e1"></i>Codex');
      this.claude = el('div', 'abs chip', root, '<i style="background:#d97757"></i>Claude');
      this.head = headline(root, PORTRAIT ? 120 : 112);
    },
    cues(sc) {
      const order = ['up', 'right', 'down', 'left', 'a', 'b'];
      return order.map((b, i) => tap(b, L(sc, 0) + 0.02 + i * BEAT / 4, 0.1));
    },
    sounds(sc) { return sc.lines.map((l, i) => ({ t: l.start - 0.03, kind: i ? 'slam' : 'pop' })); },
    render(t, sc) {
      const cx = W / 2, cy = PORTRAIT ? H * 0.36 : H * 0.4;
      const pulse = 1 + 0.03 * Math.sin(prog(t, L(sc, 2), L(sc, 2) + 0.5) * Math.PI);
      const spin = tw(t, sc.start, sc.start + 0.7, -18, 0, E.back);
      place(this.ctrl.el, cx, cy + tw(t, sc.start, sc.start + 0.7, 60, 0), tw(t, sc.start, sc.start + 0.7, 0.5, 1, E.back) * pulse,
        tw(t, sc.start, sc.start + 0.3, 0, 1), `rotate(${spin}deg)`);
      this.ctrl.update(this.cues(sc), t);

      const k = E.back(prog(t, L(sc, 1), L(sc, 1) + 0.5));
      const o = prog(t, L(sc, 1), L(sc, 1) + 0.2);
      const cs = lerp(0.4, 1.25, k), rot = (1 - k) * 20;
      if (PORTRAIT) {
        place(this.codex, cx - lerp(0, 200, k), cy + 330, cs, o, `rotate(${-rot}deg)`);
        place(this.claude, cx + lerp(0, 200, k), cy + 330, cs, o, `rotate(${rot}deg)`);
      } else {
        place(this.codex, cx - lerp(200, 500, k), cy, cs, o, `rotate(${-rot}deg)`);
        place(this.claude, cx + lerp(200, 500, k), cy, cs, o, `rotate(${rot}deg)`);
      }

      let i = 0;
      for (let j = 0; j < sc.lines.length; j++) if (t >= L(sc, j) - 0.05) i = j;
      const st = L(sc, i) - 0.05;
      const hy = PORTRAIT ? H * 0.62 : H * 0.78;
      kinetic(this.head, sc.lines[i].text, t, st);
      place(this.head, cx, hy, 1, 1);
      this.head.style.color = i === 2 ? 'var(--gold-lite)' : 'var(--ink)';
    },
  };

  // 2 — Hardware
  SCENES.hardware = {
    build(root) {
      this.tag = sectionTag(root, '01', 'THE HARDWARE');
      this.persp = el('div', 'abs', root);
      this.persp.style.perspective = '1600px';
      this.ctrl = makeController(this.persp);
      this.ctrl.el.style.position = 'relative';
      size(this.persp, PORTRAIT ? 700 : 760);
      // Dimension lines ride inside the controller's box so they tilt with it.
      this.dimW = el('div', 'abs', this.ctrl.el, `
        <div style="position:absolute;left:2%;right:2%;top:0;height:2px;background:var(--gold)"></div>
        <div style="position:absolute;left:2%;top:-10px;width:2px;height:22px;background:var(--gold)"></div>
        <div style="position:absolute;right:2%;top:-10px;width:2px;height:22px;background:var(--gold)"></div>
        <div class="mono" style="position:absolute;left:0;right:0;top:18px;text-align:center;color:var(--gold-lite);font-size:30px;font-weight:600">49 mm</div>`);
      this.dimH = el('div', 'abs', this.ctrl.el, `
        <div style="position:absolute;top:3%;bottom:3%;left:0;width:2px;background:var(--gold)"></div>
        <div style="position:absolute;top:3%;left:-10px;height:2px;width:22px;background:var(--gold)"></div>
        <div style="position:absolute;bottom:3%;left:-10px;height:2px;width:22px;background:var(--gold)"></div>
        <div class="mono" style="position:absolute;left:22px;top:50%;transform:translateY(-50%);color:var(--gold-lite);font-size:30px;font-weight:600;white-space:nowrap">34 mm</div>`);
      this.title = headline(root, PORTRAIT ? 104 : 96);
      this.subtitle = el('div', 'abs sub', root);
      this.subtitle.style.fontSize = PORTRAIT ? '40px' : '34px';
      this.stats = ['49 × 34 × 17 mm', '10 h battery', 'Pocket-size'].map((s) => el('div', 'abs chip', root, s));
      // Mode switch: T · C · H with a knob, as printed on the side of the controller.
      this.mode = el('div', 'abs', root, `
        <div style="position:relative;width:300px;height:92px;border-radius:46px;background:#231f1d;border:1px solid var(--line)">
          <div class="knob" style="position:absolute;top:10px;left:10px;width:88px;height:72px;border-radius:36px;background:var(--gold)"></div>
          <div class="mono" style="position:absolute;inset:0;display:flex;justify-content:space-around;align-items:center;font-size:32px;font-weight:700">
            <span>T</span><span class="c">C</span><span>H</span></div>
        </div>
        <div class="sub" style="text-align:center;margin-top:18px;font-size:26px">mode switch</div>`);
      this.knob = this.mode.querySelector('.knob');
      this.bt = el('div', 'abs', root, `<svg width="96" height="96" viewBox="0 0 24 24"><circle cx="12" cy="12" r="12" fill="#2f6fe0"/>
        <path d="M8 8.2l8 7.6-4 3.4V4.8l4 3.4-8 7.6" fill="none" stroke="#fff" stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round"/></svg>
        <div class="sub" style="text-align:center;margin-top:14px;font-size:26px">Bluetooth</div>`);
      this.rings = [0, 1, 2].map(() => {
        const r = el('div', 'abs', root);
        r.style.border = '3px solid rgba(90,150,255,0.7)';
        r.style.borderRadius = '50%';
        return r;
      });
      // The Mac: a screen with a menu bar and the two agent windows.
      this.mac = el('div', 'abs', root, `
        <div style="position:relative;width:100%;height:100%;border-radius:22px;background:#151312;border:10px solid #2c2826;overflow:hidden;box-shadow:0 40px 120px rgba(0,0,0,.6)">
          <div style="height:40px;background:#221f1d;display:flex;align-items:center;justify-content:flex-end;padding:0 20px;gap:18px;color:var(--muted);font-size:18px">
            <span class="menuicon" style="display:inline-flex;align-items:center;gap:8px;color:var(--gold-lite);font-weight:600">
              <svg width="30" height="21" viewBox="0 0 49 34"><rect width="49" height="34" rx="4" fill="#d8b25c"/><path d="M11 9h5v5h5v5h-5v5h-5v-5H6v-5h5z" fill="#1a1414"/><circle cx="36" cy="11" r="4" fill="#1a1414"/><circle cx="36" cy="23" r="4" fill="#1a1414"/></svg>
              PocketAgentRemote</span><span>Tue 9:41</span></div>
          <div class="w1" style="position:absolute;left:6%;top:18%;width:52%;height:64%;border-radius:12px;background:#201d1c;border:1px solid var(--line)">
            <div style="padding:14px 18px;font-weight:700;font-size:22px">Codex</div>
            <div style="margin:4px 18px;height:12px;border-radius:6px;background:#2f2b29;width:70%"></div>
            <div style="margin:14px 18px;height:12px;border-radius:6px;background:#2f2b29;width:50%"></div>
            <div style="margin:14px 18px;height:12px;border-radius:6px;background:#2f2b29;width:62%"></div></div>
          <div class="w2" style="position:absolute;left:42%;top:30%;width:52%;height:62%;border-radius:12px;background:#22201f;border:1px solid var(--line)">
            <div style="padding:14px 18px;font-weight:700;font-size:22px;color:#e8a27f">Claude</div>
            <div style="margin:4px 18px;height:12px;border-radius:6px;background:#302c2a;width:66%"></div>
            <div style="margin:14px 18px;height:12px;border-radius:6px;background:#302c2a;width:44%"></div></div>
        </div>`);
      this.link = el('div', 'abs', root);
      this.link.style.height = '4px';
      this.link.style.background = 'repeating-linear-gradient(90deg, var(--gold) 0 18px, transparent 18px 34px)';
    },
    cues(sc) {
      return [tap('up', L(sc, 3) + 0.9, 0.12), tap('a', L(sc, 3) + 1.5, 0.14)];
    },
    sounds(sc) {
      const s = [{ t: L(sc, 3) + 0.2, kind: 'slam' }, { t: L(sc, 2) + 0.3, kind: 'whoosh' }];
      for (let i = 0; i < 3; i++) s.push({ t: L(sc, 1) + 0.4 + i * 0.35, kind: 'pop' });
      return s;
    },
    render(t, sc) {
      this.tag(t, sc);
      const cx = W / 2;
      const s0 = sc.start, l1 = L(sc, 1), l2 = L(sc, 2), l3 = L(sc, 3);
      // Controller pose: tilted hero → flat front for the measurements → shrinks aside for the Mac.
      const spin = tw(t, s0, l1, -28, -8, E.inOut);
      const rotY = t < l1 ? spin : tw(t, l1, l1 + 0.8, spin, 0, E.inOut);
      const rotX = t < l1 ? tw(t, s0, l1, 18, 10) : tw(t, l1, l1 + 0.8, 10, 0, E.inOut);
      const move = E.inOut(prog(t, l3 - 0.1, l3 + 0.8));
      let x, y, s;
      if (PORTRAIT) {
        x = cx; y = lerp(H * 0.44, H * 0.3, move); s = lerp(1, 0.62, move);
      } else {
        x = lerp(W * 0.6, W * 0.24, move); y = lerp(H * 0.5, H * 0.55, move); s = lerp(1, 0.62, move);
      }
      const enter = tw(t, s0, s0 + 0.9, 0.8, 1);
      place(this.persp, x, y, s * enter, tw(t, s0, s0 + 0.4, 0, 1));
      this.ctrl.el.style.transform = `rotateX(${rotX}deg) rotateY(${rotY}deg)`;
      this.ctrl.update(this.cues(sc), t);

      const dimO = window01(t, l1 + 0.6, l2 + 0.2);
      this.dimW.style.cssText += `;left:0;top:104%;width:100%;opacity:${dimO}`;
      this.dimH.style.cssText += `;left:103%;top:0;height:100%;opacity:${dimO}`;

      // Titles
      const titleText = t < l3 ? 'Gamebrick' : 'PocketAgentRemote';
      const subText = t < l3 ? 'mini retro controller · 6 buttons' : 'turns it into a remote for Codex & Claude';
      kinetic(this.title, titleText, t, t < l3 ? L(sc, 0) - 0.1 : l3 + 0.2);
      this.subtitle.textContent = subText;
      const ty = PORTRAIT ? H * 0.14 : H * 0.15;
      const tIn = t < l3 ? L(sc, 0) - 0.1 : l3 + 0.2;
      const tOut = t < l3 ? l3 - 0.3 : sc.end - 0.4;
      const to = window01(t, tIn, tOut, 0.3);
      if (PORTRAIT) {
        place(this.title, cx, ty, 1, to);
        place(this.subtitle, cx, ty + 96, 1, to);
      } else {
        this.title.style.transformOrigin = 'left center';
        this.title.style.transform = `translate(${W * 0.07}px, ${ty}px)`;
        this.title.style.opacity = to;
        this.subtitle.style.transform = `translate(${W * 0.07 + 4}px, ${ty + 120}px)`;
        this.subtitle.style.opacity = to;
      }

      // Stats (line 1)
      const statY = PORTRAIT ? H * 0.665 : H * 0.86;
      this.stats.forEach((c, i) => {
        const a = l1 + 0.4 + i * 0.35;
        const o = window01(t, a, l2 - 0.2);
        const sx = PORTRAIT ? cx : W * 0.6 + (i - 1) * 380;
        const sy = PORTRAIT ? statY + i * 110 : statY;
        place(c, sx, sy + (1 - o) * 20, 1, o);
      });

      // Mode switch + Bluetooth (line 2)
      const mo = window01(t, l2, l3 - 0.2);
      const mx = PORTRAIT ? cx - 200 : W * 0.6 - 260, my = PORTRAIT ? H * 0.7 : H * 0.84;
      place(this.mode, mx, my, 1, mo);
      // Knob parks on H, slides to C.
      this.knob.style.transform = `translateX(${lerp(192, 96, E.inOut(prog(t, l2 + 0.3, l2 + 0.8)))}px)`;
      place(this.bt, PORTRAIT ? cx + 200 : W * 0.6 + 260, my - 10, 1, window01(t, l2 + 0.9, l3 - 0.2));
      const ringO = window01(t, l2 + 1.0, l3 - 0.1);
      this.rings.forEach((r, i) => {
        const ph = ((t - l2) / 1.2 + i / 3) % 1;
        const d = lerp(300, 1000, ph) * (PORTRAIT ? 1.05 : 1);
        size(r, d, d);
        place(r, x, y, 1, ringO * (1 - ph) * 0.8);
      });

      // Mac + link (line 3)
      const macO = prog(t, l3 + 0.3, l3 + 0.9);
      const macW = PORTRAIT ? 920 : 900, macH = PORTRAIT ? 620 : 580;
      size(this.mac, macW, macH);
      const macX = PORTRAIT ? cx : W * 0.68, macY = PORTRAIT ? H * 0.64 : H * 0.57;
      place(this.mac, macX, macY + (1 - E.out(macO)) * 40, 1, macO * (1 - prog(t, sc.end - 0.35, sc.end)));
      const linkO = window01(t, l3 + 0.8, sc.end - 0.4);
      if (PORTRAIT) {
        size(this.link, 150);
        place(this.link, cx, H * 0.43, 1, linkO, 'rotate(90deg)');
      } else {
        size(this.link, 200);
        place(this.link, W * 0.45, H * 0.55, 1, linkO);
      }
      this.link.style.backgroundPosition = `${(t * 80) % 34}px 0`;
    },
  };

  // 3 — The couch
  SCENES.couch = {
    hideCaption: (i) => i === 2,
    build(root) {
      this.tag = sectionTag(root, '02', 'THE IDEA');
      this.win = makeWindow(root, 'Codex');
      size(this.win.el, PORTRAIT ? 940 : 1080, PORTRAIT ? 860 : 640);
      this.log = el('div', 'msg log', this.win.body);
      this.log.style.top = '28px';
      this.card = el('div', 'card', this.win.body, `
        <div style="font-size:22px;color:var(--gold-lite);font-weight:700;margin-bottom:10px">Allow command?</div>
        <div class="mono" style="font-size:26px;margin-bottom:22px">$ swift test</div>
        <div style="display:flex;gap:14px">
          <div class="btn ok" style="background:var(--gold);color:#1a1410">Approve <small>⏎</small></div>
          <div class="btn" style="background:#3a3431">Reject <small>⎋</small></div></div>`);
      this.card.style.position = 'absolute';
      this.card.style.left = '32px';
      this.card.style.right = '32px';
      this.approveBtn = this.card.querySelector('.btn.ok');
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 440 : 330);
      this.you = el('div', 'abs sub', root, '3 m away, on the couch');
      this.you.style.fontSize = PORTRAIT ? '32px' : '24px';
      this.head = headline(root, PORTRAIT ? 120 : 110);
      this.head.textContent = 'Just press A.';
      this.head.style.color = 'var(--gold-lite)';
    },
    pressAt(sc) { return L(sc, 2) + 0.45; },
    cues(sc) { return [tap('a', this.pressAt(sc), 0.16)]; },
    sounds(sc) { return [{ t: L(sc, 1) + 0.3, kind: 'pop' }, { t: L(sc, 2) - 0.05, kind: 'slam' }, { t: this.pressAt(sc) + 0.12, kind: 'chime' }]; },
    render(t, sc) {
      this.tag(t, sc);
      const cx = W / 2;
      const wo = window01(t, sc.start, sc.end - 0.35);
      const wx = PORTRAIT ? cx : W * 0.45, wy = PORTRAIT ? H * 0.37 : H * 0.49;
      place(this.win.el, wx, wy + (1 - wo) * 30, 1, wo);

      const pa = this.pressAt(sc);
      const lines = [
        [sc.start + 0.3, '<span class="spin" style="transform:rotate(' + (t * 360) % 360 + 'deg)"></span>Editing Sources/Parser.swift'],
        [sc.start + 1.1, '  + 42 lines   − 9 lines'],
        [sc.start + 1.8, '<span class="spin" style="transform:rotate(' + (t * 360) % 360 + 'deg)"></span>Waiting for approval…'],
        [pa + 0.5, '<span class="ok">✓ 345 tests passed</span>'],
      ];
      this.log.innerHTML = lines.filter(([a]) => t >= a).map(([, h]) => `<div>${h}</div>`).join('');

      const co = prog(t, L(sc, 1) + 0.3, L(sc, 1) + 0.6);
      const done = t >= pa + 0.1;
      this.card.style.top = (PORTRAIT ? 300 : 230) + (1 - E.back(co)) * 30 + 'px';
      this.card.style.opacity = co * (done ? 1 - prog(t, pa + 0.9, pa + 1.2) : 1);
      const flash = Math.max(0, 1 - Math.abs(t - pa - 0.08) / 0.25);
      this.approveBtn.style.boxShadow = `0 0 0 ${flash * 10}px rgba(241,213,140,${flash * 0.5})`;
      this.approveBtn.innerHTML = done ? '✓ Approved' : 'Approve <small>⏎</small>';

      const ko = window01(t, sc.start + 0.4, sc.end - 0.35);
      const kx = PORTRAIT ? cx : W * 0.84, ky = PORTRAIT ? H * 0.74 : H * 0.62;
      const bob = Math.sin(t * 2.2) * 6;
      place(this.ctrl.el, kx, ky + bob + (1 - ko) * 30, 1, ko);
      this.ctrl.update(this.cues(sc), t);
      place(this.you, kx, ky + (PORTRAIT ? 170 : 150), 1, ko * 0.9);

      kinetic(this.head, 'Just press A.', t, L(sc, 2) - 0.05);
      if (PORTRAIT) place(this.head, cx, H * 0.9, 1, 1);
      else place(this.head, W * 0.8, H * 0.86, 0.85, 1);
    },
  };

  // 4 — Basics
  SCENES.basics = {
    build(root) {
      this.tag = sectionTag(root, '03', 'THE BASICS');
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 460 : 560);
      const rows = [['A', 'Enter · submit / approve'], ['hold A', 'Voice input'], ['B', 'Escape · cancel / reject'],
        ['D-pad', 'Move · hold to repeat'], ['B + A', 'Backspace · hold to repeat']];
      this.legend = el('div', 'abs legend', root, rows.map(([k, v]) => `<div class="row"><b>${k}</b>${v}</div>`).join(''));
      this.rows = [...this.legend.querySelectorAll('.row')];
      this.win = makeWindow(root, 'Codex');
      size(this.win.el, PORTRAIT ? 960 : 1000, PORTRAIT ? 760 : 700);
      this.old = el('div', 'msg', this.win.body, '<div style="color:#cfc6ba">Parser updated. Want tests next?</div>');
      this.old.style.top = '28px';
      this.sent = el('div', 'msg', this.win.body, '<div class="bubble">Add a test for the parser</div>');
      this.status = el('div', 'msg log', this.win.body);
      this.pop = el('div', 'pop', this.win.body, ['/model', '/review', '/status', '/compact', '/init'].map((s) => `<div>${s}</div>`).join(''));
      this.pop.style.left = '28px';
      this.pop.style.width = '360px';
      this.popRows = [...this.pop.children];
      this.composer = el('div', 'composer', this.win.body);
      this.key = el('div', 'abs key', root);
    },
    beats(sc) {
      const b = {};
      b.send = L(sc, 0) + 0.7;
      b.holdA = [L(sc, 1) + 0.05, LE(sc, 1) + 0.25];
      b.cancel = L(sc, 2) + 0.55;
      b.down1 = L(sc, 3) + 0.35;
      b.downHold = [L(sc, 3) + 1.1, L(sc, 3) + 1.1 + 0.2 * 3 + 0.1];
      b.bHold = [L(sc, 4) + 0.35, L(sc, 4) + 2.1];
      b.aBack = [L(sc, 4) + 0.6, L(sc, 4) + 0.6 + 0.16 * 4];
      return b;
    },
    cues(sc) {
      const b = this.beats(sc);
      return [
        tap('a', b.send, 0.14),
        { btn: 'a', t: b.holdA[0], dur: b.holdA[1] - b.holdA[0] },
        tap('b', b.cancel, 0.14),
        tap('down', b.down1, 0.12),
        { btn: 'down', t: b.downHold[0], dur: b.downHold[1] - b.downHold[0] },
        { btn: 'b', t: b.bHold[0], dur: b.bHold[1] - b.bHold[0] },
        { btn: 'a', t: b.aBack[0], dur: b.aBack[1] - b.aBack[0] },
      ];
    },
    sounds(sc) {
      const b = this.beats(sc);
      const s = [];
      for (let i = 1; i <= 3; i++) s.push({ t: b.downHold[0] + i * 0.2, kind: 'tick' });
      for (let i = 1; i < 4; i++) s.push({ t: b.aBack[0] + i * 0.16, kind: 'tick' });
      s.push({ t: b.send + 0.1, kind: 'pop' });
      return s;
    },
    render(t, sc) {
      this.tag(t, sc);
      const b = this.beats(sc);
      const fade = window01(t, sc.start, sc.end - 0.35);
      const cx = W / 2;
      // Layout
      let kx, ky, lx, ly, wx, wy;
      if (PORTRAIT) {
        wx = cx; wy = H * 0.3; kx = cx; ky = H * 0.64; lx = cx; ly = H * 0.8;
      } else {
        kx = W * 0.24; ky = H * 0.36; lx = W * 0.24; ly = H * 0.72; wx = W * 0.69; wy = H * 0.5;
      }
      place(this.win.el, wx, wy + (1 - fade) * 30, 1, fade);
      place(this.ctrl.el, kx, ky + (1 - fade) * 30, 1, fade);
      place(this.legend, lx, ly, 1, fade);

      let line = -1;
      for (let j = 0; j < sc.lines.length; j++) if (t >= L(sc, j) - 0.1) line = j;
      this.rows.forEach((r, i) => r.classList.toggle('on', i === line));

      const cues = this.cues(sc);
      const holdA = t >= b.holdA[0] && t <= b.holdA[1] ? prog(t, b.holdA[0], b.holdA[1]) : 0;
      this.ctrl.update(cues, t, holdA);

      // Conversation
      const sentO = prog(t, b.send, b.send + 0.3);
      this.sent.style.top = lerp(PORTRAIT ? 560 : 500, 100, E.out(sentO)) + 'px';
      this.sent.style.opacity = sentO;
      const working = t >= b.send + 0.35;
      const cancelled = t >= b.cancel + 0.05;
      this.status.style.top = '190px';
      this.status.style.opacity = working ? 1 : 0;
      this.status.innerHTML = cancelled
        ? '<span style="color:#e57b6b">■ Interrupted</span>'
        : `<span class="spin" style="transform:rotate(${(t * 360) % 360}deg)"></span>Working…`;

      // Composer text
      const typed = 'Add a test for the parser';
      const spoken = 'refactor the passer';
      let text;
      if (t < b.send) text = typed;
      else if (t < b.holdA[0]) text = '';
      else if (t < b.holdA[1]) text = spoken.slice(0, Math.floor(spoken.length * prog(t, b.holdA[0] + 0.2, b.holdA[1] - 0.2)));
      else if (t < b.aBack[0]) text = spoken;
      else {
        const del = Math.min(4, 1 + Math.floor((t - b.aBack[0]) / 0.16));
        text = spoken.slice(0, spoken.length - del);
        const re = 'rser';
        const retype = Math.floor(prog(t, b.bHold[1] + 0.1, b.bHold[1] + 0.6) * re.length);
        if (t > b.bHold[1] + 0.1) text = spoken.slice(0, spoken.length - 4) + re.slice(0, retype);
      }
      const recording = t >= b.holdA[0] && t < b.holdA[1];
      const wave = recording
        ? `<span style="display:inline-flex;gap:4px;align-items:center;margin-right:16px">${[0, 1, 2, 3, 4].map((i) =>
          `<i style="width:5px;border-radius:3px;background:#e57b6b;height:${8 + 22 * Math.abs(Math.sin(t * 9 + i * 1.3))}px"></i>`).join('')}</span>`
        : '';
      const caretOn = Math.floor(t * 2.2) % 2 === 0 || recording;
      this.composer.innerHTML = `${wave}<span>${text}</span><span class="caret" style="opacity:${caretOn ? 1 : 0}"></span>`;
      if (text.includes('passer') && t > b.holdA[1] && t < L(sc, 4) + 0.35) {
        this.composer.innerHTML = this.composer.innerHTML.replace('passer', '<u style="text-decoration-color:#e57b6b;text-decoration-style:wavy">passer</u>');
      }

      // Slash-command popover
      const po = window01(t, b.down1 - 0.25, L(sc, 4) - 0.2, 0.2);
      this.pop.style.bottom = '124px';
      this.pop.style.opacity = po;
      let sel = 0;
      if (t >= b.down1) sel = 1;
      for (let i = 1; i <= 3; i++) if (t >= b.downHold[0] + (i - 1) * 0.2) sel = 1 + i;
      this.popRows.forEach((r, i) => r.classList.toggle('on', i === Math.min(sel, 4)));

      // Keycap: what the Mac actually received
      const keys = [[b.send, '⏎  Enter'], [b.holdA[0], '●  Voice'], [b.cancel, '⎋  Esc'], [b.down1, '↓'], [b.downHold[0], '↓ ↓ ↓'], [b.aBack[0], '⌫ ⌫ ⌫']];
      let cur = null;
      for (const k of keys) if (t >= k[0]) cur = k;
      const kx2 = PORTRAIT ? cx : wx, ky2 = PORTRAIT ? H * 0.527 : wy + 410;
      if (cur) {
        this.key.textContent = cur[1];
        const ko = window01(t, cur[0], cur[0] + (cur === keys[1] ? 1.9 : 0.9), 0.12) * fade;
        place(this.key, kx2, ky2, tw(t, cur[0], cur[0] + 0.25, 1.25, 1, E.back), ko);
      } else place(this.key, kx2, ky2, 1, 0);
    },
  };

  // ---------- shared UI for the feature scenes ----------
  const APPS = {
    codex: { name: 'Codex', bg: 'linear-gradient(#2e2e2e,#0b0b0b)', glyph: '&gt;_' },
    claude: { name: 'Claude', bg: 'linear-gradient(#e6906c,#c65f3c)', glyph: '✳' },
    wechat: { name: 'WeChat', bg: 'linear-gradient(#45d672,#1eaa4a)', glyph: 'W' },
    browser: { name: 'Chrome', bg: 'linear-gradient(#5a9bff,#2459d6)', glyph: '◎' },
    finder: { name: 'Finder', bg: 'linear-gradient(#7cc4ff,#2f7de0)', glyph: '☺' },
    terminal: { name: 'Terminal', bg: 'linear-gradient(#444,#161616)', glyph: '$' },
  };
  const tile = (k, s) =>
    `<div class="tile" style="width:${s}px;height:${s}px;border-radius:${s * 0.23}px;background:${APPS[k].bg};font-size:${s * 0.42}px">${APPS[k].glyph}</div>`;
  const CTL_ICON = '<svg width="30" height="21" viewBox="0 0 49 34"><rect width="49" height="34" rx="5" fill="currentColor"/><path d="M11 9h5v5h5v5h-5v5h-5v-5H6v-5h5z" fill="#1a1414"/><circle cx="36" cy="11" r="4" fill="#1a1414"/><circle cx="36" cy="23" r="4" fill="#1a1414"/></svg>';
  const CURSOR = '<svg width="34" height="44" viewBox="0 0 17 22"><path d="M1 1v17l4.5-4.2 3 6.7 2.6-1.2-3-6.6H14z" fill="#fff" stroke="#000" stroke-width="1.2" stroke-linejoin="round"/></svg>';

  // A big kinetic line under the section tag: the scene's point in five words.
  function sceneTitle(root, text) {
    const e = el('div', 'abs kt', root);
    e.style.fontSize = (PORTRAIT ? 66 : 60) + 'px';
    return (t, sc) => {
      kinetic(e, text, t, sc.start + 0.12, { stagger: 0.06 });
      const o = 1 - prog(t, sc.end - 0.3, sc.end);
      if (PORTRAIT) place(e, W / 2, 210, 1, o);
      else {
        e.style.transform = `translate(88px, 112px)`;
        e.style.opacity = o;
      }
    };
  }

  // Keycaps: what the Mac received, popping in at each cue.
  function keycaps(root) {
    const e = el('div', 'abs key', root);
    return (t, list, x, y, fade = 1) => {
      let cur = null;
      for (const k of list) if (t >= k[0]) cur = k;
      if (!cur) return place(e, x, y, 1, 0);
      e.textContent = cur[1];
      const o = window01(t, cur[0], cur[0] + (cur[2] || 0.9), 0.12) * fade;
      place(e, x, y, tw(t, cur[0], cur[0] + 0.25, 1.3, 1, E.back), o);
    };
  }

  // The controller overlay in its three layouts, at the app's own metrics.
  const HINTS = { list: '↑↓ Select    A Run    B Close', strip: '←→ Select    A Switch    B Close', dial: 'Arrows Select · A Run · B Close' };
  function makeOverlay(parent) {
    const e = el('div', 'abs', parent);
    let key = null, nodes = [], name = null;
    return {
      el: e,
      render(m) {
        const k = JSON.stringify([m.layout, m.title, m.items.map((i) => i.title)]);
        if (k !== key) {
          key = k;
          if (m.layout === 'list') {
            e.innerHTML = `<div class="ovl" style="width:420px"><div class="ovl-title">${m.title}</div>${m.items.map((i) =>
              `<div class="ovl-row">${i.pin ? '<span class="pin">★</span>' : ''}${i.title}</div>`).join('')}<div class="ovl-hint">${HINTS.list}</div></div>`;
            nodes = [...e.querySelectorAll('.ovl-row')];
          } else if (m.layout === 'dial') {
            const g = (460 - 36) / 3;
            const cells = [[1, 0], [0, 1], [1, 2], [2, 1]];
            e.innerHTML = `<div class="ovl" style="width:460px;height:${460 + 26}px">${m.items.map((i, n) =>
              `<div class="ovl-slot" style="left:${18 + cells[n][0] * g + 4}px;top:${18 + cells[n][1] * g + g / 2 - 23}px;width:${g - 8}px;height:46px">${i.title}</div>`).join('')}
              <div class="ovl-title" style="position:absolute;left:${18 + g}px;top:${18 + g + g / 2 - 30}px;width:${g}px;justify-content:center;padding:0">${m.title}</div>
              <div class="ovl-hint" style="position:absolute;left:18px;bottom:18px">${HINTS.dial}</div></div>`;
            nodes = [...e.querySelectorAll('.ovl-slot')];
          } else {
            const w = Math.max(420, 36 + 88 * m.items.length);
            e.innerHTML = `<div class="ovl" style="width:${w}px"><div class="ovl-title">${m.title}</div>
              <div style="display:flex;justify-content:center">${m.items.map((i) =>
                `<div style="position:relative;width:88px;height:88px"><div class="ovl-cell" style="inset:4px">${tile(i.app, 62)}</div></div>`).join('')}</div>
              <div class="nm" style="height:40px;display:flex;align-items:center;justify-content:center;font:500 26px -apple-system,sans-serif"></div>
              <div class="ovl-hint">${HINTS.strip}</div></div>`;
            nodes = [...e.querySelectorAll('.ovl-cell')];
            name = e.querySelector('.nm');
          }
        }
        nodes.forEach((n, i) => n.classList.toggle('on', i === m.sel));
        if (m.layout === 'strip') name.textContent = m.items[m.sel] ? m.items[m.sel].title : '';
      },
    };
  }

  function makeToast(parent) {
    const e = el('div', 'abs toast', parent);
    return e;
  }

  function makeDesktop(parent, w, h) {
    const e = el('div', 'abs desktop', parent, `<div class="desk"></div><div class="mbar"><span class="app"></span><span class="menus"></span>
      <span class="right"><span class="ctl" style="color:var(--gold-lite)">${CTL_ICON}</span><span>Tue 9:41</span></span></div>`);
    size(e, w, h);
    const d = {
      el: e, w, h,
      desk: e.querySelector('.desk'),
      appEl: e.querySelector('.app'),
      ctl: e.querySelector('.ctl'),
      menusEl: e.querySelector('.menus'),
      setMenus(app, menus) {
        if (d._k === app + menus.join()) return;
        d._k = app + menus.join();
        d.appEl.textContent = app;
        d.menusEl.innerHTML = menus.map((m) => `<span class="mn">${m}</span>`).join('');
        d.menuEls = [...d.menusEl.children];
      },
    };
    return d;
  }

  // Chat-app window contents for Codex / Claude / WeChat / a browser, switchable per frame.
  const CHATS = {
    codex: ['Parser tests', 'Refactor CLI', 'Fix CI'],
    claude: ['Release notes', 'API design', 'Bug triage'],
    wechat: ['Design team', 'Mom', 'Weekend hike', 'Alex'],
  };
  function makeAppWindow(root, w, h) {
    const win = makeWindow(root, 'Codex');
    size(win.el, w, h);
    const side = el('div', 'side', win.body);
    const main = el('div', 'mainpane', win.body);
    const pal = el('div', 'pop', win.body, `<div style="font:22px -apple-system;color:#9a8f82;border-bottom:1px solid var(--line);border-radius:0;margin-bottom:6px">Search commands…</div>`
      + ['New chat', 'Switch model', 'Toggle sidebar'].map((s) => `<div>${s}</div>`).join(''));
    pal.style.width = '420px';
    pal.style.left = '50%';
    pal.style.top = '90px';
    pal.style.marginLeft = '-210px';
    let key = null;
    return {
      el: win.el,
      set(app, sel, opts = {}) {
        const k = JSON.stringify([app, sel, opts.attention, opts.focusRow]);
        pal.style.opacity = opts.palette || 0;
        pal.style.transform = `scale(${lerp(0.9, 1, opts.palette || 0)})`;
        if (k === key) return;
        key = k;
        win.title.textContent = APPS[app].name;
        win.title.style.color = app === 'claude' ? '#e8a27f' : app === 'wechat' ? '#5ad17f' : 'var(--muted)';
        if (app === 'browser') {
          side.style.display = 'none';
          main.style.left = '0';
          main.innerHTML = `<div style="height:44px;border-radius:22px;background:#2a2625;display:flex;align-items:center;padding:0 20px;color:#9a8f82;font-size:20px">example.com/news</div>`
            + ['Show HN: a remote for coding agents', 'Why small controllers are back', 'Ask: favourite macOS utilities', 'Retro hardware, modern software']
              .map((s, i) => `<div style="margin-top:14px;padding:14px 18px;border-radius:12px;font-size:22px;${i === opts.focusRow ? 'background:var(--gold);color:#1a1410;font-weight:650' : 'color:#cfc6ba'}">${s}</div>`).join('');
          return;
        }
        side.style.display = 'block';
        main.style.left = '250px';
        side.innerHTML = CHATS[app].map((c, i) =>
          `<div class="${i === sel ? 'on' : ''}">${c}${opts.attention && i === 2 ? '<span class="dot"></span>' : ''}</div>`).join('');
        const name = CHATS[app][sel];
        if (app === 'wechat') {
          main.innerHTML = `<div style="font-size:24px;font-weight:700;margin-bottom:18px">${name}</div>
            <div style="background:#2f2b29;padding:12px 18px;border-radius:14px;width:fit-content;font-size:21px;margin-bottom:12px">Are we still on for Saturday?</div>
            <div style="background:#3fbf62;color:#0c1f10;padding:12px 18px;border-radius:14px;width:fit-content;margin-left:auto;font-size:21px">Yes! 9am at the trailhead</div>`;
          return;
        }
        const needs = app === 'codex' && sel === 2;
        main.innerHTML = `<div style="font-size:24px;font-weight:700">${name}</div><div class="bar-f" style="width:72%"></div><div class="bar-f" style="width:54%"></div><div class="bar-f" style="width:63%"></div>`
          + (needs ? `<div class="card" style="margin-top:26px;padding:18px 22px"><div style="color:var(--gold-lite);font-weight:700;font-size:20px">Needs your approval</div><div class="mono" style="font-size:22px;margin-top:8px">$ git push origin main</div></div>` : '');
      },
    };
  }

  // 5 — Auto profiles
  SCENES.profiles = {
    build(root) {
      this.tag = sectionTag(root, '04', 'AUTO PROFILES');
      this.title = sceneTitle(root, 'It knows what’s in front.');
      this.win = makeAppWindow(root, PORTRAIT ? 960 : 1040, PORTRAIT ? 680 : 640);
      this.dock = el('div', 'abs', root, `<div style="display:flex;gap:18px;padding:12px 18px;border-radius:24px;background:rgba(40,36,34,.85);border:1px solid var(--line)">${
        ['codex', 'claude', 'browser'].map((k) => `<div class="dk" style="position:relative">${tile(k, 70)}<i style="position:absolute;left:50%;bottom:-9px;width:6px;height:6px;margin-left:-3px;border-radius:50%;background:#ddd"></i></div>`).join('')}</div>`);
      this.dockItems = [...this.dock.querySelectorAll('.dk')];
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 400 : 420);
      this.badge = el('div', 'abs chip', root);
      this.map = el('div', 'abs legend', root, ['B + ↑', 'B + →', 'Arrows'].map((k) => `<div class="row"><b>${k}</b><span></span></div>`).join(''));
      this.mapRows = [...this.map.querySelectorAll('.row')];
      this.mapText = [...this.map.querySelectorAll('.row span')];
      this.key = keycaps(root);
    },
    beats(sc) {
      const l1 = L(sc, 1), l2 = L(sc, 2), l3 = L(sc, 3);
      return {
        l1, l2, l3,
        c: { bHold: [l1 + 0.3, l1 + 3.9], up: l1 + 0.75, right: l1 + 3.05 },
        k: { bHold: [l2 + 0.3, l2 + 3.0], up: l2 + 0.85, right: l2 + 2.25 },
        g: { down1: l3 + 0.9, down2: l3 + 1.3, a: l3 + 1.9 },
      };
    },
    mode(t, sc) {
      const b = this.beats(sc);
      if (t < b.l1 - 0.1) return ['codex', 'claude', 'browser'][Math.max(0, Math.floor((t - sc.start) / 0.5)) % 3];
      if (t < b.l2 - 0.1) return 'codex';
      if (t < b.l3 - 0.1) return 'claude';
      return 'browser';
    },
    cues(sc) {
      const b = this.beats(sc);
      return [
        { btn: 'b', t: b.c.bHold[0], dur: b.c.bHold[1] - b.c.bHold[0] }, tap('up', b.c.up), tap('right', b.c.right),
        { btn: 'b', t: b.k.bHold[0], dur: b.k.bHold[1] - b.k.bHold[0] }, tap('up', b.k.up), tap('right', b.k.right),
        tap('down', b.g.down1), tap('down', b.g.down2), tap('a', b.g.a),
      ];
    },
    sounds(sc) {
      const b = this.beats(sc);
      const s = [{ t: b.l2 - 0.15, kind: 'whoosh' }, { t: b.l3 - 0.15, kind: 'whoosh' }, { t: b.k.right + 0.05, kind: 'pop' }];
      for (let x = sc.start + 0.5; x < b.l1 - 0.1; x += 0.5) s.push({ t: x, kind: 'tick' });
      return s;
    },
    render(t, sc) {
      this.tag(t, sc);
      this.title(t, sc);
      const b = this.beats(sc);
      const mode = this.mode(t, sc);
      const fade = window01(t, sc.start, sc.end - 0.3);
      let wx, wy, kx, ky, bx, by, mx, my;
      if (PORTRAIT) {
        wx = W / 2; wy = H * 0.33; kx = W / 2; ky = H * 0.615; bx = W / 2; by = H * 0.715; mx = W / 2; my = H * 0.8;
      } else {
        wx = W * 0.64; wy = H * 0.55; kx = W * 0.2; ky = H * 0.44; bx = W * 0.2; by = H * 0.62; mx = W * 0.2; my = H * 0.77;
      }
      // Window swaps with a quick squash on every change of front app.
      let lastSwap = sc.start;
      for (const x of [sc.start + 0.5, sc.start + 1.0, sc.start + 1.5, b.l2 - 0.1, b.l3 - 0.1]) if (t >= x && x < b.l1 - 0.1 || x >= b.l1 && t >= x) lastSwap = x;
      const pop = 1 - E.out(prog(t, lastSwap, lastSwap + 0.3));
      place(this.win.el, wx, wy + (1 - fade) * 30, 1 - 0.04 * pop, fade);

      let sel = 0, attention = false, palette = 0, focusRow = -1;
      if (mode === 'codex' && t >= b.l1 - 0.1) {
        attention = true;
        sel = t >= b.c.right ? 2 : t >= b.c.up ? 1 : 0;
      } else if (mode === 'claude' && t >= b.l2 - 0.1) {
        sel = t >= b.k.up ? 0 : 1;
        palette = E.back(prog(t, b.k.right + 0.05, b.k.right + 0.3));
      } else if (mode === 'claude') sel = 1;
      if (mode === 'browser') focusRow = t >= b.g.down2 ? 2 : t >= b.g.down1 ? 1 : 0;
      this.win.set(mode, sel, { attention, palette, focusRow });

      const dockY = PORTRAIT ? wy + 340 + 14 : wy + 320 + 14;
      place(this.dock, wx, dockY, 1, fade);
      ['codex', 'claude', 'browser'].forEach((k, i) => {
        const on = k === mode;
        this.dockItems[i].style.transform = `translateY(${on ? -10 : 0}px) scale(${on ? 1.12 : 1})`;
        this.dockItems[i].querySelector('i').style.opacity = on ? 1 : 0;
      });

      place(this.ctrl.el, kx, ky + (1 - fade) * 30, 1, fade);
      this.ctrl.update(this.cues(sc), t);
      const profile = { codex: 'Codex profile', claude: 'Claude profile', browser: 'Generic' }[mode];
      const html = `${tile(mode, 34)}<span style="color:var(--muted);font-weight:500">front app →</span>${profile}`;
      if (this.badge._h !== html) { this.badge.innerHTML = html; this.badge._h = html; }
      place(this.badge, bx, by, 1 + 0.08 * pop, fade);

      const text = {
        codex: ['Recent chat 1', 'Chat that needs you'],
        claude: ['Previous chat', 'Command palette'],
        browser: ['not sent', 'not sent'],
      }[mode];
      this.mapText[0].textContent = text[0];
      this.mapText[1].textContent = text[1];
      this.mapText[2].textContent = 'Arrows · Enter · Escape';
      const hot = (a) => t >= a && t < a + 0.7;
      this.mapRows[0].classList.toggle('on', hot(b.c.up) || hot(b.k.up));
      this.mapRows[1].classList.toggle('on', hot(b.c.right) || hot(b.k.right));
      this.mapRows[2].classList.toggle('on', mode === 'browser' && t >= b.l3);
      this.mapRows.slice(0, 2).forEach((r) => { r.style.opacity = mode === 'browser' && t >= b.l3 - 0.1 ? 0.35 : 1; });
      place(this.map, mx, my, 1, fade);

      this.key(t, [[b.c.up, '⌥⌘1'], [b.c.right, '⌥⌘A'], [b.k.up, 'Previous chat'], [b.k.right, '⌘K'],
        [b.g.down1, '↓'], [b.g.down2, '↓'], [b.g.a, '⏎  Enter']], PORTRAIT ? W / 2 + 330 : wx + 400, dockY, fade);
    },
  };

  // 6 — Command menu (list, then the experimental dial)
  const CODEX_ROWS = ['New Chat', 'Changes', 'Terminal', 'Switch Model', 'Archive Chat'];
  SCENES.menu = {
    build(root) {
      this.tag = sectionTag(root, '05', 'COMMAND MENU');
      this.title = sceneTitle(root, 'One chord. Every command.');
      this.win = makeAppWindow(root, PORTRAIT ? 960 : 1060, PORTRAIT ? 900 : 660);
      this.ov = makeOverlay(root);
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 400 : 380);
      this.focus = el('div', 'abs chip', root, '<i style="background:var(--green)"></i>Codex stays in front');
      this.own = el('div', 'abs chip', root, '<i style="background:var(--gold)"></i>Controller → menu only');
      this.exp = el('div', 'abs chip', root, '<i style="background:#0a84ff"></i>Experimental: Dial');
    },
    beats(sc) {
      const l0 = L(sc, 0), l1 = L(sc, 1), l2 = L(sc, 2), l3 = L(sc, 3);
      return {
        l0, l1, l2, l3,
        bHold: [l0 + 0.3, l0 + 0.95], left: l0 + 0.5, open: l0 + 0.6,
        downs: [0, 1, 2, 3].map((i) => l1 + 0.45 + i * 0.5),
        ups: [l2 + 2.3, l2 + 2.75],
        dial: l3 + 0.35, right: l3 + 1.5,
      };
    },
    cues(sc) {
      const b = this.beats(sc);
      return [{ btn: 'b', t: b.bHold[0], dur: b.bHold[1] - b.bHold[0] }, tap('left', b.left),
        ...b.downs.map((x) => tap('down', x)), ...b.ups.map((x) => tap('up', x)), tap('right', b.right)];
    },
    sounds(sc) {
      const b = this.beats(sc);
      return [{ t: b.open, kind: 'pop' }, { t: b.dial - 0.1, kind: 'whoosh' }, { t: b.dial + 0.05, kind: 'pop' }];
    },
    render(t, sc) {
      this.tag(t, sc);
      this.title(t, sc);
      const b = this.beats(sc);
      const fade = window01(t, sc.start, sc.end - 0.3);
      let wx, wy, kx, ky, cx1, cy1, s;
      if (PORTRAIT) { wx = W / 2; wy = H * 0.4; kx = W / 2; ky = H * 0.73; cx1 = W / 2; cy1 = H * 0.825; s = 1.55; }
      else { wx = W * 0.4; wy = H * 0.55; kx = W * 0.82; ky = H * 0.46; cx1 = W * 0.82; cy1 = H * 0.66; s = 1.4; }
      place(this.win.el, wx, wy + (1 - fade) * 30, 1, fade);
      this.win.set('codex', 0);
      this.win.el.style.filter = t >= b.open ? 'brightness(0.55)' : 'none';

      let sel = 0;
      b.downs.forEach((x, i) => { if (t >= x) sel = i + 1; });
      b.ups.forEach((x) => { if (t >= x) sel -= 1; });
      const dial = t >= b.dial;
      const model = dial
        ? { layout: 'dial', title: 'Codex', items: ['New Chat', 'Changes', 'Terminal', 'More'].map((x) => ({ title: x })), sel: t >= b.right ? 3 : -1 }
        : { layout: 'list', title: 'Codex', items: CODEX_ROWS.map((x) => ({ title: x })), sel };
      this.ov.render(model);
      const openK = E.back(prog(t, b.open, b.open + 0.3));
      const morph = 1 - 0.12 * Math.sin(Math.PI * prog(t, b.dial - 0.12, b.dial + 0.12));
      const ownGlow = window01(t, b.l2 + 1.6, b.l3 - 0.1);
      this.ov.el.style.filter = ownGlow > 0 ? `drop-shadow(0 0 ${18 * ownGlow}px rgba(241,213,140,${0.8 * ownGlow}))` : 'none';
      place(this.ov.el, wx, wy + 10, s * lerp(0.85, 1, openK) * morph, prog(t, b.open, b.open + 0.12) * (1 - prog(t, sc.end - 0.3, sc.end)));

      place(this.ctrl.el, kx, ky + (1 - fade) * 30, 1, fade);
      this.ctrl.update(this.cues(sc), t);
      const fo = window01(t, b.l2 + 0.1, b.l3 - 0.2);
      const oo = window01(t, b.l2 + 1.6, b.l3 - 0.2);
      place(this.focus, cx1, cy1, 1, fo);
      place(this.own, cx1, cy1 + (PORTRAIT ? 0 : 84), 1, PORTRAIT ? oo * (t < b.l2 + 1.6 ? 0 : 1) : oo);
      if (PORTRAIT) place(this.focus, cx1, cy1, 1, fo * (1 - oo));
      place(this.exp, cx1, cy1, 1, window01(t, b.dial, sc.end - 0.3));
    },
  };

  // 7 — App switcher
  const SWITCH_APPS = ['codex', 'claude', 'wechat', 'browser', 'finder', 'terminal'];
  SCENES.switcher = {
    build(root) {
      this.tag = sectionTag(root, '06', 'APP SWITCHER');
      this.title = sceneTitle(root, '⌘⇥, from the couch.');
      this.win = makeAppWindow(root, PORTRAIT ? 960 : 1100, PORTRAIT ? 900 : 660);
      this.ov = makeOverlay(root);
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 400 : 340);
    },
    beats(sc) {
      const l0 = L(sc, 0), l1 = L(sc, 1);
      return { bHold: [l0 + 0.1, l0 + 0.75], open: l0 + 0.6, rights: [l1 + 0.4, l1 + 0.9], left: l1 + 1.5, a: l1 + 2.3 };
    },
    cues(sc) {
      const b = this.beats(sc);
      return [{ btn: 'b', t: b.bHold[0], dur: b.bHold[1] - b.bHold[0] }, ...b.rights.map((x) => tap('right', x)), tap('left', b.left), tap('a', b.a)];
    },
    sounds(sc) { const b = this.beats(sc); return [{ t: b.open, kind: 'pop' }, { t: b.a + 0.08, kind: 'whoosh' }]; },
    render(t, sc) {
      this.tag(t, sc);
      this.title(t, sc);
      const b = this.beats(sc);
      const fade = window01(t, sc.start, sc.end - 0.3);
      let wx, wy, kx, ky, s;
      if (PORTRAIT) { wx = W / 2; wy = H * 0.42; kx = W / 2; ky = H * 0.79; s = 1.55; }
      else { wx = W * 0.44; wy = H * 0.55; kx = W * 0.85; ky = H * 0.55; s = 1.45; }
      const switched = t >= b.a + 0.05;
      const pop = switched ? 1 - E.out(prog(t, b.a + 0.05, b.a + 0.4)) : 0;
      place(this.win.el, wx, wy + (1 - fade) * 30, 1 + 0.05 * pop, fade);
      this.win.set(switched ? 'wechat' : 'codex', switched ? 2 : 0);
      this.win.el.style.filter = t >= b.open && !switched ? 'brightness(0.55)' : 'none';

      let sel = 1;
      b.rights.forEach((x) => { if (t >= x) sel += 1; });
      if (t >= b.left) sel -= 1;
      this.ov.render({ layout: 'strip', title: 'Switch App', items: SWITCH_APPS.map((k) => ({ app: k, title: APPS[k].name })), sel });
      const openK = E.back(prog(t, b.open, b.open + 0.3));
      const vis = t >= b.open && t < b.a + 0.12 ? 1 : 0;
      place(this.ov.el, wx, wy, s * lerp(0.85, 1, openK) * (1 - 0.15 * prog(t, b.a, b.a + 0.12)), vis);

      place(this.ctrl.el, kx, ky + (1 - fade) * 30, 1, fade);
      const hb = t >= b.bHold[0] && t < b.open ? prog(t, b.bHold[0], b.bHold[0] + 0.5) : 0;
      this.ctrl.update(this.cues(sc), t, 0, hb);
    },
  };

  // 8 — Any app's own menu bar
  const WECHAT_ROWS = [
    { title: 'Show Next Unread Chat', pin: 1 }, { title: 'Show Next Chat', pin: 1 },
    { title: 'Show Previous Chat', pin: 1 }, { title: 'Search', pin: 1 }, { title: 'More' },
  ];
  const NEVER = ['Quit WeChat', 'Delete Chat', 'Clear Chat History', 'Log Out'];
  SCENES.appmenu = {
    build(root) {
      this.tag = sectionTag(root, '07', 'ANY APP');
      this.title = sceneTitle(root, 'Any app. Safely.');
      this.dt = makeDesktop(root, PORTRAIT ? 1000 : 1400, PORTRAIT ? 1100 : 760);
      this.dt.setMenus('WeChat', ['File', 'Edit', 'View', 'Window', 'Help']);
      this.win = makeAppWindow(this.dt.desk, PORTRAIT ? 860 : 1000, PORTRAIT ? 700 : 560);
      this.win.set('wechat', 2);
      this.ov = makeOverlay(this.dt.desk);
      this.card = el('div', 'abs card', root, `<div style="font-size:24px;font-weight:750;color:#ff8a80;margin-bottom:14px;white-space:nowrap">✕  Never listed</div>`
        + NEVER.map((n) => `<div style="font-size:26px;margin:10px 0;color:#cfc6ba;white-space:nowrap"><span class="strike">${n}<i></i></span></div>`).join(''));
      this.strikes = [...this.card.querySelectorAll('.strike i')];
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 300 : 260);
    },
    beats(sc) {
      const l0 = L(sc, 0), l1 = L(sc, 1), l2 = L(sc, 2);
      return { l1, l2, bHold: [l0 + 0.3, l0 + 0.9], left: l0 + 0.45, scan: [l0 + 0.7, l0 + 1.9], open: l0 + 2.0,
        downs: [l1 + 1.3, l1 + 1.65, l1 + 2.0], card: l2 + 0.1, strikes: [0.8, 1.35, 1.95, 2.5].map((x) => l2 + x) };
    },
    cues(sc) {
      const b = this.beats(sc);
      return [{ btn: 'b', t: b.bHold[0], dur: b.bHold[1] - b.bHold[0] }, tap('left', b.left), ...b.downs.map((x) => tap('down', x))];
    },
    sounds(sc) {
      const b = this.beats(sc);
      const s = [{ t: b.open, kind: 'pop' }, { t: b.card, kind: 'whoosh' }];
      for (let i = 0; i < 6; i++) s.push({ t: b.scan[0] + i * (b.scan[1] - b.scan[0]) / 6, kind: 'tick' });
      b.strikes.forEach((x) => s.push({ t: x, kind: 'slam' }));
      return s;
    },
    render(t, sc) {
      this.tag(t, sc);
      this.title(t, sc);
      const b = this.beats(sc);
      const fade = window01(t, sc.start, sc.end - 0.3);
      const dx = PORTRAIT ? W / 2 : W * 0.43, dy = PORTRAIT ? H * 0.43 : H * 0.57;
      place(this.dt.el, dx, dy + (1 - fade) * 30, 1, fade);
      const dw = this.dt.w, dh = this.dt.h - 34;
      place(this.win.el, dw / 2, dh / 2 + 10, 1, 1);
      this.win.el.style.filter = t >= b.open ? 'brightness(0.55)' : 'none';

      // The reader walks the menu bar left to right, then the overlay opens.
      const titles = [this.dt.appEl, ...this.dt.menuEls];
      const scanI = t >= b.scan[0] && t < b.scan[1] ? Math.floor(prog(t, b.scan[0], b.scan[1]) * titles.length) : -1;
      titles.forEach((m, i) => m.classList.toggle('on', i === scanI));

      let sel = 0;
      b.downs.forEach((x) => { if (t >= x) sel += 1; });
      this.ov.render({ layout: 'list', title: 'WeChat', items: WECHAT_ROWS, sel });
      const openK = E.back(prog(t, b.open, b.open + 0.3));
      const slide = E.inOut(prog(t, b.card - 0.1, b.card + 0.4));
      const ox = PORTRAIT ? dw / 2 : dw / 2 - 250 * slide;
      const oy = PORTRAIT ? dh / 2 - 170 * slide : dh / 2;
      place(this.ov.el, ox, oy, (PORTRAIT ? 1.5 : 1.3) * lerp(0.85, 1, openK), prog(t, b.open, b.open + 0.12));

      const co = prog(t, b.card, b.card + 0.35);
      const cxp = PORTRAIT ? W / 2 : dx + 390, cyp = PORTRAIT ? dy + 300 : dy + 20;
      place(this.card, cxp + (1 - E.out(co)) * 60, cyp, 1.15, co);
      this.strikes.forEach((s, i) => { s.style.width = `calc(${(E.out(prog(t, b.strikes[i], b.strikes[i] + 0.25)) * 100).toFixed(1)}% + 8px)`; });

      const kx = PORTRAIT ? W / 2 : W * 0.89, ky = PORTRAIT ? H * 0.785 : H * 0.8;
      place(this.ctrl.el, kx, ky + (1 - fade) * 30, 1, fade);
      this.ctrl.update(this.cues(sc), t);
    },
  };

  // 9 — Reliable: notices, login, sleep, permissions, menu-bar entry
  const DROP_ITEMS = ['Launch at Login  ✓', 'Open Input Monitor…', 'Show Controller Menu', 'Show App Switcher', '—', 'Open Config File', 'Reload Config', '—', 'Quit PocketAgentRemote'];
  SCENES.reliable = {
    build(root) {
      this.tag = sectionTag(root, '08', 'ALWAYS ON');
      this.title = sceneTitle(root, 'Tells you. Stays on.');
      this.dt = makeDesktop(root, PORTRAIT ? 1000 : 1400, PORTRAIT ? 860 : 600);
      this.dt.setMenus('Chrome', ['File', 'Edit', 'View', 'History', 'Window', 'Help']);
      this.win = makeAppWindow(this.dt.desk, PORTRAIT ? 860 : 1000, PORTRAIT ? 640 : 440);
      this.win.set('browser', 0, { focusRow: -1 });
      this.toast = makeToast(this.dt.desk);
      this.drop = el('div', 'drop', this.dt.desk, DROP_ITEMS.map((x) => (x === '—' ? '<hr>' : `<div>${x}</div>`)).join(''));
      this.dropRows = [...this.drop.querySelectorAll('div')];
      this.ov = makeOverlay(this.dt.desk);
      this.cursor = el('div', 'abs', this.dt.desk, CURSOR);
      this.tiles = [
        ['Launch at Login', 'starts with your Mac', '<div class="sw" style="width:64px;height:38px;border-radius:19px;background:#3a3431;position:relative"><i style="position:absolute;top:4px;left:4px;width:30px;height:30px;border-radius:50%;background:#fff"></i></div>'],
        ['Survives sleep', 'no stuck keys after wake', '<div class="ms" style="font-size:44px;width:64px;text-align:center">☾</div>'],
        ['Permission watch', 'warns the moment it’s lost', '<div style="font-size:44px;width:64px;text-align:center;color:#ffb340">⚠</div>'],
      ].map(([h, p, icon]) => el('div', 'abs tcard', root, `${icon}<div><h4>${h}</h4><p>${p}</p></div>`));
      this.sw = this.tiles[0].querySelector('.sw');
      this.moon = this.tiles[1].querySelector('.ms');
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 260 : 240);
    },
    beats(sc) {
      const l0 = L(sc, 0), l1 = L(sc, 1), l2 = L(sc, 2);
      return {
        l1, l2, bHold: [l0 + 0.3, l0 + 0.8], up: l0 + 0.45, toast: [l0 + 0.55, l0 + 3.55],
        tiles: [l1 + 0.0, l1 + 1.25, l1 + 2.35], lost: [l1 + 2.5, l2 - 0.15],
        cur: [l2 + 0.0, l2 + 0.5], dropOpen: l2 + 0.55, hover: l2 + 1.4, click: l2 + 2.1,
      };
    },
    cues(sc) {
      const b = this.beats(sc);
      return [{ btn: 'b', t: b.bHold[0], dur: b.bHold[1] - b.bHold[0] }, tap('up', b.up)];
    },
    sounds(sc) {
      const b = this.beats(sc);
      return [{ t: b.toast[0], kind: 'pop' }, ...b.tiles.map((x) => ({ t: x, kind: 'slam' })), { t: b.lost[0], kind: 'pop' },
        { t: b.dropOpen, kind: 'tick' }, { t: b.click, kind: 'tick' }, { t: b.click + 0.1, kind: 'pop' }];
    },
    render(t, sc) {
      this.tag(t, sc);
      this.title(t, sc);
      const b = this.beats(sc);
      const fade = window01(t, sc.start, sc.end - 0.3);
      const dx = PORTRAIT ? W / 2 : W * 0.46, dy = PORTRAIT ? H * 0.38 : H * 0.47;
      place(this.dt.el, dx, dy + (1 - fade) * 30, 1, fade);
      const dw = this.dt.w, dh = this.dt.h - 34;
      place(this.win.el, dw / 2, dh / 2 + 20, 1, 1);

      // Toasts sit near the top of the screen, like the real one.
      const lost = t >= b.lost[0] && t < b.lost[1];
      const tIn = lost ? b.lost[0] : b.toast[0], tOut = lost ? b.lost[1] - 0.2 : b.toast[1];
      this.toast.textContent = lost ? 'Accessibility permission lost: keys are being dropped. Re-enable it in Settings'
        : "Generic mode doesn't support Recent Chat 1";
      const to = window01(t, tIn, tOut, 0.2);
      place(this.toast, dw / 2, 24 + 32 + (1 - E.out(prog(t, tIn, tIn + 0.25))) * -30, PORTRAIT ? 1.45 : 1.3, to);
      this.dt.ctl.style.color = lost ? '#ffb340' : 'var(--gold-lite)';

      // Menu-bar dropdown, driven by a pointer.
      const iconX = dw - 16 - 70 - 16 - 21, iconY = -17;
      const hoverY = 4 + (6 + 2 * 33 + 16) * 1.35;
      let px = dw * 0.55, py = dh * 0.55;
      const k1 = E.inOut(prog(t, b.cur[0], b.cur[1]));
      px = lerp(px, iconX, k1); py = lerp(py, iconY, k1);
      const k2 = E.inOut(prog(t, b.dropOpen + 0.3, b.hover));
      px = lerp(px, iconX - 200, k2); py = lerp(py, hoverY + 8, k2);
      const curO = t >= b.cur[0] && t < b.click + 0.6 ? 1 : 0;
      place(this.cursor, px + 17, py + 22, t >= b.click && t < b.click + 0.1 ? 0.85 : 1, curO * fade);
      const dropO = t >= b.dropOpen && t < b.click ? 1 : 0;
      this.drop.style.right = '100px';
      this.drop.style.top = '4px';
      this.drop.style.transformOrigin = 'top right';
      this.drop.style.transform = 'scale(1.35)';
      this.drop.style.opacity = dropO;
      this.dt.ctl.classList.toggle('on', dropO > 0);
      this.dropRows.forEach((r, i) => r.classList.toggle('on', i === 2 && t >= b.hover));
      this.ov.render({ layout: 'list', title: 'Chrome', items: ['New Tab', 'New Window', 'Reopen Closed Tab', 'Find…', 'More'].map((x) => ({ title: x })), sel: 0 });
      const oo = E.back(prog(t, b.click + 0.1, b.click + 0.4));
      place(this.ov.el, dw / 2, dh / 2 + 30, (PORTRAIT ? 1.3 : 1.1) * lerp(0.85, 1, oo), prog(t, b.click + 0.1, b.click + 0.2) * (1 - prog(t, sc.end - 0.3, sc.end)));

      // Three promise cards.
      this.tiles.forEach((c, i) => {
        const a = b.tiles[i];
        const o = window01(t, a, b.l2 - 0.2, 0.25);
        const x = PORTRAIT ? W / 2 : W * 0.46 + (i - 1) * 520;
        const y = PORTRAIT ? H * 0.64 + i * 175 : H * 0.835;
        place(c, x, y + (1 - E.out(prog(t, a, a + 0.3))) * 40, PORTRAIT ? 1.25 : 1, o);
      });
      const on = E.inOut(prog(t, b.tiles[0] + 0.35, b.tiles[0] + 0.6));
      this.sw.style.background = on > 0.5 ? 'var(--green)' : '#3a3431';
      this.sw.firstChild.style.transform = `translateX(${26 * on}px)`;
      this.moon.textContent = t >= b.tiles[1] + 0.6 ? '☀' : '☾';
      this.moon.style.color = t >= b.tiles[1] + 0.6 ? 'var(--gold-lite)' : '#9ab';

      const kx = PORTRAIT ? W / 2 : W * 0.915, ky = PORTRAIT ? H * 0.66 : H * 0.45;
      place(this.ctrl.el, kx, ky, 1, fade * (1 - prog(t, b.l1 - 0.3, b.l1)));
      this.ctrl.update(this.cues(sc), t);
    },
  };

  // 10 — Outro
  SCENES.outro = {
    hideCaption: () => true,
    build(root) {
      this.ctrl = makeController(root);
      size(this.ctrl.el, PORTRAIT ? 560 : 460);
      this.name = headline(root, PORTRAIT ? 104 : 120);
      this.sub = el('div', 'abs kt', root);
      this.sub.style.fontSize = (PORTRAIT ? 54 : 52) + 'px';
      this.sub.style.color = 'var(--gold-lite)';
      this.foot = el('div', 'abs', root, `<div style="display:flex;gap:16px">${['macOS', 'Codex', 'Claude', 'IINE Gamebrick'].map((x) => `<span class="chip" style="font-size:24px;padding:10px 20px">${x}</span>`).join('')}</div>`);
      this.black = el('div', 'abs', root);
      this.black.style.cssText += `;width:${W}px;height:${H}px;background:#000`;
    },
    cues(sc) { return [tap('a', L(sc, 1) + 0.05, 0.16)]; },
    sounds(sc) { return [{ t: L(sc, 0) - 0.03, kind: 'slam' }, { t: L(sc, 1) + 0.2, kind: 'chime' }]; },
    render(t, sc) {
      const cx = W / 2;
      const s0 = sc.start;
      const float = Math.sin((t - s0) * 2) * 8;
      place(this.ctrl.el, cx, (PORTRAIT ? H * 0.34 : H * 0.3) + float + tw(t, s0, s0 + 0.6, 80, 0), tw(t, s0, s0 + 0.6, 0.4, 1, E.back),
        prog(t, s0, s0 + 0.2), `rotate(${tw(t, s0, s0 + 0.6, 20, 0, E.back)}deg)`);
      this.ctrl.update(this.cues(sc), t);
      kinetic(this.name, 'PocketAgentRemote', t, L(sc, 0) - 0.05);
      place(this.name, cx, PORTRAIT ? H * 0.54 : H * 0.6, 1, 1);
      kinetic(this.sub, 'Your agents, one pocket away.', t, L(sc, 1) - 0.05, { stagger: 0.08 });
      place(this.sub, cx, PORTRAIT ? H * 0.61 : H * 0.72, 1, 1);
      const fo = prog(t, L(sc, 1) + 0.6, L(sc, 1) + 1.0);
      place(this.foot, cx, (PORTRAIT ? H * 0.69 : H * 0.84) + (1 - fo) * 20, PORTRAIT ? 1 : 1, fo);
      const end = TIMING.total;
      place(this.black, cx, H / 2, 1, prog(t, end - 0.9, end - 0.1));
    },
  };

  // ---------- orchestration ----------
  const order = TIMING.scenes.filter((s) => SCENES[s.id]);
  for (const sc of order) {
    const def = SCENES[sc.id];
    def.root = el('div', 'scene', sceneLayer);
    def.build(def.root);
  }

  function cuesAll() {
    const out = [];
    for (const sc of order) {
      const def = SCENES[sc.id];
      for (const p of def.cues(sc)) out.push({ t: +p.t.toFixed(3), kind: 'click', btn: p.btn, dur: +p.dur.toFixed(3) });
      if (def.sounds) for (const s of def.sounds(sc)) out.push({ t: +s.t.toFixed(3), kind: s.kind });
      if (sc.start > 0) out.push({ t: sc.start - 0.3, kind: 'whoosh' });
    }
    return out.sort((a, b) => a.t - b.t);
  }

  // Camera: punch in on the cut, drift in slowly, push out on the way to the next cut, and
  // shake a little on every press so the button feels like it hit something.
  function camera(def, sc, t, first) {
    const punch = first ? 0 : 1 - E.out(prog(t, sc.start, sc.start + 0.45));
    const exit = E.inOut(prog(t, sc.end - 0.2, sc.end));
    let sx = 0, sy = 0;
    for (const p of def.cues(sc)) {
      const d = t - p.t;
      if (d < 0 || d > 0.35) continue;
      const a = 7 * Math.exp(-d / 0.08);
      sx += a * Math.sin(d * 71);
      sy += a * Math.cos(d * 53);
    }
    const s = 1 + 0.08 * punch + 0.025 * prog(t, sc.start, sc.end) + 0.06 * exit;
    def.root.style.transform = `translate(${sx.toFixed(2)}px, ${sy.toFixed(2)}px) scale(${s.toFixed(4)})`;
    def.root.style.opacity = (1 - exit * 0.7).toFixed(3);
  }

  const DROP = TIMING.scenes[1].start;
  function backdrop(t) {
    // A kick on every beat after the drop; before it, the hook's own lines are the pulse.
    let since = t >= DROP ? (t - DROP) % BEAT : 9;
    for (const l of TIMING.scenes[0].lines) if (t >= l.start && t < DROP) since = Math.min(since, t - l.start);
    const kick = Math.exp(-since / 0.14);
    glow.style.transform = `scale(${(1 + 0.05 * kick).toFixed(4)})`;
    glow.style.opacity = (0.55 + 0.45 * kick).toFixed(3);
    grid.style.backgroundPosition = `${(t * 14).toFixed(1)}px ${(t * 7).toFixed(1)}px`;
    grid.style.opacity = (0.6 + 0.4 * kick).toFixed(3);

    let cut = null;
    for (const sc of TIMING.scenes.slice(1)) if (t >= sc.start - 0.25 && t < sc.start + 0.4) cut = sc.start;
    flash.style.opacity = cut != null && t >= cut ? (0.22 * (1 - prog(t, cut, cut + 0.18))).toFixed(3) : 0;
    if (cut != null) {
      const k = E.inOut(prog(t, cut - 0.25, cut + 0.4));
      stripes.style.transform = `translate(-50%, -50%) rotate(-12deg) translateX(${lerp(-110, 110, k).toFixed(2)}%)`;
      stripes.style.display = 'block';
    } else stripes.style.display = 'none';
  }

  function seek(t) {
    backdrop(t);
    order.forEach((sc0, i) => {
      const def = SCENES[sc0.id];
      const sc = i === order.length - 1 ? { ...sc0, end: TIMING.total + 1 } : sc0;
      const on = t >= sc.start && t < sc.end;
      def.root.style.display = on ? 'block' : 'none';
      if (on) {
        camera(def, sc, t, i === 0);
        def.render(t, sc);
      }
    });
    let text = '';
    for (const sc of TIMING.scenes) {
      sc.lines.forEach((l, i) => {
        const hide = SCENES[sc.id] && SCENES[sc.id].hideCaption && SCENES[sc.id].hideCaption(i);
        if (!hide && t >= l.start - 0.05 && t < l.end + 0.25) text = l.text;
      });
    }
    caption.textContent = text;
  }

  window.seek = seek;
  window.cuesAll = cuesAll;
  window.VIDEO = { W, H, total: TIMING.total, scenes: order.map((s) => ({ id: s.id, start: s.start, end: s.end })) };
  seek(+(Q.get('t') || 0));
})();
