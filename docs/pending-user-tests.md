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
| 9 | B + A | 打开审阅/变更标签 |

- [ ] 9 个手势逐个确认

**重点看两个容易出问题的：**

- [ ] **`B + A`（查看变更）** —— 用的是 `⌃⇧G`（Control 不是 Command）。如果没反应，
      说明 Codex 改了 `openReviewTab` 的键位，需要在 `commands.tsv` 那类地方重新核对。
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

## D. Claude 侧

Claude 侧的调研深度不如 Codex，**大部分键位是静态推断而非实测**。

- [ ] 选 `Profile → Claude Code`，在 Claude.app 里试：
      `B + A`（⌘⇧D 变更）、`B + ←`（⌘⇧I 模型菜单）、`B + ↓`（⌘J 终端）
- [ ] **已知不可用**：`B + →`（Claude 没有排队动作，日志会显示 `SKIP`）
- [ ] 特别注意：**Claude 的 Code 面板和 chat 面板语义不同**。同一个 `⌘⇧D` 在两个面板里
      可能做不同的事，需要你确认哪个面板下可用。

---

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

## G. 出问题时把这些发给我

```bash
tail -100 ~/Library/Application\ Support/PocketAgentRemote/debug.log
```

日志里 `RAW` / `GESTURE` / `OUTPUT`（`SEND`|`SKIP`|`DENY`）四类标签足以定位问题出在哪一层。
如果是「完全没反应」，重点看有没有 `RAW` —— 没有的话是手柄/输入源问题，有的话是适配层或权限问题。
