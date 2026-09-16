# Claude 桌面版：命令与键位的实测记录（2026-09-16）

> 这份文档回答一个问题：**我们能把哪些 Claude 命令交给手柄，依据是什么。**
> 结论按「证据强度」分级，未验证的一律不写进菜单。

## 1. 结论速查

| 语义动作 | Claude 命令 | 键位 | 证据强度 |
|---|---|---|---|
| `newChat` | `File > New Chat` | `⌘N` | **实测**（运行中菜单） |
| `inspectChanges` | `View > Show Changes` | `⌘⇧D` | **双重印证**：运行中菜单 + App 内快捷键表 |
| `openTerminal` | `View > Show Terminal` | `⌘J` | **双重印证**：同上 |
| `openBrowser`（未建模） | `View > Show Browser` | `⌘⇧F` | 仅 App 内快捷键表 |
| `openSideChat` | `View > Show Side Chat` | `⌘;` | 仅 App 内快捷键表 |
| `openFiles`（未建模） | `View > Show Files` | `⌘⇧?` | **键位未知**（不在表里） |
| `openModelPicker` | `openModelMenu` | `⌘⇧I`（表内） | **冲突未解，禁止使用**（见 §3） |
| `openPermissionModeMenu` | `openModeMenu` | `⌘⇧M` | 仅表内 |
| `toggleFastMode` | `toggleFastMode` | `⌥⌘F` | 仅表内 |

**「实测」= 从运行中 App 的菜单读出**；**「表内」= 从 Claude 自己的 JS bundle 提取**。

## 2. 证据来源

### 2.1 运行中菜单（最可信）

```bash
swift Tools/dump-menu-accelerators.swift Claude
```

56 条，其中与本项目相关的：

```text
[on ] File > New Chat                    cmd+n
[OFF] View > Show Terminal               cmd+j
[OFF] View > Show Changes                cmd+shift+d
[OFF] View > Show Browser                cmd+shift+b   ← 注意：与 bundle 表里的 ⌘⇧F 不一致
[OFF] View > Show Files                  cmd+shift+f
[OFF] View > Show Side Chat              cmd+;
```

**`[OFF]` 的含义**：菜单项存在，但**当前语境下被 Claude 自己禁用**。这是 Claude 的行为，
不是我们的问题 —— 一个普通 chat 会话里，这些 Code 面板命令本来就不可用。

### 2.2 App 内快捷键表（权威，但要分辨语境）

Claude 把快捷键表打进了自己的 bundle：

```text
/Applications/Claude.app/Contents/Resources/ion-dist/assets/v1/shared-21-BReOo3jr.js
```

共 36 条，带 `when` 语境判断（`isClaudeApp` / `!isClaudeApp`）。与本项目相关的：

```text
toggleDiff        cmd+shift+d   when:"isClaudeApp"     → 与运行中菜单一致 ✅
toggleTerminal    cmd+j         when:"isClaudeApp"     → 与运行中菜单一致 ✅
toggleBrowser     cmd+shift+f   （无 when）             → 与运行中菜单的 ⌘⇧B 冲突 ⚠️
toggleSideChat    cmd+;                                 → 待验证
openModeMenu      cmd+shift+m   when:"isClaudeApp"
openModelMenu     cmd+shift+i                           → 与 incognito 冲突 ❌
toggleFastMode    cmd+alt+f
```

**能交叉印证的两条（⌘⇧D、⌘J）与运行中菜单逐字一致**，这提高了整张表的可信度；
但表里带**无 `when`** 的条目是**网页版**口径，不能直接用于桌面版（`⌘⇧F` 就是例子）。

## 3. `⌘⇧I` 未解之谜（重要）

- Claude 的 bundle 表：`openModelMenu = ⌘⇧I`
- 本项目调研笔记：`incognito = ⌘⇧I`
- 用户实测：手柄菜单里选「切换模型」→ **进入了匿名会话**
- 我的实测：向前台（已确认是 Claude）发送 `⌘⇧I`，**菜单与窗口均无可见变化**

也就是说：**冲突真实存在，但我没能复现它的触发条件**。两种可能都无法排除：

1. `⌘⇧I` 在特定语境内是匿名会话（用户看到的现象）；
2. 用户当时选中的菜单项并非 `openModelPicker`（记忆或界面歧义）。

**处置：`openModelPicker` 在 Claude 侧保持 unsupported，且不进入菜单。**
理由与结论无关 —— 无论哪种解释成立，**我们都没有把握它不会做错事**，而「偷偷建一个匿名会话」
是不可接受的失败模式。宁可少一个功能。

要重新启用它，需要满足其一：
- 在 Claude 的 **Settings → Keyboard Shortcuts**（若有）里确认模型菜单的真实键位；
- 或找到不依赖快捷键的路径（命令面板 `⌘K` 里搜 "model"），把那串操作做成宏。

> 附带结论：**Claude 里切模型请走 `B+→` 的命令面板（`⌘K`）**，那条路不依赖未验证键位。

## 4. 为什么没能验证 Code 面板命令

要在 Code 会话里验证 `⌘J` / `⌘⇧D`，必须先「打开一个项目」：

- Claude 的 File 菜单里没有「新建 Code 会话」，只有 `Open File…`（⌘O）与 `Open Folder…`（⌘⇧O）；
- 两者都会弹出**原生文件选择框**，需要驱动 AppKit 的 open panel 才能完成；
- 而这会在用户的仓库里真的建一个 Code 会话（可能触发 Claude 自己的读写）。

判断：**代价与风险高于收益**，所以停在这里，把结论如实记录，而不是用推断填补。

**键盘探针本身也踩了坑（值得记下）**：

- `NSRunningApplication.activate(options:)` 在本机 **无效**（此前实测过六种激活方式，只有
  AppleScript 可用）；探针用它激活 → 前台仍是微信 → **按键全发给了微信**，前几轮测试结论
  全部无效；
- 改用 AppleScript 激活并**在发送前校验前台 bundle ID** 之后，才确认事件真的进了 Claude。

这条与 `docs/HANDOFF.md` §7 第 12 条同源：**激活只能靠 AppleScript**。

## 5. 对程序的处置

1. Claude 的菜单只列**键位已双重印证**的两条 Code 命令 + 已验证的 `New Chat`：
   `新建对话`（⌘N）、`显示变更`（⌘⇧D）、`显示终端`（⌘J）。
2. 标签改用 **Claude 菜单自己的措辞**（Show Changes / Show Terminal），不再复用 Codex 的中文标签。
3. `openModelPicker` 保持 unsupported（理由写进适配器注释）。
4. 菜单项执行时**在日志里记下注入的键**，这样「按了没反应」可以和日志对照 ——
   语境受限的命令（chat 下的 ⌘J/⌘⇧D）表现为「键发出去了，Claude 没接」，
   这属于 Claude 的语境规则，不是我们的失败。
