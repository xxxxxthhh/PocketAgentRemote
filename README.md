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
| **B + ↑** | 新建会话 | `⌘N` |
| **B + ↓** | 打开终端面板 | `` ⌃` `` |
| **B + ←** | 模型选择器 | `⌃⇧M` |
| **B + →** | 排队追问 | `Enter`（运行中即入队） |
| **B + A** | 查看变更 / 审阅 | `⌃⇧G` |

> `A` / `B` 同时承担「批准 / 拒绝」，因为 Codex 和 Claude 的审批弹层用的就是 `Enter` / `Escape` ——
> 最终的确认权始终留在 agent 自己的 UI 里。

按住 `B` 不放可以连续触发多个 chord（类似按住 Shift 连按不同字母）。

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
  }
}
```

**`actionKeyOverrides` 是补齐「Codex 没有默认键位」的动作的方式。** 例如 fast mode：
在 Codex 的 `Settings → Keyboard Shortcuts` 里给 Fast mode 绑一个键，然后把同一个键写进这里，
我们的手柄就能触发它了。

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
swift test                                  # 73 个测试
./.build/debug/coresmoke --duration 60      # 真机看手势链路（只打日志）
./.build/debug/agentprobe watch             # 看原始 HID 报告
```
