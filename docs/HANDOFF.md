# 交接文档：当前完整状态

> 生成于 2026-09-16 · 27 个 commit · 5413 行 Swift · 111 个单测全绿
> **2026-09-16 更新**：新增「切到另一个 agent」（`B 长按`）· 审查后修复 6 项 · 新增手柄菜单 · 171 个单测全绿
> **2026-09-18 更新**：`B 长按` 改为**程序切换器**（横向图标条，←→ 选 / A 切 / B 关，见 §3.7）· 206 个单测全绿
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
| **A 轻按** | `Enter`（提交 / **批准**，按下即发） | 同左 | 同左 |
| **A 长按** | **按住说话**（单键语音输入，内置默认） | 同左 | 同左 |
| **B 轻按** | `Escape`（取消 / **拒绝**） | 同左 | 同左 |
| **B 长按** | **程序切换器**（全局，不受 profile/白名单影响，见 §3.7） | 同左 | 同左 |
| **B + ↑** | `⌥⌘1` 跳到最近会话 1 | `⌘⇧]` 下一个会话 | **不发** |
| **B + ↓** | `⌥⌘2` 跳到最近会话 2 | `⌘⇧[` 上一个会话 | **不发** |
| **B + ←** | `⌘N` 新建会话 | `⌘N` 新建对话 | **不发** |
| **B + →** | `⌥⌘A` 跳到「需要我处理」的会话 | `⌘K` 命令面板 | **不发** |
| **B + A** | 按住右 ⌥ → 语音输入（旧方式，仍然可用） | 同左 | 同左 |

> `A` / `B` 兼作批准 / 拒绝，因为 Codex 与 Claude 的审批弹层就是 `Enter` / `Escape` ——
> 最终确认权留在 agent 自己的 UI 里。**没有**独立的 approve/reject 动作，是刻意的（见 §6）。
> **注意**：`B 长按` 已改作程序切换器，审批时拒绝必须用 B **轻按**。

### 3.3 切到另一个 agent（2026-09-16 新增；2026-09-18 起手柄入口让位给 §3.7）

> **2026-09-18**：`B 长按` 不再触发它。`focusOtherAgent` / `agentPair` / `AppActivator` 都还在，
> 入口只剩菜单栏 `Focus Other Agent Now`；程序切换器复用同一个 `AppActivator`。
> 配置里没有「手势绑到语义动作」的机制，所以用户也无法把 `b.hold` 绑回它。

一条手势在两个 agent 之间来回切，目标是「把手从键盘上解放出来」：在浏览器里也能一键回到
Codex / Claude。

- **不经过 adapter，也不受白名单限制** —— 切前台 App 是系统效果，不是发给某个 App 的按键。
  它只会在配置指定的两个 App 之间切，且不给它们任何输入，所以没有误发的可能。
- **门槛是 `holdMs`（450 ms），不是 `tapMaxMs`（220 ms）。** 识别器原先在 220 ms 就无条件把 B 判为
  「长按」，于是 300 ms 的按压会切窗口 —— 这比文档承诺的更激进，且是破坏性动作。现在只有
  `holdMs` 计时器真的触发才算长按，更短的按压一律算轻按（取消）。见 §7 第 15 条。
- **实测结论（macOS 27，本机）**：`NSRunningApplication.activate(options:)`（含
  `.activateIgnoringOtherApps` / `.activateAllWindows`）、AX `kAXFrontmost`（返回 `.success`
  但无效）、AX raise main window、合成 `⌘⇥`、`NSWorkspace.openApplication(.activates)`
  **全部无效**；**只有 AppleScript `tell application "X" to activate` 稳定生效**（两个方向、
  反复通过，CLI 进程与签名 App bundle 两种宿主都验证过，且没有弹 TCC 授权框）。
  `AppActivator` 因此把 AppleScript 排在 `methodOrder` 第一位，并把「谁生效了」写进日志。
- **`Info.plist` 必须有 `NSAppleEventsUsageDescription`**（`scripts/make-agent-app.sh` 已加），
  否则 Apple Events 请求会被直接拒绝而不是弹框。
- 目标由配置 `agentPair` 决定：在两方之一按下就切另一方，从别的 App 按则切到 `left`；
  `left/right` 是**槽位**不是左右手方向，为后续「左=Codex / 右=Claude」留了口子。
- 菜单里加了 `Focus Other Agent Now`（等价入口）和 `Last switch:` 结果行；
  日志标签是 `FOCUS`。

### 3.6 单键语音：A 长按（2026-09-16）

用户反馈 `B+A` 要**同时按住两个键**太别扭，要求单键。做了 `a.hold`：按住 A 说话、松开结束。

- **提交没有延迟，这是关键设计**。A 短按在**按下瞬间**就发 `Enter`（审批必须即时）；只有
  跨过 `aHoldMs`（220 ms）才转成「按住手势」，而**一旦转成就从不发 `Enter`**。所以是
  「按住变手势」，不是「松开才提交」——没有把每次提交都拖慢。
- 识别器为此新增了 **`holdBegan` / `holdEnded`** 两个事件：`hold` 是「已完成的按压」（松开才发），
  表达不了「正在按住」。绑定仍是原来那套 `gestureKeyOverrides`（`a.hold` → 按住右 ⌥），
  所以解析层零特殊逻辑。
- 开关由**解析后的覆盖表里有没有 `a.hold`** 决定（`ControllerEngine.aHoldEnabled`），
  因此改配置即可关掉，关掉后 A 完全恢复成原来的一次性按钮。
- 默认绑定放在 `AppConfig.defaultGestureOverrides`（代码里的默认层，优先级低于配置文件），
  这样**不必让每个已有配置都改一遍**。旧配置里的 `b.a` 不动，两种方式并存。
- 手势清单因此从 12 个变成 **13 个**（`a.hold`）—— 硬件仍是 12 个手势，多的那个是 A 的第二种用法。

### 3.4 语音输入的正确用法（踩了很久）

**按住 B → 按住 A → 可以松开 B → 一直按住 A 说话 → 松开 A 结束。**

日志实测：一次 `down`、一次 `up` 相隔 14 秒，松开 B 时**零输出**。
成立的原因是 `bConsumedByChord` 标志阻止了 B 的释放补发 Escape，而 chord 的生命周期只跟 A 走。

---

### 3.5 手柄菜单（`B+←`，2026-09-16 新增）

高频动作直达、低频动作看菜单选。手势只有 12 个，菜单是继续扩展的唯一方向。

- **打开期间手柄整个归菜单**：引擎在**识别器之前**拦截原始事件（`ActionDispatching.handleMenuEvent`），
  所以 ↑↓/A/B 既不会变成聊天窗口里的方向键/回车，也不会触发任何 chord。
- **浮层是 non-activating panel，永不成为 key window**。实测：显示前后前台 App 不变、
  `app.isActive == false`、`panel.isKeyWindow == false`。这是「不抢焦点」的硬证据。
- **两道安全网**：切 App 由浮层自己轮询（0.15 s）关闭；即使来不及关，
  **执行时再次校验前台 App == 打开时的 App**，不等则拒绝执行并记 `DENY`。
- **只列「那个 App 上验证过」的项**：菜单内容由 `ToolAdapter.menuItems` 声明，不再是一份写死的
  通用清单。**这条是踩坑换来的**（见 §7 第 23 条）：原来两个 App 共用一份清单，于是 Claude 被硬塞了
  「切换模型」，而它背后的 `⌘⇧I` 在桌面版根本不是模型菜单 —— 是**新建匿名会话**。现在
  Claude 只提供「新建对话」一项（`⌘N`，实测菜单确认），`openModelPicker` 在 Claude 侧明确
  unsupported 并写明原因。
- 打开菜单时会 `recognizer.resetAndEmit()`：菜单是**因为 B+← 这个手势**才打开的，
  该手势的残留状态不能带进菜单。
- 菜单栏 `Show Controller Menu` 是同一入口（无手柄也能验证）。
- **每个 App 的菜单内容不同**：Codex 5 项（键位都验证过），Claude 目前 1 项「新建对话」。
  Claude 的 `⌘K` 命令面板仍挂在 `b.right` 上，所以「切换模型」这类操作在 Claude 里走命令面板即可。

**顺带修掉一个真实缺陷**：Claude 侧 `.newChat` 一直是 `unsupported`，而菜单第一项就是「新建会话」，
于是 Claude 的菜单会缺掉最有用的一行。用 `dump-menu-accelerators` 读运行中菜单确认
`File > New Chat = ⌘N`，已补上映射（原注释说的「未验证」是过期的）。

**配置自动迁移**：`B+←` 从「新建会话」改为「打开菜单」。若配置里还留着旧的 per-profile
`b.left` 覆盖（你那份 Claude 侧就是 `⌘N`），它会**盖住新默认**，导致那个 profile 根本开不出菜单。
`ConfigMigrations.adoptMenuChord` 只在覆盖**仍等于旧默认值 `⌘N`** 时移除它，并先写
`config.json.backup-<时间戳>`；用户自己改过的绑定不动。

---

### 3.7 程序切换器（`B 长按`，2026-09-18 新增）

手柄版 ⌘⇥。用户的原话：「长按 B 后，程序切换界面一直保持，然后可以通过左右来选择，通过 A 来确认。」

- **为什么不合成真实 ⌘⇥**：本机实测合成 `⌘⇥` 无效（§3.3），而且系统切换器要求 ⌘ 一直按住，
  与「松开 B 后界面保持」矛盾。
- **复用菜单会话，不是新子系统。** `ActionDispatcher.menuSession` 同时承载命令菜单和切换器；
  `AgentMenu.layout`（`.list` / `.strip`）决定哪个轴移动高亮（↑↓ vs ←→），另一轴被吞掉。
  `MenuItem.choice` 是 `.run(AgentAction)` 或 `.activateApp(bundleID:)`；后者直接走
  `AppActivator`，通过 `onActivation` 汇报，不进 adapter/guard。引擎的「菜单开着就接管手柄」
  与开合复位识别器的逻辑一行没改。
- **在 B 松开时打开，不是计时器触发时。** 计时器触发时弹出会打断「B 按久一点再按方向键」的
  慢 chord（菜单一开就接管手柄）。识别器完全没动。
- **初始高亮第二个（上一个程序）**：「长按 B、A」= 切回上一个，原来的两 agent 来回切是特例。
- **少于两个普通程序不弹**，`SKIP openAppSwitcher`。
- **列表在 App 层**（`RunningAppsTracker`）：`NSWorkspace.runningApplications` 过滤
  `activationPolicy == .regular`（本 App 是 accessory，自动排除）。macOS 不提供 MRU 顺序，
  所以从启动起监听 `didActivateApplicationNotification` 自己维护，未见过的按系统顺序排后面，
  已退出的在下次列举时剔除。图标由浮层按 bundle ID 取 `NSRunningApplication.icon`，Core 不碰 AppKit。
- **`AppActivator` 改为按 bundle ID 寻址**（`tell application id "…"`）：切换器让任意程序成为目标，
  按 localizedName 会撞名/本地化。实测 `tell application id "com.openai.codex" to get name` → ChatGPT。
- **`bHold` 默认值是代码常量，不是存盘配置**，所以不需要像 `b.left` 那样做迁移。
- 菜单栏 `Show App Switcher` 是等价入口；日志 `MENU  app switcher opened with N apps` / `FOCUS`。
- 单测：`Tests/PocketAgentCoreTests/AppSwitcherTests.swift`（builder、dispatcher、端到端长按）。
  手柄实机 11 项验收已通过（2026-09-18），见 `docs/pending-user-tests.md` §L。

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
  "agentPair": {
    "leftBundleID": "com.openai.codex",
    "rightBundleID": "com.anthropic.claudefordesktop",
    "leftName": "Codex",
    "rightName": "Claude"
  },

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

**`agentPair` 的语义**：`left`/`right` 是两个**槽位**（不是左右手方向）。从任一方按下 → 切另一方；
从其他 App 按下 → 切 `left`。某侧写 `""` = 单 agent 模式（永远切到剩下那个）；
写 `null` 或不写 = 回落到内置默认值。**注意 `""` 与 `null` 不是一回事**，前者是「没有第二个」。`

- **12 个手势标识符**（硬件能产生的全部）：
  `up` `down` `left` `right` `a` · `b.tap` `b.hold` · `b.up` `b.down` `b.left` `b.right` `b.a`
  （`b.tap` = 取消；`b.hold` = 切到另一个 agent）
- **`key` 可省略** → 只按修饰键。默认单击，`"hold": true` 改按住式。
- **修饰键分左右**：`option`=左(58) / `rightOption`=右(61)。**选错不报错，只是没反应。**
- **`key` 支持自然写法**：`"1"` `"]"` `"up"` `"esc"` 等（也接受 `digit1`/`rightBracket`/`upArrow`）。
- 写错的 gesture id 或 profile 名**只会被忽略并记日志**，不会让整份配置解析失败。

---

## 5. 代码结构

```text
Sources/PocketAgentCore/          全部逻辑，无 UI 依赖，可单测
├── Domain/                       PhysicalButton · InputEvent · ControllerGesture(含 chordReleased)
│                                 AgentAction(25 个) · ActionRisk · OutputRecipe · RecipeEffect
├── Gesture/                      GestureRecognizer（纯状态机 + 可注入时钟）
├── Actions/                      GestureBindings(含 bHold) / GestureID / GestureOverride / EventResolver
├── Adapters/                     ToolAdapter 协议 + Codex / Claude / Generic 三套
├── Guard/                        ActionGuard（显式 profile / macro / 白名单）
├── Focus/                        AppActivator（切前台 App，按 bundle ID 寻址）+ AgentPairResolver（切哪个）
├── Menu/                         AgentMenu（list/strip 两种布局）· MenuItem.choice · AgentMenuBuilder · AppSwitcherBuilder
├── Config/                       AppConfig（容错解码，含 agentPair）+ ConfigStore
├── Dispatch/                     ActionDispatcher（trigger → adapter/系统效果 → guard → emitter）
├── Output/                       KeyStroke · CGEventEmitter（串行队列 + 真修饰键事件）
├── Input/                        HIDMapping · GameControllerInputSource · HIDInputSource · Coordinator
└── Engine/                       ControllerEngine（把上面串起来）

Sources/PocketAgentApp/           菜单栏 App（薄壳）：AppEnvironment / MenuBarController / DebugMonitor
                                  MenuOverlayController（浮层，纵向列表 + 横向图标条）/ RunningAppsTracker（MRU 程序列表）
Sources/AgentProbe/               Phase 0 探针
Sources/AgentCoreSmoke/           Phase 1 真机验证工具（log-only）
Tools/dump-menu-accelerators.swift 用 AX API 导出运行中 App 的真实菜单快捷键
```

`focusOtherAgent` 是唯一**不走 adapter、不走白名单**的动作：`ActionDispatcher` 在 keystroke 路径
之前按 `RecipeEffect.activateAgentApp` 分流，交给 `AppActivator`。理由写在代码注释里，
测试在 `DispatcherTests.testFocusOtherAgent*` 与 `AgentPairTests`。

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
| 8 | — | **`b.hold` 从「拒绝」改为「切到另一个 agent」** | 用户要求「把手从键盘上释放出来」；12 个手势已用满，只有 B 的长按不占用其他功能（代价：审批拒绝改用轻按） |
| 8b | — | **`b.hold` 再改为「程序切换器」（2026-09-18）** | 用户要「⌘⇥ 那样在所有程序里选」；两 agent 互切是它的特例（初始高亮上一个程序）。复用菜单会话，不合成 ⌘⇥（本机无效且要求 ⌘ 常按） |
| 9 | 输出只有按键 + 修饰键 | **增加系统效果 `RecipeEffect.activateAgentApp`** | 切前台 App 不是按键，adapter 表达不了；且它必须在任何前台 App 下都能用，所以也绕开白名单 |
| 10 | §18「B 超过 tapMaxMs 即 hold」 | **改为以 `holdMs` 判定，且 chord 优先** | 一次代码审查发现 300 ms 就会切窗口；破坏性动作不能用「比文档更激进」的门槛 |
| 11 | 释放复用同一条 dispatch 路径 | **释放按「实际发出的按键」处理，不再鉴权/重解析** | 否则中途换前台/换 profile 会让按键卡住（实测复现） |
| 12 | — | **`b.left` 从「新建会话」改为「打开菜单」** | 手势已用满；菜单是继续扩展功能的唯一方向，新建会话成为菜单第一项 |
| 13 | — | **`openMenu` 走效果型 recipe（不经过 adapter 的按键路径）** | 打开菜单不是按键，且必须在任何 profile 下都能开 |

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
12. **切前台 App 只有 AppleScript 一条路（macOS 14+/27 实测）。** `NSRunningApplication.activate`
    的各种 options、AX `kAXFrontmost`（**返回 `.success` 却毫无效果**）、AX raise window、
    合成 `⌘⇥`、`NSWorkspace.openApplication(.activates)` 全部无效。别因为「看起来更正统」就把
    AppleScript 换掉 —— 换掉就是功能直接失效。同时 `Info.plist` 必须有
    `NSAppleEventsUsageDescription`，否则请求被拒且不弹框。
13. **`""` 与 `nil` 在 `agentPair` 里含义不同。** `nil`/缺省 = 用内置默认值（回落到另一个 agent）；
    `""` = 这一侧没有 agent。两者都走容错解码，所以写错不会报错 —— 只会静默用默认值。
    解析时一律用过滤后的 `bundleIDs`，别用原始字段（曾因此返回空 bundle ID）。
14. **释放不能被重新决策。** `keyUp` 曾和 `keyDown` 走同一条 guard/adapter 路径，于是
    「按住方向键 → 前台切到白名单外 → 松开」会**丢掉释放**（键卡在目标 App 里）；
    「按住 B+A 语音 → 中途换 profile/改配置，覆盖表变了」则连触发都没有，`rightOption` 一直按着。
    现在 dispatcher 记录**每个按下动作实际发出的按键**，释放时按记录发，不再重新解析或鉴权
    （`releaseHeldStrokes()` 在断连时清账）；手势层面则在下 chord 时**冻结覆盖表**，直到该 chord 释放。
15. **`tapMaxMs` 不是长按门槛。** 识别器过去在 `tapMaxMs` 就到 `.ready`，长按动作在释放时无条件发射，
    等价于「220 ms 即长按」。`holdMs` 形同虚设。现在 `.ready` 带 `holdFired` / `occupiedByChord`
    两个标志：只有计时器真的触发才算长按；chord 一旦接手，这次 B 按下就**不再产生任何 B 手势**
    （否则语音输入结束会多补一次 `Escape`）。**A 已按住时按 B 一律忽略** —— 否则松开 A 之后那一下
    B 会被当成新的按下，长按后变成切窗口。
16. **断连清理不是用户输入。** HID 源原先在 `deviceRemoved` 里先合成「全部松开」再报 detach，
    识别器把按着的 B 当成真实手势 —— 于是**手柄断连/走远会自己切窗口**。现在源在清理前发
    `onWillDetach`，协调器据此整段屏蔽事件；引擎另有一道兜底：**没有按下在飞行的释放一律丢弃**。
17. **配置解析失败后不能写盘。** `load()` 只回退默认值不写文件，但此后任何一个菜单开关都会
    `update()` → 把默认值覆盖上去，一个拼写错误就抹掉用户全部设置。现在 `didFailToLoad` 会让
    `update()` 返回 `.refusedUnreadableConfig` 并保留原文件。
18. **两个 Swift 可选链陷阱，都栽过**：`flatMap` 的闭包返回 `nil` 会得到 `.some(nil)`，
    `??` 不会回落；`Optional.filter` 在一元上下文里可能被解析成 `String.filter`。两者都静默走偏。
    宁可写显式 `if let`。

---

19. **长按/修饰键的争用必须明确优先权（push-to-talk 的教训）。** 用户习惯「先按住 B，再按 A」说
    话（B 一按就是 600–1200 ms）。把长按门槛改成 450 ms 后，B 在他按下 A 之前就已经触发了
    「切 App」，语音全废。规则现在是：**chord 一旦形成就完全接管这次 B 按下**（清掉 holdFired），
    无论 B 已按住多久 —— 用户还按着 B，正因为他在把它当修饰键用。
20. **"没有按键在飞行的释放一律丢弃"这个兜底太宽，会吃掉真实松开。** 菜单打开时会复位识别器
    （清掉按键状态），于是随后真实的 A 松开落到「没有按键在飞行」分支被丢掉，`aIsDown` 永远留真，
    「A 已按住时忽略 B」从此拒绝每一次 B —— 语音彻底失效，而且 B 按一下才「解锁」。现在守卫只在
    真正的拆设备窗口（`isDetaching`）生效；设备清理那一层已由协调器的 `onWillDetach` 屏蔽。
21. **菜单状态一变就必须复位识别器，而且只能有一个来源。** 菜单打开期间识别器收不到任何事件，
    所以菜单期间的真实松开不会送达；不复位的话下一个按键会被当成「某个早已结束的手势的尾巴」
    而被静默吞掉（表现为「要再按一下 B 解锁」）。复位挂在 `dispatcher.onMenuChanged` 上，
    覆盖全部路径（手柄打开/菜单栏打开/B 关闭/执行后关闭/切 App 关闭）。
23. **没验证过键位的动作不能进菜单。** 菜单最初用一份写死的通用清单，两个 App 共用；于是
    Claude 被提供了「切换模型」，而其键位 `⌘⇧I` 抄自**网页版**的快捷键表 —— 桌面版上它是
    **新建匿名会话**。用户选中后直接开了匿名对话。调研文档其实自己就记了矛盾
    （`openModelMenu = ⌘⇧I` 与 `incognito = ⌘⇧I` 并存），而我当时没核对运行中菜单。
    规则：**菜单项由适配器声明，只列在该 App 上实际观察过能用的**；没验证的动作宁可不出现在
    菜单里，也不要出现一行「选了做错事」。顺带：Claude 的 `⌘J`/`⌘⇧D` 菜单项在**普通 chat 语境下
    是 `[OFF]`**（Code 会话命令），所以也从 Claude 菜单撤掉了，键位本身保留待验证。
24. **菜单状态只能有一处。** 浮层自己关掉时（切 App、断连）曾只清了 dispatcher 的会话，
    没通知引擎，于是引擎仍以为菜单开着 —— 下一个按下的键被 dispatcher 回 `.ignored`，
    引擎**继续往下传给识别器**，`↑` 就变成了发给聊天窗口的真实方向键（用户实测：菜单在屏幕上，
    但上下键不动光标却动了聊天窗口）。现在「菜单是否打开」只有 `dispatcher.openMenu` 一个来源，
    引擎读它、并在收到 `.ignored` 时把事件吞掉并重置识别器。

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
- `AppActivator` 切换前台 App（用仓库内真实代码跑集成：浏览器 → Codex → Claude → Codex → Claude，
  四次全 PASS，`via appleScript`，30–184 ms）
- 断连/重连清理状态、不卡键
- 重建后 Accessibility 授权保持

### 2026-09-16 代码审查后的修复 ✅（当时 146 个单测）
- 6 条外部审查意见全部独立复核成立，逐条修复并加回归测试（`EngineTests` / `DispatcherTests` /
  `CGEventEmitterTests` / `GuardAndConfigTests` / `GestureRecognizerTests`）。
- 修复过程中自己引入并当场发现 2 处回归：`performKeyDown` 误弹修饰键（`[58,124,58,124]` 顺序错了）、
  `releaseAll` 因此少释放一个修饰键 —— 两条既有测试立刻抓到，已按原语义重做。

### 未验证 ⚠️
- **程序切换器（`B 长按`，2026-09-18）** —— 已通过手柄实机 11 项验收（`docs/pending-user-tests.md` §L），
  含 `AppActivator` 改为按 bundle ID 寻址后 `Focus Other Agent Now` 的重验。
- **旧 `B 长按`（切另一个 agent）与手柄菜单** —— 已通过手柄实机验收（2026-09-16）：切 App、菜单打开/导航/执行/
  B 关闭、语音输入、以及三者的交替重复使用。
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
swift build && swift test                       # 构建 + 171 个测试
# 若报 sandbox_apply: Operation not permitted，加 --disable-sandbox
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
| **`docs/research-claude-commands-verified.md`** | **Claude 命令键位的实测记录**：证据强度分级、`⌘⇧I` 冲突、为什么没验 Code 面板 |
| `docs/research-codex-micro-mapping.md` | Codex Micro 对标（33 个动作可达性） |
| `README.md` | 面向使用者的说明 |
