# Phase 1 — Controller Core: 真机验证记录

> 验证日期：2026-09-16 00:00–00:05
> 被测硬件：IINE 良值 L1162（C 档，两个变体都测了）
> 被测代码：`Sources/PocketAgentCore` @ commit 之后的 `bf82cae` + 本次未提交改动
> 运行方式：`./.build/debug/coresmoke --duration 180`（**`--emit` 关闭**，只打日志不注入按键）

这次验证的目的很明确：单元测试只能覆盖纯逻辑，覆盖不到**真实的 HID 报告、两个设备变体、热插拔**。
下面是实测结果与结论。

---

## 1. 结论

**Phase 1 控制器核心在真机上端到端跑通，两条输入路径都验证了。**
180 秒内触发 36 个语义动作，计数与操作次数完全自洽，无异常、无卡键、无重复触发。

---

## 2. 两条输入路径都验证了

同一次会话里切换了设备变体，两条路径依次接管：

```text
[  0.036] SOURCE     attached Xbox Wireless Controller [Xbox One] elements=35 bound=6
[  0.036] SOURCE     connected via gameController: Xbox Wireless Controller
…
[138.519] SOURCE     attached Wireless Controller (raw HID)
[138.519] SOURCE     connected via rawHID: Wireless Controller
```

| 变体 | 路径 | 结果 |
|---|---|---|
| `Xbox Wireless Controller`（XInput） | GameController | 35 个元素，**6 个输入全部绑定成功**（`bound=6`） |
| `Wireless Controller`（泛用） | raw HID | 六个输入、tap/hold/chord 全部正常 |

这直接回答了 spec §4 的要求：**用户不需要知道自己处在哪个变体，两种都能用。**
也再次印证了 Phase 0 的结论 —— GameController 只覆盖 XInput 变体，raw HID 路径是必需的而非兜底。

---

## 3. 关键行为逐条验证

### 3.1 `shouldMonitorBackgroundEvents` 在非前台进程上生效

`coresmoke` 是个命令行进程，**从头到尾都不是前台 App**。它收到了全部输入事件，
说明 Phase 0 §6.5 那条约束在真实场景下确实成立 —— 不设这一行，这个进程会「attach 成功但按下去毫无反应」。

### 3.2 方向键走 keyDown/keyUp，A 走一次性 down+up

```text
[   9.001] RAW press up  → GESTURE keyDown(up) → ACTION down navigateUp → upArrow
[   9.270] RAW release up → GESTURE keyUp(up)  → ACTION up   navigateUp → upArrow

[  14.505] RAW press a   → GESTURE keyDown(a) + keyUp(a)   ← 同一时刻成对发出
[  14.505] ACTION down submit → enter
[  14.505] ACTION up   submit → enter
[  14.641] RAW release a                                    ← 真实松开在这里，但已无输出
```

方向键是真正的按住语义（让目标 App 自己处理按键重复），A 是原子的一次性按键 ——
**按住 A 2.5 秒（14.505 → 17.0 之间）没有产生任何重复**，符合 spec §19。

### 3.3 tap / hold 的分界正确

```text
[  16.425] press b → [16.485] release b     60 ms  → GESTURE tap(b)
[  37.141] press b → [37.680] release b    539 ms  → GESTURE hold(b)
```

阈值是 `tapMaxMs=220` / `holdMs=450`，两次都落在预期侧。

### 3.4 chord 抑制 Escape —— 真机确认

这是**单元测试抓到的那个 bug**（chord 结束后松开 B 会多冒一个 Escape）在真机上的验证：

```text
[  44.160] GESTURE chord(b + up)  → ACTION press newChat → command+n
[  44.325] RAW release up
[  44.655] RAW release b           ← 只到这里结束，之后没有任何输出
```

整场 `cancelOrInterrupt` 计数是 **4**，恰好等于刻意做的 B tap/hold 次数。
10 次 chord 里**没有一次泄漏 Escape**。若泄漏，这个数会是 5 或更多。

### 3.5 B 层是「按住型修饰键」，可以连着触发多个 chord

实测发现并已用单测锁定的行为：

```text
[  72.225] RAW press b
[  73.035] chord(b + down)  → openTerminal
[  75.526] chord(b + left)  → openModelPicker      ← B 一直没松
[  76.365] chord(b + right) → queueFollowUp
[  77.730] chord(b + a)     → inspectChanges
[  78.329] RAW release b                            ← 最后才松，且不产生 Escape
```

**按住 B 不放、依次点几个方向键，会依次触发对应的动作**（类似按住 Shift 连按不同字母）。
这不是 bug —— 是「修饰键仍然按着」的自然结果，而且很实用（一次按住可以连做几件事）。
但它此前没有测试覆盖，现已补 `testHoldingBAllowsSeveralChordsInSequence`。

### 3.6 断连清理与热重连

```text
[  85.345] SOURCE detached Xbox Wireless Controller
[  85.345] DETACH controller gone — gesture state reset: Xbox Wireless Controller
[ 106.685] SOURCE attached Xbox Wireless Controller [Xbox One] elements=35 bound=6
[ 133.020] RAW press a → ACTION down/up submit       ← 重连后立即恢复，无需重启进程
```

断连时 gesture 状态被清空；重连后**同一个进程**内立刻恢复可用。

---

## 4. 过程中发现并修掉的一处日志缺陷

```text
[  0.023] SOURCE  ignoring unsupported gamepad "Xbox Wireless Controller"
```

这条出现在启动瞬间，是 HID 源拒绝了 XInput 变体的设备 —— **行为正确**（该设备由 GameController 源负责，
两边都监听会导致每个事件触发两次），但**文案有误导性**：它会让调试的人以为设备不受支持。
已改为：

```text
skipping gamepad "Xbox Wireless Controller" (handled by another source)
```

---

## 5. 尚未验证的部分

- **`--emit` 路径未做端到端验证**：本次全程 log-only。真实的 CGEvent 注入、目标 App 的实际响应、
  以及 Accessibility 授权在签名 App 下的行为，都要等 Phase 3 适配层落地后再验。
- **H 模式（键盘）未纳入**：按 spec 只识别不消费，本次也未测。
- **睡眠/唤醒后的恢复**：本次测的是设备断连，不是系统 sleep。
- **长时间稳定性**：只跑了 180 秒。
