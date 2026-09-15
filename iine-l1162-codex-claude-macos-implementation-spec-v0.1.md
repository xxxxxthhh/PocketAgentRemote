# IINE L1162 → macOS Codex / Claude Code Remote
## Implementation Spec v0.1

> Status: Draft for implementation  
> Target: macOS native menu-bar utility  
> Hardware: IINE 良值 L1162 迷你控制器  
> Primary tools: OpenAI Codex CLI, Anthropic Claude Code  
> Primary interaction model: controller input → semantic action → tool-specific shortcut/macro

---

## 1. Goal

把 IINE L1162 迷你控制器变成一个面向 AI Coding Agent 工作流的 macOS 随身控制器。

目标不是“把手柄映射成几个键盘键”，而是建立一层稳定的 **semantic action layer**：

```text
L1162 physical input
        ↓
Controller input backend
        ↓
Gesture / Layer engine
        ↓
Semantic Agent Actions
        ↓
Tool Adapter
   ├── Codex
   ├── Claude Code
   └── Generic Terminal
        ↓
macOS Input Emitter
        ↓
Terminal / IDE
```

最终用户应该能够单手完成最常见的操作：

- 上下左右导航
- Submit / Confirm
- Cancel / Interrupt
- Queue follow-up
- 切换 permission mode
- 切换 fast mode
- 打开 model picker
- 查看 diff / transcript
- 在 Codex / Claude Code profile 之间切换

---

## 2. Non-goals

v0.1 不做：

- 修改 L1162 固件
- USB/Bluetooth reverse engineering，除非 GameController / IOHIDManager 都无法读取
- kernel extension
- root 权限
- 自动执行危险 shell command
- 自动开启 `--dangerously-skip-permissions` / bypass 权限模式
- 根据 Terminal 前台窗口“猜测”当前一定运行 Codex 或 Claude
- 网络服务、账号登录、云同步

---

## 3. Hardware assumptions

IINE L1162 有三种模式，其中本项目重点使用：

### C Mode — Gamepad

官方说明中 C 模式可作为游戏控制器使用：

- 默认设备形态：`XINPUT - Xbox Wireless Controller`
- 可通过设备组合操作切换为通用 `Wireless Controller`

macOS 上应优先测试这两个枚举形态，选择能够被 `GameController.framework` 稳定识别并暴露 D-pad / A / B 的模式。

### H Mode — Keyboard / Mouse

H 模式可以作为：

- `IINE-keyboard`
- `IINE-mouse`

**不建议作为主实现路径。**

原因：当设备本身以键盘方式连接时，macOS 会首先把按键作为普通键盘输入分发；如果我们再做设备级拦截、过滤和重映射，会进入类似 Karabiner 的问题域，复杂度明显更高。

H 模式保留作为：

1. PoC / troubleshooting
2. GameController 与 IOHIDManager 都无法读取时的 fallback
3. Karabiner-Elements 的临时方案

### Physical controls considered usable

MVP 假设有 6 个主要输入：

```text
↑
↓
←
→
A
B
```

不要假定“配对键”会出现在 HID report 中。只有 probe 验证后才能使用它。

---

## 4. Hardware Probe — implementation must start here

在写正式映射逻辑之前，先做一个最小 Hardware Probe。

### 4.1 GameController probe

使用：

```swift
import GameController
```

枚举：

```swift
GCController.controllers()
```

记录：

- `vendorName`
- `productCategory`
- `physicalInputProfile`
- `extendedGamepad`
- 所有可访问 element
- button pressed/value
- dpad x/y

监听：

```swift
GCControllerDidConnect
GCControllerDidDisconnect
```

### 4.2 Test matrix

依次测试：

| Device mode | Expected |
|---|---|
| C / XInput-like | 是否被 GCController 识别 |
| C / Wireless Controller | 是否被 GCController 识别 |
| H / keyboard | 仅用于确认 fallback |

优先级：

```text
GameController
    ↓ if unavailable/incomplete
IOHIDManager
    ↓ if unavailable
H mode + Karabiner fallback
```

### 4.3 Probe acceptance criteria

必须确认：

- 6 个主要按键都能独立识别
- press / release 都可观测
- D-pad 不产生异常重复
- 同时按 B + 方向键时可观察到真实 chord
- controller 输入不会向当前应用泄漏普通键盘字符
- reconnect 后无需重启 app

只有满足这些条件，再开始主功能。

---

## 5. Why semantic actions

不要这样写：

```swift
if button == .up {
    sendKey(.upArrow)
}
```

应该先定义：

```swift
Physical input
→ Gesture
→ Semantic action
→ Adapter recipe
```

例如：

```text
B + Up
→ cyclePermissionMode
→ CodexAdapter
→ Codex keymap shortcut

B + Up
→ cyclePermissionMode
→ ClaudeAdapter
→ Shift+Tab
```

这样硬件布局可以保持不变，而 Codex / Claude Code 的快捷键变化只影响 Adapter。

---

## 6. Recommended button map

### 6.1 Base Layer — universal navigation

保持最简单、最符合肌肉记忆：

| L1162 | Semantic action | Default output |
|---|---|---|
| ↑ | Navigate Up | Arrow Up |
| ↓ | Navigate Down | Arrow Down |
| ← | Navigate Left | Arrow Left |
| → | Navigate Right | Arrow Right |
| A | Submit / Confirm | Enter |
| B tap | Cancel / Interrupt / Close | Escape |

这 6 个输入本身已经可以操作：

- slash command picker
- model picker
- permission prompt
- history / list
- dialog
- confirm / cancel

### 6.2 Agent Layer — hold B as modifier

B 在按下后先进入一个短暂的 pending 状态。

建议阈值：

```text
tap threshold:     <= 220 ms
modifier acquire:  180–250 ms
hold threshold:    >= 450 ms
```

当 B 与第二个键组成 chord 时，不再发出 Escape。

推荐映射：

| Chord | Semantic action | Codex | Claude Code |
|---|---|---|---|
| B + ↑ | Cycle Permission Mode | `next_permission_mode` | `Shift+Tab` / `chat:cycleMode` |
| B + ↓ | Toggle Fast Mode | `toggle_fast_mode` | `chat:fastMode` |
| B + ← | Model Picker | adapter-defined | `chat:modelPicker` |
| B + → | Queue Follow-up | `queue` | `chat:queueSubmit` |
| B + A | Inspect Changes | `/diff` fallback | diff panel / transcript |
| B hold alone | Escape / Cancel | Escape | Escape |

### 6.3 Why B is the modifier

B 在大多数游戏/UI 语义中本来就是：

- Back
- Cancel
- Escape

因此：

```text
B tap = Back
B + X = secondary command
```

比把 A 当 modifier 更自然。

### 6.4 Profile switching

MVP **不要占用 controller chord 来切 profile**。

原因：

- 只有 6 个主要输入，非常宝贵
- profile 切错后可能把同一 chord 解释成不同的敏感操作
- 自动识别 terminal subprocess 在 macOS 上并不可靠

MVP 在 menu bar 中明确选择：

```text
Profile
○ Generic Terminal
○ Codex
○ Claude Code
```

后续版本再增加 profile switching gesture。

---

## 7. Current Codex CLI actions to support

Codex 当前 TUI 已经有 semantic keymap，因此优先使用 keymap，而不是模拟输入 slash command。

重点 action：

### Global

- `open_agents`
- `open_transcript`
- `open_external_editor`
- `copy`
- `clear_terminal`
- `submit`
- `queue`
- `toggle_shortcuts`
- `toggle_vim_mode`
- `toggle_fast_mode`
- `toggle_raw_output`
- `toggle_side_conversation`

### Chat

- `interrupt_turn`
- `decrease_reasoning_effort`
- `increase_reasoning_effort`
- `previous_permission_mode`
- `next_permission_mode`
- `edit_queued_message`
- `prompt_stack_back`
- `skip_question`

### Composer

- `submit`
- `queue`
- `history_search_previous`
- `history_search_next`

### Approval

Codex source exposes approval actions such as：

- approve
- approve for session
- approve for prefix
- deny
- decline
- cancel

**v0.1 不直接映射“一键 approve for session/prefix”。**

确认类操作统一通过 A / Enter，让 Codex 自己的 UI 保持最后一层确认。

### Existing Codex UX worth preserving

当前 Codex CLI 已支持：

- `Up / Down`: draft/history navigation
- `Ctrl+R`: prompt history
- `Ctrl+O`: copy latest completed output
- `Tab` while working: queue follow-up
- `Enter` while working: inject instructions into current turn
- `Esc Esc` with empty composer: edit previous user message / fork
- `Ctrl+C`: close / exit behavior depending context
- `/keymap`: configure TUI key bindings
- `/diff`
- `/review`
- `/permissions`
- `/model`
- `/fast`
- `/plan`
- `/fork`
- `/side`
- `/resume`
- `/new`
- `/status`

### Codex integration strategy

Preferred:

```text
L1162 semantic action
→ CodexAdapter
→ configured Codex keymap action
→ CGEvent keystroke
```

Fallback only when there is no semantic keymap action:

```text
→ safely type slash command
→ Enter
```

Slash-command macro必须满足：

1. Codex profile explicitly active
2. target application is allowed
3. no modifier keys stuck
4. macro action explicitly enabled in config

---

## 8. Current Claude Code actions to support

Claude Code 当前已经提供可自定义 `keybindings.json`。

重点 semantic actions：

### Global

- `app:interrupt`
- `app:exit`
- `app:toggleTodos`
- `app:toggleTranscript`

### Chat

- `chat:cancel`
- `chat:cycleMode`
- `chat:modelPicker`
- `chat:fastMode`
- `chat:thinkingToggle`
- `chat:submit`
- `chat:queueSubmit`
- `chat:newline`
- `chat:externalEditor`
- `chat:stash`

### Current useful defaults

- `Ctrl+C`: interrupt / clear input
- `Ctrl+D`: exit
- `Ctrl+G`: external editor
- `Ctrl+O`: transcript viewer
- `Ctrl+R`: history search
- `Ctrl+B`: background
- `Ctrl+T`: task checklist
- `Ctrl+S`: stash prompt
- `Esc`: interrupt / close / decline permission
- `Esc Esc`: clear draft / rewind
- `Shift+Tab`: cycle permission modes
- `Option+P`: model picker
- `Option+T`: thinking toggle
- `Option+O`: fast mode

Recent Claude Code versions also support queued submission through semantic action：

```text
chat:queueSubmit
```

### Claude integration strategy

Prefer：

```text
semantic action
→ ClaudeAdapter
→ Claude-supported keyboard shortcut
```

后续 setup assistant 可以选择 patch：

```text
~/.claude/keybindings.json
```

把我们需要的 action 绑定到一组明确、稳定、无冲突的 shortcut。

必须：

- 修改前 backup
- JSON parse + merge，不能覆盖用户已有 config
- 保留用户定义优先级
- 支持 dry-run diff
- 支持 restore

---

## 9. macOS architecture

建议原生 Swift 实现。

### 9.1 App type

```text
Native macOS menu-bar app
Swift
SwiftUI + AppKit where required
```

不要 Electron。

理由：

- GameController.framework 直接可用
- CGEvent 直接可用
- 常驻内存低
- 蓝牙 controller 生命周期处理简单
- Accessibility 权限接入直接
- menu bar 很适合 profile/status

### 9.2 Modules

```text
App/
├── AppDelegate
├── MenuBar/
│   ├── StatusMenu
│   └── ProfilePicker
│
├── Input/
│   ├── ControllerInputSource.swift
│   ├── GameControllerSource.swift
│   ├── HIDControllerSource.swift
│   └── HardwareProbe.swift
│
├── Gesture/
│   ├── PhysicalButton.swift
│   ├── ButtonState.swift
│   ├── Gesture.swift
│   └── GestureRecognizer.swift
│
├── Actions/
│   ├── AgentAction.swift
│   ├── OutputRecipe.swift
│   └── ActionResolver.swift
│
├── Adapters/
│   ├── ToolAdapter.swift
│   ├── GenericTerminalAdapter.swift
│   ├── CodexAdapter.swift
│   └── ClaudeCodeAdapter.swift
│
├── Output/
│   ├── InputEmitter.swift
│   ├── CGEventEmitter.swift
│   └── MacroEmitter.swift
│
├── Security/
│   ├── AccessibilityPermission.swift
│   └── TargetAppGuard.swift
│
├── Config/
│   ├── AppConfig.swift
│   ├── ConfigStore.swift
│   └── Defaults.swift
│
└── Debug/
    ├── InputMonitorView.swift
    └── EventLogger.swift
```

---

## 10. Core interfaces

### 10.1 Physical input

```swift
enum PhysicalButton: String, Codable {
    case up
    case down
    case left
    case right
    case a
    case b
}

enum InputEvent {
    case pressed(PhysicalButton, timestamp: TimeInterval)
    case released(PhysicalButton, timestamp: TimeInterval)
}
```

### 10.2 Gestures

```swift
enum ControllerGesture: Equatable {
    case tap(PhysicalButton)
    case hold(PhysicalButton)
    case chord(modifier: PhysicalButton, key: PhysicalButton)
}
```

Do not add double-tap to MVP unless needed.

原因：double tap 会增加单击判定延迟。

### 10.3 Semantic actions

```swift
enum AgentAction: String, Codable {
    case navigateUp
    case navigateDown
    case navigateLeft
    case navigateRight

    case submit
    case cancelOrInterrupt

    case queueFollowUp
    case cyclePermissionMode
    case toggleFastMode
    case openModelPicker
    case inspectChanges
}
```

### 10.4 Adapter

```swift
protocol ToolAdapter {
    var id: ToolProfile { get }

    func recipe(
        for action: AgentAction,
        context: ActionContext
    ) -> OutputRecipe?
}
```

```swift
enum ToolProfile: String, Codable {
    case genericTerminal
    case codex
    case claudeCode
}
```

### 10.5 Output recipe

```swift
enum OutputStep: Equatable {
    case keyDown(KeyCode, modifiers: ModifierFlags)
    case keyUp(KeyCode, modifiers: ModifierFlags)
    case keyPress(KeyCode, modifiers: ModifierFlags)
    case text(String)
    case delay(milliseconds: Int)
}

struct OutputRecipe {
    let steps: [OutputStep]
    let requiresExplicitProfile: Bool
    let risk: ActionRisk
}
```

```swift
enum ActionRisk {
    case navigation
    case normal
    case macro
    case sensitive
}
```

---

## 11. Input output implementation

### 11.1 Keyboard injection

使用 Quartz：

- `CGEventCreateKeyboardEvent`
- `CGEventPost`

App 首次启动时检查 Accessibility：

```swift
AXIsProcessTrustedWithOptions(...)
```

如果没有授权：

- menu bar 状态显示 `Accessibility Required`
- 提供打开 System Settings 的入口
- 不静默失败

### 11.2 Modifier handling

必须确保：

```text
keyDown modifier
keyDown key
keyUp key
keyUp modifier
```

即使 macro 中途失败，也要通过 cleanup 释放 modifier。

否则容易出现：

```text
Shift stuck
Option stuck
Ctrl stuck
```

### 11.3 Event serialization

所有 output recipe 放在单独 serial queue / actor 中执行：

```swift
actor InputOutputEngine
```

禁止两个 chord 的 CGEvent 序列交叉。

---

## 12. Target application guard

MVP 不尝试判断 terminal 中到底运行哪个 shell subprocess。

只判断 frontmost macOS app 是否在 allowlist。

默认建议：

```text
Terminal
iTerm2
Ghostty
Warp
Visual Studio Code
Cursor
Windsurf
```

配置结构：

```json
{
  "allowedBundleIds": [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "com.microsoft.VSCode"
  ]
}
```

规则：

### Generic navigation

允许：

```text
Arrow
Enter
Escape
```

### Tool-specific action

必须同时满足：

```text
profile != genericTerminal
AND frontmost app allowed
```

### Macro action

额外要求：

```text
explicitProfileSelected == true
AND macrosEnabled == true
```

---

## 13. Suggested config model

```json
{
  "version": 1,
  "activeProfile": "genericTerminal",

  "timing": {
    "tapMaxMs": 220,
    "modifierAcquireMs": 200,
    "holdMs": 450
  },

  "bindings": {
    "base": {
      "up": "navigateUp",
      "down": "navigateDown",
      "left": "navigateLeft",
      "right": "navigateRight",
      "a": "submit",
      "b": "cancelOrInterrupt"
    },

    "bLayer": {
      "up": "cyclePermissionMode",
      "down": "toggleFastMode",
      "left": "openModelPicker",
      "right": "queueFollowUp",
      "a": "inspectChanges"
    }
  },

  "security": {
    "macrosEnabled": false,
    "requireAllowedFrontmostApp": true
  },

  "allowedBundleIds": [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "com.microsoft.VSCode"
  ]
}
```

Store in：

```text
~/Library/Application Support/<AppName>/config.json
```

不要存 secret。

---

## 14. Menu bar UX

Menu bar 至少显示：

```text
● L1162 Connected
Profile: Codex
```

或：

```text
○ L1162 Disconnected
```

菜单：

```text
Device
  L1162 Connected

Profile
  Generic Terminal
  Codex
  Claude Code

Debug
  Open Input Monitor
  Show Last Action

Permissions
  Accessibility: Granted

Settings
  Launch at Login
  Macros
  Allowed Apps

Quit
```

### Debug monitor

非常重要，建议 MVP 就做：

```text
RAW:       B down
RAW:       Right down
GESTURE:   chord(B, Right)
ACTION:    queueFollowUp
PROFILE:   Claude Code
OUTPUT:    Ctrl+X → Enter
TARGET:    com.mitchellh.ghostty
```

这样后续调 L1162 的 HID 行为会快很多。

---

## 15. CodexAdapter v0.1

目标是尽量基于 Codex semantic keymap。

伪代码：

```swift
final class CodexAdapter: ToolAdapter {
    func recipe(
        for action: AgentAction,
        context: ActionContext
    ) -> OutputRecipe? {
        switch action {
        case .navigateUp:
            return .key(.upArrow)

        case .navigateDown:
            return .key(.downArrow)

        case .navigateLeft:
            return .key(.leftArrow)

        case .navigateRight:
            return .key(.rightArrow)

        case .submit:
            return .key(.return)

        case .cancelOrInterrupt:
            return .key(.escape)

        case .queueFollowUp:
            return codexKeymap.queue

        case .cyclePermissionMode:
            return codexKeymap.nextPermissionMode

        case .toggleFastMode:
            return codexKeymap.toggleFastMode

        case .openModelPicker:
            return codexKeymap.openModelPicker
                ?? safeSlashCommand("/model")

        case .inspectChanges:
            return safeSlashCommand("/diff")
        }
    }
}
```

### Important

Codex 支持 `/keymap`，因此 implementation agent 应：

1. 先读取当前 Codex version
2. 检查实际 `$CODEX_HOME/config.toml`
3. 不覆盖现有 user config
4. 为需要的 semantic action 选择无冲突 shortcut
5. 让 app 读取同一套 binding

不要把快捷键散落 hardcode 在 Swift source 里。

建议抽象：

```swift
struct CodexKeymap {
    let queue: OutputRecipe
    let nextPermissionMode: OutputRecipe
    let toggleFastMode: OutputRecipe
    let openModelPicker: OutputRecipe?
}
```

---

## 16. ClaudeCodeAdapter v0.1

Claude Code 的 keybinding API 更适合做明确映射。

默认可以先使用官方行为：

```text
Cancel             → Esc
Cycle Permission   → Shift+Tab
Model Picker       → Option+P
Fast Mode          → Option+O
Queue Submit       → configured `chat:queueSubmit`
```

对于 queue，优先读取用户已有：

```text
~/.claude/keybindings.json
```

后续提供可选 `Configure Claude Code` 操作：

1. backup
2. parse
3. merge
4. show diff
5. user confirms
6. write
7. restore available

不要直接 replace 整个 JSON。

### Diff / transcript

Claude Code 有：

```text
app:toggleTranscript
```

以及较新的 fullscreen diff panel action。

`inspectChanges` 的 v0.1 默认行为建议：

```text
Claude → transcript / configured diff action
Codex  → /diff
```

把具体实现放进 Adapter，不放进 Gesture Engine。

---

## 17. Safety model

这个项目会向 terminal 注入按键，因此必须把安全作为一等设计。

### MUST

- 默认 `macrosEnabled = false`
- slash command typing 属于 macro
- tool-specific macro 只能在明确 profile 下运行
- frontmost app 必须通过 allowlist
- 不提供一键 bypass permissions
- 不提供一键执行 arbitrary shell command
- 不映射 `approve forever` / `approve for prefix` 到单击
- 任何 modifier 注入后必须保证 release
- app quit / sleep / disconnect 时清空 internal button state

### Permission prompts

保持：

```text
A = Enter / selected confirmation
B = Escape / decline/cancel
```

让 agent 自己的原生 UI 决定最终语义。

不要绕过确认层。

---

## 18. State machine details

B 作为 modifier 时最容易出现误触，需要明确 state machine。

建议：

```text
Idle

B down
→ BPending

if B released before chord/hold:
→ emit B tap = Escape
→ Idle

if secondary key down while BPending:
→ ChordActive(B, key)
→ suppress B tap

if B held beyond hold threshold:
→ BModifierReady

secondary key down while BModifierReady:
→ ChordActive(B, key)

all keys released:
→ Idle
```

要求：

- 一个 chord 每次只触发一次
- held dpad 不应重复触发 destructive/semantic action
- base navigation可以支持 key repeat
- secondary layer 默认不 repeat
- disconnect 时强制 reset

---

## 19. Key repeat policy

### Allow repeat

```text
navigateUp
navigateDown
navigateLeft
navigateRight
```

### No repeat

```text
submit
cancel
queueFollowUp
cyclePermissionMode
toggleFastMode
openModelPicker
inspectChanges
```

---

## 20. Testing

### 20.1 Unit tests

Gesture：

- B tap → cancel
- B + Up → permission
- B + Down → fast
- B + Left → model
- B + Right → queue
- B + A → inspect
- B chord does not emit Escape
- reconnect resets state
- held chord fires once

Adapter：

- same AgentAction maps differently per profile
- generic profile never emits slash macro
- macro disabled → no macro output
- disallowed target → no tool-specific output

### 20.2 Integration tests

至少测试：

- Apple Terminal
- Ghostty
- VS Code integrated terminal

如果环境可用，再测：

- iTerm2
- Cursor
- Windsurf

Agent：

- Codex CLI
- Claude Code

### 20.3 Manual acceptance flows

#### Flow A — basic navigation

```text
Open Codex / Claude
Open slash menu
D-pad moves selection
A selects
B closes
```

#### Flow B — permission prompt

```text
Permission prompt appears
D-pad selects option
A confirms selected option
B declines/cancels
```

#### Flow C — permission mode

```text
Hold B + Up
Exactly one permission-mode cycle happens
No Escape leaks
```

#### Flow D — queue

```text
Agent is working
Type follow-up text
B + Right
Follow-up is queued
Current turn is not unintentionally canceled
```

#### Flow E — reconnect

```text
Turn controller off
Turn it on
Reconnect
No app restart
All mappings restored
```

---

## 21. MVP acceptance criteria

v0.1 完成定义：

### Hardware

- [ ] L1162 在 C 模式下被 app 识别
- [ ] 6 个主要输入完整
- [ ] hot reconnect

### Base controls

- [ ] D-pad
- [ ] A / Enter
- [ ] B / Escape
- [ ] correct key repeat

### Agent layer

- [ ] B+Up permission
- [ ] B+Down fast
- [ ] B+Left model
- [ ] B+Right queue
- [ ] B+A inspect

### Profiles

- [ ] Generic Terminal
- [ ] Codex
- [ ] Claude Code

### macOS

- [ ] Accessibility onboarding
- [ ] target-app guard
- [ ] menu-bar status
- [ ] debug monitor
- [ ] launch at login optional

### Safety

- [ ] macros off by default
- [ ] no stuck modifiers
- [ ] no one-tap dangerous permission bypass
- [ ] no arbitrary shell execution

---

## 22. Implementation phases

### Phase 0 — Hardware Probe

Deliverable:

```text
Minimal macOS app / CLI probe
```

输出 raw controller state。

不要先做 UI。

### Phase 1 — Controller Core

实现：

- input source
- reconnect
- gesture recognizer
- CGEventEmitter
- base mapping

### Phase 2 — Menu Bar App

实现：

- connection state
- profile picker
- accessibility status
- debug monitor
- config persistence

### Phase 3 — Codex / Claude Adapters

实现：

- Codex keymap integration
- Claude keybindings integration
- B-layer actions

### Phase 4 — Setup Assistant

可选：

- inspect Codex keymap
- inspect Claude keybindings
- suggest conflict-free bindings
- backup / merge / restore

### Phase 5 — Nice-to-have

以后考虑：

- app-specific profile memory
- shell integration for trustworthy tool detection
- long-press / double-tap custom mappings
- user-configurable layer editor
- Shortcuts.app actions
- media mode
- Stream Deck-like generic actions

---

## 23. Decisions that should NOT be changed without evidence

1. **C / Gamepad mode is the primary hardware path.**
2. H / keyboard mode is fallback only.
3. GameController is preferred over raw IOHIDManager.
4. IOHIDManager is fallback if GameController does not expose enough controls.
5. Physical button → semantic action → adapter; no direct global hardcoding.
6. Base layer stays generic and predictable.
7. Tool profile is explicit in MVP.
8. Macro injection is secondary and guarded.
9. No dangerous one-tap permission bypass.
10. Hardware probe comes before full implementation.

---

## 24. Questions the implementation agent must answer during Phase 0

Record answers in `docs/hardware-probe.md`:

1. What `vendorName` does macOS report?
2. What `productCategory`?
3. Which C mode works better:
   - XInput-like
   - Wireless Controller
4. Is `extendedGamepad` available?
5. How are D-pad controls exposed?
6. How are A/B exposed?
7. Is the pairing button exposed?
8. Are simultaneous B + direction presses observable?
9. Does macOS generate any unwanted keyboard events in C mode?
10. Does Bluetooth reconnect preserve the same controller identity?

Do not guess any of these.

---

## 25. Suggested repository bootstrap

```text
PocketAgentRemote/
├── README.md
├── docs/
│   ├── implementation-spec.md
│   ├── hardware-probe.md
│   └── mappings.md
├── PocketAgentRemote.xcodeproj
├── PocketAgentRemote/
└── PocketAgentRemoteTests/
```

Suggested README one-liner：

> Turn the IINE L1162 mini controller into a pocket remote for Codex and Claude Code on macOS.

---

## 26. Agent kickoff prompt

可以直接把下面这段交给 coding agent：

```text
Implement this spec incrementally.

Start ONLY with Phase 0 Hardware Probe.

Do not assume IINE L1162 button IDs or HID mappings.
Use Apple's GameController framework first.
Enumerate the connected controller and expose/log every available physical input.
Test both L1162 C-mode variants if needed.

Create docs/hardware-probe.md and record verified findings.

Only after all six primary controls (D-pad + A + B) are observable and simultaneous
B+direction chords are verified should you proceed to Phase 1.

Architecture constraints:
- Native macOS Swift app
- GameController first, IOHIDManager fallback
- CGEvent for output
- semantic action layer between physical controls and tool adapters
- explicit Codex / Claude / Generic profiles
- no kernel extension
- no network dependency
- no arbitrary shell execution
- macros disabled by default
- preserve all user Codex/Claude configs and backup before modifying anything

Add unit tests for gesture state transitions before implementing tool-specific adapters.
```

---

## 27. Sources / verification references

### IINE L1162

Official product page:

https://www.iine.top/products/mi-ni-kong-zhi-qi

Official product/manual information establishes:

- L1162
- C gamepad mode
- H keyboard/mouse mode
- iOS / Android / computer support
- physical layout

### OpenAI Codex CLI

Codex interactive/developer commands:

https://developers.openai.com/codex/cli/slash-commands

Codex source repository:

https://github.com/openai/codex

Relevant current capabilities verified during this spec research:

- `/keymap`
- semantic TUI actions including queue, permission-mode navigation and fast-mode toggle
- `/diff`
- `/review`
- `/permissions`
- `/model`
- `/fast`
- queued input / interrupt behavior

### Claude Code

Interactive mode:

https://docs.anthropic.com/en/docs/claude-code/interactive-mode

Keyboard customization:

https://docs.anthropic.com/en/docs/claude-code/keybindings

Relevant current capabilities verified during this spec research:

- `chat:cycleMode`
- `chat:modelPicker`
- `chat:fastMode`
- `chat:queueSubmit`
- `chat:submit`
- `chat:cancel`
- `app:toggleTranscript`
- customizable `~/.claude/keybindings.json`

### Apple

GameController:

https://developer.apple.com/documentation/gamecontroller

Accessibility trust:

https://developer.apple.com/documentation/applicationservices/axisprocesstrustedwithoptions(_:)

/ Quartz keyboard events:

https://developer.apple.com/documentation/coregraphics/cgevent
