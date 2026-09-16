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
3. **菜单里选 `Profile → Codex`**（或 Claude Code）。
   *默认是 Generic Terminal，此时只有方向键／A／B 生效，B 层动作会被安全地跳过。*
4. 手柄切到 **C 档**并连上，直接用。

> ⚠️ **每次重新构建 App 后，两项授权都可能失效**（ad-hoc 签名变了），需要在系统设置里重新勾选。

菜单栏图标：实心 = 手柄已连接。菜单里能实时看到当前 profile、前台 App、以及每类动作的结果。

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
| **B 轻按** / **B 长按** | 取消 / **拒绝** | `Escape` |
| **B + ↑** | 跳到最近会话 1 | `⌥⌘1` |
| **B + ↓** | 跳到最近会话 2 | `⌥⌘2` |
| **B + ←** | 新建会话 | `⌘N` |
| **B + →** | 跳到**需要我处理**的会话 | `⌥⌘A` |
| **B + A** | **语音输入**（豆包输入法，长按说话） | 按住右 `⌥`（见下） |

> **`B + A` 来自配置里的修饰键手势**，不是内置的语义动作。按住 B 再按 A 就开始语音输入，
> **此时松开 B 也没关系** —— 只要一直按着 A 就持续输入，松开 A 结束。
> 这类绑定是**全局**的（不受前台 App 白名单限制），因为它不向任何 App 输入命令。
>
> 用的是豆包的「长按**右**option」形态，不是「单击左option+左shift」—— 后者实测在合成事件下**不生效**。

> `A` / `B` 同时承担「批准 / 拒绝」，因为 Codex 和 Claude 的审批弹层用的就是 `Enter` / `Escape` ——
> 最终的确认权始终留在 agent 自己的 UI 里。

按住 `B` 不放可以连续触发多个 chord（类似按住 Shift 连按不同字母）。

**B 层为什么是「会话跳转」**：手柄只有 11 个手势，而
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

手势标识符（共 11 个，就是硬件能产生的全部）：

```text
基础层      up · down · left · right · a
B 手势      b.tap · b.hold
chord       b.up · b.down · b.left · b.right · b.a
```

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

### 已知限制

- **Codex 没有权限模式循环动作**，`B+↑` 已改绑 `新建会话`。切权限模式请用 Codex 自己的 UI。
- **Claude 侧的动作映射未做深度验证**（调研深度不及 Codex），`queueFollowUp` 在 Claude 上不可用。
- **没有开机自启**（可选功能，未实现）。
- 手柄的 **H 档（键盘模式）不消费输入** —— 只识别。C 档两个变体都完整支持。

---

## 目录

```text
docs/spec-v0.3.md              当前规格（唯一权威）
docs/pending-user-tests.md     ⚠️ 需要你亲自验证的清单
docs/codex-menu-shortcuts.md   Codex 菜单快捷键实测导出（44 条，可从运行中 App 重新生成）
docs/phase0-summary.md         硬件实测结论与实现约束
docs/hardware-probe.md         Phase 0 原始记录
docs/phase1-verification.md    Phase 1 真机验证记录
docs/research-*.md             Codex / Claude / Codex Micro 调研

Sources/PocketAgentCore/       全部逻辑（可单测，无 UI 依赖）
Sources/PocketAgentApp/        菜单栏 App（薄壳）
Sources/AgentProbe/            Phase 0 探针
Sources/AgentCoreSmoke/        Phase 1 真机验证工具

scripts/make-agent-app.sh      构建菜单栏 App
scripts/make-app.sh            构建探针 App
```

## 开发

```bash
swift build
swift test                                  # 82 个测试
./.build/debug/coresmoke --duration 60      # 真机看手势链路（只打日志）
./.build/debug/agentprobe watch             # 看原始 HID 报告
swift Tools/dump-menu-accelerators.swift ChatGPT   # 导出 Codex 的真实菜单快捷键
```

> **改键位前先跑最后那条命令。** Codex 的命令注册表里写的键位**不一定是运行时生效的** ——
> `inspectChanges` 就因此错过一次：注册表的 `⌃⇧G` 毫无反应，菜单里实际绑的是 `⌥⌘B`。
> 能从运行中菜单读到的，一律以菜单为准。
