# 功能测试手册（2026-09-18 批次）

> 这份手册只写**你能上手做、能用眼睛和日志判定**的事。代码怎么改的不在这里，
> 想看去 `docs/ux-roadmap.md` §7 和 `.impl-reports/`（每张任务单的实现报告，未跟踪进 git，看完可删）。
> 全部改动目前**未提交**，在工作树里；测完决定要不要 commit。
> 所有新功能都只过了单元测试（292 用例全绿），**没有一项接过真手柄**——所以才需要你。

## 0. 这批改了什么（一句话版）

| 编号 | 用户可见的变化 | 单测 | 实机 |
|---|---|---|---|
| M1 | 菜单栏的 `Show Controller Menu` / `Show App Switcher` 以前实际上不能用（开出来也执行不了），现在能用 | ✅ | ⬜ |
| M2 | A 键：连按两次不再把「长按」阈值推后；长按说话中途切 App / 改配置不再把右 ⌥ 卡住 | ✅ | ⬜ |
| M3 | 菜单 / 切换器打开、关闭前后，按键不会泄漏到后面的窗口（这次是加了 12 个用例证明，没改代码） | ✅ | ⬜ |
| M4 | 切换器里连按 ←→ 不再每按一下重建整个浮层；日志不再刷屏 | ✅ | ⬜ |
| M5 | 被拦截 / 不支持 / 切换失败时，屏幕顶部弹 3 秒中文提示，以前是「按了没反应」 | ✅ | ⬜ |
| M6 | Codex 命令菜单可切换成「四向操作盘」实验布局（默认仍是列表） | ✅ | ⬜ |
| 文档 | README / HANDOFF 里「A 短按按下即发 Enter」改成真实语义：**松开时发** | — | — |

## 1. 准备（每次测试前）

```bash
cd ~/Documents/agentController
swift test 2>&1 | tail -3                 # 期望 Executed N tests, with 0 failures
./scripts/make-agent-app.sh debug         # 打包 build/PocketAgentRemote.app
```

1. **备份旧日志**：`cp ~/Library/Application\ Support/PocketAgentRemote/debug.log ~/Desktop/debug-before.log`
2. **退出正在跑的旧实例**：菜单栏手柄图标 → Quit。别同时跑两份。
3. `open build/PocketAgentRemote.app`，确认菜单栏出现图标，Accessibility 授权还在（菜单里能看到）。
4. 另开一个终端窗口一直挂着日志：

```bash
tail -f ~/Library/Application\ Support/PocketAgentRemote/debug.log
```

日志格式是 `[启动后秒数] 标签 消息`。这批新增了两个标签：`TOAST`（屏幕上弹了什么）和 `OVERLAY`（浮层这一轮重建了几次）。
`SEND` / `MENU` 大多是 `OUTPUT` 标签里的前缀，grep 时用 `rg 'SEND|MENU'` 别只按标签筛。

**模式切换**：菜单栏 → `Profile Mode` → Auto / Manual。Auto 跟随前台 App；Manual 下才检查白名单。
下面有几项要用 Manual。

## 2. 测试项

每项格式：怎么做 → 应该看到 → 日志里应该有 → 判定。判定不过就把当时的日志段贴给我。

### M1 菜单栏入口能用了（对应 T0.5）

**怎么做**
1. Codex 在前台。菜单栏 → `Show Controller Menu`。
2. 浮层出现后 ↓ 一次选「查看变更」，按 A。
3. 再来：菜单栏 → `Show App Switcher`，←→ 选一个别的程序，按 A。

**应该看到**：第 2 步 Codex 真的打开了变更视图；第 3 步真的切到了那个程序。

**日志**
```
OUTPUT  MENU  opened for com.openai.codex with 5 items     ← 不是 opened for ?
OUTPUT  MENU  running showChanges (查看变更) → …
FOCUS   openAppSwitcher: focused <bundleID> via appleScript in … ms
```

**判定**：两个入口都执行成功，且日志里没有 `opened for ?`、没有 `menu item refused`。
以前的表现是：Auto 模式下 `Show Controller Menu` 根本开不出来；切换器开得出但按 A 什么都不发生。

### M2 A 键的四种边界（对应 T0.2）

先在 Codex 里开一个**空白的新会话**，输入框里随便打两个字但不要发送，用它当靶子。别在审批弹窗上测。

| # | 怎么做 | 应该看到 | 日志 |
|---|---|---|---|
| 2a | A 短按 5 次 | 每次松开时消息发出（不是按下时）；5 条 | 每次 `SEND down submit → enter` + `SEND up`，成对 |
| 2b | A 按住 2 秒说一句话，松开 | 豆包录音 → 文字落到输入框；**没有**发送 | `GESTURE holdBegan(a)` … `holdEnded(a)`；`SEND down … rightOption` / `SEND up … rightOption` 各一次；**没有** enter |
| 2c | （手动做不出来：这是防 HID 抖动的修复，真实按钮不会在没抬起时再按下一次；单测已覆盖，跳过） | — | — |
| 2d | **先临时改配置**（见下）→ Codex 前台 A 按住开始说话 → 说话中用**鼠标**点到 Claude 窗口 → 松开 A → 改回配置 | 回到任一输入框打字，**字符正常**，没有变成 ⌥ 组合字符（如打 `a` 出来 `å` 就是卡键） | `SEND down … rightOption → com.openai.codex` 和 `SEND up … rightOption` 两行 stroke **相同**都是 rightOption（修前第二行是 `option`） |
| 2e | 2b 之后，立刻 B 长按开切换器 → ←→ 移动 → B 关闭 | 切换器正常，方向键正常 | 无异常 |

**2d 的临时配置**：你现在的 `a.hold` 两个 profile 都用代码默认的右 ⌥，这个 bug 触发不了，所以要让两边不一样。
菜单栏 → `Open Config File`，在 `profileGestureKeyOverrides.claudeCode` 里加一行：

```json
"a.hold": { "modifiers": ["option"], "hold": true }
```

`Reload Config` 后做 2d；做完删掉这行再 `Reload Config`。

**判定**：2c 与 2d 是这次修的两个真 bug。2d 修前的表现是 `down → rightOption`、`up → option`，之后系统右 ⌥ 一直按着；
不改配置的话 2d 修前修后都会过，只能算回归检查。

### M3 菜单打开 / 关闭不泄漏按键（对应 T0.3）

靶子同上（Codex 空会话，输入框有草稿）。

| # | 怎么做 | 应该看到 |
|---|---|---|
| 3a | 按住 B → 按 ← → **先松 ←、再松 B** → 菜单还在 → B 关闭 | 输入框草稿没被动；没有多出的 Escape 效果（会话没被取消） |
| 3b | 按住 B → 按 ← → **先松 B、再松 ←** → ↓↓ → A | 执行了第 3 项「打开终端」；输入框没收到方向键 |
| 3c | 按住 B → 按 ← → 不松 B 直接 ↓ → A → 再松 B | 执行选中项；松 B 不再补 Escape |
| 3d | 开菜单 → 用鼠标点 Chrome → 回来看 | 菜单自动消失；日志 `MENU  closed`；Chrome 没收到任何键 |
| 3e | 开菜单 → 拔手柄 / 关手柄 | 菜单消失；日志先 `disconnected (…)` 后 `MENU  closed` |

**日志判定**：菜单打开期间**不应**出现任何 `SEND navigate*`、`SEND submit`、`SEND cancelOrInterrupt`；
关闭后第一个方向键正常成对 `SEND down/up`。

### M4 切换器不再每按一下重建（对应 T1.1）

**怎么做**
1. 尽量开够多程序（目标 ≥ 10 个，17 个最好）。
2. B 长按 → 松开 → 连按 ← 或 → 20 次以上 → A 切换。
3. 再做一次：B 长按 → ←→ 几次 → B 关闭。

**应该看到**：连按时高亮移动跟手、无停顿感（以前 17 个图标时每按一下都重画整条）。

**日志**（一次完整切换）
```
OUTPUT  MENU  app switcher opened with 17 apps
OVERLAY session ended: rebuild=1 timer=1          ← 关键（浮层在执行前就关，所以它排在 switching 前面）
OUTPUT  MENU  switching to <bundleID> (<名字>)
FOCUS   openAppSwitcher: focused … via appleScript in … ms
```
**判定**：`rebuild=1 timer=1`，且**没有**一堆 `MENU  open for 切换程序: …`（旧行为每按一下一行）。
`MENU` 行合计 ≤ 3。若 rebuild 不是 1，把整段贴给我。`OVERLAY` 这行是临时探针，验收后会删。

### M5 失败提示（对应 T1.2）

提示出现在**屏幕顶部居中**，深色胶囊，3 秒后自己消失。它**不响应任何按键**，B 该干嘛还干嘛。

| # | 怎么做 | 应该看到的提示 | 日志 |
|---|---|---|---|
| 5a | Auto 模式，**Chrome 在前台**，按 `B+↑` | `通用模式 不支持：最近会话 1` | `SKIP  goToRecentChat1: …` + `TOAST 通用模式 不支持：最近会话 1` |
| 5b | Auto 模式，Chrome 前台，按 `B+←` | `打不开菜单：前台不是 agent` | `SKIP  openMenu: …` + `TOAST …` |
| 5c | 菜单栏切 **Manual**，Profile 选 Codex，把 Finder 切到前台，按 `B+↑` | `已拦截：前台不是 agent（不在白名单）` | `DENY  goToRecentChat1: …` + `TOAST …` |
| 5d | 切换器里选一个**切不过去**的程序（之前日志里微信失败过）按 A | `切换失败：微信（<原因>）` | `FOCUS … could not focus …` + `TOAST …` |
| 5e | 提示显示中按 B 轻按（Codex 前台） | Codex 收到 Escape，行为和没提示时一样；提示不因此消失 | `SEND … escape` |
| 5f | 先触发 5a，3 秒内再触发一次 | 新文案替换旧文案，重新计 3 秒 | 两行 `TOAST` |
| 5g | 开着 `B+←` 菜单时触发不了失败（菜单吃掉按键）——改为：开菜单前 1 秒先触发 5a，再立刻开菜单，等提示到期 | 提示消失后**菜单还在**，↑↓A 正常 | — |

**判定**：5a/5b/5c 三条必须能看见提示且文案一致；5e 证明提示不吞键。测完记得把 Profile Mode 切回 Auto。
5d 依赖微信那个失败能复现，复现不了就记「未触发」。

### M6 四向操作盘 Dial（对应 T1.3）

**怎么打开**：菜单栏手柄图标 → `Command Menu: List / Dial (experimental)` → 勾 **Dial**。
默认是 List；这个选择只在本次运行有效，重启 App 回到 List，配置文件不动。然后 **Codex 切到前台**，按 `B+←`。
Claude 前台时开关无效，仍出原列表。

**看到什么**：屏幕下方一块方形浮层，上「新建会话」、左「查看变更」、下「打开终端」、右「更多」，正中是 Codex，
底部一行 `方向选择 · A 执行 · B 关闭`。**刚打开时四个槽都不高亮**，这是有意的：表示还没选中任何东西。

**怎么操作**：按一个方向 → 那个槽高亮（不执行）；按 A → 执行高亮的槽，浮层关闭。
`→` 再 `A` 进「更多」（竖列表：切换模型 / 归档会话），里面 `↑↓` 选、`A` 执行、`B` 回到四向盘（回来时又是无高亮）。
四向盘上按 `B` 关闭整个菜单。没选中时按 A 什么都不发生，菜单也不关。切前台 App 会关掉整个菜单含子页。

| # | 怎么做 | 应该看到 | 日志 |
|---|---|---|---|
| 6a | 开 Dial：按住 B → 按 ← → 松开两键（两种松开次序各试一次） | 四槽都**不**高亮；Codex 没收到任何键 | `MENU  opened for com.openai.codex with 4 items`，无 SEND |
| 6b | 按 ↑ 然后 ← 然后 ↓ | 高亮跟着方向跳，**不执行** | 无 SEND |
| 6c | 开 Dial 后不按方向直接按 A | 什么都不发生，菜单还在 | 无 SEND、无 closed |
| 6d | ↓ 然后 A | Codex 打开终端，菜单关闭 | `MENU  running openTerminal (打开终端) → ⌃\`` |
| 6e | → 然后 A | 进「更多」竖列表，两项 | `MENU  更多 page opened with 2 items` |
| 6f | 在「更多」里按 B | 回到四向盘，无高亮；Codex **没收到 Escape** | `MENU  back to the dial`，无 SEND escape |
| 6g | 在「更多」里 ↓ 选归档 → 别按 A，按 B 回来，再 B | 菜单关闭；没有归档任何会话 | `MENU  closed by B` |
| 6h | 开 Dial → 鼠标点 Chrome | 菜单消失 | `MENU  closed` |
| 6i | 开 Dial → ↑ → A 按住 1.5 秒再松 | 只新建一次会话；**不**触发录音 | 一条 `SEND … ⌘N`，无 rightOption |
| 6j | 切回 List，再 `B+←` | 回到原来的竖列表，第一项默认选中 | `opened for … with 5 items` |

**判定**：6a/6c/6f/6i 是安全性，必须过；6d 的快捷键要真的打开 Codex 终端。
浮层是 460pt 见方，笔记本屏幕上若裁切请截图给我（原型没做自适应缩放）。

**按键次数对照**（列表 vs Dial，实体键 press 数）

| 动作 | 旧列表 | Dial |
|---|---|---|
| 新建会话 | `B+← A` = 3 | `B+← ↑ A` = 4（**多一下**） |
| 查看变更 | `B+← ↓ A` = 4 | `B+← ← A` = 4 |
| 打开终端 | `B+← ↓↓ A` = 5 | `B+← ↓ A` = 4 |
| 切换模型 | `B+← ↓↓↓ A` = 6 | `B+← → A A` = 5 |

最高频的「新建会话」在 Dial 下多一次，这正是 §3 S2 对照实验要盯的那条。默认布局保持 List，直到 S2 有数据。

### M7 B+A 退格 与 按住重复（2026-09-21）

靶子：Codex 空会话，输入框里先用语音或键盘放一句十几个字的话，光标在句尾。

| # | 怎么做 | 应该看到 | 日志 |
|---|---|---|---|
| 7a | 按住 B，按一下 A，松开 | 删掉光标前 1 个字 | `SEND down  deleteBackward → delete`、`SEND up    deleteBackward → delete` |
| 7b | 按住 B，按住 A 不放约 1 秒，松开 A | 先删 1 个字，停顿一下后连续删，约每秒 12 个；松开即停 | 一行 down、一行 up，中间的重复不记日志 |
| 7c | 按住 B，按住 A，**先松 B**，A 继续按着 | 还在连续删；松开 A 才停；没有 Escape（会话没被取消） | 同上 |
| 7d | ← 按住不放 | 光标连续左移（以前每按一次只动一格） | `SEND down navigateLeft` … `SEND up` |
| 7e | 浏览器地址栏里打几个字，B+A | 一样能删 | 无 DENY、无 TOAST |
| 7f | 按住 B+A 连删中，用鼠标点到别的窗口 | 连删立刻停；松开 A 后回来打字正常，没有卡键 | — |
| 7g | A 单独短按 / 长按 | 仍是提交 / 语音，不受影响 | — |
| 7h | 首次启动后看配置 | `config.json` 里 `gestureKeyOverrides` 的 `b.a` 没了，旁边多了一个 `config.json.backup-…` | — |

**判定**：7a/7b/7c/7f 必须过。重复节奏（0.35 s 后每 80 ms）是拍脑袋定的，太快太慢告诉我改。

## 3. 需要你做的实机 spike（代码做不了的部分）

这些在 §7 里是有 time-box 的验证单，只有你有手柄和真实 App。每项都给了记录表，填完给我。

### S1 微信切换失败复现（T0.4，2 小时封顶）

1. 确认微信在运行。从 Codex 前台开切换器，选微信按 A。重复 5 次。
2. 每次记：成功/失败、日志 `FOCUS` 行原文（含 `via <method> in <ms>` 或 `could not focus … (<tried>)`）。
3. 失败时补两条：微信是否被最小化/隐藏；同样步骤切 Claude 是否成功（对照）。
4. 失败后立刻再开切换器选别的程序 → 应能切走（这是 M5 的「失败后可恢复」）。

| 次 | 起始前台 | 结果 | FOCUS 行 | 微信状态 |
|---|---|---|---|---|
| 1–5 | | | | |

### S2 列表 vs Dial 对照（T1.4，3 小时封顶）

Codex 前台，用一个**可丢弃的测试会话**。四个动作各做 5 次，列表和 Dial 交错（ABBA）。练习一轮不计。

每次记：动作、布局、从第一下 B 到**屏幕上看到结果**的秒数（手机秒表就行）、实体按键次数、有没有选错/返回。

| 动作 | 布局 | 耗时 s | 按键数 | 错选 |
|---|---|---|---|---|
| 新建会话 | List / Dial | | | |
| 查看变更 | | | | |
| 打开终端 | | | | |
| 切换模型 | | | | |

判定规则（§7.3 T1.4）：Dial 加权中位耗时比列表低 ≥15%、错选不增加、「新建」不慢超过 10% → 才考虑默认启用；否则保持列表。

### S3 任务定位能力（T2.1，每工具 2 小时封顶）

问题只有一个：**Codex / Claude 能不能从外面精确打开某个指定会话**，而不只是把 App 带到前台。

1. 每个工具挑两个现有测试会话 A、B。
2. 查该 App 有没有分享链接、URL scheme、菜单里的「最近会话」是否稳定指向同一个。
3. 用找到的方法打开 A 5 次、B 5 次，**每次先离开目标会话**再打开。记落点对不对。
4. 试无效链接 / App 未运行。

只要一个工具能 10/10 正确、且不发消息，就值得做「我的任务」收藏；否则搁置。

### S4 回到输入框（T3.1，每工具 2 小时封顶）

1. 在 Codex 里打开变更视图（`B+←` → 查看变更）。
2. 找一个**不用鼠标**回到输入框的办法（快捷键 / Tab 次数 / 菜单项），记下来。
3. 用它回到输入框 → A 长按说一句 → 松开 → 检查文字落在输入框、旧草稿还在 → A 发送。5 次。
4. 试：输入框里已有一段被选中的文字时做同样的事，旧文字不能被替换。

能稳定回去且不丢草稿 → 下一批做成菜单项；否则保持现状。

## 4. 已知限制 / 这批没做

- `OVERLAY` 与 `TOAST` 日志行、`rebuildCount` 探针是临时的，M4/M5 验收通过后删。
- 没做成功提示、没做每次 SEND 的提示、没加任何配置项；toast 不能用手柄关。
- 「已拦截：前台已切换，菜单项未执行」这条提示很难触发（浮层 0.15 s 轮询通常先把菜单关了），不在测试项里。
- App 层（AppKit）没有测试 target，M1/M4/M5/M6 的界面行为全靠你实机。
- 「A 短按按下即发」这一设计承诺与「长按不提交」不可兼得，代码现状是**松开才发**（最多晚 220 ms）。要不要改回「按下即发、放弃单键语音」是产品决定，不是这批的 bug。
- F1 连走 / F2 持久 MRU / F4 取景窗 / F8 开机自启 / F9 权限提示 / F10 睡眠唤醒 / U1–U3 样式：本批未做。

## 5. 结果回填

| 项 | 通过 | 备注 / 日志段 |
|---|---|---|
| M1 | ⬜ | |
| M2 (2a–2e) | ⬜ | |
| M3 (3a–3e) | ⬜ | |
| M4 | ⬜ | |
| M5 (5a–5g) | ⬜ | |
| M6 | ⬜ | |
| M7 (7a–7h) | ⬜ | |
| S1–S4 | ⬜ | |
