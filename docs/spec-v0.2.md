# IINE L1162 → macOS Codex 桌面 App / Claude 桌面 App 遥控器
## Implementation Spec v0.2

> **Status: Draft for implementation（待人类拍板项见 §25，未拍板前不要进入 Phase 3）**
> **Last updated: 2026-09-15**
> Target: macOS native menu-bar utility
> Hardware: IINE 良值 L1162 迷你控制器（实测设备，见 `docs/hardware-probe.md`）
> Primary targets: **Codex 桌面 App**（`/Applications/ChatGPT.app`，bundle id `com.openai.codex`）与 **Claude 桌面 App**（`/Applications/Claude.app`，bundle id `com.anthropic.claudefordesktop`）
> Primary interaction model: controller input → gesture → semantic action → **desktop-app adapter** → menu click / key injection

**证据等级图例**（全文统一，每个关键结论后括号标注来源）

| 标记 | 含义 |
|---|---|
| **实测验证** | 本次项目在本机跑命令/跑探针并看到输出（`docs/hardware-probe.md`、`docs/phase0-summary.md`、两份 research 里标 `【实测】` 的部分） |
| **静态推断** | 从 app.asar / 二进制 / 注册表 / 配置结构中读出，**未做端到端运行验证**（research 里标 `【代码】` / `【静态】` / `【推断】` 的部分） |
| **未验证** | 只有线索，本次刻意未验证；全部集中在 §9 |

⚠️ **本文档不引入任何未被上述五份输入文档覆盖的结论。** 凡是输入文档没查到的，本文档一律写「未验证」并给出验证它的副作用，而不是补全。

---

## 0. 本版相对 v0.1 的变更摘要

### 0.1 一句话

**语义动作层保留，适配层整条路线换掉。** v0.1 假设目标是 CLI（Codex TUI 的 `/keymap`、Claude Code CLI 的 `~/.claude/keybindings.json`、向终端注入按键）；用户已明确澄清实际目标是**桌面 App**。桌面 App 与 CLI **不是同一个程序、不共用控制面**（来源: research-codex-desktop.md，实测验证）。

### 0.2 保留（v0.1 的设计仍然成立）

| v0.1 位置 | 内容 | 结论 |
|---|---|---|
| §1 / §2 | 目标、非目标 | 保留，目标对象由 CLI 改为桌面 App |
| §5 | **语义动作层**（物理输入 → 手势 → 语义动作 → 适配层 → 输出） | **保留**，这是 v0.1 最有价值的设计 |
| §9 | 分层架构、原生 Swift menu-bar app、不用 Electron | 保留 |
| §10 | 核心接口 | 保留，类型按桌面 App 调整（§14） |
| §17 | 安全模型 | 保留，新增「桌面 App 面板级歧义」风险 |
| §18 | 手势状态机（B 作为 modifier） | 保留 |
| §19 | 按键重复策略 | 保留 |
| §20 | 测试策略 | 保留，测试对象由终端改为两个 App |
| §22 | 实施阶段划分 | 保留骨架，阶段内容按新路线重排（§21） |

### 0.3 删除 / 作废（CLI 专属，v0.2 不再适用）

| v0.1 位置 | 内容 | 作废理由 |
|---|---|---|
| §7 | Codex CLI TUI 的 `[tui.keymap]` 集成 | 桌面 App 跑的是 Electron + 私有 `codex app-server`，**不跑 TUI**；`[tui.keymap]` 对桌面 App **零影响**（来源: research-codex-desktop.md，实测验证） |
| §8 | 改写 `~/.claude/keybindings.json`、`chat:cycleMode` 等 CLI action 命名空间 | 桌面 Code 面板用的是 `ion-dist` 里的 `jz` 键表与 `XP` 注册表，**两套命名空间无已知映射关系**（来源: research-claude-desktop.md，未验证是否存在映射） |
| §15 | `CodexAdapter` 基于 Codex semantic keymap | 桌面 App 的快捷键是另一套命令注册表（131 条），且部分命令**根本没有默认键位**（来源: research-codex-desktop.md，实测验证） |
| §16 | `ClaudeCodeAdapter` / Claude keybindings patch | 同上；且 `~/.claude/keybindings.json` 是否影响桌面 App **未验证**（当前该文件不存在） |
| §12 的 allowlist | Terminal / iTerm2 / Ghostty / VS Code | 目标应用换成两个桌面 App 的 bundle id（§11） |
| §13 / §14 的 `Profile` 概念 | Generic Terminal / Codex / Claude Code 三选一 | 改为「目标 App 探测 + surface 感知」，profile 退化为兜底开关（§11.4、§12） |
| §3 硬件假设 | 只有 C / H 两种模式 | **漏了 T 档，且每档有两个变体**（来源: phase0-summary.md，实测验证） |
| §23 决策 3 | 「GameController 优先于 IOHIDManager」 | 限定为「仅 XInput 变体优先」；IOHIDManager 升为**一级输入源**（§3、§4） |
| §6.1 | 假定 B = Escape | 仅 C/XInput + GC 路径成立；H 模式下 B 是 `Space`（来源: phase0-summary.md，实测验证） |

### 0.4 新增（本版独有章节）

| 章节 | 内容 | 为什么必须有 |
|---|---|---|
| §3 | Phase 0 硬件实测约束（7 条硬性约束） | 不固化就会在 Phase 1 踩坑（来源: phase0-summary.md §5） |
| §4 | 模式与变体模型（T/C/H × 每档两变体）+ 为什么 IOHIDManager 是一级输入源 | 用户明确要求：C 档两个变体都必须可用 |
| §7 | 能力矩阵（11 语义动作 × 2 App × 4 种机制 × 证据等级） | 决定每一格能不能做、靠什么做 |
| §8 | 能力缺口与降级方案 | 4 个缺口必须给出明确降级或明确不可用 |
| §9 | 未验证项清单（含验证副作用） | 防止实现者把【静态推断】当【实测验证】用 |
| §10 | 风险登记 | 外部依赖会整体失效（如 `disableDeepLinkRegistration`） |
| §11 | 目标应用守卫 + surface 感知 | 同一个 App 内 chat / cowork / code 三个面板语义不同 |
| §25 | 需要人类拍板的决策清单 | 有 14 项取舍不能由实现者替用户决定 |

### 0.5 本版最重要的一句结论

**桌面 App 上「程序化接口」这一层在两个目标 App 上几乎都是空的，唯一稳定的机制是向有焦点的窗口注入按键（CGEvent）。** Codex 桌面 App 没有任何对外可用的本地程序化控制面（来源: research-codex-desktop.md，实测验证）；Claude 桌面 App 没有留任何进程外 API（来源: research-claude-desktop.md，实测验证）。因此 v0.2 的适配层必须按「程序化 > 菜单点击 > 按键注入」的优先级设计，但**实际落到第三层的比例极高**。

---

## 1. 目标

把 IINE L1162 迷你控制器变成一个面向 AI Coding Agent 工作流的 macOS 随身控制器，遥控**正在运行的 Codex 桌面 App 与 Claude 桌面 App**。

```text
L1162 physical input
        ↓
Controller input backend（GameController + IOHIDManager，两条都是一级）
        ↓
Gesture / Layer engine
        ↓
Semantic Agent Actions
        ↓
Desktop App Adapter
   ├── CodexDesktopAdapter   (com.openai.codex)
   ├── ClaudeDesktopAdapter  (com.anthropic.claudefordesktop)
   └── GenericAdapter        (无适配层，只发基础键)
        ↓
Delivery Layer（按优先级）
   1. Programmatic  —— deep link / CLI / IPC
   2. Native menu   —— AXUIElement / System Events 菜单点击
   3. Key injection —— CGEvent 合成按键
        ↓
macOS frontmost App
```

最终用户应该能够单手完成最常见的操作：

- 上下左右导航
- Submit / Confirm
- Cancel / Interrupt
- Queue follow-up
- 切换 permission mode
- 切换 fast mode
- 打开 model picker
- 查看 diff / changes
- 在两个目标 App 之间切换

---

## 2. 非目标

v0.2 不做：

- 修改 L1162 固件
- USB/Bluetooth 协议逆向（Phase 0 已证明 GameController + IOHIDManager 足够读出 6 个输入）
- kernel extension、root 权限
- 自动执行危险 shell command
- 自动开启 `--dangerously-skip-permissions` / bypass 权限模式
- **实现或依赖 Codex TUI / Claude Code CLI 的 keymap**（CLI 路线在 v0.2 中彻底移除）
- **依赖 `~/.codex/ipc/ipc.sock`**（能力未验证，见 §10 风险 R3）
- **依赖 Anthropic 内置的蓝牙硬件伴侣（`hardwareBuddyEnabled` / `buddy-ble`）**，仅作为干扰源登记（§10 风险 R1）
- 读取会话内容做「智能判断」（需要 AX 状态读取，是 v0.3 议题，见 §21 Phase 5）
- 网络服务、账号登录、云同步
- 支持 T 档（多媒体触控）与 H 档作为主路径

---

## 3. Phase 0 硬件实测约束（硬性，7 条）

以下 7 条来自 `docs/phase0-summary.md` §5，全部为**实测验证**。每条都给出「如果不遵守会发生什么」（后果）。**这些是 Phase 1 一开始就要固化进代码的规则，不是等踩坑后补的。**

### C1. `GCController.shouldMonitorBackgroundEvents = true` 是硬性要求

- **内容**：自 macOS 11.3 起该属性默认 `NO`，含义是「非前台 App 收不到任何手柄事件」。menu-bar 工具永远不是前台 App。
- **后果**：不设这一行，整条 GameController 路径**静默失效** —— 不报错、不崩溃、`controllers()` 仍能看到设备，但回调 0 条。实测：同一套按键，设之前 GC 回调 0 条，设之后 36 条。
- 来源: phase0-summary.md §5.1，实测验证（原始记录 hardware-probe.md §6.5）

### C2. GameController 只覆盖 XInput 变体，IOHIDManager 是必需路径而非兜底

- **内容**：泛用 `Wireless Controller` 变体和 H 模式下 `GCController.controllers()` 恒为 `count=0`，且不会有 `GCControllerDidConnect`。
- **后果**：若只实现 GC 路径，用户一旦切到泛用变体，App 表现为「完全没反应」。要么实现 HID 路径，要么**主动检测该变体并给出明确提示**，不能静默。
- 来源: phase0-summary.md §5.2，实测验证

### C3. 设备匹配不能只看 VID/PID，也不能用 `location`

- **内容**：泛用 C 变体与 H 键盘共用 `0x4353`/`0x9b09`；`location` 重连后会变（实测 `2142999777` → `584791771`）。
- **后果**：只看 VID/PID 会把用户的键盘当成手柄（H 模式泄漏时更严重）；只看 `location` 会在每次重连后失配。必须用 **product 名 + usage（+ VID/PID 辅助）**。
- 来源: phase0-summary.md §5.3，实测验证（原始记录 hardware-probe.md §2、§6.7）

### C4. 每个 element 只能绑定一次

- **内容**：`extendedGamepad` 与 `microGamepad` 是**同一个对象**（指针实测相同），元素全部共享；`pressedChangedHandler` 是赋值不是追加。
- **后果**：绑两次会静默覆盖，回调名字与预期不符（探针第一版就因此报出 `Micro.Up`，看起来像设备属性，实为探针 artifact）。同理 `physicalInputProfile.elements["Button A"]` 与 `extendedGamepad.buttonA` 也是同一对象。
- 来源: phase0-summary.md §5.4，实测验证（原始记录 hardware-probe.md §6.6）

### C5. GameController 是异步附着的，启动瞬间查询不可靠

- **内容**：冷启动后头约 100ms `controllers()` 必然为空，真实设备只在 `GCControllerDidConnect` 里出现（实测 0.138s）。
- **后果**：启动时轮询会得出「没有手柄」的错误结论并可能永久放弃监听。必须挂连接/断开通知。
- 来源: phase0-summary.md §5.5，实测验证（原始记录 hardware-probe.md §6.7）

### C6. 模拟轴必须用死区

- **内容**：每次连接时，所有物理上不存在的轴都会上报一次中心值（如 `32767/65535`）。
- **后果**：`value > 0.5 ⇒ 按下` 这种朴素判断会把它们当成按下，凭空造出幽灵 chord（例如刚连上就触发 `B+↑`）。死区 + 不把轴上报当按键。
- 来源: phase0-summary.md §5.6，实测验证（原始记录 hardware-probe.md §6.7）

### C7. 设备移除时必须清空按键状态（两条路径都要）

- **内容**：手柄消失时不会为按住的键发 release。
- **后果**：探针在 HID 路径漏了这一步，导致「配对键一直按着」污染了后续整份日志。GC 路径与 HID 路径都必须 reset。
- 来源: phase0-summary.md §5.7，实测验证（原始记录 hardware-probe.md §6.8）

### 3.1 附带的两条禁令（同样来自实测）

- **不要硬编码 HID cookie 与 logical range**：两个 C 变体对同一个控件的 cookie 和取值范围都不同（hat cookie 33 range `[1,8]` null `0` vs cookie 29 range `[0,7]` null `15`；A/B cookie 11/12 vs 7/8）。映射表必须**按设备实例推导**。（来源: phase0-summary.md §5.8，实测验证）
- **不要映射配对键**：`Button 13`（page `0x9` usage `0xd`）既会切换变体又是电源键，映射它等于给用户一个「按了手柄就消失」的按钮。（来源: phase0-summary.md §5.8，实测验证）

---

## 4. 模式与变体模型

### 4.1 T / C / H 三档 × 每档两个变体

（来源: phase0-summary.md §2，实测验证；原始记录 hardware-probe.md §2）

| 开关 | 模式 | 默认设备 | 变体（配对键 + A） | 本项目 |
|---|---|---|---|---|
| **T** | 多媒体触控模式 | `IINE-Control`（触控） | `IINE-Phone`（多媒体） | **不实现**，但必须能识别并跳过 |
| **C** | 手柄模式 | **`Xbox Wireless Controller`（XINPUT）** | `Wireless Controller`（Gamepad） | **两个变体都必须支持** |
| **H** | 键盘鼠标模式 | `IINE_keyboard`（+ 鼠标） | 说明书未写（未知） | 仅识别并提示，不作主路径 |

### 4.2 实测身份对照（识别设备的唯一依据是 product + usage）

| 模式 | Product | VID / PID | Primary usage | 备注 |
|---|---|---|---|---|
| C / XInput | `Xbox Wireless Controller` | `0x045e` / `0x0b13` | `1/5` GamePad | 唯一能被 GameController 看到的形态 |
| C / generic | `Wireless Controller` | `0x4353` / `0x9b09` | `1/5` GamePad | **HID-only**，GC 永不附着 |
| H | `IINE_keyboard` | `0x4353` / `0x9b09` | `1/6` Keyboard | 与泛用 C 变体 VID/PID 完全相同 |

来源: phase0-summary.md §2，实测验证。

### 4.3 变体是持久状态，App 无法设置、只能检测

- 变体存在设备里，**扛得住关机重开，也扛得住平台开关往返**（C→H→C 回来后仍是原变体）。（来源: phase0-summary.md §2，实测验证）
- 唯一能改的路径是**配对键 + A 同时按住约 2 秒**；只点一下 A 会被静默忽略（实测：按住 2 秒 ✅ / 点 0.17 秒 ❌）。（来源: phase0-summary.md §2，实测验证）
- 变体切换会造成**完整的热插拔**（`HID-REMOVE` + 新设备 `HID-MATCH`）。（来源: phase0-summary.md §2，实测验证）
- **App 不能替用户切变体**，只能检测并告知。

### 4.4 为什么 IOHIDManager 必须是一级输入源（而不是兜底）

**用户需求**：手柄只要在 C 档，不管当前是哪个变体，App 都必须可用。

**实测事实**：GameController 框架**只认 XInput 变体**；泛用 `Wireless Controller` 变体对 GameController 完全不可见（`count=0`，无 `GCControllerDidConnect`）。（来源: phase0-summary.md §5.2 / §2 Q3，实测验证）

**推导**：由于变体是设备端持久状态、用户可能在任何时候处于任一变体、且 App 无法自动切回 XInput，唯一的实现方式是同时实现两条输入路径：

```text
XInput 变体  → GameControllerSource（含 C1 背景事件开关、C4 单次绑定）
泛用变体     → HIDControllerSource（含 C3 product+usage 匹配、C6 死区、C7 移除清状态）
两者都归一到同一个 ControllerInputSource 抽象 → Gesture Engine
```

因此 §23 决策「GameController 优先，IOHIDManager 兜底」在本版**必须改写**为：

> **在 XInput 变体下优先走 GameController；对泛用变体，IOHIDManager 是唯一路径，两者都是一级输入源。**

同时，即使两条路径都实现，**仍必须做「当前变体」的显式状态展示**（menu bar 显示 `C/XInput` 或 `C/generic` 或 `H` 或 `T/不支持`），因为用户看不到自己的手柄当前是哪个变体。

### 4.5 T 档与 H 档的处理（明确不做，但必须能识别）

- **T 档**：完全未采集（超出项目范围）。Phase 1 的设备匹配逻辑必须能识别 T 档设备名（`IINE-Control` / `IINE-Phone`）并**跳过 + 提示**，不能把它当成未知设备反复重试。
- **H 档**：实测会**严重泄漏**——6 个键全部作为普通按键进入前台 App（A = `Enter`、B = `Space`，不是 Escape）。因此 H 档绝不能做输入源；App 只应**识别并提示用户切回 C 档**。
- H 档的第二变体未知（说明书未记载）。
- 来源: phase0-summary.md §2 / §7，实测验证。

---

## 5. 为什么是语义动作层（v0.1 设计的保留）

不要这样写：

```swift
if button == .up {
    sendKey(.upArrow)
}
```

应该先定义：

```text
Physical input
→ Gesture
→ Semantic action
→ Adapter recipe（含 delivery tier）
```

例如：

```text
B + Up
→ cyclePermissionMode
→ CodexDesktopAdapter
→ ❌ 桌面 App 无此动作（来源: research-codex-desktop.md，实测验证）
→ 降级：提示「Codex 桌面版不支持切换权限模式」（§8 G1）
```

这个例子恰好说明语义动作层为什么必要：同一个语义动作在两个 App 上的落地方式完全不同，甚至一边做不到；如果直接把按键写死在手势里，就无法表达「做不到」这件事。

v0.2 在 v0.1 的四段式上增加一层 **delivery tier**，因为桌面 App 上「用什么机制把动作送进去」本身就是决策：

```text
Physical input
→ Gesture
→ Semantic action
→ Adapter（per target app）
→ Delivery tier（programmatic / menu / keystroke / unavailable）
→ Output recipe
```

---

## 6. 推荐按键映射

### 6.1 Base Layer —— 通用导航（保留 v0.1 设计，标注风险）

| L1162 | Semantic action | Default output | 风险 |
|---|---|---|---|
| ↑ | `navigateUp` | Arrow Up | `ActionRisk.navigation` |
| ↓ | `navigateDown` | Arrow Down | `ActionRisk.navigation` |
| ← | `navigateLeft` | Arrow Left | `ActionRisk.navigation` |
| → | `navigateRight` | Arrow Right | `ActionRisk.navigation` |
| A | `submit` | Return | normal |
| B tap | `cancelOrInterrupt` | Escape | normal |

**v0.2 的重要修正**：桌面 App 上这 4 个 `navigate*` **没有专用命令**，只能注入方向键，语义完全取决于当前焦点在哪个面板（会话列表 / 命令面板 / 审批选项 / 聊天区滚动）。这与 CLI 里 `↑/↓` = 会话列表 / 草稿历史的确定性语义**差别很大**。（来源: research-codex-desktop.md §6，静态推断）适配层必须把它们标为 `ActionRisk.navigation`（§14.5）。

### 6.2 Agent Layer —— 按住 B 作为 modifier

时间阈值沿用 v0.1：

```text
tap threshold:     <= 220 ms
modifier acquire:  180–250 ms
hold threshold:    >= 450 ms
```

| Chord | Semantic action | Codex 桌面 | Claude 桌面 |
|---|---|---|---|
| B + ↑ | `cyclePermissionMode` | ❌ 做不到（G1） | ⚠️ 只能「打开菜单 + 选择」（G2） |
| B + ↓ | `toggleFastMode` | ⚠️ 无默认快捷键（G3：命令面板兜底） | ✅ `⌘⌥F` |
| B + ← | `openModelPicker` | ✅ `⌃⇧M` | ✅ `⌘⇧I` |
| B + → | `queueFollowUp` | ⚠️ 运行中 `Enter`（未验证） | ❌ 无专用接口（G4） |
| B + A | `inspectChanges` | ✅ `⌃⇧G` / `⌘⌥B` | ✅ `⌘⇧D`（且原生菜单同一键位，交叉印证） |
| B hold alone | `cancelOrInterrupt` | ✅ `Esc` | ✅ `esc` |

证据来源逐条见 §7。

### 6.3 为什么 B 是 modifier

保持 v0.1 的理由：B 在游戏/UI 语义中本来就是 Back / Cancel / Escape，`B tap = Back`、`B + X = secondary command` 比把 A 当 modifier 更自然。**但 v0.2 补一条实测警告**：在 H 模式下 B 是 `Space` 而不是 Escape（来源: phase0-summary.md，实测验证）——这又一条 H 模式不能做主路径的理由。

### 6.4 目标 App 切换不占用 chord

沿用 v0.1 §6.4 的决策：只有 6 个主要输入，非常宝贵；profile 切错后可能把同一 chord 解释成不同的敏感操作。**v0.2 改为自动探测 + menu bar 显式覆盖**（§11.4）。

---

## 7. 能力矩阵（11 个语义动作 × 2 个 App × 4 种机制）

图例：

- ✅ = 该机制可用 ｜ ⚠️ = 可用但有明确缺陷/依赖 ｜ ❌ = 做不到或无对应
- 证据等级：**【实测】** / **【静态】** / **【未验证】**（定义见文档头部）

> **关于「程序化接口」列的总说明**：两个 App 都**不存在**针对这 11 个动作的专用编程接口。Codex 桌面 App「没有任何对外可用的本地程序化控制面」（来源: research-codex-desktop.md，实测验证）；Claude 桌面 App「没有留任何进程外 API」（来源: research-claude-desktop.md，实测验证）。两条 deep link 通道（`codex://` / `claude://`）都只做**会话级导航**，不覆盖任何**会话内动作**。因此该列除特别说明外全部为 ❌。

### 7.1 Codex 桌面 App（`com.openai.codex`）

| # | 语义动作 | 程序化接口 | 原生菜单点击 | 按键注入 | 做不到 | 证据等级 |
|---|---|---|---|---|---|---|
| 1 | `navigateUp` | ❌ | ❌（菜单无导航项） | ⚠️ `↑`，语义随焦点 | — | 静态推断 |
| 2 | `navigateDown` | ❌ | ❌ | ⚠️ `↓`，同上 | — | 静态推断 |
| 3 | `navigateLeft` | ❌ | ❌ | ⚠️ `←`，同上 | — | 静态推断 |
| 4 | `navigateRight` | ❌ | ❌ | ⚠️ `→`，同上 | — | 静态推断 |
| 5 | `submit` | ❌ | ❌ | ✅ `Enter`（`composer.submit`，受 `composerEnterBehavior` 控制） | — | 静态推断（源码分支） |
| 6 | `cancelOrInterrupt` | ❌ | ❌ | ✅ `Esc`（生成中 → `stop-turn` / `confirm-stop-turn`） | — | 静态推断（源码分支 `N_r()`） |
| 7 | `queueFollowUp` | ⚠️ `codex queue --thread <id> --message`（写存储，**运行中 App 是否采纳【未验证】**） | ❌ | ⚠️ 运行中 `Enter`（受 `[desktop] followUpQueueMode = "queue"` 控制） | — | 静态推断 + 实测验证（配置项存在） |
| 8 | `cyclePermissionMode` | ❌ | ❌ | ❌ | **✅ 做不到** | **实测验证**（131 条命令注册表只有 `approval.approve`/`approval.decline`；renderer 里 `Shift+Tab` 0 次命中） |
| 9 | `toggleFastMode` | ❌ | ❌ | ⚠️ **无默认快捷键**，只能 `⌘K` 命令面板或点 UI | — | 实测验证（`composer.toggleFastMode` 无 `defaultKeybindings`） |
| 10 | `openModelPicker` | ❌ | ❌ | ✅ `⌃⇧M`（`composer.openModelPicker`，无菜单项、渲染进程处理） | — | 实测验证（注册表默认键位） |
| 11 | `inspectChanges` | ❌ | ❌ | ✅ `⌃⇧G`（`openReviewTab`）/ `⌘⌥B`（`toggleSidePanel`） | — | 实测验证（注册表默认键位） |

**Codex 额外的可用动作（v0.1 没有、桌面 App 有默认键位的现成捷径）**（来源: research-codex-desktop.md §5.2 / §6，实测验证）：

```text
⌘N       newTask（新会话）          ⌘K / ⌘⇧P  openCommandMenu（命令面板）
⌘B       toggleSidebar             ⌘J         toggleBottomPanel
⌃`       toggleTerminal            ⌘⇧G        openReviewTab
⌃1..⌃3   switchToMode1..3（Chat / Work / Codex 三个面板）  ← surface 切换的关键
⌘⇧[ / ⌘⇧]  previous / next thread
⏎ / Esc  approval.approve / approval.decline（审批卡上下文）
```

> ⚠️ `approval.approve`（`⏎`）与 `approval.decline`（`Esc`）**只在审批卡上下文生效**——它们与 `submit` / `cancelOrInterrupt` 共用同一物理键，这正是 v0.1「A = Enter、B = Escape，让 agent 自己的原生 UI 决定最终语义」策略在桌面 App 上依然成立的原因（§13）。

### 7.2 Claude 桌面 App（`com.anthropic.claudefordesktop`）

> ⚠️ **语境前提**：下表第三列的键位来自 `ion-dist` 的 **Code session 语境** `jz` 键表与官方快捷键面板（**Code session / Composer 分组**）。同名的键位在 chat / cowork 语境语义不同，实现时必须先做 surface 判定（§11.3）。

| # | 语义动作 | 程序化接口 | 原生菜单点击 | 按键注入 | 做不到 | 证据等级 |
|---|---|---|---|---|---|---|
| 1 | `navigateUp` | ❌ | ❌ | ⚠️ `⌘⌥↑`（`jumpPrevPrompt`，会话内提示级跳转）或 AX 选中后 `↑` | — | 静态推断（键位）/ 未验证（实际行为） |
| 2 | `navigateDown` | ❌ | ❌ | ⚠️ `⌘⌥↓`（`jumpNextPrompt`） | — | 同上 |
| 3 | `navigateLeft` | ❌ | ✅ `Go > Back`（`⌘[`，历史后退） | ⚠️ `⌘⌥←`（前一 sidebar tab） | — | 菜单项实测验证 / 键位静态推断 |
| 4 | `navigateRight` | ❌ | ✅ `Go > Forward`（`⌘]`，历史前进） | ⚠️ `⌘⌥→`（后一 sidebar tab） | — | 同上 |
| 5 | `submit` | ❌ | ❌ | ⚠️ `enter`（**Code session 语境为【未验证】**：Code UI 的 Composer 分组里没有 `enter`/`shift+enter` 条目，提交可能由 textarea 组件自身处理） | — | 静态推断（chat 语境）/ **未验证**（Code 语境） |
| 6 | `cancelOrInterrupt` | ❌ | ❌ | ✅ `esc`（官方面板 Code session General 组明确写 "Stop Claude's response"） | — | 静态推断 |
| 7 | `queueFollowUp` | ❌ | ❌ | ❌ | **✅ 做不到**（无专用接口；`⌘⌥enter` 是 "Send in a forked session"，**语义不同，慎用**） | 静态推断 + 未验证 |
| 8 | `cyclePermissionMode` | ❌ | ❌ | ⚠️ `⌘⇧M`（`openModeMenu`）打开菜单后 `1…9` 选择；**没有「循环」动作** | — | 静态推断 |
| 9 | `toggleFastMode` | ❌ | ❌ | ✅ `⌘⌥F`（`jz` 表中 `toggleFastMode` 唯一来源） | — | 静态推断 |
| 10 | `openModelPicker` | ❌ | ❌ | ✅ `⌘⇧I`（`openModelMenu`）；命令面板注册表里 `model_selector` = `⌘⇧.`，两处来源一致指向「打开模型菜单」 | — | 静态推断（交叉印证） |
| 11 | `inspectChanges` | ❌ | ✅ `View > Show Changes`（`⌘⇧D`） | ✅ `⌘⇧D`（`toggleDiff`） | — | 菜单项实测验证 + 键位静态推断（同一键位交叉印证） |

**Claude 深链能做的事**（4 条动作型路由，来源: research-claude-desktop.md §3.2，静态推断；仅 `resume` 路由的非法参数分支是实测验证）：

```text
claude://code/new?q=&folder=&file=     新建 Code 会话
claude://code/continue?session=last    打开最近 Code 会话
claude://code/needs-input              跳到等权限答复最久的会话
claude://resume?session=<uuid>         导入 CLI 会话记录并继续
```

**这 4 条没有一条对应 §7 的 11 个语义动作** —— 它们是「会话级跳转」，不是「会话内动作」。它们可作为 v0.3 的补充动作（如 `openSessionNeedingInput`），但**不能用来实现本版的任何一格**。

### 7.3 矩阵的三个关键读数

1. **能用程序化接口完成的语义动作：0 个**（两个 App 都是 0）。唯一沾边的是 Codex 的 `codex queue`，但它「是否被运行中的 App 采纳」未验证（§9 U4）。
2. **能用原生菜单点击完成的语义动作：Claude 2 个**（`navigateLeft` / `navigateRight` 的历史语义、`inspectChanges`）；**Codex 0 个**（Codex 菜单里没有任何业务动作，只有窗口与面板级操作，来源: research-codex-desktop.md §4.7，实测验证）。
3. **必须靠按键注入：Codex 10 / 11，Claude 9 / 11**。这是本版的安全模型必须比 v0.1 更严的根本原因（§13）。

---

## 8. 能力缺口与降级方案

每个缺口给出**明确降级或不Available**，不含糊。缺口编号 G1–G4 供实现与测试引用。

### G1. Codex 桌面 App 没有 `cyclePermissionMode`

- **事实**：Codex 桌面 App **不存在「循环权限模式」这个动作**。131 条命令注册表里权限相关只有 `approval.approve`（`Enter`）与 `approval.decline`（`Esc`）；渲染进程 bundle 里 grep `Shift+Tab`：`app-primary.js` 0 次，`app-initial.js` 的 3 次全部属于 `previousTab`（标签切换）。（来源: research-codex-desktop.md §5.5，实测验证）
- **为什么无法绕过**：唯一可能程序化改权限档的路径是 app-server 的 `thread/settings/update` / `permissionProfile/list`，但桌面 App 的 app-server 挂在 **stdio 私有管道**上，外部进程拿不到（来源: research-codex-desktop.md §2.2，实测验证）。
- **降级方案（二选一，需人类拍板，见 §25 Q5）**：
  - **D1-a（推荐，安全侧）**：`cyclePermissionMode` 在 Codex 上标记为 **不可用**。按下 `B + ↑` 时，menu bar 浮层提示「Codex 桌面版没有权限模式切换，请用审批卡上的 A/B」，**不注入任何按键**。
  - **D1-b（功能侧，有风险）**：把 `B + ↑` 重映射为 Codex 侧的「approval 相关」动作，即 `approval.approve`（`Enter`）。**⚠️ 这会让「想切模式」变成「批准一次操作」，语义完全错位，且踩到 v0.1 §17 的「不提供一键 approve」红线。不推荐，除非用户明确要求。**
- **绝不允许**：把 `B + ↑` 静默映射成某个「看起来像」的键（例如 `⌘K` 后盲打命令名），因为这会在用户不知情的情况下改变权限档。

### G2. Claude 的 `cyclePermissionMode` 「循环」语义做不到

- **事实**：Claude 桌面 Code 面板只有 `openModeMenu`（`⌘⇧M`，打开菜单），**没有循环动作**；菜单项要用 `1…9` 选择。（来源: research-claude-desktop.md §4.2 / §7.1，静态推断）
- **缺口本质**：真正的 `cyclePermissionMode` 需要「读取当前模式 → 计算下一档 → 选中」，即需要 AX 状态读取；而 Code 面板的 AX 元素标识**尚未探明**（来源: research-claude-desktop.md §5.7，未验证）。
- **降级方案（推荐，两段式）**：
  - `B + ↑` → 注入 `⌘⇧M` 打开 mode menu，浮层提示「用方向键选择后按 A 确认」。
  - **不做**「打开菜单 + 盲发 `1`」这种伪循环：菜单项顺序未验证，盲选可能选到 `bypassPermissions` 一类高风险档（v0.1 §17 / 本版 §13 明令禁止）。
  - **v0.3 升级路径**：探明 Code 面板 AX 标识后，先读当前模式再按键，实现真正的循环。

### G3. Codex 的 `toggleFastMode` 无默认快捷键

- **事实**：`composer.toggleFastMode` 存在于命令注册表，但**没有 `defaultKeybindings`**。（来源: research-codex-desktop.md §5.3 / §6，实测验证）
- **可用的三条路**：
  - **D3-a（推荐）**：`⌘K` 打开命令面板 → 输入命令名（如 "fast"）→ `Enter`。**这属于 v0.1 §17 定义的 macro（文本注入）**，必须满足 `macrosEnabled == true` + 明确 profile + 目标 App 在 allowlist（§13）。命令名必须可配置，不能 hardcode 未验证的字符串。
  - **D3-b**：放弃，标记不可用，只提示用户。
  - **D3-c**：引导用户**在 App 内**把 `composer.toggleFastMode` 绑到一个自定义快捷键（App 内 UI 的 `set-codex-command-keybinding` IPC 存在，来源: research-codex-desktop.md §4.1，实测验证），然后 App 读用户配置使用它。**⚠️ 该 IPC 的落盘位置未验证**（§9 U8），因此「App 能读到用户绑了什么键」这件事目前无法保证。
- **默认策略**：**D3-b**（v0.2 先不可用 + 提示），把 D3-a 作为可选开关、D3-c 作为 v0.3 议题。

### G4. `navigate*` 在两边都只能注入方向键，语义随焦点变化

- **事实**：Codex 注册表里**没有**通用 navigate 命令，`↑/↓` 只出现在各上下文（`select:previous`、`autocomplete:previous`、`footer:up`…，来源: research-codex-desktop.md §6，静态推断）；Claude 侧 `⌘⌥↑/↓` 是「提示级跳转」而非「列表导航」（来源: research-claude-desktop.md §7.1，静态推断）。
- **降级方案**：
  - 把 4 个 `navigate*` 统一标记为 **`ActionRisk.navigation`**（§14.5）。
  - 仅在「目标 App 是 frontmost 且 Pass 1 守卫通过」时注入，且**永不进入 macro 路径**（不弹命令面板、不输入文本）。
  - menu bar / debug monitor 必须显示 `TARGET` 与当前 surface，让用户知道方向键会被谁吃掉。
  - **明确的不可用边界**：当焦点在内置浏览器标签页或终端面板时，方向键的语义**完全不同**（来源: research-codex-desktop.md §7 风险 1，静态推断）。这种情况 v0.2 **不做自动判定**，只在 menu bar 显示警告（surface 感知是 v0.3，§21 Phase 5）。

### G5（附带）. `submit` 在 Claude Code session 语境存疑

严格说这是「未验证」而非「缺口」，但它会影响核心流程，单列：

- **事实**：Claude 的 Code session `Composer` 分组里**没有** `enter` / `shift+enter` 条目；`enter` → "Send message" 只出现在第一套（chat/cowork）列表里。（来源: research-claude-desktop.md §4.3，静态推断）
- **实现要求**：代码里不得把「`enter` 一定提交」写成既定事实。首次在 Claude Code 面板使用 `submit` 时做一次轻量自检（见 §9 U10 的验证方案），或在 UI 上提供「submit 键位可配置」开关。
- **降级**：若实测发现 Code 语境 `enter` 不提交，则**没有已验证的替代键位**（`⌘⌥⏎` 是 "Send in a forked session"，语义不同，不可用），此时应把 `submit` 在 Claude Code 面板标记为**不可用 + 提示**，而不是猜一个键。

---

## 9. 未验证项清单

**本节的用途**：把两份调研中所有「未验证」的结论集中列出，并标注**验证它会有什么副作用**。任何实现者在写代码前若需要依赖表中某项，必须先完成验证并把结果写回本文档（或 `docs/hardware-probe.md` 的同级文档）。

**先看副作用的分类**（决定了「什么时候能验」）：

| 副作用等级 | 含义 | 典型场景 |
|---|---|---|
| **零副作用** | 只读或非法参数探测，不改用户状态 | 读 AX 树、grep bundle、`open claude://resume?session=not-a-uuid` |
| **改 UI 状态** | 会切换/新建/关闭窗口或面板，不改会话内容 | 发 deep link、点菜单、开 Code 会话 |
| **改会话数据** | 会往用户真实会话里写内容、触发一轮 turn、改权限档 | 注入 `Enter`、`codex queue`、`thread-follower-*` |
| **改运行环境** | 需要重启 App、加启动参数、装东西 | `--remote-debugging-port`、安装 CLI |

### 9.1 Codex 桌面 App

| # | 未验证项 | 为什么没验 | 验证的副作用 | 等级 |
|---|---|---|---|---|
| U1 | `codex://` deep link 的**端到端 UI 行为**（真的 `open -g "codex://..."` 之后发生什么） | 会改变正在运行的用户 App 的 UI 状态（可能新建会话、弹设置窗口） | 改 UI 状态 | 未验证 |
| U2 | `~/.codex/ipc/ipc.sock` 上 `thread-follower-*` 系列（start-turn / interrupt / steer / approval decision）是否有人应答 | 全部是变更操作，在真实会话上触发会污染用户数据；只测了只读的 `thread-owner-discovery` → `no-client-found` | **改会话数据**（严重） | 未验证 |
| U3 | 桌面 App 的 app-server 是否通过 fd 传递接入了 IPC 总线 | `lsof` 看不到第二方持有 `ipc.sock` 路径，但 fd 传递可以不显示路径 | 零副作用（可做 fd 追踪） | 未验证 |
| U4 | `codex queue --thread <id> --message` 对**运行中的桌面会话**是否真的生效 | 需要往用户会话写数据 | 改会话数据 | 未验证 |
| U5 | 运行中按 `Enter` 是否真的走 queue（而非 steer） | 同上 | 改会话数据 | 未验证 |
| U6 | 11 个动作的**实际按键效果**（键位存在 ≠ 按下去有预期效果） | 需要把手柄/键盘事件真的打给正在运行的用户 App | 改会话数据 / 改 UI 状态 | 未验证 |
| U7 | 打包后的 Swift App 是否拿到 Accessibility 授权 | 本次只证明了**当前终端**有 AX 权限；签名 App 的 TCC 授权是另一回事 | 改运行环境（需授权） | 未验证 |
| U8 | 快捷键自定义（`set-codex-command-keybinding`）的落盘位置 | 只看到 IPC handler 存在，存储介质没追到底 | 零副作用（读文件系统） | 未验证 |

补充（对桌面 App 无用但记录在案）：Codex TUI 的默认键位表**未能从二进制确定**（Rust `&str` 字面量首尾相连无 NUL 分隔，无法可靠切分）；未做 `/keymap` 交互抓屏。因为 v0.2 不用 TUI，**不列为待办**。（来源: research-codex-desktop.md 附录 A.4）

### 9.2 Claude 桌面 App

| # | 未验证项 | 为什么没验 | 验证的副作用 | 等级 |
|---|---|---|---|---|
| U9 | `claude://code/new`、`claude://code/continue`、`claude://code/needs-input` 三条**动作型深链**的真实行为 | 会真的新建/切换用户会话，属破坏性副作用 | 改 UI 状态（可能新建会话） | 未验证 |
| U10 | **Code 面板的 AX 元素标识**（各按钮/控件的 AX 属性） | 需要先打开一个 Code 会话 | 改 UI 状态 | 未验证（**这是 §21 Phase 3 的前置第一工作项**） |
| U11 | `queueFollowUp` 在桌面端的确切语义（可能是流式期间 `enter` 的隐式行为） | 未找到对应动作 | 改会话数据 | 未验证 |
| U12 | `esc` 在「运行中」vs「空闲」下的差异 | 需真实运行中的会话 | 改会话数据 | 未验证 |
| U13 | 「通过 DevTools 或 `--remote-debugging-port` 注入渲染进程再调 IPC」是否可行 | 需重启 App 加参数 | 改运行环境 | 未验证（**v0.2 明确不做**） |
| U14 | `~/.claude/keybindings.json` 是否影响桌面 App | 该文件当前不存在 | 零副作用（用 `CLAUDE_CONFIG_DIR` 指向临时目录对比 CLI 即可） | 未验证（桌面端大概率不受影响） |
| U15 | `ion-dist` Code 面板的实际加载 URL / 由哪个 BrowserWindow 承载 | 未能运行时抓取 | 零副作用（开 DevTools 或看 `main.log`） | 未验证 |
| U16 | `~/.claude/daemon/` 的 wire protocol 与 `control.key` 用法 | 超出「桌面 App」范围，且可能触发认证流程 | 改运行环境 / 可能触发认证 | 未验证（**与桌面 App 无关，不在本项目范围**） |
| U17 | `claude-desktop` 命令是否存在 | 未在该版本安装（i18n 里有文案但二进制没有） | 零副作用 | 未验证 |

### 9.3 硬件侧仍然开着的小口子（来自 Phase 0）

| # | 未验证项 | 验证的副作用 | 等级 |
|---|---|---|---|
| U18 | 泛用 C 变体的 6 输入映射、chord、长按重复、泄漏均**未测**（只做了最小验证） | 零副作用（纯探针） | 未验证 |
| U19 | T 档完全未采集 | 零副作用（纯探针） | 未验证 |
| U20 | H 模式第二变体未知（说明书未记载） | 零副作用（纯探针） | 未验证 |
| U21 | 斜向 D-pad（HatSwitch 2/4/6/8）在本设备上从未产生，但**不能据此认为永远不会** | 零副作用（纯探针） | 未验证 |
| U22 | 权限行为未在**正式打包 App** 里验证（Accessibility / Input Monitoring，尤其重签后授权失效） | 改运行环境 | 未验证 |
| U23 | 结论绑定当前系统版本（macOS 27.0 beta `26A428` + Xcode 27 beta）；`shouldMonitorBackgroundEvents` 默认值与 GC 对第三方 BLE 手柄的接纳策略属系统行为 | 大版本升级后重新验证 C1/C2 | 已知风险 |

来源: phase0-summary.md §7，实测验证（这些是「实测后仍未覆盖的空白」，非猜测）。

### 9.4 验证纪律

- 任何 U 项一旦验证，**必须把结论与命令写回文档**（Codex 侧写回 `docs/research-codex-desktop.md` 或本文档 §7/§9 的对应行；Claude 侧同理），并把证据等级升级。
- **U2 / U4 / U5 / U6 / U11 / U12 属于「改会话数据」**：验证前必须先获得用户明确同意，并且优先在**可牺牲的会话或账号**里做。
- 本文档 §7 矩阵里凡标【静态推断】的格子，都隐含一个 U 项（U6 / U11 / U12）。

---

## 10. 风险登记

| # | 风险 | 影响 | 证据等级 | 缓解措施 |
|---|---|---|---|---|
| **R1** | **Anthropic 自带蓝牙硬件伴侣**（`hardwareBuddyEnabled` / `buddy-ble`）可能干扰我们的蓝牙扫描 | 手柄扫描/连接不稳定、配对失败 | 实测验证（App 日志里有 `[buddy-ble] scan timeout — saw 0 stick(s), none matched` / `pair: result=false`；`--desktop-features` 含 `hardwareBuddyEnabled`；菜单有 `Developer > Open Hardware Buddy…`）（来源: research-claude-desktop.md §5.8） | ① 不依赖主动扫描发现手柄——优先用 GameController 的已配对设备列表与 `IOHIDManager` 的已连接设备枚举，而不是 `--discover` 式扫描；② 文档化提示用户关掉 Hardware Buddy；③ 若出现连接抖动，先排查 Buddy |
| **R2** | `claude://` 深链可被托管配置 `disableDeepLinkRegistration` **整体关闭** | Claude 侧唯一实测可用的程序化投递通道**整体失效**（企业策略置位时） | 静态推断（`if (U().authentication.disableDeepLinks) { ... "claudeURLHandler: dropping deep link (disableDeepLinkRegistration)" }`）（来源: research-claude-desktop.md §3.4） | ① **实现时必须探测这个开关**（App 启动时与每次投递失败时）；② 探测到关闭 → 把 delivery tier 直接降到「菜单点击 / 按键注入」，并提示用户；③ **不要把任何语义动作的可用性押在深链上**（本版本来也只有 0 个动作依赖它） |
| **R3** | **Codex IPC 总线能力未验证**（`~/.codex/ipc/ipc.sock`） | 若被当作控制面，会在真机上表现为「能连上、发请求永远 `no-client-found`」，或更糟：验证变更类方法时污染用户会话 | 实测验证（可连接、可 `initialize`、`thread-owner-discovery` → `no-client-found`）+ 未验证（`thread-follower-*` 是否有人应答） | **v0.2 不押注**：不实现、不调用、不做 fallback。仅作为 v0.3 的探索方向（用 fd 追踪确认 app-server 是否在总线上）。任何实现代码中**禁止出现 `ipc.sock` 的写操作** |
| **R4** | **同 App 内 surface 歧义**（chat / cowork / code 三种面板语义不同） | 同一个键（如 Claude 的 `⌘K` / `⌘⇧D` / `⌘⇧M`、Codex 的 `⌘K`）在不同面板含义不同 → **误触** | 静态推断（Claude `extended_thinking` = `⌘⇧E` 与 `openEffortMenu` = `⌘⇧E` 冲突；Codex 焦点在内置浏览器/终端面板时同一键含义完全不同）（来源: research-claude-desktop.md §4.4、§7.3；research-codex-desktop.md §7 风险 1） | 见 §11.3：v0.2 做**最小 surface 判定**（菜单 `enabled` 状态 + 窗口标题），不做完整 AX 特征识别；所有 macro 动作额外要求显式确认 |
| **R5** | 无菜单项的命令由**渲染进程**处理，**窗口失焦即失效**；原生菜单快捷键在 App 失焦时同样不触发 | 「后台遥控」不可能；事件可能打到错误的 App | 实测验证（来源: research-codex-desktop.md §7 风险 3） | ① Pass 1 守卫强制要求 frontmost app ∈ allowlist（§11.1）；② 每次投递前重新读 frontmost，不用缓存值；③ 失焦时不投递，只更新 menu bar 状态 |
| **R6** | **Accessibility 授权**：打包签名后的真实 App 需要自己的 TCC 授权；**重签后授权会失效** | 菜单枚举/点击、CGEvent 注入全部静默失败 | 实测验证（探针以无 bundle 方式跑；`docs/hardware-probe.md` §1.4 明确记录 ad-hoc 签名每次重建都要重新授权） | ① 启动时 `AXIsProcessTrustedWithOptions`，未授权时 menu bar 显式显示 `Accessibility Required` + 入口；② 不静默失败；③ 每次 CGEvent 投递失败要有可见计数（debug monitor） |
| **R7** | 快捷键可被用户改写（Codex 的 `set-codex-command-keybinding`、Claude 的 App 内设置） | 硬编码的键位在用户改过之后失效 | 实测验证（handler 存在，来源: research-codex-desktop.md §4.1）+ 未验证（落盘位置 U8） | 键位表放在配置文件中，不 hardcode 在 Swift source 里；提供「键位自检」流程（§21 Phase 3） |
| **R8** | Codex `⌥Space`（`openAvatarOverlay`）是 `os-global` 全局热键 | 与系统快捷键冲突，也可能被我们的 chord 误触 | 实测验证（来源: research-codex-desktop.md §7 风险 2） | 配置手柄时检测冲突并在文档列出；不把 `⌥Space` 用于任何语义动作 |
| **R9** | **H 模式严重泄漏**：6 个键全部作为普通按键进入前台 App（A = `Enter`、B = `Space`），且随 OS key repeat 重复 | 用户在 H 档时，按手柄 = 往当前 App 打字（实测在 TextEdit 里插入了 19 个空格） | 实测验证（来源: phase0-summary.md §2 Q9 / hardware-probe.md §5.4） | ① H 档不做输入源；② 设备匹配按 product+usage，绝不能按 usage class 打开监听（否则会连用户内置键盘一起听，`hardware-probe.md` §5.5 实测 921/1057 条来自内置键盘）；③ 检测到 H 档立即在 menu bar 提示切回 C 档 |
| **R10** | **日志隐私**：`--with-keyboard` 模式日志包含用户真实键盘输入 | 泄漏用户输入 | 实测验证（`docs/hardware-probe.md` §1.4 / §5.5） | ① 正式 App **不做**键盘级日志；② `logs/*.jsonl` 已在 `.gitignore`，**不要外发**；③ 调试模式默认关闭，打开时 UI 显式警告 |
| **R11** | 系统行为随 macOS 大版本变化（`shouldMonitorBackgroundEvents` 默认值、GC 对第三方 BLE 手柄的接纳策略） | 现有实测结论失效 | 实测验证（结论绑定 macOS 27.0 beta `26A428`）（来源: phase0-summary.md §7） | 启动时记录 OS 版本；大版本升级后**重新验证 C1 / C2**；把这两条做成启动自检项 |
| **R12** | U 项验证本身有副作用（改会话数据 / 改 UI 状态） | 污染用户真实会话、打断正在跑的任务 | 见 §9 | 所有「改会话数据」级验证必须先取得用户同意，优先在可牺牲环境做 |

---

## 11. 目标应用守卫与 surface 感知

（重写 v0.1 §12。v0.1 的 allowlist 是终端类 App；v0.2 换成两个桌面 App，并新增 surface 维度。）

### 11.1 Pass 1 —— 进程级守卫（硬性）

只判断 **frontmost macOS app 是否在 allowlist**。默认：

```json
{
  "allowedBundleIds": [
    "com.openai.codex",
    "com.anthropic.claudefordesktop"
  ]
}
```

- `com.openai.codex` = `/Applications/ChatGPT.app`（实测 `CFBundleIdentifier`，来源: research-codex-desktop.md §1，实测验证）
- `com.anthropic.claudefordesktop` = `/Applications/Claude.app`（来源: research-claude-desktop.md 头部，实测验证）

规则（沿用 v0.1 §12 的分级，按 delivery tier 重新表述）：

| 动作类别 | 要求 |
|---|---|
| **Generic navigation**（方向键） | frontmost ∈ allowlist **或** `GenericAdapter` 激活；永不进入 macro 路径 |
| **Tool-specific action**（由某个 App adapter 产生） | frontmost ∈ allowlist **且** frontmost 的 bundle id 与该 adapter 匹配 |
| **Menu action**（AX 菜单点击） | 同 tool-specific，**且** 目标菜单项 `enabled == true`（先读再点） |
| **Macro action**（文本注入，如 G3 的命令面板路径） | 额外要求 `macrosEnabled == true` **且** 用户对该动作显式启用 |

**不要**判断「App 里当前跑的是哪个会话」（v0.1 就否掉了 subprocess 猜测；桌面 App 上同样不做）。

### 11.2 Pass 2 —— 菜单可用性守卫（仅 Claude 侧有意义）

Claude 的 AX 菜单树里，Code 专属项是**上下文相关**的：没有打开 Code 会话时 `View > Show Terminal` / `Show Changes` / `Show Browser` / `Show Files` / `Show Side Chat` / `Close Pane` 都是 `enabled=false`，`View > Command Palette…` / `Go > Code` 是 `enabled=true`。（来源: research-claude-desktop.md §4.1，实测验证）

实现要求：

```applescript
tell application "System Events" to tell process "Claude"
  if enabled of menu item "Show Changes" of menu 1 of menu bar item "View" of menu bar 1 then
    click menu item "Show Changes" of menu 1 of menu bar item "View" of menu bar 1
  end if
end tell
```

- **先说断言再动作**：`enabled == false` ⇒ 视为该动作暂不可用，浮层提示，**不注入按键兜底**。
- Codex 侧菜单没有业务动作（来源: research-codex-desktop.md §4.7，实测验证），因此 Pass 2 对 Codex 不适用。

### 11.3 Pass 3 —— surface 感知（本版做最小版）

**问题**：同一个 App 里有 **chat / cowork / code** 三个面板，语义不同。

- Claude 侧：`⌘⇧D` 在 Code 面是 Toggle changes；`⌘K` 在 chat 与 code 面语义不同；`openModeMenu`（`⌘⇧M`）只在会话面板有意义。（来源: research-claude-desktop.md §7.3 硬约束 1，静态推断）
- Codex 侧：快捷键要求 App 在前台，且「焦点在内置浏览器标签页或终端面板时，同一个键的含义完全不同」。（来源: research-codex-desktop.md §7 风险 1，静态推断）

**v0.2 的最小实现（不做完整 AX 特征识别）**：

1. **可用信号**（都是零副作用读取）：
   - Claude：`Go > Code` 菜单项的 `enabled` 状态；menu bar 是否有 Code 专属项被 enable；窗口标题。
   - Codex：`⌃1..⌃3`（`switchToMode1..3` = Chat / Work / Codex）的存在本身说明有三个 mode（来源: research-codex-desktop.md §5.2，实测验证）；窗口标题。
2. **判定策略**：只区分 `chatLike` / `codeLike` / `unknown` 三态。
3. **动作分级**：
   - `codeLike` 明确 → 允许投递 Code 专属动作（`inspectChanges`、`toggleFastMode` 等）。
   - `chatLike` 明确 → 只允许 base layer（方向键 / `submit` / `cancelOrInterrupt`），Code 专属动作降级为提示。
   - `unknown` → 只允许 base layer，**禁止 macro**。
4. **v0.2 明确不做**：完整 AX 特征识别、按会话 id 跟踪、跨面板状态机。这些留给 v0.3（依赖 §9 U10）。

### 11.4 profile 的退化用法

v0.1 要求用户在 menu bar 显式选择 profile（Generic Terminal / Codex / Claude Code）。v0.2 改为：

```text
Target:  [ Auto-detect (recommended)  ▾ ]
         ○ Auto-detect
         ○ Force Codex Desktop
         ○ Force Claude Desktop
         ○ Generic (base keys only)
```

- **Auto-detect**：由 frontmost bundle id 决定 adapter（§11.1）；surface 由 §11.3 判定。
- **Force \***：用于自动探测失败或调试；仍然要过 Pass 1 守卫（不允许把 Codex 的键打到 Claude 里）。
- **Generic**：只发方向键 / `Return` / `Escape`，不启动任何 adapter，不进入 macro。

---

## 12. 分层架构

```text
App/
├── AppDelegate
├── MenuBar/
│   ├── StatusMenu              # 连接状态 / 变体 / surface / 权限
│   ├── TargetAppPicker         # §11.4
│   └── ActionOverlay           # 不可用动作的提示浮层（G1–G4）
│
├── Input/
│   ├── ControllerInputSource.swift   # 归一化抽象（两条路径的共同出口）
│   ├── GameControllerSource.swift    # XInput 变体；含 C1 背景事件开关、C4 单次绑定、C5 通知驱动
│   ├── HIDControllerSource.swift     # 泛用变体；含 C3 product+usage 匹配、C6 死区、C7 移除清状态
│   ├── DeviceMatcher.swift           # 按 product + usage + VID/PID 辅助；拒绝 location 与裸 VID/PID
│   ├── DeviceMode.swift              # C/XInput · C/generic · H · T · unknown
│   └── HardwareProbe.swift           # Phase 0 探针（保留，用于回归）
│
├── Gesture/
│   ├── PhysicalButton.swift
│   ├── ButtonState.swift
│   ├── Gesture.swift
│   └── GestureRecognizer.swift
│
├── Actions/
│   ├── AgentAction.swift
│   ├── ActionResolver.swift
│   └── CapabilityMatrix.swift        # §7 矩阵的代码化：每个 (action, app) → tier + 证据等级
│
├── Adapters/
│   ├── DesktopAppAdapter.swift       # protocol
│   ├── CodexDesktopAdapter.swift
│   ├── ClaudeDesktopAdapter.swift
│   └── GenericAdapter.swift
│
├── Delivery/                          # v0.1 的 Output/ 拆分并升级
│   ├── DeliveryTier.swift            # programmatic / menu / keystroke / unavailable
│   ├── ProgrammaticDelivery.swift    # deep link / (禁用) ipc.sock
│   ├── MenuDelivery.swift            # AXUIElement + System Events
│   ├── KeyInjectionDelivery.swift    # CGEvent（含 modifier cleanup，v0.1 §11.1/11.2）
│   └── InputOutputEngine.swift       # actor，串行化所有 recipe（v0.1 §11.3）
│
├── Guard/
│   ├── AccessibilityPermission.swift
│   ├── TargetAppGuard.swift          # §11.1 Pass 1
│   ├── MenuAvailabilityGuard.swift   # §11.2 Pass 2
│   └── SurfaceDetector.swift         # §11.3 Pass 3
│
├── Config/
│   ├── AppConfig.swift
│   ├── ConfigStore.swift
│   └── KeybindingTable.swift         # 两个 App 的默认键位（不 hardcode 在 logic 里）
│
└── Debug/
    ├── InputMonitorView.swift
    └── EventLogger.swift             # 默认关闭；不含键盘级日志（R10）
```

### 12.1 关于 `ProgrammaticDelivery` 的实现边界

- **允许**：`open -g <deep-link>`（Claude 的 4 条动作型路由 + `codex://launch` 一类的无害路由）。
- **禁止**：`~/.codex/ipc/ipc.sock` 的任何请求（R3）；`--remote-debugging-port` 注入（U13，v0.2 明确不做）。
- **可选**：`codex queue`（G1 无关，属 `queueFollowUp` 备选）。默认**关闭**，因为「运行中 App 是否采纳」未验证（U4）；开启时必须提示用户这是实验性路径。

---

## 13. 安全模型

（保留 v0.1 §17 的全部 MUST，按桌面 App 重新表述，并补 4 条新约束。）

### MUST

- 默认 `macrosEnabled = false`
- 任何文本注入（命令面板输入、slash command）都属于 macro
- tool-specific 动作只能在**明确的目标 App 上下文**下运行（§11.1）
- frontmost app 必须通过 allowlist
- **菜单点击前必须读 `enabled`**（Claude Code 面板项天然 disabled，§11.2）
- **不允许盲发数字键选择菜单项**（G2：菜单项顺序未验证，可能选到高风险权限档）
- 不提供一键 bypass permissions
- 不提供一键执行 arbitrary shell command
- 不映射 `approve forever` / `approve for prefix` 到单击（桌面 App 上本来也只有 `approval.approve` 单次批准）
- 任何 modifier 注入后必须保证 release（v0.1 §11.2 的 `keyDown mod → keyDown key → keyUp key → keyUp mod` + cleanup）
- app quit / sleep / disconnect 时清空 internal button state（**两条输入路径都要**，C7）
- **不把 deep link 当作任何语义动作的依赖**（R2）
- **不写 `~/.codex/ipc/ipc.sock`**（R3）
- **H 档不做输入源**（R9）

### Permission prompts（沿用 v0.1 的策略，桌面 App 上依然成立）

```text
A = Enter / selected confirmation
B = Escape / decline / cancel
```

- Codex 侧：`approval.approve`（`Enter`）与 `approval.decline`（`Esc`）**只在审批卡上下文生效**（来源: research-codex-desktop.md §5.2，实测验证）——把 A/B 交给 App 自己的 UI 决定最终语义，正是 v0.1 这条策略的价值。
- 不要绕过确认层。**特别是 G1 的降级方案 D1-b 被否决的理由就在这里**：把 `B + ↑` 变成 `Enter` 会让它落到审批卡上时变成「批准」。

---

## 14. 核心接口

（v0.1 §10 的调整版。保留语义动作层与 recipe 概念，新增 delivery tier 与 capability 类型。）

### 14.1 Physical input（不变）

```swift
enum PhysicalButton: String, Codable {
    case up, down, left, right, a, b
}

enum InputEvent {
    case pressed(PhysicalButton, timestamp: TimeInterval)
    case released(PhysicalButton, timestamp: TimeInterval)
}
```

### 14.2 Device 与变体（新增）

```swift
enum DeviceVariant: String, Codable {
    case cXInput        // Xbox Wireless Controller, 0x045e/0x0b13, usage 1/5, GC 可见
    case cGeneric       // Wireless Controller, 0x4353/0x9b09, usage 1/5, HID-only
    case hKeyboard      // IINE_keyboard, 0x4353/0x9b09, usage 1/6, 泄漏，不支持
    case tMultimedia    // IINE-Control / IINE-Phone, 不支持
    case unknown
}

struct DeviceIdentity: Equatable {
    let product: String       // 匹配主键之一
    let primaryUsage: (page: UInt32, usage: UInt32)  // 匹配主键之一
    let vendorId: Int?        // 辅助，不单独使用
    let productId: Int?       // 辅助，不单独使用
    // 注意：绝不包含 `location`（C3）
}
```

### 14.3 Gestures（不变）

```swift
enum ControllerGesture: Equatable {
    case tap(PhysicalButton)
    case hold(PhysicalButton)
    case chord(modifier: PhysicalButton, key: PhysicalButton)
}
```

不做 double-tap（v0.1 理由保留：会增加单击判定延迟）。

### 14.4 Semantic actions（保持 v0.1 的 11 个）

```swift
enum AgentAction: String, Codable, CaseIterable {
    case navigateUp, navigateDown, navigateLeft, navigateRight   // 4
    case submit, cancelOrInterrupt                               // 2
    case queueFollowUp, cyclePermissionMode, toggleFastMode      // 3
    case openModelPicker, inspectChanges                         // 2
}   // 合计 11
```

**不扩到这 11 个之外**。桌面 App 有额外现成动作（`newTask` / `toggleSidebar` / `openCommandMenu` 等），但它们属 v0.3 的「补充动作」议题，避免本版范围膨胀。

### 14.5 Delivery tier 与 risk（新增/调整）

```swift
enum DeliveryTier: String, Codable {
    case programmatic   // deep link / CLI / IPC（当前仅 Claude 4 条深链；不覆盖任何 AgentAction）
    case menuClick      // AXUIElement / System Events
    case keyInjection   // CGEvent
    case unavailable    // 明确做不到（G1 等），必须给出用户可见提示
}

enum ActionRisk: String, Codable {
    case navigation     // 语义随焦点变化（§6.1 的 4 个 navigate*）
    case normal
    case macro          // 文本注入，必须 macrosEnabled
    case sensitive      // 触碰权限/审批语义（如 G1 的 D1-b，默认禁用）
}
```

### 14.6 Adapter

```swift
protocol DesktopAppAdapter {
    var targetBundleId: String { get }     // com.openai.codex / com.anthropic.claudefordesktop

    /// 返回该语义动作在本 App 上的投递方案；返回 nil 表示不可用（调用方必须提示，不得静默）
    func delivery(for action: AgentAction, surface: Surface, context: ActionContext) -> DeliveryPlan?
}

struct DeliveryPlan {
    let tier: DeliveryTier
    let steps: [OutputStep]
    let risk: ActionRisk
    let requiresExplicitProfile: Bool      // 通常 false（自动探测），保留给 Force 模式
    let evidence: EvidenceLevel            // 见 14.7：用于 debug monitor 与「本动作未经验证」提示
}
```

**关键约束**：`delivery(for:)` 返回 `nil` **必须**导致用户可见提示（menu bar 浮层 / debug monitor 红字），**不允许静默无输出**。这是 G1–G4 的实现载体。

### 14.7 证据等级进代码（新增，防止把未验证当已验证用）

```swift
enum EvidenceLevel: String, Codable {
    case measured      // 实测验证
    case staticInfer   // 静态推断
    case unverified    // 未验证
}
```

`CapabilityMatrix.swift` 里每一格都带 `EvidenceLevel`，debug monitor 显示它；`unverified` 的动作首次使用时弹一次提示。

### 14.8 Output step（沿用 v0.1 §10.5）

```swift
enum OutputStep: Equatable {
    case keyDown(KeyCode, modifiers: ModifierFlags)
    case keyUp(KeyCode, modifiers: ModifierFlags)
    case keyPress(KeyCode, modifiers: ModifierFlags)
    case text(String)              // macro；必须 macrosEnabled
    case delay(milliseconds: Int)
    case menuClick(app: String, path: [String])   // 新增：AX 菜单路径
    case openURL(String)                          // 新增：deep link（零副作用路由白名单见 §12.1）
}
```

### 14.9 ActionContext

```swift
struct ActionContext {
    let frontmostBundleId: String?
    let surface: Surface            // .chatLike / .codeLike / .unknown
    let variant: DeviceVariant
    let macrosEnabled: Bool
    let menuEnabled: [String: Bool] // Pass 2 的结果缓存（每次投递前刷新）
}
```

---

## 15. 输入输出实现要点

### 15.1 输入（两条路径的共同要求）

- 归一化到 `ControllerInputSource`，Gesture Engine 完全不知道事件来自 GC 还是 HID。
- **C1**：`GCController.shouldMonitorBackgroundEvents = true`，并在启动自检里读回校验。
- **C5**：只用 `GCControllerDidConnect` / `GCControllerDidDisconnect`，不做启动轮询。
- **C4**：每个 element 只绑一次；`extendedGamepad` 与 `microGamepad` 是同一对象时跳过 micro。
- **C3**：`DeviceMatcher` 用 product + usage；裸 VID/PID 只作辅助；`location` 永不用。
- **C6**：所有轴用死区（含连接时的中心值上报）。
- **C7**：`HID-REMOVE` 与 `GC-DISCONNECT` 都清空 held set。
- 变体变化（`HID-REMOVE` → 新 `HID-MATCH`）当作普通断开/连接对，重新解析设备身份，不假设稳定身份。

### 15.2 输出（沿用 v0.1 §11 的三条纪律）

- **Key injection**：`CGEventCreateKeyboardEvent` + `CGEventPost`；首次启动 `AXIsProcessTrustedWithOptions`；未授权时 menu bar 显式显示且不静默失败。
- **Modifier handling**：`keyDown mod → keyDown key → keyUp key → keyUp mod`，macro 中途失败也要 cleanup 释放 modifier（否则 Shift/Option/Ctrl stuck）。
- **Serialization**：所有 recipe 在一个 `actor InputOutputEngine` 中串行执行，禁止两个 chord 的 CGEvent 序列交叉。
- **Menu click**（新增）：先用 AX 读 `enabled`，再 click；失败时**不自动 fallback 到按键注入**（避免"以为点了菜单，其实盲注了键"）。
- **Deep link**（新增）：只允许白名单路由；投递前探测 `disableDeepLinkRegistration`（R2）。

---

## 16. 配置模型

```json
{
  "version": 2,
  "target": {
    "mode": "autoDetect",
    "allowedBundleIds": [
      "com.openai.codex",
      "com.anthropic.claudefordesktop"
    ]
  },

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

  "capabilities": {
    "codex": {
      "cyclePermissionMode": { "tier": "unavailable", "reason": "G1", "evidence": "measured" },
      "toggleFastMode":      { "tier": "unavailable", "reason": "G3", "evidence": "measured" },
      "queueFollowUp":       { "tier": "keyInjection", "evidence": "unverified" }
    },
    "claude": {
      "queueFollowUp":       { "tier": "unavailable", "reason": "G4", "evidence": "staticInfer" },
      "cyclePermissionMode": { "tier": "keyInjection", "strategy": "openMenuThenUserSelects", "evidence": "staticInfer" },
      "submit":              { "tier": "keyInjection", "evidence": "unverified" }
    }
  },

  "security": {
    "macrosEnabled": false,
    "requireAllowedFrontmostApp": true,
    "allowCodexQueueCli": false,
    "allowExperimentalUnverifiedActions": false
  },

  "keybindings": {
    "codex":  { "openModelPicker": "ctrl+shift+m", "inspectChanges": "ctrl+shift+g" },
    "claude": { "toggleFastMode": "cmd+alt+f", "openModelPicker": "cmd+shift+i", "inspectChanges": "cmd+shift+d" }
  }
}
```

存放位置（沿用 v0.1 §13）：

```text
~/Library/Application Support/<AppName>/config.json
```

**不要存 secret。**

设计要点：

- `capabilities` 段把 §7 矩阵**落到配置**，而不是散在 Swift 里；用户可以在不重新编译的情况下把某个动作从 `unavailable` 改成实验性启用。
- `keybindings` 段允许用户改键位后不用改代码（R7）。键位变更后 App 需走一次自检。
- `allowExperimentalUnverifiedActions` 默认 false：打开后 `evidence == unverified` 的动作才允许投递，并在 UI 上标注。

---

## 17. Menu bar UX

至少显示：

```text
● L1162 Connected  [C/XInput]
Target: Codex Desktop  (surface: code)
```

或：

```text
○ L1162 Disconnected
```

菜单：

```text
Device
  L1162 Connected
  Variant: C / XInput        ← 变体是用户看不见的设备状态，必须显示（§4.4）
  (H mode detected — switch to C)   ← 条件显示

Target
  Auto-detect
  Force Codex Desktop
  Force Claude Desktop
  Generic (base keys only)
  Detected surface: code / chat / unknown

Capabilities                ← 直接读 §16 的 capabilities
  cyclePermissionMode: unavailable (Codex: G1)
  …

Debug
  Open Input Monitor
  Show Last Action (with evidence level)

Permissions
  Accessibility: Granted / Required
  Input Monitoring: Granted / Required

Settings
  Launch at Login
  Macros (default OFF)
  Allowed Apps
  Experimental / unverified actions (default OFF)

Quit
```

### Debug monitor（保留 v0.1 的强制要求，增加 tier / surface / evidence / variant）

```text
RAW:       B down
RAW:       Right down
GESTURE:   chord(B, Right)
ACTION:    queueFollowUp
VARIANT:   C/XInput
TARGET:    com.openai.codex   SURFACE: code
TIER:      keyInjection
EVIDENCE:  unverified          ← 提示这条链路还没做端到端验证
OUTPUT:    keyPress(Return)
RESULT:    delivered
```

debug monitor 在 v0.2 里比 v0.1 更重要：因为矩阵里大量格子是【静态推断】/【未验证】，这个面板就是**把证据等级实时暴露给用户**的唯一渠道。

---

## 18. 手势状态机

（保留 v0.1 §18 的设计，无改动；补充 disconnect 的行为对齐 C7。）

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
- held dpad 不重复触发破坏性/语义动作
- base navigation 支持 key repeat
- secondary layer 默认不 repeat
- **disconnect / HID-REMOVE / variant change 时强制 reset**（C7；v0.1 只写了 disconnect，v0.2 扩到两条路径 + 变体切换）
- **动作返回 `unavailable` 时不得改变状态机行为**：仍然完成一次 tap/chord 语义，只是输出为「提示」而不是按键

---

## 19. 按键重复策略

### Allow repeat

```text
navigateUp / navigateDown / navigateLeft / navigateRight
```

### No repeat

```text
submit
cancelOrInterrupt
queueFollowUp
cyclePermissionMode
toggleFastMode
openModelPicker
inspectChanges
```

（与 v0.1 §19 完全一致。注意：`navigate*` 在桌面 App 上的语义随焦点变化，repeat 会让「翻列表」变成「连续滚动」，这也是 §6.1 标 `ActionRisk.navigation` 的原因之一。）

---

## 20. 测试策略

### 20.1 Unit tests（手势层，脱离硬件与 App）

沿用 v0.1 §20.1 并改名：

```text
B tap                → cancelOrInterrupt
B + Up               → cyclePermissionMode
B + Down             → toggleFastMode
B + Left             → openModelPicker
B + Right            → queueFollowUp
B + A                → inspectChanges
B chord 不发出 Escape
reconnect 重置状态
held chord 只触发一次
```

测试替身：Phase 0 已确定 C/XInput 的 `Dpad.*` / `A` / `B` 回调语义，可直接作为 fixture（来源: phase0-summary.md §8.3，实测验证）。

新增（v0.2 特有）：

```text
unavailable 动作 → 产出「提示」而非按键，且不抛异常
macrosEnabled=false → 任何 macro recipe 被拒
frontmost 不在 allowlist → 所有 tool-specific 动作被拒
菜单项 enabled=false → 拒绝点击且不 fallback 到按键注入
surface=unknown → Code 专属动作被降级
evidence=unverified 且 allowExperimentalUnverifiedActions=false → 动作被拒
变体切换（HID-REMOVE → 新 MATCH）→ held set 清空
轴在连接时的中心值上报 → 不产生 phantom chord
```

### 20.2 Adapter 矩阵测试

对 §7 的每一格写一个断言，确保代码里的 `CapabilityMatrix` 与文档一致：

```text
codex.cyclePermissionMode == .unavailable      (G1)
codex.toggleFastMode      == .unavailable      (G3, 可配置打开)
claude.queueFollowUp      == .unavailable      (G4)
claude.cyclePermissionMode == .keyInjection 且 strategy == openMenuThenUserSelects  (G2)
4 个 navigate* 的 risk == .navigation
```

这组测试的作用：**文档改了但代码没改**（或反过来）会立刻失败。

### 20.3 Integration tests

目标环境（按优先级）：

```text
1. Codex 桌面 App（com.openai.codex）
2. Claude 桌面 App（com.anthropic.claudefordesktop）
3. GenericAdapter + TextEdit（只验证 base layer，不碰任何 App）
```

每个 App 至少覆盖：

```text
- Accessibility 授权流程（含未授权时的提示路径）
- frontmost 守卫：切到 Finder / TextEdit 时无输出
- base layer：方向键 / Enter / Esc 的可见效果
- 至少一个 keyInjection tier 的 agent action
- 至少一个 menuClick tier 的 agent action（Claude 的 inspectChanges）
- 至少一个 unavailable 动作的提示路径（Codex 的 B+Up）
```

⚠️ **进行 §20.3 的第 1、2 项测试有副作用**（会在真实 App 里按键，可能提交内容、打断 turn）。测试前必须：① 用户在可牺牲的会话里；② 明确告知用户；③ 优先在 TextEdit 里先跑通的 recipe 再对 App 跑。

### 20.4 Manual acceptance flows

#### Flow A — base navigation

```text
打开 Codex / Claude
打开一个列表（会话列表 / 命令面板）
D-pad 移动选择
A 选择
B 关闭
```
预期：与 v0.1 相同；额外要求 debug monitor 显示 `SURFACE` 与 `TIER=keyInjection`。

#### Flow B — permission prompt

```text
审批卡出现
D-pad 选择
A 确认（Codex: approval.approve）
B 拒绝（Codex: approval.decline）
```
预期：不出现「一键 approve for session」。

#### Flow C — permission mode（v0.2 重点变化）

```text
Codex 下按住 B + ↑
→ 期望：无按键注入 + 浮层提示「Codex 桌面版不支持」（G1/D1-a）
→ 若走 D1-b（已否决）：必须能看到 approval 被触发 —— 这正是要避免的

Claude 下按住 B + ↑
→ 期望：⌘⇧M 打开 mode menu + 提示用户用方向键选择
→ 期望：绝不出现「按一次就切了一档」的伪循环（G2）
```

#### Flow D — queue

```text
Agent 正在工作
输入 follow-up 文本
B + → （Claude）
→ 期望：明确提示「Claude 桌面版无 queue 接口」，不注入任何可能误触的键（G4）

B + → （Codex）
→ 默认关闭；若用户开启实验路径，注入 Enter 并标注 evidence=unverified（U5）
```

#### Flow E — reconnect / 变体

```text
关闭手柄 → 打开 → 自动重连，无需重启 App（C/XInput 与泛用变体都已实测，来源: phase0-summary.md §3 Q10）
配对键 + A 按住 2 秒切变体
→ 期望：App 检测到 HID-REMOVE → 新 MATCH，重新解析变体，menu bar 变体标签更新
→ 期望：XInput → 泛用 时 GameController 消失但 HID 路径接管，手柄仍然可用（§4.4 的核心验收）
```

#### Flow F — H 档误入

```text
把平台开关拨到 H
→ 期望：menu bar 显示「H mode detected — switch to C」，输入源停止消费该设备，不产生任何按键
```

### 20.5 MVP 验收标准（v0.2 版）

**硬件**

- [ ] C/XInput 与 C/generic 两个变体都被识别，6 个输入可用
- [ ] hold 配对键 + A 切变体后，App 自动恢复可用（无需重启）
- [ ] H 档与 T 档被识别并提示，不消费输入
- [ ] 热重连（关机重开）无需重启 App

**Base controls**

- [ ] D-pad / A / B 在目标 App frontmost 时可注入
- [ ] 目标 App 非 frontmost 时零输出
- [ ] key repeat 策略正确

**Agent layer**

- [ ] Codex：`openModelPicker` / `inspectChanges` 可用
- [ ] Codex：`cyclePermissionMode` 给出明确不可用提示（G1）
- [ ] Claude：`toggleFastMode` / `openModelPicker` / `inspectChanges` 可用
- [ ] Claude：`cyclePermissionMode` 走「打开菜单 + 用户选择」两段式
- [ ] Claude：`queueFollowUp` 给出明确不可用提示（G4）

**macOS**

- [ ] Accessibility 引导（未授权不静默失败）
- [ ] 目标应用守卫（Pass 1 + Pass 2）
- [ ] surface 最小判定（§11.3）
- [ ] menu bar 显示变体 / surface / 权限
- [ ] debug monitor 显示 tier + evidence

**Safety**

- [ ] macros 默认关闭
- [ ] 无 stuck modifiers
- [ ] 无「一键 bypass permissions」
- [ ] 无任意 shell 执行
- [ ] 不写 `~/.codex/ipc/ipc.sock`
- [ ] H 档不产生按键

---

## 21. 实施阶段

### Phase 0 — Hardware Probe ✅ 已完成（2026-09-15）

产出：`docs/hardware-probe.md`（原始实测）+ `docs/phase0-summary.md`（结论汇总）。**7 条硬性约束已进 §3。**

### Phase 1 — Controller Core（按 §3 的 7 条约束写）

实现：

- `ControllerInputSource` 骨架，把 C1–C7 **直接固化进去**，不等踩坑后补
- `GameControllerSource`（XInput）+ `HIDControllerSource`（泛用变体），两条都是一级
- `DeviceMatcher`（product + usage，禁用 location）
- 变体检测与 menu bar 展示
- reconnect / 变体切换 / 移除清状态
- 手势识别器 + 状态机（§18）

**Phase 1 起步建议**（沿用 phase0-summary §8.4）：始终锁定 XInput 变体开发，泛用变体留到 HID 输入源落地后再回归。

### Phase 2 — Menu Bar App + Guard

实现：

- 连接状态 / 变体 / surface 显示
- `TargetAppGuard`（Pass 1）+ `AccessibilityPermission`
- `KeyInjectionDelivery`（含 modifier cleanup + serialization）
- debug monitor（含 tier / evidence / variant）
- 配置持久化（§16）

### Phase 3 — Desktop Adapters（**前置：§9 U10 必须完成**）

**第一工作项不是写 adapter，而是补测**（因为 §7.2 的 Claude 键位是【静态推断】）：

1. **U10**：打开一个 Code 会话，遍历 AX 树，记录 Code 面板的按钮/AX 标识。
2. **U15**（零副作用，可与 U10 并行）：确认 `ion-dist` 由哪个窗口加载。
3. 补测后把结果写回 §7.2，升级证据等级。

然后实现：

- `CodexDesktopAdapter`（§7.1 的 10 个 keyInjection tier + 1 个 unavailable）
- `ClaudeDesktopAdapter`（§7.2 的 9 个 keyInjection + 2 个 menuClick + 2 个缺口降级）
- `MenuDelivery`（AX 读 `enabled` → click）
- `CapabilityMatrix` 代码化 + §20.2 的矩阵测试
- `ActionOverlay`（不可用动作的用户提示，G1–G4 的载体）

### Phase 4 — 能力补测与降级收口

- 完成 §9 中**零副作用**级别的 U 项：U3（fd 追踪）、U7（打包 App 的 TCC）、U8、U14、U15、U18–U21
- 与用户协商后完成**改 UI 状态**级别的 U 项：U1、U9、U16（可选）
- **改会话数据**级别的 U 项（U2 / U4 / U5 / U6 / U11 / U12）**默认不做**，除非用户明确同意并提供可牺牲会话
- 收口 G1–G4 的最终形态，更新 §7 矩阵的证据等级

### Phase 5 — v0.3 候选（本版不做）

- 完整 surface 感知（依赖 U10 的 AX 特征）
- 真正的 `cyclePermissionMode`（Claude：读当前模式 → 计算下一档）
- Claude 深链补充动作（`claude://code/needs-input` → `openSessionNeedingInput`）
- Codex `codex queue` 实验路径（依赖 U4）
- 用户自定义层编辑器、Shortcuts.app actions、media mode

---

## 22. 不得在没有证据的情况下更改的决策

（v0.1 §23 的修订版。**加粗**为 v0.2 改写或新增的条目。）

1. **C / 手柄模式是首要硬件路径；H 模式只识别不消费；T 档只识别并跳过。**（来源: phase0-summary.md，实测验证）
2. H / keyboard 模式不得作为输入源（泄漏严重，实测）。
3. **GameController 仅在 XInput 变体下优先；对泛用 C 变体，IOHIDManager 是唯一路径。两者都是一级输入源。**（改写 v0.1 决策 3、4）
4. **C 档两个变体都必须支持**（用户明确要求）；不做变体的 App 内切换，只做检测与提示。
5. **设备匹配必须用 product + usage，不得单独用 VID/PID，不得使用 location。**
6. **配对键永远不映射。**
7. 物理按钮 → 语义动作 → adapter；不做直接全局硬编码。
8. Base layer 保持通用且可预测；4 个 `navigate*` 必须标 `ActionRisk.navigation`。
9. **投递优先级固定为：程序化接口 > 原生菜单点击 > 按键注入 > 明确不可用。** 不允许跨层静默 fallback（尤其：菜单点击失败不得自动改成盲注按键）。
10. **目标应用必须是两个桌面 App 的 allowlist 之一**；profile 自动探测，Force 模式仅作调试。
11. Macro 注入是次要且必须守卫（`macrosEnabled` 默认 false）。
12. **不提供「一键 bypass permissions」，也不提供任何会让语义错位的高风险重映射（G1 的 D1-b 已否决）。**
13. **不依赖 `~/.codex/ipc/ipc.sock`。**
14. **不把 deep link 作为任何语义动作的可用性前提（因为 `disableDeepLinkRegistration` 可整体关闭）。**
15. **`unavailable` 必须产生用户可见提示，不允许静默无输出。**
16. 硬件探针先于完整实现（已在 Phase 0 完成）。
17. **§7 矩阵中证据等级低于「实测验证」的动作，默认不启用；启用需用户在设置里显式打开。**

---

## 23. 实施 agent 的启动提示（v0.2）

```text
Implement this spec incrementally.

Read first: docs/spec-v0.2.md, docs/phase0-summary.md, docs/research-codex-desktop.md,
docs/research-claude-desktop.md. Do not re-derive hardware facts — Phase 0 is complete.

Phase 0 is DONE. Start at Phase 1 (Controller Core).

Hard constraints (from Phase 0, measured):
- GCController.shouldMonitorBackgroundEvents = true, or the GameController path is silently dead.
- GameController only ever sees the C/XInput variant. The generic variant and H mode are
  invisible to it, so IOHIDManager is a first-class input source, not a fallback.
- Match devices on product string + HID usage. Never on VID/PID alone (generic C and H
  keyboard share 0x4353/0x9b09). Never on location (it changes across reconnects).
- Bind exactly one profile: extendedGamepad and microGamepad are the same object.
- GameController attaches asynchronously; rely on connect/disconnect notifications.
- Use a deadzone: every analog axis reports its centre value once at connect.
- Clear held state on device removal on BOTH paths.

Target apps (this is the whole point of v0.2 — the CLI route is dropped):
- com.openai.codex (ChatGPT.app) and com.anthropic.claudefordesktop (Claude.app).
- Do not implement or depend on Codex TUI [tui.keymap] or ~/.claude/keybindings.json.

Delivery priority: programmatic > native menu click (AX) > key injection (CGEvent) >
explicitly unavailable. Never silently fall back across tiers.

Known capability gaps — implement as visible "unavailable", never silently:
- G1 Codex has NO cyclePermissionMode (measured).
- G2 Claude has no "cycle" for permission mode — open the mode menu and let the user pick.
- G3 Codex toggleFastMode has no default shortcut.
- G4 Claude has no queueFollowUp interface.
- navigate* on both apps is arrow-key injection with focus-dependent meaning: mark it
  ActionRisk.navigation.

Before writing the Claude adapter, first do §9 U10: open a Code session and enumerate its
AX tree. The Claude key bindings in §7.2 are static inference, not measurement.

Safety: macros off by default; never write ~/.codex/ipc/ipc.sock; do not depend on claude://
deep links (they can be globally disabled by managed config); never map the pairing key;
never provide a one-tap permission bypass.

Write unit tests for gesture state transitions and for the capability matrix (§20.2) before
implementing tool-specific adapters.
```

---

## 24. 来源与证据索引

| 文档 | 覆盖范围 | 本版主要引用 |
|---|---|---|
| `iine-l1162-codex-claude-macos-implementation-spec-v0.1.md` | 原始 spec（CLI 路线） | 骨架、语义动作层、§9/§10/§17/§18/§19/§20 保留；§7/§8/§12/§13/§14/§15/§16 重写 |
| `docs/phase0-summary.md` | Phase 0 结论汇总 | §3 的 7 条约束、§4 模式与变体、§7 修订表、§7 未验证项 |
| `docs/hardware-probe.md` | Phase 0 原始实测记录 | §3/§4 的原始证据行（§2 identity、§6.5 背景事件、§6.6 同对象、§6.7 死区、§6.8 变体切换） |
| `docs/research-codex-desktop.md` | Codex 桌面 App 控制面调研 | §7.1 矩阵、G1、G3、R3、R5、R8、§9.1 U1–U8 |
| `docs/research-claude-desktop.md` | Claude 桌面 App 控制面调研 | §7.2 矩阵、G2、G4、R1、R2、R4、§9.2 U9–U17 |

### 证据等级分布（本版 §7 矩阵）

> ⚠️ 读表须知：**「实测验证」指的是「该机制/该键位确实存在」已实测，不是「按下去有预期效果」**。后者对两个 App 的每一格都是【未验证】（§9 U6）。

| 等级 | Codex（11 格） | Claude（11 格） |
|---|---|---|
| 实测验证 | **4 格** —— `cyclePermissionMode` ❌、`toggleFastMode` ⚠️、`openModelPicker` ✅、`inspectChanges` ✅ | **2 格** —— `navigateLeft` / `navigateRight` 的原生菜单项、`inspectChanges` 的原生菜单项 |
| 静态推断 | **6 格** —— 4 个 `navigate*`、`submit`、`cancelOrInterrupt` | **8 格** —— 4 个 `navigate*`（键位）、`cancelOrInterrupt`、`cyclePermissionMode`、`toggleFastMode`、`openModelPicker` |
| 混合（半实测 + 半静态） | **1 格** —— `queueFollowUp`（`codex queue` 命令可达 = 实测；是否被运行中 App 采纳 = 未验证；运行中 `Enter` = 静态） | **1 格** —— `inspectChanges`（键位 = 静态，原生菜单项 = 实测，同一键位交叉印证） |
| 未验证 | 0 格（矩阵级另有「程序化接口为空」= 实测） | **1 格** —— `submit`（Code 语境） |

**这张分布表本身就是结论**：v0.2 的适配层在纸面上可行，但**多数格子的证据等级低于「实测验证」**——Phase 3 的第一件事是补测（§9 U10 / U15），不是写代码。

---

## 25. 需要人类拍板的决策清单

以下问题**不能由实现者替用户决定**。每项给出推荐选项与理由，但需要用户明确回答后才进入对应阶段。

| # | 问题 | 选项 | 推荐 | 阻塞哪个阶段 |
|---|---|---|---|---|
| **Q1** | 确认彻底放弃 CLI 路线？v0.1 的 TUI / `keybindings.json` 集成是否完全不做？ | (a) 彻底放弃 (b) 保留为 v0.3 可选 | **(a)** —— 桌面 App 不跑 TUI，`[tui.keymap]` 零影响（实测） | Phase 3 |
| **Q2** | C 档的两个变体都要支持吗？（= IOHIDManager 必须从「兜底」升为「一级输入源」，Phase 1 工作量显著增加） | (a) 两个都支持 (b) 只支持 XInput，检测到泛用变体就提示 | **(a)** —— 用户已明确要求「不管哪个变体都要可用」；但需要确认接受 Phase 1 的额外成本 | **Phase 1** |
| **Q3** | G1：Codex 的 `cyclePermissionMode` 怎么处理？ | (a) 标记不可用 + 提示 (b) 重映射为 approval（**有风险，已否决过一次**） | **(a)** —— (b) 会让「切模式」变成「批准一次操作」，踩 §13 红线 | Phase 3 |
| **Q4** | G3：Codex 的 `toggleFastMode` 怎么处理？ | (a) 标记不可用 + 提示 (b) `⌘K` 命令面板 + 输入命令名（macro） (c) 引导用户在 App 内自定义快捷键（依赖 U8） | **(a)** 起步，把 (b) 做成默认关闭的开关 | Phase 3 |
| **Q5** | G4：Claude 的 `queueFollowUp` 怎么处理？ | (a) 标记不可用 + 提示 (b) 实验性注入 `enter`（U11 未验证） | **(a)** —— 未验证且可能实际是「发送」而非「排队」 | Phase 3 |
| **Q6** | G2：Claude 的权限模式怎么落地？ | (a) 两段式「打开菜单 + 用户选择」 (b) 「打开菜单 + 盲发 `1`」伪循环 | **(a)** —— (b) 的菜单项顺序未验证，可能选到 `bypassPermissions` | Phase 3 |
| **Q7** | `navigate*` 的语义歧义（随焦点变化）是否接受？ | (a) 接受，标 `ActionRisk.navigation`，只在 frontmost 时注入 (b) 要求先做完整 surface 感知再上 | **(a)** —— (b) 依赖 §9 U10，会把 Phase 3 推后 | Phase 3 |
| **Q8** | H 档 / T 档的处理？ | (a) 只识别 + 提示，不消费输入 (b) H 档做 fallback 输入源 | **(a)** —— H 档实测会严重泄漏（每个键都进入前台 App） | Phase 1 |
| **Q9** | §9 里「改会话数据」级别的验证（U2 / U4 / U5 / U6 / U11 / U12）要不要做？ | (a) 都不做，全部保持【未验证】并在 UI 标注 (b) 在可牺牲会话/账号里做一部分 | **(a)** 起步；若要 (b)，需要用户提供可牺牲环境 | Phase 4 |
| **Q10** | Claude 的 surface 感知方案？ | (a) 只做最小版（菜单 `enabled` + 窗口标题 → chatLike/codeLike/unknown） (b) 先探明完整 AX 特征再做 | **(a)** —— (b) 需要 U10，且会阻塞 Phase 3 | Phase 2/3 |
| **Q11** | 是否接受「Claude `submit` 在 Code 语境是未验证的」这个前提？ | (a) 接受，先按 `enter` 实现并在首次使用时提示 (b) 先补测再实现 | **(a)** 或 **(b)** —— 取决于用户能否提供可牺牲会话 | Phase 3 |
| **Q12** | `allowCodexQueueCli`（`codex queue` 备选路径）要不要开？ | (a) 关闭（默认） (b) 开启为实验性 | **(a)** —— U4 未验证，且会写用户存储 | Phase 3 |
| **Q13** | 配置文件位置与 `capabilities` 可编辑性是否接受？（用户能把 `unavailable` 改成实验性启用） | (a) 接受 (b) 锁定不可改 | **(a)** —— 但 `allowExperimentalUnverifiedActions` 必须默认 false | Phase 2 |
| **Q14** | R1：是否要求用户在 Claude 侧关闭 Hardware Buddy（Anthropic 蓝牙硬件伴侣）？ | (a) 仅在连接异常时提示 (b) 启动时检测并强制要求关闭 | **(a)** —— (b) 侵入性太强 | Phase 1/2 |

---

## 附录 A — 术语对照（v0.1 → v0.2）

| v0.1 | v0.2 | 说明 |
|---|---|---|
| `ToolProfile.codex` | `CodexDesktopAdapter`（bundle `com.openai.codex`） | CLI → 桌面 App |
| `ToolProfile.claudeCode` | `ClaudeDesktopAdapter`（bundle `com.anthropic.claudefordesktop`） | CLI → 桌面 App |
| `ToolProfile.genericTerminal` | `GenericAdapter`（base keys only） | 不再向终端注入 tool-specific 动作 |
| `OutputRecipe` | `DeliveryPlan`（含 `tier` + `evidence`） | 新增投递层与证据等级 |
| `InputEmitter` / `CGEventEmitter` / `MacroEmitter` | `Delivery/`（`ProgrammaticDelivery` / `MenuDelivery` / `KeyInjectionDelivery` / `InputOutputEngine`） | 三种机制 + 串行化 |
| `TargetAppGuard` | `Guard/`（Pass 1 进程级 + Pass 2 菜单可用性 + Pass 3 surface） | 三级守卫 |
| C mode / H mode | T / C / H × 每档两变体 | Phase 0 修正 |
| "GameController 优先，IOHIDManager 兜底" | 两者都是一级输入源 | Phase 0 修正 |
