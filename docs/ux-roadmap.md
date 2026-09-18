# 体验增强路线图（功能 + UI）

> 起草于 2026-09-18，程序切换器（`B 长按`）手柄实机验收通过之后。
> 依据：当天 `debug.log` 里的真实使用数据、`docs/HANDOFF.md` §8/§9 的未验证项与候选项、
> 以及现有界面（浮层 / 菜单栏菜单 / 调试窗口）的逐项走查。
> 每一项都带「验证标准」——做完以什么为准，不靠感觉。

---

## 0. 日志里看到的事实（优先级的依据）

| 事实 | 出处 | 含义 |
|---|---|---|
| 切换器一次列出 **17 个程序** | `MENU  app switcher opened with 17 apps` | 横向条很长，MRU 排序是否准确直接决定按几下 |
| 几次打开分别按了 **16 / 22 / 54** 次方向键才落地 | 统计两次 `opened` 之间的 `open for 切换程序` 行数 | 一格一格走是当前最大的摩擦点 |
| **每按一次 ←→ 浮层整个重建**（重取 17 个图标、重布局、重启前台轮询） | `AppEnvironment.onMenuChanged` 无条件调 `overlay.show` | 命令菜单时代 5 行看不出来，17 个图标就有感；日志也被刷满 |
| `SKIP` / `DENY` 一条没有 | 全量 grep | 当前会话没被守卫拦过；但一旦被拦，沙发上完全看不见 |
| 切换全部 `via appleScript`，0 次失败 | `FOCUS` 行 | 按 bundle ID 寻址的路径稳定 |

---

## 1. 功能增强

### 第一档 —— 直接解决实测到的摩擦（建议第一批做，一次提交）

#### F1. 切换器导航提速
- **←→ 按住自动连走。** 菜单打开期间原始事件不经过识别器，所以现在没有键重复。在
  `ActionDispatcher.handleMenuEvent` 或引擎层加一个「按住 350 ms 后每 120 ms 重复」的定时器，
  松开即停。只对 strip 布局的 ←→ 和 list 布局的 ↑↓ 生效。
- **↑↓ 在切换器里有用。** 现在被吞掉。改为 ↑ = 跳到最前、↓ = 跳到最后（或各跳 5 格）。
- **两个 agent 固定排在当前程序之后的前两格。** 配置项 `appSwitcher.pinAgentsFirst`（默认 `true`）。
  你的主要目标就是 Codex / Claude，不该和微信、Telegram 在 MRU 里排队。
  实现：`AppEnvironment.switcherBuilder` 里把 `agentPair.bundleIDs` 里在跑的程序移到索引 1、2。
- 验证标准：17 个程序里切到任意一个 **≤ 3 次按键**；`AppSwitcherTests` 覆盖置顶、跳转、重复。

#### F2. 顺序真正接近 ⌘⇥
- 现状：只有 App 启动后被激活过的程序按最近顺序排，之前就开着的按系统顺序排后面（README 已注明）。
- 方案：`RunningAppsTracker` 初始化时用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 的
  前后顺序为每个 `ownerPID` 取首窗口位置，作为初始 MRU；之后仍由激活通知维护。顺带可以过滤掉
  **没有任何窗口**的 `.regular` 程序（它们在 ⌘⇥ 里也是灰的，切过去没意义）。
- 需要 Screen Recording 权限吗？**不需要**：只读窗口层序和 owner，不读窗口名/图像。要实测确认
  一次（macOS 27）——如果实测发现某个字段被清空，只用 `kCGWindowOwnerPID` 与顺序即可。
- 验证标准：重启 App 后**第一次**长按 B，顺序与随后按 ⌘⇥ 看到的一致。

#### F3. 浮层增量刷新
- `AppEnvironment.onMenuChanged`：若浮层已可见且 `items` 未变，只调 `overlay.render(menu)`；
  只有首次打开才 `show`。前台轮询定时器不再每次重启。
- 日志：一次打开只记「opened」「switching / closed」两行；选择移动不再记 `MENU open for …`。
- 验证标准：17 个程序连按 ←→ 无可感知延迟；一次完整切换日志 ≤ 3 行 `MENU`。

#### F4. 长条改成取景窗（视 F1–F3 做完后是否仍需要）
- 超过 9 个程序时只画以高亮为中心的 9 格，两端渐隐，角上标 `3 / 17`。
- 验证标准：3024 px 宽屏上图标不再缩到 60 pt 以下；两端渐隐可见。

### 第二档 —— 把「没反应」变成「看得见」

#### F5. 动作反馈 HUD（半秒即隐的小提示）
- 复用 `MenuOverlayController` 的 panel 基础设施（non-activating、不抢焦点），新增一个
  一行式 toast：`B+↑ → ⌥⌘1 最近会话 1`、`已拦截：前台不是 agent`、`Codex 不支持：切换权限模式`。
- 触发源：`dispatcher.onEmitted / onDenied / onUnsupported / onActivation`，已经都是回调。
- 配置项 `hud.enabled`、`hud.showEmitted`（默认只显示 DENY/SKIP/FOCUS，不显示每次方向键）。
- 验证标准：人为触发一次 DENY（手动模式 + 白名单外 App）屏幕上有提示；方向键不刷屏。

#### F6. 手柄震动反馈
- Xbox 变体走 GameController 框架，`GCController.haptics?.createEngine(withLocality: .default)`
  可用；泛用 HID 变体没有，自动跳过并在菜单里显示「Haptics: unavailable」。
- 模式：菜单/切换器打开 = 轻一下；切换成功 = 一下；DENY/SKIP = 短促两下；
  语音输入开始/结束 = 各一下（这是唯一不用看屏幕的确认通道）。
- 验证标准：每种模式在手柄上可区分；断连/重连后仍工作。

#### F7. 语音输入进行中指示
- A 长按期间右 ⌥ 一直按着，但屏幕上没有任何迹象。显示一个小胶囊 `● 正在听…`，松开即隐。
  同时是 F5 的一个特例。
- 验证标准：按住 A 出现、松开消失；期间切 App 不残留。

### 第三档 —— 每天能用的基础设施

#### F8. 开机自启（HANDOFF §9 第 1 候选）
- `SMAppService.mainApp.register()`，菜单栏加「Launch at Login」开关，状态实时反映。
- 验证标准：注销再登录，菜单栏图标在；关闭开关后不再自启。

#### F9. 权限丢失主动提示
- Accessibility 被收回（重签名、系统升级后常见）时，用 F5 的 HUD 提示一次 + 菜单栏图标加角标，
  附「去设置」入口；不重复打扰。
- 验证标准：在系统设置里取消勾选，10 s 内出现提示；重新勾选后角标消失。

#### F10. 睡眠/唤醒与长时间稳定性（HANDOFF 未验证项）
- 监听 `NSWorkspace.didWakeNotification`：唤醒后重置识别器、释放所有按键、重查手柄。
- 验证标准：合盖 10 分钟后打开，第一下手势正常，日志有 `WAKE` 行。

---

## 2. UI 增强

按「用户看到的顺序」组织：浮层 → 菜单栏 → 调试窗口 → 整体。

### U1. 浮层（`MenuOverlayController`）

| # | 现状 | 改进 | 验证标准 |
|---|---|---|---|
| U1.1 | 出现/消失是瞬间的 | 120 ms 淡入、80 ms 淡出；高亮移动用 `NSAnimationContext` 做 60 ms 位移。尊重系统「减弱动态效果」 | 打开/关闭不闪；开启减弱动态效果后无动画 |
| U1.2 | 始终在 `NSScreen.main` 下方 22% 处 | 改到**前台窗口所在的屏幕**（`CGWindowList` 或 AX 取前台窗口 frame → 找屏幕）；多显示器时不再跑到另一块屏 | 双屏下浮层与前台窗口同屏 |
| U1.3 | 提示行是纯文字「↑↓ 选择 A 执行 B 关闭」 | 用手柄按键图形：SF Symbols `a.circle.fill` / `b.circle.fill` / `arrow.left.arrow.right`，与手上的键一一对应 | 一眼能对上按键 |
| U1.4 | 命令菜单每行只有标题 | 行右侧灰字显示实际快捷键（`⌘N` / `⌥⌘B`），行左侧 SF Symbol（新建 `plus.bubble`、变更 `doc.text.magnifyingglass`、终端 `terminal`）；数据已在 adapter 的 recipe 里 | 每行有图标和快捷键 |
| U1.5 | 命令菜单头部只有 App 名 | 头部加 App 图标（与切换器一致的取法）；切换器头部显示 `切换程序 · 17` | 两种菜单视觉一致 |
| U1.6 | 切换器只有高亮项显示名字 | 高亮项名字下方再加一行小字：窗口标题或「上一个」「当前」标签；当前程序格子加细边框 | 不用数格子也知道位置 |
| U1.7 | 高亮是实心强调色块 | 改为强调色描边 + 10% 填充，更接近系统 ⌘⇥ 的观感；图标格子圆角与系统一致（约 22%） | 与系统切换器风格接近 |
| U1.8 | `hudWindow` 材质固定偏暗 | 保持暗色（沙发距离对比度更好），但文字与次级文字改用 `NSColor.labelColor` 的 vibrancy 版本，避免浅色壁纸下发灰 | 浅/深壁纸下均可读 |
| U1.9 | 字号固定（行 26 / 标题 15 / 提示 13） | 配置项 `overlay.scale`（0.8–1.5）；默认按屏幕对角线自动：≥ 27" 用 1.2 | 大屏远看可读，小屏不过大 |
| U1.10 | 长按 B 期间没有任何反馈，松开才出现 | 按住超过 `holdMs` 时在浮层位置先出现一个小圆点/进度环（不接管手柄，识别器不变），松开变成完整切换器 | 按住时知道「已经够久了」 |

### U2. 菜单栏（`MenuBarController`）

| # | 现状 | 改进 | 验证标准 |
|---|---|---|---|
| U2.1 | 图标只有「实心=已连接」一种状态 | 三态：未连接（空心）/ 已连接（实心）/ 需要权限（角标 `!`）；菜单打开期间图标短暂高亮 | 不点开菜单就知道状态 |
| U2.2 | 状态行、开关、工具混排 ~20 项 | 分组：**状态**（手柄 / 前台 / profile）→ **动作**（Show Controller Menu / Show App Switcher / Focus Other Agent）→ **设置**（子菜单：Profile Mode / Profile / Macros / Allowlist / Launch at Login）→ **权限**（Accessibility / Input Monitoring / Automation）→ **诊断**（Input Monitor / Open Config / Reload） | 一屏内找到任何项不超过 2 秒 |
| U2.3 | 权限只有 Accessibility / Input Monitoring | 加 **Automation**（AppleScript 切换依赖它）：用 `AEDeterminePermissionToAUTOSendEvents` 查询，denied 时给「去设置」 | 三项权限都可见 |
| U2.4 | `Last switch:` 只显示最近一次 | 改为「最近 3 次动作」子菜单（时间 / 手势 / 结果），点击复制到剪贴板 | 出问题不用开日志就能截图 |
| U2.5 | 全英文 | 与浮层统一为中文（或跟随系统语言，二选一）；按键名保留符号 | 语言一致 |

### U3. 调试窗口（`DebugMonitorWindowController`）

| # | 现状 | 改进 | 验证标准 |
|---|---|---|---|
| U3.1 | 纯文本滚动 | 按标签着色（RAW 灰 / GESTURE 蓝 / SEND 绿 / SKIP 黄 / DENY 红 / FOCUS 紫 / MENU 青） | 一眼分出拦截行 |
| U3.2 | 无过滤 | 顶部标签开关 + 搜索框；「只看问题」= SKIP + DENY + failed | 17 个图标的切换器不会刷掉关键行 |
| U3.3 | 无暂停 | 暂停 / 继续、清屏、「复制最近 100 行」按钮 | 发日志给人不用去找文件 |
| U3.4 | 只有时间戳 | 增加当前前台 App 列（切换类问题最常问「那会儿前台是谁」） | 每行可见前台 |

### U4. 整体一致性

- **视觉语言一份**：颜色、圆角、字号、动效时长集中到一个 `OverlayStyle`，浮层 / HUD / 语音胶囊共用。
- **可访问性**：尊重「减弱动态效果」「增强对比度」；所有 SF Symbol 有文字回退。
- **配置可见**：新增的每个配置项都在 README 配置节有一行说明，并在菜单栏能看到当前值。

---

## 3. 建议的实施顺序

| 批次 | 内容 | 理由 |
|---|---|---|
| **1** | F1 + F2 + F3（+ U1.10 顺手） | 全部来自本轮实测，改动都在切换器内部，风险最低，手感差异最大 |
| **2** | U1.1–U1.7 + U2.1 + U2.2 | 浮层是每天看的东西；菜单栏分组是一次性整理 |
| **3** | F5 + F7 + U3.1–U3.3 | 「看得见」三件套：HUD、语音指示、日志着色 |
| **4** | F8 + F9 + U2.3 | 常驻基础设施与权限可见性 |
| **5** | F6 + F4 + F10 + 其余 UI 项 | 锦上添花，视前几批反馈决定 |

每批一个 commit 系列 + `pending-user-tests.md` 新增一节验收表，沿用现在的流程。

---

## 4. 明确不做 / 暂缓

- **A 也当修饰键**（HANDOFF §9 第 3 项）—— 用户已知悉并暂缓；会让 A 的提交变成「松开才发」。
- **合成真实 ⌘⇥** —— 本机实测无效，且与「松开 B 后界面保持」矛盾（见 HANDOFF §3.7）。
- **在切换器里显示窗口缩略图** —— 需要 Screen Recording 权限，代价与收益不成比例。
- **浮层可用鼠标点选** —— 会让 panel 参与事件分发，破坏「永不抢焦点」的前提。
