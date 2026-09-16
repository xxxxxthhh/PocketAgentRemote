# 交接文档：当前完整状态

> 生成于 2026-09-16 · 27 个 commit · 5413 行 Swift · 111 个单测全绿
> **给新会话读的第一份文档。** 它记录的是「现在真实是什么状态」，
> 而 `docs/spec-v0.3.md` 记录的是「设计意图」—— 两者已经有偏离，差异在 §6 列明。

---

## 1. 一句话状态

**已经可用了。** 手柄（IINE 良值 L1162）在 C 档下可以驱动 **Codex 桌面 App** 与
**Claude 桌面 App**，profile 自动跟随前台 App 切换；另有一个手势被用作豆包输入法的语音输入。
用户已用它在浏览器里按 A 成功发送消息，两个 App 的 B 层手势也逐个实测通过。

| 阶段 | 状态 |
|---|---|
| Phase 0 硬件探针 | ✅ 三种模式（T/C/H）× 两个 C 档变体全部实测 |
| Phase 1 控制器核心 | ✅ 单测 + 真机验证 |
| Phase 2 菜单栏 App | ✅ 可用 |
| Phase 3 适配层（Codex / Claude / Generic） | ✅ 两侧手势均实测通过 |
| Phase 4 Setup assistant | ❌ 未做（配置靠手写 JSON） |

---

## 2. 怎么跑起来

```bash
cd ~/Documents/agentController
./scripts/make-agent-app.sh release     # 构建 build/PocketAgentRemote.app
open build/PocketAgentRemote.app        # 启动（菜单栏出现手柄图标）
swift test                              # 111 个测试
```

首次使用需要在系统设置里授予两项权限（菜单里有跳转入口）：

| 权限 | 用途 | 是否必需 |
|---|---|---|
| **Accessibility** | 注入按键 | **必需**，否则按键被系统丢弃 |
| **Input Monitoring** | 读 raw HID | **仅泛用变体需要**（`Wireless Controller`）；XInput 变体走 GameController，不需要 |

> **签名已换成 Apple Development 证书**（`scripts/make-agent-app.sh` 自动探测）。
> 早先 ad-hoc 签名时每次重建都会让 Accessibility 授权失效，现在不会了。
> 若机器上没有可用证书，脚本会回退 ad-hoc 并打印警告。

**App 必须常驻**：C 档下手柄本身不向任何 App 发按键（它是游戏手柄），一切靠这个 App 注入。
重启电脑后需要重新启动它 —— **开机自启还没做**。

---

## 3. 当前行为

### 3.1 自动切换 profile（2026-09-16 起）

```text
前台是 ChatGPT (com.openai.codex)        → Codex 键位
前台是 Claude  (com.anthropic.claudefordesktop) → Claude 键位
前台是其他任何 App                        → Generic（只有方向键 / A=回车 / B=Esc）
```

**自动模式下不检查前台 App 白名单** —— profile 本身就是从前台 App 推出来的，
未知 App 只能落到 Generic，工具专属动作不可能误发。手动模式仍保留白名单。

### 3.2 手势映射（全部实测通过）

| 手势 | Codex | Claude | Generic |
|---|---|---|---|
| ↑ ↓ ← → | 方向键 | 方向键 | 方向键 |
| **A** | `Enter`（提交 / **批准**） | 同左 | 同左 |
| **B 轻按 / 长按** | `Escape`（取消 / **拒绝**） | 同左 | 同左 |
| **B + ↑** | `⌥⌘1` 跳到最近会话 1 | `⌘⇧]` 下一个会话 | **不发** |
| **B + ↓** | `⌥⌘2` 跳到最近会话 2 | `⌘⇧[` 上一个会话 | **不发** |
| **B + ←** | `⌘N` 新建会话 | `⌘N` 新建对话 | **不发** |
| **B + →** | `⌥⌘A` 跳到「需要我处理」的会话 | `⌘K` 命令面板 | **不发** |
| **B + A** | **按住右 ⌥** → 豆包语音输入（全局，所有 profile 生效） | 同左 | 同左 |

> `A` / `B` 兼作批准 / 拒绝，因为 Codex 与 Claude 的审批弹层就是 `Enter` / `Escape` ——
> 最终确认权留在 agent 自己的 UI 里。**没有**独立的 approve/reject 动作，是刻意的（见 §6）。

### 3.3 语音输入的正确用法（踩了很久）

**按住 B → 按住 A → 可以松开 B → 一直按住 A 说话 → 松开 A 结束。**

日志实测：一次 `down`、一次 `up` 相隔 14 秒，松开 B 时**零输出**。
成立的原因是 `bConsumedByChord` 标志阻止了 B 的释放补发 Escape，而 chord 的生命周期只跟 A 走。

---

## 4. 配置

`~/Library/Application Support/PocketAgentRemote/config.json`（菜单 → `Open Config File` / `Reload Config`）

```json
{
  "profileMode": "auto",
  "autoProfileBundleIDs": {
    "com.openai.codex": "codex",
    "com.anthropic.claudefordesktop": "claudeCode"
  },
  "fallbackProfile": "genericTerminal",

  "gestureKeyOverrides": {
    "b.a": { "modifiers": ["rightOption"], "hold": true }
  },
  "profileGestureKeyOverrides": {
    "claudeCode": {
      "b.up":   { "key": "]", "modifiers": ["command", "shift"] },
      "b.down": { "key": "[", "modifiers": ["command", "shift"] }
    }
  },

  "actionKeyOverrides": {},
  "allowedBundleIDs": ["com.openai.codex", "com.anthropic.claudefordesktop", "..."],
  "requireAllowedFrontmostApp": true,
  "macrosEnabled": false,
  "tapMaxMs": 220,
  "holdMs": 450
}
```

**三层覆盖，后者优先**：内置语义动作 → `gestureKeyOverrides`（全局）→ `profileGestureKeyOverrides`（按 profile）。

- **12 个手势标识符**（硬件能产生的全部）：
  `up` `down` `left` `right` `a` · `b.tap` `b.hold` · `b.up` `b.down` `b.left` `b.right` `b.a`
- **`key` 可省略** → 只按修饰键。默认单击，`"hold": true` 改按住式。
- **修饰键分左右**：`option`=左(58) / `rightOption`=右(61)。**选错不报错，只是没反应。**
- **`key` 支持自然写法**：`"1"` `"]"` `"up"` `"esc"` 等（也接受 `digit1`/`rightBracket`/`upArrow`）。
- 写错的 gesture id 或 profile 名**只会被忽略并记日志**，不会让整份配置解析失败。

---

## 5. 代码结构

```text
Sources/PocketAgentCore/          全部逻辑，无 UI 依赖，可单测
├── Domain/                       PhysicalButton · InputEvent · ControllerGesture(含 chordReleased)
│                                 AgentAction(24 个) · ActionRisk · OutputRecipe
├── Gesture/                      GestureRecognizer（纯状态机 + 可注入时钟）
├── Actions/                      GestureBindings / GestureID / GestureOverride / EventResolver
├── Adapters/                     ToolAdapter 协议 + Codex / Claude / Generic 三套
├── Guard/                        ActionGuard（显式 profile / macro / 白名单）
├── Config/                       AppConfig（容错解码）+ ConfigStore
├── Dispatch/                     ActionDispatcher（trigger → adapter → guard → emitter）
├── Output/                       KeyStroke · CGEventEmitter（串行队列 + 真修饰键事件）
├── Input/                        HIDMapping · GameControllerInputSource · HIDInputSource · Coordinator
└── Engine/                       ControllerEngine（把上面串起来）

Sources/PocketAgentApp/           菜单栏 App（薄壳）：AppEnvironment / MenuBarController / DebugMonitor
Sources/AgentProbe/               Phase 0 探针
Sources/AgentCoreSmoke/           Phase 1 真机验证工具（log-only）
Tools/dump-menu-accelerators.swift 用 AX API 导出运行中 App 的真实菜单快捷键
```

日志：`~/Library/Application Support/PocketAgentRemote/debug.log`
标签 `RAW` / `GESTURE` / `OUTPUT`(`SEND`|`SKIP`|`DENY`) / `DEVICE` / `APP` 足以定位问题在哪一层。

---

## 6. 与 spec v0.3 的偏离（重要）

`docs/spec-v0.3.md` 是**设计意图**，但实测推动了不少改动。**以本文档为准**：

| # | v0.3 的说法 | 实际实现 | 为什么改 |
|---|---|---|---|
| 1 | §6.4/§23.7：profile **必须显式选择，绝不推断** | **自动跟随前台 App**（`profileMode: "auto"`，默认） | v0.3 的理由是「猜终端里跑的是哪个 agent」；而读前台 App 的 bundle ID 是**精确的**，守卫本来就在用同一信号。前提变了 |
| 2 | B 层 = 新建 / 终端 / 模型 / 排队 / 审阅 | 会话跳转 + 新建 + 需要我处理 | 用户拍板：手势有限（12 个），「哪个 agent 需要我」价值更高 |
| 3 | `inspectChanges` = `⌃⇧G`（注册表） | `⌥⌘B`（**运行中菜单**） | 注册表的键位实测**无效**；静态注册表 ≠ 运行时绑定 |
| 4 | 输出只有「按键」一种形态 | 增加**只按修饰键**（单击 / 按住） | 豆包语音输入需要 |
| 5 | 修饰键不分左右 | 分左右（keyCode 56/60、58/61…） | 豆包要的是**右** option |
| 6 | 手势绑定全局 | 支持按 profile 区分 | 两个 App 的快捷键几乎零重叠 |
| 7 | — | `chordReleased` 事件 | 按住式修饰键绑定需要知道何时结束 |

---

## 7. 实现层面踩过的坑（新会话最需要知道的）

这些都是**实测付出代价换来的**，不要「优化」掉：

1. **`GCController.shouldMonitorBackgroundEvents = true` 是硬性要求。** macOS 11.3 起默认 `NO`，
   含义是「非前台 App 收不到任何手柄事件」。menu-bar 工具永远不是前台 —— 不设这行整条 GC 路径**静默失效**。
2. **GameController 只覆盖 XInput 变体。** 泛用变体（`Wireless Controller`）只有 raw HID 能看到，
   所以 `HIDInputSource` 是**一级路径**而非兜底。
3. **`extendedGamepad` 与 `microGamepad` 是同一个对象**（指针实测相同），元素共享。
   `pressedChangedHandler` 是赋值 —— 绑两次会静默覆盖。现在只通过 `physicalInputProfile.elements` 绑一次。
4. **完全不绑轴。** 连接瞬间所有不存在的轴会上报一次中心值（32767/65535），
   朴素的 `value > 0.5 ⇒ 按下` 会造出幽灵按键。
5. **带修饰键的按键必须发真实的修饰键事件**，不能只设 `event.flags`。
   `⌘N` 用 flags 能生效、`⌃⇧M` 不能 —— Codex 直接无视。spec §11.2 本来就规定了顺序，之前只对按住型实现了。
6. **修饰键分左右，且选错侧不报错。** 豆包要 `rightOption`（61），我们一开始只有左（58），
   怎么调时序都不可能成功。
7. **豆包的「单击左option+左shift」在合成事件下无效**，只有「长按右 option」能打通。
8. **静态注册表 ≠ 运行时绑定。** 用 `swift Tools/dump-menu-accelerators.swift <App>` 读运行中菜单（Codex 44 条、Claude 57 条）。
9. **`AppConfig` 必须容错解码**（每个字段 `decodeIfPresent` 回退默认值）。
   否则新增一个字段就会让旧配置解析失败、静默重置用户设置。
10. **`bConsumedByChord` 标志**阻止「chord 结束后松开 B 补发 Escape」—— 单测抓到的真实缺陷。
11. **App 必须签名稳定**，否则每次重建丢 Accessibility 授权（实测三次重建三次重授权）。

---

## 8. 验证状态

### 已实测 ✅
- 手柄 C 档两个变体都能读（`bound=6`）
- 12 个手势的识别（tap / hold / chord / 修饰键按住/单击）
- Codex 侧 8 个手势逐个生效
- Claude 侧 8 个手势逐个生效
- 语音输入（按住 B+A → 右 ⌥ → 豆包）
- 自动切换 profile（切 App 换键位）
- 在非白名单 App（浏览器）里按 A 发送回车
- 断连/重连清理状态、不卡键
- 重建后 Accessibility 授权保持

### 未验证 ⚠️
- **T / H 模式实拨验证** —— 代码层面确认不匹配键盘/鼠标设备，但没实际拨过开关
- **Claude 的 Code 面板命令**（`⌘J` 终端 / `⌘⇧D` 变更 / `⌘⇧F` 文件 / `⌘;` 侧边对话）
  —— 菜单里实测为 `[OFF]`，需要先开 Code 会话
- **系统睡眠/唤醒后的恢复** —— 只测过手柄断连
- **长时间稳定性** —— 最长连续跑过约 1 小时
- **`ActionRisk.macro` 路径** —— 没有任何动作用它，命令面板 macro 未实现
- **`allowedBundleIDs` 在自动模式下不生效** —— 设计如此，但手动模式的白名单拦截没实测过

---

## 9. 下一步候选

按「性价比 / 影响面」排序：

1. **开机自启** —— 现在重启电脑后 App 不会起来，而它必须常驻。实现成本低（LaunchAgent 或 `SMAppService`），
   但对「每天真的能用」影响最大。
2. **出 spec v0.4** —— §6 那 7 条偏离目前只散落在 README、提交信息和本文档里。
3. **A 也当修饰键** —— 手势从 12 → 约 17（A 层 5 个 + B 层 5 个，`b.a`/`a.b` 实际是同一组合）。
   代价：A 的提交要变成「松开才发」，每次多几十到两百毫秒。
   用户已知悉，暂缓。
4. **Phase 4 setup assistant** —— 引导式改键、备份/合并/还原用户的 Codex/Claude 配置。目前全靠手写 JSON。
5. **Code 面板命令**（Claude）—— 需要用户先开一个 Code 会话才能验证。

---

## 10. 常用命令

```bash
swift build && swift test                       # 构建 + 111 个测试
./scripts/make-agent-app.sh release             # 打包菜单栏 App
./.build/debug/coresmoke --duration 60          # 真机看手势链路（只打日志，不注入按键）
./.build/debug/agentprobe watch                 # 看原始 HID 报告
swift Tools/dump-menu-accelerators.swift ChatGPT  # 导出某 App 的真实菜单快捷键
tail -f ~/Library/Application\ Support/PocketAgentRemote/debug.log
```

---

## 11. 文档索引

| 文档 | 内容 |
|---|---|
| **`docs/HANDOFF.md`** | **本文档 —— 当前真实状态，优先读** |
| `docs/spec-v0.3.md` | 设计意图（与实现有偏离，见 §6） |
| `docs/pending-user-tests.md` | 待验证清单（A–H 节，多数已勾） |
| `docs/phase0-summary.md` | 硬件实测结论与 7 条硬性约束 |
| `docs/phase1-verification.md` | Phase 1 真机验证记录 |
| `docs/hardware-probe.md` | Phase 0 原始记录（三模式 × 两变体） |
| `docs/codex-shortcuts.md` | Codex 快捷键（官方面板 + 菜单实测） |
| `docs/codex-menu-shortcuts.md` | 菜单导出早期版本（44 条，对照用） |
| `docs/research-codex-desktop.md` | Codex 控制面调研 |
| `docs/research-claude-desktop.md` | Claude 控制面调研 |
| `docs/research-codex-micro-mapping.md` | Codex Micro 对标（33 个动作可达性） |
| `README.md` | 面向使用者的说明 |
