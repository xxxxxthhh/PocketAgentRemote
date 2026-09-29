# PocketAgentRemote

**English** · [中文](README.zh-CN.md)

Turn a six-button retro controller (IINE Gamebrick L1162) into a remote for the **Codex and Claude desktop apps** on macOS.

https://github.com/user-attachments/assets/02247d58-2c79-4a6b-af12-fdf2f89e1cb7

<p align="center"><b>Your agents, one pocket away.</b></p>

---

## What it does

The controller has six inputs: ↑↓←→, A and B. B doubles as a modifier. Everything it can do today, most-used first:

| You do | What happens |
|---|---|
| D-pad | Moves the cursor or selection in Codex, Claude or any app; hold to repeat |
| Tap A | Submit / approve (Enter, sent on release) |
| Hold A and talk | Voice input via Doubao; releasing ends it, and this press never submits |
| Tap B | Cancel / reject (Escape) |
| Hold B for half a second | Opens the **app switcher**: ←→ to pick, A to switch. Works in any app |
| B + ← | Opens the **command menu**: New Chat, Changes, Terminal, Switch Model, Archive Chat (depends on the frontmost app) |
| B + ↑ / ↓ | Jump to recent chat 1 / 2 (Codex) or previous / next chat (Claude) |
| B + → | Jump to the chat that needs you (Codex) / open the command palette (Claude) |
| B + A | **Backspace**: deletes the character before the cursor; hold to keep deleting (for fixing misheard words) |
| Nothing at all | The profile follows the frontmost app; in a browser you only get the D-pad, Enter and Esc |
| A press does nothing | A 3-second notice at the top of the screen says why (blocked, unsupported, switch failed) |
| Controller not in hand | Menu bar → `Show Controller Menu` / `Show App Switcher` open the same menus |
| B + ← in WeChat, a browser or Finder | Lists that **app's own menu-bar commands**; A runs one. WeChat pins "next unread chat" and "search" to the top. Destructive items (quit, close, delete…) are never listed |
| Lid closed, reboot, permission revoked | Picks up again after wake with no stuck keys; launches at login (can be turned off in the menu bar); a lost Accessibility permission raises an on-screen notice and a warning menu-bar icon |

Experimental and off by default: the Codex command menu can be switched to a **four-way dial** (pick by direction, see "Controller menu").

---

## Quick start

```bash
./scripts/make-agent-app.sh release       # builds build/PocketAgentRemote.app
open /Applications/PocketAgentRemote.app  # launch (the script copies the bundle to /Applications; a controller icon appears in the menu bar)
```

Then:

1. **Menu-bar controller icon → `Request Accessibility Permission`**, and enable PocketAgentRemote in System Settings.
   (Without it, macOS drops every key the app sends; the menu keeps showing `Accessibility: Required`.)
2. **Menu → `Input Monitoring`**: if your controller is the **generic variant** (shows up in Bluetooth as `Wireless Controller`),
   it also needs **Input Monitoring**. The XInput variant (`Xbox Wireless Controller`) does not.
   The menu shows the current state; when it says `denied`, click it to open System Settings.
3. Put the controller in **C mode**, connect it, and use it. **The profile follows the frontmost app**; there is nothing to choose.

> Signed with an Apple Development certificate, **rebuilding no longer invalidates the permissions** (the earlier ad-hoc signature needed re-granting after every build).

Menu-bar icon: filled = controller connected. The menu shows the current profile, the frontmost app and the result of each kind of action, live.

### Automatic profiles

```text
Frontmost is ChatGPT (Codex)  → Codex bindings    (B+↑ = jump to chat 1)
Frontmost is Claude.app       → Claude bindings   (B+↑ = next chat)
Any other frontmost app       → Generic           (D-pad / A = Enter / B = Esc only)
```

In the config:

```json
"profileMode": "auto",
"autoProfileBundleIDs": {
  "com.openai.codex": "codex",
  "com.anthropic.claudefordesktop": "claudeCode"
},
"fallbackProfile": "genericTerminal"
```

**Auto mode does not check the frontmost-app allowlist**: the profile is itself derived from the frontmost app, so an unknown
app can only land on Generic and a tool-specific action cannot reach the wrong app. The allowlist still applies in manual mode.

You can switch back to `"profileMode": "manual"`: you then pick the profile from the menu, and the allowlist stops actions from reaching the wrong app.

> **Why inferring the profile is safe**: the early spec required choosing the profile by hand, because back then it meant
> guessing which agent was running inside a terminal, which is unreliable on macOS. Now it reads the frontmost app's bundle ID,
> an exact signal the guard already relied on, so auto mode is a safe default.

### Troubleshooting

**Menu → `Open Input Monitor…`** shows the live pipeline, or read the log file directly:

```bash
tail -f ~/Library/Application\ Support/PocketAgentRemote/debug.log
```

```text
[   9.001] RAW      press   up
[   9.001] GESTURE  keyDown(up)
[   9.001] OUTPUT   SEND  down  navigateUp → upArrow → com.openai.codex
```

`SKIP` = the current profile does not support the action; `DENY` = the guard blocked it (frontmost app not allowlisted, etc.).
The reason is at the end of the line. `TOAST` = the on-screen notice that was shown.

---

## Controller mapping (defaults, zero config)

Six inputs; `B` is the modifier.

| Gesture | Action | What Codex receives |
|---|---|---|
| ↑ ↓ ← → | Navigate | Arrow keys (after 0.35 s held, repeats every 80 ms) |
| **Tap A** | Submit / **approve** (sent on release, at most 220 ms late) | `Enter` |
| **Hold A** | **Push to talk** (Doubao voice input, one button) | Holds right `⌥` until release |
| **Tap B** | Cancel / **reject** | `Escape` |
| **Hold B** | **Open the app switcher** (a controller ⌘⇥, see below) | No key; shows an icon strip |
| **B + ↑** | Jump to recent chat 1 | `⌥⌘1` |
| **B + ←** | **Open the controller menu** (see below) | No key; shows an overlay |
| **B + ↓** | Jump to recent chat 2 | `⌥⌘2` |
| **B + →** | Jump to the chat that **needs me** | `⌥⌘A` |
| **B + A** | **Backspace** (fix misheard words) | `⌫`, repeats while held |

> **Hold B bypasses the adapters and the allowlist.** Switching the frontmost app is not "sending keys to an app" but a system
> effect, so it **works whatever app is in front**, including a browser, which is exactly where it is most useful. Tested on
> macOS 27, every in-process method (`NSRunningApplication.activate`, AX `kAXFrontmost`, a synthesized `⌘⇥`) **failed**; the only
> reliable one is AppleScript `activate`, so `Info.plist` must carry `NSAppleEventsUsageDescription` (the build script adds it).
>
> Before 2026-09-18, holding B toggled between Codex and Claude. That logic (`agentPair`) still exists, now only behind the
> menu-bar item `Focus Other Agent Now`; on the controller the app switcher replaced it (see below).

> **Voice input takes one button: hold A and talk.** It is the built-in default (the `a.hold` gesture), no config needed.
> A tap still submits, but `Enter` is sent **when A is released** (only then is it known whether the press was a tap or a hold);
> once a press crosses the threshold it never sends `Enter` and becomes push-to-talk instead. The threshold is `aHoldMs` (default 220 ms).
>
> **Since 2026-09-21, `B + A` is backspace**, for deleting misrecognised characters: hold B and tap A to delete one, hold A
> to keep deleting. **Letting go of B meanwhile is fine**; it stops when A is released. Works in any app, browsers included.
> An old `b.a` voice binding (hold right ⌥) in an existing config is removed at launch with a backup, and only if it still
> equals the old default. It deletes one character at a time, not whole words.
>
> Doubao (ByteDance's input method) needs the "hold **right** Option" form, not "tap left Option + left Shift"; the latter
> **does not work** with synthesized events.

> `A` / `B` double as approve / reject because the approval prompts in Codex and Claude use exactly `Enter` / `Escape`;
> the final say always stays in the agent's own UI. **To reject, tap B**: only holding B past `holdMs` (default **450 ms**)
> opens the app switcher. `tapMaxMs` (220 ms) **no longer** decides tap versus hold: a 300 ms press is still "cancel" and
> does not open the switcher.
>
> Two more edge cases: **once B forms a chord with the D-pad or A, that B press belongs entirely to the chord**, so
> releasing B does not send a stray `Escape` (ending voice input never cancels as well); **pressing B while A is already held
> is ignored** (A is not a layer key, so the B after releasing A cannot turn into a window switch).

Keep B held to fire several chords in a row (like holding Shift and typing different letters).

**Why the B layer is "jump to chat"**: the controller has only 12 gestures, and `⌥⌘1…6` (Go to recent chat) is the direct
counterpart of Codex Micro's six agent keys, each jumping to one agent's chat. `⌥⌘A` goes further: one press to the chat that
is **waiting for you** (an approval or unread output). That is as close to the Micro experience as a six-button controller gets.

To bind these back to "new chat / terminal / model picker" and so on, change the config; see below.

---

## Controller menu (`B+←`)

Frequent actions by feel, infrequent ones from a menu: with only 12 gestures, a menu is the one way left to grow.

<p align="center"><img src="docs/media/command-menu.gif" width="640" alt="B+← opens the command menu, ↓ walks the rows, then the four-way dial"></p>

```text
┌───────────────────────────┐
│  Codex                    │
│                           │
│  ▸ New Chat               │
│    Changes                │
│    Terminal               │
│                           │
│  ↑↓ Select  A Run  B Close│
└───────────────────────────┘
```

- **You can let go of B once it is open**; the menu stays on screen, no need to keep holding the chord.
- **↑↓ to move, A to run, B to close.** While the menu is open it owns the controller: **↑↓/A/B never reach the chat window behind it**.
- **The contents follow the app**: Codex actions in Codex, Claude actions in Claude, and **only rows that can actually run**
  (an action without a default key is left out rather than shown as a row that does nothing).
- **The overlay never takes focus** (a non-activating panel; tested: the app stays inactive and the chat window stays frontmost),
  so voice input and the agent's own shortcuts are unaffected.
- **Switching to another app closes the menu**; if it could not close in time, **running a row re-checks that the frontmost app
  is unchanged** and refuses (with a log line) if it is not.
- **Direct shortcuts stay**: hold A for voice, `B+A` for backspace, `B+→` for the chat that needs you, hold B to switch apps,
  `B+↑/↓` to jump between chats. None of them go through the menu.
- Without the controller: **menu bar → `Show Controller Menu`** is the same menu.

> **`B+←` used to be "new chat"** (later rebound to `⌘N` on the Claude side). It is now "open the menu" everywhere, with new chat
> as the first row. If your config still has the old `b.left` override, the app **removes it at launch and keeps a backup**
> (`config.json.backup-<timestamp>`), and only when it still equals the old default `⌘N`; bindings you changed yourself are left alone.

**Each app declares its own rows, and lists only commands verified to work in that app:**

| App | Menu |
|---|---|
| Codex | New Chat / Changes / Terminal / Switch Model / Archive Chat |
| Claude | New Chat (`⌘N`) / Show Changes (`⌘⇧D`) / Show Terminal (`⌘J`), each confirmed twice: in the running app's menu and in its shortcut table |

---

## App switcher (hold `B`)

A controller ⌘⇥: **hold B for about half a second and release**, and a row of icons appears at the bottom of the screen with every
running regular app (the ones in the Dock; menu-bar utilities are not listed), most recently used on the left.

```text
┌──────────────────────────────────────────┐
│  Switch App                              │
│                                          │
│   [Codex]  [▮Claude▮]  [Chrome]  [Finder]│
│                Claude                    │
│                                          │
│  ←→ Select   A Switch   B Close          │
└──────────────────────────────────────────┘
```

- **The strip stays after B is released**: ←→ moves the highlight, A switches to it, B closes. ↑↓ are swallowed while it is open,
  so nothing reaches the window behind.
- **The highlight starts on the second app, the one you used before**, so "hold B, release, press A" switches back to the previous
  app, just like a quick ⌘⇥. The old Codex ⇄ Claude toggle is a special case of this.
- **It opens in any app** (browsers and terminals included), unlike the `B+←` command menu, which only has content when an agent is in front.
- Switching uses the same AppleScript `activate` path (addressed by bundle ID); it shows up as `FOCUS` lines in the log.
- With only one regular app running it does not open, and the log records `SKIP openAppSwitcher`.
- The order is only accurate for apps used since PocketAgentRemote launched: macOS offers no global most-recently-used order, so the
  app tracks activation notifications itself. Apps that were open before and not touched since go to the end.
- Without the controller: **menu bar → `Show App Switcher`** is the same switcher.

**Experimental: the four-way dial.** Menu bar → `Command Menu: List / Dial (experimental)` → Dial. With Codex in front, `B+←` then
shows four direction slots instead of a list: "New Chat" up, "Changes" left, "Terminal" down, "More" right. Press a direction to
select, then A to run; "More" holds Switch Model / Archive Chat, and B returns to the dial. **Nothing is selected when it opens**,
so the ← that opened the menu cannot pick anything by accident. The list stays the default and the choice resets on restart;
whether the dial becomes the default waits on comparison testing.

> Claude lists only these three rows on purpose: the other commands' keys have not been confirmed twice, and a missing row is better
> than a row that does the wrong thing. `⌘⇧I` once opened an incognito chat in Claude while labelled "switch model".
> Note that Show Changes / Show Terminal belong to Code sessions and **Claude itself greys them out in a plain chat** (`[OFF]` in the
> menu dump); a press doing nothing there is Claude's behaviour. Evidence: `docs/research-claude-commands-verified.md`.
> To switch models or run other commands in Claude, the **command palette** (`⌘K`) is still one `B+→` away.

---

## On-screen notices

A press that did nothing used to mean digging through the log; now a 3-second notice appears at the top of the screen, for example:

```text
Generic mode doesn't support Recent Chat 1              ← B+↑ pressed in a browser
Can't open menu: frontmost app isn't an agent           ← B+← pressed in a browser
Blocked: frontmost app isn't an agent (not allowlisted) ← manual mode, sent to an app outside the allowlist
Switch failed: WeChat (…reason…)                        ← the app switcher could not bring it forward
```

- Only things that **did not happen** are reported; successful actions show nothing, since the target app itself shows the result.
- The notice never takes over any key: while it is visible, B is still Escape and the D-pad still moves.
- It disappears after 3 seconds; a new notice replaces the old one. It cannot be dismissed early and has no settings.
- "Switch failed" only appears when the target app has not come forward within 4 seconds; the switch request runs in the background,
  so the controller stays usable while waiting. Slow responders like WeChat (about 2 seconds) now switch normally instead of being reported as failures.
- With a menu open, the notice appears at the top of the screen, never overlaps the menu, and does not close it when it expires.

---

## Configuration

`~/Library/Application Support/PocketAgentRemote/config.json` (menu → `Open Config File`, then `Reload Config` after editing).

```json
{
  "activeProfile": "codex",
  "macrosEnabled": false,
  "requireAllowedFrontmostApp": true,
  "agentPair": {
    "leftBundleID": "com.openai.codex",
    "rightBundleID": "com.anthropic.claudefordesktop"
  },
  "allowedBundleIDs": ["com.openai.codex", "com.anthropic.claudefordesktop", "..."],
  "actionKeyOverrides": {
    "toggleFastMode": { "key": "f", "modifiers": ["control", "option"] }
  },
  "gestureKeyOverrides": {
    "b.a": { "modifiers": ["option"], "hold": true }
  },
  "profileGestureKeyOverrides": {
    "claudeCode": {
      "b.up":   { "key": "]", "modifiers": ["command", "shift"] },
      "b.down": { "key": "[", "modifiers": ["command", "shift"] }
    }
  }
}
```

**`agentPair` decides how the menu-bar item `Focus Other Agent Now` switches between two apps** (holding B is now the app
switcher and no longer reads it): `left`/`right` are not hands but two slots. Pressing from either one switches to the other;
pressing from any other app switches to `left`. An empty side (`""`) means single-agent mode; `null` falls back to the built-in default.
`leftName`/`rightName` are display names only and optional.

Three layers of overrides, **later wins**: built-in bindings → `gestureKeyOverrides` (global) → `profileGestureKeyOverrides` (per profile).

**Left and right modifiers are distinct in `modifiers`**: `option` is left Option (keyCode 58), `rightOption` is right Option (61).
Some targets only accept one side (Doubao does), and **picking the wrong one fails silently**. The same goes for `shift`/`rightShift` and the rest.

**`key` is forgiving**: `"a"`, `"1"`, `"]"`, `"up"`, `"esc"`, `"space"` all work (enum names such as `digit1` / `rightBracket` /
`upArrow` are accepted too). Leaving out `key` presses only the modifiers.

### `actionKeyOverrides`: change which key an action sends

Keys are semantic action names, values are key strokes. Use it for actions Codex has **no default key** for: bind Fast mode to a key
in Codex's `Settings → Keyboard Shortcuts`, write the same key here, and the controller can trigger it.

### `gestureKeyOverrides`: change which key a gesture sends

**This layer bypasses the action vocabulary**, so any gesture can point at any key, for example making `B + A` send `⇧⎋`
(Clear all unreads), which our action table does not have at all.

Gesture identifiers (12 in total, everything the hardware can produce):

```text
base layer   up · down · left · right · a
B gestures   b.tap (cancel) · b.hold (app switcher)
chords       b.up · b.down · b.left · b.right · b.a
```

> `b.tap` and `b.hold` are independent gestures that can point at different things, and by default they already do.
> Putting `b.hold` in `gestureKeyOverrides` replaces the app switcher with a key of your choice.

Key names: `a`-`z`, `0`-`9`, `upArrow`/`downArrow`/`leftArrow`/`rightArrow`, `enter`/`escape`/`tab`/`space`,
`minus`/`equal`/`comma`/`period`/`slash`/`grave` and more; modifiers `command`/`option`/`control`/`shift` (`modifiers` can be omitted).

**`key` can be omitted, which means "modifiers only"**:

```json
"gestureKeyOverrides": {
  "b.a": { "modifiers": ["option"], "hold": true }
}
```

> The example uses left ⌥. "`b.a` = hold right ⌥" was the old voice binding, and the app removes it at launch (with a backup).

- `hold: true` = **held** (pressed when the chord starts, released when A is released). This is the form Doubao voice input needs
  (holding right ⌥), and the default A hold already does it.
- Without `hold` (the default) = **a tap** (pressed and released at once).
- Modifiers **distinguish sides**: `option` is left Option (keyCode 58), `rightOption` is right Option (61). Some targets (such as
  Doubao) only accept one side; the wrong one does not error, it just does nothing. Likewise `shift`/`rightShift`,
  `control`/`rightControl`, `command`/`rightCommand`.

Two safety classes:

- A custom binding **with a main key** = a tool-specific action → needs a chosen profile and an allowlisted frontmost app
- A binding with **modifiers only** = a global gesture → not limited by the allowlist (it types no command into any app);
  released by force on disconnect or quit, so modifiers never stay stuck

> Unknown gesture identifiers in the config **do not break parsing**; they are ignored and listed in the log (`unrecognised gesture ids`).

---

## Safety model

- `macrosEnabled = false` by default; auto mode by default, where any unknown app lands on Generic (D-pad / Enter / Esc only)
- Tool-specific actions only go to their own app: in auto mode the profile comes from the frontmost app; in manual mode the frontmost
  app must also be on the allowlist (by default only the two AI apps plus common terminals/IDEs)
- A blocked action is **never substituted**, only reported. In particular a permission-mode action is never quietly turned into "approve"
- Every modifier and held key is released on quit, disconnect and sleep

---

## Project status

In daily use; all 345 unit tests pass. Verification depth varies by feature:

| Feature | Verified by |
|---|---|
| Controller input (both C-mode variants) | ✅ Tested on the real controller |
| Codex / Claude / Generic bindings | ✅ Codex and Claude tested on real hardware; 8 of 11 Codex actions have default keys |
| Controller menu (`B+←`) | ✅ Unit tests + real windows + the physical controller |
| App switcher (hold `B`) | ✅ Unit tests + an 11-item acceptance run on the physical controller |
| Menu-bar entry points, A-button edge cases, on-screen notices, rapid switcher presses | ✅ Unit tests; not yet fully accepted on hardware |
| Four-way dial | 🧪 Experimental, off by default |

### Known limitations

- **Codex has no action for cycling permission modes**; use Codex's own UI to change them.
- **The Claude-side mappings are less thoroughly researched** than Codex's, and `queueFollowUp` is unavailable in Claude.
- **Holding B is the app switcher, not "reject"**: tap B to reject an approval. This is a deliberate trade-off.
- **Switching apps relies on AppleScript**: in-process `activate()` / AX / a synthesized `⌘⇥` all failed on macOS 27, so
  `NSAppleEventsUsageDescription` in `Info.plist` is required. Should the system change its rules, the log prints the method that
  worked (`via appleScript`) and every failure reason.
- **Tap A sends Enter on release** (up to 220 ms late): only on release is it known whether the press was a tap or push-to-talk.
  Sending on press would mean giving up one-button voice input; a trade-off, not a bug.
- **On-screen notices cannot be dismissed**, only waited out (3 seconds), and there are no success notices.
- **Only Codex has the four-way dial**; Claude stays a list, and the choice is not saved across restarts.
- **Voice input is bound to holding A only** (`B+A` is backspace). To put voice on `B+A`, give `b.a` a binding that is **not right ⌥**
  (for example left `option`: `"b.a": { "modifiers": ["option"], "hold": true }`); right ⌥ is removed at launch by the old-config migration.
  A custom `b.a` fires once per press, does not repeat while held, and is blocked in non-agent apps such as browsers.
- The controller's **H mode (keyboard mode) is detected but not consumed**. Both C-mode variants are fully supported.

---

## Repository layout

```text
docs/HANDOFF.md                ⭐ Start here as a developer: current implementation state and key design decisions
docs/spec-v0.3.md              The original design spec (partly superseded by the implementation, see HANDOFF §6)
docs/ux-roadmap.md             UX roadmap and execution plan
docs/test-manual.md            Feature test manual (step-by-step hardware acceptance)
docs/pending-user-tests.md     Earlier hardware verification checklist
docs/codex-shortcuts.md        Codex shortcuts (official panel + exported live menu)
docs/codex-menu-shortcuts.md   Early version of the menu export (44 entries, for comparison)
docs/phase0-summary.md         Hardware findings and the constraints they impose
docs/hardware-probe.md         Raw Phase 0 notes
docs/phase1-verification.md    Phase 1 hardware verification log
docs/research-*.md             Research on Codex / Claude / Codex Micro
docs/research-claude-commands-verified.md  Measured Claude command keys, graded by strength of evidence
docs/media/                    The intro video (720p) and command-menu GIF used by this README

promo/                         Source of the intro video: animation page + narration + music + renderer (see promo/README.md)

Sources/PocketAgentCore/       All logic (unit-testable, no UI dependencies)
Sources/PocketAgentCore/Focus/ Frontmost-app switching (AppActivator + the two-agent switching rules)
Sources/PocketAgentApp/        The menu-bar app (a thin shell)
Sources/AgentProbe/            Phase 0 hardware probe
Sources/AgentCoreSmoke/        Phase 1 hardware verification tool

Tools/dump-menu-accelerators.swift  Exports the real menu shortcuts of a running app
scripts/make-agent-app.sh      Builds the menu-bar app
scripts/make-app.sh            Builds the probe app
```

Most documents under `docs/` are in Chinese.

## Development

```bash
swift build
swift test                                  # 345 tests
./.build/debug/coresmoke --duration 60      # watch the gesture pipeline on real hardware (log only)
./.build/debug/agentprobe watch             # watch raw HID reports
swift Tools/dump-menu-accelerators.swift ChatGPT   # export Codex's real menu shortcuts
```

> If `swift build` fails with `sandbox_apply: Operation not permitted` (SwiftPM's nested sandbox refused by an outer sandbox),
> add `--disable-sandbox`; `scripts/make-agent-app.sh` passes it through via `POCKETAGENT_SWIFTPM_FLAGS=--disable-sandbox`.

To regenerate the intro video (after changing features or wording): `promo/make.sh`; setup is described in `promo/README.md`.

> **Run the last command before changing any key binding.** The keys listed in Codex's command registry **are not necessarily the
> ones in effect at runtime**: `inspectChanges` once missed because of it. The registry's `⌃⇧G` did nothing, while the menu
> actually bound `⌥⌘B`. Whatever can be read from the running app's menu wins.

## License

[MIT](LICENSE). IINE, Gamebrick, Codex, Claude, WeChat and other names belong to their respective owners; this project is not
affiliated with them and mentions them only to describe compatibility.
