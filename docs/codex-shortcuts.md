# Codex 桌面 App 快捷键

> 两部分来源，**优先信任前者**：
> 1. **官方快捷键面板**（Codex 内按 `⌘/` 打开）—— 2026-09-16 由用户逐屏截图提供
> 2. **菜单实测导出**（`swift Tools/dump-menu-accelerators.swift ChatGPT`）—— 可随时重新生成
>
> 为什么需要后者：官方面板只列 App 自己注册的快捷键；菜单导出能反映**当前实际可用状态**
> （哪些项此刻是灰的）。两者互补。
>
> ⚠️ 面板是长列表，用户截图之间**可能有少量遗漏**（Project 段与 App 段之间、General 段与后续之间
> 看不出是否连续）。标 `?` 的行表示该段可能还有未截到的项。

---

## 一、官方快捷键面板

使用 `⌘/` 打开。下表按面板的分组原样记录。

### 会话（面板顶部，无分组标题）

| 命令 | 快捷键 |
|---|---|
| New chat | `⌘N` / `⇧⌘O` |
| Quick chat | `⌥⌘N` |
| Archive chat | `⇧⌘A` |
| New standalone chat | `⌥⌘O` |
| Toggle pin | `⌥⌘P` |

### Navigation

| 命令 | 快捷键 |
|---|---|
| Find | `⌘F` |
| Back | `⌘[` / Mouse Back |
| Forward | `⌘]` / Mouse Forward |
| Next recently viewed chat | `⌃Tab` |
| Previous recently viewed chat | `⌃⇧Tab` |
| Next tab | `⌃Tab` / `⇧⌘]` / `⌥⌘→` |
| Previous tab | `⌃⇧Tab` / `⇧⌘[` / `⌥⌘←` |
| Next chat | `⇧⌘]` / `⌥⌘→` |
| Previous chat | `⇧⌘[` / `⌥⌘←` |
| **Next chat needing attention** | **`⌥⌘A`** |
| **Go to recent chat 1 … 6** | **`⌥⌘1` … `⌥⌘6`** |
| Switch to Chat | `⌃1` |
| Switch to Work | `⌃2` |
| Switch to Codex | `⌃3` |

### Panels

| 命令 | 快捷键 |
|---|---|
| Open browser tab | `⌘T` |
| Reopen closed tab | `⇧⌘T` |
| Toggle browser panel | `⇧⌘B` |
| Toggle bottom panel | `⌘J` |
| Toggle sidebar | `⌘B` |
| Toggle Review panel | `⌥⌘B` |
| Open terminal | `` ⌃` `` |

### Project

| 命令 | 快捷键 |
|---|---|
| Open folder | `⌘O` |
| ? | 截图间可能有遗漏 |

### App

| 命令 | 快捷键 |
|---|---|
| Clear all unreads | `⇧⎋` |
| Show pet | `⌥Space` |
| Settings | `⌘,` |

### General

| 命令 | 快捷键 |
|---|---|
| Close other tabs | `⌥⌘W` |
| Close Tab | `⌘W` |
| Close | `⌘W` |
| **Open model picker** | **`⌃⇧M`** |
| Open project picker | `⌥⇧⌘O` |
| Toggle voice chat | `⌃⇧V` |
| Send message in background | `⌘⏎` |
| ? | 截图间可能有遗漏 |

### 其余

| 命令 | 快捷键 |
|---|---|
| Copy conversation path | `⌥⇧⌘C` |
| Copy deeplink | `⌥⌘L` |
| Copy working directory | `⇧⌘C` |
| Toggle dictation hotkey | `⌃⌥⌘D` |
| Force Reload Browser Page | `⇧⌘R` |
| Reload Browser Page | `⌘R` |
| **Open command menu** | **`⌘K` / `⇧⌘P`** |
| Rename chat | `⌥⌘R` |
| Search Files… | `⌘P` |
| Show keyboard shortcuts | `⌘/` |
| Go to chat 1 / 2 / … | `⌘1` / `⌘2` / … |

---

## 二、菜单实测导出

```bash
swift Tools/dump-menu-accelerators.swift ChatGPT
```

作用有两层：

1. **交叉印证**官方面板（例如 `Toggle Review panel = ⌥⌘B`、`Open terminal = ⌃\``、`New chat = ⌘N` 都一致）
2. **读当前可用状态** —— 官方面板不告诉你哪些项此刻是灰的

实测踩过的坑：`inspectChanges` 原本按 App 内部命令注册表的 `openReviewTab = ⌃⇧G` 实现，
注入后**毫无反应**；而菜单里 `View > Toggle Review Panel` 实际绑的是 `⌥⌘B`，一按就生效。

> **静态注册表 ≠ 运行时绑定。** 能从运行中菜单或官方面板读到的，一律以它们为准。

`docs/codex-menu-shortcuts.md` 是只含菜单导出的早期版本（44 条），保留作对照。

---

## 三、怎么绑到手柄

### 改键（不改手势）

`actionKeyOverrides` 让已有的**语义动作**改发任意按键：

```json
"actionKeyOverrides": {
  "inspectChanges": { "key": "b", "modifiers": ["command"] }
}
```

### 任意手势 → 任意命令（已实现）

`gestureKeyOverrides` **绕过语义动作词表**，手势标识符共 11 个：

```text
基础层      up · down · left · right · a
B 手势      b.tap · b.hold
chord       b.up · b.down · b.left · b.right · b.a
```

```json
"gestureKeyOverrides": {
  "b.up":  { "key": "1", "modifiers": ["option", "command"] },
  "b.tap": { "key": "b", "modifiers": ["command"] }
}
```

改完菜单 → `Reload Config` 即生效，**不需要重新构建**。

自定义绑定按工具专属动作处理：需要选定 profile + 前台 App 在白名单内。
写错的手势标识符会被忽略并在日志里列出，不会导致配置解析失败。

---

## 四、当前的默认映射（2026-09-16 起）

采用「会话跳转」形态，因为它是六键手柄能最接近 Codex Micro 的形态：

| 手势 | 动作 | 键 |
|---|---|---|
| B + ↑ ↓ ← → | 跳到最近会话 1-4 | `⌥⌘1` … `⌥⌘4` |
| B + A | 跳到需要我处理的会话 | `⌥⌘A` |

被替换掉的（可用 `gestureKeyOverrides` 找回）：
`新建会话` `⌘N` · `终端` `` ⌃` `` · `模型选择器` `⌃⇧M` ·
`排队追问` `Enter` · `审阅面板` `⌥⌘B`。

---

## 四、对六键手柄最有价值的候选

手柄只有 12 个手势（5 基础 + 2 个 B 手势 + 5 个 chord），下面是按「对 agent 工作流的实际价值」排序的候选：

| 命令 | 键 | 价值 |
|---|---|---|
| **Next chat needing attention** | `⌥⌘A` | 一键跳到需要你处理的会话 —— 最接近 Codex Micro 的「agent 键」精神 |
| **Go to recent chat 1…6** | `⌥⌘1…6` | Micro 的六个 agent 键的对等物；我们的六个输入刚好对上 |
| Next / Previous chat | `⇧⌘]` / `⇧⌘[` | 会话间快速跳转 |
| Toggle sidebar | `⌘B` | 信息密度切换 |
| Open command menu | `⌘K` | 兜底入口，能到达面板里没列出快捷键的命令 |
| Clear all unreads | `⇧⎋` | |

> 注意 `⌥⌘1…6` 与当前默认映射的 `B + 方向键` 会冲突：两者都是 5 个 chord 位 + 1 个基础位。
> 要采用「六会话键」形态，就必须放弃现有的 `新建会话 / 终端 / 模型选择器 / 排队追问 / 审阅面板`。
