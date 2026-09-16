# PocketAgentRemote

把手柄（IINE 良值 L1162）变成 macOS 上 **Codex 桌面 App / Claude 桌面 App** 的遥控器。

> 当前生效的规格：`docs/spec-v0.3.md`
> Phase 0 硬件实测：`docs/phase0-summary.md` · Phase 1 真机验证：`docs/phase1-verification.md`
> **需要你亲自测的项：`docs/pending-user-tests.md`**

---

## 快速开始

```bash
./scripts/make-agent-app.sh release     # 构建 build/PocketAgentRemote.app
open build/PocketAgentRemote.app        # 启动（菜单栏出现手柄图标）
```

然后：

1. **点菜单栏的手柄图标 → `Request Accessibility Permission`**，在系统设置里勾选 PocketAgentRemote。
   （没有这个权限，按键会被系统丢弃 —— 菜单里会一直显示 `Accessibility: Required`。）
2. **菜单 → `Input Monitoring`**：如果你的手柄是**泛用变体**（蓝牙里显示为 `Wireless Controller`），
   还需要授予 **Input Monitoring**。XInput 变体（`Xbox Wireless Controller`）不需要。
   菜单里会显示当前状态；`denied` 时点它跳到系统设置。
3. 手柄切到 **C 档**并连上，直接用 —— **profile 会自动跟着前台 App 走**，不用手动选。

> 签名换成 Apple Development 证书后，**重新构建不再使授权失效**（早先 ad-hoc 签名每次重建都要重授权）。

菜单栏图标：实心 = 手柄已连接。菜单里能实时看到当前 profile、前台 App、以及每类动作的结果。

### 自动切换 profile

```text
前台是 ChatGPT(Codex)  → Codex 键位      （B+↑ = 跳到会话 1）
前台是 Claude.app      → Claude 键位     （B+↑ = 下一个会话）
前台是其他任何 App     → Generic         （只有方向键 / A=回车 / B=Esc）
```

配置里改：

```json
"profileMode": "auto",
"autoProfileBundleIDs": {
  "com.openai.codex": "codex",
  "com.anthropic.claudefordesktop": "claudeCode"
},
"fallbackProfile": "genericTerminal"
```

**自动模式下不再检查前台 App 白名单** —— 因为 profile 本身就是从「前台 App」推出来的，
未知 App 只能落到 Generic，工具专属动作不可能误发。白名单在手动模式下仍然生效。

也可以切回 `"profileMode": "manual"`：那时在菜单里手动指定 profile，白名单负责拦住发错对象。

> 这个设计**推翻了 spec v0.3 的 §6.4/§23.7**（「profile 必须显式选择、绝不推断」）。
> 那条的理由是 v0.1 时代的「猜终端里跑的是哪个 agent」，在 macOS 上确实不可靠；
> 而读前台 App 的 bundle ID 是精确的，守卫本来就在用同一个信号。前提变了，所以规则改了。

### 排查问题

**菜单 → `Open Input Monitor…`** 显示实时链路，或者直接看日志文件：

```bash
tail -f ~/Library/Application\ Support/PocketAgentRemote/debug.log
```

```text
[   9.001] RAW      press   up
[   9.001] GESTURE  keyDown(up)
[   9.001] OUTPUT   SEND  down  navigateUp → upArrow → com.openai.codex
```

`SKIP` = 当前 profile 不支持该动作；`DENY` = 被守卫拦下（前台 App 不在白名单等），原因都写在行尾。

---

## 手柄映射（默认，零配置）

手柄只有 6 个输入，`B` 是修饰键。

| 手势 | 语义动作 | Codex 实际发出 |
|---|---|---|
| ↑ ↓ ← → | 导航 | 方向键（可长按重复） |
| **A** | 提交 / **批准** | `Enter` |
| **B 轻按** | 取消 / **拒绝** | `Escape` |
| **B 长按** | **切到另一个 agent**（Codex ⇄ Claude） | 不发按键，直接切换前台 App |
| **B + ↑** | 跳到最近会话 1 | `⌥⌘1` |
| **B + ↓** | 跳到最近会话 2 | `⌥⌘2` |
| **B + ←** | 新建会话 | `⌘N` |
| **B + →** | 跳到**需要我处理**的会话 | `⌥⌘A` |
| **B + A** | **语音输入**（豆包输入法，长按说话） | 按住右 `⌥`（见下） |

> **`B 长按` 不经过 adapter，也不受白名单限制。** 切换前台 App 不是「给某个 App 发按键」，
> 而是系统效果，所以它**在任何前台 App 下都生效** —— 包括你在浏览器里的时候，这正是它最有用
> 的场景。实测（macOS 27）在进程内能用的几种办法（`NSRunningApplication.activate`、AX
> `kAXFrontmost`、合成 `⌘⇥`）**全部无效**，唯一稳定生效的是 AppleScript `activate`，
> 因此 `Info.plist` 里必须有 `NSAppleEventsUsageDescription`（构建脚本已带上）。
>
> 两侧的 App 可以在配置里改：`"agentPair": { "leftBundleID": …, "rightBundleID": … }`。
> 在任何一方按下就切到另一方；从别的 App 按则切到 `left`。
> 菜单里的 `Focus Other Agent Now` 是不用手柄的等价入口，结果会显示在菜单和日志里。

> **`B + A` 来自配置里的修饰键手势**，不是内置的语义动作。按住 B 再按 A 就开始语音输入，
> **此时松开 B 也没关系** —— 只要一直按着 A 就持续输入，松开 A 结束。
> 这类绑定是**全局**的（不受前台 App 白名单限制），因为它不向任何 App 输入命令。
>
> 用的是豆包的「长按**右**option」形态，不是「单击左option+左shift」—— 后者实测在合成事件下**不生效**。

> `A` / `B` 同时承担「批准 / 拒绝」，因为 Codex 和 Claude 的审批弹层用的就是 `Enter` / `Escape` ——
> 最终确认权始终留在 agent 自己的 UI 里。**注意：拒绝请用 B 轻按**；按住 B 超过
> `holdMs`（默认 **450 ms**）才会被当作「切换 agent」。`tapMaxMs`（220 ms）**不再**决定
> 轻按/长按之分：按住 300 ms 仍是「取消」，不会切窗口。
>
> 另外两条边界：**B 一旦与方向键/A 组成 chord，这次 B 的按下就完全归 chord 所有** ——
> 松开 B 不会再补发 `Escape`（语音输入结束不会多取消一次）；**A 已按住时再按 B 会被忽略**
> （A 不是层键，避免松开 A 之后那一下 B 变成切窗口）。

按住 `B` 不放可以连续触发多个 chord（类似按住 Shift 连按不同字母）。

**B 层为什么是「会话跳转」**：手柄只有 12 个手势，而
`⌥⌘1…6`（Go to recent chat）正是 Codex Micro 六个 agent 键的对等物 ——
每个键跳到某个 agent 的会话。`⌥⌘A` 更进一步：一键跳到**正在等你处理**的那个会话
（等审批 / 有未读）。这是我们能用六键手柄做到的、最接近 Micro 体验的形态。

想换回「新建会话 / 终端 / 模型选择器」等，改配置即可，见下节。

---

## 配置

`~/Library/Application Support/PocketAgentRemote/config.json`（菜单 → `Open Config File`，改完 `Reload Config`）。

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
    "b.a": { "modifiers": ["rightOption"], "hold": true }
  },
  "profileGestureKeyOverrides": {
    "claudeCode": {
      "b.up":   { "key": "]", "modifiers": ["command", "shift"] },
      "b.down": { "key": "[", "modifiers": ["command", "shift"] }
    }
  }
}
```

**`agentPair` 决定 `B 长按` 在两个 App 之间怎么切**：`left`/`right` 不是左右手方向，
而是「两个槽位」——从任一方按下都切到另一方，从别的 App 按下则切到 `left`。
留空一侧（`""`）就是单 agent 模式；写 `null` 则回落到内置默认值。
`leftName`/`rightName` 只是显示用的名字，可省略。

三层覆盖，**后者优先**：内置语义绑定 → `gestureKeyOverrides`（全局）→ `profileGestureKeyOverrides`（按 profile）。

**`modifiers` 里的左右侧是分开的**：`option` 是左 Option（keyCode 58），`rightOption` 是右 Option（61）。
有些目标只认其中一侧（豆包就是），**选错不报错、只是没反应**。同理 `shift`/`rightShift` 等。

**`key` 的写法很自由**：`"a"`、`"1"`、`"]"`、`"up"`、`"esc"`、`"space"` 都可以
（也接受 `digit1` / `rightBracket` / `upArrow` 这种枚举名）。省略 `key` 就是只按修饰键。

### `actionKeyOverrides` —— 改「某个动作发什么键」

key 是语义动作名，value 是按键。用来补齐 Codex **没有默认键位**的动作：
在 Codex 的 `Settings → Keyboard Shortcuts` 里给 Fast mode 绑一个键，
再把同一个键写进这里，手柄就能触发它了。

### `gestureKeyOverrides` —— 改「某个手势发什么键」

**这一层绕过语义动作词表**，可以直接把任意手势指向任意按键，
比如让 `B + A` 发 `⇧⎋`（Clear all unreads），而我们的动作表里根本没有这个动作。

手势标识符（共 12 个，就是硬件能产生的全部）：

```text
基础层      up · down · left · right · a
B 手势      b.tap（取消）· b.hold（切到另一个 agent）
chord       b.up · b.down · b.left · b.right · b.a
```

> `b.tap` 与 `b.hold` 是两个独立的手势，可以分别指向不同东西 —— 现在默认就是分开的。
> 把 `b.hold` 写进 `gestureKeyOverrides` 可以覆盖掉「切换 agent」，改回发某个按键。

按键名：`a`-`z`、`0`-`9`、`upArrow`/`downArrow`/`leftArrow`/`rightArrow`、
`enter`/`escape`/`tab`/`space`、`minus`/`equal`/`comma`/`period`/`slash`/`grave` 等；
修饰键 `command`/`option`/`control`/`shift`（`modifiers` 可省略）。

**`key` 可以省略 —— 那就是「只按修饰键」**：

```json
"gestureKeyOverrides": {
  "b.a": { "modifiers": ["rightOption"], "hold": true }
}
```

- `hold: true` = **按住式**（chord 开始时按下，松开 A 时抬起）。实测这是豆包语音输入唯一可行的形态。
- 不写 `hold`（默认）= **单击**（按下即抬起）。
- 修饰键**区分左右**：`option` 是左 Option（keyCode 58），`rightOption` 是右 Option（61）。
  有些目标（比如豆包）只认其中一侧，选错了不会报错、只是没反应。
  同理还有 `shift`/`rightShift`、`control`/`rightControl`、`command`/`rightCommand`。

安全上分两类：

- **带主体键**的自定义绑定 = 工具专属动作 → 需要选定 profile + 前台 App 在白名单内
- **只按修饰键**的绑定 = 全局手势 → 不受白名单限制（它不向任何 App 输入命令）；
  断连或退出时会强制释放，不会卡住修饰键

> 配置里写错的手势标识符**不会导致解析失败**，而是被忽略并在日志里列出来（`unrecognised gesture ids`）。

---

## 安全模型

- 默认 `macrosEnabled = false`，默认 profile 是 Generic Terminal
- 工具专属动作**必须**显式选 profile，且前台 App 必须在白名单内（默认只有两个 AI App + 常见终端/IDE）
- 被守卫拦下的动作**不做任何替代**，只报原因 —— 尤其是权限模式，绝不会被悄悄换成「批准」
- 退出、断连、睡眠时释放所有修饰键与按住的键

---

## 当前状态

| 阶段 | 状态 |
|---|---|
| Phase 0 硬件探针 | ✅ 三种模式、两个变体全部实测 |
| Phase 1 控制器核心 | ✅ 73 个单测 + 真机验证（两条输入路径均通过） |
| Phase 2 菜单栏 App | ✅ 可用（见 `docs/pending-user-tests.md` 待你验收） |
| Phase 3 适配层 | ✅ Codex / Claude / Generic 三套；Codex 侧 8/11 动作有默认键位 |
| 跨 App 切换（`B 长按`） | ✅ 代码与打包验证通过；**手柄真机验收待你** |

### 已知限制

- **Codex 没有权限模式循环动作**，`B+↑` 已改绑 `新建会话`。切权限模式请用 Codex 自己的 UI。
- **Claude 侧的动作映射未做深度验证**（调研深度不及 Codex），`queueFollowUp` 在 Claude 上不可用。
- **`B 长按` 现在是切 App，不再是「拒绝」**：审批时拒绝请用 B 轻按。这是刻意的取舍。
- **跨 App 切换依赖 AppleScript**：进程内的 `activate()` / AX / 合成 `⌘⇥` 在本机实测全部无效，
  所以 `Info.plist` 里的 `NSAppleEventsUsageDescription` 是必需的。若将来系统改规则，
  日志会打印实际生效的方法（`via appleScript`）以及全部失败原因。
- **没有开机自启**（可选功能，未实现）。
- 手柄的 **H 档（键盘模式）不消费输入** —— 只识别。C 档两个变体都完整支持。

---

## 目录

```text
docs/HANDOFF.md                ⭐ 当前真实状态（新会话从这里读起）
docs/spec-v0.3.md              设计意图（与实现已有偏离，见 HANDOFF §6）
docs/pending-user-tests.md     待验证清单
docs/codex-shortcuts.md        Codex 快捷键（官方面板 + 菜单实测导出）
docs/codex-menu-shortcuts.md   菜单导出早期版本（44 条，对照用）
docs/phase0-summary.md         硬件实测结论与实现约束
docs/hardware-probe.md         Phase 0 原始记录
docs/phase1-verification.md    Phase 1 真机验证记录
docs/research-*.md             Codex / Claude / Codex Micro 调研

Sources/PocketAgentCore/       全部逻辑（可单测，无 UI 依赖）
Sources/PocketAgentCore/Focus/ 切前台 App（AppActivator + 两个 agent 的切换规则）
Sources/PocketAgentApp/        菜单栏 App（薄壳）
Sources/AgentProbe/            Phase 0 探针
Sources/AgentCoreSmoke/        Phase 1 真机验证工具

Tools/dump-menu-accelerators.swift  导出运行中 App 的真实菜单快捷键
scripts/make-agent-app.sh      构建菜单栏 App
scripts/make-app.sh            构建探针 App
```

## 开发

```bash
swift build
swift test                                  # 146 个测试
./.build/debug/coresmoke --duration 60      # 真机看手势链路（只打日志）
./.build/debug/agentprobe watch             # 看原始 HID 报告
swift Tools/dump-menu-accelerators.swift ChatGPT   # 导出 Codex 的真实菜单快捷键
```

> 如果 `swift build` 报 `sandbox_apply: Operation not permitted`（SwiftPM 的嵌套沙箱被外层沙箱拒绝），
> 加 `--disable-sandbox` 即可；`scripts/make-agent-app.sh` 可用
> `POCKETAGENT_SWIFTPM_FLAGS=--disable-sandbox` 透传。

> **改键位前先跑最后那条命令。** Codex 的命令注册表里写的键位**不一定是运行时生效的** ——
> `inspectChanges` 就因此错过一次：注册表的 `⌃⇧G` 毫无反应，菜单里实际绑的是 `⌥⌘B`。
> 能从运行中菜单读到的，一律以菜单为准。
