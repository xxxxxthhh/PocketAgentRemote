# 需要你亲自验证的清单

> 生成于 2026-09-16 00:45。
> 这里列的每一项，都是**我在没有你参与的情况下无法验证**的 —— 要么需要物理按键，要么需要授权，
> 要么会改动你的真实会话。其余部分已经跑通并记录在 `docs/phase1-verification.md`。

---

## A. 必须先做的两步（否则什么都测不了）

- [ ] **1. 授予 Accessibility 权限**
      菜单栏手柄图标 → `Request Accessibility Permission` → 系统设置里勾选 PocketAgentRemote。
      验证：菜单里变成 `Accessibility: Granted`，且日志里不再有
      `Accessibility is NOT granted — keystrokes will be dropped by the OS`。
      ⚠️ 注意：**每次重新构建 App 后授权都可能失效**（ad-hoc 签名会变），需要重新勾选。

- [ ] **2. 授予 Input Monitoring 权限（只有泛用变体需要）**
      **这是实测发现的坑**：打包成 App 后 `IOHIDCheckAccess` 返回 **denied**
      （探针当初在终端里跑没有暴露这个问题，因为终端自己可能有权限）。
      影响：手柄若是 `Wireless Controller`（泛用变体），App 会**完全收不到输入**；
      若是 `Xbox Wireless Controller`（XInput 变体）则不受影响，因为它走 GameController。
      操作：菜单 → `Input Monitoring: denied — open Settings` → 在系统设置里勾选。
      验证：日志里 `Input Monitoring: granted`。

- [ ] **3. 菜单里选 `Profile → Codex`**
      默认是 `Generic Terminal`，此时 B 层动作会被安全跳过（日志里是 `SKIP`），这是设计如此。

---

## B. Codex 侧：逐个手势验证

在 ChatGPT.app（Codex 桌面版）窗口里保持前台，依次做：

| # | 操作 | 预期 |
|---|---|---|
| 1 | ↑ ↓ ← → | 会话列表/内容区正常移动；**长按会连续移动**（原生按键重复） |
| 2 | A | 提交当前输入（或批准审批弹层） |
| 3 | B 轻按 | 中断 / 取消 / 拒绝 |
| 4 | B 长按约 0.7 秒再松 | 同 `Escape` |
| 5 | B + ↑ | **新建会话** |
| 6 | B + ↓ | 打开/切换终端面板 |
| 7 | B + ← | 打开模型选择器 |
| 8 | B + → | 追问入队（需要在 agent 正在生成时试） |
| 9 | B + A | ~~审阅面板~~ → 已改为语音输入，见 §H |

- [ ] 9 个手势逐个确认

**重点看两个容易出问题的：**

- [x] **`B + ↑`（新建会话）** —— ✅ 已验证（2026-09-16）
- [x] **`B + ↓`（终端面板）** —— ✅ 已验证
- [x] **`B + ←`（模型选择器）** —— ✅ 已验证
- [x] **`B + A`（查看变更）** —— ✅ 已修正并验证：原用注册表的 `⌃⇧G` **无效**，
      改为运行中菜单里的 `⌥⌘B`（`View > Toggle Review Panel`）。
      **教训**：静态注册表 ≠ 运行时绑定。可用
      `swift Tools/dump-menu-accelerators.swift ChatGPT` 导出真实键位（44 条）。
- [ ] **`B + →`（排队追问）** —— Codex 是「运行中按 Enter 即入队」，依赖它自己的
      `followUpQueueMode` 设置。如果你机器上这个值不是 `queue`，行为会不同。

---

## C. 守卫是否真的在拦

- [ ] **1. 切到 Finder 或 Mail 保持前台**，然后按 `B + ↑`
      预期：**什么都不发生**，日志里出现
      `DENY  newChat: frontmost app "com.apple.finder" is not in the allowlist`。
- [ ] **2. 在同一个前台 App 下按 ↑ ↓** —— 预期同样被 DENY（白名单未关时导航也受保护）。
- [ ] **3. 菜单里关掉 `Require allowlisted frontmost app`**，再按 ↑ ↓
      预期：现在能动了，但 `B + ↑` 这类工具动作**仍然**因「需要显式 profile」以外的原因……
      注意：关掉白名单后工具动作也会放行 —— 这是配置的含义，心里有数即可。

---

## D. Claude 侧 —— 已验证 ✅（2026-09-16）

八个手势全部实测通过。B 层用的是 Claude 菜单里**实测为可用状态**的键
（避开了没开 Code 会话时是灰的 `⌘J` / `⌘⇧D` / `⌘⇧F`）：

| 手势 | 键 | 命令 |
|---|---|---|
| B + ↑ | `⌘⇧]` | Go > Next Chat |
| B + ↓ | `⌘⇧[` | Go > Previous Chat |
| B + ← | `⌘N` | File > New Chat |
| B + → | `⌘K` | View > Command Palette |

做法是 `profileGestureKeyOverrides.claudeCode` —— 两个 App 的快捷键几乎不重叠，
所以手势映射必须能按 profile 分开。

**仍未验证**：Claude 的 Code 面板相关命令（`⌘J` 终端 / `⌘⇧D` 变更 / `⌘⇧F` 文件 /
`⌘;` 侧边对话）—— 它们需要先开一个 Code 会话才会启用，本次没测。

## E. 补齐「没有默认键位」的动作（可选）

Codex 有 3 个动作**没有默认快捷键**，需要一次性配置：

- [ ] **Fast mode**：Codex `Settings → Keyboard Shortcuts` 里绑一个键（比如 `⌃⌥F`），
      然后在我们的 config 里加：
      ```json
      "actionKeyOverrides": {
        "toggleFastMode": { "key": "f", "modifiers": ["control", "option"] }
      }
      ```
      菜单 → `Reload Config`，然后验证。
      （注意：fast mode 不在 ⌘K 命令面板里，只能绑键。）
- [ ] **分屏 / fork**（`forkThread`）同理。

---

## F. 我**没有**做、也没有验证的

- **`--emit` 的真实按键注入从未做过端到端验证** —— 我全程用 log-only 模式，
  避免往你不认识的窗口里打字。上面 B/C/D 节是你第一次真正让它发键。
- **系统睡眠/唤醒后的恢复**：只测了手柄断连，没测系统 sleep。
- **长时间稳定性**：最长只跑过 3 分钟。
- **开机自启**：未实现（spec 里是可选项）。
- **H 档（键盘模式）**：按规格只识别不消费，未测。
- **`ActionRisk.macro` 路径**：目前没有任何动作用它（命令面板 macro 未实现）。

---

## I. 切到另一个 agent（`B 长按`）—— 待你按手柄 ✅/❌

代码、单测、打包、以及「用真实 `AppActivator` 切换真实 App」都已经验过
（浏览器 → Codex → Claude → Codex → Claude 四次全通过），**只有「按住手柄 B」这一下需要你来按**。

> 2026-09-16 一轮外部代码审查提出的 6 条问题已全部修复，其中 3 条会影响真机手感，已在下面加了
> 5b / 5c / 7 三项：长按门槛改为 450 ms、chord 结束后不再补发取消、断连不再自己切 App。

准备：两个 App 都先打开（`ChatGPT.app` 和 `Claude.app`）。重新构建并启动 App：

```bash
POCKETAGENT_SWIFTPM_FLAGS=--disable-sandbox ./scripts/make-agent-app.sh release
open build/PocketAgentRemote.app
```

| # | 操作 | 期望 | 结果 |
|---|---|---|---|
| 1 | 菜单 → `Focus Other Agent Now` | 前台切到另一个 agent，菜单出现 `Last switch: focused … via appleScript` | |
| 2 | 焦点在 Codex，**按住 B 约 1 秒后松开** | 切到 Claude | |
| 3 | 焦点在 Claude，**按住 B 约 1 秒后松开** | 切回 Codex | |
| 4 | 焦点在浏览器/终端，**按住 B** | 切到 **Codex**（`left` 槽） | |
| 5 | 焦点在 Codex，**轻按 B**（<220 ms） | 仍然是 `Escape`（取消），**不**切 App | |
| 5b | 焦点在 Codex，按住 B **约 300 ms** 后松开 | 仍然是 `Escape`（取消），**不**切 App（门槛是 450 ms） | |
| 5c | 按住 `B+A` 语音输入，说完先松 A 再松 B | 只结束语音输入，**不**切 App、**不**多发一次取消 | |
| 6 | 在 Codex 的审批弹层里**轻按 B** | 拒绝（弹层消失），确认「拒绝」没被切 App 顶掉 | |
| 7 | 按着 B（或 ⬆⬇⬅➡）直接关掉手柄电源 / 走远断连 | **不该**发生切 App；日志有 `detached`，且没有 `FOCUS` 行 | |

同时看一眼日志，应当每次都有且只有一行 `FOCUS`：

```bash
tail -f ~/Library/Application\ Support/PocketAgentRemote/debug.log
```

```text
FOCUS  focusOtherAgent: focused com.anthropic.claudefordesktop via appleScript in 80 ms
```

**如果第 2/3 步没反应**，把日志发我，重点看：

- 有没有 `GESTURE hold(b)` —— 没有 = 手柄没触发长按（`holdMs` 默认 450 ms，按住时间要够）。
- 有没有 `FOCUS` 行 —— 有但 `failed` = 切换被系统拒绝，行尾会逐个列出试过的方法和原因。
- 若日志里出现 AppleScript 权限相关错误（`err=-1743` 之类），去
  **系统设置 → 隐私与安全性 → 自动化** 里给 PocketAgentRemote 勾上 ChatGPT / Claude。
  本机实测**没有**弹这个框、也没有被拦，但换机器/换系统版本可能不同。

---

## J. 手柄菜单（`B+←`）—— 已验证 ✅（2026-09-16）

代码、单测、真实窗口冒烟（不抢焦点/可见/切 App 自动关闭）与**手柄实机**均已通过。
调试过程中在这里踩到并修掉了 3 个真问题（见 `docs/HANDOFF.md` §7 第 19–21 条）：
push-to-talk 被长按定时器抢先、兜底守卫吃掉真实松开导致 B 被永久忽略、菜单开合未复位识别器。

准备：焦点在 Codex 或 Claude（菜单只在 agent 前台时才有内容），然后重建启动 App：

```bash
POCKETAGENT_SWIFTPM_FLAGS=--disable-sandbox ./scripts/make-agent-app.sh release
open build/PocketAgentRemote.app
```

| # | 操作 | 期望 | 结果 |
|---|---|---|---|
| 1 | 菜单栏 → `Show Controller Menu` | 浮层出现在屏幕偏下位置，标题是 Codex/Claude，第一项是「新建会话」 | |
| 2 | 焦点在 Codex，按 `B+←` | 浮层出现 | |
| 3 | **松开 B**，等 1 秒 | 浮层仍然在（不用一直捏着） | |
| 4 | 连按 `↓` | 选中项上下移动，到底部回到顶部 | |
| 5 | 选中「查看变更」后按 `A` | 浮层消失，Codex 打开审阅面板 | |
| 6 | 再按 `B+←`，然后按 `B` | 浮层消失，**聊天窗口没有反应**（不会发出取消/拒绝） | |
| 7 | 浮层打开时，**鼠标点一下别的 App** | 浮层自动消失 | |
| 8 | 浮层打开时在 Claude 里做同样操作 | 显示 **Claude 自己的一项「新建对话」**，执行后新建普通对话（**不是**匿名会话） | ✅ 已验证 |
| 9 | 浮层打开时按 `B+A`（语音） | 语音输入**照常工作**（说明浮层没抢焦点） | |
| 10 | 离屏幕 2–3 米看浮层 | 字够大、能看清选中项 | |

日志里应能看到：

```text
MENU  opened for com.openai.codex with 5 items
MENU  running inspectChanges (查看变更)
MENU  closed by B
```

**如果第 1 项就失败**（菜单栏点了没反应）：说明前台不是 Codex/Claude，日志会有
`SKIP openMenu: no agent in front`。

---

## K. 单键语音（按住 A）—— 待你验 ✅/❌

按住 A 说话、松开结束（旧的双键 `B+A` 仍可用）。阈值 220 ms，超过就转成语音、**不发回车**。

| # | 操作 | 期望 | 结果 |
|---|---|---|---|
| 1 | **轻按 A**（<220 ms） | 照旧提交 / 批准，**没有**任何延迟感 | |
| 2 | **按住 A 约 1 秒后说话** | 语音输入开始；松开 A 结束 | |
| 3 | 按住 A 期间**不要**出现多发一次回车 | 聊天框不应多出空行或重复提交 | |
| 4 | 连续快速轻按 A 三次 | 三次提交，不触发语音 | |
| 5 | 按住 A 说话时**手柄断连** | ⌥ 被释放（不会卡住修饰键） | |
| 6 | 菜单打开时按 A | 执行菜单项（菜单优先，不进语音） | |
| 7 | 旧方式 `B+A` | 仍然触发语音（兼容保留） | |

日志对照：轻按应出现 `GESTURE keyDown(a)/keyUp(a)` → `SEND down/up submit → enter`；
按住应出现 `GESTURE holdBegan(a)` → `SEND down <gesture override> → rightOption`，松开发 `holdEnded(a)`。

**如果轻按变慢或被吞**：说明 `aHoldMs` 太大或 A 的计时器没被正确取消，把日志发我。

---

## H. 语音输入（B + A）—— 已验证 ✅

2026-09-16 实测通过。用的是配置里的修饰键手势，不是内置语义动作。

```json
"gestureKeyOverrides": {
  "b.a": { "modifiers": ["rightOption"], "hold": true }
}
```

**正确用法**：按住 B → 按住 A → **可以松开 B** → 一直按住 A 说话 → 松开 A 结束。
（日志实测：一次 down、一次 up 相隔 14 秒，松开 B 时零输出。）

**踩过的两个坑，都值得记住**：

1. **单击式不生效。** 豆包菜单里的「单击左option+左shift」在我们的合成事件下无效，
   即使加了几十毫秒的事件间隔也一样。只有「长按**右**option」这条能打通。
2. **修饰键分左右。** 一开始模型里只有左 Option（keyCode 58），表达不出右 Option（61），
   所以怎么调都不可能成功 —— 时序、间隔都是次要的。现在 `rightOption` / `rightShift` /
   `rightControl` / `rightCommand` 都已支持。

---

## G. 出问题时把这些发给我

```bash
tail -100 ~/Library/Application\ Support/PocketAgentRemote/debug.log
```

日志里 `RAW` / `GESTURE` / `OUTPUT`（`SEND`|`SKIP`|`DENY`）四类标签足以定位问题出在哪一层。
如果是「完全没反应」，重点看有没有 `RAW` —— 没有的话是手柄/输入源问题，有的话是适配层或权限问题。

**如果菜单栏一直显示 "No controller connected"**，按这个顺序查：

1. 手柄是否在 **C 档**？H 档（键盘模式）和 T 档都不在支持范围内 —— 菜单不会提示这一点，因为
   那需要去读键盘类 HID 设备，代价是接收你的全部键盘输入（探针里能这么做，正式 App 里不做）。
2. 手柄是否已配对并在蓝牙里显示为 `Xbox Wireless Controller` 或 `Wireless Controller`？
3. 若是泛用变体，检查 **Input Monitoring** 是否为 `denied`。
