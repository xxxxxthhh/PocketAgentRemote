# Claude 桌面 App 可编程控制面调研

- 调研对象：`/Applications/Claude.app`（bundle id `com.anthropic.claudefordesktop`，版本 `1.52386.6`）
- 调研时间：2026-09-15
- 调研方式：只读静态分析（解 `app.asar` 到 `/tmp`）+ 运行时可观测（App 当时正在运行，PID 33588）
- 纪律说明：**未修改 `~/.claude/` 或 `~/.codex/` 下任何文件**；asar 解包到 `/tmp/claude-desktop-research/`；未提交 git；未启动新的 GUI 进程。

> **证据标注约定**
> - 【实测】= 本次实际运行命令并看到输出的结论。
> - 【静态】= 从二进制/JS bundle 的字符串与代码结构推断，未运行时验证。
> - 【未验证】= 有线索但本次未确认。

---

## 0. 结论速览（TL;DR）

| 问题 | 结论 |
|---|---|
| 桌面 App 有 Claude Code 能力吗？ | **有**。是内嵌的 Agent SDK + 本地打包的 Code UI（`ion-dist`），不是终端，也不是远程网页。 |
| `claude-cli://` 是给谁用的？ | 给 **`claude` CLI 自己**用的，与桌面 App 无关。Handler 可执行文件是指向 CLI 二进制的 symlink。 |
| `claude://` 有深链路由吗？ | **有，且是当前唯一被实测确认可用的外部编程入口**。已拿到完整 route 表（约 23 条），其中 4 条是"动作型"。 |
| 桌面 App 有本地 socket / HTTP / CLI 控制面吗？ | **没有**。无监听端口、无控制用 unix socket、`ccd` CLI 在这个版本里不存在。 |
| 菜单栏能用 `osascript` 读吗？ | **能**（Accessibility 权限已授予）。已实测枚举出完整菜单树。 |
| 11 个语义动作能走程序化吗？ | 见 [§7](#7-11-个语义动作映射建议)。**0 个能走专用编程接口**；4 个可走深链；其余需键位注入或 AX。 |

**最重要的一条**：Claude 桌面 App 没有 Codex 那种 `codex queue --thread <id>` 式的对等物。它的编程面只有 **`claude://` 深链 + macOS Accessibility（菜单点击 / 键盘注入）** 两层。

---

## 1. 基础事实核对

### 1.1 App 正在运行

```
$ pgrep -fl "Claude.app"
33588 /Applications/Claude.app/Contents/MacOS/Claude
33595 .../chrome_crashpad_handler ...
33596 ... --type=gpu-process --user-data-dir=~/Library/Application Support/Claude
33598 Claude Helper --type=utility --utility-subtype=network.mojom.NetworkService ...
33627 Claude Helper (Renderer) --type=renderer ... --app-path=/Applications/Claude.app/Contents/Resources/app.asar
33715 Claude Helper --type=utility --utility-subtype=node.mojom.NodeService ...
```

【实测】App 在调研期间始终运行，因此**运行时行为可以验证**（区别于"未运行只能静态分析"的情况）。

### 1.2 进程参数里泄露的功能开关

主 renderer 的启动参数带 `--desktop-features={...}`【实测，来自 `pgrep` 输出】。其中与本项目直接相关的：

```json
"codeSessionKeepAwake":  "supported",
"localSessionsWithoutGit":"supported",
"ccdPlugins":            "supported",
"desktopTopBar":         "supported",
"computerUse":           "supported",
"chillingSlothSshShell": "supported",
"sessionFolderFileAccess":"supported",
"sessionMentions":       "supported",
"coworkThinkingInSend":  "supported",
"nativeQuickEntry":      "supported",
"quickEntryGlobalShortcut": "supported"
```

`codeSessionKeepAwake` / `localSessionsWithoutGit` 是 **Code 会话存在**的直接运行时证据。

### 1.3 asar 解包

```
$ npx --yes @electron/asar extract /Applications/Claude.app/Contents/Resources/app.asar \
    /tmp/claude-desktop-research/asar
$ du -sh /tmp/claude-desktop-research/asar
119M
```

【实测】解包成功，目录结构（`package.json` 摘要）：

```json
{
  "name": "@ant/desktop",
  "productName": "Claude",
  "version": "1.52386.6",
  "main": ".vite/build/index.pre.js",
  "dependencies": {
    "@ant/claude-for-chrome-mcp": "*",
    "@ant/claude-native": "*",
    "@ant/claude-swift": "*",
    "@ant/computer-use-mcp": "*",
    "ws": "^8.18.0"
  },
  "optionalDependencies": { "node-pty": "1.2.0-beta.14" },
  "devDependencies": {
    "@anthropic-ai/claude-agent-sdk": "0.3.270",
    "@anthropic-ai/claude-agent-sdk-future": "npm:@anthropic-ai/claude-agent-sdk@0.3.267-dev...",
    "@ant/cds": "workspace:*",
    "@ant/claude-ssh": "*",
    "@ant/cowork-win32-service": "*",
    "node-pty": "1.2.0-beta.14"
  }
}
```

【静态】按 `package.json` 的字面依赖：桌面 App 直接依赖 `@anthropic-ai/claude-agent-sdk` 与 `node-pty`。这是"桌面 App 内嵌 Claude Code 能力"的**依赖层证据**。

---

## 2. Q1：桌面 App 有没有 Claude Code 能力？

**结论：有。桌面 App 内置了完整的 Claude Code（Code session）产品面，一个本地的 React UI，通过内嵌 Agent SDK 驱动。**

### 2.1 三条独立证据链

**证据 A：`claude://` 深链里有专门的动作型 Code 路由**【静态】

来自 `.vite/build/index.chunk-xyx_RsJ_.js`（桌面主进程 bundle）：

```js
// 系统级入口（Dock 菜单 / Spotlight / Linux launcher action）
{ id:"NewCode",      name:"New Claude Code Session",
  url:"claude://code/new?source=desktop_action" },
{ id:"ContinueLast", name:"Continue Last Claude Code Session",
  url:"claude://code/continue?session=last&source=desktop_action" },
{ id:"NeedsInput",   name:"Sessions Waiting for You",
  url:"claude://code/needs-input?source=desktop_action" },
{ id:"NewChat",      name:"New Chat",
  url:"claude://claude.ai/new?surface=chat&source=desktop_action" }
```

**证据 B：Deep link handler 里有 `importCliSession`**【静态】

```js
case rl.Resume:{
  let e = i.searchParams.get("session");
  return e && rF.test(e)
    ? (N.info(`Resume deep link: importing CLI session ${e}`),
       MC().then(t => t.importCliSession(e), ...)
       ...)
    : (N.warn("Resume deep link: missing or invalid session", {sessionId:e}), !1)
}
```

配套的用户可见错误文案（同一 bundle）：

- `"Couldn't open that session from Claude Code."`
- `"Couldn't open that session. Its transcript may have been removed."`
- 埋点：`desktop_code_deeplink_resume_failed`、`desktop_code_deeplink_session_received`

即桌面 App 能**直接导入 CLI 会话的记录并继续**。

**证据 C：本地打包的 Code UI**【静态 + 实测文件存在】

```
/Applications/Claude.app/Contents/Resources/ion-dist/     # 172 MB, 3243 个文件
```

【实测】在其中检索到 Claude Code 专有标识：

```
$ grep -rl 'acceptEdits'        ion-dist | wc -l   ->  14
$ grep -rl 'bypassPermissions'  ion-dist | wc -l   ->  22
$ grep -rl 'fastMode'           ion-dist | wc -l   ->  13
$ grep -rl 'modelPicker'        ion-dist | wc -l   ->   4
$ grep -rl 'Claude Code'        ion-dist | wc -l   -> 138
```

`acceptEdits` / `bypassPermissions` 是 Claude Code 的 permission mode 名称，`fastMode` / `modelPicker` 是 Code 的 composer 控件 —— 这些不可能出现在普通聊天 UI 里。

**关键推论**：Code UI 是**本地打包**的（`ion-dist`），不是从 `claude.ai` 远程加载的。【静态，但强】
- `.vite/renderer/main_window/index.html` 的注释写的是 `<!-- this is the html for app title bar and error UI. everything else gets loaded from claude.ai -->` —— 那句话只对 **chat/cowork 主窗口**成立。
- 但 Code 的 keybinding 表（见 §5）物理存在于本地 `ion-dist`，说明 Code 面板由本地 bundle 渲染。
- 【未验证】Code 面板具体由哪个 BrowserWindow 加载 `ion-dist` 的哪个入口（未能在运行时抓到 URL）。

### 2.2 `claude-cli://` 深链是给谁用的

**结论：给 `claude` CLI 自己用的，与桌面 App 无关。**

【实测】`Claude Code URL Handler.app` 的内容：

```
$ find "~/Applications/Claude Code URL Handler.app" -type f
.../Contents/Info.plist          # 仅此一个真实文件
$ ls -la ".../Contents/MacOS/"
lrwxr-xr-x  claude -> ~/.local/bin/claude
$ readlink -f ".../Contents/MacOS/claude"
~/.local/share/claude/versions/2.1.272
```

`Info.plist`：

```xml
CFBundleExecutable   = claude
CFBundleIdentifier   = com.anthropic.claude-code-url-handler
CFBundleURLName      = Claude Code Deep Link
CFBundleURLSchemes   = [ claude-cli ]
LSBackgroundOnly     = true
CFBundleVersion      = 1.0
```

**这个 bundle 没有自己的代码**：可执行文件是一个指向 `claude` CLI 二进制的 symlink，`LSBackgroundOnly=true` 让它不进 Dock。

【静态】CLI bundle 内部自证了这条路径：

```js
if (process.env.__CFBundleIdentifier === "com.anthropic.claude-code-url-handler") { ... }
...
export { D as handleDeepLinkUri, ie as handleUrlSchemeLaunch };
```
（`~/.local/share/claude/versions/2.1.272`，偏移 ~182188615）

CLI 还会**自我注册**这个 scheme：

```js
t("Auto-registered claude-cli:// deep link protocol handler")
...
deepLink: { buildGate: () => !0,
  shape: () => ({ disableDeepLinkRegistration: G(["disable"]).optional()
    .describe("Prevent claude-cli:// protocol handler registration with the OS") }) }
```

**判定**：`claude-cli://` 是 **Claude Code CLI 的深链 scheme**，由 CLI 自己注册、自己处理，用于把 URL 送进 CLI（`handleUrlSchemeLaunch`）。它**不是**控制桌面 App 的通道，`com.anthropic.claude-code-url-handler` 与 `com.anthropic.claudefordesktop` 是两个不同的 bundle。

> 顺带纠正一个容易踩的坑：`~/Library/Application Support/Claude/claude-code/<version>/claude.app`（bundle id `com.anthropic.claude-code`）是 CLI 的自更新副本，也不属于桌面 App。【实测，来自 `lsregister -dump`】

---

## 3. Q2：`claude://` 支持哪些深链路由

### 3.1 scheme 与 route 白名单

【静态】`.vite/build/index.chunk-xyx_RsJ_.js` 中的字面定义：

```js
var Gje="claude:", Kje="claude-dev:", qje="claude-nest:",
    Jje="claude-nest-dev:", Yje="claude-nest-prod:";
var Xje=[Gje,Kje,qje,Jje,Yje];
function tl(e){ return URL.canParse(e) && Xje.includes(new URL(e).protocol) }

// host 维度
var nl = function(e){ return
  e.Hotkey="hotkey", e.Login="login", e.ClaudeAI="claude.ai",
  e.Preview="preview", e.Cowork="cowork", e.Code="code",
  e.DebugHandoff="debug-handoff", e }({});

// pathname 维度
var rl = function(e){ return
  e.MagicLink="magic-link",      e.New="new",
  e.SSOCallback="sso-callback",  e.McpAuthCallback="mcp-auth-callback",
  e.OpenConversation="chat",     e.OpenProject="project",
  e.Settings="settings",         e.AdminSettings="admin-settings",
  e.Customize="customize",       e.Directory="directory",
  e.Create="create",             e.Tasks="tasks",
  e.Task="task",                 e.Space="space",
  e.ClaudeCodeDesktop="claude-code-desktop",
  e.Code="code",                 e.Epitaxy="epitaxy",
  e.Design="design",             e.Resume="resume",
  e.Cowork="cowork",             e.LocalSessions="local_sessions", e }({});
```

主 dispatch 是 `switch(i.host)`，每个 host 下再 `switch(i.pathname)`。允许的 scheme 只有 5 个（`claude-dev:` / `claude-nest*:` 是 dev/nest 构建用的，正式版只认 `claude:`）。

### 3.2 实际路由表

【静态】从 `switch` 分支逐条提取。**"能否触发 UI 动作"是我按分支实现打的判断**：

| URL 形态 | 分支行为 | 能否触发 UI 动作 |
|---|---|---|
| `claude://claude.ai/new?surface=chat` | 打开新建 chat；带 `surface=cowork` 则开 cowork | 是（导航） |
| `claude://claude.ai/chat/<uuid>` | 打开会话；uuid 非法则回退 `/recents` | 是（导航） |
| `claude://claude.ai/project/<uuid>` | 打开 project；非法则回退 `/projects` | 是（导航） |
| `claude://claude.ai/mcp-auth-callback/<...>` | 转交渲染进程 `dispatchHandleDeepLink` | 是（OAuth 流程） |
| `claude://claude.ai/<tasks\|task\|space\|settings\|admin-settings\|create\|directory\|customize\|epitaxy\|design>` | 归一化后导航 | 是（导航） |
| `claude://code/new` | **新建 Code 会话**；支持 `q`/`prompt`、`folder`、`file`、`src=external` | **是（命令）** |
| `claude://code/continue?session=last` | **打开最近 Code 会话**；`session` 可为 `last` 或 `local_<id>` | **是（命令）** |
| `claude://code/needs-input` | **跳到等权限答复最久的会话** | **是（命令）** |
| `claude://code/<cse_…\|session_…>` | 按 session id 打开 Code 会话 | 是（导航） |
| `claude://resume?session=<uuid>` | **导入 CLI 会话记录并继续** | **是（命令）** |
| `claude://cowork/new?q=&folder=&file=` | 新建 cowork 任务 | 是（命令） |
| `claude://cowork/shared-artifact?uuid=<uuid>` | 打开共享 artifact | 是（导航） |
| `claude://login/google-auth` / `sso-callback` / `magic-link` | 登录回调 | 是（仅登录） |
| `claude://hotkey` | 直接 `return !0`（空操作） | 否 |
| `claude://preview` / `claude://debug-handoff` | 仅 nest 构建可用，正式版 warn 并丢弃 | 否 |

**session id 校验规则**【静态，同 bundle】：

```js
var rF  = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/i; // 严格 UUID
var Vcn = /^local_[A-Za-z0-9-]{1,64}$/;      // code/continue 的 local session
var Hcn = /^(cse|session)_[A-Za-z0-9_-]+$/;  // code/<id> 的会话 id
```

### 3.3 运行时验证

【实测】为了确认深链确实送达桌面 App 且不产生副作用，使用**非法 UUID**（命中 else 分支，只写日志、不改 UI 状态）：

```
$ open "claude://resume?session=not-a-uuid"
$ echo $?
0

$ tail ~/Library/Logs/Claude/main.log
2026-09-15 22:52:29 [warn] Resume deep link: missing or invalid session { sessionId: 'not-a-uuid' }
```

**这条是本次调研中唯一被运行时验证的编程入口**，确认了：

1. `claude://` 在 OS 层确实绑定到 Claude.app；
2. `open <claude-url>` 是可行的外部投递方式；
3. `Resume` 路由与其 `session` 校验逻辑真实存在并生效；
4. 用非法参数可以"零副作用"地探测 handler 存活。

【未验证】`claude://code/new`、`claude://code/continue`、`claude://code/needs-input` 这三条**动作型**路由**没有实际触发**——它们会真的新建/切换用户的会话，属于破坏性副作用，本次主动放弃。它们的正确性目前是【静态】级别。

### 3.4 一个安全阀

【静态】托管配置项 `disableDeepLinkRegistration`（title `"Disable claude:// deep-link handling"`）可整体关闭深链。若被企业策略置位，上面所有深链都会失效：

```js
if (U().authentication.disableDeepLinks) {
  ... N.info("claudeURLHandler: dropping deep link (disableDeepLinkRegistration)"), !1
}
```
**实现时必须探测这个开关**。

---

## 4. Q3：桌面 App 的菜单与快捷键

### 4.1 原生菜单栏（实测枚举）

【实测】Accessibility 权限**已授予**，直接读到了运行中 App 的真实菜单树：

```
$ osascript -e 'tell application "System Events" to get name of every menu bar item of menu bar 1 of process "Claude"'
Apple, Claude, File, Edit, View, Go, Developer, Window, Help
```

完整结果已存 `/tmp/claude-desktop-research/claude-menus.txt`（141 行）。**与本项目相关的加速键**（`key` = `AXMenuItemCmdChar`，`mods` = `AXMenuItemCmdModifiers` 原始位掩码；`mods=0` 表示 ⌘+key）：

| 菜单项 | key | mods | 解读 | 对应语义动作 |
|---|---|---|---|---|
| **View > Command Palette…** | `K` | 0 | ⌘K | （通用入口，可当兜底） |
| **View > Show Changes** | `D` | 1 | ⌘⇧D | **inspectChanges** |
| **View > Show Terminal** | `J` | 0 | ⌘J | （终端面板） |
| **View > Show Files** | `F` | 1 | ⌘⇧F | （文件面板） |
| **View > Show Browser** | `B` | 1 | ⌘⇧B | （浏览器面板） |
| **View > Show Side Chat** | `;` | 0 | ⌘; | （旁路对话） |
| **View > Close Pane** | `\` | 0 | ⌘\ | （关面板） |
| View > Hide Sidebar | `B` | 0 | ⌘B | （侧栏） |
| View > Reload | `R` | 0 | ⌘R | — |
| View > Enter Full Screen | `F` | 4 | ⌃⌘F | — |
| **Go > Back** | `[` | 0 | ⌘[ | **navigateLeft**（历史后退） |
| **Go > Forward** | `]` | 0 | ⌘] | **navigateRight**（历史前进） |
| **Go > Chat and Cowork** | — | — | 无快捷键 | 切到 chat 面 |
| **Go > Code** | — | — | 无快捷键 | **切到 Code 面** |
| Go > Previous Chat | `[` | 1 | ⌘⇧[ | navigateUp/Left |
| Go > Next Chat | `]` | 1 | ⌘⇧] | navigateDown/Right |
| Go > Search… | `K` | 1 | ⌘⇧K | 全局搜索 |
| **File > New Chat** | `N` | 0 | ⌘N | — |
| **Help > Keyboard Shortcuts** | `/` | 0 | ⌘/ | **弹出应用内快捷键面板** |
| Developer > Show Dev Tools | `I` | 2 | ⌥⌘I | — |
| Window > Minimize | `M` | 0 | ⌘M | — |
| Claude > Settings… | `,` | 0 | ⌘, | — |

**重要**：这些是 **AppKit 原生菜单**，因此可以用 `System Events` 直接 **click**，不必合成键盘事件（见 §6.2）。

**View 菜单里 Code 专属项是上下文相关的**【实测】：

```
View > Show Terminal        | enabled=false
View > Show Changes         | enabled=false
View > Show Browser         | enabled=false
View > Show Files           | enabled=false
View > Show Side Chat       | enabled=false
View > Close Pane           | enabled=false
View > Command Palette…     | enabled=true
View > Split View           | enabled=true
Go  > Code                  | enabled=true
```

即：**当前没有打开的 Code 会话时，这些面板项是 disabled 的**。控制器实现时不能假设点击一定生效，需要先读 `enabled`。

子菜单【实测】：

```
View > Split View:  New Session on the Right, New Session Below, —,
                    Focus Next Split View, Focus Previous Split View, —, Close Split View
Edit > Find:        Find…, Find Next, Find Previous, —, Find in Files
Help > Troubleshooting: Show Logs in Finder, Show Cowork Session Data in Finder,
                    Copy Installation ID, Generate Diagnostic Report, Record Net Log (30s), —,
                    Disable Hardware Acceleration, —, Enable Cowork VM Debug Logging,
                    Enable Cowork SDK Debugging, Free Up Cowork Disk Space…,
                    Delete Cowork VM Bundle and Restart…, Delete Cowork VM Sessions and Restart…, —,
                    Import Claude Code CLI Sessions…, Clear Cache and Restart, Reset App Data…
```

`Import Claude Code CLI Sessions…` 是**再次确认桌面 App 与 CLI 会话互通**的菜单级证据。

### 4.2 应用内快捷键（Code/session 面板）

原生菜单**只覆盖了一小部分** Code 动作。真正的主力在本地 bundle `ion-dist` 里。

【静态】`ion-dist/assets/v1/shared-19-B-vs9Ua0.js`，偏移 ~260466，是一张**扁平 keybinding 表 `jz`**：

```js
var jz=[
 {command:"togglePreview",        key:"cmd+shift+b", code:"KeyB", when:"isClaudeApp", gate:"externalPreviewAvailable"},
 {command:"togglePreview",        key:"cmd+shift+p", code:"KeyP", when:"isClaudeApp"},
 {command:"togglePreview",        key:"cmd+alt+p",   code:"KeyP", when:"!isClaudeApp"},
 {command:"toggleDiff",           key:"cmd+shift+d", code:"KeyD", when:"isClaudeApp"},
 {command:"toggleDiff",           key:"ctrl+shift+d",code:"KeyD", when:"!isClaudeApp"},
 {command:"toggleTerminal",       key:"cmd+j",       code:"KeyJ", when:"isClaudeApp", mac:!0},
 {command:"toggleTerminal",       key:"ctrl+`",      code:"Backquote"},
 {command:"toggleBrowser",        key:"cmd+shift+f", code:"KeyF"},
 {command:"closePane",            key:"cmd+\\",      code:"Backslash"},
 {command:"toggleExpandPane",     key:"cmd+shift+\\",code:"Backslash"},
 {command:"toggleSideChat",       key:"cmd+;",       code:"Semicolon"},
 {command:"cycleTranscriptMode",  key:"ctrl+o",      code:"KeyO"},
 {command:"backgroundTasks",      key:"ctrl+b",      code:"KeyB", matchBy:"key"},
 {command:"openModeMenu",         key:"cmd+shift+m", code:"KeyM", when:"isClaudeApp"},
 {command:"openModeMenu",         key:"cmd+alt+m",   code:"KeyM"},
 {command:"openModelMenu",        key:"cmd+shift+i", code:"KeyI"},
 {command:"openEffortMenu",       key:"cmd+shift+e", code:"KeyE"},
 {command:"toggleFastMode",       key:"cmd+alt+f",   code:"KeyF"},
 {command:"toggleSelectionMode",  key:"cmd+shift+s", code:"KeyS"},
 {command:"toggleSketchMode",     key:"cmd+shift+x", code:"KeyX", when:"isClaudeApp"},
 {command:"newPreviewTab",        key:"cmd+t",       code:"KeyT", when:"isClaudeApp"},
 {command:"jumpPrevPrompt",       key:"cmd+alt+up",  code:"ArrowUp",   mac:!0, gate:"promptJump"},
 {command:"jumpPrevPrompt",       key:"alt+up",      code:"ArrowUp",   mac:!1, gate:"promptJump"},
 {command:"jumpNextPrompt",       key:"cmd+alt+down",code:"ArrowDown", mac:!0, gate:"promptJump"},
 {command:"jumpNextPrompt",       key:"alt+down",    code:"ArrowDown", mac:!1, gate:"promptJump"},
 {command:"sketchDeleteSelection",key:"backspace",   code:"Backspace"},
 {command:"sketchDeleteSelection",key:"delete",      code:"Delete"},
 {command:"sketchDeselect",       key:"esc",         code:"Escape"},
 {command:"toggleDiffFileList",   key:"cmd+shift+y", code:"KeyY", matchBy:"char", when:"isClaudeApp"},
 {command:"toggleDiffFileList",   key:"ctrl+shift+y",code:"KeyY", matchBy:"char", when:"!isClaudeApp"},
 {command:"reopenClosed",         key:"cmd+shift+t", code:"KeyT", matchBy:"char", when:"isClaudeApp"},
 {command:"goToDiffFile",         key:"cmd+p",       code:"KeyP", matchBy:"char"},
 {command:"attachTerminalOutput", key:"cmd+shift+l", code:"KeyL", matchBy:"char"},
 {command:"sketchUndo",           key:"cmd+z",       code:"KeyZ", matchBy:"char"},
 {command:"sketchRedo",           key:"cmd+shift+z", code:"KeyZ", matchBy:"char"},
 {command:"sketchRedo",           key:"ctrl+y",      code:"KeyY", matchBy:"char", mac:!1}
];
```

匹配逻辑【静态】：`Iz()` → 按 `matchBy`（默认按 `code`，`"char"` 按字符，`"key"` 按 key）匹配，再校验 `when`（`isClaudeApp`）、`mac`、`gate`、修饰键。**注意 `matchBy` 的差异会导致同键位在不同控件上行为不同**，实现时要照抄这张表的语义。

### 4.3 composer（输入框）与全局动作

【静态】同文件偏移 ~262000–279000 是 `Keyboard Shortcuts` 面板的 JSX，即**面向用户的官方快捷键列表**，可直接采信为文档。

**该面板有两套并列的列表**，必须区分——这是实现时最容易出错的地方：

```
SECTION 位置      面板
General     266851  ┐
In chats    267872  │ 第一套：chat / cowork 语境
In tasks    269208  │
In projects 269680  │
iOS Simulator 270007┘
General     271448  ┐
Panes       274153  │ 第二套：Code session 语境
Composer    275989  ┘
```

**第二套（Code session）** —— 即本项目关心的语境：

| 快捷键 | 动作 | 分组 |
|---|---|---|
| `cmd+n`（native）/ `cmd+shift+o`（web） | New session | General |
| `cmd+w` | Close session | General |
| `b`（`shortcut:b` 变量） | Reopen closed session | General |
| `cmd+shift+]` / `ctrl+tab` | Next session | General |
| `cmd+shift+[` / `ctrl+shift+tab` | Previous session | General |
| `cmd+1…9` | Jump to session | General |
| `cmd+alt+left` / `cmd+alt+right` | Previous / Next sidebar tab | General（`eB`） |
| `cmd+alt+a` / `cmd+shift+backspace` | Archive session | General |
| `alt+click` | Open session in split view | General |
| `cmd+alt+p` | Pin / unpin session | General |
| `cmd+alt+r` | Rename session | General |
| `cmd+alt+u` | Mark session as read/unread | General |
| `cmd+l` / `cmd+alt+l` | Copy session / project link | General |
| `cmd+alt+g` | Open session PR | General |
| `cmd+alt+o` | Fork session | General |
| `cmd+ctrl+w` | Close split view | General |
| `cmd+alt+up` / `cmd+alt+down` | Jump to previous / next prompt（经 `zz(...,{promptJump})`） | General |
| **`esc`** | **Stop Claude's response** | General |
| `cmd+shift+d` | **Toggle changes** | Panes |
| `cmd+shift+f` | Toggle Files | Panes |
| `cmd+\` | Close pane | Panes |
| `cmd+;` | Toggle side chat | Panes |
| **`cmd+shift+m`** | **Open mode menu**（权限模式） | Composer |
| **`cmd+shift+i`** | **Open model menu** | Composer |
| `cmd+shift+e` | Open effort selector | Composer |
| **`cmd+alt+f`** | **Toggle fast mode**（`zz("toggleFastMode",c)`） | Composer |
| `1…9` | Select menu item | Composer |
| `cmd+alt+enter` | Send in a forked session (local sessions) | Composer |

**第一套（chat/cowork）** 里才有 `enter` → `Send message`（偏移 267988，位于 `In chats` 分组）：

| 快捷键 | 动作 | 分组 |
|---|---|---|
| **`enter`** | **Send message** | In chats |
| `shift+enter` | New line in message | In chats |
| `esc` | Stop Claude's response（偏移 274080 之外的另一处：268484） | In chats |
| `esc esc` | Edit your last message | In chats |
| `cmd+alt+enter` | Send in a forked session | In chats |
| `shortcutId:"extended_thinking"` | Toggle thinking | In chats |
| `shortcutId:"model_selector"` | Open model menu | In chats |
| `shortcutId:"file_upload"` | Add files or photos | In chats |
| `cmd+;` | Toggle side chat | In chats |
| `ctrl+o` | Cycle transcript mode | — |
| `ctrl+b` | Background tasks | — |

> **⚠️ 关键差异**：**Code session 的 `Composer` 分组里没有 `enter` / `shift+enter` 条目**（我逐条提取过，只有 mode/model/effort/fastMode/选择/附件六项）。`enter` 提交在 Code 面板里应由 textarea 组件自身处理，而非 `jz` keybinding 表。因此 §7 中 `submit → enter` 在 **chat 语境是【静态】确认**，在 **Code session 语境是【推断，未验证】**。

### 4.4 命令面板动作注册表

【静态】`ion-dist/assets/v1/shared-7-BTho74mC.js`，偏移 ~273243，注册表 `XP`（被 `shortcutId` 引用）。与本项目相关的条目：

```js
command_palette:   ⌘K / ⌃K
search_palette:    ⌘⇧K / ⌃⇧K
quick_chat:        ⌘⌃K / ⌃⌥K
claude_code:       { group:"navigation", icon:"Code", href:"/code" }
new_conversation:  ⌘⇧O (app:"web")
settings:          ⌘⇧,      // 注意：原生菜单里 Settings 是 ⌘,
incognito:         ⌘⇧I
file_upload:       ⌘U / ⌃U
extended_thinking: ⌘⇧E / ⌃⇧E
model_selector:    ⌘⇧. / ⌃⇧.
toggle_dictation:  ⌘D (app:"desktop")
rename_code_session:  ⌘⌥R
pin_code_session:     ⌘⌥P
```

**⚠️ 冲突提示**：`extended_thinking` 在注册表里是 `⌘⇧E`，`openEffortMenu` 在 `jz` 里也是 `⌘⇧E`。同一个键在不同上下文含义不同，实现时不要跨上下文复用键位映射。

---

## 5. Q4：有没有别的可编程控制面

### 5.1 监听端口 / socket：没有

【实测】

```
$ lsof -nP -iTCP -sTCP:LISTEN | grep -i claude
(空)
```

Claude App 各进程**没有任何 TCP 监听**。唯一的 unix socket（`fd 92u`）对端 node `0x1d06f71fcbaef616` 同时被 `loginwindow` / `usernoted` / `sharingd` 等大量系统进程持有 —— 那是 **launchd bootstrap socket**，不是控制面。

【静态】asar 内检索 `WebSocketServer`、`net.Server`、`named pipe` 均无命中（`createServer` 的命中都在 MCP client、file-index-worker 等**出站/内部**用途）。

**结论：Claude 桌面 App 不暴露本地 HTTP / WebSocket / unix socket 控制面。**

### 5.2 Electron IPC：存在，但外部不可达

【静态】`index.chunk-xyx_RsJ_.js` 用代码生成器 `Ha(eh,"<Service>",th,{methods,events})` 注册了 16 个服务：

```
AppConfig, AppFeatures, AppPreferences, CcdCli, ClaudeAiImport,
Custom3pHelperRun, Custom3pSetup, Custom3pUsage, DesktopInfo, Extensions,
FilePickers, GlobalShortcut, MCP, Startup, SupportBundle, WakeScheduler
```

方法级签名示例：

```js
Ha(eh,"CcdCli",th,{methods:[["getCcdCliStatus",[],e4e],
                            ["installCcdCli",[],r4e],
                            ["uninstallCcdCli",[],r4e]]}),
Ha(eh,"GlobalShortcut",th,{methods:[["setGlobalShortcut",[["globalShortcut",P]]],
                                    ["getGlobalShortcut",[],P]]}),
Ha(eh,"Startup",th,{methods:[["isMenuBarEnabled",[],F],
                             ["setMenuBarEnabled",[["enabled",F]]]]}),
```

**这是一套 renderer↔main 的内部 IPC**，通过 Electron `ipcMain.handle` 暴露。它**没有外部传输层**（无 socket / 无 stdio 桥），所以第三方进程无法调用。

【未验证】是否存在"通过 DevTools 或 `--remote-debugging-port` 注入渲染进程再调 IPC"的路径。本次未测试（需要重启 App 加参数，违反"不擅自改动运行环境"）。

**注意**：这 16 个服务里**没有任何 Code 会话动作服务**（没有 `Session` / `Chat` / `Composer`）。它们全是配置、MCP、扩展、启动项之类的 App 级设置。所以即使能打通 IPC，也拿不到 `chat:submit` 这类动作。

### 5.3 `ccd` CLI：存在设计，但这个版本没有

【静态】有完整的 installer 逻辑：

```js
var Q7="/usr/local/bin/ccd", Pxi="/usr/local/bin";
function Hxi(){ return !o.app.isPackaged||!1 }
function Uxi(){ return o.app.isPackaged
  ? n.default.join(process.resourcesPath,"bin","ccd")
  : n.default.join(o.app.getAppPath(),"bin","ccd") }
function zxi(e){ return `sudo mkdir -p ${Pxi} && sudo ln -sfn ${e} ${Q7}` }
async function Yxi(){ // getCcdCliStatus
  let e={state:Lm.Unavailable, ...};
  if(!Hxi()) return e;
  let t=Uxi(); if(!await Wxi(t)) return e;   // 文件不存在 -> Unavailable
  ...
}
```

【实测】**这个构建里没有该二进制**：

```
$ ls -la /Applications/Claude.app/Contents/Resources/bin/
ls: No such file or directory
$ ls -la /usr/local/bin/ccd
ls: No such file or directory
$ which ccd
(空)
```

且 `getCcdCliStatus` 的守卫 `if(!Hxi()) return Unavailable`，而 `Hxi()` 在 packaged 构建下为 `false` —— 逻辑上也是关闭的。

**结论：`ccd` 在当前版本不可用，不能作为控制面。**

### 5.4 `claude-desktop` 命令：不存在

【静态】i18n 里有文案 `"Open Claude from your applications menu, or run <cmd>claude-desktop</cmd>."`【实测，`ion-dist/i18n/en-US.json`】。但：

```
$ which claude-desktop          -> (空)
$ ls /usr/local/bin/claude-desktop  -> No such file
$ strings -a /Applications/Claude.app/Contents/MacOS/Claude | grep claude-desktop  -> (空)
```

【未验证】未在该版本安装。

### 5.5 `claude` CLI → 桌面 App：**存在对等物，但形态不同**

这是与 Codex 对比时最关键的一节。

【静态】CLI bundle（`versions/2.1.272`，偏移 ~181806899）里有完整的 desktop handoff 实现：

```js
function sk(w){                                   // 构造深链
  let P = cd() ? "claude-dev" : "claude";
  let I = new URL(`${P}://resume`);
  I.searchParams.set("session", w);
  return I.toString();
}
async function md(){                              // 检测桌面 App 是否安装
  let w="darwin";
  if(w==="darwin") return pc("/Applications/Claude.app");
  else if(w==="linux"){ ... xdg-mime query default x-scheme-handler/claude ... }
  else if(w==="win32"){ ... reg query HKEY_CLASSES_ROOT\claude ... }
}
async function ik(){                              // 读桌面 App 版本
  let {code:P,stdout:I}=await $e("defaults",["read",
     "/Applications/Claude.app/Contents/Info.plist","CFBundleShortVersionString"]);
  ...
}
async function vhn(){                             // 版本够不够
  if(!await md()) return {status:"not-installed"};
  ..., return {status:"version-too-old",version:P};
  return {status:"ready",version:P};
}
async function ak(w){                             // 真正打开
  t(`Opening deep link: ${w}`);
  { if(cd()){ let {code:U}=await $e("osascript",["-e",`tell application "Electron" to open location "${w}"`]); return U===0 }
    let {code:I}=await $e("open",[w]); return I===0 }
}
async function qQn(){                             // 对外入口
  let w=X(), P=await vhn();
  if(P.status==="not-installed") return {success:!1, error:"Claude Desktop is not installed. Install it from https://claude.ai/download"};
  if(P.status==="version-too-old") return {success:!1, error:`Claude Desktop ${P.version} is too old ...`};
  let I=sk(w);
  if(!await ak(I)) return {success:!1, error:"Failed to open Claude Desktop. Please try opening it manually.", deepLinkUrl:I};
  return {success:!0, deepLinkUrl:I};
}
```

调用点是 CLI 的 **`/desktop` 斜杠命令**【静态，偏移 ~200034532】：

```js
let c = await O4(x(), "desktop_handoff", {}, C);   // 埋点
t({state:"flushing"}); await vu(); t({state:"opening"});
let i = await qQn();
...
u("Session transferred to Claude Desktop", {display:"system"})
```

配套文案：`"Re-run /desktop once you've installed the app."`、`"The desktop app is required for /desktop."`、`"Session transferred to Claude Desktop"`。

**对照表**：

| | Codex | Claude |
|---|---|---|
| 把当前会话交给桌面 App | `codex queue --thread <id>` | **`claude` 内 `/desktop`**（非独立子命令） |
| 底层机制 | 未调研（由另一子代理负责） | 写盘 flush → `open claude://resume?session=<id>` |
| 反向（桌面→CLI） | — | 桌面 `Help > Troubleshooting > Import Claude Code CLI Sessions…` |
| 外部能否直接驱动桌面 App 会话内容 | — | **不能**，只能"打开/继续/新建" |

**结论**：Claude 侧的 CLI→桌面通道是 **"会话交接（handoff）"**，不是 **"远程命令执行"**。它可以让你**打开**一个会话，但**不能**替你在会话里 `submit` / 切权限模式 / 切模型。

### 5.6 `~/.claude/daemon/` 与 `~/.claude/ide/`

【实测】

```
$ ls -la ~/.claude/daemon/
-rw-------  32B  control.key
drwx------      dispatch/          (空目录)
$ cat ~/.claude/daemon-auth-status.json
{"status":"auth_required","since":1786515183800}

$ cat ~/.claude/ide/49449.lock
{"pid":1621,"workspaceFolders":["~/Documents/notes-vault"],
 "ideName":"Obsidian","transport":"ws"}
```

- `~/.claude/daemon/` = **Claude Code CLI 的 remote-control daemon**（`control.key` 是认证密钥，`dispatch/` 是派发队列，当前为空，状态 `auth_required`）。属于 CLI 的远程控制通道，与桌面 App 无关。
- `~/.claude/ide/<port>.lock` = **CLI ↔ IDE 的 WebSocket 桥**（这里是 Obsidian，pid 1621，`transport:"ws"`）。同样是 CLI 侧，不是桌面 App。

【未验证】daemon 的 wire protocol 与 `control.key` 用法本次未调研（超出"Claude 桌面 App"范围，且可能触发认证流程）。

### 5.7 macOS Accessibility：可用

【实测】权限已授予：

```
$ osascript -e 'tell application "System Events" to get name of every process whose name contains "Claude"'
Claude, Claude Helper          # exit 0
```

AX 树里**渲染进程的 web 内容也是暴露的**【实测】：

```
$ osascript -e 'tell application "System Events" to tell process "Claude" to return count of UI elements of window 1'
4
$ ... get value of attribute "AXRole" of every UI element of window 1
AXGroup, AXButton, AXButton, AXButton
$ ... entire contents of window 1
group Claude of window Claude ... UI element 收租标的的可行性与资金效率 - Claude ...
... splitter 1 ... button 1 ... button 2 ...
```

即可以深入到会话标题、splitter、按钮级别。**这意味着 `System Events` 的 AX 遍历是一条比"盲注按键"更稳的路径**（能先断言再动作）。

【未验证】未对 Code 面板做完整 AX 树遍历（需要先打开一个 Code 会话，属于副作用）。因此**Code 面板里各个按钮的 AX 标识当前未知**。

### 5.8 顺带发现：蓝牙相关

【实测】App 日志里有 `[buddy-ble]` 记录：

```
2026-09-15 22:51:32 [warn] [buddy-ble] scan timeout — saw 0 stick(s), none matched
2026-09-15 22:51:32 [info] [buddy-ble] pair: result=false
```

且 `--desktop-features` 中有 `"hardwareBuddyEnabled"`、菜单里有 `Developer > Open Hardware Buddy…`。这是 Anthropic 自己的蓝牙硬件伴侣功能，**可能会与本项目的蓝牙手柄扫描互相干扰**，实现时建议留意。

---

## 6. 控制面清单与投递方式

### 6.1 可用控制面总览

| 控制面 | 状态 | 能力边界 |
|---|---|---|
| `open claude://…` | ✅ **实测可用** | 导航 + 4 个命令型动作（新建/继续/待输入/导入 CLI 会话） |
| `System Events` 菜单点击 | ✅ **实测可枚举**（权限已给） | 可点所有原生菜单项，但 Code 专属项需会话在开 |
| `System Events` 键盘注入 | ✅ 权限已给（推断可用） | 可发任意快捷键，但需先聚焦目标控件 |
| AX 树遍历 | ✅ 实测可深入到 web 内容 | 可读标题/按钮，Code 面板标识未探 |
| Electron IPC（16 服务） | ❌ 外部不可达 | 无外部传输层 |
| 本地 HTTP/WS/socket | ❌ 不存在 | 无监听端口 |
| `ccd` CLI | ❌ 本版本无 | 二进制不存在 |
| `claude-desktop` 命令 | ❌ 不存在 | 未安装 |
| CLI `/desktop` | ⚠️ 单向 | 只做会话交接，不是远程控制 |

### 6.2 菜单点击 vs 按键注入

由于 Code 专属动作**同时**存在于原生菜单（View 菜单）和 keybinding 表里，推荐优先级：

1. **深链**（最稳，无焦点依赖）—— 仅限它能表达的 4 个动作。
2. **AX 菜单点击** —— 先读 `enabled`，再 `click`，不依赖窗口焦点和输入法状态：
   ```applescript
   tell application "System Events" to tell process "Claude"
     if enabled of menu item "Show Changes" of menu 1 of menu bar item "View" of menu bar 1 then
       click menu item "Show Changes" of menu 1 of menu bar item "View" of menu bar 1
     end if
   end tell
   ```
3. **键盘注入**（`keystroke … using {command down, shift down}`）—— Code 面板内部动作（`enter` / `esc` / `1…9`）只能走这条，因为菜单里没有。

**风险**：`⌘K`、`⌘⇧D` 等在 chat 与 code 两个面的语义不同；注入前必须先确认当前是哪个 surface（可用 `Go > Code` 的 AX 状态或窗口 title 辅助判断）。

---

## 7. 11 个语义动作映射建议

### 7.1 总表

| # | 语义动作 | 建议实现 | 状态 |
|---|---|---|---|
| 1 | `navigateUp` | 会话内提示级：`⌘⌥↑`（`jumpPrevPrompt`）。列表级：AX 选中 + `↑` | 【静态】键位 / 【未验证】实际行为 |
| 2 | `navigateDown` | 同上，`⌘⌥↓`（`jumpNextPrompt`） | 【静态】 |
| 3 | `navigateLeft` | `⌘⌥←`（Previous sidebar tab，session 面板 General 组）；历史后退 `⌘[`（原生菜单） | 【静态】+ 原生菜单【实测】 |
| 4 | `navigateRight` | `⌘⌥→`（Next sidebar tab）；历史前进 `⌘]` | 同上 |
| 5 | `submit` | 键盘注入 `enter`（composer 焦点下） | chat 语境【静态】；**Code session 语境【推断，未验证】**（见 §4.3 警告） |
| 6 | `cancelOrInterrupt` | 键盘注入 `esc`（= "Stop Claude's response"，**Code session General 组已确认**） | 【静态】 |
| 7 | `queueFollowUp` | **无专用接口**。流式期间 `enter` 可能自动排队；`⌘⌥enter` 是 "Send in a forked session"（语义不同，慎用） | 【未验证】 |
| 8 | `cyclePermissionMode` | **无"循环"动作**。有 `openModeMenu` = `⌘⇧M`（打开菜单），再用 `1…9` 选择 | 【静态】 |
| 9 | `toggleFastMode` | `⌘⌥F`（`toggleFastMode`，`jz` 表内唯一） | 【静态】 |
| 10 | `openModelPicker` | `⌘⇧I`（`openModelMenu`）；另一处 `model_selector` = `⌘⇧.` | 【静态】，两处来源一致指向"打开模型菜单" |
| 11 | `inspectChanges` | `⌘⇧D`（`toggleDiff`）+ 原生菜单 `View > Show Changes`（同一键位，**交叉印证**） | 【静态】键位 + 【实测】菜单项存在 |

### 7.2 分类总结

**A. 可走程序化"打开/切换"（深链，无需注入）—— 0 个完全对应，1 个部分对应**
- 没有任何一个语义动作有专属深链。
- 唯一沾边的是 `claude://code/continue?session=last` / `claude://code/needs-input`，属于**会话级跳转**，不是**会话内动作**。

**B. 可走原生菜单点击（AX，无焦点依赖）—— 2 个**
- `inspectChanges` → `View > Show Changes`（⌘⇧D）
- `navigateLeft` / `navigateRight` → `Go > Back` / `Go > Forward`（历史语义）
- ⚠️ 均需先确认 `enabled=true`（无 Code 会话时是 disabled，已实测）。

**C. 只能注入按键 —— 9 个**
`navigateUp/Down`（`⌘⌥↑/↓`）、`navigateLeft/Right`（`⌘⌥←/→`、`⌘⇧[/]`）、`submit`（`enter`）、`cancelOrInterrupt`（`esc`）、`cyclePermissionMode`（`⌘⇧M` 再 `1…9`）、`toggleFastMode`（`⌘⌥F`）、`openModelPicker`（`⌘⇧I`）

**D. 做不到 / 无对应 —— 2 个**
- `queueFollowUp`：桌面 UI 未暴露"显式入队"动作。CLI 侧有 `chat:queueSubmit`，但那是 TUI 的 action 命名空间（`app:`/`chat:`/`history:`/`editor:`），桌面 Code UI 用的是另一套（`jz` 表的 `command` 名 + `XP` 注册表 id），**两者不通用**。
- `cyclePermissionMode` 的"循环"语义：桌面只有"打开菜单 + 选择"，没有循环。需要额外观测当前模式才能实现"下一档"。

### 7.3 对实现的三条硬约束

1. **surface 感知是前置条件**。`⌘⇧D`、`⌘K`、`⌘⇧M` 在 chat / cowork / code 三个面语义不同。控制器必须先判定当前 surface（`Go > Code` 菜单项状态、窗口 title、或 AX 树特征），否则会误触。
2. **CLI 的 action 命名空间不能直接搬**。用户手上那份 `app:toggleTranscript` / `chat:cycleMode` / `chat:fastMode` / `chat:queueSubmit` / `chat:modelPicker` 列表来自 **Claude Code CLI（TUI）**，其 keybinding 走 `~/.claude/keybindings.json` 配置。桌面 App 的 Code 面板用的是 `ion-dist` 里那张 `jz` 表和 `XP` 注册表，**两套命名空间没有已知映射关系**【未验证是否存在映射】。若本项目要"一套语义动作同时驱动 CLI 和桌面 App"，需要自己维护一张对照表。
3. **深链有全局开关**。`disableDeepLinkRegistration`（托管配置）会把整条深链通道关掉。控制器启动时应探测。

---

## 8. 未验证清单（写代码前需要补测）

| 项 | 为什么没测 | 建议怎么测 |
|---|---|---|
| `claude://code/new` 等 3 条动作型深链的真实行为 | 会真的新建/切换用户会话，属破坏性副作用 | 在可牺牲的账号/环境里跑，观察 `main.log` 与 UI |
| Code 面板的 AX 元素标识 | 需要先打开 Code 会话 | 开一个 Code 会话后遍历 AX 树 |
| `queueFollowUp` 在桌面端的确切语义 | 未找到对应动作；可能是流式期间 `enter` 的隐式行为 | 在流式响应中发 `enter`，观察是否入队 |
| `esc` 在"运行中"vs"空闲"下的差异 | 需真实运行中的会话 | 分别在有/无流式响应时注入 |
| 渲染进程远程调试注入 IPC 的可行性 | 需重启 App 加 `--remote-debugging-port` | 隔离环境另起实例（不要动用户的运行实例） |
| `~/.claude/keybindings.json` 是否影响桌面 App | 该文件当前不存在 | 用 `CLAUDE_CONFIG_DIR` 指向临时目录建一份，对比 CLI 行为（桌面端大概率不受影响） |
| `ion-dist` Code 面板的实际加载 URL | 未能运行时抓取 | 开 DevTools 或看 `main.log` 的窗口创建记录 |

---

## 9. 复现本次调研的关键命令

```bash
# 解 asar（写到 /tmp，不污染用户目录）
npx --yes @electron/asar extract \
  /Applications/Claude.app/Contents/Resources/app.asar \
  /tmp/claude-desktop-research/asar

# 大文件里带上下文检索（不要用 grep -x 或带通配符的 grep -o，会回溯超时）
python3 /tmp/claude-desktop-research/bin/ctx.py <file> '<needle>' <before> <after> <maxhits>

# 原生菜单枚举（需 Accessibility 权限）
osascript -e 'tell application "System Events" to get name of every menu bar item of menu bar 1 of process "Claude"'

# 深链探测（用非法 session，零副作用）
open "claude://resume?session=not-a-uuid" && tail -5 ~/Library/Logs/Claude/main.log
```

**证据文件**（均在 `/tmp/claude-desktop-research/`，非项目目录）：

| 文件 | 内容 |
|---|---|
| `asar/` | app.asar 完整解包（119 MB） |
| `claude-menus.txt` | 原生菜单树 + AX 快捷键 + enabled 状态（141 行） |
| `urlhandler.txt` | 桌面端 `claude://` URL handler 源码段（`gSwitch` + 全部 case） |
| `ion-shortcuts.txt` | Code UI 快捷键面板 JSX（含 `jz` keybinding 表） |
| `ion-registry.txt` | 命令面板注册表 `XP`（`shared-7-BTho74mC.js` 片段） |
| `cli-deeplink.bin` | CLI bundle 中 `handleDeepLinkUri` 区域（偏移 191.7M–192.1M） |
| `cli-opendesktop.bin` | CLI bundle 中 desktop handoff 区域（偏移 71.3M–71.46M） |
| `bin/ctx.py` | 大文件带上下文检索工具 |
| `bin/menus.applescript` / `bin/enabled.applescript` | 菜单枚举脚本 |
| `bin/axtree.applescript` | AX 树遍历脚本（**有语法错误，未跑通**，仅作草稿保留） |
| `bin/ctx.py` | 大文件带上下文检索工具 |

---

## 10. 一句话给实现者

Claude 桌面 App 的 Code 能力是**真实的、本地的**，但它**没有留任何进程外 API**。你能做的只有两件事：用 `claude://` 深链做**会话级导航**（4 个动作），以及用 macOS Accessibility 做**会话内动作**（菜单点击或按键注入，9 个动作）。任何需要"读取会话状态再决定"的智能控制，都要先靠 AX 树把状态读出来——**这部分是可行的，但 Code 面板的具体 AX 标识尚未探明，是下一步的首要工作**。
