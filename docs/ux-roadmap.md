# 体验增强路线图（功能 + UI）

> 起草于 2026-09-18，程序切换器（`B 长按`）手柄实机验收通过之后。
> 依据：当天 `debug.log` 里的真实使用数据、`docs/HANDOFF.md` §8/§9 的未验证项与候选项、
> 以及现有界面（浮层 / 菜单栏菜单 / 调试窗口）的逐项走查。
> 每一项都带「验证标准」——做完以什么为准，不靠感觉。
> **2026-09-18 review 更新**：修正硬件能力、日志统计与排序假设；增加任务面板、四向操作盘、
> 语音派活面板三个产品方向。本文中的新增设计均为建议，尚未实现，也不表示已通过真机验收。
> **2026-09-18 执行计划**：§7 把 §3 的批次拆成可直接开工的任务单（T0.x–T3.x），每单带涉及文件、
> 步骤、验收方法、依赖、规模与失败处理；由 Claude 与 Codex 对照代码两轮讨论后落盘，仍为静态分析结果。

## Review 结论与产品边界

**保留现有摩擦修复，但把主线推进到「选择任务、发起工作、回到结果」。** 原路线图偏重切换器
提速、样式与诊断，能改善手感，却还没有增加多少用户可以完成的事情。建议短期试做四向操作盘，
并优先验证任务收藏能否准确打开具体会话；具备任务定位能力后，再决定是否投入统一任务面板。

必须遵守的边界：

- **IINE L1162 只有 ↑↓←→、A、B 六个实体输入，没有可用震动能力。** 不从 Xbox profile 推断
  额外硬件能力，不把配对/电源键纳入交互。
- **豆包输入法已经承担语音转写。** 新功能复用右 Option 触发链路；本 App 目前知道的是
  「已发送/释放语音快捷键」，不能据此声称豆包正在录音、识别成功或文本已送达。
- **键位预算已经很紧。** 新功能优先复用 `B+←` 菜单及其子页面；`B 长按` 保留程序切换器，
  `B+A` 保留现有语音方式。每个方案都说明原功能多了几步，不默认增加双击或第二修饰层。
- **主路线图与代码缺陷分开。** A 轻按/长按是否会串发 Enter、菜单关闭后是否残留输入，仍需
  专项代码 review；未经确认，不能把文档中的「即时提交且长按不提交」当作新 UI 的可靠前提。

| Review 发现 | 调整 |
|---|---|
| 原 F6 把 GameController 的 API 当作设备有震动的证据 | 从当前设备计划移除，保留编号说明原因 |
| 原 F1 承诺任意 17 个程序 ≤3 次按键，且默认把 agent 插入 MRU 前部 | 拆开常用入口与完整列表；明确计数口径，不破坏「上一个程序」默认选中语义 |
| 原 F2 把窗口层序等同于应用 MRU，并过滤无可见窗口的程序 | 改为保留应用激活历史；窗口层序只作为可选近似实验 |
| 原 F7 把模拟按键状态写成「正在听」 | 改为「语音键已按住」，真实识别状态须有豆包侧证据 |
| 原实施顺序连续多批只做样式/诊断 | 插入可单独验证的功能增量，详见 §3、§5 |
| 原路线图按提交批次组织 | 改按可验收的用户结果组织；不代表提交、部署授权 |

---

## 0. 日志与代码证据（修订后的口径）

本次读取 `~/Library/Application Support/PocketAgentRemote/debug.log` 时共 713 行，SHA-256：
`c4f3a81793d7f213f55f7cb0f4f54cff092220c583626d35a3540ebea881546a`。
日志会随运行变化/重启覆盖，以下仅对应这次读取，不代表长期统计；未在仓库保存原始日志。

| 已核对的事实 | 出处 | 可以支持的判断 |
|---|---|---|
| 切换器列出 17 个程序 | `app switcher opened with 17 apps` | 需要检查长列表可见性和导航成本 |
| 例：53 次左右键 press 后执行，15 次和 31 次后取消 | 按单次 opened → switching/closed 分段，统计 `RAW press left/right`；对应行 12–173、264–311、440–535 | 值得测导航效率；这些可能包含刻意的真机测试，不能直接解释成每次寻找目标都要这么多次 |
| 原「16 / 22 / 54 次」来自 `open for` 绘制回调计数 | 首次打开和导航更新均可触发，导航后选择未变也可能回调 | 撤回其作为真实方向键次数的结论；后续分开记录输入次数、重复步数、取消和成功 |
| 选择更新仍调用 `overlay.show`，重建内容并重启轮询 | `AppEnvironment.swift` 的 `engine.onMenuChanged`；`MenuOverlayController.show` | F3 有明确代码依据；卡顿程度仍需测量 |
| 当前样本无 DENY/SKIP | 对上述日志逐行筛选 | 只能说本次样本没有，不能说明反馈无需建设 |
| FOCUS 记录为 10 次成功、1 次失败 | 第 571 行：微信两种激活方式均未改变前台；成功记录均为 `via appleScript` | 撤回「0 次失败/路径稳定」的概括；失败原因待复现，F5 应能呈现失败并支持重新选择 |

后续对比用固定目标集：在相同的 17 个程序、相同起始前台下，分别切换上一个程序、两个 agent、
列表前/中/末部目标。记录从打开到成功的耗时、独立按键次数、自动重复步数和取消/误切次数。
一次按住算一次物理操作，但持续时间与重复步数另记；不把长按 3 秒包装成「只按了一下」。

---

## 1. 功能增强

### 第一档 —— 修复已有摩擦，并验证新的导航方式

#### F1. 切换器导航提速
- **←→ 按住自动连走。** 初始候选参数为按住 350 ms 后每 120 ms 一步，需真机调手感。
  仅 strip 的 ←→、list 的 ↑↓可重复；A/B 不重复。释放、关闭、失焦、断连均停止计时器，
  到边界后的行为必须明确，不能关闭菜单后继续把方向键送给原 App。
- **↑↓ 可用于翻页，先作为实验。** 若采用每页 5 项，↑上一页、↓下一页，屏幕明确显示提示；
  不同时提供「跳首尾」和「跳 5 格」两种含义，也不与未来网格导航混用。
- **常用程序与 MRU 分开。** 默认继续选中上一个程序；Codex / Claude 可加入显式的常用区，
  不默认插入 MRU 的第 1、2 位。配置若允许置顶，用户须看得出当前是常用顺序还是最近顺序；
  一次菜单打开期间顺序固定。
- **撤回「17 个程序任意目标 ≤3 次按键」承诺。** 连走、跳页和 agent 置顶本身不能保证这个目标。
  常用 4 项的操作盘可要求打开后 ≤2 次操作完成选择与确认；完整列表按 §0 的目标集测耗时，
  候选验收目标为中位耗时降低至少 30%，且误切次数不增加。百分比是待测目标，不是已有结果。

#### F2. 可预测的最近使用顺序
- 现状：`RunningAppsTracker` 仅记录本次启动后的激活顺序，其他程序按系统枚举顺序追加。
- **先选可解释的方案：** 持久化本工具已观察到的 bundle ID 最近顺序；启动时与仍在运行的程序
  求交集、当前程序放首位，未观察过的应用以稳定顺序追加。说明这不是系统 ⌘⇥ 的完整历史。
- **窗口层序路线降为候选实验。** `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 描述窗口集合，
  不是应用激活历史；多窗口、最小化、隐藏及不同 Space 都需要单独验证，不能据此承诺与 ⌘⇥ 一致。
  也不能因为屏幕窗口列表没出现某个 App，就自动把它从切换器剔除。
- 权限与字段可见性标为 **[未核实]**：若后续用窗口 API，须在本机无 Screen Recording 授权状态下
  验证需要的字段和降级表现。Apple 将该 API 定义为窗口信息查询，且提示其有生成成本；
  不应放进每次方向键更新路径。[Apple API 文档](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:))
- 验证标准：重启后已观察过的运行程序顺序可恢复；未观察程序顺序稳定；隐藏、最小化和无当前屏幕
  窗口的运行程序不会被错误排除；打开期间顺序不跳动。

#### F3. 浮层增量刷新
- `AppEnvironment.swift` 的 `engine.onMenuChanged`：若浮层已可见且目标、标题、布局及条目未变，只调 `overlay.render(menu)`；
  只有首次打开或目标/布局/条目/标题变化时才 `show`。前台轮询定时器不再每次重启。
- 日志：一次打开只记「opened」「switching / closed」两行；选择移动不再记 `MENU open for …`。
- 验证标准：17 个程序连按 ←→ 无可感知延迟；一次完整切换中，MENU 标签及 OUTPUT 内 MENU 前缀合计 ≤3 行。

#### F4. 长条改成取景窗（视 F1–F3 做完后是否仍需要）
- 超过 9 个程序时只画以高亮为中心的 9 格，两端渐隐，角上标 `3 / 17`。
- 验证标准：按屏幕 `visibleFrame` 的逻辑点尺寸计算，在笔记本与外接屏上均不越界；
  图标目标尺寸 ≥60 pt，选中项始终可见。窄屏可减少可见格数，不用像素宽度直接推导 pt。

### 第二档 —— 把「没反应」变成「看得见」

#### F5. 动作反馈 HUD（成功短提示，失败可读、可恢复）
- 复用 `MenuOverlayController` 的 panel 基础设施（non-activating、不抢焦点），新增一个
  一行式 toast：`B+↑ → ⌥⌘1 最近会话 1`、`已拦截：前台不是 agent`、`Codex 不支持：切换权限模式`。
- 触发源：`dispatcher.onEmitted / onDenied / onUnsupported / onActivation`；部分失败仅写日志，需补接通知。
- 批次 1 仅显示拒绝、不支持和激活失败，不新增配置；成功提示后续再评估。
- SEND 只显示「已请求发送快捷键」，不证明系统已注入或目标 App 已执行；FOCUS 以已核验的前台变化为准。
- 成功提示候选 0.8 s；批次 1 的失败/拒绝提示保留 3 s 后到期，不占手柄按键。HUD 不占用命令菜单或切换器的会话状态，
  不抢焦点、不因 toast 到期关闭用户正在选择的菜单。切换失败后可重新打开切换器选择其他目标。
- 验证标准：人为触发一次 DENY（手动模式 + 白名单外 App）和一次激活失败，屏幕可读且能恢复；
  方向键不刷屏；菜单同时打开时选择与确认不受 HUD 干扰。

#### F6. 手柄震动反馈 —— 当前设备不做
- 用户已明确本设备没有震动能力，从实施批次移除。
- GameController profile 或 API 的存在不代表设备有马达。Apple 也明确 `haptics` 可以为 `nil`。
  [Apple haptics 文档](https://developer.apple.com/documentation/gamecontroller/gccontroller/haptics)
- 仅在将来更换硬件、实测确认能力后另行评估；当前使用屏幕反馈，可选声音提示另做体验验证。

#### F7. 语音快捷键保持指示
- A 长按或旧 `B+A` 实际开始持有右 Option 时，显示胶囊 `语音键已按住 · 松开结束`，释放即隐。
  不显示「正在听/正在转写」，除非将来能从豆包取得可信状态。
- 与 F5 共用样式，但持续状态和瞬时 toast 分开管理；未获输出权限时不能显示成成功持有。
- 验证标准：两种语音入口均覆盖；短按 A 不出现；释放、断连、退出时不残留；切 App 后的显示
  与实际按键持有状态一致；豆包未运行时不声称它已开始识别。

### 第三档 —— 每天能用的基础设施

#### F8. 开机自启（HANDOFF §9 第 1 候选）
- `SMAppService.mainApp.register()`，菜单栏加「Launch at Login」开关，状态实时反映。
- 验证标准：注销再登录，菜单栏图标在；关闭开关后不再自启。

#### F9. 权限丢失主动提示
- Accessibility 被收回（重签名、系统升级后常见）时，用 F5 的 HUD 提示一次 + 菜单栏图标加角标，
  附「去设置」入口；不重复打扰。
- 验证标准：在系统设置里取消勾选，10 s 内出现提示；重新勾选后角标消失。

#### F10. 睡眠/唤醒与长时间稳定性（HANDOFF 未验证项）
- 睡眠前取消手势与菜单定时器、释放已发出的按键；唤醒后重置输入状态、重查手柄和权限。
  不能只在唤醒时才做清理，也不能把断连清理合成为新的 B 轻按/长按动作。
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
| U1.4 | 命令菜单每行只有标题 | 行右侧灰字显示实际快捷键（`⌘N` / `⌥⌘B`），行左侧 SF Symbol（新建 `plus.bubble`、变更 `doc.text.magnifyingglass`、终端 `terminal`）；快捷键从有效 recipe 提取；图标映射和展示字段另补 | 每行有图标和快捷键 |
| U1.5 | 命令菜单头部只有 App 名 | 头部加 App 图标（与切换器一致的取法）；切换器头部显示 `切换程序 · 17` | 两种菜单视觉一致 |
| U1.6 | 切换器只有高亮项显示名字 | 高亮项名字下方再加一行小字：窗口标题或「上一个」「当前」标签；当前程序格子加细边框 | 不用数格子也知道位置 |
| U1.7 | 高亮是实心强调色块 | 改为强调色描边 + 10% 填充，更接近系统 ⌘⇥ 的观感；图标格子圆角与系统一致（约 22%） | 与系统切换器风格接近 |
| U1.8 | `hudWindow` 材质固定偏暗 | 保持暗色（沙发距离对比度更好），但文字与次级文字改用 `NSColor.labelColor` 的 vibrancy 版本，避免浅色壁纸下发灰 | 浅/深壁纸下均可读 |
| U1.9 | 字号固定（行 26 / 标题 15 / 提示 13） | 提供标准/远距两档预览，可选 `overlay.scale`（0.8–1.5）；按逻辑可用区域限制尺寸，不依赖可能缺失的物理对角线推测观看距离 | 大屏远看可读，小屏不裁切 |
| U1.10 | 长按 B 期间没有任何反馈，松开才出现 | 按住超过 `holdMs` 时在浮层位置先出现一个小圆点/进度环（不接管手柄，识别器不变），松开变成完整切换器 | 按住时知道「已经够久了」 |

### U2. 菜单栏（`MenuBarController`）

| # | 现状 | 改进 | 验证标准 |
|---|---|---|---|
| U2.1 | 图标只有「实心=已连接」一种状态 | 三态：未连接（空心）/ 已连接（实心）/ 需要权限（角标 `!`）；菜单打开期间图标短暂高亮 | 不点开菜单就知道状态 |
| U2.2 | 状态行、开关、工具混排 ~20 项 | 分组：**状态**（手柄 / 前台 / profile）→ **动作**（Show Controller Menu / Show App Switcher / Focus Other Agent）→ **设置**（子菜单：Profile Mode / Profile / Macros / Allowlist / Launch at Login）→ **权限**（Accessibility / Input Monitoring / Automation）→ **诊断**（Input Monitor / Open Config / Reload） | 一屏内找到任何项不超过 2 秒 |
| U2.3 | 权限只有 Accessibility / Input Monitoring | 展示明确目标 App 的自动化拒绝/未知状态，不能用单一开关代表所有目标；后台状态检查不主动弹授权框。查询 API 与实际 activate 路径的关系先实测 | 能指出失败目标和处理入口；打开菜单不会逐 App 弹框 |
| U2.4 | `Last switch:` 只显示最近一次 | 改为「最近 3 次动作」子菜单（时间 / 手势 / 结果），点击复制到剪贴板 | 出问题不用开日志就能截图 |
| U2.5 | 全英文 | 与浮层统一为中文（或跟随系统语言，二选一）；按键名保留符号 | 语言一致 |

### U3. 调试窗口（`DebugMonitorWindowController`）

| # | 现状 | 改进 | 验证标准 |
|---|---|---|---|
| U3.1 | 纯文本滚动 | 按标签与消息前缀着色（RAW 灰 / GESTURE 蓝 / SEND 绿 / SKIP 黄 / DENY 红 / FOCUS 紫 / MENU 青；兼容 OUTPUT 内前缀） | 一眼分出拦截行 |
| U3.2 | 无过滤 | 顶部分类开关 + 搜索框；「只看问题」= SKIP + DENY + FOCUS 的 `could not focus` | 17 个图标的切换器不会刷掉关键行 |
| U3.3 | 无暂停 | 暂停 / 继续、清屏、「复制最近 100 行」按钮 | 发日志给人不用去找文件 |
| U3.4 | 只有时间戳 | 增加当前前台 App 列（切换类问题最常问「那会儿前台是谁」） | 每行可见前台 |

### U4. 整体一致性

- **视觉语言一份**：颜色、圆角、字号、动效时长集中到一个 `OverlayStyle`，浮层 / HUD / 语音胶囊共用。
- **可访问性**：尊重「减弱动态效果」「增强对比度」；所有 SF Symbol 有文字回退。
- **配置可见**：新增的每个配置项都在 README 配置节有一行说明，并在菜单栏能看到当前值。

---

## 3. 建议的实施顺序（按用户结果，而非润色清单）

| 批次 | 交付的用户结果 | 范围与完成门槛 |
|---|---|---|
| **0：确认基线** | 明确当前单键语音、菜单及切换器是否有阻断缺陷 | 完成专项代码 review；核实 A/Enter 时序，复现微信切换失败。缺陷单独修复，不与新 UI 混在一起 |
| **1：操作更快且看得到结果** | 常用动作可直接按方向选择；完整切换器不因选择更新重建 | G2 四向操作盘原型 + F3；仅补最小失败提示。用现有竖向菜单作对照，未改善则保留列表 |
| **2：从切 App 到切任务** | 打开 2–4 个真实收藏任务 | 先做 G1 定位验证；至少一个目标工具能准确打开具体任务后才做收藏 UI。无需等两工具同时支持 |
| **3：完成一次遥控派活** | 在正确目标里完成输入、检查、发送 | 优先验证 G3-A 输入框聚焦；仅在仍有明确痛点时做 G3-B 独立语音草稿面板 |
| **并行候选：日常可靠性** | 每天启动、断连和恢复有明确反馈 | F5/F7/F8/F9/F10，按已出现的故障排期；睡眠释放属于可靠性，不列为锦上添花 |
| **后续按证据选做** | 大列表更易浏览、远距更可读 | F1/F2/F4、U1/U2；U3 和装饰性动效后排。F6 不进入当前设备计划 |

本表的批次 0–3 已在 §7 拆成任务单，开工以 §7 为准。「并行候选」只是排期分类，不要求并行开发。一次选择一个可用闭环；每批交付前记录实际步骤、
实测结果与剩余限制。本文不授权提交代码，也不要求为了路线图新增全部配置项。

---

## 4. 明确不做 / 暂缓

- **A 也当修饰键**（HANDOFF §9 第 3 项）—— 用户已知悉并暂缓；会让 A 的提交变成「松开才发」。
- **合成真实 ⌘⇥** —— 本机实测无效，且与「松开 B 后界面保持」矛盾（见 HANDOFF §3.7）。
- **在切换器里显示窗口缩略图** —— 需要 Screen Recording 权限，代价与收益不成比例。
- **本轮增加鼠标点选** —— 先把六键流程做好；是否支持鼠标是产品范围选择，不直接断言鼠标事件必然抢焦点。
- **自动批准、按一下连续执行多项任务** —— 不作为任务面板的默认能力；面板先负责定位和显示。

---

## 5. 功能与 UI 的新增方向

这三项扩展的是可完成的工作。不是三项一起做：G2 可以独立验证；G1 先验证任务定位能力；
G3 先利用现有输入框和豆包，不预设必须再造一个聊天界面。

### G1. 任务收藏 → 任务面板（产品主线，先验证定位）

**用户收益：** 从研究报告切回代码任务时，不再先切 App、再在侧栏找会话。用户选的是
「修复登录」「研究报告」这样的工作，而不是程序图标。

第一版只做 2–4 个手工收藏：名称、所属 App、已验证的任务定位信息，以及一个打开动作。
不自动扫描聊天数据库，不把窗口标题当作可靠任务 ID，也不先做运行进度聚合。

```text
┌────────────────────────────────────┐
│ 我的任务                       1/3 │
│                                    │
│ 修复登录                           │
│ Codex · 已收藏                     │
│                                    │
│ ←→ 选任务      A 打开      B 返回   │
└────────────────────────────────────┘
```

- **入口与键位代价：** `B+←` 的命令菜单增加「我的任务」入口；进入后 ←→ 选卡片，A 打开，
  B 返回上层，根菜单再按 B 关闭。不占新的组合键。首次进入比直接切 App 多一次菜单选择，
  收益应来自省掉目标 App 内找会话的步骤；不能只比较打开面板用了几下。
- **能力门槛 [未核实]：** 分别验证 Codex、Claude 是否有稳定任务链接、公开接口或可复现的
  导航方式。先对每个工具测试两个同属该 App 的不同任务，证明能打开指定任务。
  若只能激活 App，明确显示「仅打开程序」，不能标成「打开任务」。一个工具支持即可先做。
- **第二阶段：** 仅当有可靠状态来源，再增加「待你处理 / 运行中 / 已完成」，附更新时间和来源。
  来源失效时显示「状态未知」；没有接入的工具也不显示虚构的进度。摘要与状态聚合不是第一版前提。
- **验收：** 已接入工具的两个任务各连续打开 5 次，目标正确且不发送消息；链接失效、任务删除、
  App 未运行时有明确结果；从任意前台到正确任务的完整操作数少于原先「切 App + 找会话」。
  测试只能确认支持的目标/版本，不由此宣称覆盖所有工具。

### G2. 四向操作盘（近期 UI 实验）

**用户收益：** 屏幕上的空间位置对应手指方向，常用低频动作不必在长列表里逐行寻找。
它替换的是 `B+←` 打开的命令菜单视图，不替换 `B 长按` 的程序切换器。

```text
                  新建会话
                     ↑
       查看变更  ←  Codex  →  更多操作
                     ↓
                  打开终端

               A 确认 · B 返回
```

- **第一版：** 每个 App 最多四个方向槽，复用 adapter 已验证且测试上下文可用的命令；超过四项进入「更多操作」
  列表。示意图里的「更多」可承载当前切换模型、归档会话，以及将来的「我的任务」。
  不为填满四格而补未验证的 Claude 动作；只有一两项时也可保留列表，按实际操作效率选择。
- **稳定映射：** 相同含义尽量放相同方向；不按使用频率实时换位。不存在的动作可留空或显示
  不可用说明，不让其他动作自动顶替其位置。
- **输入规则：** 打开时无自动执行；↑↓←→ 选择对应槽，A 执行，B 返回/关闭。打开菜单的
  `B+←` 那次输入必须被完整消费，不能刚打开就选中或执行左槽；松开 B 后菜单仍保留。
  面板标题显示当前目标 App；切换目标后关闭旧菜单，避免旧选择落到新 App。
- **代价：** 新建从现有「打开 → A」变成「打开 → ↑ → A」，多一步；较后面的动作会少走几步。
  是否值得替换默认列表，要以真实使用频率和测试结果判断，不能仅凭四向布局好看决定。
- **验收：** 选择四个常用动作与现有列表对照，每个执行 5 次，统计完整耗时、物理按键数、
  错选与返回次数；打开后的任一直接槽 ≤2 次操作（方向 + A）。远距能读清标签，
  高频新建若明显变慢，保留列表默认或调整方案。测试期间仅实现一个可切换原型，不先做复杂主题系统。

### G3. 语音派活：先补焦点，再决定是否独立面板

**用户收益：** 阅读输出或查看代码后，手柄能继续发起下一条需求，不必用鼠标找输入框。
现有 A 长按 / `B+A` 已触发豆包；要增加的是准确的去向和可检查的草稿。

#### G3-A. 在原 App 里完成输入（先做能力验证）

- 验证两个 App 的输入框聚焦方式，提供一个明确的「回到输入框」菜单动作。
  进入正确输入框后继续用原有豆包语音，文本仍留在目标 App 供用户检查，A 再发送。
- 不默认把所有全局语音入口都改成强行聚焦 agent：浏览器等 App 的现有语音用途仍需保留。
- 验收场景为「看变更 → 回输入框 → 说话 → 检查 → 发送」：全程无需鼠标，
  不覆盖已有草稿，不误触审批界面的 Enter；焦点定位失败时明确提示，不盲发后续输入。

#### G3-B. 独立语音草稿面板（仅在 G3-A 仍不足时投入）

```text
┌────────────────────────────────────┐
│ 草稿 → Codex · 修复登录             │
│                                    │
│ 帮我检查刚才的修改，并补充……        │
│                                    │
│ 语音键已按住 · 松开后检查           │
│ A 发送       B 返回并保留草稿       │
└────────────────────────────────────┘
```

- **与现有浮层不同：** 输入面板需要可编辑控件获得键盘/输入法焦点。应作为独立的输入模式，
  明确显示目标并管理进入/退出焦点，不能继续宣称它「永不抢焦点」。命令菜单与切换器仍不抢焦点。
- **A 的冲突必须先解决：** 同一时刻按下 A，无法预知用户稍后是松开还是继续按住。
  本模式若复用 A 轻按发送、长按语音，轻按应在松开且未达到长按阈值时判定；不能先发 Enter 再撤回。
  录音长按的结束只结束持有，不顺便发送。是否接受这个局部模式的延迟需原型体验确认。
- **投递能力 [未核实]：** 依赖 G1 的目标定位与 G3-A 的输入框定位。先确定已有草稿如何保留、
  文本如何转移、失败如何重试；若只能用剪贴板，原内容保留策略和失败结果需明确。
  成功注入文本不等于消息已发送，送达结果须有可观察依据，不能自动重试成两条消息。
- **验收：** 原输入框已有草稿、目标被切走、豆包未运行、转写尚未落字、发送失败时均不会丢草稿
  或误发。至少在一个已支持工具上跑通预览与发送，再考虑跨工具。
- 「解释选中内容 / 审查当前变更 / 总结任务」可作为后续模板，但必须明确传入的选区、文件或任务
  上下文；没有上下文获取能力时，只能叫文本模板，不能显示成已读取当前工作内容。

### 方向取舍

| 方向 | 增加的实际能力 | 主要依赖 | 建议 |
|---|---|---|---|
| G1 任务收藏/面板 | 直接回到某项工作，后续集中处理待办 | 具体任务定位；状态聚合另需可信来源 | 产品主线，先验证一个工具，不先做假状态卡片 |
| G2 四向操作盘 | 方向直选可见动作，减少列表浏览 | 现有 adapter 命令与浮层事件归属 | 短期原型，对照列表后决定是否默认启用 |
| G3-A 输入框定位 | 看完结果后继续语音派活 | 目标 App 的可靠聚焦方式 | 小范围实测，复用现有豆包与目标输入框 |
| G3-B 独立草稿面板 | 明确目标、检查转写、保留草稿后发送 | 可编辑焦点、定位与投递确认 | 条件投入，成本明显高于普通浮层 |

## 6. Review 范围与未完成项

本次仅修订本文：读取当前代码、路线图、已有验收记录与当次运行日志，核对 Apple 官方 API 文档。
未修改实现、未启动新的手柄真机实验、未执行发送消息/审批动作，也未完成上一轮计划中的全量代码
review。因此本文既不宣称新方案已验证，也不把原有验收记录扩展成新增功能的证据。

---

## 7. 执行计划（任务单）

> 2026-09-18 由 Claude 与 Codex 对照 HEAD `cded9a1` 工作树两轮讨论后整理。全部为静态分析：
> 未构建、未跑测试、未做手柄实验、未读取当次 debug.log。文中命令与试次表都是「开工后要做的事」。
> 规模口径：S ≈ 半天内，M ≈ 1–2 个工作日，L 应再拆。spike 的 time-box 是硬上限，到时交结论与证据缺口。

### 7.0 共用规则与验收方法

- **边界不变：** 六个实体输入、无震动；`B+←` 承担菜单及子页，`B 长按` 切换器，`B+A` 语音，B 轻按仍是
  `.cancelOrInterrupt`；不加双击、A 修饰层、第二修饰层；不为本计划新增持久配置项。
- **缺陷与新 UI 分开：** D-A / D-MENU / D-FOCUS / D-ENTRY 各自立单；静态风险不等于已复现缺陷。
- **每张实现单交付：** 作用范围、复现实例、定向测试结果、实际 UI 结果、剩余限制。测试通过 ≠ 实机通过；
  源码有日志语句 ≠ 已产生过日志。
- **定向测试：** 从仓库根目录跑 `swift test --filter <Suite>`；看退出码、实际运行用例与失败断言，
  不硬编码历史测试总数。只有遇到 `sandbox_apply: Operation not permitted` 才按 HANDOFF 用 `--disable-sandbox` 重试。
- **实机验收：** 用 `./scripts/make-agent-app.sh debug` 生成 `build/PocketAgentRemote.app`；先保存旧日志，
  经菜单退出旧实例再 `open`，不同时跑两份注入进程；不用裸 `swift run` 代替已签名 App。
- **日志口径：** `DebugLog.append` 格式是 `[启动后秒数] 标签 消息`。SEND 与多数 MENU 是 **OUTPUT 标签内的
  消息前缀**（`OUTPUT SEND …`、`OUTPUT MENU app switcher opened …`），筛选时标签 + 前缀一起看。
  激活失败文案是 `FOCUS … could not focus …`。每轮保存日志副本、SHA-256、App/系统版本、代码身份、
  有效 profile/override、目标 bundle ID、起始前台、运行程序集合与试次表。
- **计数口径：** ①每个实体键的 press 次数（`B+←` 记 2）；②用户完成一次组合手势的操作次数（`B+←` 记 1）。
  释放不算新操作，持续时间另记。G2 的「≤2 次」只指菜单已打开后的「方向 + A」，不含开菜单与进入「更多」。
- **成功判据：** `MenuEventResult` 的 `.executed/.activated` 不是成功证据（dispatcher 对失败也返回它们）；
  以 `AppActivationOutcome` / 失败通知 / 前台核验 / 目标 App 页面为准。

### 7.1 关键路径与依赖

```text
T0.1(预检 30–60 min) ─┬─► T0.3(菜单事件归属，小范围核对) ─► T1.1 F3 ─► T1.3 G2 原型 ─► T1.4 对照 spike
                     ├─► T0.2 D-A ──────────────────────┐        │
                     ├─► T0.4 D-FOCUS（不阻塞 F3）          ├─► T1.2 失败提示（可与 T1.3 并行）
                     └─► T0.5 D-ENTRY（不阻塞 F3）          ┘
T2.1 G1 定位 spike、T3.1 G3-A 聚焦 spike：只依赖 T0.1，可随时安排；不进入批次 1 关键路径。
TX.1 / TX.2：带启动条件的研究卡，不排进当前承诺。
```

到 T1.1 的**硬阻塞**只有：无法构建、无法建立相关测试基线、或菜单会话与绘制状态存在无法隔离的冲突。
未解决的 A 误发/卡键风险不阻塞 F3 编码，但阻塞受影响路径的**真实手柄验收**（可先用假输入验证）。
「独立推进」是依赖关系，不要求同时改共享文件；AppEnvironment 的改动分单落地。

**批次 0 门槛：** A/菜单输入归属没有未处置的误发或卡键；微信问题有复现/未复现结论与独立处置。
**批次 1 门槛：** F3 结构性证据通过；失败提示可见且不干扰菜单；G2 原型输入隔离通过后再做对照；
效率未改善就保留列表，F3 与失败提示仍可独立交付。

### 7.2 批次 0：确认基线

#### T0.1 固定可复核的基线与对照脚本 — S
- **目标：** 明确现有六键流程哪些已验证、哪些待核验；后续提速可与同条件结果比较。
- **涉及：** `DebugMonitor.swift` `DebugLog`；`RunningAppsTracker.runningApps(frontmostBundleID:)`；
  `AgentMenu.swift` `AppSwitcherBuilder.menu`；`Tests/…/TestSupport.swift` `ManualScheduler`；`scripts/make-agent-app.sh`。
- **步骤：** ①记录 HEAD、dirty 文件、有效配置；②重启前复制旧日志并算 hash，§0 那份若已不存在则标「不可重算」；
  ③跑 `GestureRecognizerTests / MenuFlowTests / EngineTests / DispatcherTests / AppSwitcherTests`，记真实结果；
  ④固定切换器目标集（上一个程序、两个 agent、前/中/末部），尽量复原 17 个程序，否则建新基线；
  ⑤固定 G2 对照动作（Codex 新建/变更/终端/模型；Claude 只纳入当前上下文可用的）并记录旧列表的最短路线；
  ⑥建逐次记录表：布局、动作、起止前台、开始/菜单出现/确认/结果可见时刻、实体 press、组合操作、取消、错选。
- **验收：** 五个 suite 有可检查输出，失败归入明确缺陷；记录表能区分「已发出快捷键」与「目标结果可见」；
  完整耗时起点为首个 B press、终点为结果可见，菜单内耗时另报。
- **依赖：** 无。真实基线采集依赖 T0.2/T0.3 的输入安全结论。开 T1.1 前只需 ①③ 与 `swift build`。
- **失败处理：** 测试红先进对应缺陷单；凑不齐 17 个程序就用新基线并声明，不跨集合算提升率。

#### T0.2 D-A：A 短按 / 长按 / 释放绑定 — M（定位 time-box 4 h）
- **目标：** A 长按语音不串发 Enter；短按提交时机准确可解释；切配置/前台后不残留语音键。
- **涉及：** `GestureRecognizer.swift` `handlePress/handleRelease/aHoldTimerFired/reset/hasNothingInFlight`；
  `ControllerEngine.swift` `triggers(for:)/syncGestureOverridesIfNeeded`；`GestureBindings.swift` `EventResolver`；
  `ActionDispatcher.emitRaw`；测试 `GestureRecognizerTests / MenuFlowTests / EngineTests / GestureOverrideTests`；HANDOFF §3.6。
- **已知静态事实：** 有 `a.hold` 时 A down 无输出、release 才发 Enter（`GestureRecognizer.swift:201–216`）；
  原 `testTappingAStillSubmitsImmediately`（现 `testTappingAIsStillAnApprovalSentOnRelease`）先 press 后 release 才断言，不证明按下瞬间提交；
  `hasNothingInFlight`（`:102`）不含 A；engine 只为 chord 冻结绑定表，`holdBegan/holdEnded` 不冻结。
- **步骤：** ①把实际语义与 HANDOFF/注释的「即时提交」歧义分开记账；②用 `ManualScheduler` 加时序断言：阈值前 1 ms、
  阈值时回调先/释放先、阈值后、重复 A press、reset、断连（事件 timestamp 不会自动推进 scheduler，要显式 `advance`）；
  ③加 A pending/holding 中 profile/override 变化、前台切换的用例；④确有缺陷只修起止配对、状态归属、重复 press 去重，
  不引入新手势、不先发 Enter 再撤回；⑤校正误导注释与验收描述。
- **验收：** SpyEmitter 证明短按 down 时零 Enter、release 后恰一对；长按仅 modifier down/up 配对且零 Enter；
  取消 pending 不提交；reset/配置切换后无未释放 modifier。实机短按/长按各 5 次，再检查下一次 B 长按与方向导航正常；
  在专用空白输入面验证，不在审批弹窗上用 Enter 探测。
- **依赖：** T0.1 ①③。
- **失败处理：** 稳定通过则关闭「串发 Enter」假设，只纠正文档；出现未配对释放/误 Enter 则阻塞新交互实机验收、先修。
  若产品要求「按下即提交」与「长按绝不提交」同时成立，记录为不可同时满足的决策点，不偷改六键契约。

#### T0.3 D-MENU：菜单关闭后的事件归属 — M（定位 time-box 4 h）
- **目标：** 开菜单、执行、返回、失焦后，旧按压不会变成后台 App 的 Enter/Escape/方向键。
- **涉及：** `ControllerEngine.swift` `start` 内 `coordinator.onEvent/dispatcher.onMenuChanged`、`openMenu/closeMenu`；
  `ActionDispatcher.swift` `handleMenuEvent/executeSelectedMenuItem`；`MenuOverlayController.hide/startWatchingFrontmostApp`；
  测试 `MenuFlowTests / EngineTests / AppSwitcherTests`。
- **步骤：** ①画出 `B down → ← down → menu open → ← up / B up` 的事件去向，确认打开动作不进选择/执行路径；
  ②FakeSource + 真实 recognizer/dispatcher + SpyEmitter 回放：B 先松、← 先松、B 未松时按方向/A、A 执行后才释放 B、
  B 关闭、失焦关闭、断连关闭；③关闭后注入旧 release 再注入新操作，分别断言「旧尾巴被消费」「新操作正常」，
  含 held direction 进菜单后释放；④对同步回调重入加专项断言：打开及每次选择变化触发的 reset 不得产生新 action；
  ⑤有失败才修最小状态路径，按「谁消费该次 press，谁结束该次 press」实现，不笼统丢弃所有 idle release。
- **验收：** 菜单导航零输出；执行仅目标 recipe 一次；关闭/旧 release 零新动作；清理 key-up 单独允许且配对。
  日志见 RAW 但菜单期间无 `SEND navigate*` / `SEND submit`。真机未做则标「假输入通过 / 真机待测」。
- **依赖：** T0.1 ①③；涉及 A 时与 T0.2 契约一致。**开 T1.1 前只需完成 ①** 及确认 F3 不改输入语义。
- **失败处理：** 泄漏可复现则单独修并回归原列表/strip，再开 G2；超时未复现则交覆盖矩阵，不标「已修复」。

#### T0.4 D-FOCUS：微信切换失败 spike — S（time-box 2 h）
- **目标：** 区分目标不存在 / 激活错误 / 前台核验超时；失败后仍能选其他程序。
- **涉及：** `AppActivator.swift` `activate/perform/waitUntilFocused`、`AppActivationReport.describe`；
  `ActionDispatcher.activateApp`；`AppEnvironment` `dispatcher.onActivation`；测试 `AppActivatorTests / AppSwitcherTests`。
- **步骤：** ①从真实 running app 记微信 bundle ID/PID/版本，保持原 methodOrder，不先调大 timeout；
  ②在已签名 App 内按现有路径从同一起始 App 切微信 5 次，有条件再测隐藏/最小化；
  ③每次记各 attempt 的 method/elapsedMs/reason 与前后前台 ID（当前失败摘要不含每次耗时，可加局部诊断采样）；
  ④失败时核对 bundle ID 是否仍在运行、AppleScript error、请求接受但目标未出现；用 Codex/Claude 做对照；
  ⑤可复现原因独立修复或记外部前置条件，再测 5 次；验证失败后重开切换器可选别的 App 且零键盘输出。
- **验收：** 成功须同时有 `FOCUS openAppSwitcher: focused <bundleID> via <method> in <ms>` 与前台核验；
  失败匹配 `could not focus`；`.activated(bundleID:)` 不是成功依据。输出逐试次矩阵与本机适用范围。
- **依赖：** T0.1；不阻塞 T1.1。
- **决策规则：** 稳定复现且定位到本程序原因 → 另开最小修复；否则搁置激活算法改动，保留「未复现/外部限制」，
  由 T1.2 提供失败说明与重新选择。不自动重复激活、不扩大授权、不宣称路径稳定。

#### T0.5 D-ENTRY：菜单栏入口的前台接线 — S（time-box 1 h）
- **目标：** 菜单栏打开的菜单与手柄打开的作用于同一前台，失焦都能正确关闭。
- **已知静态事实：** `ControllerEngine.frontmost`（`:80`）在 `AppEnvironment` 的 init/wire 中未赋值，
  `MenuFlowTests.makeRig` 却显式赋值；手势路径的 dispatcher 自己读前台（`ActionDispatcher.swift:312`）。
- **涉及：** `AppEnvironment.swift` `init/wire/showControllerMenu/showAppSwitcher`；`ControllerEngine.frontmost/openMenu/openAppSwitcher`；
  测试 `MenuFlowTests.makeRig / EngineTests`。
- **步骤：** ①确认接线差异；②加同一前台经菜单栏 open 与手势 open 的对照断言（bundleID、标题、选中项、执行前 guard）；
  ③在 AppEnvironment 最小接入已有 `frontmostObserver`，不借此改排序或浮层；
  ④实机分别从 Codex、Claude、浏览器用菜单栏开菜单/切换器，切前台确认旧菜单消失、未知目标不发命令。
- **验收：** Core 回归证明非 nil 前台被转交；App 层另做真实 wiring 验证（`Package.swift` 只有 CoreTests，Core 绿不等于接线已覆盖）。
  日志 `opened for ?` 不应出现在已知前台的入口；auto + 浏览器不提供 agent 命令；strip 的 A 不因 `session.bundleID` 为 nil 被拒。
- **依赖：** T0.1；不阻塞 T1.1，放行真实 UI 前需过 T0.3。
- **失败处理：** 若实际存在未读到的赋值点则撤销结论并记出处；否则独立修复，不以菜单栏入口坏掉为由绕过 App 层验收。

### 7.3 批次 1：操作更快且看得到结果

顺序：T1.1 → T1.3（T1.2 可与 T1.3 并行）→ T1.4。

#### T1.1 F3：选择更新只刷新高亮 — M
- **目标：** 切换器和命令列表移动选择时不重建内容，日志清楚区分打开与执行/关闭。
- **涉及：** `AppEnvironment.swift:150` 起的 `engine.onMenuChanged` 闭包（`:153` 记 `open for`，`:154` 调 show）、`overlay.onDismiss`；
  `MenuOverlayController.swift` `show(:59 重建)/render/rebuildContent/startWatchingFrontmostApp(:64)/hide`，`:273` 每次先停旧 timer；
  `ActionDispatcher` 菜单生命周期日志；`AgentMenu.swift` `AgentMenu/MenuItem`。
- **步骤：** ①定结构比较键：bundleID、title、layout、完整有序 items（choice + title），G2 后加 page/slot/可用态；selection 不纳入；
  ②可见且结构相同 → `render`；首次打开/重开/结构变化 → `show`；nil → `hide`；条目数相同但 action/标题不同也必须重建；
  ③同会话保留 pollTimer，结构变化仍校正监听目标，关闭后取消；保留 `onStatusChange` 所需状态更新；
  ④删除每次绘制的 `MENU open for …`，由生命周期事件记 opened/running/switching/closed（含 B、失焦、断连、选择当前 App、子页返回）；
  ⑤用**临时诊断计数**（拟新增探针，非现有日志）验证 rebuild/timer 创建次数，不变成用户配置。
- **验收：** `swift build` + `MenuFlowTests / AgentMenuTests / AppSwitcherTests`。打开 17 项 strip 后连按 50 次方向：
  `rebuild=1`、timer 创建 1 次，移动阶段二者不增长；顺序固定，首次高亮仍为上一 App；同数量异内容/标题/layout/bundleID 必须刷新；
  hide 后重开恢复。一次无子页完整切换 MENU 标签 + OUTPUT 内 MENU 前缀合计 ≤3 行，无 `open for` 噪声。现场观察无可感延迟；耗时待测。
- **依赖：** T0.1 ①③、T0.3 ①。
- **失败处理：** 旧标题/旧 target/timer 失效先修比较键与生命周期；单一路径不稳定就回到该路径原 show 行为并标 F3 未完成，
  不连带回退输入修复。卡顿仍在则记各阶段耗时，不立即扩展 F1/F4。

#### T1.2 最小失败提示：补齐失败事件后再显示 — M
- **目标：** 用户看到被拦截、不支持或切换失败的原因，并能继续操作菜单或重新选择程序。
- **已知静态事实：** 菜单前台变更（`ActionDispatcher.swift:147`）、无 activator（`:172`）、空目标（`:261`）、无可开菜单（`:372`）
  只走 `onDiagnostic`；`AppEnvironment.wire`（`:91`）未订阅 `onEmitted`；`:226` 手动激活绕过 `onActivation`；
  `onEmitted` 无 phase，`CGEventEmitter` 仅异步入队、无成功回执。
- **涉及：** `ActionDispatcher.swift` `onDenied/onUnsupported/onActivation`、`executeSelectedMenuItem/activateApp/performFocus/dispatch`；
  `AppEnvironment.swift` `wire/focusOtherAgentNow/showControllerMenu/showAppSwitcher`；`MenuOverlayController.makePanel`（只参考 panel 属性）；
  `AppActivator.swift` `AppActivationOutcome/Report`；测试 `DispatcherTests / AppSwitcherTests`。
- **步骤：** ①列失败出口，给只走 diagnostic 的出口补结构化通知，优先复用 onDenied/onUnsupported，避免同一事件通知两次；
  ②AppEnvironment 转成中文短提示（目标 + 原因）；手动 `focusOtherAgentNow` 也接同一显示方法；本批不做每次 SEND toast；
  ③独立 non-activating toast panel + 独立 timer + generation 管过期；不复用菜单 panel 的内容/显示状态/menuSession；
  ④失败/拒绝至少保留 3 s 后到期；新消息替换旧消息并重置到期；**不接管任何手柄事件、不加关闭手势**；
  ⑤用 mock 激活失败与 denied/unsupported 回调驱动 UI；再在手动 profile + 白名单外 App 触发一次真实 DENY。
- **验收：** `DispatcherTests / AppSwitcherTests` 每个失败用例恰一个通知、零键盘输出；菜单前台变化用例能进入提示。
  GUI：原因可读、≥3 s；toast 出现前/显示中/刚过期各按 B，输出与无 toast 时一致；到期只隐藏 toast，不能关闭菜单；
  菜单打开期间旧 toast 到期菜单仍在、选择/A 正常。模拟失败可完成通用验收，但不能宣称微信已修复。
- **依赖：** T0.2/T0.3 的输入结论；真实入口检查依赖 T0.5；T0.4 只提供分类。可与 T1.3 并行。
- **失败处理：** toast 抢焦点/吞组合键/关闭菜单 → 撤下显示原型，保留已验证的失败事件与日志修复；不用新全局键或永久 HUD 配置绕过。

#### T1.3 G2 Codex 四向操作盘对照原型 — M（实施 time-box 1.5 日）
- **目标：** Codex 常用动作可方向直选；「更多」B 返回；打开菜单不误选左槽、不误执行；原列表完整保留可对照。
- **范围固定：** 只做 Codex 一个 profile；↑新建 ←变更 ↓终端 →更多；「更多」用现有竖向列表承载模型/归档；Claude 保持原状。
- **已知静态事实：** `AgentMenu.swift:9` 只有 run/activateApp、`:65` 只有 list/strip、`:78` 默认 selection=0；
  `ActionDispatcher.swift:115` B 直接关闭、`:133` selectedItem nil 也关闭；`AgentMenuBuilder`（`:147`）只判 recipe 非 nil，不查目标 App 当前 enabled。
- **涉及：** `AgentMenu.swift` `MenuChoice/Layout/selection/selectedItem/AgentMenuBuilder.menu`；`ActionDispatcher.swift` `MenuSession/handleMenuEvent/executeSelectedMenuItem`；
  `MenuOverlayController.swift` `rebuildContent/render/position`；`AppEnvironment`/`MenuBarController.menuNeedsUpdate(_:)` 接线；
  `CodexDesktopAdapter.menuItems/support(for:)`；`ToolAdapter.primaryStroke`。
- **步骤：** ①菜单模型/dispatcher 加根盘与「更多」两页的最小状态：初开无选中、方向选槽、A 执行、B 子页返回/根页关闭，不建通用导航栈；
  ②`MenuOverlayController` 用文字标签 + 高亮画四向位置，更多复用列表；保留目标标题与操作提示，接入 T1.1 的结构刷新判断；
  ③仅加一个开发态、进程内的列表/原型切换入口（菜单栏诊断项），试次开始前选好；不占手柄键、不持久化；
  ④动作走既有 adapter + guard + 前台重检；App 切换关闭整个菜单树；
  ⑤定向测试：两种 opening release 次序、未松 B 导航、A 长持有不重复且释放不触发语音、更多往返零 Escape、空槽 A 不执行、失焦拒绝、执行恰一次、旧 strip 不受影响；
  Codex 打开终端的 SpyEmitter 须匹配实际 `.grave + .control`；
  ⑥实机只验读得清、不抢焦点、不裁切、输入不泄漏，即进入 T1.4。
- **砍掉：** Claude 方向盘、动态可用态检测、快捷键副标题、SF Symbols/App 图标、展示元数据体系、主题/缩放/动画、通用子页系统。
- **不能砍：** opening chord 完整消费、无默认执行、前台归属、A 不重复、B 返回语义、更多动作可达、旧列表对照入口。
- **验收：** `AgentMenuTests / MenuFlowTests / DispatcherTests / AppSwitcherTests / AdapterTests` 覆盖上述断言。
  实机：直接槽从出现起「方向 + A」两次完成；模型路径为 → A 列表选择 A，不算直接槽；重复方向不增加 T1.1 的重建计数。
- **依赖：** T1.1；T0.2/T0.3 输入风险可控。失败路由复用 T1.2，但 T1.2 不是编码硬依赖。
- **失败处理：** 模型要泛化成复杂框架 → 缩回根盘 + 更多一层；输入隔离失败 → 停在原列表；不靠删「更多」、改组合键或放宽误发标准压工期。

#### T1.4 G2 对照验证 spike：决定默认布局 — S（time-box 3 h）
- **目标：** 常用动作完整操作成本实际下降，默认布局有测量依据。
- **步骤：** ①先定动作、频率权重、判据；无频率样本只做等权探索，不宣称总效率提升；
  ②Codex 新建/变更/终端/模型各在列表与原型执行 5 次（共 40），AB/BA 交错，练习轮不计，每轮恢复同一初始页面与焦点；
  ③「模型」标记为更多子页路径；归档只用可丢弃测试会话；④逐轮填 T0.1 的记录表，结果可见以 App 页面为准，失败/取消不删；
  ⑤Claude 动作集不足就记「不足」，不编造；⑥汇总每动作中位耗时、实体键数、组合操作数、错选/返回次数，再按频率加权。
- **决策规则（待测阈值，只支持本人这组任务的默认选择）：** 所有直接槽满足方向 + A ≤2 次且零后台误输入；加权耗时至少降 15%、
  错选不增加、最高频「新建」中位耗时恶化不超过 10%，且远距可读 → 候选默认启用；否则保留列表，收起或保留开发态切换。
  F1 的「30%」不套用于本实验。
- **依赖：** T1.1–T1.3；T0.1 ④⑤⑥。
- **失败处理：** 新建多一步导致明显变慢 → 列表默认；不用新增直执行、双击或改 B+A 挽救指标。样本不足就交「不足以决定」。

### 7.4 批次 2：G1 任务定位 spike

#### T2.1 每工具任务定位判定 — S（总 time-box 4 h，每工具 ≤2 h）
- **目标：** 证明至少一个工具能准确打开两个指定任务，而不是只把程序带到前台。
- **现状：** 只有 App 级激活（`AppActivator.activate`）、`CodexDesktopAdapter` 的 `goToRecentChat1…6` recipes；无任务定位函数、无收藏数据模型。
  `Tools/dump-menu-accelerators.swift` 只证明菜单状态，不证明任务定位。
- **步骤：** ①每工具选两个用户指定测试任务，记可区分身份的证据、App 版本；不扫聊天数据库、不以窗口标题充当 ID；
  ②各 30 分钟查公开分享/定位入口、官方说明、本机菜单，再限时验证一个最有希望的方法；
  ③任务 A/B 各连续定位 5 次，每次先离开目标任务；补交替、改最近会话顺序、从浏览器起步、多窗口用例；不发消息；
  ④检查落点身份而非 FOCUS；近期序号随顺序变动即不能当收藏标识；⑤测无效链接、可丢弃任务删除后、App 未运行；
  ⑥纸面估算未来 `B+← → 更多 → 我的任务 → 选择 → A` 的成本与原「切 App + 找会话」对比；不做收藏 UI。
- **验收：** 能力矩阵：工具/版本、定位方法、身份依据、两任务各 5 次结果、坏目标/未运行表现、操作成本。
- **决策规则：** 至少一个工具两任务各 5/5 正确、不发消息、异常目标有明确结果、成本有下降空间 → 该工具「可进入下一轮收藏计划」；
  否则搁置任务收藏；只能激活程序就只称「仅打开程序」。本轮不拆收藏实现、状态聚合或面板 UI。
- **依赖：** T0.1；借用激活路径时参考 T0.4 的失败分类。

### 7.5 批次 3：G3-A 输入框聚焦 spike

#### T3.1 从查看结果回到正确输入框 — S（总 time-box 4 h，每工具 ≤2 h）
- **目标：** 看完变更后无鼠标回到当前任务输入框，保留旧草稿，检查语音文本后再决定发送。
- **现状：** 无 composer-focus action；App 激活 ≠ 输入框聚焦；现有全局语音入口作用域不变。
- **步骤：** ①每工具一个专用测试任务，准备五类起点：空输入框、已有草稿且部分选中、变更视图、终端/侧栏、审批模态；
  ②先查真实菜单/快捷键，再查可验证的 AX 焦点路径；每工具最多验证一个主要候选；不猜固定 Tab 次数；
  ③只执行聚焦，读取 focused element 是否为目标任务的可编辑 composer；仅 bundle ID 正确不算通过；
  ④目标被切走、焦点不可读、审批模态时验证候选方法明确失败、不继续输入；不得用 Enter 试探；
  ⑤聚焦可靠后在测试任务验证 `A 长按 / B+A` 豆包流程：文本落到 composer、先检查再由人按 A；旧草稿被替换即失败；
  ⑥支持的一侧跑 5 次「看变更 → 聚焦 → 说话 → 检查 → 手动发送」，另测豆包未运行/尚未落字。
- **验收：** 焦点/草稿前后证据与逐次表；「聚焦能力通过」与「完整语音流程通过」分开标；`SEND rightOption` 只说明注入请求。
  靠鼠标挽救的试次不算通过。
- **决策规则：** 至少一个工具可靠聚焦正确 composer、保留草稿、模态/错误目标能阻断、5 次闭环成功 → 出「可另排回到输入框菜单动作」结论；
  否则搁置该工具集成，继续原有语音方式。失败不直接导向 G3-B 实现。
- **依赖：** T0.2；不强依赖 G1。要宣称「从任意 App 到指定任务派活」还须 T2.1 对该工具通过。

### 7.6 带启动条件的研究卡（不排进当前承诺）

#### TX.1 F2 窗口 API 权限/字段 spike — S（time-box 90 min）
- **启动条件：** 出现确定的多屏定位需求（U1.2）或 MRU 方案不足。当前无 `CGWindowListCopyWindowInfo` 调用点。
- **步骤：** 限定真正需要的字段（PID、bounds，不默认要窗口标题）→ 以实际 App 身份、无 Screen Recording 权限用临时只读探针查询
  → 普通/最小化/隐藏/不同 Space/多窗口各测一次并与 `NSWorkspace.runningApplications` 对照 → 写字段/权限/降级结论，删探针。
- **决策规则：** 所需字段在目标权限状态下稳定可见 → 只建议其已验证用途；否则搁置窗口 API 路线。无论如何不把窗口层序称为系统 MRU，
  不进方向更新热路径，运行 App 不因缺窗口被剔除。

#### TX.2 G3-B 投递能力 spike — S（time-box 2 h）
- **启动条件（须同时满足）：** T2.1 与 T3.1 对同一工具通过，且原输入框流程仍有具体可复现痛点。否则只登记不开工。
- **现状：** dispatcher 只提取 `primaryStroke`；`OutputStep` 有 `.text` 类型不等于已实现文本投递。
- **步骤：** 专用任务用无副作用测试文本验证一个可观测转移办法，记旧草稿/目标身份/焦点前后；若只能用剪贴板，验证原内容保留与粘贴失败后草稿保留，
  不覆盖用户新剪贴板来「恢复」；「已注入」与「已发送」分开验证；结果未知时保持可恢复、不自动再发。
- **决策规则：** 转移、保留、错误目标阻断、结果判定均可验证 → 才允许未来另写 G3-B 产品计划；否则搁置独立草稿面板，保留 G3-A。
  本卡不授权 editable panel、收藏 UI 或发送实现。

### 7.7 已核对的路线图与代码差异

正文中 F3、F5、U1.4、U3.1、U3.2、G2 的措辞已按下表修正；其余项留在对应任务单处理。

| # | 描述 | 代码事实（文件:行） | 落到 |
|---|---|---|---|
| 1 | HANDOFF §3.6 与 `GestureRecognizer.swift:60` 注释说 A 按下即发 Enter | 有 `a.hold` 时 `:201` 返回空，`:209–216` release 才发 Enter | T0.2 |
| 2 | `testTappingAStillSubmitsImmediately`（T0.2 后改名 `testTappingAIsStillAnApprovalSentOnRelease`）看似证明即时提交 | `MenuFlowTests.swift:274–283` 先 press 后 release 才断言 | T0.2 |
| 3 | F3 写成 `AppEnvironment.onMenuChanged`、只比较 `items` | 实为 `AppEnvironment.swift:150` 的 `engine.onMenuChanged` 闭包；比较键需含 bundleID/title/layout | 已改正文；T1.1 |
| 4 | §0 说绘制回调可由非导航输入触发 | `ActionDispatcher.swift:99` release 直接 handled，`:120` 非导航键直接返回；只有导航到 `:126` | 已改正文 |
| 5 | MENU/SEND 被当作独立日志标签 | `AppEnvironment.swift:110` 把 diagnostic 全记 OUTPUT；`ActionDispatcher.swift:218/235/446` 是消息内前缀；失败文案 `AppActivator.swift:255` | 已改正文；7.0 |
| 6 | F5 说四个回调已足够 | `ActionDispatcher.swift:147/172/261/372` 只走 onDiagnostic；`AppEnvironment.swift:91` 未订阅 onEmitted，`:226` 绕过 onActivation | 已改正文；T1.2 |
| 7 | 「已发送」/「实际按住」当作强证据 | `ActionDispatcher.swift:20` 的 `onEmitted` 无 phase，`:286` 调 emitter 即通知；`CGEventEmitter.swift:77–86` 仅异步入队、`:26–29` 可静默失败 | 已改正文；F7 后续 |
| 8 | G2 只是换视图 | `AgentMenu.swift:9/65/78` 无「无选择」与子页；`ActionDispatcher.swift:115/133` B 与 nil 选项都直接关闭 | T1.3 |
| 9 | U1.4 说图标/快捷键数据已在 recipe 里 | `ToolAdapter.swift:34/61` 只有 action/title/按键；`AgentMenu.swift:15/148` 丢弃展示信息 | 已改正文 |
| 10 | G2 复用「已验证命令」可推出 Claude 三项可用 | `ClaudeDesktopAdapter.swift:25/30` 普通 chat 下两项 OFF 仍列出；`AgentMenu.swift:147` 只判 recipe 非 nil | 已改正文；T1.3 |
| 11 | `MenuEventResult` 被当成功证据 | `ActionDispatcher.swift:173/178/197` 无论成败都返回 activated/executed；真实核验在 `AppActivator.swift:163/235` | 7.0 |
| 12 | 菜单栏入口与手柄入口接线差异未覆盖 | `ControllerEngine.swift:80` 的 `frontmost` 在 `AppEnvironment` 未赋值；`MenuFlowTests.swift:86` 赋值 | T0.5 |
| 13 | F7 要求切 App 后显示与持有一致 | `ControllerEngine.swift:249/255` 只为 chord 冻结；`GestureBindings.swift:224/225` 支持 hold；`hasNothingInFlight` 漏 A | T0.2 |

补充：`RunningAppsTracker` 确为进程内激活历史 + 未观察项系统枚举顺序（`:14/:59`），只列 `.regular`、有 bundle ID 的运行 App（`:51`），
无窗口可见性筛选；`AppSwitcherBuilder.menu` 固定初选 index 1（`AgentMenu.swift:182`），「上一个」只相对这份已观察历史。
HANDOFF §8「未验证」标题下前两项正文已注明实机通过（`HANDOFF.md:405–411`），按条目读，其结论不扩展到 G2/HUD/A 配置切换。

### 7.8 可立即派发的最小顺序

> **2026-09-18 实施状态**：T0.1、T0.2、T0.3、T0.5、T1.1、T1.2、T1.3 已实现并通过单测（279 用例全绿），
> 全部为假输入/静态核对，未接真手柄；实机验收步骤与 T0.4 / T1.4 / T2.1 / T3.1 的实机 spike 见 `docs/test-manual.md`。
> T0.2 查出并修复 4 个真实缺陷（重复 A press、长按中 override 变化导致右 ⌥ 卡键）；T0.5 查出菜单栏两个入口此前不可用。
> `OVERLAY` / `TOAST` 日志行与 `rebuildCount` 等探针为临时，实机验收后删除。


1. T0.1 ①③ + T0.3 ① 预检（30–60 min）→ 开 T1.1。
2. D-A / D-MENU / D-FOCUS / D-ENTRY 四张缺陷单独立推进，谁先出结论谁先落地。
3. T1.1 通过 → T1.3 原型；T1.2 并行。
4. T1.4 对照决定默认布局。
5. T2.1、T3.1 只交能力矩阵，随时可排；TX.1/TX.2 等启动条件。
