# IINE L1162 → macOS Codex 桌面 App / Claude 桌面 App 遥控器
## Implementation Spec v0.3

> **Status: Draft for implementation（待人类拍板项见 §26，未拍板前不要进入 Phase 3）**
> **Last updated: 2026-09-15**
> Target: macOS native menu-bar utility
> Hardware: IINE 良值 L1162 迷你控制器（实测设备，见 `docs/hardware-probe.md`）
> Primary targets: **Codex 桌面 App**（`/Applications/ChatGPT.app`，bundle id `com.openai.codex`）与 **Claude 桌面 App**（`/Applications/Claude.app`，bundle id `com.anthropic.claudefordesktop`）
> Primary interaction model: controller input → gesture → semantic action → **desktop-app adapter** → menu click / key injection

**v0.3 = v0.2 + Codex Micro 对标调研的整合 + 语义动作集重定 + 三处结论修正。**

**证据等级图例**（全文统一，每个关键结论后括号标注来源）

| 标记 | 含义 |
|---|---|
| **实测验证** | 本次项目在本机跑命令/跑探针并看到输出（`docs/hardware-probe.md`、`docs/phase0-summary.md`、三份 research 里标 `【实测】` 的部分） |
| **静态推断** | 从 app.asar / 二进制 / 注册表 / 配置结构中读出，**未做端到端运行验证**（research 里标 `【代码】` / `【静态】` / `【推断】` 的部分） |
| **未验证** | 只有线索，本次刻意未验证；全部集中在 §9 |

⚠️ **本文档不引入任何未被下列六份输入文档覆盖的结论。** 凡是输入文档没查到的，本文档一律写「未验证」并给出验证它的副作用，而不是补全。

**v0.3 新增的输入文档**：`docs/research-codex-micro-mapping.md`（Codex Micro 对标调研，本版的核心新材料）。

⚠️ **关于证据等级的一条重要读表须知**（沿用 v0.2，本版更关键）：
**「实测验证」指的是「该键位/该命令/该常量确实存在」已实测，不是「按下去有预期效果」。** 后者对两个 App 的几乎所有格子仍然是【未验证】（§9 U6）。本版的「A/B/C/D 分类」说的全部是**可达性**（键位或面板入口是否存在），不是**行为正确性**。

---

## 0. 本版相对 v0.2 的变更摘要

### 0.1 一句话

**语义动作层的词汇表按 Codex 自己的物理键动作集重定；可行性结论从「怎么把 L1162 伪装成 Codex Micro」收敛为「L1162 永远不可能被识别为 Codex Micro，但 33 个动作全部可达」。**

### 0.2 保留（v0.2 的设计仍然成立，不做改动）

| v0.2 位置 | 内容 | 结论 |
|---|---|---|
| §3 | Phase 0 的 7 条硬性约束（C1–C7）+ 2 条附带禁令 | **逐字保留**，这是硬件的唯一事实来源 |
| §4 | T / C / H × 每档两变体、IOHIDManager 是一级输入源 | 保留 |
| §5 | 语义动作层（物理输入 → 手势 → 语义动作 → adapter → delivery tier） | 保留（本版只换词汇表，不换分层） |
| §7.2 的 Claude 行 | Claude 桌面 App 的键位与缺口 | 保留；本版**没有**对 Claude 重新调研（见 §7.2 的范围声明） |
| §11 / §12 / §13 / §15 | 三级守卫、分层架构、安全模型、输入输出实现要点 | 保留，仅同步新的动作名 |
| §18 | 手势状态机（B 作为 modifier） | 保留；B hold 的语义明确为与 B tap 相同的动作（§6.4） |
| §20 | 测试策略 | 保留，测试用例同步新映射 |
| §22 | 实施阶段划分 | 保留骨架，Phase 5 内容更新 |
| §23 | 「不得在没有证据的情况下更改的决策」 | 保留，新增 4 条、改写 2 条（§23） |
| §24 / §25 | 来源索引、人类拍板清单 | 保留，扩写 |

### 0.3 修正（v0.2 此处有误，v0.3 修正）

| # | v0.2 的说法 | v0.3 的修正 | 来源 |
|---|---|---|---|
| **F1** | `⌘K` 命令面板可当作「没有默认键位的命令」的兜底通道（§6.2 / §8 G3 的 D3-a） | **命令面板确实存在**（`openCommandMenu` = `⌘K` / `⌘⇧P`），但**只收录 63/131 条命令**（`kind === 'webview' && commandMenu === true`）。**不能**再把「有 i18n 标题」当成「面板里一定有」 | research-codex-micro-mapping.md §2.1 / §5.1，实测验证 |
| **F2** | `toggleFastMode`「只能 `⌘K` 命令面板或点 UI」（§7.1 行 9、§8 G3） | **`toggleFastMode` 不在命令面板里**：它的 i18n 描述是 `Shortcut settings row for toggling Fast mode`（面板项的措辞是 `Command menu item to …`）。正解是 **C 类：用户在 Settings → Keyboard Shortcuts 里绑一次键** | research-codex-micro-mapping.md §2.2 / §2.3，实测验证 |
| **F3** | 未说明 `browser.defaultKeybindings` 的适用范围 | **`browser.defaultKeybindings` 在桌面 App 不生效**：只有 `windowType !== 'electron'` 才查 browser 段。因此 `⌘U`（`composer.addFiles`）与 `⌘K`（`searchChats`）在桌面 App 上**无效**。凡是只在 browser 段出现的键位，一律视为「无默认键位」 | research-codex-micro-mapping.md §2.1 路径 ①，实测验证 |
| **F4** | `queueFollowUp` 在 Codex 侧「⚠️ 运行中 `Enter`（未验证）」（§7.1 行 7），并在 §8 把它归入「缺口」 | **升级为「绑一次键即可用」**：`composer.queue` 与 `composer.steer` 是**真实命令且有处理器**，注册表无默认键位，可在 Settings → Keyboard Shortcuts 绑一次键后用按键注入直接触发；「运行中 `Enter`」是另一条天然路径（受 `followUpQueueMode = "queue"` 控制）。两种落地都是 A/C 类可达，**不再是缺口** | research-codex-desktop.md §4.4 / §5.4；research-codex-micro-mapping.md §2.2 注 `CODEX`、§4.1 |
| **F5** | `cyclePermissionMode` 作为动作名（§6.2 / §7.1 行 8 / §14.4） | **重命名为 `openPermissionModeMenu`**。Codex 桌面 App 完全没有权限模式动作（Micro 的 33 条动作清单是第三条独立证据），Claude 侧也只有「打开菜单 + 数字选择」、没有循环语义。**并禁止在 Codex profile 下静默替换成 `approve`** | research-codex-micro-mapping.md §4.3；research-codex-desktop.md §5.5；research-claude-desktop.md §4.2 / §7.1 |
| **F6** | §7.1 把 `approval.approve` / `approval.decline` 当作「Codex 额外的可用动作」 | **不新增 `approve` / `reject` 两个语义动作**：它们的默认键就是 `Enter` / `Escape`，与 `submit` / `cancelOrInterrupt` **完全相同**。明文规定「`submit` 在审批弹层里即 approve，`cancelOrInterrupt` 即 reject」（§14.4 给出决定与理由） | research-codex-micro-mapping.md §2.2（`APPR`/`REJ` 键帽）；research-codex-desktop.md §5.2 |
| **F7** | §6.2 的 B 层映射（B+↑ = `cyclePermissionMode`、B+↓ = `toggleFastMode`） | **替换为新的默认映射**（§6.2）：B+↑ = `newChat`、B+↓ = `openTerminal`、B+← = `openModelPicker`、B+→ = `queueFollowUp`、B+A = `inspectChanges`。`toggleFastMode` 与 `openPermissionModeMenu` **退出默认绑定**，成为可选未绑定动作 | 用户拍板；§23 决策 8 |
| **F8** | `submit` 在 Codex 的实现表述为「✅ `Enter`（`composer.submit`，受 `composerEnterBehavior` 控制）」 | 更准确的表述：**`composer.submit` 在命令注册表里没有默认键位**，它是以 `n0('composer.submit', handler, {enabled})` 注册的处理器；composer 聚焦时的回车提交是**组件内部逻辑**而不是注册表键位。行为仍然可用，但它是**B 类（无默认键位）**，不能写成「有默认键位」 | research-codex-micro-mapping.md §2.2 注 `CODEX`，实测验证 + 该文档 §5.4 未验证项 3 |

### 0.4 新增（本版独有章节 / 表格）

| 位置 | 内容 | 为什么必须有 |
|---|---|---|
| §5.1 | **可行性判定：L1162 不可能被当作 Codex Micro 接受**（硬件级三重硬过滤 + 5 条被否掉的伪造路径） | 这是本版最硬的一条结论，必须一次写死，禁止后续再试 |
| §5.2 | **33 个 `keycaps.*` 动作的逐条可达性表**（A/B/C/D 四类 + 证据等级） | 证明「动作层完全可以对齐」，并把 v0.2 的兜底假设换成真实可达路径 |
| §5.3 | **复刻不了的体验清单**（RGB / 摇杆 / 旋钮 / 按线程绑定 / 单双击 / PTT / 设备状态 UI） | 防止把「被识别为 Micro」和「对齐 Micro 动作」混为一谈 |
| §5.4 | **可复刻的体验清单** | 明确本项目的价值主张边界 |
| §6.3 / §6.5 | **可选未绑定动作**与**需一次性绑键的动作**两张表 | v0.2 只有「默认映射」一个概念；本版必须区分「默认绑定」与「可选未绑定」 |
| §14.4 | 新的 `AgentAction`（17 个）与 `approve`/`reject` 合并的书面决定 | 扩充语义动作集是用户已拍板的方向 |
| §26 | 新增 3 项待拍板（Q15–Q17） | 新结论带来新的取舍 |

### 0.5 本版最重要的一句结论

**L1162 永远不可能被 Codex 认成 Codex Micro —— 但这不是坏消息。** 设备发现走的是原生插件 `hid-topology-watcher.node` 里硬编码的 `VendorID = 0x303A` + `ProductID ∈ {0x8360, 0x8297, 0x8298}` + `usagePage = 0xFF00` 三重 AND 过滤（来源: research-codex-micro-mapping.md §1.1，实测验证），而这三项在 L1162 上全部锁在固件里、不可改。与此同时，**Codex Micro 的 33 个可分配动作在外部 100% 可达**（11 条默认键位 / 8 条命令面板 / 9 条绑一次键 / 5 条文本或 URL，0 条不可达，来源: 同文档 §2.3，实测验证）。因此本项目的路线不变：**L1162 → 我们的 Swift App → CGEvent 键盘注入 → Codex 公开命令体系**。被识别的路走不通，动作的路完全走得通。

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
Semantic Agent Actions（v0.3：17 个，按 Codex Micro 的动作清单重定）
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

最终用户应该能够单手完成最常见的操作（v0.3 的可达清单以 §5.2 / §6.2 为准）：

- 上下左右导航（4 个方向）
- Submit / Confirm（在审批弹层里即 approve）
- Cancel / Interrupt（在审批弹层里即 reject）
- Queue follow-up（运行中入队）
- 新建会话 / 打开终端 / 打开侧聊 / 归档 / 置顶 / 分叉
- 打开 model picker
- 查看 diff / changes
- （可选未绑定）切换 fast mode、打开权限模式菜单
- 在两个目标 App 之间切换

---

## 2. 非目标

v0.3 不做：

- 修改 L1162 固件
- USB/Bluetooth 协议逆向（Phase 0 已证明 GameController + IOHIDManager 足够读出 6 个输入）
- **让 L1162 被 Codex 识别为 Codex Micro**（本版已给出**不可行**的硬件级结论，见 §5.1；5 条伪造路径全部否决）
- **实现 Work Louder / Codex Micro 的私有协议**（`AG00`–`AG05`、`ACT06`–`ACT12`、`ENC_CW`/`ENC_CC`、JSON-RPC over HID）
- kernel extension、root 权限、DriverKit、`IOHIDUserDevice`（需要 `com.apple.developer.hid.virtual.device` 受限 entitlement，本项目拿不到）
- 自动执行危险 shell command
- 自动开启 `--dangerously-skip-permissions` / bypass 权限模式
- **实现或依赖 Codex TUI / Claude Code CLI 的 keymap**（CLI 路线在 v0.2 中已彻底移除，本版延续）
- **依赖 `~/.codex/ipc/ipc.sock`**（能力未验证，见 §10 风险 R3）
- **依赖 Anthropic 内置的蓝牙硬件伴侣（`hardwareBuddyEnabled` / `buddy-ble`）**，仅作为干扰源登记（§10 风险 R1）
- 读取会话内容做「智能判断」（需要 AX 状态读取，是后续议题，见 §22 Phase 5）
- 网络服务、账号登录、云同步
- 支持 T 档（多媒体触控）与 H 档作为主路径
- **对 Claude 桌面 App 扩充动作集**（本版新增的 6 个语义动作只在 Codex 侧有调研证据，Claude 侧一律标【未验证】，见 §7.2 范围声明）

---

## 3. Phase 0 硬件实测约束（硬性，7 条）

以下 7 条来自 `docs/phase0-summary.md` §5，全部为**实测验证**。每条都给出「如果不遵守会发生什么」（后果）。**这些是 Phase 1 一开始就要固化进代码的规则，不是等踩坑后补的。**（本版逐字沿用 v0.2 §3，无改动。）

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

（本版逐字沿用 v0.2 §4。）

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

> **与 Codex Micro 的对照（本版新增，仅供说明，不影响本项目实现）**：Codex Micro 的设备发现同样按 VID/PID/usagePage 过滤，条件是 `0x303A` / `{0x8360,0x8297,0x8298}` / `0xFF00`（§5.1）。两套过滤条件互不相交，这也是 §5.1 结论不可绕过的结构性原因。

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

因此决策「GameController 优先，IOHIDManager 兜底」在本版**必须改写**为：

> **在 XInput 变体下优先走 GameController；对泛用变体，IOHIDManager 是唯一路径，两者都是一级输入源。**

同时，即使两条路径都实现，**仍必须做「当前变体」的显式状态展示**（menu bar 显示 `C/XInput` 或 `C/generic` 或 `H` 或 `T/不支持`），因为用户看不到自己的手柄当前是哪个变体。

### 4.5 T 档与 H 档的处理（明确不做，但必须能识别）

- **T 档**：完全未采集（超出项目范围）。Phase 1 的设备匹配逻辑必须能识别 T 档设备名（`IINE-Control` / `IINE-Phone`）并**跳过 + 提示**，不能把它当成未知设备反复重试。
- **H 档**：实测会**严重泄漏**——6 个键全部作为普通按键进入前台 App（A = `Enter`、B = `Space`，不是 Escape）。因此 H 档绝不能做输入源；App 只应**识别并提示用户切回 C 档**。
- H 档的第二变体未知（说明书未记载）。
- 来源: phase0-summary.md §2 / §7，实测验证。

---

## 5. Codex Micro 对标（v0.3 新增核心章节）

> 本章全部结论来自 `docs/research-codex-micro-mapping.md`（2026-09-15），该调研只读、未启动 GUI App、未修改任何 `~/.codex/` / `~/.claude/` / `/Applications/` 内容。
> 目标 App 版本：`/Applications/ChatGPT.app`，app.asar 大小 322,016,862 字节（2026-09-13 01:10 构建）。

### 5.0 为什么要做这次对标

用户的原始问题是：**「L1162 能不能被 Codex 当作 Codex Micro 接受？」** 如果答案是「能」，那么本项目可以直接复用 Codex 官方的物理键体验，而不需要注入按键。本次对标给出了明确的「不能」，但同时证明了第二条更重要的结论：**Codex 认为「值得绑到物理键上」的那套动作，我们 100% 可达**。

### 5.1 可行性结论：L1162 无法被 Codex 当作 Codex Micro 接受

#### 5.1.1 结论

> **❌ 不可行。**
> L1162 固件不可改、无法改 VID/PID/HID 描述符，而 Codex 桌面 App 在 macOS 上的设备发现是 **IOKit 匹配字典硬过滤 `VendorID = 12346 (0x303A)` + `ProductID ∈ {0x8360, 0x8297, 0x8298}` + HID `usagePage = 0xFF00`**，三重条件全部硬编码在原生插件里。
> **「困难」不等于「可能」：这条路在 L1162 上没有任何可达路径。**

来源: research-codex-micro-mapping.md §1.1 / §1.3 / §1.5，实测验证。

#### 5.1.2 硬件级原因：三重 AND 硬过滤

**链路**：`CodexMicroService` 在 macOS 上**根本不走** `WLDeviceDiscovery.findWLDevices()`，而是走原生插件 `hid-topology-watcher.node` 的 `findCodexMicroInterfaces()`（来源: research-codex-micro-mapping.md §1.1 证据 A，实测验证）：

```js
// service-tYAbfsGu.js（.vite/build/service-tYAbfsGu.js，29630 字节，单行）开头
var c=`hid-topology-watcher.node`,l=`hid_topology_watcher.node`,u=(0,s.createRequire)(__filename);
function f(){return p().findCodexMicroInterfaces()}
var h=12346,g=33632,_=[33431,33432],v=[g,..._],y=65280;         // 0x303A / 0x8360 / 0x8297,0x8298 / 0xFF00
async function te(){return ne(process.platform===`linux`?(...):await f())}
function ne(e){return e.flatMap(e=>{let t=re(e.productId);
  return e.path==null||e.usagePage!==y||t==null?[]:[{portPath:e.path,devicePid:String(e.productId),...,deviceType:t,...}]})}
```

插件在
`/Applications/ChatGPT.app/Contents/Resources/native/hid-topology-watcher.node`，其 `CreateCodexMicroMatchingDictionary(int productId)` 构造 `IOServiceMatching("IOHIDDevice")` 后写入 `VendorID` / `ProductID` 两个键，`__const` 里的 int32 常量为 `12346`（来源: research-codex-micro-mapping.md §1.1 证据 B，实测验证 —— `otool -tV` 可见 `mov w2, #0x8360` / `#0x8297` / `#0x8298` 与 `cmp w8, #0xff00`；`__const` 偏移 `0x6f38` 读出 `3a300000`）。

**要进入候选集，必须同时满足（AND）**（来源: research-codex-micro-mapping.md §1.2，实测验证）：

| # | 条件 | 值 | L1162 现状 | 可改？ |
|---|---|---|---|---|
| 1 | 出现在 IORegistry 的 `IOHIDDevice` | — | ✅ 满足 | — |
| 2 | `VendorID` | **12346 / 0x303A** | IINE 自己的 VID | ❌ 固件不可改 |
| 3 | `ProductID` | **0x8360 / 0x8297 / 0x8298** 之一 | 不匹配 | ❌ 固件不可改 |
| 4 | HID `PrimaryUsagePage`（或 `DeviceUsagePairs` 某项）= **0xFF00** | 65280 | BLE HID，标准 usage（Generic Desktop / Button），无 `0xFF00` 集合 | ❌ HID 描述符由固件生成 |
| 5 | 有可打开的 HID `path` | — | ✅ 满足（`e.path==null` 才丢弃） | — |
| 6 | 能说私有 JSON-RPC over HID | 见 §5.1.4 | ❌ 不可能 | ❌ |

第 4 条尤其关键：Work Louder 用的是 **vendor-defined usage page `0xFF00`**，普通 BLE 手柄的 HID 报告描述符里根本没有这个集合。

**BLE 不是障碍，VID/PID/usagePage 才是。** macOS 的 IOHIDDevice 也会暴露 BLE 设备（`Transport=Bluetooth`），但三项仍然全部不匹配。（来源: research-codex-micro-mapping.md §1.3，实测验证）

> ⚠️ 注意与 §4.2 的对比：L1162 自己的识别也依赖 product + usage，但那是**我们**的匹配逻辑；Codex 的匹配逻辑是**别人写死在二进制里**的，我们改不了。

#### 5.1.3 被否掉的伪造路径（逐条）

（来源: research-codex-micro-mapping.md §1.4，逐条结论均为该文档给出的判定）

| 方案 | 需要什么 | 本条件下可行性 |
|---|---|---|
| **A. 刷 L1162 固件改 VID/PID/HID 描述符** | 厂商 Bootloader / DFU 入口、固件签名、逆向协议 | **❌ 不可行**。L1162 无公开 DFU，Phase 0 硬件探测也未发现可写路径；改 HID 描述符等于重写固件 |
| **B. 中间人代理流量** | 硬件中间人（Facedancer / Raspberry Pi Pico 冒充 host） | **❌ 不可行**。BLE HID 不经 USB 线，且需要伪造完整 USB 设备栈 + 私有 RPC 设备端 |
| **C. 打补丁改 `app.asar` / 注入 Electron** | 破坏代码签名、可能触发 asar integrity 校验、违反 ToS | **❌ 不可行（也不应做）**。任务纪律明确禁止改 `/Applications/ChatGPT.app` |
| **D. 写 DriverKit / IOKit HID 驱动冒充** | `com.apple.developer.hid.virtual.device`（**Apple 受限 entitlement，需申请审批**）+ 开发者签名 + 系统扩展审批 | **❌ 不可行**。本项目是自签 ad-hoc 的菜单栏 App（`scripts/make-app.sh`），拿不到该 entitlement |
| **E. `IOHIDUserDevice`（用户态虚拟 HID 设备）** | 同上 entitlement；且要自己实现设备端 `device.status` / `lights.preview` 等 JSON-RPC 响应 + 主动上报 `AG00`–`AG05` | **❌ 本条件下不可行**（缺 entitlement）。即便拿到，也只是**另造一个假 Codex Micro**，L1162 本体仍不被识别 |
| **F. 直接把按键注入 Codex（本项目现行路线）** | CGEvent / AX API | ✅ **可行**，见 §5.2 |

**结论**：伪造路线全部封死；现实路线只有 F。

#### 5.1.4 附带事实：即便被发现，还要能说私有协议

（来源: research-codex-micro-mapping.md §1.4，实测验证）

- 64 字节 HID report：`byte[0]`=report id、`byte[1]`=channel（1=debug，2=rpc）、`byte[2]`=长度、`byte[3..]`=UTF-8；换行分隔的 JSON-RPC（`parseHIDReport`）。
- 已知私有 RPC 方法名：`device.status`、`sys.version`、`sys.bootloader`、`sys.selftest`、`lights.preview`、`fs.list/read/write/...`、`mp.write_info`、`appmgr.list_active`、`host.focused_app`、`ui.active_screen` 等。App 侧连接成功还要求 `device.status` 等 RPC 正常返回（`setDeviceState({status:'connected'})` 之前会先 `applyLatestLighting()`，失败降级为 `detected`/`error`）。
- 按键事件也是私有格式：主进程用正则 `/^AG0([0-5])$/` 识别 6 个 agent 键；另有 `ACT06`–`ACT12`（来自 layout 产物）与 `ENC_CW`/`ENC_CC` 这类私有字符串，**不是标准键盘 usage**。

**这解释了为什么「改改 VID/PID 就行」是不可能的**：即便过滤条件全中，App 还会跟设备握手；不握上手，状态永远停在 `detected` 而不是 `connected`。

### 5.2 动作层：33 个 `keycaps.*` 动作全部可达，0 条不可达

> **结论**：**33 / 33 可达，0 条不可达。**（来源: research-codex-micro-mapping.md §2.3，实测验证）
> 分类口径：**A** = 有 macOS 默认键位、可直接按键注入；**B** = 无默认键位但命令面板可搜到（`⌘K` → 输入标题 → `Enter`）；**C** = 无默认键位、面板也没有，**需用户在 Settings → Keyboard Shortcuts 自己绑一次键**，之后即可按键注入；**D** = 非 Codex 命令机制（注入文本 / 打开 URL / 纯键转发）。
> ⚠️ **证据等级读法**：下表的「实测验证」= 「该命令存在于 131 条注册表 / 该键位存在于注册表 / 该 `commandMenu` 标志位存在」已实测；**不表示**按下去有预期效果（那是 §9 U6）。

#### 5.2.1 A 类 —— 11 条：有默认键位，可直接注入

| 键帽 | 动作标签 | 命令注册表 id | macOS 默认键位 | 面板 | 可达方式 | 证据等级 |
|---|---|---|---|---|---|---|
| `APPR` | Approve | `approval.approve` | `Enter` | ❌ | A（上下文限定：审批卡） | 实测验证（键位）/ 静态推断（`enabled` 门控） |
| `REJ` | Reject | `approval.decline` | `Escape` | ❌ | A（上下文限定：审批卡） | 实测验证（键位）/ 静态推断（`enabled` 门控） |
| `TERM` | Toggle terminal | `toggleTerminal` | `⌃\`` | ✅ | A | 实测验证 |
| `DEL` | Archive chat | `archiveThread` | `⌘⇧A` | ✅ | A | 实测验证 |
| `NEW` | New chat | `newTask` | `⌘N`（另 `⌘⇧O`） | ✅ | A | 实测验证 |
| `NAV` | Open browser tab | `openBrowserTab` | `⌘T` | ✅ | A | 实测验证 |
| `MAGIC` | Pin or unpin chat | `toggleThreadPin` | `⌥⌘P` | ✅ | A | 实测验证 |
| `LAB` / `SETUP` | Open Settings | `settings` | `⌘,` | ✅（作为 Settings 分组另行渲染） | A | 实测验证 |
| `PARTY` | Open side chat | `openSideChat` | `⌥⌘S` | ✅ | A | 实测验证 |
| `FOLD` | Open folder | `openFolder` | `⌘O` | ✅ | A | 实测验证 |
| `PLAY` | Run primary action | `environmentAction1` | `⇧⌘D` | ❌ | **A′**（键位在，处理器未找到，**语义未验证**） | 实测验证（键位）+ 未验证（语义） |

#### 5.2.2 B 类 —— 8 条：命令面板可搜到

面板机制：`openCommandMenu`（`⌘K` / `⌘⇧P`），面板行按命令标题模糊匹配（`filter: mwo`，行 `value:{title}`）。**面板只收录 `kind === 'webview' && commandMenu === true` 的命令，共 63/131 条。**（来源: research-codex-micro-mapping.md §2.1 路径 ②，实测验证 + 静态推断）

| 键帽 | 动作标签 | 命令注册表 id | 面板标题（= 搜索用原文） | 可达方式 | 证据等级 |
|---|---|---|---|---|---|
| `BUG` | Open feedback | `feedback` | `Feedback` | B | 实测验证 |
| `BRCH` | Create draft PR | `git.createDraftPullRequest` | `Create draft PR` | B（另需 `codexLocal` 与 git 工作区上下文） | 实测验证 |
| `BRANCH` | Create branch | `git.createBranch` | `Create branch` | B（同上） | 实测验证 |
| `MRG` | Merge PR | `git.mergePullRequest` | `Merge PR` | B（同上） | 实测验证 |
| `GIT` | Commit or push | `git.commit` | `Commit or push` | B（同上） | 实测验证 |
| `PR` | Create PR | `git.createPullRequest` | `Create PR` | B（同上） | 实测验证 |
| `APPS` | Open plugins | `openSkills` | `Go to skills` | B | 实测验证 |
| `TIME` | Open Scheduled | `manageTasks` | `Manage scheduled tasks` | B | 实测验证 |

#### 5.2.3 C 类 —— 9 条：需用户在 App 内绑一次键

绑定机制：Settings → Keyboard Shortcuts 是一个可搜索、可逐命令录制快捷键的设置页；提交走 IPC `set-codex-command-keybinding` / `reset-codex-command-keybindings`（state key `codex-command-keymap-state`）。**除了显式标 `shortcutConfigurable:false` 的两条命令（`composer.captureAppshot`、`codexMicroSettings`），其余 129 条都可绑键**；绑定后走 `keymapState.bindings`，在**任何窗口（含 electron）都生效**（`uMi` 第一优先级）。（来源: research-codex-micro-mapping.md §2.1 路径 ③，实测验证）

| 键帽 | 动作标签 | 命令注册表 id | 为什么不在面板 | 可达方式 | 证据等级 |
|---|---|---|---|---|---|
| `FAST` | Toggle Fast mode | `composer.toggleFastMode` | i18n 是 `Shortcut settings row for toggling Fast mode` | **C** | 实测验证 |
| `SPLIT` | Fork chat | `forkThread` | 无 `commandMenu` 标志 | **C** | 实测验证 |
| `CODEX` | Send message | `composer.submit` | 无 `commandMenu` 标志；注册表**无默认键位**，靠 `n0('composer.submit', handler, {enabled})` 注册 | **C**（另有 composer 内 `Enter` 组件逻辑，见下） | 实测验证（无默认键位 + 有处理器）/ 静态推断（回车分支） |
| `DWN` | Copy chat as Markdown | `copyConversationMarkdown` | 无 `commandMenu` 标志 | **C** | 实测验证 |
| `DIFF` | Toggle review | `toggleReviewTab` | 无 `commandMenu` 标志 | **C** | 实测验证 |
| `UPL` | Attach files and folders | `composer.addFiles` | `⌘U` 只写在 `browser` 段 → 桌面不生效（F3） | **C** | 实测验证 |
| `PAINT` | Add photos | `composer.addPhotos` | 无 `commandMenu` 标志 | **C** | 实测验证 |
| `MIND+` | Increase reasoning effort | `composer.increaseReasoningEffort` | 无 `commandMenu` 标志 | **C** | 实测验证 |
| `MIND-` | Decrease reasoning effort | `composer.decreaseReasoningEffort` | 无 `commandMenu` 标志 | **C** | 实测验证 |

#### 5.2.4 D 类 —— 5 条：非 Codex 命令机制

| 键帽 | 动作标签 | 机制 | 可达方式 | 证据等级 |
|---|---|---|---|---|
| `YEET` | Write `:yeet:` in the composer | `{type:'composer-text', text:':yeet:'}` | D（CGEvent 注入字面文本） | 实测验证（定义）/ 未验证（写入后的下游处理） |
| `YOLO` | Write `:yolo:` in the composer | `{type:'composer-text', text:':yolo:'}` | D（同上） | 同上 |
| `OAI` | Open OpenAI docs | `{type:'external-url', url:'https://developers.openai.com'}` | D（打开 URL） | 实测验证 |
| `EMPT1..5` | Assign any shortcut | `{type:'custom-shortcut'}` | D（任意键，纯转发） | 实测验证 |
| — | Insert text | `{type:'composer-text'}`（自定义） | D（注入自定义文本） | 实测验证 |

> ⚠️ D 类全部属于 v0.1 §17 / 本版 §13 定义的 **macro（文本注入）**，必须满足 `macrosEnabled == true` + 明确 profile + 目标 App 在 allowlist。**D 类不是开箱即用的**，不计入「零配置」承诺。

#### 5.2.5 分类统计与三条读表结论

| 类别 | 数量 | 本项目含义 |
|---|---|---|
| **A. 有 macOS 默认快捷键 → 可直接按键注入** | **11** | 零配置可用（`PLAY`/`A′` 语义未验证，暂不启用） |
| **B. 命令面板可搜到** | **8** | 需要 macro（`⌘K` + 文本 + `Enter`），默认关闭 |
| **C. 需在 Settings → Keyboard Shortcuts 自己绑一次键** | **9** | **可达，但属于一次性配置负担**（见 §10 R13） |
| **D. 文本 / URL / 纯键转发** | **5** | 全部是 macro |
| **完全不可达** | **0** | — |
| **合计** | **33** | — |

三条结论：

1. **「33 条全部可达」是可达性结论，不是行为结论。** 每一条的端到端按键效果仍是【未验证】（§9 U6 / U25）。
2. **本项目只需要这 33 条里的一个子集。** §14.4 的 17 个语义动作覆盖了其中最有价值的部分；`git.*` 这类低频高危动作**保留在面板里，不给手柄键**（来源: research-codex-micro-mapping.md §4.2 的排序建议）。
3. **B 类（面板）不是「兜底」，是 macro。** v0.2 把 `⌘K` 面板当万能兜底是本版修正的 F1/F2；本版对 B 类的默认策略是**默认关闭**（§8 G3'）。

### 5.3 复刻不了的体验（硬件能力缺口）

我们的硬件只有 **6 个数字输入、无 RGB、无摇杆、无旋钮、无屏幕**。（来源: research-codex-micro-mapping.md §3.1，实测验证）

| Codex Micro 体验 | 证据 | 为什么复刻不了 |
|---|---|---|
| **每键 / 每线程 RGB 状态灯** | `RPCApiOAI.sendThreadsLighting(ThreadLighting[])`、`sendLightingConfig({keys,ambient})`、`settings.codexMicro.agentKeyPreview.status.{idle,working,awaitingApproval,awaitingResponse,unread,error,off}` | L1162 **无 RGB**；且这套灯效走设备私有协议（`lights.preview` + OAI 专有 effect 枚举），外部无法驱动 |
| **摇杆模拟输入 + 模拟命令** | `onJoystickMove(JoystickPos{angle,distance})`；`settings.codexMicro.analog.commands.{app,configure,navigation,panels,skills,thread,workspace}`；`analog.direction.{up,down,left,right}` | L1162 十字键是**数字**信号，没有角度/位移；`analog` 的 8 方向可编程语义需要模拟量 |
| **旋钮（encoder）** | `settings.codexMicro.keyboardLayout.knobByDevice`、`knobTooltip.{turnLeft,turnRight,click,pressAndHold}`；HID key 名 `ENC_CW`/`ENC_CC` | L1162 没有旋钮 |
| **6 个 agent 键的按线程绑定** | `agentKeys.{pinnedChats,priorityChats,recentChats,customChats,singleTap}`；`CodexMicroServiceManager.updateAgentThreadKeys(...)`；`agentKeyKinds[slot] === 'recent-thread' \| 'action'` | 这是**设备固件侧**的槽位绑定（`AG00`–`AG05` → 具体 threadKey），并依赖键帽上的灯/屏显示「哪个键是哪个线程」。我们的 6 键没有显示，也无法让 App 把绑定下发到我们设备 |
| **单击 / 双击 agent 键区分（原生识别）** | 主进程 `HN = 350`（ms）双击窗口、`singleTapAgentKeys`、`lastAgentTap` | 属于设备端手势 + 灯效反馈；本项目有自己的手势引擎（`GestureRecognizer`），**语义可以自己实现**，但「App 原生识别」复刻不了 |
| **键帽外观 / 图标体系** | `codex-micro-layout` 每个 keycap 带 `icon:`（`lightning-outline` / `check-circle` / `worktree`…）、`size:single\|double` | 纯硬件外观，与本项目无关 |
| **麦克风键 / Push-to-Talk / Voice Chat** | keycap `MIC`/`MIC1` → `{type:'named',label:'Push to talk'}`；`realtimeVoice.toggleMicrophoneMute`、`composer.startVoiceMode`、`settings.codexMicro.microphoneKey.*`、`microphoneKeyPushToTalk` / `microphoneKeyVoiceChat` | L1162 无麦克风键。**可用替代**：`Ctrl+Shift+V`（`composer.startVoiceMode`，注册表实测验证），但那是键盘快捷键，不是 PTT |
| **设备状态展示**（固件版本 / 电量 / 连接态） | `WLDeviceStatus{firmwareVersion,batteryPercentage,isCharging}`；前端 `codexMicro.battery.percentage` / `codexMicro.battery.charging` | 只有 Work Louder 硬件会出现在 UI 里 |
| **固件更新 / 烧录** | `WLDeviceProgrammer.flashDeviceFirmware` + `findWLBootloaderDevices()`；`WLRelease` | 同上，且本项目不需要 |

> **一句话**：**Codex Micro 的「硬件体验」复刻不了，"动作层"完全复刻得了。** 本项目从一开始就不应该把「被识别」当作目标（§5.1）。

### 5.4 可复刻的体验

（来源: research-codex-micro-mapping.md §3.2，实测验证）

| 可复刻项 | 怎么复刻 | 依据 |
|---|---|---|
| **「6 个可编程动作键」的核心体验** | 我们的 6 个输入 → 语义动作 → 键注入。33 条动作全部可达（11 直接键位 / 8 面板 / 9 绑一次键 / 5 文本或 URL） | §5.2 |
| **设备按键 → 命令面板入口** | 把某个键映射成 `⌘K`，再注入命令标题 + `Enter`。面板行可模糊匹配标题 | `$4.Dialog{filter:mwo}` + `value:{title}`；`cmd-titles.json` |
| **Sticky / 长按 / 双击手势层** | 项目已有 `GestureRecognizer` + `GestureConfiguration`；语义与 Micro 的单/双击思想一致 | `Sources/PocketAgentCore/Gesture/` |
| **每键上下文相关动作**（按前台 App / 当前是否在生成中切换语义） | 项目已有 adapter + 守卫设计；Micro 用 `enabled` 门控（如 `composer.queue` 仅在有回复进行中时 enabled）——可以做同构的「上下文守卫」 | `app-primary.js`: `n0('composer.queue', S, {enabled:y})`，`y = r&&!i&&!m&&!c&&s==='submit'` |
| **「输入后处理成文本」类动作** | `:yeet:` / `:yolo:` / 自定义 composer text 都只是往输入框写文本，CGEvent 注入即可 | `codex-micro-layout`: `{type:'composer-text',text:':yeet:'}` |
| **`custom`（任意快捷键）体验** | 我们自己就是「任意键转发器」，等价甚至更强（可带手势/长按） | — |
| **面板快捷入口（Settings / Terminal / Review / Side chat…）** | 全部有默认键位或面板可达 | §5.2 A/B 类 |

---

## 6. 推荐按键映射与手势映射

### 6.1 Base Layer —— 通用导航（保留 v0.1 设计，标注风险）

| L1162 | Semantic action | Default output | 风险 |
|---|---|---|---|
| ↑ | `navigateUp` | Arrow Up | `ActionRisk.navigation` |
| ↓ | `navigateDown` | Arrow Down | `ActionRisk.navigation` |
| ← | `navigateLeft` | Arrow Left | `ActionRisk.navigation` |
| → | `navigateRight` | Arrow Right | `ActionRisk.navigation` |
| A | `submit` | `Enter`（审批弹层里即 approve） | normal |
| B tap | `cancelOrInterrupt` | `Escape`（审批弹层里即 reject） | normal |
| B hold（单独，无 chord） | `cancelOrInterrupt` | 同 B tap | normal |

**v0.2 的重要修正（保留）**：桌面 App 上这 4 个 `navigate*` **没有专用命令**，只能注入方向键，语义完全取决于当前焦点在哪个面板（会话列表 / 命令面板 / 审批选项 / 聊天区滚动）。这与 CLI 里 `↑/↓` = 会话列表 / 草稿历史的确定性语义**差别很大**。（来源: research-codex-desktop.md §6，静态推断）适配层必须把它们标为 `ActionRisk.navigation`（§14.5）。

### 6.2 新的默认 B 层映射（用户已拍板，全部 A 类、零配置）

> **本表是 v0.3 的默认映射，替换 v0.2 §6.2 的旧 B 层表。**（F7）
> 「Codex 触发」列给出该动作在 Codex 桌面 App 上的实际落地键位；证据等级说明这条键位本身已实测存在，**不代表按下去有预期效果**（§9 U6）。

| 手势 | 语义动作 | Codex 触发 | 可达类别 | 证据等级 |
|---|---|---|---|---|
| ↑ ↓ ← → | 导航（四个方向） | 方向键 `↑` / `↓` / `←` / `→` | —（键注入） | 静态推断（语义随焦点，§6.1） |
| A | `submit`（兼 **approve**） | `Enter` | C / A（组件逻辑 + 审批卡） | 实测验证（`composer.submit` 处理存在、`approval.approve` = `Enter`）/ 未验证（行为） |
| B tap | `cancelOrInterrupt`（兼 **reject**） | `Escape` | A（`approval.decline`）+ 键注入 | 实测验证（键位）/ 静态推断（`N_r()` 的 `stop-turn` / `confirm-stop-turn` 分支） |
| B 长按单独 | `cancelOrInterrupt`（兼 **reject**） | `Escape` | 同上 | 同上 |
| B + ↑ | `newChat` | `⌘N`（`newTask`） | **A** | 实测验证（注册表默认键位） |
| B + ↓ | `openTerminal` | `` ⌃` ``（`toggleTerminal`） | **A** | 实测验证（注册表默认键位） |
| B + ← | `openModelPicker` | `⌃⇧M`（`composer.openModelPicker`） | **A** | 实测验证（注册表默认键位） |
| B + → | `queueFollowUp` | 绑定：`composer.queue`（用户绑一次键，C 类）；天然路径：运行中 `Enter` | C + 隐式 | 实测验证（命令与处理器存在）/ 未验证（运行中 `Enter` 是否真排队，U5） |
| B + A | `inspectChanges` | **`⌥⌘B`**（View > Toggle Review Panel） | **A** | 实测验证 2026-09-16：从**运行中 App 的菜单**读取并实操生效；本行原先并列的 `⌃⇧G` 已证伪 |

三条必须写清的边界：

1. **`openModelPicker` 不属于 Codex Micro 的语义集。** Micro 的 33 条动作清单里**没有** model picker，只有 `MIND+` / `MIND-`（`composer.increaseReasoningEffort` / `decreaseReasoningEffort`）调推理档。它在本项目里**可用**（`⌃⇧M` 是注册表实测默认键位），但**不能**说成「对齐了 Micro」。（来源: research-codex-micro-mapping.md §4.1 的「反向缺口」，实测验证）
2. **`queueFollowUp` 是两种落地并存**：绑一次键（C 类，确定性）或依赖运行中 `Enter`（受 `[desktop] followUpQueueMode = "queue"` 控制，实测配置项存在但链路未验证）。**v0.2 把它当缺口是错的**（F4）。
3. **`toggleFastMode` 与 `openPermissionModeMenu` 已退出默认绑定** —— 它们在 Codex 侧要么需要用户绑键（C 类），要么根本不存在。见 §6.3 / §6.5。

4. **静态注册表 ≠ 运行时绑定（v0.3 实测教训）。** `inspectChanges` 一条踩过：注册表里
   `openReviewTab` 写着 `Ctrl+Shift+G`，注入后**毫无反应**；而运行中 App 的
   `View > Toggle Review Panel` 实际绑的是 `⌥⌘B`，一按就生效。
   凡是可以从**运行中菜单**读到的键位，一律以菜单为准；用
   `swift Tools/dump-menu-accelerators.swift ChatGPT` 可直接导出（44 条）。
   其余无法从菜单读到的（如 `⌃⇧M` 模型选择器、`⌘N` 新建）才回退到注册表，且必须实测。

### 6.3 可选未绑定动作（v0.3 新增概念）

> **「默认绑定」与「可选未绑定」的区分是本版的核心结构变化。** 只有 6 个物理输入，`chord` 位不够用；把低频动作塞进默认映射会挤掉高频动作，并放大误触风险。以下动作**在 `AgentAction` 里存在、有可用触发，但不占默认手势**，由用户在配置里显式绑定。

| 语义动作 | Codex 触发 | 可达类别 | 证据等级 | 为什么默认不绑 |
|---|---|---|---|---|
| `archiveChat` | `⌘⇧A`（`archiveThread`） | **A** | 实测验证 | 归档是「不可一键撤销」的破坏性动作，不适合零配置单手触达 |
| `pinThread` | `⌥⌘P`（`toggleThreadPin`） | **A** | 实测验证 | 低频；且 `⌥⌘P` 与系统「打印」类快捷键形态相近，留给用户自己选 |
| `forkThread` | 绑定 `forkThread`（用户绑一次键，C 类；注册表无默认键位） | **C** | 实测验证（无默认键位）/ 未验证（落盘位置 U8/U24） | 会话分叉是「产生新状态」的动作，默认不鼓励误触 |
| `openSideChat` | `⌥⌘S`（`openSideChat`） | **A** | 实测验证 | 面板类动作，可先用 `openModelPicker` / `openTerminal` 覆盖更常用的入口 |
| `toggleFastMode` | 绑定 `composer.toggleFastMode`（C 类） | **C** | 实测验证（命令存在、无默认键位、**不在命令面板**） | 需要用户先在 App 内绑键；且 v0.2 的「面板兜底」已被证伪（F2） |
| `openPermissionModeMenu` | **Codex 侧明确不支持**；Claude 侧 `⌘⇧M`（`openModeMenu`）打开菜单 + `1…9` 选择 | Codex: **unavailable** / Claude: keyInjection（两段式） | 实测验证（Codex 无此动作）/ 静态推断（Claude） | 参 §8 G1 / G2 |

**实现要求**：可选未绑定动作在 menu bar 的 `Capabilities` 列表里**必须可见**（显示「已定义、未绑定、触发方式是什么、当前 profile 是否支持」），否则用户不知道它们存在。默认映射表（§6.2）与可选表（§6.3）的并集 = §14.4 的 17 个动作。

### 6.4 为什么 B 是 modifier

保持 v0.1 的理由：B 在游戏/UI 语义中本来就是 Back / Cancel / Escape，`B tap = Back`、`B + X = secondary command` 比把 A 当 modifier 更自然。**但 v0.2 补一条实测警告**：在 H 模式下 B 是 `Space` 而不是 Escape（来源: phase0-summary.md，实测验证）——这又一条 H 模式不能做主路径的理由。

**v0.3 补充两条状态机层面的明确化**：

- **B hold 单独松开 = `cancelOrInterrupt`，与 B tap 同义。** 换句话说 B 没有「第四个动作」：`B tap` 与 `B hold alone` 都产出同一个语义动作，只是判定窗口不同（`<= 220 ms` vs `>= 450 ms`）。这样 hover 在 220–450 ms 之间的边界情况不会「什么都不发生」。
- **B + 方向键的 chord 在 `BPending` 阶段即合法**（沿用 §19.2 的状态机），因此上表的手势无需等待 `holdMs` 就能触发 —— 这是「零配置、单手、快速」体验的关键。

### 6.5 关于「Codex Micro 式键帽」的映射取向（本版新增）

Codex Micro 有 39 个键帽槽、33 条可分配动作，因为它有 20+ 个物理键和 RGB 反馈；我们只有 6 个输入。因此本项目的取向是：

- **把 Micro 动作清单当作「词汇表的可信来源」**（它证明这些动作在 Codex 里真实存在、值得绑键），而不是「必须一一映射的清单」；
- **默认手势只留高频 8 条**（§6.2）；其余 9 条动作进入可选未绑定（§6.3）；
- **明确拒绝**给 `git.*`（`git.commit` / `createPR` / `createDraftPR` / `createBranch` / `mergePR`）这类**低频高危**动作分配手柄键 —— 它们保留在命令面板（B 类，macro，默认关闭）。（来源: research-codex-micro-mapping.md §4.2 排序建议）

### 6.6 目标 App 切换不占用 chord

沿用 v0.1 §6.4 的决策：只有 6 个主要输入，非常宝贵；profile 切错后可能把同一 chord 解释成不同的敏感操作。**v0.2 改为自动探测 + menu bar 显式覆盖**（§11.4），本版不变。

### 6.7 冲突检查（配置落地前必须看）

| 检查项 | 结论 | 依据 |
|---|---|---|
| `⌃⇧M`（`openModelPicker`）与 Codex 其它默认键位冲突？ | 不冲突 | research-codex-desktop.md §5.2 快捷键表 |
| `⌘N` / `⌃\`` / `⌥⌘S` / `⌘⇧A` / `⌥⌘P` 彼此冲突？ | 不冲突 | 同上 |
| 与 `os-global` 热键冲突？ | `⌥Space`（`openAvatarOverlay`，Show pet）是 `os-global`，**本项目未使用** | research-codex-desktop.md §7 风险 2，实测验证 |
| 与 Claude 侧键位冲突？（同一 chord 打到 Claude 会话） | `⌃⇧M` = Codex 的 model picker；Claude 的 `⌘⇧I` / `⌘⇧.` 是 model menu，**不同键**，不会互相污染 | research-claude-desktop.md §4.4 / §7.1 |
| 与浏览器 `⌘U` / `⌘K` 冲突？ | 桌面 App 不上这两个 browser 段键位（F3），无冲突 | research-codex-micro-mapping.md §2.1 路径 ① |

---

## 7. 能力矩阵

> **v0.3 的范围声明（重要）**：本版的能力矩阵分为两张表。
> - **§7.1 Codex**：按 §5.2 的 33 条动作调研**逐条重写**，覆盖 §14.4 的 17 个语义动作 + B/D 类可选项。
> - **§7.2 Claude**：**本版没有对 Claude 重新调研**。因此只保留 v0.2 §7.2 的 11 行动作结论（原样、原证据等级），其余 6 个新增动作**一律标【未验证】**并注明「本版未调研，无结论」。**不允许**把 Codex 的键位外推到 Claude。

图例：

- ✅ = 该机制可用 ｜ ⚠️ = 可用但有明确缺陷/依赖 ｜ ❌ = 做不到或无对应 ｜ — = 该动作在本 App 未定义/未调研
- 证据等级：**【实测】** / **【静态】** / **【未验证】**（定义见文档头部 + §0.2 的读表须知）

> **关于「程序化接口」列的总说明**：两个 App 都**不存在**针对这些动作的专用编程接口。Codex 桌面 App「没有任何对外可用的本地程序化控制面」（来源: research-codex-desktop.md，实测验证）；Claude 桌面 App「没有留任何进程外 API」（来源: research-claude-desktop.md，实测验证）。两条 deep link 通道（`codex://` / `claude://`）都只做**会话级导航**，不覆盖任何**会话内动作**。因此该列除特别说明外全部为 ❌。

### 7.1 Codex 桌面 App（`com.openai.codex`）

| # | 语义动作 | 程序化接口 | 原生菜单点击 | 按键注入 | 做不到 | 证据等级 | 可达类别 |
|---|---|---|---|---|---|---|---|
| 1 | `navigateUp` | ❌ | ❌（菜单无导航项） | ⚠️ `↑`，语义随焦点 | — | 静态推断 | — |
| 2 | `navigateDown` | ❌ | ❌ | ⚠️ `↓`，同上 | — | 静态推断 | — |
| 3 | `navigateLeft` | ❌ | ❌ | ⚠️ `←`，同上 | — | 静态推断 | — |
| 4 | `navigateRight` | ❌ | ❌ | ⚠️ `→`，同上 | — | 静态推断 | — |
| 5 | `submit` | ❌ | ❌ | ✅ `Enter`（注册表**无默认键位**，走 `n0('composer.submit', handler, {enabled})`；composer 聚焦时回车由组件自身处理） | — | **实测验证（处理存在）** + 静态推断（回车分支） | C / A（审批卡） |
| 6 | `cancelOrInterrupt` | ❌ | ❌ | ✅ `Esc`（生成中 → `stop-turn` / `confirm-stop-turn`） | — | 静态推断（源码分支 `N_r()`） | A（`approval.decline`）/ 键注入 |
| 7 | `queueFollowUp` | ⚠️ `codex queue --thread <id> --message`（写存储，**运行中 App 是否采纳【未验证】**） | ❌ | ✅ **首选：用户在 Settings 里给 `composer.queue` 绑一次键，然后注入**；备选：运行中 `Enter`（受 `[desktop] followUpQueueMode = "queue"` 控制） | — | 实测验证（命令与处理器存在、配置项存在） + 未验证（运行中 `Enter` 链路 U5） | **C + 隐式**（**v0.2 判为缺口，本版修正**） |
| 8 | `openPermissionModeMenu`（原 `cyclePermissionMode`） | ❌ | ❌ | ❌ | **✅ 做不到** | **实测验证**（131 条命令注册表只有 `approval.approve` / `approval.decline`；Micro 的 33 条动作清单里同样没有；renderer 里 `Shift+Tab` 0 次命中） | **unavailable** |
| 9 | `toggleFastMode` | ❌ | ❌ | ⚠️ **无默认快捷键、也不在命令面板**；只能由用户在 Settings → Keyboard Shortcuts 给 `composer.toggleFastMode` 绑一次键 | — | 实测验证（无 `defaultKeybindings` + i18n 为 `Shortcut settings row for …`） | **C**（**v0.2 的「面板兜底」有误，本版修正**） |
| 10 | `openModelPicker` | ❌ | ❌ | ✅ `⌃⇧M`（`composer.openModelPicker`，无菜单项、渲染进程处理） | — | 实测验证（注册表默认键位） | **A**（但**不属于 Micro 语义集**） |
| 11 | `inspectChanges` | ❌ | ❌ | ✅ `⌃⇧G`（`openReviewTab`）/ `⌥⌘B`（`toggleSidePanel`） | — | 实测验证（注册表默认键位） | **A** |
| 12 | `newChat` | ❌ | ❌ | ✅ `⌘N`（`newTask`，另 `⌘⇧O`） | — | 实测验证（注册表默认键位） | **A** |
| 13 | `openTerminal` | ❌ | ❌ | ✅ `⌃\``（`toggleTerminal`） | — | 实测验证（注册表默认键位） | **A** |
| 14 | `openSideChat` | ❌ | ❌ | ✅ `⌥⌘S`（`openSideChat`） | — | 实测验证（注册表默认键位） | **A** |
| 15 | `archiveChat` | ❌ | ❌ | ✅ `⌘⇧A`（`archiveThread`） | — | 实测验证（注册表默认键位） | **A** |
| 16 | `pinThread` | ❌ | ❌ | ✅ `⌥⌘P`（`toggleThreadPin`） | — | 实测验证（注册表默认键位） | **A** |
| 17 | `forkThread` | ❌ | ❌ | ⚠️ 注册表**无默认键位**；需用户绑一次键后注入 | — | 实测验证（无默认键位） | **C** |

**B 类补充（v0.2 已登记、本版标注分类）**（来源: research-codex-desktop.md §5.2 / §6 + research-codex-micro-mapping.md §2.1，实测验证）：

```text
⌘N       newTask（新会话）          ⌘K / ⌘⇧P  openCommandMenu（命令面板，**仅 63/131 条命令**）
⌘B       toggleSidebar             ⌘J         toggleBottomPanel
⌃`       toggleTerminal            ⌘⇧G        openReviewTab
⌃1..⌃3   switchToMode1..3（Chat / Work / Codex 三个面板）  ← surface 切换的关键
⌘⇧[ / ⌘⇧]  previous / next thread
⏎ / Esc  approval.approve / approval.decline（审批卡上下文）
```

> ⚠️ `approval.approve`（`⏎`）与 `approval.decline`（`Esc`）**只在审批卡上下文生效** —— 它们与 `submit` / `cancelOrInterrupt` 共用同一物理键，这正是 v0.1「A = Enter、B = Escape，让 agent 自己的原生 UI 决定最终语义」策略在桌面 App 上依然成立的原因（§13）。**本版据此不新增 `approve` / `reject` 两个重复动作**（§14.4）。

### 7.2 Claude 桌面 App（`com.anthropic.claudefordesktop`）

> ⚠️ **范围声明**：本表前 11 行逐字沿用 v0.2 §7.2 的结论与证据等级，**本版未对 Claude 重新调研**。第 12–17 行（本版新增动作）在 Claude 侧**没有调研证据**，一律标【未验证】，实现时**不得**假设可用。若 Claude 侧对本项目重要，应在 Phase 3 前补一次与 Codex Micro 同级别的调研（§9 U26）。
>
> ⚠️ **语境前提**：下表第三列的键位来自 `ion-dist` 的 **Code session 语境** `jz` 键表与官方快捷键面板（**Code session / Composer 分组**）。同名的键位在 chat / cowork 语境语义不同，实现时必须先做 surface 判定（§11.3）。

| # | 语义动作 | 程序化接口 | 原生菜单点击 | 按键注入 | 做不到 | 证据等级 |
|---|---|---|---|---|---|---|
| 1 | `navigateUp` | ❌ | ❌ | ⚠️ `⌘⌥↑`（`jumpPrevPrompt`，会话内提示级跳转）或 AX 选中后 `↑` | — | 静态推断（键位）/ 未验证（实际行为） |
| 2 | `navigateDown` | ❌ | ❌ | ⚠️ `⌘⌥↓`（`jumpNextPrompt`） | — | 同上 |
| 3 | `navigateLeft` | ❌ | ✅ `Go > Back`（`⌘[`，历史后退） | ⚠️ `⌘⌥←`（前一 sidebar tab） | — | 菜单项实测验证 / 键位静态推断 |
| 4 | `navigateRight` | ❌ | ✅ `Go > Forward`（`⌘]`，历史前进） | ⚠️ `⌘⌥→`（后一 sidebar tab） | — | 同上 |
| 5 | `submit` | ❌ | ❌ | ⚠️ `enter`（**Code session 语境为【未验证】**：Code UI 的 Composer 分组里没有 `enter` / `shift+enter` 条目，提交可能由 textarea 组件自身处理） | — | 静态推断（chat 语境）/ **未验证**（Code 语境） |
| 6 | `cancelOrInterrupt` | ❌ | ❌ | ✅ `esc`（官方面板 Code session General 组明确写 "Stop Claude's response"） | — | 静态推断 |
| 7 | `queueFollowUp` | ❌ | ❌ | ❌ | **✅ 做不到**（无专用接口；`⌘⌥enter` 是 "Send in a forked session"，**语义不同，慎用**） | 静态推断 + 未验证 |
| 8 | `openPermissionModeMenu`（原 `cyclePermissionMode`） | ❌ | ❌ | ⚠️ `⌘⇧M`（`openModeMenu`）打开菜单后 `1…9` 选择；**没有「循环」动作** | — | 静态推断 |
| 9 | `toggleFastMode` | ❌ | ❌ | ✅ `⌘⌥F`（`jz` 表中 `toggleFastMode` 唯一来源） | — | 静态推断 |
| 10 | `openModelPicker` | ❌ | ❌ | ✅ `⌘⇧I`（`openModelMenu`）；命令面板注册表里 `model_selector` = `⌘⇧.`，两处来源一致指向「打开模型菜单」 | — | 静态推断（交叉印证） |
| 11 | `inspectChanges` | ❌ | ✅ `View > Show Changes`（`⌘⇧D`） | ✅ `⌘⇧D`（`toggleDiff`） | — | 菜单项实测验证 + 键位静态推断（同一键位交叉印证） |
| 12 | `newChat` | — | — | — | — | **未验证**（v0.3 新增动作，Claude 侧未调研；相邻线索：`new_conversation` = `⌘⇧O`，但那是**注册表条目**，未确认在桌面 App 的 Code 语境生效） |
| 13 | `openTerminal` | — | ✅ `View > Show Terminal`（`⌘J`） | — | — | **未验证**（菜单项存在是 v0.2 的实测旁证，但**没有**把它当作 `openTerminal` 语义动作验证过） |
| 14 | `openSideChat` | — | ✅ `View > Show Side Chat`（`⌘;`） | — | — | **未验证**（同上；另 `⌘;` 是 "Toggle side chat"，与 Codex 的 `⌥⌘S` 不同键） |
| 15 | `archiveChat` | — | — | — | — | **未验证**（未调研；不要外推 Codex 的 `⌘⇧A`） |
| 16 | `pinThread` | — | — | — | — | **未验证**（相邻线索：`pin_code_session` = `⌘⌥P`；未确认语义等价） |
| 17 | `forkThread` | — | — | ⚠️ `⌘⌥enter` 是 "Send in a forked session" —— **语义不同，不可当作 `forkThread`** | — | **未验证**（明确记录为「不要用」） |

**Claude 深链能做的事**（4 条动作型路由，来源: research-claude-desktop.md §3.2，静态推断；仅 `resume` 路由的非法参数分支是实测验证）：

```text
claude://code/new?q=&folder=&file=     新建 Code 会话
claude://code/continue?session=last    打开最近 Code 会话
claude://code/needs-input              跳到等权限答复最久的会话
claude://resume?session=<uuid>         导入 CLI 会话记录并继续
```

**这 4 条没有一条对应 §7 的任何语义动作** —— 它们是「会话级跳转」，不是「会话内动作」。它们可作为后续版本的补充动作（如 `openSessionNeedingInput`），但**不能用来实现本版的任何一格**。

### 7.3 矩阵的四个关键读数

1. **能用程序化接口完成的语义动作：0 个**（两个 App 都是 0）。唯一沾边的是 Codex 的 `codex queue`，但它「是否被运行中的 App 采纳」未验证（§9 U4）。
2. **能用原生菜单点击完成的语义动作：Claude 若干**（`navigateLeft` / `navigateRight` 的历史语义、`inspectChanges`，以及新增动作里的 `openTerminal` / `openSideChat` 菜单项，但后者语义未验证）；**Codex 0 个**（Codex 菜单里没有任何业务动作，只有窗口与面板级操作，来源: research-codex-desktop.md §4.7，实测验证）。
3. **必须靠按键注入：Codex 16 / 17**（唯一例外是 `openPermissionModeMenu` = unavailable），**Claude 11 / 11（v0.2 口径）**。这是本版的安全模型必须比 v0.1 更严的根本原因（§13）。
4. **v0.3 的核心增量**：Codex 侧可用动作从 v0.2 的 10 个变成 **16 个**（新增 `newChat` / `openTerminal` / `openSideChat` / `archiveChat` / `pinThread` / `forkThread`，其中前 5 个零配置），**`queueFollowUp` 从缺口变成可达**，`toggleFastMode` 从「面板兜底」变成「绑一次键」。

---

## 8. 能力缺口与降级方案

每个缺口给出**明确降级或明确不可用**，不含糊。缺口编号 G1–G5 供实现与测试引用（v0.2 的 G1–G4 编号保留；**G4 的含义在本版收窄**，G5 为 v0.2 的 G5 保留位）。

### G1. Codex 桌面 App 没有权限模式动作（`openPermissionModeMenu` 不可用）

- **事实（三条独立证据链）**：
  1. **131 条命令注册表**：权限相关只有 `approval.approve`（`Enter`）与 `approval.decline`（`Esc`），没有任何 permission-mode / sandbox-mode / mode-cycle 类命令；渲染进程 bundle 里 grep `Shift+Tab`：`app-primary.js` 0 次，`app-initial.js` 的 3 次全部属于 `previousTab`。（来源: research-codex-desktop.md §5.5，实测验证）
  2. **Micro 的 33 条可分配动作清单**：只有 `approve` / `reject` 这种**一次性审批**语义，没有「切换权限模式」。（来源: research-codex-micro-mapping.md §4.3，实测验证）
  3. **Codex 桌面 App 的审批模型**：审批是**按请求**的 `approve` / `decline`，不是「当前会话处于哪种权限档位」的状态机。（来源: research-codex-micro-mapping.md §4.3，静态推断，与 1、2 一致）
- **为什么无法绕过**：唯一可能程序化改权限档的路径是 app-server 的 `thread/settings/update` / `permissionProfile/list`，但桌面 App 的 app-server 挂在 **stdio 私有管道**上，外部进程拿不到（来源: research-codex-desktop.md §2.2，实测验证）。
- **降级方案（二选一，需人类拍板，见 §26 Q3）**：
  - **D1-a（推荐，安全侧）**：`openPermissionModeMenu` 在 Codex 上标记为 **unavailable**。按下 `B + ↑` 时（若用户把它绑到手势上），menu bar 浮层提示「Codex 桌面版没有权限模式菜单，请用审批卡上的 A/B」，**不注入任何按键**。
  - **D1-b（功能侧，有风险，已否决）**：把它重映射为 `approval.approve`（`Enter`）。**⚠️ 这会让「想切模式」变成「批准一次操作」，语义完全错位，且踩到 v0.1 §17 的「不提供一键 approve」红线。不推荐。**
- **绝不允许**：把 `B + ↑` 静默映射成某个「看起来像」的键（例如 `⌘K` 后盲打命令名），因为这会在用户不知情的情况下改变权限档。**本版进一步要求：Codex profile 下该动作必须显式返回 `unavailable` + 用户可见提示，禁止任何静默替换。**

### G2. Claude 的权限模式「循环」语义做不到（沿用 v0.2）

- **事实**：Claude 桌面 Code 面板只有 `openModeMenu`（`⌘⇧M`，打开菜单），**没有循环动作**；菜单项要用 `1…9` 选择。（来源: research-claude-desktop.md §4.2 / §7.1，静态推断）
- **缺口本质**：真正的「循环」需要「读取当前模式 → 计算下一档 → 选中」，即需要 AX 状态读取；而 Code 面板的 AX 元素标识**尚未探明**（来源: research-claude-desktop.md §5.7，未验证）。
- **降级方案（推荐，两段式）**：
  - `openPermissionModeMenu` → 注入 `⌘⇧M` 打开 mode menu，浮层提示「用方向键选择后按 A 确认」。
  - **不做**「打开菜单 + 盲发 `1`」这种伪循环：菜单项顺序未验证，盲选可能选到 `bypassPermissions` 一类高风险档（v0.1 §17 / 本版 §13 明令禁止）。
- **动作名必须叫 `openPermissionModeMenu`**：Claude 侧本来就只是「打开菜单」，叫 `cycle*` 是错的（F5）。

### G3'. Codex 的 `toggleFastMode` 无默认快捷键、也不在命令面板（**v0.2 此处有误，v0.3 修正**）

- **事实（修正后）**：`composer.toggleFastMode` 存在于命令注册表，**没有 `defaultKeybindings`**，**且没有 `commandMenu:true`**（i18n 描述是 `Shortcut settings row for toggling Fast mode`，而面板项的措辞是 `Command menu item to …`）。（来源: research-codex-micro-mapping.md §2.2 / §2.3 / §5.1，实测验证）
- **v0.2 的错误**：把 `⌘K` 命令面板写成它的兜底通道（§7.1 行 9、§8 G3 的 D3-a）。**该路径不存在。**
- **可用的三条路（重排）**：
  - **D3-a（推荐，本版新增）**：引导用户在 **Codex 的 Settings → Keyboard Shortcuts** 里给 `composer.toggleFastMode` 绑一个键（该设置页可搜索、可逐命令录制；`shortcutConfigurable !== false`）。绑定后该键在任何窗口（含 electron）生效，此后我们用按键注入触发。**属于 C 类：一次性配置负担。**
  - **D3-b**：放弃，标记不可用，只提示用户。
  - **D3-c（降级为实验性）**：仍然走 `⌘K` 面板 —— 但**这不是「输入命令名」而是 macro**，且**面板里没有这条命令**，所以它连做都做不到。**否决。**
- **默认策略**：`toggleFastMode` **退出默认绑定**（§6.3），默认状态为「已定义 / 未绑定 / Codex 侧需先绑键」；menu bar 的 Capabilities 里给出 `Settings → Keyboard Shortcuts` 的操作指引。
- **本版明确保留的未知**：我们在 App 内**读不到**用户绑了什么键（落盘位置未验证，§9 U8/U24）。因此第一版实现里，用户绑完键后**必须把同一个键位也填进本 App 的 `keybindings` 配置**（§16）。

### G4（收窄）. Codex 的 `queueFollowUp` 不再是缺口；Claude 的 `queueFollowUp` 仍是缺口

- **Codex 侧（修正后）**：`composer.queue` / `composer.steer` 是**真实命令且有处理器**（`composer.queue` 以 `n0('composer.queue', S, {enabled:y})` 注册），只是没有默认键位。**用户绑一次键就能用**；另一条天然路径是运行中 `Enter`（受 `[desktop] followUpQueueMode = "queue"` 控制，`followUpSubmitAction = steer | queue`）。（来源: research-codex-desktop.md §5.4；research-codex-micro-mapping.md §2.2 注 `CODEX` / §4.1，实测验证）
- **Claude 侧（不变）**：**无专用接口**。流式期间 `enter` 可能隐式排队（【未验证】）；`⌘⌥enter` 是 "Send in a forked session"，**语义不同，不可当 queue 用**。（来源: research-claude-desktop.md §7.1 / §8，静态推断 + 未验证）
- **降级方案**：
  - Codex：默认映射 `B + →`；首次使用时若检测到用户未绑键，浮层提示两条路（「在 Codex 里绑 `composer.queue`」或「保持运行中按 Enter」）。
  - Claude：`B + →` 给出明确不可用提示，**不注入任何可能误触的键**。
- **绝不允许**：把 Claude 的 `⌘⌥enter` 当作 `queueFollowUp`（那是 fork-session 语义）。

### G5. `navigate*` 在两边都只能注入方向键，语义随焦点变化（沿用 v0.2 G4 的内容）

- **事实**：Codex 注册表里**没有**通用 navigate 命令，`↑/↓` 只出现在各上下文（`select:previous`、`autocomplete:previous`、`footer:up`…，来源: research-codex-desktop.md §6，静态推断）；Claude 侧 `⌘⌥↑/↓` 是「提示级跳转」而非「列表导航」（来源: research-claude-desktop.md §7.1，静态推断）。
- **降级方案**：
  - 把 4 个 `navigate*` 统一标记为 **`ActionRisk.navigation`**（§14.5）。
  - 仅在「目标 App 是 frontmost 且 Pass 1 守卫通过」时注入，且**永不进入 macro 路径**（不弹命令面板、不输入文本）。
  - menu bar / debug monitor 必须显示 `TARGET` 与当前 surface，让用户知道方向键会被谁吃掉。
  - **明确的不可用边界**：当焦点在内置浏览器标签页或终端面板时，方向键的语义**完全不同**（来源: research-codex-desktop.md §7 风险 1，静态推断）。这种情况本版**不做自动判定**，只在 menu bar 显示警告（完整 surface 感知是 Phase 5，§22）。

### G6（附带）. `submit` 在两个 App 的语境存疑

- **Codex 侧（本版更新）**：`composer.submit` 在注册表里**没有默认键位**，它是以 `n0('composer.submit', handler, {enabled})` 注册的处理器；composer 聚焦时的回车提交是**组件内部逻辑**（未逐字验证按键分发分支）。（来源: research-codex-micro-mapping.md §2.2 注 `CODEX` 与 §5.4 未验证项 3）
- **Claude 侧（不变）**：Code session `Composer` 分组里**没有** `enter` / `shift+enter` 条目；`enter` → "Send message" 只出现在 chat/cowork 列表里。（来源: research-claude-desktop.md §4.3，静态推断）
- **实现要求**：代码里不得把「`enter` 一定提交」写成既定事实。首次在对应面板使用 `submit` 时做一次轻量自检（见 §9 U10 的验证方案），或在 UI 上提供「submit 键位可配置」开关。
- **降级**：若实测发现某语境下 `Enter` 不提交，则**没有已验证的替代键位**（`⌘⌥⏎` / `⌘⏎` 语义不同，不可用），此时应把 `submit` 在该面板标记为**不可用 + 提示**，而不是猜一个键。

---

## 9. 未验证项清单

**本节的用途**：把三份调研中所有「未验证」的结论集中列出，并标注**验证它会有什么副作用**。任何实现者在写代码前若需要依赖表中某项，必须先完成验证并把结果写回本文档（或 `docs/hardware-probe.md` 的同级文档）。

**先看副作用的分类**（决定了「什么时候能验」）：

| 副作用等级 | 含义 | 典型场景 |
|---|---|---|
| **零副作用** | 只读或非法参数探测，不改用户状态 | 读 AX 树、grep bundle、`open claude://resume?session=not-a-uuid` |
| **改 UI 状态** | 会切换/新建/关闭窗口或面板，不改会话内容 | 发 deep link、点菜单、开 Code 会话、按 `⌘N` / `⌃\`` / `⌥⌘S` |
| **改会话数据** | 会往用户真实会话里写内容、触发一轮 turn、改权限档 | 注入 `Enter`、`codex queue`、`thread-follower-*`、按 `⌘⇧A` 归档 |
| **改运行环境** | 需要重启 App、加启动参数、装东西 | `--remote-debugging-port`、安装 CLI |

### 9.1 Codex 桌面 App

| # | 未验证项 | 为什么没验 | 验证的副作用 | 等级 |
|---|---|---|---|---|
| U1 | `codex://` deep link 的**端到端 UI 行为**（真的 `open -g "codex://..."` 之后发生什么） | 会改变正在运行的用户 App 的 UI 状态（可能新建会话、弹设置窗口） | 改 UI 状态 | 未验证 |
| U2 | `~/.codex/ipc/ipc.sock` 上 `thread-follower-*` 系列（start-turn / interrupt / steer / approval decision）是否有人应答 | 全部是变更操作，在真实会话上触发会污染用户数据；只测了只读的 `thread-owner-discovery` → `no-client-found` | **改会话数据**（严重） | 未验证 |
| U3 | 桌面 App 的 app-server 是否通过 fd 传递接入了 IPC 总线 | `lsof` 看不到第二方持有 `ipc.sock` 路径，但 fd 传递可以不显示路径 | 零副作用（可做 fd 追踪） | 未验证 |
| U4 | `codex queue --thread <id> --message` 对**运行中的桌面会话**是否真的生效 | 需要往用户会话写数据 | 改会话数据 | 未验证 |
| U5 | 运行中按 `Enter` 是否真的走 queue（而非 steer） | 同上；`followUpQueueMode = "queue"` 的分支是【代码】级结论 | 改会话数据 | 未验证 |
| U6 | **17 个动作的实际按键效果**（键位存在 ≠ 按下去有预期效果） | 需要把手柄/键盘事件真的打给正在运行的用户 App | 改会话数据 / 改 UI 状态 | 未验证 |
| U7 | 打包后的 Swift App 是否拿到 Accessibility 授权 | 本次只证明了**当前终端**有 AX 权限；签名 App 的 TCC 授权是另一回事 | 改运行环境（需授权） | 未验证 |
| U8 | 快捷键自定义（`set-codex-command-keybinding`）的落盘位置 | 只看到 IPC handler 存在，存储介质没追到底 | 零副作用（读文件系统） | 未验证 |

补充（对桌面 App 无用但记录在案）：Codex TUI 的默认键位表**未能从二进制确定**（Rust `&str` 字面量首尾相连无 NUL 分隔，无法可靠切分）；未做 `/keymap` 交互抓屏。因为本版不用 TUI，**不列为待办**。（来源: research-codex-desktop.md 附录 A.4）

### 9.2 Codex Micro 调研新标记的未验证项（v0.3 新增）

| # | 未验证项 | 为什么没验 | 验证的副作用 | 等级 |
|---|---|---|---|---|
| **U24** | **我们能否读到用户在 Codex 里绑的自定义键**（`keymapState.bindings` / `codex-command-keymap-state` 的**持久化位置**与格式） | 只确认了 IPC `set-codex-command-keybinding` 与 state key 名，**没有追到落盘文件**；U8 是同一条链路的另一面 | 零副作用（读 `~/Library/Application Support` / `~/.codex` 下的文件） | **未验证** |
| **U25** | **C 类 9 条动作「绑一次键即可用」的端到端链路**（用户绑键 → 我们注入该键 → Codex 真的执行对应命令） | 需要让用户先在 App 内绑键，再真的往运行中的 App 注入按键 | 改会话数据 / 改 UI 状态 | **未验证** |
| **U26** | **B 类 8 条动作在命令面板里的模糊匹配行为**（输入部分标题能否命中、`Enter` 是否选中第一项） | 面板只确认了 filter 回调是 `mwo`（`Math.max(m3(value), m3(keywords...))`），未运行验证边界行为；且需要打开面板并注入文本 | 改 UI 状态 + macro（文本注入） | **未验证** |
| **U27** | **`environmentAction1`（`runAction`，`⇧⌘D`）的真实语义** | 注册表有默认键位，但**全 App 打包产物里搜不到 `environmentAction*` 的处理器注册**；实际行为取决于工作区 environment action 配置 | 未知（可能触发工作区自定义动作） | **未验证** |
| **U28** | **`:yeet:` / `:yolo:` 写入输入框之后的下游处理**（是否有 skill 展开、是否有特殊语义） | 只确认这两个动作是「插入字面文本」，未验证下游 | 改会话数据（一旦误提交） | **未验证** |
| **U29** | **`approval.approve` / `approval.decline` 的 `enabled` 门控具体实现**（是否只在审批卡上 enabled） | 已知它们在「审批卡上下文」生效，未逐行验证门控条件 | 零副作用（读代码）/ 改会话数据（实按） | **未验证** |
| **U30** | **`newChat` 等 5 条新默认动作在「非会话界面」下的行为**（如设置页 frontmost 时按 `⌘N`） | 注册表键位是实测的，但**没有验证**各 surface 下的实际反应 | 改 UI 状态（可能新建会话） | **未验证** |
| **U31** | **用户绑键的数量下限**：9 条 C 类动作里，本项目的 3 个（`toggleFastMode` / `forkThread` / `queueFollowUp`）是否真的都能绑到不冲突的键 | 需要用户实际操作 Settings 页并观察冲突 | 改运行环境（改用户 App 设置） | **未验证** |

### 9.3 Claude 桌面 App（v0.2 原表，本版未重新调研）

| # | 未验证项 | 为什么没验 | 验证的副作用 | 等级 |
|---|---|---|---|---|
| U9 | `claude://code/new`、`claude://code/continue`、`claude://code/needs-input` 三条**动作型深链**的真实行为 | 会真的新建/切换用户会话，属破坏性副作用 | 改 UI 状态（可能新建会话） | 未验证 |
| U10 | **Code 面板的 AX 元素标识**（各按钮/控件的 AX 属性） | 需要先打开一个 Code 会话 | 改 UI 状态 | 未验证（**这是 §22 Phase 3 的前置第一工作项**） |
| U11 | `queueFollowUp` 在桌面端的确切语义（可能是流式期间 `enter` 的隐式行为） | 未找到对应动作 | 改会话数据 | 未验证 |
| U12 | `esc` 在「运行中」vs「空闲」下的差异 | 需真实运行中的会话 | 改会话数据 | 未验证 |
| U13 | 「通过 DevTools 或 `--remote-debugging-port` 注入渲染进程再调 IPC」是否可行 | 需重启 App 加参数 | 改运行环境 | 未验证（**本版明确不做**） |
| U14 | `~/.claude/keybindings.json` 是否影响桌面 App | 该文件当前不存在 | 零副作用（用 `CLAUDE_CONFIG_DIR` 指向临时目录对比 CLI 即可） | 未验证（桌面端大概率不受影响） |
| U15 | `ion-dist` Code 面板的实际加载 URL / 由哪个 BrowserWindow 承载 | 未能运行时抓取 | 零副作用（开 DevTools 或看 `main.log`） | 未验证 |
| U16 | `~/.claude/daemon/` 的 wire protocol 与 `control.key` 用法 | 超出「桌面 App」范围，且可能触发认证流程 | 改运行环境 / 可能触发认证 | 未验证（**与桌面 App 无关，不在本项目范围**） |
| U17 | `claude-desktop` 命令是否存在 | 未在该版本安装（i18n 里有文案但二进制没有） | 零副作用 | 未验证 |
| **U32** | **Claude 侧本版新增的 6 个语义动作**（`newChat` / `openTerminal` / `openSideChat` / `archiveChat` / `pinThread` / `forkThread`）的键位与语义 | **本版没有对 Claude 重新调研**（§7.2 范围声明） | 零副作用（读 bundle/AX）→ 改 UI 状态（实按） | **未验证** |

### 9.4 硬件侧仍然开着的小口子（来自 Phase 0）

| # | 未验证项 | 验证的副作用 | 等级 |
|---|---|---|---|
| U18 | 泛用 C 变体的 6 输入映射、chord、长按重复、泄漏均**未测**（只做了最小验证） | 零副作用（纯探针） | 未验证 |
| U19 | T 档完全未采集 | 零副作用（纯探针） | 未验证 |
| U20 | H 模式第二变体未知（说明书未记载） | 零副作用（纯探针） | 未验证 |
| U21 | 斜向 D-pad（HatSwitch 2/4/6/8）在本设备上从未产生，但**不能据此认为永远不会** | 零副作用（纯探针） | 未验证 |
| U22 | 权限行为未在**正式打包 App** 里验证（Accessibility / Input Monitoring，尤其重签后授权失效） | 改运行环境 | 未验证 |
| U23 | 结论绑定当前系统版本（macOS 27.0 beta `26A428` + Xcode 27 beta）；`shouldMonitorBackgroundEvents` 默认值与 GC 对第三方 BLE 手柄的接纳策略属系统行为 | 大版本升级后重新验证 C1/C2 | 已知风险 |

来源: phase0-summary.md §7，实测验证（这些是「实测后仍未覆盖的空白」，非猜测）。

### 9.5 验证纪律

- 任何 U 项一旦验证，**必须把结论与命令写回文档**（Codex 侧写回 `docs/research-codex-desktop.md` 或 `docs/research-codex-micro-mapping.md` 或本文档 §7/§9 的对应行；Claude 侧同理），并把证据等级升级。
- **U2 / U4 / U5 / U6 / U11 / U12 / U25 属于「改会话数据」**：验证前必须先获得用户明确同意，并且优先在**可牺牲的会话或账号**里做。
- **U25 / U26 / U30 属于「A/B 类动作的行为验证」**：是本版新结论的直接待办，优先级高于 v0.2 的 U1/U9。
- 本文档 §7 矩阵里凡标【静态推断】的格子，都隐含一个 U 项（U6 / U11 / U12）。

---

## 10. 风险登记

| # | 风险 | 影响 | 证据等级 | 缓解措施 |
|---|---|---|---|---|
| **R1** | **Anthropic 自带蓝牙硬件伴侣**（`hardwareBuddyEnabled` / `buddy-ble`）可能干扰我们的蓝牙扫描 | 手柄扫描/连接不稳定、配对失败 | 实测验证（App 日志里有 `[buddy-ble] scan timeout — saw 0 stick(s), none matched` / `pair: result=false`；`--desktop-features` 含 `hardwareBuddyEnabled`；菜单有 `Developer > Open Hardware Buddy…`）（来源: research-claude-desktop.md §5.8） | ① 不依赖主动扫描发现手柄——优先用 GameController 的已配对设备列表与 `IOHIDManager` 的已连接设备枚举，而不是 `--discover` 式扫描；② 文档化提示用户关掉 Hardware Buddy；③ 若出现连接抖动，先排查 Buddy |
| **R2** | `claude://` 深链可被托管配置 `disableDeepLinkRegistration` **整体关闭** | Claude 侧唯一实测可用的程序化投递通道**整体失效**（企业策略置位时） | 静态推断（`if (U().authentication.disableDeepLinks) { ... "claudeURLHandler: dropping deep link (disableDeepLinkRegistration)" }`）（来源: research-claude-desktop.md §3.4） | ① **实现时必须探测这个开关**（App 启动时与每次投递失败时）；② 探测到关闭 → 把 delivery tier 直接降到「菜单点击 / 按键注入」，并提示用户；③ **不要把任何语义动作的可用性押在深链上**（本版本来也只有 0 个动作依赖它） |
| **R3** | **Codex IPC 总线能力未验证**（`~/.codex/ipc/ipc.sock`） | 若被当作控制面，会在真机上表现为「能连上、发请求永远 `no-client-found`」，或更糟：验证变更类方法时污染用户会话 | 实测验证（可连接、可 `initialize`、`thread-owner-discovery` → `no-client-found`）+ 未验证（`thread-follower-*` 是否有人应答） | **本版不押注**：不实现、不调用、不做 fallback。仅作为后续探索方向（用 fd 追踪确认 app-server 是否在总线上）。任何实现代码中**禁止出现 `ipc.sock` 的写操作** |
| **R4** | **同 App 内 surface 歧义**（chat / cowork / code 三种面板语义不同） | 同一个键（如 Claude 的 `⌘K` / `⌘⇧D` / `⌘⇧M`、Codex 的 `⌘K`）在不同面板含义不同 → **误触** | 静态推断（Claude `extended_thinking` = `⌘⇧E` 与 `openEffortMenu` = `⌘⇧E` 冲突；Codex 焦点在内置浏览器/终端面板时同一键含义完全不同）（来源: research-claude-desktop.md §4.4、§7.3；research-codex-desktop.md §7 风险 1） | 见 §11.3：本版做**最小 surface 判定**（菜单 `enabled` 状态 + 窗口标题），不做完整 AX 特征识别；所有 macro 动作额外要求显式确认 |
| **R5** | 无菜单项的命令由**渲染进程**处理，**窗口失焦即失效**；原生菜单快捷键在 App 失焦时同样不触发 | 「后台遥控」不可能；事件可能打到错误的 App | 实测验证（来源: research-codex-desktop.md §7 风险 3） | ① Pass 1 守卫强制要求 frontmost app ∈ allowlist（§11.1）；② 每次投递前重新读 frontmost，不用缓存值；③ 失焦时不投递，只更新 menu bar 状态 |
| **R6** | **Accessibility 授权**：打包签名后的真实 App 需要自己的 TCC 授权；**重签后授权会失效** | 菜单枚举/点击、CGEvent 注入全部静默失败 | 实测验证（探针以无 bundle 方式跑；`docs/hardware-probe.md` §1.4 明确记录 ad-hoc 签名每次重建都要重新授权） | ① 启动时 `AXIsProcessTrustedWithOptions`，未授权时 menu bar 显式显示 `Accessibility Required` + 入口；② 不静默失败；③ 每次 CGEvent 投递失败要有可见计数（debug monitor） |
| **R7** | 快捷键可被用户改写（Codex 的 `set-codex-command-keybinding`、Claude 的 App 内设置） | 硬编码的键位在用户改过之后失效 | 实测验证（handler 存在，来源: research-codex-desktop.md §4.1）+ 未验证（落盘位置 U8 / U24） | 键位表放在配置文件中，不 hardcode 在 Swift source 里；提供「键位自检」流程（§22 Phase 3）；**C 类动作依赖用户绑键，必须先引导后使用**（R13） |
| **R8** | Codex `⌥Space`（`openAvatarOverlay`）是 `os-global` 全局热键 | 与系统快捷键冲突，也可能被我们的 chord 误触 | 实测验证（来源: research-codex-desktop.md §7 风险 2） | 配置手柄时检测冲突并在文档列出；不把 `⌥Space` 用于任何语义动作 |
| **R9** | **H 模式严重泄漏**：6 个键全部作为普通按键进入前台 App（A = `Enter`、B = `Space`），且随 OS key repeat 重复 | 用户在 H 档时，按手柄 = 往当前 App 打字（实测在 TextEdit 里插入了 19 个空格） | 实测验证（来源: phase0-summary.md §2 Q9 / hardware-probe.md §5.4） | ① H 档不做输入源；② 设备匹配按 product+usage，绝不能按 usage class 打开监听（否则会连用户内置键盘一起听，`hardware-probe.md` §5.5 实测 921/1057 条来自内置键盘）；③ 检测到 H 档立即在 menu bar 提示切回 C 档 |
| **R10** | **日志隐私**：`--with-keyboard` 模式日志包含用户真实键盘输入 | 泄漏用户输入 | 实测验证（`docs/hardware-probe.md` §1.4 / §5.5） | ① 正式 App **不做**键盘级日志；② `logs/*.jsonl` 已在 `.gitignore`，**不要外发**；③ 调试模式默认关闭，打开时 UI 显式警告 |
| **R11** | 系统行为随 macOS 大版本变化（`shouldMonitorBackgroundEvents` 默认值、GC 对第三方 BLE 手柄的接纳策略） | 现有实测结论失效 | 实测验证（结论绑定 macOS 27.0 beta `26A428`）（来源: phase0-summary.md §7） | 启动时记录 OS 版本；大版本升级后**重新验证 C1 / C2**；把这两条做成启动自检项 |
| **R12** | U 项验证本身有副作用（改会话数据 / 改 UI 状态） | 污染用户真实会话、打断正在跑的任务 | 见 §9 | 所有「改会话数据」级验证必须先取得用户同意，优先在可牺牲环境做 |
| **R13（v0.3 新增）** | **C 类动作需要用户手动绑键，属于一次性配置负担** | 本版默认映射里有 1 条（`queueFollowUp`），可选未绑定里有 2 条（`toggleFastMode` / `forkThread`）依赖用户在 Codex 的 Settings → Keyboard Shortcuts 里先绑键；用户不绑，动作就不可用。此外，**我们在 App 内读不到用户绑了什么键**（U8 / U24），用户必须在两处各填一次 | 实测验证（设置页与 IPC 存在：`set-codex-command-keybinding`、`shortcutConfigurable !== false`）+ 未验证（落盘位置） | ① menu bar 的 `Capabilities` 必须显示每条动作的**可达类别**（A/B/C/D）与「未绑定」状态；② 提供**一次性引导流程**：列出需要绑的 3 个命令 id（`composer.queue`、`composer.toggleFastMode`、`forkThread`）、给出建议键位、并在用户绑完后写入本 App 的 `keybindings`；③ 提供「键位自检」：注入一次后由用户确认是否生效（U25）；④ 不把 C 类动作放在「零配置可用」的承诺里 |
| **R14（v0.3 新增）** | **命令面板不是兜底**：面板只收录 63/131 条命令，且按标题模糊匹配 | 任何「用 `⌘K` 兜底」的设计都会在具体命令上静默失败（v0.2 的 D3-a 就是实例） | 实测验证（`$ji(e) = kind==='webview' && commandMenu===true`，63/131）（来源: research-codex-micro-mapping.md §2.1 / §5.1） | ① 把 `⌘K` + 文本注入**一律归类为 macro**（默认关闭）；② 在 `CapabilityMatrix` 里对 B 类动作记录「面板标题原文」（搜索用），不靠猜命令名；③ 任何依赖面板的动作，其证据等级最高只能到【静态推断】+【未验证】（U26） |
| **R15（v0.3 新增）** | **`browser.defaultKeybindings` 误用**：文档/实现可能把 browser 段键位当成桌面 App 键位 | 硬编码了在桌面 App 上根本不生效的键位（`⌘U`、`⌘K` 搜索聊天） | 实测验证（`lMi`：`t !== 'electron'` 才查 browser 段）（来源: research-codex-micro-mapping.md §2.1 路径 ①） | ① 键位表的来源必须标注**来自 `electron.*` 还是 `browser.*`**；② `browser.*` 的键位一律不许进默认映射；③ 加一条单测断言 `⌘U` / `searchChats` 不在 Codex 默认键位表里 |

---

## 11. 目标应用守卫与 surface 感知

（沿用 v0.2 §11，动作名同步更新。）

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
| **Macro action**（文本注入，如 B 类的命令面板路径、D 类的 composer-text） | 额外要求 `macrosEnabled == true` **且** 用户对该动作显式启用 |

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
- Codex 侧菜单没有业务动作（来源: research-codex-desktop.md §4.7，实测验证），因此 Pass 2 对 Codex 不适用。**这是 Codex 侧 16 个动作必须靠按键注入的直接原因。**

### 11.3 Pass 3 —— surface 感知（本版做最小版）

**问题**：同一个 App 里有 **chat / cowork / code** 三个面板，语义不同。

- Claude 侧：`⌘⇧D` 在 Code 面是 Toggle changes；`⌘K` 在 chat 与 code 面语义不同；`openModeMenu`（`⌘⇧M`）只在会话面板有意义。（来源: research-claude-desktop.md §7.3 硬约束 1，静态推断）
- Codex 侧：快捷键要求 App 在前台，且「焦点在内置浏览器标签页或终端面板时，同一个键的含义完全不同」。（来源: research-codex-desktop.md §7 风险 1，静态推断）

**最小实现（不做完整 AX 特征识别）**：

1. **可用信号**（都是零副作用读取）：
   - Claude：`Go > Code` 菜单项的 `enabled` 状态；menu bar 是否有 Code 专属项被 enable；窗口标题。
   - Codex：`⌃1..⌃3`（`switchToMode1..3` = Chat / Work / Codex）的存在本身说明有三个 mode（来源: research-codex-desktop.md §5.2，实测验证）；窗口标题。
2. **判定策略**：只区分 `chatLike` / `codeLike` / `unknown` 三态。
3. **动作分级**：
   - `codeLike` 明确 → 允许投递 Code 专属动作（`inspectChanges`、`toggleFastMode` 等）。
   - `chatLike` 明确 → 只允许 base layer（方向键 / `submit` / `cancelOrInterrupt`）与**会话级动作**（`newChat` / `pinThread` / `archiveChat` / `openSideChat`）；Code 专属动作降级为提示。
   - `unknown` → 只允许 base layer，**禁止 macro**。
4. **本版明确不做**：完整 AX 特征识别、按会话 id 跟踪、跨面板状态机。这些留给后续（依赖 §9 U10）。

> ⚠️ **v0.3 新增的 surface 风险**：`archiveChat`（`⌘⇧A`）与 `forkThread` 会产生**持久状态变化**。建议把这两个动作在 `unknown` 与 `chatLike` 下都降级为提示，只在 `codeLike` 明确时投递。

### 11.4 profile 的退化用法

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
│   ├── StatusMenu              # 连接状态 / 变体 / surface / 权限 / 可达类别
│   ├── TargetAppPicker         # §11.4
│   └── ActionOverlay           # 不可用动作的提示浮层（G1–G6）
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
│   ├── AgentAction.swift             # §14.4 的 17 个动作
│   ├── ActionResolver.swift
│   ├── ActionAvailability.swift      # v0.3 新增：可达类别 A/B/C/D + 默认绑定 vs 可选未绑定
│   └── CapabilityMatrix.swift        # §7 矩阵的代码化：每个 (action, app) → tier + evidence + category
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
│   ├── KeybindingTable.swift         # 两个 App 的默认键位（不 hardcode 在 logic 里）；标注 electron/browser 来源
│   └── UserBindingGuide.swift        # v0.3 新增：C 类动作的一次性绑键引导 + 自检（R13）
│
└── Debug/
    ├── InputMonitorView.swift
    └── EventLogger.swift             # 默认关闭；不含键盘级日志（R10）
```

### 12.1 关于 `ProgrammaticDelivery` 的实现边界

- **允许**：`open -g <deep-link>`（Claude 的 4 条动作型路由 + `codex://launch` 一类的无害路由）。
- **禁止**：`~/.codex/ipc/ipc.sock` 的任何请求（R3）；`--remote-debugging-port` 注入（U13，本版明确不做）；**任何 Work Louder / Codex Micro 私有协议的模拟（§5.1）**。
- **可选**：`codex queue`（属 `queueFollowUp` 备选）。默认**关闭**，因为「运行中 App 是否采纳」未验证（U4）；开启时必须提示用户这是实验性路径。

---

## 13. 安全模型

（保留 v0.1 §17 的全部 MUST，按桌面 App 重新表述，并补 6 条新约束。）

### MUST

- 默认 `macrosEnabled = false`
- 任何文本注入（命令面板输入、slash command、`:yeet:` / `:yolo:` 一类 composer-text）都属于 macro
- tool-specific 动作只能在**明确的目标 App 上下文**下运行（§11.1）
- frontmost app 必须通过 allowlist
- **菜单点击前必须读 `enabled`**（Claude Code 面板项天然 disabled，§11.2）
- **不允许盲发数字键选择菜单项**（G2：菜单项顺序未验证，可能选到高风险权限档）
- 不提供一键 bypass permissions
- 不提供一键执行 arbitrary shell command
- **不映射 `approve forever` / `approve for session` / `approve for prefix` 到单击**（桌面 App 上本来也只有 `approval.approve` 单次批准；`approve_for_session` / `approve_for_prefix` 只存在于 Codex TUI 的 approval 段，桌面 App 没有）
- 任何 modifier 注入后必须保证 release（v0.1 §11.2 的 `keyDown mod → keyDown key → keyUp key → keyUp mod` + cleanup）
- app quit / sleep / disconnect 时清空 internal button state（**两条输入路径都要**，C7）
- **不把 deep link 当作任何语义动作的依赖**（R2）
- **不写 `~/.codex/ipc/ipc.sock`**（R3）
- **H 档不做输入源**（R9）
- **（v0.3 新增）不实现、不模拟 Work Louder / Codex Micro 私有协议，不申请受限 entitlement 去伪造 HID 设备**（§5.1）
- **（v0.3 新增）`openPermissionModeMenu` 在 Codex profile 下必须返回 `unavailable`，禁止静默替换成 `approve`**（G1）
- **（v0.3 新增）不新增 `approve` / `reject` 两个与 `submit` / `cancelOrInterrupt` 同键的重复动作**（§14.4）
- **（v0.3 新增）`archiveChat` / `forkThread` 这类产生持久状态变化的动作，在 surface 非 `codeLike` 时降级为提示**（§11.3）
- **（v0.3 新增）C 类动作不得伪装成「零配置可用」**：UI 必须显示其「需先绑键」状态（R13）
- **（v0.3 新增）键位来源必须可追溯**：`browser.*` 的键位不许进默认映射（R15）

### Permission prompts（沿用 v0.1 的策略，桌面 App 上依然成立）

```text
A = Enter / selected confirmation     → 在审批弹层里即 approval.approve
B = Escape / decline / cancel         → 在审批弹层里即 approval.decline
```

- Codex 侧：`approval.approve`（`Enter`）与 `approval.decline`（`Esc`）**只在审批卡上下文生效**（来源: research-codex-desktop.md §5.2，实测验证）——把 A/B 交给 App 自己的 UI 决定最终语义，正是 v0.1 这条策略的价值。
- 不要绕过确认层。**特别是 G1 的降级方案 D1-b 被否决的理由就在这里**：把权限菜单动作变成 `Enter` 会让它落到审批卡上时变成「批准」。
- **（v0.3 明确化）`submit` 与 `cancelOrInterrupt` 是这两个语义的唯一载体**：语义动作层不重复定义 `approve` / `reject`（§14.4）。

---

## 14. 核心接口

（v0.2 §14 的调整版。最大变化是 §14.4 的语义动作集重定与 §14.10 的可达类别。）

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

### 14.2 Device 与变体（不变）

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
    case hold(PhysicalButton)                            // B hold alone ⇒ 与 tap 同义（§6.4）
    case chord(modifier: PhysicalButton, key: PhysicalButton)
}
```

不做 double-tap（v0.1 理由保留：会增加单击判定延迟）。**注意**：Codex Micro 的设备端支持「单击 / 双击 agent 键」识别（`HN = 350` ms 窗口），但那是**设备固件**行为，我们不在自己的手势引擎里复刻（§5.3）。

### 14.4 Semantic actions（v0.3 重定：17 个）

```swift
enum AgentAction: String, Codable, CaseIterable {
    // 导航（默认绑定）
    case navigateUp, navigateDown, navigateLeft, navigateRight     // 4

    // composer / turn 控制（默认绑定）
    case submit, cancelOrInterrupt                                 // 2
    case queueFollowUp                                             // 1

    // 会话与工作区（v0.3 新增；部分默认绑定，部分可选未绑定）
    case newChat, archiveChat, pinThread, forkThread               // 4
    case openSideChat, openTerminal                                // 2

    // 模式与面板
    case openModelPicker, inspectChanges                           // 2
    case toggleFastMode                                            // 1（可选未绑定）
    case openPermissionModeMenu                                    // 1（可选未绑定；Codex 侧 unavailable）
}   // 合计 4 + 3 + 6 + 4 = 17
```

#### 14.4.1 新增的 6 个动作及其来源

| 新增动作 | 来源（Codex Micro 动作标签 / 命令 id） | 默认绑定？ | Codex 触发 |
|---|---|---|---|
| `newChat` | `new` / `newTask` | **是**（B+↑） | `⌘N` |
| `openTerminal` | `terminal` / `toggleTerminal` | **是**（B+↓） | `` ⌃` `` |
| `openSideChat` | `sideChat` / `openSideChat` | 否（可选未绑定） | `⌥⌘S` |
| `archiveChat` | `delete` / `archiveThread` | 否（可选未绑定） | `⌘⇧A` |
| `pinThread` | `pinThread` / `toggleThreadPin` | 否（可选未绑定） | `⌥⌘P` |
| `forkThread` | `split` / `forkThread` | 否（可选未绑定） | 需绑键（C 类） |

（来源: research-codex-micro-mapping.md §2.2 / §4.2，实测验证）

#### 14.4.2 重命名：`cyclePermissionMode` → `openPermissionModeMenu`（F5）

**理由**：

1. **Codex 桌面 App 完全没有权限模式动作** —— 131 条命令注册表里只有 `approval.approve` / `approval.decline`；Micro 的 33 条可分配动作清单里也没有权限模式动作；审批模型是 per-request 的，不是档位状态机。（三条独立证据，来源: research-codex-micro-mapping.md §4.3，实测验证 + 静态推断）
2. **Claude 侧只有 `openModeMenu`（`⌘⇧M`）打开菜单，没有「循环」语义**；真正的循环需要读当前模式再计算下一档，依赖尚未探明的 AX 标识。（来源: research-claude-desktop.md §4.2 / §7.1，静态推断）
3. 因此 v0.1 起的名字 `cyclePermissionMode` **从一开始就是错的**：它许诺了一个两个 App 都不存在的能力。

**强制要求**：

- **Codex profile 下该动作显式标为 `unavailable`**（§7.1 行 8 / §8 G1），返回 `nil` 的 delivery plan 并触发用户可见提示。
- **禁止静默替换成 `approve`**（D1-b 已否决）：那会把「想切模式」变成「批准一次操作」，是 v0.1 §17「不提供一键 approve」红线的直接违反。
- Claude profile 下保留两段式（打开菜单 + 用户用方向键选择后按 A 确认），**名实相符**。

#### 14.4.3 决定：不新增 `approve` / `reject`（F6，含理由）

Codex Micro 的键帽清单里有 `APPR`（Approve → `approval.approve`）和 `REJ`（Reject → `approval.decline`），调研文档也把它们列为「值得新增的语义动作」候选。**本项目决定不新增这两个动作**，理由如下：

1. **它们的默认键与现有动作完全相同**：`approval.approve` = `Enter`（= `submit`），`approval.decline` = `Escape`（= `cancelOrInterrupt`）。在物理输入只有 6 个的前提下，多定义两个语义动作**不会多出任何一个可绑定位置**，只会让同一个键有 2 个候选动作。
2. **同键多动作正是 G1 那个错误的成因**：D1-b（把权限菜单动作静默替换成 `approve`）之所以危险，就是因为 `Enter` 在审批卡上等于「批准」。如果动作表里再放一个 `approve`，实现者很容易在「想让手柄更好用」时把某个 chord 指过去。
3. **语义已经由 App 自己的 UI 决定**：v0.1 §17 / 本版 §13 的核心策略是「A = Enter、B = Escape，让 agent 的原生 UI 决定最终语义」。`submit` 在审批弹层里**就是** approve，`cancelOrInterrupt` **就是** reject —— 这不是近似，是同一个按键在同一个上下文里的同一个行为。
4. **代价可控**：失去的是「在审批卡上下文给出更精确的动作名与风险等级的展示」。这个需求用**上下文标签**满足即可：debug monitor / menu bar 在检测到 `hasActiveApprovalSurface` 时，把当前 A/B 的显示名标为 `submit → approve (approval card)`，而不新增动作。

**书面结论（实现时必须遵守）**：

```text
`submit` 在 Codex 的审批弹层里即 approve；
`cancelOrInterrupt` 即 reject。
语义动作层不重复定义 approve / reject。
```

### 14.5 Delivery tier 与 risk（调整）

```swift
enum DeliveryTier: String, Codable {
    case programmatic   // deep link / CLI / IPC（当前仅 Claude 4 条深链；不覆盖任何 AgentAction）
    case menuClick      // AXUIElement / System Events
    case keyInjection   // CGEvent
    case unavailable    // 明确做不到（G1 等），必须给出用户可见提示
}

enum ActionRisk: String, Codable {
    case navigation     // 语义随焦点变化（§6.1 的 4 个 navigate*）
    case normal         // submit / cancelOrInterrupt
    case macro          // 文本注入，必须 macrosEnabled
    case sensitive      // 产生持久状态变化或触碰权限/审批语义（默认映射里的 B 层动作 + 归档/分叉）
}
```

**风险分级口径（v0.3 明确化）**：

| 动作 | risk |
|---|---|
| `navigateUp` / `navigateDown` / `navigateLeft` / `navigateRight` | `.navigation` |
| `submit` / `cancelOrInterrupt` | `.normal` |
| `queueFollowUp` / `openModelPicker` / `inspectChanges` / `toggleFastMode` / `openPermissionModeMenu` / `newChat` / `archiveChat` / `pinThread` / `forkThread` / `openSideChat` / `openTerminal` | `.sensitive` |
| 文本注入类（B 类面板路径、D 类 composer-text） | `.macro` |

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
    let reachability: ReachabilityCategory // v0.3 新增：A/B/C/D
    let requiresUserKeybinding: Bool       // v0.3 新增：C 类动作必须先由用户绑键（R13）
    let isDefaultBinding: Bool             // v0.3 新增：默认绑定 vs 可选未绑定（§6.2 / §6.3）
}
```

**关键约束**：`delivery(for:)` 返回 `nil` **必须**导致用户可见提示（menu bar 浮层 / debug monitor 红字），**不允许静默无输出**。这是 G1–G6 的实现载体。

### 14.7 证据等级进代码（不变）

```swift
enum EvidenceLevel: String, Codable {
    case measured      // 实测验证
    case staticInfer   // 静态推断
    case unverified    // 未验证
}
```

`CapabilityMatrix.swift` 里每一格都带 `EvidenceLevel`，debug monitor 显示它；`unverified` 的动作首次使用时弹一次提示。

### 14.8 Output step（不变）

```swift
enum OutputStep: Equatable {
    case keyDown(KeyCode, modifiers: ModifierFlags)
    case keyUp(KeyCode, modifiers: ModifierFlags)
    case keyPress(KeyCode, modifiers: ModifierFlags)
    case text(String)              // macro；必须 macrosEnabled
    case delay(milliseconds: Int)
    case menuClick(app: String, path: [String])   // AX 菜单路径
    case openURL(String)                          // deep link（零副作用路由白名单见 §12.1）
}
```

### 14.9 ActionContext（扩展）

```swift
struct ActionContext {
    let frontmostBundleId: String?
    let surface: Surface                 // .chatLike / .codeLike / .unknown
    let variant: DeviceVariant
    let macrosEnabled: Bool
    let menuEnabled: [String: Bool]      // Pass 2 的结果缓存（每次投递前刷新）
    let hasActiveApprovalSurface: Bool   // v0.3 新增：审批卡上下文（用于把 submit/cancel 显示成 approve/reject）
    let responseInProgress: Bool         // v0.3 新增：运行中（queueFollowUp 与 cancelOrInterrupt 的语义前提）
}
```

> `hasActiveApprovalSurface` 与 `responseInProgress` 的**读取方式是【未验证】**（U29 / U6）。第一版允许它们是「由用户显式确认」或「保守取 false」，**不允许**靠猜测。

### 14.10 ReachabilityCategory（v0.3 新增）

```swift
/// 外部可达路径的分类，直接对应 §5.2 的 A/B/C/D 四类。
enum ReachabilityCategory: String, Codable {
    case a_defaultKeybinding   // 有默认键位，可直接注入（零配置）
    case b_commandMenu         // 无默认键位，命令面板可搜到（macro，默认关闭）
    case c_userBinding         // 无默认键位、面板也没有，需用户绑一次键
    case d_textOrURL           // 非命令机制（注入文本 / 打开 URL / 纯键转发）
    case unsupported           // 明确做不到
}
```

**用途**：menu bar 的 `Capabilities` 面板按此分类展示；`c_userBinding` 必须显示「需先绑键」并给出命令 id（R13）；`b_commandMenu` 必须显示面板标题原文（R14）。

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

### 15.2 输出（沿用 v0.1 §11 的三条纪律 + v0.2 的两条）

- **Key injection**：`CGEventCreateKeyboardEvent` + `CGEventPost`；首次启动 `AXIsProcessTrustedWithOptions`；未授权时 menu bar 显式显示且不静默失败。
- **Modifier handling**：`keyDown mod → keyDown key → keyUp key → keyUp mod`，macro 中途失败也要 cleanup 释放 modifier（否则 Shift/Option/Ctrl stuck）。
- **Serialization**：所有 recipe 在一个 `actor InputOutputEngine` 中串行执行，禁止两个 chord 的 CGEvent 序列交叉。
- **Menu click**：先用 AX 读 `enabled`，再 click；失败时**不自动 fallback 到按键注入**（避免「以为点了菜单，其实盲注了键」）。
- **Deep link**：只允许白名单路由；投递前探测 `disableDeepLinkRegistration`（R2）。
- **（v0.3 新增）C 类动作的前置检查**：投递前检查 `requiresUserKeybinding`，若用户尚未在本 App 的 `keybindings` 里填入键位，直接走提示路径，**不猜键位**（R13）。
- **（v0.3 新增）B 类 = macro**：`⌘K` → `text(面板标题原文)` → `Enter`，整条 recipe 的 `risk = .macro`，默认被 `macrosEnabled` 拦截。

---

## 16. 配置模型

```json
{
  "version": 3,
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
      "up": "newChat",
      "down": "openTerminal",
      "left": "openModelPicker",
      "right": "queueFollowUp",
      "a": "inspectChanges"
    },
    "optionalUnbound": [
      "toggleFastMode",
      "openPermissionModeMenu",
      "archiveChat",
      "pinThread",
      "forkThread",
      "openSideChat"
    ]
  },

  "capabilities": {
    "codex": {
      "openPermissionModeMenu": { "tier": "unavailable", "reason": "G1", "evidence": "measured", "reachability": "unsupported" },
      "toggleFastMode":         { "tier": "keyInjection", "reason": "G3", "evidence": "measured", "reachability": "c_userBinding", "requiresUserKeybinding": true, "keybinding": null },
      "forkThread":             { "tier": "keyInjection", "evidence": "measured", "reachability": "c_userBinding", "requiresUserKeybinding": true, "keybinding": null },
      "queueFollowUp":          { "tier": "keyInjection", "evidence": "measured", "reachability": "c_userBinding", "requiresUserKeybinding": true, "keybinding": null,
                                  "fallback": { "tier": "keyInjection", "steps": ["keyPress(Return)"], "evidence": "unverified", "note": "运行中 Enter 是否真排队未验证（U5）" } },
      "newChat":        { "tier": "keyInjection", "evidence": "measured", "reachability": "a_defaultKeybinding", "keybinding": "cmd+n" },
      "openTerminal":   { "tier": "keyInjection", "evidence": "measured", "reachability": "a_defaultKeybinding", "keybinding": "ctrl+`" },
      "openSideChat":   { "tier": "keyInjection", "evidence": "measured", "reachability": "a_defaultKeybinding", "keybinding": "cmd+alt+s" },
      "archiveChat":    { "tier": "keyInjection", "evidence": "measured", "reachability": "a_defaultKeybinding", "keybinding": "cmd+shift+a" },
      "pinThread":      { "tier": "keyInjection", "evidence": "measured", "reachability": "a_defaultKeybinding", "keybinding": "cmd+alt+p" },
      "openModelPicker":{ "tier": "keyInjection", "evidence": "measured", "reachability": "a_defaultKeybinding", "keybinding": "ctrl+shift+m" },
      "inspectChanges": { "tier": "keyInjection", "evidence": "measured", "reachability": "a_defaultKeybinding", "keybinding": "ctrl+shift+g" },
      "submit":         { "tier": "keyInjection", "evidence": "measured", "reachability": "c_userBinding", "requiresUserKeybinding": false,
                          "note": "composer.submit 无注册表默认键位，但 composer 聚焦时 Enter 由组件处理；审批卡上 Enter = approval.approve" },
      "cancelOrInterrupt": { "tier": "keyInjection", "evidence": "staticInfer", "reachability": "a_defaultKeybinding", "keybinding": "escape" }
    },
    "claude": {
      "queueFollowUp":           { "tier": "unavailable", "reason": "G4", "evidence": "staticInfer", "reachability": "unsupported" },
      "openPermissionModeMenu":  { "tier": "keyInjection", "strategy": "openMenuThenUserSelects", "evidence": "staticInfer", "reachability": "a_defaultKeybinding", "keybinding": "cmd+shift+m" },
      "submit":                  { "tier": "keyInjection", "evidence": "unverified", "reachability": "c_userBinding", "note": "Code 语境 enter 提交未验证" },
      "newChat":                 { "tier": "unverified", "evidence": "unverified", "reachability": "unsupported", "note": "v0.3 新增动作，Claude 侧未调研（U32）" },
      "openTerminal":            { "tier": "unverified", "evidence": "unverified", "reachability": "unsupported", "note": "同上；相邻线索 View > Show Terminal = cmd+j" },
      "openSideChat":            { "tier": "unverified", "evidence": "unverified", "reachability": "unsupported", "note": "同上；相邻线索 View > Show Side Chat = cmd+;" },
      "archiveChat":             { "tier": "unverified", "evidence": "unverified", "reachability": "unsupported", "note": "同上；不要外推 Codex 的 cmd+shift+a" },
      "pinThread":               { "tier": "unverified", "evidence": "unverified", "reachability": "unsupported", "note": "同上；相邻线索 pin_code_session = cmd+alt+p" },
      "forkThread":              { "tier": "unverified", "evidence": "unverified", "reachability": "unsupported", "note": "同上；cmd+alt+enter 是 fork-session 语义，不可用" }
    }
  },

  "security": {
    "macrosEnabled": false,
    "requireAllowedFrontmostApp": true,
    "allowCodexQueueCli": false,
    "allowExperimentalUnverifiedActions": false
  },

  "keybindings": {
    "codex":  { "openModelPicker": "ctrl+shift+m", "inspectChanges": "ctrl+shift+g",
                "newChat": "cmd+n", "openTerminal": "ctrl+`", "openSideChat": "cmd+alt+s",
                "archiveChat": "cmd+shift+a", "pinThread": "cmd+alt+p",
                "_userBound": { "composer.queue": null, "composer.toggleFastMode": null, "forkThread": null } },
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

- `bindings.optionalUnbound` 是 v0.3 新增：**显式列出「已定义但未绑定」的动作**，让 UI 能提示用户（而不是让用户以为动作不存在）。
- `capabilities.<app>.<action>.reachability` 是 v0.3 新增：把 §5.2 的 A/B/C/D 分类落到配置。
- `capabilities...requiresUserKeybinding` 是 v0.3 新增：C 类动作的前置条件（R13）。
- `keybindings._userBound` 是 v0.3 新增：用户**在 Codex 里**绑了什么键（我们读不到，见 U8/U24，必须由用户手填）。三个键为 `null` 时对应动作走提示路径。
- `allowExperimentalUnverifiedActions` 默认 false：打开后 `evidence == unverified` 的动作才允许投递，并在 UI 上标注。
- `version` 从 2 升到 3：动作集与绑定结构都变了，**不做向后兼容迁移**（v0.2 的配置直接作废）。

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

Capabilities                ← 直接读 §16 的 capabilities；按 A/B/C/D 分类显示
  [A] newChat            ⌘N                bound: B+↑
  [A] openTerminal       ⌃`                bound: B+↓
  [A] openModelPicker    ⌃⇧M               bound: B+←   (not a Codex Micro action)
  [C] queueFollowUp      needs keybinding  bound: B+→
  [C] toggleFastMode     needs keybinding  unbound
  [C] forkThread         needs keybinding  unbound
  [—] openPermissionModeMenu   unsupported on Codex (G1)   unbound
  [A] archiveChat / pinThread / openSideChat   unbound (optional)
  …

User keybindings            ← v0.3 新增：C 类动作的一次性引导（R13）
  Guide: bind composer.queue / composer.toggleFastMode / forkThread in Codex
  Self-check: press the chord and confirm it worked

Debug
  Open Input Monitor
  Show Last Action (with evidence level + reachability)

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

### Debug monitor（保留 v0.1 的强制要求，增加 tier / surface / evidence / variant / reachability）

```text
RAW:          B down
RAW:          Right down
GESTURE:      chord(B, Right)
ACTION:       queueFollowUp
VARIANT:      C/XInput
TARGET:       com.openai.codex   SURFACE: code
TIER:         keyInjection
REACHABILITY: C (user binding)
EVIDENCE:     measured (keybinding exists) / unverified (behaviour)
BINDING:      composer.queue → user key not set → PROMPT instead of inject
RESULT:       prompted
```

或在审批卡上下文中：

```text
ACTION:       submit
CONTEXT:      approval card → displayed as "approve (approval.approve)"
```

debug monitor 在本版比 v0.2 更重要：矩阵里大量格子仍是【静态推断】/【未验证】，且**可达类别**与**默认/可选绑定**是新增维度，这个面板是把这些信息实时暴露给用户的唯一渠道。

---

## 18. 手势状态机

（保留 v0.1 §18 的设计；v0.3 明确 B hold 的产出，并补 C7 的 disconnect 行为。）

```text
Idle

B down
→ BPending

if B released before chord/hold:
→ emit B tap = cancelOrInterrupt
→ Idle

if secondary key down while BPending:
→ ChordActive(B, key)
→ suppress B tap

if B held beyond hold threshold:
→ BModifierReady

if B released while BModifierReady (no chord):
→ emit B hold = cancelOrInterrupt        ← v0.3 明确化（§6.4）
→ Idle

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
openPermissionModeMenu
toggleFastMode
openModelPicker
inspectChanges
newChat
archiveChat
pinThread
forkThread
openSideChat
openTerminal
```

（v0.2 的 7 条 + v0.3 新增的 6 条。注意：`navigate*` 在桌面 App 上的语义随焦点变化，repeat 会让「翻列表」变成「连续滚动」，这也是 §6.1 标 `ActionRisk.navigation` 的原因之一。）

---

## 20. 测试策略

### 20.1 Unit tests（手势层，脱离硬件与 App）

沿用 v0.1 §20.1 并按 **v0.3 的新默认映射**改写：

```text
↑ / ↓ / ← / →        → navigateUp / Down / Left / Right
A tap                → submit
B tap                → cancelOrInterrupt
B hold (alone)       → cancelOrInterrupt        ← v0.3 新增
B + Up               → newChat                  ← v0.3 新映射
B + Down             → openTerminal             ← v0.3 新映射
B + Left             → openModelPicker
B + Right            → queueFollowUp
B + A                → inspectChanges
B chord 不发出 Escape
B hold 不发出两次 cancelOrInterrupt             ← v0.3 新增
reconnect 重置状态
held chord 只触发一次
```

测试替身：Phase 0 已确定 C/XInput 的 `Dpad.*` / `A` / `B` 回调语义，可直接作为 fixture（来源: phase0-summary.md §8.3，实测验证）。

新增（v0.3 特有）：

```text
optionalUnbound 里的动作未被任何手势触发（默认映射不含它们）
C 类动作 requiresUserKeybinding=true 且 keybinding=null → 提示路径，不注入
openPermissionModeMenu 在 codex profile → unavailable + 提示，且绝不产出 Enter
submit / cancelOrInterrupt 的 delivery plan 不包含任何 approval.* 专用动作
B 类动作的 recipe 全部 risk == .macro
```

沿用 v0.2 的断言：

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

v0.3 新增的配置层断言（对应 R15 / R14）：

```text
codex 默认键位表里不包含 "cmd+u"（browser 段专用）
codex 默认键位表里不包含 "cmd+k" 作为 searchChats
toggleFastMode 的 delivery plan 不含 B 类（命令面板）路径
```

### 20.2 Adapter 矩阵测试

对 §7 的每一格写一个断言，确保代码里的 `CapabilityMatrix` 与文档一致：

```text
codex.openPermissionModeMenu == .unavailable                                  (G1)
codex.toggleFastMode      == .keyInjection 且 reachability == .c_userBinding   (G3', R14)
codex.forkThread          == .keyInjection 且 reachability == .c_userBinding
codex.queueFollowUp       == .keyInjection 且 requiresUserKeybinding == true   (F4)
codex.newChat             == .keyInjection 且 reachability == .a_defaultKeybinding
claude.queueFollowUp      == .unavailable                                      (G4)
claude.openPermissionModeMenu == .keyInjection 且 strategy == openMenuThenUserSelects  (G2)
claude.newChat 等 6 个新增动作 == .unverified                                  (U32)
4 个 navigate* 的 risk == .navigation
默认映射的动作集合 == { navigate*×4, submit, cancelOrInterrupt, queueFollowUp,
                        newChat, openTerminal, openModelPicker, inspectChanges }  (8 条)
optionalUnbound == { toggleFastMode, openPermissionModeMenu, archiveChat, pinThread, forkThread, openSideChat }
AgentAction.allCases.count == 17
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
- 至少一个 keyInjection tier 的 A 类 agent action
- 至少一个 menuClick tier 的 agent action（Claude 的 inspectChanges）
- 至少一个 unavailable 动作的提示路径（Codex 的 openPermissionModeMenu）
- 至少一个 C 类动作的「未绑键 → 提示」路径（不注入）
```

⚠️ **进行 §20.3 的第 1、2 项测试有副作用**（会在真实 App 里按键，可能提交内容、打断 turn、新建会话、归档会话）。测试前必须：① 用户在可牺牲的会话里；② 明确告知用户；③ 优先在 TextEdit 里先跑通的 recipe 再对 App 跑。

### 20.4 Manual acceptance flows

#### Flow A — base navigation

```text
打开 Codex / Claude
打开一个列表（会话列表 / 命令面板）
D-pad 移动选择
A 选择
B 关闭
```
预期：与 v0.1 相同；额外要求 debug monitor 显示 `SURFACE` / `TIER=keyInjection` / `REACHABILITY`。

#### Flow B — approval prompt（v0.3 增加显示名要求）

```text
审批卡出现
D-pad 选择
A 确认（Codex: approval.approve；显示名应为 "approve (approval card)"）
B 拒绝（Codex: approval.decline；显示名应为 "reject (approval card)"）
```
预期：不出现「一键 approve for session」；**语义动作层只有 `submit` / `cancelOrInterrupt`，没有 `approve` / `reject`**。

#### Flow C — permission mode menu（v0.3 变化）

```text
Codex 下触发 openPermissionModeMenu（若用户绑到某个手势）
→ 期望：无按键注入 + 浮层提示「Codex 桌面版没有权限模式菜单」（G1）
→ 绝不能看到 approval 被触发

Claude 下触发 openPermissionModeMenu
→ 期望：⌘⇧M 打开 mode menu + 提示用户用方向键选择后按 A 确认
→ 期望：绝不出现「按一次就切了一档」的伪循环（G2）
```

#### Flow D — queue（v0.3 变化）

```text
Agent 正在工作
输入 follow-up 文本
B + →（Codex）
→ 若用户已绑 composer.queue：注入该键，RESULT=delivered
→ 若未绑：提示两条路（在 Codex 里绑 / 保持运行中按 Enter），RESULT=prompted
→ 若走运行中 Enter 的实验路径：必须标注 evidence=unverified（U5）

B + →（Claude）
→ 期望：明确提示「Claude 桌面版无 queue 接口」，不注入任何可能误触的键（G4）
```

#### Flow E — 新增动作（v0.3 新增）

```text
B + ↑（Codex）→ 期望：新建会话（⌘N），surface 非 codeLike 时先提示
B + ↓（Codex）→ 期望：打开终端面板（⌃`）
B + ←（Codex）→ 期望：打开 model picker（⌃⇧M）
可选未绑定动作 → 期望：menu bar 里可见、显示 unbound、不响应任何手势
```

#### Flow F — reconnect / 变体

```text
关闭手柄 → 打开 → 自动重连，无需重启 App（C/XInput 与泛用变体都已实测，来源: phase0-summary.md §3 Q10）
配对键 + A 按住 2 秒切变体
→ 期望：App 检测到 HID-REMOVE → 新 MATCH，重新解析变体，menu bar 变体标签更新
→ 期望：XInput → 泛用 时 GameController 消失但 HID 路径接管，手柄仍然可用（§4.4 的核心验收）
```

#### Flow G — H 档误入

```text
把平台开关拨到 H
→ 期望：menu bar 显示「H mode detected — switch to C」，输入源停止消费该设备，不产生任何按键
```

### 20.5 MVP 验收标准（v0.3 版）

**硬件**

- [ ] C/XInput 与 C/generic 两个变体都被识别，6 个输入可用
- [ ] hold 配对键 + A 切变体后，App 自动恢复可用（无需重启）
- [ ] H 档与 T 档被识别并提示，不消费输入
- [ ] 热重连（关机重开）无需重启 App

**Base controls**

- [ ] D-pad / A / B 在目标 App frontmost 时可注入
- [ ] 目标 App 非 frontmost 时零输出
- [ ] key repeat 策略正确（仅 4 个 `navigate*`）
- [ ] B tap 与 B hold 单独都产出 `cancelOrInterrupt`，且各只触发一次

**Agent layer（v0.3 新口径）**

- [ ] Codex：`newChat` / `openTerminal` / `openModelPicker` / `inspectChanges` 四条 A 类零配置动作可用
- [ ] Codex：`queueFollowUp` 在「已绑键」与「未绑键」两种状态下行为正确（后者只提示）
- [ ] Codex：`openPermissionModeMenu` 给出明确不可用提示，且**绝不产出 Enter**（G1）
- [ ] Codex：`toggleFastMode` 显示为 C 类「需绑键」，且**不出现「命令面板兜底」路径**（G3'）
- [ ] Codex：可选未绑定动作在 Capabilities 里可见且未被任何默认手势触发
- [ ] Claude：`toggleFastMode` / `openModelPicker` / `inspectChanges` 可用（v0.2 口径）
- [ ] Claude：`openPermissionModeMenu` 走「打开菜单 + 用户选择」两段式
- [ ] Claude：`queueFollowUp` 与 6 个 v0.3 新增动作给出明确不可用/未验证提示

**macOS**

- [ ] Accessibility 引导（未授权不静默失败）
- [ ] 目标应用守卫（Pass 1 + Pass 2）
- [ ] surface 最小判定（§11.3）
- [ ] menu bar 显示变体 / surface / 权限 / **可达类别** / **绑定状态**
- [ ] debug monitor 显示 tier + evidence + reachability + binding

**Safety**

- [ ] macros 默认关闭（含 B 类面板路径与 D 类文本）
- [ ] 无 stuck modifiers
- [ ] 无「一键 bypass permissions」
- [ ] 无任意 shell 执行
- [ ] 不写 `~/.codex/ipc/ipc.sock`
- [ ] H 档不产生按键
- [ ] **不实现 Codex Micro 私有协议、不申请受限 entitlement**（§5.1）
- [ ] **动作表里没有 `approve` / `reject`**（§14.4.3）
- [ ] **没有把 `browser.*` 键位当默认键位**（R15）

---

## 21. 实施阶段（v0.3 修订）

### Phase 0 — Hardware Probe ✅ 已完成（2026-09-15）

产出：`docs/hardware-probe.md`（原始实测）+ `docs/phase0-summary.md`（结论汇总）。**7 条硬性约束已进 §3。**

### Phase 0.5 — Codex Micro 对标 ✅ 已完成（2026-09-15）

产出：`docs/research-codex-micro-mapping.md`。**结论已进 §5**：
- 可行性判定（不可行，三重硬过滤）；
- 33 条动作的 A/B/C/D 可达性表；
- 复刻不了 / 可复刻清单；
- 三处对 v0.2 的结论修正（F1–F4）。

### Phase 1 — Controller Core（按 §3 的 7 条约束写）

实现：

- `ControllerInputSource` 骨架，把 C1–C7 **直接固化进去**，不等踩坑后补
- `GameControllerSource`（XInput）+ `HIDControllerSource`（泛用变体），两条都是一级
- `DeviceMatcher`（product + usage，禁用 location）
- 变体检测与 menu bar 展示
- reconnect / 变体切换 / 移除清状态
- 手势识别器 + 状态机（§18，含 B hold 单独的动作）
- **v0.3 新增**：`AgentAction` 的 17 个 case 与 `ReachabilityCategory` 落地（§14.4 / §14.10）

**Phase 1 起步建议**（沿用 phase0-summary §8.4）：始终锁定 XInput 变体开发，泛用变体留到 HID 输入源落地后再回归。

### Phase 2 — Menu Bar App + Guard

实现：

- 连接状态 / 变体 / surface / 可达类别 / 绑定状态显示
- `TargetAppGuard`（Pass 1）+ `AccessibilityPermission`
- `KeyInjectionDelivery`（含 modifier cleanup + serialization）
- debug monitor（含 tier / evidence / reachability / binding）
- 配置持久化（§16，version 3）
- **v0.3 新增**：`UserBindingGuide`（C 类动作的一次性绑键引导 + 自检，R13）

### Phase 3 — Desktop Adapters（**前置：§9 U10 必须完成**）

**第一工作项不是写 adapter，而是补测**（因为 §7.2 的 Claude 键位是【静态推断】）：

1. **U10**：打开一个 Code 会话，遍历 AX 树，记录 Code 面板的按钮/AX 标识。
2. **U15**（零副作用，可与 U10 并行）：确认 `ion-dist` 由哪个窗口加载。
3. **v0.3 新增前置**：**U25 / U30**（A 类动作的端到端行为验证，在可牺牲会话里做）；**U31**（C 类绑键实操，确认 3 个命令能绑到不冲突的键）。
4. 补测后把结果写回 §7.1 / §7.2，升级证据等级。

然后实现：

- `CodexDesktopAdapter`（§7.1 的 16 个 keyInjection/可达 tier + 1 个 unavailable）
- `ClaudeDesktopAdapter`（§7.2 的 11 个 v0.2 动作 + 6 个标 unverified 的新动作的提示路径）
- `MenuDelivery`（AX 读 `enabled` → click）
- `CapabilityMatrix` 代码化（含 `reachability` / `requiresUserKeybinding`）+ §20.2 的矩阵测试
- `ActionOverlay`（不可用动作的用户提示，G1–G6 的载体）

### Phase 4 — 能力补测与降级收口

- 完成 §9 中**零副作用**级别的 U 项：U3（fd 追踪）、U7（打包 App 的 TCC）、U8 / U24（绑键落盘）、U15、U18–U21
- 与用户协商后完成**改 UI 状态**级别的 U 项：U1、U9、U26、U30、U16（可选）
- **改会话数据**级别的 U 项（U2 / U4 / U5 / U6 / U11 / U12 / U25 / U28）**默认不做**，除非用户明确同意并提供可牺牲会话
- 收口 G1–G6 的最终形态，更新 §7 矩阵的证据等级

### Phase 5 — 后续版本候选（本版不做）

- 完整 surface 感知（依赖 U10 的 AX 特征）
- 真正的权限模式「读取 + 下一档」循环（Claude：读当前模式 → 计算下一档）
- Claude 深链补充动作（`claude://code/needs-input` → `openSessionNeedingInput`）
- Codex `codex queue` 实验路径（依赖 U4）
- **Claude 侧的 Codex Micro 级别调研**（补 U32，让 6 个新增动作在 Claude 上有结论）
- 用户自定义层编辑器、Shortcuts.app actions、media mode
- **（已明确放弃，不再列为候选）**：让 L1162 被识别为 Codex Micro（§5.1）

---

## 22. 不得在没有证据的情况下更改的决策

（v0.1 §23 → v0.2 §22 → 本版修订。**加粗**为 v0.3 改写或新增的条目。）

1. **C / 手柄模式是首要硬件路径；H 模式只识别不消费；T 档只识别并跳过。**（来源: phase0-summary.md，实测验证）
2. H / keyboard 模式不得作为输入源（泄漏严重，实测）。
3. **GameController 仅在 XInput 变体下优先；对泛用 C 变体，IOHIDManager 是唯一路径。两者都是一级输入源。**（改写 v0.1 决策 3、4）
4. **C 档两个变体都必须支持**（用户明确要求）；不做变体的 App 内切换，只做检测与提示。
5. **设备匹配必须用 product + usage，不得单独用 VID/PID，不得使用 location。**
6. **配对键永远不映射。**
7. 物理按钮 → 语义动作 → adapter；不做直接全局硬编码。
8. **Base layer 与新 B 层映射按下表固定（用户已拍板）：↑↓←→ = 导航；A = `submit`（兼 approve）；B tap / B hold 单独 = `cancelOrInterrupt`（兼 reject）；B+↑ = `newChat`；B+↓ = `openTerminal`；B+← = `openModelPicker`；B+→ = `queueFollowUp`；B+A = `inspectChanges`。4 个 `navigate*` 必须标 `ActionRisk.navigation`。**
9. **投递优先级固定为：程序化接口 > 原生菜单点击 > 按键注入 > 明确不可用。** 不允许跨层静默 fallback（尤其：菜单点击失败不得自动改成盲注按键）。
10. **目标应用必须是两个桌面 App 的 allowlist 之一**；profile 自动探测，Force 模式仅作调试。
11. Macro 注入是次要且必须守卫（`macrosEnabled` 默认 false）。**命令面板路径（B 类）与 composer-text（D 类）一律算 macro。**
12. **不提供「一键 bypass permissions」，也不提供任何会让语义错位的高风险重映射（G1 的 D1-b 已否决）。**
13. **不依赖 `~/.codex/ipc/ipc.sock`。**
14. **不把 deep link 作为任何语义动作的可用性前提（因为 `disableDeepLinkRegistration` 可整体关闭）。**
15. **`unavailable` 必须产生用户可见提示，不允许静默无输出。**
16. 硬件探针先于完整实现（已在 Phase 0 完成）。
17. **§7 矩阵中证据等级低于「实测验证」的动作，默认不启用；启用需用户在设置里显式打开。**
18. **（v0.3 新增）不追求、也不实现「L1162 被 Codex 识别为 Codex Micro」**：VID/PID/usagePage 三重硬过滤在固件里改不了，5 条伪造路径全部否决（§5.1）。任何后续实现不得引入 Work Louder / Codex Micro 私有协议或受限 entitlement。
19. **（v0.3 新增）语义动作集就是 §14.4 的 17 个**；`cyclePermissionMode` 更名为 `openPermissionModeMenu`，且 Codex profile 下不得静默替换成 `approve`（§14.4.2）。
20. **（v0.3 新增）不新增 `approve` / `reject` 动作**：`submit` 在审批弹层里即 approve，`cancelOrInterrupt` 即 reject；语义动作层不重复定义同键动作（§14.4.3）。
21. **（v0.3 新增）命令面板不是兜底**：只收录 63/131 条命令，且没有 `commandMenu:true` 的命令（如 `toggleFastMode`）**在面板里不存在**；不得再把面板当作「无默认键位命令」的通用出口（§8 G3'、R14）。
22. **（v0.3 新增）C 类动作（`toggleFastMode` / `forkThread` / `queueFollowUp`）依赖用户手动绑键，必须显式引导与自检，不得伪装成零配置可用**（R13）。
23. **（v0.3 新增）键位来源必须可追溯：`browser.defaultKeybindings` 的键位在桌面 App 不生效，一律不许进默认映射**（R15）。
24. **（v0.3 新增）`openModelPicker` 不属于 Codex Micro 的语义集**（Micro 只有 `MIND+` / `MIND-` 调推理档）：它可用，但文档与 UI 不得声称它「对齐了 Micro」（§6.2）。

---

## 23. 实施 agent 的启动提示（v0.3）

```text
Implement this spec incrementally.

Read first: docs/spec-v0.3.md, docs/phase0-summary.md, docs/research-codex-micro-mapping.md,
docs/research-codex-desktop.md, docs/research-claude-desktop.md.
Do not re-derive hardware facts — Phase 0 is complete.

Phase 0 is DONE. Phase 0.5 (Codex Micro mapping) is DONE. Start at Phase 1 (Controller Core).

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

Do NOT try to make the L1162 look like a Codex Micro (spec §5.1, measured):
- Codex discovers it via the native plugin hid-topology-watcher.node with a hardcoded
  IOKit match on VendorID 0x303A + ProductID {0x8360,0x8297,0x8298} + usagePage 0xFF00.
- All three are locked in L1162 firmware. Firmware flashing / USB MITM / asar patching /
  DriverKit / IOHIDUserDevice are all ruled out (the last two need a restricted entitlement).
- The action layer is the route: all 33 Codex Micro keycap actions are reachable from outside
  (11 default keybindings, 8 command-menu, 9 bind-once, 5 text/URL, 0 unreachable).

Target apps:
- com.openai.codex (ChatGPT.app) and com.anthropic.claudefordesktop (Claude.app).
- Do not implement or depend on Codex TUI [tui.keymap] or ~/.claude/keybindings.json.

Semantic actions are exactly the 17 in spec §14.4. Note:
- cyclePermissionMode is renamed openPermissionModeMenu. Codex has NO permission-mode action:
  mark it unavailable and never silently substitute an approval (spec §8 G1).
- Do NOT add approve/reject actions. submit IS approve on the approval card and
  cancelOrInterrupt IS reject — same keystrokes, one action each (spec §14.4.3).
- Default chord map: B+Up newChat, B+Down openTerminal, B+Left openModelPicker,
  B+Right queueFollowUp, B+A inspectChanges (spec §6.2). B tap and B hold alone are both
  cancelOrInterrupt.
- toggleFastMode / openPermissionModeMenu / archiveChat / pinThread / forkThread / openSideChat
  are defined but unbound by default (spec §6.3).

Corrected facts you must not re-break (spec §0.3):
- The command menu exists (Cmd+K / Cmd+Shift+P) but contains only 63 of 131 commands.
- toggleFastMode is NOT in the command menu; it needs a user-assigned shortcut (class C).
- browser.defaultKeybindings do not apply in the desktop app (Cmd+U, searchChats Cmd+K are dead).
- queueFollowUp is no longer a gap: composer.queue is a real command with a handler; either the
  user binds a key once, or running Enter (followUpQueueMode="queue") does it implicitly.

Delivery priority: programmatic > native menu click (AX) > key injection (CGEvent) >
explicitly unavailable. Never silently fall back across tiers.

Known gaps — implement as visible "unavailable", never silently:
- G1 Codex has NO permission-mode menu action (measured, three independent evidence chains).
- G2 Claude has no "cycle" for permission mode — open the mode menu and let the user pick.
- G3 Codex toggleFastMode has no default shortcut and is not in the command menu.
- G4 Claude has no queueFollowUp interface (Codex's is fixed; Claude's is not).
- G5 navigate* on both apps is arrow-key injection with focus-dependent meaning.

Before writing the Claude adapter, first do §9 U10: open a Code session and enumerate its
AX tree. The Claude key bindings in §7.2 are static inference, not measurement. The 6 new
v0.3 actions have NO Claude evidence at all — keep them unverified/unsupported there.

Safety: macros off by default; never write ~/.codex/ipc/ipc.sock; do not depend on claude://
deep links; never map the pairing key; never provide a one-tap permission bypass; never
implement or emulate the Work Louder private HID protocol.

Write unit tests for gesture state transitions and for the capability matrix (§20.2) before
implementing tool-specific adapters.
```

---

## 24. 来源与证据索引

| 文档 | 覆盖范围 | 本版主要引用 |
|---|---|---|
| `iine-l1162-codex-claude-macos-implementation-spec-v0.1.md` | 原始 spec（CLI 路线） | 骨架、语义动作层、安全模型、手势状态机、按键重复、测试策略、决策清单 |
| `docs/spec-v0.2.md` | 上一版 spec（桌面 App 路线） | 全文底稿；§3/§4/§11/§12/§13/§15/§16 基本沿用；§0.3 列出修正项 |
| `docs/phase0-summary.md` | Phase 0 结论汇总 | §3 的 7 条约束、§4 模式与变体、§9 未验证项 |
| `docs/hardware-probe.md` | Phase 0 原始实测记录 | §3/§4 的原始证据行（§2 identity、§6.5 背景事件、§6.6 同对象、§6.7 死区、§6.8 变体切换） |
| **`docs/research-codex-micro-mapping.md`** | **Codex Micro 对标调研（本版核心新材料）** | **§5 全章**（可行性、33 条动作、复刻边界）、§0.3 的 F1–F4、§6 的映射依据、§8 G3'/G4、R13–R15、U24–U31 |
| `docs/research-codex-desktop.md` | Codex 桌面 App 控制面调研 | §7.1 矩阵、G1、G5、R3、R5、R8、§9.1 U1–U8、附录 A（TUI，不采用） |
| `docs/research-claude-desktop.md` | Claude 桌面 App 控制面调研 | §7.2 矩阵、G2、G4、R1、R2、R4、§9.3 U9–U17 |

### 证据等级分布（本版 §7.1 的 Codex 17 格）

> ⚠️ 读表须知：**「实测验证」指的是「该机制/该键位确实存在」已实测，不是「按下去有预期效果」**。后者对两个 App 的每一格都是【未验证】（§9 U6 / U25 / U30）。

| 等级 | Codex（17 格） |
|---|---|
| 实测验证 | **13 格** —— `newChat`、`openTerminal`、`openSideChat`、`archiveChat`、`pinThread`、`openModelPicker`、`inspectChanges`（7 个 A 类默认键位）、`openPermissionModeMenu`（❌ 实测无此动作）、`toggleFastMode`（实测无默认键位且不在面板）、`forkThread`（实测无默认键位）、`queueFollowUp`（实测命令与处理器存在）、`submit`（实测处理器存在）、`archiveChat` 的键位 |
| 静态推断 | **3 格** —— 4 个 `navigate*`（键位存在但语义随焦点）、`cancelOrInterrupt`（源码分支 `N_r()`） |
| 混合（实测 + 未验证） | **1 格** —— `queueFollowUp` 的「运行中 `Enter` 是否真排队」 |
| 未验证 | **0 格**（矩阵级另有「程序化接口为空」= 实测） |

### 证据等级分布（本版 §7.2 的 Claude 17 格）

| 等级 | Claude |
|---|---|
| 实测验证（键位或菜单项） | **2 格** —— `navigateLeft` / `navigateRight` 的原生菜单项、`inspectChanges` 的原生菜单项 |
| 静态推断 | **8 格** —— 4 个 `navigate*`（键位）、`cancelOrInterrupt`、`openPermissionModeMenu`、`toggleFastMode`、`openModelPicker` |
| 混合 | **1 格** —— `inspectChanges` |
| 未验证 | **6 格** —— v0.3 新增动作（`newChat` / `openTerminal` / `openSideChat` / `archiveChat` / `pinThread` / `forkThread`），本版未调研（U32） |

**这两张分布表本身就是结论**：本版把 Codex 侧的证据密度大幅提高（Phase 0.5 的成果），但 **Claude 侧新增动作是空白**，且所有动作的**行为**仍未验证。Phase 3 的第一件事仍然是补测（§9 U10 / U15 / U25 / U30 / U31），不是写代码。

---

## 25. 配置迁移说明（v0.2 → v0.3）

**不做自动迁移。** 理由：

1. `AgentAction` 的枚举变了（`cyclePermissionMode` → `openPermissionModeMenu`，新增 6 个），旧配置里的字符串无法安全映射。
2. **默认绑定变了**（B+↑ / B+↓ 换了动作），静默把旧绑定迁移过去会让用户以为「没变」而实际行为不同 —— 这是最危险的一类迁移。
3. 新增 `reachability` / `requiresUserKeybinding` / `optionalUnbound` / `_userBound` 四个结构，语义上要求用户重新确认。

处理方式：启动时若读到 `version: 2` 的配置，显示一次性提示「配置结构已更新，已重置为 v0.3 默认值；请重新检查 Capabilities 与 User keybindings」，把旧文件备份为 `config.v2.backup.json`，然后写新的 v3 配置。

---

## 26. 需要人类拍板的决策清单

以下问题**不能由实现者替用户决定**。每项给出推荐选项与理由，但需要用户明确回答后才进入对应阶段。

| # | 问题 | 选项 | 推荐 | 阻塞哪个阶段 | 状态 |
|---|---|---|---|---|---|
| **Q1** | 确认彻底放弃 CLI 路线？ | (a) 彻底放弃 (b) 保留为可选 | **(a)** —— 桌面 App 不跑 TUI（实测） | Phase 3 | v0.2 已定 |
| **Q2** | C 档的两个变体都要支持吗？ | (a) 两个都支持 (b) 只支持 XInput | **(a)** —— 用户已明确要求 | **Phase 1** | v0.2 已定 |
| **Q3** | G1：Codex 的 `openPermissionModeMenu` 怎么处理？ | (a) 标记不可用 + 提示 (b) 重映射为 approval（**有风险，已否决**） | **(a)** | Phase 3 | v0.2 已定（本版改名） |
| **Q4** | G3'：Codex 的 `toggleFastMode` 怎么处理？ | (a) 标记不可用 + 提示 (b) ~~`⌘K` 面板输入命令名~~（**本版证明做不到**） (c) 引导用户在 App 内绑键 + 手填到本 App 配置 | **(c)** 为默认，(a) 为其回退 | Phase 3 | **v0.3 更新** |
| **Q5** | G4：Claude 的 `queueFollowUp` 怎么处理？ | (a) 标记不可用 + 提示 (b) 实验性注入 `enter`（U11 未验证） | **(a)** | Phase 3 | v0.2 已定（Codex 侧本版已修复） |
| **Q6** | G2：Claude 的权限模式菜单怎么落地？ | (a) 两段式「打开菜单 + 用户选择」 (b) 「打开菜单 + 盲发 `1`」伪循环 | **(a)** | Phase 3 | v0.2 已定 |
| **Q7** | `navigate*` 的语义歧义是否接受？ | (a) 接受，标 `ActionRisk.navigation` (b) 要求先做完整 surface 感知 | **(a)** | Phase 3 | v0.2 已定 |
| **Q8** | H 档 / T 档的处理？ | (a) 只识别 + 提示 (b) H 档做 fallback 输入源 | **(a)** | Phase 1 | v0.2 已定 |
| **Q9** | §9 里「改会话数据」级别的验证要不要做？ | (a) 都不做 (b) 在可牺牲会话里做一部分 | **(a)** 起步 | Phase 4 | v0.2 已定 |
| **Q10** | Claude 的 surface 感知方案？ | (a) 最小版 (b) 完整 AX 特征 | **(a)** | Phase 2/3 | v0.2 已定 |
| **Q11** | 是否接受「Claude `submit` 在 Code 语境未验证」？ | (a) 先按 `enter` 实现并提示 (b) 先补测 | **(a) 或 (b)** | Phase 3 | v0.2 已定 |
| **Q12** | `allowCodexQueueCli` 要不要开？ | (a) 关闭（默认） (b) 开启为实验性 | **(a)** | Phase 3 | v0.2 已定 |
| **Q13** | 配置文件位置与 `capabilities` 可编辑性？ | (a) 接受 (b) 锁定不可改 | **(a)**，`allowExperimentalUnverifiedActions` 默认 false | Phase 2 | v0.2 已定 |
| **Q14** | R1：是否要求用户关闭 Claude 侧 Hardware Buddy？ | (a) 仅异常时提示 (b) 启动时强制 | **(a)** | Phase 1/2 | v0.2 已定 |
| **Q15** | **C 类动作的一次性绑键引导要做到什么程度？** | (a) 只在 Capabilities 里显示「需绑键」+ 命令 id（最轻） (b) 额外提供引导流程：列出 3 个命令、给建议键位、用户绑完后手填进本 App 配置、再跑一次自检 (c) 尝试自动读用户绑的键（**依赖 U24，当前不可行**） | **(b)** —— 「读不到就引导用户填两次」是当前唯一可落地路径；(c) 作为 U24 验证成功后的升级 | Phase 2/3 | **v0.3 新增** |
| **Q16** | **`openModelPicker` 保留在默认映射（B+←）吗？** 它不是 Codex Micro 的语义动作 | (a) 保留 —— 它是实测可用的 A 类键位，实用价值高 (b) 移出默认映射，改绑 `MIND+`/`MIND-` 或 `toggleFastMode`，以更贴近 Micro | **(a)** —— 用户已拍板 B+← = `openModelPicker`；但需确认接受「默认映射不完全等价于 Micro 语义集」这一事实（§6.2 边界 1） | Phase 1/3 | **v0.3 新增** |
| **Q17** | **`archiveChat` / `forkThread` 这类产生持久状态变化的动作，是否允许出现在默认手势里？** | (a) 保持现状：两者都是可选未绑定 (b) 允许其中一个进默认映射（如 B 长按 + A） | **(a)** —— 6 个输入的误触代价高，且 v0.1 §17 的精神是「破坏性动作要更贵」 | Phase 1/3 | **v0.3 新增** |
| **Q18** | **是否为本版新增的 6 个动作补一次 Claude 侧调研（U32）？** | (a) 不补，Claude 侧一律标 unsupported/unverified（本版默认） (b) Phase 3 前补一次与 Micro 同级别的调研 | **(b)** 若 Claude 是一等目标；**(a)** 若本项目实际以 Codex 为主 | Phase 3 | **v0.3 新增** |

---

## 附录 A — 术语对照

### A.1 v0.2 → v0.3

| v0.2 | v0.3 | 说明 |
|---|---|---|
| `cyclePermissionMode` | `openPermissionModeMenu` | 名实相符：两个 App 都没有「循环」，只有「打开菜单」（F5） |
| —— | `newChat` / `openTerminal` / `openSideChat` / `archiveChat` / `pinThread` / `forkThread` | 来自 Codex Micro 动作清单的新增语义动作 |
| `approve` / `reject`（调研建议） | **不新增** | 与 `submit` / `cancelOrInterrupt` 同键，由后者承载（F6 / §14.4.3） |
| B+↑ = `cyclePermissionMode` | B+↑ = `newChat` | 新默认映射 |
| B+↓ = `toggleFastMode` | B+↓ = `openTerminal` | 新默认映射；`toggleFastMode` 退出默认绑定 |
| 11 个语义动作 | 17 个语义动作 | §14.4 |
| 「命令面板可作兜底」 | 面板只含 63/131 条；B 类 = macro，默认关闭 | F1 / R14 |
| 「`toggleFastMode` 走面板」 | `toggleFastMode` = C 类，需用户绑键 | F2 / G3' |
| `queueFollowUp` 在 Codex = 缺口 | `queueFollowUp` = C 类（绑一次键）或运行中 Enter | F4 / G4 |
| 无「可达类别」概念 | `ReachabilityCategory`（A/B/C/D/unsupported） | §14.10 |
| 「默认绑定」单一概念 | 「默认绑定」vs「可选未绑定」 | §6.2 / §6.3 |
| `version: 2` 配置 | `version: 3` 配置（不自动迁移） | §16 / §25 |

### A.2 v0.1 → v0.2（保留，便于追溯）

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
