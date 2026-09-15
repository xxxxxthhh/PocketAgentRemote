# Hardware Probe — IINE L1162

> Phase 0 deliverable for `iine-l1162-codex-claude-macos-implementation-spec-v0.1.md` (§4, §24).
>
> **Status: Phase 0 complete — 2026-09-15.** All three platform modes characterised (H §5, C/XInput §6,
> C/generic §6.8) and all ten spec §24 questions answered from measurement. Summary and implementation
> implications: `docs/phase0-summary.md`.
> `Answer` fields are filled in only from real captures — nothing here is guessed. Per spec §24, none
> of them may be.

Last updated: 2026-09-15

---

## 0. Environment

| Item | Value |
|---|---|
| macOS | 27.0 (build 26A428), arm64 |
| Xcode | 27.0 (27A5228h) |
| Swift | 6.4 |
| Probe binary | `agentprobe` (SwiftPM) / `.build/PocketAgentProbe.app` |
| Probe source | `Sources/AgentProbe/` |
| Controller connected at bootstrap | **no** — Bluetooth device list and USB device list showed no IINE device |
| Controller tested | **H mode** (§5) and **C mode / XInput variant** (§6), both 2026-09-15. C-mode `Wireless Controller` variant not yet captured. |

Verified at bootstrap time (real command output, not assumed):

- `GCController.controllers()` → `count=0`
- `IOHIDManagerOpen` on all devices → `IOReturn=success`
- HID device count → `17`, none with primary usage page/usage `1/4` (Joystick), `1/5` (GamePad) or `1/8` (Multi-axis)
- `watch --with-keyboard` → `IOHIDManagerOpen IOReturn=success` and matched
  `product="Apple Internal Keyboard / Trackpad"` (usage `1/6`) without an extra permission
  prompt on this machine
- `scripts/make-app.sh release` → ad-hoc signed bundle, `Bundle.main.bundleIdentifier`
  reported as `com.pocketagentremote.probe` at runtime

So the toolchain and both input backends work on this machine; only the device-specific
answers are outstanding.

---

## 1. How to run

### 1.1 Build

```bash
swift build                       # debug binary at .build/debug/agentprobe
./scripts/make-app.sh release     # .build/PocketAgentProbe.app (ad-hoc signed)
```

The `.app` wrapper exists because GameController wireless discovery, Bluetooth usage and
stable TCC (Accessibility / Input Monitoring) grants behave better for a bundled, signed app
than for a bare binary launched from a shell. Both forms work for plain enumeration.

### 1.2 Identity snapshot (safe, read-only, no device seized)

```bash
./.build/debug/agentprobe list
```

Prints every controller macOS exposes to GameController plus every HID device with
`product / manufacturer / vid / pid / transport / primaryUsagePage/Usage / serial / location`.
This does not register input callbacks, so it can be run while typing.

Use it to answer Q1, Q2, Q7 and the identity part of Q10: with the controller in C mode,
look for `transport=Bluetooth` entries and note the `product` string and usage page/usage.

### 1.3 Live capture

```bash
# capture a session to JSONL for later diffing
mkdir -p logs
./.build/PocketAgentProbe.app/Contents/MacOS/agentprobe watch \
    --log logs/probe-$(date +%Y%m%d-%H%M%S).jsonl

# H mode / keyboard fallback (also watches keyboard-usage HID devices)
./.build/PocketAgentProbe.app/Contents/MacOS/agentprobe watch --with-keyboard

# bypass GameController entirely (spec §4.2 fallback path)
./.build/PocketAgentProbe.app/Contents/MacOS/agentprobe watch --hid-only

# scripted, self-terminating session
./.build/PocketAgentProbe.app/Contents/MacOS/agentprobe watch --duration 60 --log logs/x.jsonl
```

Stop with `Ctrl-C`. Log tags to read:

| Tag | Meaning |
|---|---|
| `GC-DEVICE` | `vendorName`, `productCategory`, `isAttachedToDevice`, `playerIndex` |
| `GC-ELEMENTS` / `GC-ELEMENT` | every element in `physicalInputProfile`, with kind and localized name |
| `GC-BUTTON` | press/release with value, plus the full held set |
| `GC-AXIS` / `GC-DPAD` / `GC-STICK-*` | analog values |
| `GC-CONNECT` / `GC-DISCONNECT` | hot-plug events; disconnect clears internal state |
| `HID-DEVICE` / `HID-MATCH` / `HID-REMOVE` | raw device identity and hot-plug |
| `HID-VALUE` | raw input values: usage page, usage, cookie, value, logical range |

Any line ending in `<== CHORD` means two or more inputs were held simultaneously — that is
the direct evidence for Q8.

### 1.4 Permissions

- `list` needs nothing extra on this machine (verified).
- `watch --with-keyboard` opened successfully here without a prompt (verified). If it ever
  fails, the cause is **Input Monitoring** (System Settings → Privacy & Security → Input
  Monitoring): the probe logs `open failed — likely missing Input Monitoring permission for
  this binary` together with the raw `IOReturn` code.
- Rebuilding the binary changes its code signature, so an ad-hoc signed `.app` must be
  re-added to the permission list after each rebuild. Re-run `./scripts/make-app.sh` and
  re-grant if events stop appearing.

---

## 2. Test matrix (spec §4.2)

| # | Device mode | Expected | Status | Result |
|---|---|---|---|---|
| 1 | C / XInput-like (`XINPUT - Xbox Wireless Controller`) | GCController recognises it | ☑ tested 2026-09-15 | Reported as `Xbox Wireless Controller` / `productCategory=Xbox One`, 35 elements, `extendedGamepad` + `microGamepad` available — see §6 |
| 2 | C / generic (`Wireless Controller`) | GCController recognises it | ☐ not tested | Switch with **pairing key + A** (official manual); not yet captured |
| 3 | H / keyboard (`IINE-keyboard`) | visible for fallback only | ☑ tested 2026-09-15 | Enumerated by IOHIDManager as a BLE keyboard; invisible to GameController; leaks all six inputs as normal keystrokes — see §5 |

Which C-mode variant wins is Q3. Record the switched-to variant and why.

### Physical controls (official manual, 说明书 5 → 按键说明)

The device has exactly **six** usable inputs plus a pairing key and a platform switch:

```text
十字键 (D-pad)   A 键   B 键        ← the only user inputs
配对键 (pairing)  切换平台 (T / I / C)  充电 C 口  挂绳口  指示灯
```

There is no X / Y / shoulder / trigger / stick hardware — the Xbox profile in §6.2 advertises those
elements, but none of them can ever fire.

### Platform modes (official manual, 说明书 5)

The platform switch has **three** positions — **T / C / H** — and each position has two variants,
toggled with **pairing key + A**:

| Switch | Mode | Default device | Variant (pairing key + A) |
|---|---|---|---|
| T | 多媒体触控模式 (multimedia / touch) | `IINE-Control` (touch) | `IINE-Phone` (multimedia) |
| C | 手柄模式 (gamepad) | `Xbox Wireless Controller` (XINPUT) | `Wireless Controller` (Gamepad) |
| H | 键盘鼠标模式 (keyboard / mouse) | `IINE_keyboard` (+ mouse) | not documented |

Pairing sequence: slide the platform switch to the mode, then **hold the pairing key ~3 s** — the LED
blinks (white in T, red in C) and goes solid when paired.

**The spec (§3) is incomplete here: it names only C and H and omits T mode entirely.** T mode targets
media playback rather than agent control, so it is out of scope for this project, but the missing
mode should be recorded so a user who lands on it is not confused.

### Device identity is mode-dependent (verified)

The same physical controller presents as a **completely different device** per mode — different
product string, VID/PID, usage and location:

| Switch | Product string | VID / PID | Primary usage | Location |
|---|---|---|---|---|
| C / XInput | `Xbox Wireless Controller` | `0x045e` / `0x0b13` | `1/5` GamePad | `4043049926` |
| C / generic | `Wireless Controller` | `0x4353` / `0x9b09` | `1/5` GamePad | `2142999777` |
| H | `IINE_keyboard` | `0x4353` / `0x9b09` | `1/6` Keyboard | `3611767360` |

**VID/PID alone does not identify a device.** The generic C variant and the H-mode keyboard share
`0x4353`/`0x9b09` exactly; only the interface usage tells them apart. Any device matching logic must
consider product string and/or usage, not just vendor and product IDs. Location IDs also differ per
mode, so they are not stable either.

Moving the platform switch produces a clean hot-plug cycle — observed 2026-09-15 22:09 when the switch
was moved C → H:

```text
t=303.27  HID-REMOVE     product="Xbox Wireless Controller" (reconnect will fire a new MATCH)
t=303.27  GC-DISCONNECT  controller disconnected | cleared held state: -
```

The app must therefore treat a mode change as an ordinary disconnect/connect pair and re-resolve the
device, **not** assume one stable device identity for the whole session.

The H-mode identity is reproducible: two independent sessions (§5.1 and this switch) reported the
identical `vid=17235 pid=39689 serial=000000 location=3611767360`.

---

## 3. Questions to answer (spec §24)

> Do not guess. Fill in from probe output, and paste the raw lines as evidence.

**Q1. What `vendorName` does macOS report?**

- Answer: **`Xbox Wireless Controller`** (C mode, XInput variant, 2026-09-15)
- Evidence: `GC-DEVICE vendorName=Xbox Wireless Controller productCategory=Xbox One attachedToDevice=false playerIndex=-1`

**Q2. What `productCategory`?**

- Answer: **`Xbox One`** (C mode, XInput variant)
- Evidence: same `GC-DEVICE` line as Q1

**Q3. Which C mode works better — XInput-like or Wireless Controller?**

- Answer: **the XInput variant, decisively — because it is the only one GameController can see.**
  - `Xbox Wireless Controller` (XINPUT): 35 elements, `extendedGamepad` available, the full GC path
    works once `shouldMonitorBackgroundEvents` is set (§6.5–6.6).
  - `Wireless Controller` (generic): **`GCController.controllers()` stays `count=0` and no
    `GCControllerDidConnect` ever fires** (§6.8); it exists only at the IOHIDManager layer.
  - Both variants deliver the same six inputs at the HID layer, so the generic variant is usable —
    but only through the raw-HID path.
- Consequence: the IOHIDManager path is **mandatory, not merely a fallback**, unless the project
  chooses to support only the XInput variant — and then it must detect and reject the generic one
  rather than silently doing nothing.
- Switch procedure observed to work: hold the pairing key (Q7) and press A → the device disconnects
  and returns as the other variant. Here it needed a **manual reconnect** in macOS.
- Note: H mode is a third, distinct variant and has been captured; see §5.
- Evidence: §6.8, manual `说明书 5 → 手柄模式`

**Q4. Is `extendedGamepad` available?**

- Answer: **yes in the XInput C mode** — both `extendedGamepad` and `microGamepad` are non-nil.
  Not available in the **generic C variant** nor in **H mode**: GameController sees no controller at
  all in either (`controllers()` → `count=0`).
- Evidence: `GC-PROFILE extendedGamepad available` / `GC-PROFILE microGamepad available` (§6.2),
  `after 1.5s settle: GCController.controllers() count=0` (§6.8)

**Q5. How are D-pad controls exposed?**

- Answer (C / XInput): a **hat switch** — page `0x1`, usage `0x39`, cookie 33, logical range `[1,8]`,
  value `0` = centred; **1 = Up, 3 = Right, 5 = Down, 7 = Left** (odd values only; no diagonals).
  GameController additionally exposes `Direction Pad` + `Direction Pad Up/Down/Left/Right` and X/Y
  axes (§6.2).
- Answer (C / generic): the **same hat usage with a different cookie and range** — cookie 29,
  logical range `[0,7]`, **`15` = centred**, and **0 = Up, 2 = Right, 4 = Down, 6 = Left** (§6.8).
  Cookies and logical ranges therefore must never be hardcoded.
- Answer (H mode): four independent keyboard usages — `0x52` ArrowUp, `0x51` ArrowDown,
  `0x50` ArrowLeft, `0x4f` ArrowRight.
- Evidence: §6.3, §6.4, §6.8, §5.2

**Q6. How are A/B exposed?**

- Answer (C / XInput): plain HID buttons — **A = `Button 1` (page `0x9`, usage `0x1`, cookie 11),
  B = `Button 2` (page `0x9`, usage `0x2`, cookie 12)**.
- Answer (C / generic): same usages, **different cookies — A = `Button 1` cookie 7,
  B = `Button 2` cookie 8** (§6.8).
- Answer (H mode): **A = `Enter` (usage `0x28`, cookie 61), B = `Space` (usage `0x2c`, cookie 65).**
  This contradicts the spec's working assumption that B behaves like Escape — in H mode B is Space.
- In every mode only these two button usages ever appear; the profile's X/Y/shoulder/trigger elements
  never fire because the hardware does not exist.
- Evidence: §6.3, §6.4, §6.8, §5.2

**Q7. Is the pairing button exposed?**

- Answer: **yes — verified 2026-09-15 22:12 on the XInput variant.** Holding it produced
  `Button 13` (page `0x9`, usage `0xd`, cookie 23) at value 1; while it was held, pressing A
  (`Button 1`) disconnected and re-enumerated the controller as the other variant:

  ```text
  t=34.17  Xbox Wireless Controller  Button 13 page=0x9 usage=0xd cookie=23 value=1
  t=35.94  Xbox Wireless Controller  Button 1  page=0x9 usage=0x1 cookie=11 value=1
  t=37.96  HID-REMOVE product="Xbox Wireless Controller"
  ```

  This contradicts spec §3's warning that the pairing key may not appear in the HID report at all.
- **Recommendation: still do not map it.** It is a destructive hardware combo — it drops the
  connection and switches the device variant — and its behaviour on the generic variant is unverified.
- The same `Button 13` is also the **power control**: on the generic variant, holding it (observed
  `value=1` at t=10.03 s) powered the controller off ~2 s later (`HID-REMOVE` at t=12.08 s). That is a
  second reason to keep it out of the button map.
- Evidence: §6.8, `logs/probe-step4-powercycle-20260915-221536.jsonl`

**Q8. Are simultaneous B + direction presses observable?**

- Answer (H mode): **yes.** `Space` (B) stayed held at value 1 while all four arrows were pressed
  and released, and the keyboard `ErrorRollOver` element (usage `0x01`) never left 0.
- Answer (C mode): **yes.** `Button 2` (B) stayed at value 1 from t=42.80 s while the hat switch
  reported all four directions, and was released at t=45.07 s. See the §6.4 timeline.
- Evidence: §5.3 (H), §6.4 (C)

**Q9. Does macOS generate any unwanted keyboard events in C mode?**

- Answer (C mode): **no leakage — verified 2026-09-15 22:03.** With a blank TextEdit document
  frontmost, all six inputs were pressed: the probe recorded all six (12 `GC-BUTTON` events) while
  the number of keyboard-usage `HID-VALUE` events was **0**, and the document body stayed empty.
  In C mode the only IINE device is a `1/5` (GamePad) BLE device — there is no keyboard interface
  for macOS to deliver as text.
- Answer (H mode): **yes, extensively** — every one of the six inputs reaches the frontmost app as
  an ordinary keystroke. Verified at the OS level (TextEdit document `testFile.rtf` in the repo root
  received the typed characters). This confirms spec §23 decision 2: H mode cannot be the primary path.
- Evidence: §6.1 device list + step-2 capture (`logs/probe-step2-leak-20260915-220318.jsonl`), §5.4

**Q10. Does Bluetooth reconnect preserve the same controller identity?**

- Answer: **verified in both C variants — 2026-09-15.**
  - **XInput (primary path), 22:37:** powered off → powered on gave `HID-REMOVE` + `GC-DISCONNECT`,
    then `HID-MATCH` + `GC-CONNECT` + 35 elements automatically ~20 s later; `product / vid / pid /
    serial / location` all identical; both paths cleared held state; all six inputs worked again in
    the same process (§6.7).
  - **Generic variant, 22:24:** automatic reconnect, identical `product/vid/pid/serial`; input live in
    the same process (§6.7).
- Also verified: a mode-switch reconnect (C → H → C) restored the XInput identity field-for-field and
  all six inputs came back in the same process (§6.7).
- Evidence: §6.7, `logs/probe-step6b-xinput-powercycle-20260915-223641.jsonl`,
  `logs/probe-step4b-poweron-20260915-222108.jsonl`

---

## 4. Acceptance criteria (spec §4.3)

All must hold before Phase 1 starts. Assessed per mode, since the two modes are different devices
as far as macOS is concerned.

| Criterion | H mode (2026-09-15) | C / XInput (2026-09-15) | C / generic (2026-09-15) |
|---|---|---|---|
| 6 primary inputs independently identifiable | ☑ yes (6 distinct usages) | ☑ yes (2 buttons + hat switch; `buttonA`/`buttonB`/`dpad` in GC) | ☑ yes at HID level only — **GameController never connects** (§6.8) |
| press **and** release observable | ☑ yes (value 1 / 0 per press) | ☑ yes (HID and GC layers both) | ☑ yes (HID) |
| D-pad produces no spurious repeats | ☐ not tested | ☑ yes — holding ↑ 2.55 s gave one press and one release (§6.5) | ☐ not tested |
| `B + direction` chord observable as a real simultaneous hold | ☑ yes | ☑ yes (§6.4 HID, §6.5 GC) | ☐ not tested |
| controller input leaks no ordinary keyboard characters | ✗ **fails** — every input leaks as a keystroke | ☑ **passes** — TextEdit stayed empty, 0 keyboard-usage events (Q9) | ☐ not tested |
| reconnect works without restarting the app | ☐ not tested | ☑ **passes** — power cycle: `GC-DISCONNECT` → `GC-CONNECT`, identical identity, 35 elements and all six inputs restored in-process (§6.7) | ☑ **passes** — power cycle auto-reconnected with identical identity, input live in the same process (§6.7) |

---

## 5. H mode capture — 2026-09-15 (verified)

Session: `logs/probe-H-mode-20260915-214017.jsonl`, 1090 records, 150 s,
command `agentprobe watch --with-keyboard --duration 150 --log …`.

### 5.1 Identity

```text
product="IINE_keyboard" manufacturer="zhuhai_jieli"
vid=17235 (0x4353)  pid=39689 (0x9b09)
transport="Bluetooth Low Energy"  primaryUsagePage/Usage=1/6 (Generic Desktop / Keyboard)
serial="000000"  location=3611767360  version=283
```

- Exactly **one** IINE device is exposed in H mode — no separate `IINE_mouse` device appeared in
  the device list.
- `GCController.controllers()` → `count=0`: the GameController framework does not see the
  controller at all in H mode.

### 5.2 Verified button → HID mapping

Every captured value change from the controller, with stable element cookies:

| Physical input | Reported key | Usage | Cookie | Press/release observed |
|---|---|---|---|---|
| ↑ | `ArrowUp` | `0x52` | 103 | value 1 → 0 |
| ↓ | `ArrowDown` | `0x51` | 102 | value 1 → 0 |
| ← | `ArrowLeft` | `0x50` | 101 | value 1 → 0 |
| → | `ArrowRight` | `0x4f` | 100 | value 1 → 0 |
| A | `Enter` | `0x28` | 61 | value 1 → 0 |
| B | `Space` | `0x2c` | 65 | value 1 → 0 |

All six were pressed twice standalone and once inside a chord; every press produced exactly one
`value=1` followed by one `value=0`.

### 5.3 Noise the implementation must filter

Three element kinds appear in the *same* report as the real keys and are not physical controls:

| Element | Behaviour | Verdict |
|---|---|---|
| page `0x7`, usage `0xffffffff`, cookie 15 | rises to 40–82 on every press, returns to 0 on release | vendor/activity element — ignore |
| page `0x7`, usage `0xffffffff`, cookie 14 | packed value, e.g. `21036 = 82×256 + 44` while `Space` was held; overflows the declared logical range `[0,255]` | vendor element — ignore |
| page `0x7`, usage `0xffffffff`, cookie 16 | appears only during the chord round, 79–82 → 0 | vendor element — ignore |
| page `0x7`, usage `0x01`, cookie 22 | `ErrorRollOver`, reported around every press, **always 0** | not a button — ignore |

Rule for the real input source: **accept only elements with a valid, known usage**, and reject
values outside `[logicalMin, logicalMax]`. Matching by HID usage alone is not enough.

### 5.4 Leakage into the frontmost app (Q9)

The controller was used while a TextEdit document was frontmost. `testFile.rtf` in the repo root
contains, after the RTF control block, exactly:

```text
\ <newline>      (paragraph break — from A / Enter)
\ <newline>      (paragraph break — from A / Enter)
19 spaces        (from B / Space, including OS key repeat while held ~6 s)
```

No letters, digits or other characters. Conclusion: **H mode delivers every physical button to
whatever app is frontmost, as plain text input.** Arrows move the caret; A inserts a paragraph
break; B inserts spaces (and repeats while held).

This is the spec's stated reason for treating H mode as fallback-only, now confirmed by evidence.

### 5.5 Cross-device observation

Of 1057 `HID-VALUE` records in the session, only 136 came from the controller; **921 came from
`Apple Internal Keyboard / Trackpad`**, i.e. ordinary trackpad activity while the probe was
running. Matching a device by usage (`1/6`) delivers *all* of that device's elements, including
vendor-page ones.

Implication for the real app: input must be scoped by **device identity (VID/PID)**, not by usage
class alone, or the app will be listening to the user's built-in keyboard and trackpad.

**Privacy caution.** While `--with-keyboard` is active the probe also receives the user's own typing
on the built-in keyboard — the step-3b capture (`logs/probe-step3b-backtoc-20260915-221012.jsonl`)
contains real keystrokes typed during that session. Those logs must not be shared, and the shipping
app must scope input to the controller's VID/PID rather than to a usage class.

---

## 6. C mode capture — 2026-09-15 (verified)

Session: `logs/probe-C-mode-20260915-214619.jsonl`, command
`agentprobe watch --duration 300 --log …`, controller in the default XInput variant.

### 6.1 Identity

```text
product="Xbox Wireless Controller"  manufacturer="zhuhai_jieli"
vid=1118 (0x045e, Microsoft)  pid=2835 (0x0b13)
transport="Bluetooth Low Energy"  primaryUsagePage/Usage=1/5 (Generic Desktop / GamePad)
serial="000000"  version=283  location=4043049926
```

macOS classifies it as `Minor Type: Gamepad`, `GameControllerCategory=xbox`,
`_GCSyntheticDeviceType=Xbox360Controller`. Only this one IINE device is present in C mode — there
is no keyboard- or mouse-usage interface, unlike H mode.

### 6.2 GameController surface

```text
GC-DEVICE   vendorName=Xbox Wireless Controller productCategory=Xbox One
            attachedToDevice=false playerIndex=-1
GC-PROFILE  extendedGamepad available
GC-PROFILE  microGamepad available
GC-ELEMENTS physicalInputProfile.elements count=35
```

35 elements are advertised, including `Button X`, `Button Y`, `Left/Right Shoulder`,
`Left/Right Trigger`, `Left/Right Thumbstick` and their axes. **None of those can ever fire** — the
hardware has six inputs (manual §2). The only meaningful keys for this device:

| Element key | Kind | `localizedName` |
|---|---|---|
| `Button A` | button | A Button |
| `Button B` | button | B Button |
| `Direction Pad` | dpad | D-pad |
| `Direction Pad Up / Down / Left / Right` | button | D-pad (Up/Down/Left/Right) |
| `Direction Pad X Axis` / `Y Axis` | axis | XBOX_DIRECTION_PAD (Horizontal/Vertical) |

System-gesture-bound elements (the OS may consume these before the app sees them):
`Button Home` (`boundToSystemGesture=true`), `Button Options` (**true**), `Button Share` (**true**).
`Button Menu` is `false`.

### 6.3 HID-level mapping

Only three HID elements ever changed state:

| Physical input | HID element | Page | Usage | Cookie | Values |
|---|---|---|---|---|---|
| D-pad ↑ | `HatSwitch` | `0x1` | `0x39` | 33 | `1` (logical range `[1,8]`, `0` = centred) |
| D-pad → | `HatSwitch` | `0x1` | `0x39` | 33 | `3` |
| D-pad ↓ | `HatSwitch` | `0x1` | `0x39` | 33 | `5` |
| D-pad ← | `HatSwitch` | `0x1` | `0x39` | 33 | `7` |
| A | `Button 1` | `0x9` | `0x1` | 11 | `0` / `1` |
| B | `Button 2` | `0x9` | `0x2` | 12 | `0` / `1` |

Diagonals (hat values 2/4/6/8) were never produced. No vendor-noise elements of the kind seen in
H mode (§5.3) appeared at all.

### 6.4 Verified event timeline

Raw sequence from the capture (value changes only), which covers all three acceptance tests:

```text
t=32.50 … 34.49   HatSwitch 1 → 0, 5 → 0, 7 → 0, 3 → 0     round 1: ↑ ↓ ← →
t=35.08 A (Button 1) press / release
t=35.54 B (Button 2) press / release
t=37.64 … 39.10   HatSwitch 1/5/7/3 again                   round 2
t=39.46 A press / release,  t=40.03 B press / release
t=42.80           Button 2 (B) → 1        ┐
t=43.12 … 44.77   HatSwitch 1, 5, 7, 3    ├ chord: B held while each direction is pressed
t=45.07           Button 2 (B) → 0        ┘
t=46.45           HatSwitch → 1           ┐ held-↑ repeat test: exactly one press,
t=49.21           HatSwitch → 0           ┘ one release across 2.76 s — no spurious repeats
```

The order of presses in rounds 1–2 (↑, ↓, ←, →, then A, then B) is what fixes the hat-value and
button-number mappings in §6.3.

### 6.5 Blocking finding: `shouldMonitorBackgroundEvents`

In this capture GameController connected and enumerated all 35 elements, but **not one
`GC-BUTTON` / `GC-AXIS` callback ever fired** while raw HID delivered every press. Root cause,
confirmed in the macOS 27 SDK header:

```objc
/* Starting with macOS Big Sur 11.3, shouldMonitorBackgroundEvents will be NO by default. */
@property (class, nonatomic, readwrite) BOOL shouldMonitorBackgroundEvents API_AVAILABLE(macos(11.3), …);
```

Since macOS 11.3 the default is **NO**, and while it is NO *"any inputs from a game controller will
not be forwarded to the application"* unless the app is frontmost. A menu-bar utility is never
frontmost, so **the app must set `GCController.shouldMonitorBackgroundEvents = true`**, or the whole
GameController path is silently dead.

The probe now sets it and logs the resulting value. **Re-verified 2026-09-15 21:49** — with the flag
on, the same six inputs produced `GC-BUTTON` ×36, `GC-AXIS` ×26 and `GC-DPAD-AXIS` ×26 callbacks
where the previous capture produced none. The flag is the difference between a working and a
silently dead GameController path.

GameController-layer evidence from the verification session:

```text
t=149.33 B DOWN                                    ┐ B held
t=149.72 Dpad.Up / yAxis=+1.0                      ├ all four directions
t=150.18 Dpad.Down / yAxis=-1.0                    │ pressed and released
t=150.53 Dpad.Left / xAxis=-1.0                    │ while B stayed down
t=150.89 Dpad.Right / xAxis=+1.0                   ┘
t=151.62 B up
t=153.41 Dpad.Up DOWN … t=155.96 Dpad.Up up        held 2.55 s: one press, one release
```

Axis sign convention observed: `y = +1.0` for Up, `x = +1.0` for Right.

### 6.6 Binding hazard: `extendedGamepad` and `microGamepad` are the same object

Measured by comparing object identities (`ObjectIdentifier`/pointer) on the live controller:

```text
extendedGamepad        0x1028586b0
microGamepad           0x1028586b0   ← identical
ext.buttonA            0x7cd9019900   ← identical to micro.buttonA
micro.buttonA          0x7cd9019900
ext.dpad               0x7cd9019f40   ← identical to micro.dpad
micro.dpad             0x7cd9019f40
ext.dpad.up            0x7cd9434540   ← identical to elements["Direction Pad Up"]
micro.dpad.up          0x7cd9434540
elements["Button A"]   0x7cd9019900
```

Consequences for the implementation:

1. Binding both profiles is **not** redundant-but-harmless: the second `pressedChangedHandler`
   assignment **replaces** the first, so the later binding silently wins. The probe's first C-mode
   capture is the proof — it reported `Micro.Up`, `Micro.A` simply because the micro bindings were
   installed last, which looked like a device property but was a probe artifact.
2. Bind **exactly one** set of canonical names per element. The probe now binds the extended profile
   and skips the micro profile when the two are the same object.
3. `physicalInputProfile.elements["Button A"]` and `extendedGamepad.buttonA` are also the same
   object, so the element dictionary and the profile are interchangeable — no need to bind both.

**Live confirmation (2026-09-15 22:02).** After the fix, pressing all six inputs produced exactly
`A`, `B`, `Dpad.Up`, `Dpad.Down`, `Dpad.Left`, `Dpad.Right` — 12 `GC-BUTTON` events, two per input,
and **no `Micro.*` names at all**. Canonical binding names for this device:

| Physical input | Canonical element | GC callback name | Axis value |
|---|---|---|---|
| ↑ | `extendedGamepad.dpad.up` | `Dpad.Up` | `yAxis = +1.0` |
| ↓ | `extendedGamepad.dpad.down` | `Dpad.Down` | `yAxis = -1.0` |
| ← | `extendedGamepad.dpad.left` | `Dpad.Left` | `xAxis = -1.0` |
| → | `extendedGamepad.dpad.right` | `Dpad.Right` | `xAxis = +1.0` |
| A | `extendedGamepad.buttonA` | `A` | — |
| B | `extendedGamepad.buttonB` | `B` | — |

---

### 6.7 Hot-plug and connect-time noise (verified)

The H → C transition was captured end-to-end in a single process
(`logs/probe-step3b-backtoc-20260915-221012.jsonl`, `--with-keyboard` so both sides are visible):

```text
t= 0.13  HID-MATCH     product="IINE_keyboard"          (device arrived in H mode)
t=29.61  HID-REMOVE    product="IINE_keyboard"          (platform switch moved to C)
t=32.93  HID-MATCH     product="Xbox Wireless Controller" vid=1118 pid=2835 location=4043049926
t=32.97  GC-CONNECT    controller connected
t=35.53  GC-BUTTON     Dpad.Up DOWN …                   (all six inputs work again)
```

- **Identity is stable across a reconnect.** The reconnected device matched the §6.4 baseline
  field-for-field: `vid=1118 pid=2835 serial=000000 location=4043049926 version=283`.
- **No app restart was needed** — the same process (`pid=98242`) logged the removal, the new match
  and then all twelve button events. This satisfies the "reconnect works without restarting the app"
  criterion for a *mode change*.
- The app must still treat removal as authoritative: `GC-DISCONNECT` cleared held state correctly,
  and the new connection re-ran full element enumeration.

**Power cycle (Q10) — verified 2026-09-15 22:24 on the generic C variant.** The controller was powered
off and switched back on about two minutes later:

```text
t= 10.03  Button 13 (pairing key) → 1     ← held; on this device the pairing key is also the power control
t= 12.08  HID-REMOVE  product="Wireless Controller" cleared held state: Button 13@19
t= 97.64  HID-MATCH   product="Wireless Controller" vid=17235 pid=39689 location=2142999777
t=116.47  Button 1 (A) → 1 … 0            ← input works again, same process
```

The identity before and after is **byte-for-byte identical**, the reconnect was **automatic** (no
confirmation prompt, no re-pairing), and input resumed without restarting the app. Since the generic
variant is invisible to GameController, no `GC-CONNECT` appears.

**Power cycle in the XInput variant — verified 2026-09-15 22:37** (the primary path):

```text
t=15.07  HID-REMOVE     product="Xbox Wireless Controller" cleared held state: Button 13@23
t=15.07  GC-DISCONNECT  controller disconnected | cleared held state: -
t=35.60  HID-MATCH      product="Xbox Wireless Controller" vid=1118 pid=2835 location=4043049926
t=35.63  GC-CONNECT     controller connected
t=35.63  GC-ELEMENTS    physicalInputProfile.elements count=35
t=39.48  GC-BUTTON      Dpad.Up / Down / Left / Right / A / B   (all six, same process)
```

Both paths cleared their held state on disconnect, the full GameController profile came back
automatically in ~20 s, and every field of the identity was unchanged.

**Caveat: `location` is not stable.** A later power-off/reconnect of the same generic device came back
with `location=584791771` where it had been `2142999777`. Product string, VID, PID and serial were
unchanged. Match devices on product/VID/PID plus usage — never on `location`.

**Connect-time axis reports.** On attach, the gamepad emitted one report for every analog axis that
has no physical hardware:

```text
t=32.93  X  page=0x1 usage=0x30 cookie=27 value=32768 logical=[0,65535]
t=32.93  Y  page=0x1 usage=0x31 cookie=28 value=32767 logical=[0,65535]
t=32.93  Z  page=0x1 usage=0x32 cookie=29 value=32768 logical=[0,65535]
t=32.93  Rz page=0x1 usage=0x35 cookie=30 value=32767 logical=[0,65535]
```

These are centre values, reported once and never again, but they sit exactly on the `0.5` boundary —
a naive `value > 0.5 ⇒ pressed` rule (which the probe's held-state display uses) marks them as
*held* and can fabricate a phantom chord at connect. The real input source must use a deadzone and
must not treat axis reports as button presses.

---

### 6.8 The `Wireless Controller` variant (Q3, Q7) — verified

Session `logs/probe-step3c-variant-20260915-221140.jsonl`. Reached by holding the pairing key and
pressing A while the platform switch stayed on C:

```text
t=34.17  Xbox Wireless Controller  Button 13 (usage 0xd, cookie 23) → 1   ← pairing key held down
t=35.94  Xbox Wireless Controller  Button 1  (usage 0x1, cookie 11) → 1   ← A pressed
t=37.96  HID-REMOVE                product="Xbox Wireless Controller"
t=70.49  HID-MATCH                 product="Wireless Controller" vid=17235 pid=39689 usage=1/5
         …no GC-CONNECT, no GC-DEVICE for the rest of the session
```

**GameController never attaches to this variant.** Not only did `GCControllerDidConnect` stay silent
for the whole session, a separate `list` run afterwards still reported
`after 1.5s settle: GCController.controllers() count=0`. The generic variant is HID-only.

HID mapping (note how much of it differs from §6.3):

| Physical input | Element | Page / usage | Cookie | Value |
|---|---|---|---|---|
| ↑ | `HatSwitch` | `0x1` / `0x39` | 29 | `0` (logical range `[0,7]`, **`15` = centred**) |
| → | `HatSwitch` | `0x1` / `0x39` | 29 | `2` |
| ↓ | `HatSwitch` | `0x1` / `0x39` | 29 | `4` |
| ← | `HatSwitch` | `0x1` / `0x39` | 29 | `6` |
| A | `Button 1` | `0x9` / `0x1` | 7 | `0` / `1` |
| B | `Button 2` | `0x9` / `0x2` | 8 | `0` / `1` |

Compared with the XInput variant: **same usages, different cookies** (29/7/8 vs 33/11/12),
**different logical range** (`[0,7]` vs `[1,8]`) and **different null value** (`15` vs `0`). Any
mapping table must be derived per device instance rather than hardcoded.

Connect-time centred axes appeared again (`X/Y/Z/Rz = 128` on `[0,255]`), i.e. the phantom-press
hazard of §6.7 applies to this variant too.

**Switching cost.** After the combo the device stayed away for ~32 s and did **not** reconnect on its
own — the user had to connect it manually. A variant switch is therefore not a clean auto-reconnect,
unlike the platform-switch cycle in §6.7.

**The variant is persistent device state, and the documented combo is timing-sensitive.**

It survives a power cycle, and it survives a platform-switch round trip: moving the switch C → H → C
brought the device back in the *same* generic variant (observed 22:28) — an identical round trip
earlier had returned XInput, but only because the stored variant was XInput at that time. **The
platform switch does not reset the variant.**

Three attempts, frame by frame — the difference is whether A is still down when the device drops:

| Attempt | Pairing key down | A down | A released | Device removed | Result |
|---|---|---|---|---|---|
| 22:12 (XInput → generic) | t=34.17 | t=35.94 | t≈37.96 | t=37.96 | **switched** |
| 22:24 (generic → ?) | t=38.51 | t=40.04 | t=40.21 | t=40.54 | **no change** |
| 22:31 (generic → XInput) | t=76.03 | t=76.27 | after removal | t=78.30 | **switched** |

In both attempts that worked, A was held ~2 s and was still down when the device dropped; in the one
that failed, A was tapped for 0.17 s and released before the device reacted.

**Confirmed procedure (verified 2026-09-15 22:31).** Holding *both* keys together for ~2 s switches the
variant reliably, and the device then reconnects **automatically** (~2 s gap):

```text
t=76.03  Button 13 (pairing key) → 1
t=76.27  Button 1 (A) → 1                    ← 0.24 s later, both held
t=78.30  HID-REMOVE  cleared held state: Button 13@19 + Button 1@7   ← both still held at removal
t=80.54  HID-MATCH   product="Xbox Wireless Controller" vid=1118 pid=2835
t=80.58  GC-CONNECT + GC-DEVICE + physicalInputProfile.elements count=35
```

So: **hold the pairing key, press and hold A, keep both down ~2 s** — a tap of A is silently ignored.
The GameController path comes back in full after switching to XInput, with no user action beyond the
combo.

Consequence for the design: the variant is **user-controlled hardware state the app must detect**, not
something the app can set. An app that only speaks the XInput/GameController path must detect the
generic variant and say so, rather than appearing dead.

**Probe bug found here.** The first version cleared held-button state on `GC-DISCONNECT` but not on
`HID-REMOVE`, so `Button 13` (the pairing key, never released because the device vanished) stayed
"held" into the next connection and contaminated every later line. Fixed: `HID-REMOVE` now clears and
logs the held set. Phase 1 must clear button state on device removal on **both** paths.

---

## 7. Evidence log

| Session | Date | Mode | Command | Log file | Notes |
|---|---|---|---|---|---|
| bootstrap-smoke | 2026-09-15 | no device | `agentprobe watch --duration 3 --log /tmp/probe-smoke.jsonl` | not kept (no device attached) | verified the probe runs, opens HID successfully and shuts down cleanly |
| H-mode-1 | 2026-09-15 21:40 | H / keyboard | `agentprobe watch --with-keyboard --duration 150 --log logs/probe-H-mode-20260915-214017.jsonl` | `logs/probe-H-mode-20260915-214017.jsonl` | full 6-button sweep ×2, chord round, leakage check; reconnect step missed; see §5 |
| C-mode-1 | 2026-09-15 21:46 | C / XInput (`Xbox Wireless Controller`) | `agentprobe watch --duration 300 --log logs/probe-C-mode-20260915-214619.jsonl` | `logs/probe-C-mode-20260915-214619.jsonl` | full sweep ×2, chord round, held-↑ repeat test. GameController delivered no callbacks — root-caused to `shouldMonitorBackgroundEvents` (§6.5); HID layer delivered everything |
| C-mode-2 | 2026-09-15 21:49 | C / XInput | `agentprobe watch --duration 300 --log logs/probe-C-mode-gc-20260915-214918.jsonl` | `logs/probe-C-mode-gc-20260915-214918.jsonl` | same sweep with the `shouldMonitorBackgroundEvents` fix: GC callbacks confirmed (§6.5); profile-identity check run separately (§6.6) |
| step1-naming | 2026-09-15 22:01 | C / XInput | `agentprobe watch --duration 180 --log logs/probe-step1-naming-20260915-220135.jsonl` | `logs/probe-step1-naming-20260915-220135.jsonl` | canonical binding names confirmed after the §6.6 fix: `A`/`B`/`Dpad.*`, no `Micro.*` |
| step2-leak | 2026-09-15 22:03 | C / XInput | `agentprobe watch --duration 180 --log logs/probe-step2-leak-20260915-220318.jsonl` | `logs/probe-step2-leak-20260915-220318.jsonl` | leakage re-check with TextEdit frontmost: 6 inputs captured, 0 keyboard-usage events, document stayed empty (Q9 C mode) |
| step3-switch | 2026-09-15 22:04 | C → H (platform switch moved) | `agentprobe watch --duration 300 --log logs/probe-step3-variant-20260915-220414.jsonl` | `logs/probe-step3-variant-20260915-220414.jsonl` | attempted variant switch actually moved the platform switch to H; produced the first real hot-plug (`HID-REMOVE` + `GC-DISCONNECT` at t=303.27 s). Reconnect fell outside the window; the device came back as `IINE_keyboard` |
| step3b-backtoc | 2026-09-15 22:10 | H → C / XInput | `agentprobe watch --with-keyboard --duration 300 --log logs/probe-step3b-backtoc-20260915-221012.jsonl` | `logs/probe-step3b-backtoc-20260915-221012.jsonl` | full H→C transition in one process: identical C-mode identity restored, all six inputs live again without restart (§6.7) |
| step3c-variant | 2026-09-15 22:11 | C / XInput → C / generic | `agentprobe watch --with-keyboard --duration 300 --log logs/probe-step3c-variant-20260915-221140.jsonl` | `logs/probe-step3c-variant-20260915-221140.jsonl` | pairing key + A switched the variant: GameController never attaches to `Wireless Controller`, HID-only mapping captured, pairing key exposed as `Button 13` (§6.8) |
| step4-poweroff | 2026-09-15 22:15 | C / generic | `agentprobe watch --with-keyboard --duration 300 --log logs/probe-step4-powercycle-20260915-221536.jsonl` | `logs/probe-step4-powercycle-20260915-221536.jsonl` | power-off captured via the pairing key (`Button 13`), `HID-REMOVE` cleared held state correctly; device stayed off, so no reconnect to observe |
| step4b-poweron | 2026-09-15 22:21 | C / generic | `agentprobe watch --with-keyboard --duration 300 --log logs/probe-step4b-poweron-20260915-222108.jsonl` | `logs/probe-step4b-poweron-20260915-222108.jsonl` | power-on: automatic reconnect, byte-identical product/VID/PID/serial, input live in the same process (Q10) |
| step5-combo-fail | 2026-09-15 22:23 | C / generic | `agentprobe watch --with-keyboard --duration 300 --log logs/probe-step5-backtoxinput-20260915-222346.jsonl` | `logs/probe-step5-backtoxinput-20260915-222346.jsonl` | pairing key + **tapped** A: device power-cycled but stayed in the generic variant; `location` changed to `584791771` |
| step5b-switch | 2026-09-15 22:25 | C / generic | `agentprobe watch --with-keyboard --duration 300 --log logs/probe-step5b-repair-20260915-222551.jsonl` | `logs/probe-step5b-repair-20260915-222551.jsonl` | platform switch C → H → C did **not** reset the variant — it came back generic |
| step5c-combo-ok | 2026-09-15 22:29 | C / generic → C / XInput | `agentprobe watch --with-keyboard --duration 300 --log logs/probe-step5c-holdcombo-20260915-222916.jsonl` | `logs/probe-step5c-holdcombo-20260915-222916.jsonl` | pairing key + A **both held ~2 s**: switched back to XInput, automatic reconnect, `GC-CONNECT` and all 35 elements restored (§6.8) |
| step6b-xinput-powercycle | 2026-09-15 22:36 | C / XInput | `agentprobe watch --with-keyboard --duration 420 --log logs/probe-step6b-xinput-powercycle-20260915-223641.jsonl` | `logs/probe-step6b-xinput-powercycle-20260915-223641.jsonl` | final acceptance test: `GC-DISCONNECT` → `GC-CONNECT`, identical identity, held state cleared on both paths, six inputs restored in-process (Q10) |

Session logs written to `logs/` are gitignored.

---

## 8. Open items for the implementation agent

- **`GCController.shouldMonitorBackgroundEvents = true` is mandatory** for a menu-bar app (§6.5).
  It is the single finding that decides whether the GameController path works at all. Verified.
- **GameController does not cover the whole device family.** It only ever attaches to the XInput
  variant. The generic `Wireless Controller` variant and H mode are invisible to it (§6.8, §5.1), so
  the IOHIDManager path decides whether those two are supported at all — the project must either
  implement it or explicitly detect-and-refuse those variants instead of silently ignoring input.
- **Device matching must not use VID/PID alone.** The generic C variant and the H-mode keyboard share
  `0x4353`/`0x9b09` exactly; usage or product string is required to tell them apart (§2).
- **Bind one profile, not two.** `extendedGamepad` and `microGamepad` are the same object and share
  elements, so a second binding silently overwrites the first (§6.6).
- **GameController attaches asynchronously.** `GCController.controllers()` is empty for the first
  ~100 ms after launch even with a paired controller; the app must rely on
  `GCControllerDidConnect` / `GCControllerDidDisconnect` rather than a startup query (§6.7).
- **Never hardcode HID cookies or logical ranges.** They differ between variants for the very same
  control (hat cookie 33 range `[1,8]` null `0` vs cookie 29 range `[0,7]` null `15`; A/B cookies
  11/12 vs 7/8) (§6.8).
- **Use a deadzone on analog axes.** Every axis reports its centre value once at connect, which a
  naive `> 0.5 ⇒ pressed` rule turns into a phantom held button and a fabricated chord (§6.7).
- **Clear button state on device removal.** The controller disappears without releasing whatever was
  held — this bit the probe itself via the `Button 13` pairing key (§6.8). Both input paths must
  reset on removal.
- **The pairing key is readable but must stay unmapped** (`Button 13`, usage `0x0d`): using it drops
  the connection and changes the device variant (§3 Q7). Spec §6's button map must not depend on it —
  confirmed, not assumed.
- **A power cycle in the XInput variant is done** — `GC-DISCONNECT` → `GC-CONNECT` verified with an
  identical identity (§6.7). Every acceptance criterion now has evidence; see the summary in
  `docs/phase0-summary.md`.
- `--discover` (GameController wireless discovery) is implemented but never exercised; it needs the
  bundled `.app` plus a controller in pairing mode.
