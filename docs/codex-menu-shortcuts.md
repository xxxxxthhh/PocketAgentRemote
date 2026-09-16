# Codex 桌面 App 的菜单快捷键（实测导出）

> 数据来源：`swift Tools/dump-menu-accelerators.swift ChatGPT`
> 导出时间：2026-09-16 · Codex `com.openai.codex` 26.908.40834
> 这是**运行中 App 的原生菜单**读出来的，不是 App 内部的命令注册表。

## 为什么不用命令注册表

实测踩过一次坑：`inspectChanges` 原本按注册表的 `openReviewTab = ⌃⇧G` 实现，
注入后**毫无反应**；而菜单里 `View > Toggle Review Panel` 实际绑的是 `⌥⌘B`，一按就生效。

**静态注册表 ≠ 运行时绑定。** 能从运行中菜单读到的，一律以菜单为准。

---

## 全部 44 条

`[on]` / `[OFF]` 是导出那一刻的可用状态（部分项在特定上下文中才启用）。

### File

| 菜单项 | 快捷键 | 状态 |
|---|---|---|
| New Chat | `⌘N` | on |
| New Temporary Chat | `⌘⇧N` | **OFF** |
| Open Folder… | `⌘O` | on |
| Close | `⌘W` | on |

### View

| 菜单项 | 快捷键 | 状态 | 我们是否在用 |
|---|---|---|---|
| Toggle Sidebar | `⌘B` | on | |
| Toggle Bottom Panel | `⌘J` | on | |
| Open Terminal | `` ⌃` `` | on | ✅ `B + ↓` |
| Toggle File Tree | `⌘⇧E` | on | |
| **Toggle Review Panel** | **`⌥⌘B`** | on | ✅ `B + A` |
| Find | `⌘F` | on | |
| Previous Chat | `⌘⇧[` | on | |
| Next Chat | `⌘⇧]` | on | |
| Back | `⌘[` | on | |
| Forward | `⌘]` | on | |
| Zoom In | `⌘+` | on | |
| Zoom Out | `⌘-` | on | |
| Actual Size | `⌘0` | on | |
| Enter Full Screen | ⚠️ 见下 | on | |
| Browser > Open Browser Tab | `⌘T` | on | |
| Browser > Reload Browser Page | `⌘R` | **OFF** | |

### Edit

| 菜单项 | 快捷键 | 状态 |
|---|---|---|
| Undo | `⌘Z` | on |
| Redo | `⌘⇧Z` | on |
| Cut / Copy / Paste | `⌘X` / `⌘C` / `⌘V` | on |
| Paste and Match Style | `⌘⇧V` | on |
| Select All | `⌘A` | on |
| Start Dictation… | ⚠️ 见下 | on |
| Emoji & Symbols | ⚠️ 见下 | on |

### App / Window / Help

| 菜单项 | 快捷键 | 状态 |
|---|---|---|
| Settings… | `⌘,` | on |
| Hide ChatGPT | `⌘H` | on |
| Hide Others | `⌥⌘H` | on |
| Quit ChatGPT | `⌘Q` | on |
| Minimize | `⌘M` | on |
| Minimize All | `⌥⌘M` | on |
| Fill | `⌃F` | on |
| Center | `⌃C` | on |
| Move & Resize > Return to Previous Size | `⌃R` | **OFF** |
| **Help > Keyboard Shortcuts** | **`⌘/`** | on |

### 系统菜单（macOS 自己的，不是 Codex 的）

Force Quit `⌥⌘⎋` · Lock Screen `⌃⌘Q` · Log Out `⌘⇧Q` 等 —— 这几个**不要绑到手柄上**。

---

## ⚠️ 三条不可靠的条目

导出工具把某些**功能键 / 特殊字形**解码成了裸字母，看起来像「无修饰键的单键」：

| 菜单项 | 导出值 | 实际情况 |
|---|---|---|
| View > Enter Full Screen | `f` | 几乎肯定是 `⌃⌘F`，我的字形表没覆盖到 |
| Edit > Start Dictation… | `🎤` | 是 `fn fn`（双击 Fn），无法用 CGEvent 合成 |
| Edit > Emoji & Symbols | `e` | 是 `⌃⌘Space` |

**这三条在绑定前必须单独实测**，不要直接照抄。

---

## 怎么把它们绑到你的手柄

### 现在就能做的（改键，不改手势）

配置里的 `actionKeyOverrides` 可以让**已有的 17 个语义动作**改发任意按键。
例如你想让 `B + A` 去开关侧栏（`⌘B`）而不是审阅面板：

```json
"actionKeyOverrides": {
  "inspectChanges": { "key": "b", "modifiers": ["command"] }
}
```

改完菜单 → `Reload Config` 即生效。

### 现在还做不到的（把任意命令绑到任意手势）

**手势 → 语义动作** 的映射目前是固定的 11 条（6 个基础 + 5 个 chord）。
所以那 44 条里，你能用的前提是「占用一个已有的语义动作」。

要真正做到「任意手势 → 44 条里的任意一条」，需要给配置加一层
`gestureKeyOverrides`（手势 → 按键，绕过语义动作词表）。**这还没实现。**

### 挑候选时的建议

六键手柄只有 12 个手势，而这 44 条里有一半是系统级或编辑级（Don't 绑）。
对 agent 工作流真正有价值的大致是：

| 候选 | 键 | 为什么值得 |
|---|---|---|
| Next / Previous Chat | `⌘⇧]` / `⌘⇧[` | 在会话间跳转，比方向键更直接 |
| Toggle Sidebar | `⌘B` | 一屏信息密度切换 |
| Toggle Bottom Panel | `⌘J` | |
| Toggle File Tree | `⌘⇧E` | |
| Open Folder | `⌘O` | 换工作区 |
| Back / Forward | `⌘[` / `⌘]` | 导航历史 |
| Help > Keyboard Shortcuts | `⌘/` | **Codex 自己的完整快捷键面板 —— 值得先按一次看看** |

> `⌘/` 那条建议你手动按一下：它会弹出 Codex 官方列出的全部快捷键，
> 比我这个从菜单导出的列表更全（菜单项之外的快捷键不会出现在菜单里）。
