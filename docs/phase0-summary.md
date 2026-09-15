# Phase 0 — Hardware Probe: 结论汇总与实现约束

> 面向 Phase 1 的收口文档。原始实测记录、逐条证据与完整日志索引见 `docs/hardware-probe.md`。
> 所有结论均来自 2026-09-15 在本机的实测，未经验证的项在 §6 单列。

环境：macOS 27.0 (26A428, arm64) / Xcode 27.0 (27A5228h) / Swift 6.4。
被测设备：IINE 良值 L1162（型号 L1162，`zhuhai_jieli`，固件 version=283）。

---

## 1. 一句话结论

**spec 的主设计成立，但有三处必须修改、六个坑必须在 Phase 1 一开始就绕开。**
手柄在 C 模式 / XInput 变体下能被 `GameController.framework` 完整识别（35 个元素、6 个可用输入、
热重连正常），可以按 spec 的语义动作层设计推进；但 GameController **只覆盖这一个变体**，
IOHIDManager 因此不是「兜底」而是必需组件。

---

## 2. 三种平台模式 × 两个变体

平台开关是 **T / C / H 三档**（spec §3 只写了 C 和 H，**漏了 T**），每档有两个变体，用
「配对键 + A」互换。

| 开关 | 模式 | 默认设备 | 变体（配对键 + A） |
|---|---|---|---|
| **T** | 多媒体触控模式 | `IINE-Control`（触控） | `IINE-Phone`（多媒体） |
| **C** | 手柄模式 | **`Xbox Wireless Controller`（XINPUT）** | `Wireless Controller`（Gamepad） |
| **H** | 键盘鼠标模式 | `IINE_keyboard`（+ 鼠标） | 说明书未写 |

### 实测身份对照

| 模式 | Product | VID / PID | Primary usage |
|---|---|---|---|
| C / XInput | `Xbox Wireless Controller` | `0x045e` / `0x0b13` | `1/5` GamePad |
| C / generic | `Wireless Controller` | `0x4353` / `0x9b09` | `1/5` GamePad |
| H | `IINE_keyboard` | `0x4353` / `0x9b09` | `1/6` Keyboard |

- **VID/PID 不足以识别设备**：泛用 C 变体与 H 模式键盘的 VID/PID 完全相同，只有 usage/产品名能区分。
- **`location` 不稳定**：同一设备重连后从 `2142999777` 变成 `584791771`，不能作为标识。
- 变体切换会造成**完整的热插拔**（`HID-REMOVE` + 新设备 `HID-MATCH`）。

### 变体是持久状态，且切换手势有讲究

变体存在设备里，**扛得住关机重开，也扛得住开关往返**（C→H→C 回来后仍是原变体）。
唯一能改的路径是配对键 + A，且**必须两个键一起按住约 2 秒**：

| 尝试 | A 的做法 | 断开时 A 是否仍按着 | 结果 |
|---|---|---|---|
| 22:12 | 按住 2 秒 | 是 | ✅ 切换 |
| 22:24 | 点 0.17 秒 | 否 | ❌ 无变化 |
| 22:31 | 按住 ~2 秒 | 是 | ✅ 切换 |

**只点一下 A 会被静默忽略。**

---

## 3. spec §24 十个问题：答案

| # | 问题 | 实测答案 |
|---|---|---|
| Q1 | `vendorName` | `Xbox Wireless Controller`（C/XInput） |
| Q2 | `productCategory` | `Xbox One` |
| Q3 | 哪个 C 变体更好 | **XInput** —— 只有它能被 GameController 看到；泛用变体是 HID-only |
| Q4 | `extendedGamepad` 可用？ | 可用（C/XInput，且与 `microGamepad` 是同一对象）；泛用变体与 H 模式均不可用 |
| Q5 | D-pad 如何暴露 | XInput：HatSwitch `0x39` cookie 33，range `[1,8]`，居中 `0`，值 1/3/5/7；泛用：同 usage 但 cookie 29，range `[0,7]`，**居中 15**，值 0/2/4/6 |
| Q6 | A/B 如何暴露 | XInput：`Button 1` cookie 11 / `Button 2` cookie 12；泛用：同 usage 但 cookie **7 / 8**；H 模式：A=`Enter`、**B=`Space`（不是 Escape）** |
| Q7 | 配对键是否暴露 | **暴露**，是 `Button 13`（page `0x9`，usage `0xd`）。但它同时是**电源键**，不建议映射 |
| Q8 | B+方向 chord 可观测？ | 可观测（H 与 C 均已实测，含 GC 层） |
| Q9 | 是否泄漏键盘事件 | **C 模式不漏**（TextEdit 空白、键盘 usage 事件 0 条）；**H 模式严重泄漏**，6 个键全部作为普通按键进入前台 App |
| Q10 | 重连身份是否保持 | **保持**。C/XInput 与泛用变体都实测过关机重开：自动重连、`product/vid/pid/serial` 一致、同一进程内映射立即恢复 |

---

## 4. spec §4.3 验收清单

| 验收项 | H 模式 | C / XInput | C / generic |
|---|---|---|---|
| 6 个输入可独立识别 | ☑ | ☑ | ☑（仅 HID 层） |
| press / release 可观测 | ☑ | ☑ | ☑ |
| D-pad 无异常重复 | 未测 | ☑ | 未测 |
| `B + 方向` 真实 chord | ☑ | ☑ | 未测 |
| 不泄漏普通键盘字符 | ✗ **失败** | ☑ **通过** | 未测 |
| 重连无需重启 App | 未测 | ☑ **通过** | ☑ **通过** |

---

## 5. 必须带进 Phase 1 的发现（按影响排序）

1. **`GCController.shouldMonitorBackgroundEvents = true` 是硬性要求。**
   自 macOS 11.3 起默认 `NO`，含义是「非前台 App 收不到任何手柄事件」。menu-bar 工具永远不是
   前台 App —— 不设这一行，整条 GameController 路径**静默失效**（实测：同一套按键，设之前
   GC 回调 0 条，设之后 36 条）。

2. **GameController 只覆盖 XInput 变体，IOHIDManager 是必需路径而非兜底。**
   泛用变体和 H 模式下 `GCController.controllers()` 恒为 `count=0`，且不会有 `GCControllerDidConnect`。
   若 Phase 1 只实现 GC 路径，用户一旦切到泛用变体，App 会表现为「完全没反应」。
   → 要么实现 HID 路径，要么**主动检测该变体并给出明确提示**。

3. **设备匹配不能只看 VID/PID，也不能用 location。**
   泛用 C 变体与 H 键盘共用 `0x4353`/`0x9b09`；`location` 重连后会变。必须用
   product 名 + usage（+ VID/PID 辅助）。

4. **每个 element 只能绑定一次。**
   `extendedGamepad` 与 `microGamepad` 是**同一个对象**（指针实测相同），元素全部共享；
   `pressedChangedHandler` 是赋值不是追加 —— 绑两次会静默覆盖，导致回调名字与预期不符。
   同理 `physicalInputProfile.elements["Button A"]` 与 `extendedGamepad.buttonA` 也是同一对象。

5. **GameController 是异步附着的，启动瞬间查询不可靠。**
   冷启动后头约 100ms `controllers()` 必然为空，真实设备只在 `GCControllerDidConnect` 里出现
   （实测 0.138s）。必须挂连接/断开通知，不能靠启动时轮询。

6. **模拟轴必须用死区。**
   每次连接时，所有物理上不存在的轴都会上报一次中心值（如 `32767/65535`），而
   `value > 0.5 ⇒ 按下` 这种朴素判断会把它们当成按下，凭空造出幽灵 chord。

7. **设备移除时必须清空按键状态（两条路径都要）。**
   手柄消失时不会为按住的键发 release。探针自己在 HID 路径上漏了这一步，导致「配对键一直按着」
   污染了后续整份日志；GC 路径的清理是正确的。

8. **不要硬编码 HID cookie 与 logical range；不要映射配对键。**
   两个 C 变体对同一个控件的 cookie 和取值范围都不同。配对键（`Button 13`）既会切换变体、
   又是电源键，映射它等于给用户一个「按了手柄就消失」的按钮。

---

## 6. spec 需要修订的地方

| 位置 | 现状 | 应改为 |
|---|---|---|
| §3 硬件假设 | 只写了 C / H 两种模式 | 三档 T / C / H，且**每档还有两个变体** |
| §3 / §24 Q7 | 「不要假定配对键会出现在 HID report 中」 | 实测**会出现**（`Button 13`），但仍不应映射 |
| §23 决策 3 | 「GameController 优先于 IOHIDManager」 | 限定为「**在 XInput 变体下**优先」；泛用变体只有 HID 路径 |
| §6.1 基础层 | 假定 B = Escape | 仅在 C/XInput 与 GC 路径成立；H 模式下 B 是 `Space` |
| §4.2 测试矩阵 | 只有 C×2 + H | 需补 T 档（本项目可不实现，但要能识别并跳过） |

---

## 7. 尚未验证 / 已知风险

- **泛用变体只做了最小验证**：6 个输入的映射、chord、长按重复、泄漏均未测（不建议把它作为受支持路径）。
- **T 档完全未采集**（超出本项目范围，但 Phase 1 的逻辑要能识别并忽略它）。
- **H 模式的第二变体未知**（说明书未记载）。
- **结论绑定当前系统版本**：实测环境是 macOS 27.0 beta（26A428）+ Xcode 27 beta。
  `shouldMonitorBackgroundEvents` 的默认值、GameController 对第三方 BLE 手柄的接纳策略都属于
  系统行为，**大版本升级后应重新验证第 5 节第 1、2 条**。
- **权限行为未在正式 App 里验证**：探针是以无 bundle、无 TCC 授权的方式跑的，
  Accessibility / Input Monitoring 在打包签名后的真实 App 中的表现（尤其是重签后授权失效）
  仍是 Phase 1/2 的待办。
- 斜向 D-pad（HatSwitch 2/4/6/8）在本设备上从未产生，但**不能据此认为永远不会**。
- 日志隐私：`--with-keyboard` 模式下日志会包含用户自己的键盘输入（本会话的日志里就有），
  这些 `.jsonl` 已在 `.gitignore` 中，**不要外发**。

---

## 8. 建议的下一步（Phase 1）

1. 先写 `ControllerInputSource` 的骨架，把第 5 节的 7 条规则直接固化进去（背景事件开关、单次绑定、
   通知驱动、usage+product 匹配、死区、移除清状态），而不是等踩坑后再补。
2. 明确一个产品决策：**是否支持泛用变体**。支持 → IOHIDManager 升为一级输入源；
   不支持 → 必须做「检测到不支持的变体」的显式提示，不能静默。
3. 手势状态机（spec §18）可以先脱离硬件用单测驱动，C/XInput 的 `Dpad.*` / `A` / `B` 回调语义
   已经确定，可以直接作为测试替身。
4. Phase 1 起步阶段建议**始终锁定 XInput 变体**开发，把泛用变体留到 HID 输入源落地之后再回归。
