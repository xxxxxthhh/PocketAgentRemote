# Codex 桌面 App 控制面调研（macOS）

> 调研时间：2026-09-15 · 只读调研 + 隔离实验
> 被测对象：`/Applications/ChatGPT.app`（bundle id `com.openai.codex`，版本 `26.908.40834`），调研时**正在运行**（pid 16965）
> 产出目标：回答「IINE L1162 手柄 → Codex 桌面 App」这条链路上，**哪些语义动作有程序化控制面、哪些只能靠注入按键、哪些做不到**。
>
> **证据分级**：全文每条结论都标注来源 —— `【实测】`（跑了命令看到输出）、`【代码】`（从 app.asar / 二进制反解出的实现）、`【推断】`（由前两者推导，未直接验证）、`【未验证】`。
> 未做端到端验证的地方一律显式写出，**没有猜测**。

---

## 0. 结论摘要

**一句话**：Codex 桌面 App **没有任何对外可用的本地程序化控制面**。它既不跟 CLI 共用 app-server daemon，也不监听任何本地端口；唯一的本地 socket（`~/.codex/ipc/ipc.sock`）是一个**进程间广播/路由总线**，外部进程能连上并注册，但实测**没有任何 client 响应请求**。因此 11 个语义动作在桌面 App 上基本只能走**合成按键（CGEvent / osascript keystroke）**，外加少量菜单项与 deep link 能程序化触发。

| 问题 | 结论 | 证据 |
|---|---|---|
| 桌面 App 与 CLI 是否共用同一个 daemon？ | **否**。App 自己 spawn 一个 `codex app-server`（stdio 私有管道）；CLI 的「共享 daemon」是另一套机制，且本机**未安装** | 【实测】 |
| 两者共享什么？ | **`CODEX_HOME`（`~/.codex`）下的存储**：`state_5.sqlite` 的 `threads` 表、rollout JSONL、`config.toml` | 【实测】 |
| App 有没有本地监听端口？ | **无**（`lsof` 查不到任何 LISTEN） | 【实测】 |
| `~/.codex/ipc/ipc.sock` 能外部连吗？ | **能**，实测拿到 `clientId`；但发请求返回 `no-client-found` | 【实测】 |
| `codex://` deep link 有哪些路由？ | 完整路由表见 §4.6；**没有任何一条**对应 submit / interrupt / queue / 权限模式 / 模型选择 / diff / transcript | 【代码】 |
| 能不能用 AppleScript 操作菜单？ | **能**（System Events 权限已具备，实测枚举出完整菜单树） | 【实测】 |
| 桌面 App 能不能跑 TUI keymap？ | **不能**。App 内部是 Electron + React renderer，跑的是 `codex app-server`（不是 `codex` TUI），所以 `[tui.keymap]` 对桌面 App 完全无效 | 【实测】+【代码】 |

11 个语义动作的可行性一览（细节见 §6）：

| 语义动作 | 桌面 App 程序化 | 按键注入 | 判定 |
|---|---|---|---|
| `openModelPicker` | ✗ | `Ctrl+Shift+M` | ✅ 可做 |
| `inspectChanges` | ✗ | `Ctrl+Shift+G` / `Cmd+Alt+B` | ✅ 可做 |
| `submit` | ✗（IPC 有对应方法，未验证） | `Enter` | ✅ 可做 |
| `cancelOrInterrupt` | ✗（IPC 有对应方法，未验证） | `Esc` | ✅ 可做 |
| `queueFollowUp` | 半：`codex queue` 能写存储 | `Enter`（运行中） | ⚠️ 部分可做，语义待验证 |
| `navigateUp/Down` | ✗ | `↑`/`↓` | ⚠️ 可用但语义依赖焦点，无专用命令 |
| `navigateLeft/Right` | ✗ | `←`/`→` | ⚠️ 同上 |
| `toggleFastMode` | ✗ | 无默认快捷键 | ⚠️ 只能走 `Cmd+K` 命令面板或 UI 点击 |
| `cyclePermissionMode` | ✗ | 无 | ❌ **桌面 App 不存在这个动作** |

---

## 1. 被测环境

| 项 | 值 | 来源 |
|---|---|---|
| App | `/Applications/ChatGPT.app`，`CFBundleIdentifier=com.openai.codex`，`CFBundleShortVersionString=26.908.40834` | 【实测】`/usr/libexec/PlistBuddy` |
| 运行状态 | pid **16965**，父进程 1，已运行 2 天 21 小时 | 【实测】`ps` |
| 架构 | Electron 42.3.0（`package.json`），`Codex Framework.framework` Chromium 152.0.7977.83 | 【代码】`app.asar!/package.json` |
| user-data-dir | `~/Library/Application Support/Codex` | 【实测】`ps` 参数 |
| `CODEX_HOME` | `~/.codex`（与 CLI 共用） | 【实测】 |
| 内置 CLI | `/Applications/ChatGPT.app/Contents/Resources/codex` = `codex-cli 0.154.0-alpha.6.2` | 【实测】 |

注册的 URL scheme（【实测】`PlistBuddy -c 'Print :CFBundleURLTypes'`）：`codex`、`http`、`https`。

---

## 2. Q1 —— 桌面 App 与 CLI 是否共用同一个 daemon

### 2.1 结论

**不共用 daemon，只共用 `CODEX_HOME` 存储。**

### 2.2 桌面 App 侧的 app-server 是私有的

【实测】`ps` 显示 pid 17110 是 pid 16965（ChatGPT 主进程）的**子进程**：

```
/Applications/ChatGPT.app/Contents/Resources/codex \
  -c features.code_mode_host=true \
  app-server --analytics-default-enabled \
  -c plugins.codex-app-tools@openai-bundled.mcp_servers.codex_app.enabled=true
```

关键点：**没有 `--listen` 参数**，而 `codex app-server` 的默认值是 `--listen stdio://`
（【实测】`codex app-server --help`：`Transport endpoint URL. Supported values: stdio:// (default), unix://, ...`）。

【实测】`lsof -p 17110` 显示它的 fd 0/1/2 是与主进程配对的匿名 socketpair（fd 0 kernel addr 与 ChatGPT fd 132 的 peer 完全对上），**没有任何 `*.sock` 路径**，也没有 LISTEN 端口。即：这个 app-server 只通过 stdio 管道与 Electron 主进程通信，**外部进程无法接入**。

### 2.3 CLI 侧的「共享 daemon」是另一套，且本机未安装

【实测】

```
$ codex app-server daemon version
Error: failed to connect to ~/.codex/app-server-control/app-server-control.sock
Caused by: No such file or directory (os error 2)
```

该目录 `~/.codex/app-server-control/` **不存在**（【实测】`ls`）。

【实测】

```
$ codex agents
Error: managed standalone Codex install not found at ~/.codex/packages/standalone/current/codex

This command requires the standalone install managed by the Codex installer, because
the daemon starts and updates app-server from that fixed path.

Install it with:
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

→ `codex agents` 依赖的是**独立安装的 standalone CLI**（安装器管理），与 ChatGPT.app 内打包的 `Resources/codex` 是两回事。**所以「CLI 与桌面 App 共用同一个本地 app-server daemon」这个前提不成立。**

### 2.4 但两者确实共用存储，桌面 App 的会话在 CLI 的目录里

【实测】`sqlite3 -readonly ~/.codex/state_5.sqlite`：

```
sqlite> select originator, count(*) from threads group by 1 order by 2 desc;
|2369
Codex Desktop|17
codex-tui|3
```

`threads` 表有 `rollout_path / cwd / title / archived / git_branch / model / reasoning_effort / name / is_pinned` 等字段，共 2389 行，其中 **17 条 `originator='Codex Desktop'`** 就是桌面 App 的会话。

### 2.5 本机所有相关的 unix socket

| 路径 | 状态 | 归属 | 用途 |
|---|---|---|---|
| `~/.codex/ipc/ipc.sock` | **存在**（目录 0700，socket 0600） | pid 16965（ChatGPT）持有全部连接 | Codex IPC 总线，见 §4.3 |
| `~/.codex/app-server-control/app-server-control.sock` | **不存在** | — | CLI managed daemon 的 control socket |
| `$TMPDIR/codex-ipc/ipc-<uid>.sock` | 未出现 | — | IPC 的 fallback 路径【代码】 |
| `/tmp/codex-browser-use/<uuid>.sock` | 存在（多个） | pid 16965 子进程 | browser-use 服务 |
| `$TMPDIR/com.openai.codex.ZY8TCh/SingletonSocket` | 存在 | pid 16965 | Electron 单实例锁 |

【实测】`lsof ~/.codex/ipc/ipc.sock` → 只有 `ChatGPT 16965` 一个进程持有；两个 `codex` TUI 进程（pid 7396、66052）**都没有**连它。

---

## 3. Q2 —— `codex app-server` 协议 schema 与可编程动作

【实测】

```
codex app-server generate-json-schema --experimental --out /tmp/agentctl-research/schema
```

产物 47 个文件、5.3 MB，含 `ClientRequest.json`（281 KB）、`ServerRequest.json`、`ServerNotification.json`、`codex_app_server_protocol.v2.schemas.json` 等。

### 3.1 全部 ClientRequest 方法（131 个，去重后）

从 `ClientRequest.json` 抽取 `method` 枚举，按功能分组：

**线程生命周期 / 控制（与 11 个语义动作最相关）**

```
thread/start            thread/resume          thread/fork
thread/archive          thread/unarchive       thread/delete
thread/name/set         thread/metadata/update thread/settings/update
thread/read             thread/list            thread/loaded/list
thread/turns/list       thread/items/list      thread/timeline/list
thread/inject_items     thread/shellCommand    thread/rollback
thread/revert           thread/compact/start
turn/start              turn/steer             turn/interrupt
turn/settings/update
thread/queue/add        thread/queue/list      thread/queue/update
thread/queue/delete     thread/queue/reorder   thread/queue/start
thread/goal/set|get|clear
```

**模型 / 能力 / 配置**

```
model/list                modelProvider/capabilities/read
permissionProfile/list    collaborationMode/list
experimentalFeature/list  experimentalFeature/enablement/set
config/read               config/value/write     config/batchWrite
configRequirements/read
```

**审批**

```
（ServerRequest 侧）ExecCommandApproval / ApplyPatchApproval /
FileChangeRequestApproval / PermissionsRequestApproval / ToolRequestUserInput / McpServerElicitation
```

**其他**：`fs/*`（读/写/删/拷贝/监听）、`process/spawn|writeStdin|kill|resizePty`、`command/exec*`、`skills/*`、`plugin/*`、`marketplace/*`、`mcpServer*`、`remoteControl/*`、`account/*`、`review/start`、`fuzzyFileSearch*`、`thread/realtime/*`、`feedback/upload`。

### 3.2 与 11 个语义动作的对应关系（协议层）

| 语义动作 | app-server 方法 | 说明 |
|---|---|---|
| `submit` | `turn/start` | 向线程发起新一轮 |
| `cancelOrInterrupt` | `turn/interrupt` | 打断当前 turn |
| `queueFollowUp` | `thread/queue/add` | 入队一条 follow-up |
| `cyclePermissionMode` | `thread/settings/update` / `permissionProfile/list` | 改线程权限档，**不是"循环"语义** |
| `toggleFastMode` | `thread/settings/update` / `turn/settings/update` | 改 service tier |
| `openModelPicker` | `model/list` + `thread/settings/update` | 无"弹选择器"动作，只能程序化改模型 |
| `inspectChanges` | `thread/turns/list` / `thread/items/list` / `review/start` | 读取变更 |
| `navigate*` | 无对应 | 纯 UI 概念 |

> ⚠️ **但这张表在本机不可用**：如 §2.2，桌面 App 的 app-server 只挂在 stdio 管道上，**外部进程拿不到这个连接**。
> 【实测】`codex app-server proxy` 的 `--sock <SOCKET_PATH>` 需要一个 app-server 的 unix socket，而本机不存在这样的 socket。

---

## 4. 桌面 App 的可编程控制面盘点

### 4.1 Electron 进程内 IPC —— 外部不可达 ❌

【代码】`app.asar!/.vite/build/preload.js` 通过 `contextBridge.exposeInMainWorld('electronBridge', R)` 暴露的 API 只有：
`sendMessageFromView`、`sendWorkerMessageFromView`、`subscribeToWorkerMessages`、`showContextMenu`、`getSystemThemeVariant`、`getInitialSidebarBootstrap`、`startFileDrag`、`getPathForFile`、`triggerSentryTestError` 等。

通道名形如 `codex_desktop:message-from-view` / `codex_desktop:message-for-view`，走 `ipcRenderer.invoke`。
**这是 Electron 渲染进程 ↔ 主进程的进程内通道，外部进程无法注入。**

【代码】主进程 handler 注册表（`main.js`）里确实有关键的两个：

```js
"set-codex-command-keybinding": async ({commandId, update}) => {...}
"reset-codex-command-keybindings": async () => {...}
```

也就是说**桌面 App 的快捷键是可改的**（渲染进程内改），但改的入口在 App 内部 UI，外部无法直接调用。

### 4.2 私有 stdio app-server —— 外部不可达 ❌

见 §2.2。

### 4.3 Codex IPC 总线 `~/.codex/ipc/ipc.sock` —— 能连，但没人应答 ⚠️

这是本次调研最重要的发现，也是唯一一个**外部进程确实能加入**的本地控制面。

#### 实现（【代码】`app.asar!/.vite/build/src-CCXHtyvY.js` 内 `jme`/`Mme`/`Fme` 三个类）

- Socket 路径：`join(codexHome, 'ipc')` + `ipc.sock`，目录 `chmod 0700`、socket `chmod 0600`，并校验 owner uid（`Codex IPC directory is not owned by the current user`）。
  Windows 走命名管道 `\\.\pipe\codex-ipc`；另有 fallback `$TMPDIR/codex-ipc/ipc-<uid>.sock`。
- 帧格式：`4 字节小端长度前缀 + UTF-8 JSON`，单帧上限 256 MiB。
- 角色：
  - **Router**（谁先起谁当）：接受 connection，维护 `clients` / `clientsById` / `pendingRequests`。
  - **Client**：连上后必须发 `{type:'request', method:'initialize', params:{clientType}}`，router 回一个随机 `clientId`。
- 消息类型：
  - `broadcast` —— `{method, params, sourceClientId, targetClientIds?, version}`，router 转发给除自己外的所有 client。
  - `request` / `response` —— router 先向候选 client 发 `client-discovery-request`，收到 `{canHandle:true}` 的才转发；找不到就回 `{resultType:'error', error:'no-client-found'}`。默认超时 5 s（`Pme=5000`）。
  - `client-discovery-request/response`、`client-status-changed`（client 上下线广播）。
- 方法白名单 `nv`（含协议版本号），共 24 个：

```
thread-stream-state-changed: 11          thread-stream-following-changed: 1
thread-stream-following-status-requested: 1
ipc-connection-reset: 1                  thread-read-state-changed: 3
thread-archived: 2                       thread-unarchived: 1
thread-owner-discovery: 1                thread-follower-start-turn: 2
thread-follower-load-complete-history: 1 thread-follower-compact-thread: 1
thread-follower-steer-turn: 1            thread-follower-interrupt-turn: 4
thread-follower-update-thread-settings: 2
thread-follower-edit-last-user-turn: 2
thread-follower-command-approval-decision: 1
thread-follower-file-approval-decision: 1
thread-follower-permissions-request-approval-response: 1
thread-follower-submit-user-input: 1
thread-follower-submit-mcp-server-elicitation-response: 1
thread-follower-set-queued-follow-ups-state: 1
thread-queued-followups-changed: 2
```

> 注意 `thread-follower-steer-turn`、`thread-follower-interrupt-turn`、`thread-follower-set-queued-follow-ups-state`、`thread-follower-command-approval-decision` —— 名字上**正好覆盖 submit / interrupt / queue / 审批**。这是理论上最漂亮的控制面。

#### 实测：外部进程能连、能注册

【实测】用 60 行 Python 以 `clientType='probe-research-readonly'` 连接（只发 `initialize`，之后只读，**不发任何变更请求**）：

```
$ python3 ipc_probe.py 10
CONNECTED to ~/.codex/ipc/ipc.sock
SENT initialize
MESSAGES RECEIVED: 1
{"type":"response","requestId":"0b53acb4-...","resultType":"success","method":"initialize",
 "handledByClientId":"972c2028-da35-4cde-821c-d26543235963",
 "result":{"clientId":"972c2028-da35-4cde-821c-d26543235963"}}
DONE
```

→ **外部进程确实可以加入这条总线并拿到 `clientId`**。10 秒内没收到任何广播（总线在空闲时安静）。

#### 实测：发请求没人应答

【实测】取一条真实的桌面 App 会话 id（`originator='Codex Desktop'`）做只读探测：

```json
{"type":"request","method":"thread-owner-discovery","params":{"threadId":"01a0a2b0-..."},"version":1}
{"type":"request","method":"thread-owner-discovery","params":{"thread_id":"01a0a2b0-..."},"version":1}
{"type":"request","method":"thread-owner-discovery","params":{},"version":1}
```

三次都返回：

```json
{"type":"response","resultType":"error","error":"no-client-found"}
```

→ **当前总线上没有任何 client 声明自己处理这个请求。**

#### 判定

- `【实测】` 外部进程可连接、可注册。
- `【实测】` `thread-owner-discovery` 无 client 应答。
- `【未验证】` `thread-follower-*` 系列是否会被桌面 App 的 app-server 接住。
  **本次调研刻意没有发送任何 `thread-follower-*` 请求**——它们全部是变更操作（start-turn / interrupt / steer / approval decision），在真实会话上触发会污染用户数据。
- `【推断】` 桌面 App 的 app-server 是 stdio 私有的（§2.2），除非通过 fd 传递接入了这条总线，否则不会应答。
  `lsof` 上 ChatGPT 对 `ipc.sock` 的所有连接都是**进程内自连**（fd 之间的 peer 一一对应），没有看到第二个进程。

**给实现的结论**：不要把 `~/.codex/ipc/ipc.sock` 当作可依赖的控制面。它可以作为未来的探索方向（值得再花时间用 fd 追踪确认 app-server 是否在总线上），但 v0.1 不应建立在它之上。

### 4.4 本地网络端口 —— 无 ❌

【实测】

```
$ lsof -p 16965 -a -iTCP -sTCP:LISTEN        # 空
$ lsof -p 17110 -a -iTCP -sTCP:LISTEN        # 空
$ lsof -iTCP -sTCP:LISTEN -P | grep -iE 'codex|ChatGPT'   # 空
```

没有任何本地 HTTP / WebSocket 服务。

### 4.5 Remote Control —— 存在，但走云端中继 ⚠️

【实测】`sqlite3 -readonly ~/.codex/state_5.sqlite 'select * from remote_control_enrollments;'`：

```
websocket_url                | wss://chatgpt.com/backend-api/wham/remote/control/server
account_id                   | 0c8464b9-8138-4b88-8eba-386dfba959a5
app_server_client_name       | Codex Desktop
server_id                    | srv_e_6a0683a6534c832ea17f62d0986a93ea
environment_id               | env_e_6a0683a6533c832e920c38efe211d622
server_name                  | TIANHAOs-MBP
updated_at                   | 1789233380
remote_control_enabled       | 1
```

即：桌面 App **已经开启 Remote Control**，通过 `wss://chatgpt.com/...` 中继让手机/网页控制本机。

- 【代码】CLI 侧对应 `codex remote-control start|stop|pair`、`codex app-server daemon enable-remote-control`。
- 这条路对本地手柄适配器**不适用**：需要云端账号 + 出网，延迟高，且不是给本机自动化设计的。仅作记录。

### 4.6 `codex://` deep link 路由表（完整）

【代码】`app.asar!/.vite/build/window-all-closed-BxbCP6YG.js` 的 `nO()` / `PD()` / `oe()`。
Scheme：**打包版是 `codex`，未打包开发版是 `codex-dev`**（`MD(isPackaged)`）；注册用 `app.setAsDefaultProtocolClient`，macOS 上通过 `open-url` 事件接收。

路由解析入口 `PD(url)`：URL 的 `protocol` 必须是 `codex:`/`codex-dev:`，`username/password/port` 必须为空，然后按 **host** 分派：

| host（deep link 形如 `codex://<host>/...`） | 触发 | 参数（白名单校验） |
|---|---|---|
| `codex://launch` | 启动/唤起 App | 无 |
| `codex://new`、`codex://threads/new` | **新建一个会话** | `prompt`, `mode`, `originUrl`, `path`, `projectId`, `browserUrl`, `browserTabId`, `browserActive` |
| `codex://threads/<id>` | 打开某个会话 | 同上（`localConversation`） |
| `codex://settings/<section>` | 打开设置页 | section ∈ `browser-use, chronicle, connections, connections/computer, connections/devices, connections/ssh, connections/ssh/add` |
| `codex://settings/connections/ssh/add` | 打开「添加 SSH 连接」 | `name`\|`alias`, `projectPath`, `enabled` |
| `codex://settings/mcp-app/...`、`codex://settings/plugins/...` | 打开插件 MCP app / 插件详情 | `hostId` 等 |
| `codex://plugins/install/<name>` | 安装插件 | `marketplace` |
| `codex://plugins/<name>` | 插件详情 | `marketplacePath`, `mode=share` |
| `codex://skills` | 打开技能页 | `category` |
| `codex://automations` | 打开自动化页 | 无 |
| `codex://shared-thread/<cx_...>` | 打开分享快照 | 无 |
| `codex://pets/install/<name>` | 安装虚拟宠物 | `name`, `description`, `imageUrl`, `spriteVersionNumber` |
| `codex://codex-app/apply-config` | **重新加载 Codex app config** | 无 |
| `codex://connector/oauth_callback` | OAuth 回调 | `returnTo` |
| `codex://activate/life_sciences` | 激活体验 | 无 |
| `codex://browser?url=<http(s)>` | 在内置浏览器打开 URL | `url` |
| `codex://chatgpt/share/...` | 打开 ChatGPT 分享会话 | 无 |

另外还接受 **CLI 参数**（不是 URL）：`--open-project <path>` / `--open-project=<path>` ⇒ 新建会话并指定 workspace。
【实测】`codex app <PATH>` 的实现就在这条路上：【代码】二进制字符串里有 `cli/src/desktop_app/mod.rs` + `Opening workspace` + `codex://threads/new?` + `` `open -a `` ⇒ **CLI 会拼一个 `codex://threads/new?...` 然后 `open -a`**。
【实测】CLI 二进制字符串里出现：`codex://threads/new`（2 次）、`codex://threads/`、`codex://plugins/`。

> **对 11 个语义动作的价值：接近零。**
> deep link 只能「新建会话 / 打开会话 / 打开设置页 / 装插件」。
> **没有任何一条 deep link 能对"已经在跑的会话"做 submit / interrupt / queue / 切模型 / 切 fast mode / 看 diff / 看 transcript。**
> 唯一勉强相关的 `codex://threads/new?prompt=...&mode=...` 是**新建**一个会话并带上首条 prompt。

> 【未验证】deep link 的**端到端行为**（真的 `open -g "codex://..."` 之后的 UI 反应）本次**没有实测**——它会改变正在运行的用户 App 的 UI 状态（可能新建会话、弹设置窗口）。
> 上面整张表都是【代码】级证据（从打包 JS 的路由解析器逐条读出来的），路由的存在与参数校验规则是确定的，**但"发出去之后用户看到什么"未验证**。

### 4.7 AppleScript / System Events —— **可用** ✅ 【实测】

【实测】

```
$ osascript -e 'tell application "System Events" to tell process "ChatGPT" to get name of every menu bar item of menu bar 1'
Apple, ChatGPT, File, Edit, View, Window, Help
```

完整菜单树（实测枚举，`missing value` 为分隔线）：

```
[ChatGPT]  About ChatGPT | Settings… (Cmd+,) | Check for Updates… | Log Out | Services |
           Hide ChatGPT | Hide Others | Show All | Quit ChatGPT
[File]     New Window | New Chat (Cmd+N) | New Temporary Chat (Cmd+Shift+N) |
           Open Folder… (Cmd+O) | Close
[Edit]     Undo | Redo | Cut | Copy | Paste | Paste and Match Style | Delete | Select All |
           Substitutions | Speech | AutoFill | Start Dictation… | Emoji & Symbols
[View]     Toggle Sidebar (Cmd+B) | Toggle Bottom Panel (Cmd+J) | Toggle Pinned Summary |
           Open Terminal (Ctrl+`) | Toggle File Tree | Toggle Review Panel (Cmd+Alt+B) |
           Browser | Find (Cmd+F) | Previous Chat (Cmd+Shift+[) | Next Chat (Cmd+Shift+]) |
           Back (Cmd+[) | Forward (Cmd+]) | Zoom In | Zoom Out | Actual Size | Enter Full Screen
[Window]   Minimize | Minimize All | Zoom | Zoom All | Fill | Center | Move & Resize |
           Full Screen Tile | Bring All to Front | Arrange in Front | Remove Window from Set
[Help]     Send ChatGPT Feedback to Apple | Documentation | Keyboard Shortcuts |
           What's New | Troubleshooting | System Status | Send Feedback | Task Manager |
           Start Performance Trace
```

要点：

1. **Accessibility（辅助功能）权限对本会话的调用方已经开放**——能枚举菜单就意味着 `System Events` 的 AX 通道可用；同一权限也允许 `keystroke` / `click menu item`。
   ⚠️ 但这是**当前调用进程（终端）**的授权。将来打包成 Swift App 后需要**自己的** TCC 授权，不能想当然继承。
2. 菜单里**没有任何业务动作**（没有 Submit / Stop / Model / Diff）。能程序化的只有窗口与面板级操作。
3. `Help → Keyboard Shortcuts` 菜单项存在，可以用 System Events 点开（未实测点击）。
4. 【代码】`scripting.sdef` 是 Chromium 标准字典，不含 Codex 业务动词 —— 与父 agent 的侦察一致，AppleScript **只能走 System Events 的 UI 脚本**，不能走 App 自己的 AppleScript 词典。

### 4.8 CLI 侧可用的程序化入口（不依赖 App）

这些命令**不需要桌面 App**，直接在 `CODEX_HOME` 上工作：

| 命令 | 作用 | 实测 |
|---|---|---|
| `codex app <PATH>` | 打开桌面 App 到该 workspace（拼 `codex://threads/new?...`） | 【实测】`--help`；【代码】实现路径 |
| `codex queue --thread <UUID\|名字> --message <TEXT>` | 向已有会话入队一条消息 | 【实测】见下 |
| `codex resume/fork/archive/unarchive/delete` | 会话管理 | 【实测】`--help` |
| `codex exec` / `codex review` | 非交互跑一轮 | 【实测】`--help` |
| `codex app-server generate-ts/json-schema` | 导出协议 | 【实测】 |

【实测】`codex queue` 确实打通了协议层：

```
$ codex queue --thread 00000000-0000-0000-0000-000000000000 --message probe
Error: failed to queue session message: thread/queue/add failed:
  failed to read thread: invalid thread-store request:
  no rollout found for thread id 00000000-... (code -32603)
```

注意：这是一个合法的 JSON-RPC 错误（`code -32603`），说明它**真的执行到了 `thread/queue/add`**。

【实测】同时用 `ps` 轮询 6 秒，**没有看到 `codex queue` 派生任何 `app-server` 子进程**——它是**在自身进程内**跑 app-server 逻辑，直接读写 `~/.codex` 下的 `state_5.sqlite` 与 rollout JSONL。

⚠️ **【未验证】`codex queue` 对"正在运行的桌面 App 会话"是否真的生效。**
理由是：存储是共享的（§2.4），但桌面 App 的 app-server 进程持有自己的内存态；一个外部进程写进 rollout 的 queue item，**运行中的 App 是否会在下一次拉取时看到，本次没有验证**——验证它必须真的往用户会话里塞一条消息，本次调研拒绝做这种污染性实验。

---

## 5. Q3/Q4 —— 桌面 App 的菜单与快捷键

### 5.1 快捷键的真相来源：命令注册表

【代码】`app.asar!/.vite/build/src-CCXHtyvY.js`（同样内容也内嵌在 `main.js` 与 `webview/assets/app-initial.js`）里有一份**命令注册表**，131 条，结构：

```js
{ id: `newTask`,
  titleIntlId: `codex.command.newThread`,
  descriptionIntlId: `codex.commandDescription.newThread`,
  commandMenuGroupKey: `thread`, commandMenu: true,
  availableIn: [`browser`,`electron`],
  shortcutScope: `app` | `os-global`,
  shortcutConfigurable: false,          // 可选
  electron: {
    menuTitle: `New Chat`,              // 有 menuTitle ⇒ 进原生菜单
    menuTitleIntlId: `...`,
    defaultKeybindings: [{key:`CmdOrCtrl+N`}, {key:`CmdOrCtrl+Shift+O`}],
    platformDefaultKeybindings: { macOS: [...], default: [...] }
  },
  browser: { defaultKeybindings: [...] },   // 网页版
  vscodeCommand: {...}                       // VS Code 扩展
}
```

- 有 `electron.menuTitle` 的 ⇒ 出现在原生菜单里，accelerator 由 Electron 原生菜单处理。
- **没有** `menuTitle` 的（如 `composer.openModelPicker`）⇒ 不进菜单，accelerator 由**渲染进程**自己在 `keydown` 里匹配，**只在 webview 有焦点时生效**。
- 快捷键可通过 App 内 UI 改写（`set-codex-command-keybinding` IPC，见 §4.1），未在本次范围。

### 5.2 完整快捷键表（macOS）

`CmdOrCtrl` 在 macOS 上 = `Command`。下表是从注册表程序化导出的全部带默认键位的命令。

| command id | 菜单标题 | 默认快捷键（macOS） | 备注 |
|---|---|---|---|
| `newTask` | New Chat | `⌘N` / `⌘⇧O` | |
| `newProjectlessTask` | New standalone chat | `⌘⌥O` | |
| `quickChat` | — | `⌘⌥N` | |
| `temporaryChat` | New Temporary Chat | `⌘⇧N` | |
| `archiveThread` | Archive chat | `⌘⇧A` | |
| `markThreadUnread` | — | `⌘⇧U` | |
| `toggleThreadPin` | Pin/unpin chat | `⌘⌥P` | |
| `openSideChat` | — | `⌘⌥S` | |
| `toggleDebugModal` | — | `⌃D` | |
| `undoAppAction` / `redoAppAction` | — | `⌘Z` / `⌘⇧Z` | |
| `reopenClosedTab` | — | `⌘⇧T` | |
| **`composer.openModelPicker`** | — | **`⌃⇧M`** | 无菜单项，渲染进程处理 |
| `composer.openProjectPicker` | — | `⌘⌥⇧O` | |
| `composer.startVoiceMode` | — | `⌃⇧V` | |
| `composer.startDictation` | Dictation | `⌃⇧D` | |
| **`composer.submitInBackground`** | — | **`⌘⏎`** | 需 `backgroundSubmissionEnabled` |
| **`approval.approve`** | — | **`⏎`** | 审批卡上 |
| **`approval.decline`** | — | **`Esc`** | 审批卡上 |
| `openAvatarOverlay` | Show pet | `⌥Space` | `os-global`，全局热键 |
| `nextThreadNeedingAttention` | — | `⌘⌥A` | |
| `previousThread` / `nextThread` | Previous/Next Chat | `⌘⇧[` / `⌘⇧]`（另 `⌘⌥←/→`） | |
| `previousTab` / `nextTab` | — | `⌘⇧[` / `⌘⇧]`、`⌃⇧⇥`/`⌃⇥` | |
| `previousRecentThread` / `nextRecentThread` | — | `⌃⇧⇥` / `⌃⇥` | |
| `recentThread1..6` | — | `⌘⌥1`..`⌘⌥6` | |
| `focusTab1..9` | — | `⌃1`..`⌃9`（Windows/Linux 为 `Alt+1..9`） | |
| `switchToMode1..3` | — | `⌃1`..`⌃3`（切换 Chat / Work / Codex） | |
| `settings` | Settings… | `⌘,` | |
| `showKeyboardShortcuts` | Keyboard Shortcuts | `⌘/` | 打开快捷键面板 |
| `clearAllUnreads` | — | `⇧Esc` | |
| `openFolder` | Open Folder… | `⌘O` | |
| `toggleSidebar` | Toggle Sidebar | `⌘B` | |
| `toggleBottomPanel` | Toggle Bottom Panel | `⌘J` | |
| `toggleTerminal` | Open Terminal | `⌃\`` | |
| `openBrowserTab` | Open Browser Tab | `⌘T` | |
| `showWorkspaceTabView` | — | `⌘⇧F` | |
| `stepWorkspaceLayout` | — | `⌘⇧B` | |
| **`openReviewTab`** | — | **`⌃⇧G`** | 审阅/变更面板 |
| **`toggleSidePanel`** | Toggle Review Panel | **`⌘⌥B`** | diff 侧栏 |
| `toggleFileTreePanel` | Toggle File Tree | `⌘⇧E` | |
| `findInThread` | Find | `⌘F` | |
| `goToLine` / `focusBrowserAddressBar` | Focus Browser Address Bar | `⌘L` | |
| `navigateBrowserBack` / `Forward` | — | `⌘←` / `⌘→` | |
| `navigateBack` / `navigateForward` | Back / Forward | `⌘[` / `⌘]` | |
| `openCommandMenu` | — | `⌘K` / `⌘⇧P` | 命令面板 |
| `searchChats` | Search Chats… | `⌘K` | |
| `searchFiles` | Search Files… | `⌘P` | |
| `renameThread` | Rename chat | `⌘⌥R` | |
| `copyDeeplink` | Copy deeplink | `⌘⌥L` | |
| `copyWorkingDirectory` | Copy working directory | `⌘⇧C` | |
| `copyConversationPath` | Copy conversation path | `⌘⌥⇧C` | |
| `closeTab` / `closeWindow` | Close Tab / Close | `⌘W` | |
| `reloadBrowserPage` / `hardReloadBrowserPage` | — | `⌘R` / `⌘⇧R` | 仅内置浏览器 |
| `toggleTraceRecording` | Start Trace Recording | `⌘⇧S` | |
| `environmentAction1` | — | `⇧⌘D` | |
| `hotkeyWindow` | — | `os-global`，注册表里无默认键位（由 App 内设置，落到 `~/.codex/keybindings.json`） | |
| `globalDictationToggle` | — | `os-global` | 【实测】本机 `~/.codex/keybindings.json` 里显式绑定为 `Ctrl+Command+Alt+D`（**该文件格式是 `[{command,key}]`，不是 TUI 的 keymap**） |

### 5.3 **没有**默认快捷键的命令（重要）

下列命令存在于注册表但**没有默认键位**，即"按键注入做不到，只能走命令面板/UI"：

```
composer.submit            composer.steer            composer.queue            composer.clear
composer.toggleFastMode    composer.togglePlanMode
composer.increaseReasoningEffort   composer.decreaseReasoningEffort   composer.cycleReasoningEffort
composer.toggleWorktreeMode        composer.toggleWorkRunLocation
composer.addPhotos         composer.captureAppshot
approval.approve(仅在审批卡上下文)  toggleReviewTab  toggleMaximizeSidePanel
forkThread  git.*  openThreadInNewWindow  copyConversationMarkdown  ...
```

### 5.4 composer 的 Enter / Esc 语义（【代码】`webview/assets/app-primary.js`）

这是 11 个动作里最关键的两个人机交互，从渲染进程源码读出：

**Esc** —— 一个上下文状态机（函数 `N_r`）：

```js
isDictating                    → `abort-dictation`
realtimePhase==='starting'|'active' → `stop-realtime-session`
hasActiveTemplatePicker        → `close-template-picker`
isTerminalTarget || hasActiveApprovalSurface → null（什么都不做）
isResponseInProgress && canStopFromEscape
      → isStopTurnConfirmationVisible ? `stop-turn` : `confirm-stop-turn`
hasActiveMentionMenu           → null
否则                            → `focus-composer`
```

即 **Esc = 停止/打断当前 turn**（前提：本地/云端会话、正在生成、且允许 Esc 停止），否则 Esc 只是把焦点还给输入框。

**Enter / ⌘Enter** —— 取决于设置 `composerEnterBehavior`（`enter` \| `cmdIfMultiline` \| `cmdAlways`）：

```js
case 'enter':          n = (metaKey||ctrlKey) && !shiftKey && !altKey;
case 'cmdIfMultiline':
case 'cmdAlways':      n = (metaKey||ctrlKey) && shiftKey && !altKey;
```

- 空闲时按 `Enter` ⇒ `composer.submit`（提交）。
- **生成中**按上面的组合键 ⇒ 走"follow-up"路径：
  `followUpSubmitAction = steer | queue`，由设置 **`followUpQueueMode`** 决定（`queue` 是默认；`interrupt` 会被规范化成 `steer`）。
- `⌘Enter` 另绑 `composer.submitInBackground`（后台提交）。

【实测】用户当前配置 `~/.codex/config.toml` 里有：

```toml
[desktop]
followUpQueueMode = "queue"
```

⇒ **运行中按 `Enter` 会把输入排队**，这就是 `queueFollowUp` 的天然实现路径。

> 【未验证】"运行中按 Enter ⇒ 真的走 queue 而不是 steer"这条链路没有做端到端按键实测（会向用户会话里写字）。上面的 `followUpQueueMode` 分支是【代码】级结论。

### 5.5 桌面 App **没有**权限模式循环

【实测】131 条命令注册表里，权限相关只有 `approval.approve`（`Enter`）与 `approval.decline`（`Esc`）。
**没有** `cycleMode` / `permissionMode` / `Shift+Tab` 之类的东西。
【实测】在渲染进程 bundle 里 grep `Shift+Tab` / `shift+tab`：`app-primary.js` **0 次**，`app-initial.js` 的 3 次全部是 `previousTab` 这个标签切换命令的 accelerator。

⇒ **Codex 桌面 App 不存在「循环权限模式」这个动作**，`cyclePermissionMode` 在桌面 App 上无法实现（除非将来通过 app-server `thread/settings/update` 程序化改，而那条路当前不可达）。

---

## 6. 11 个语义动作 × 桌面 App 可行性

图例：**P** = 程序化可用 · **K** = 需要注入按键 · **X** = 做不到 / 未验证

| # | 语义动作 | 桌面 App 方案 | 等级 | 证据 |
|---|---|---|---|---|
| 1 | `navigateUp` | 注入 `↑`（会话列表 / 命令面板 / 审批选项 等列表上下移动；聊天区为滚动） | K / 【推断】 | 注册表里**没有**通用 navigate 命令；`↑/↓` 只出现在各上下文（`select:previous`、`autocomplete:previous`、`footer:up`…）【代码】 |
| 2 | `navigateDown` | 注入 `↓` | K / 【推断】 | 同上 |
| 3 | `navigateLeft` | 注入 `←`（标签/附件/面板切换） | K / 【推断】 | | 
| 4 | `navigateRight` | 注入 `→` | K / 【推断】 | |
| 5 | `submit` | 聚焦输入框后注入 `Enter` | K / 【代码】 | §5.4 的 `composer.submit` + `composerEnterBehavior` |
| 6 | `cancelOrInterrupt` | 注入 `Esc`（生成中） | K / 【代码】 | §5.4 的 `N_r()` → `stop-turn` / `confirm-stop-turn` |
| 7 | `queueFollowUp` | 首选：运行中注入 `Enter`（受 `followUpQueueMode="queue"` 控制）；备选：`codex queue --thread <id> --message` | K+P / ⚠️ | 前半【代码】+【实测】配置；后半【实测】命令可达，**是否被运行中的 App 采纳【未验证】** |
| 8 | `cyclePermissionMode` | **无**。桌面 App 没有这个动作，也没有快捷键 | **X** | 【实测】注册表无此命令；【实测】renderer 无 `Shift+Tab` |
| 9 | `toggleFastMode` | 无快捷键。只能：`⌘K` 命令面板输入命令名，或点击模型菜单里的 Fast 开关 | K（脆弱）| 【实测】`composer.toggleFastMode` 无 `defaultKeybindings` |
| 10 | `openModelPicker` | 注入 `Ctrl+Shift+M` | K / 【实测】 | 注册表 `composer.openModelPicker` → `Ctrl+Shift+M` |
| 11 | `inspectChanges` | 注入 `Ctrl+Shift+G`（打开 Review 标签）或 `⌘⌥B`（Toggle Review Panel，即 diff 侧栏） | K / 【实测】 | 注册表 `openReviewTab` / `toggleSidePanel` |

**结论**：
- **11 个动作里 10 个在桌面 App 上可达**，其中 9 个纯靠按键注入，1 个（`queueFollowUp`）有半程序化替代路径。
- **`cyclePermissionMode` 在 Codex 桌面 App 上不存在对应动作** —— 这是唯一一个 spec §10.3 里在 Codex 侧无法落地的语义动作。
- **`navigateUp/Down/Left/Right` 没有专用命令**，只能注入方向键，语义完全取决于当前焦点在哪个面板；这一点与 CLI 里 `↑/↓` = 会话列表 / 草稿历史 的确定性语义**差别很大**，adapter 里应当把它标为 `ActionRisk.navigation` 并接受"上下文相关"。
- 桌面 App 还有一批 **CLI 里没有**、值得考虑的现成快捷键：`⌘N` 新会话、`⌘K` 命令面板、`⌘B` 侧栏、`⌘J` 底部面板、`⌃\`` 终端、`⌘⇧G` diff。

---

## 7. 未验证清单与风险

| 项 | 状态 | 说明 |
|---|---|---|
| `codex://` deep link 的端到端 UI 行为 | **未验证** | 路由表是【代码】级确定；故意没发真实 deep link，避免改动正在运行的 App |
| `~/.codex/ipc/ipc.sock` 上 `thread-follower-*` 是否有人应答 | **未验证** | 只测了只读的 `thread-owner-discovery` → `no-client-found`；变更类方法一律没发 |
| 桌面 App 的 app-server 是否通过 fd 传递接入了 IPC 总线 | **未验证** | `lsof` 看不到第二方持有 `ipc.sock` 路径，但 fd 传递可以不显示路径 |
| `codex queue` 对运行中的桌面会话是否生效 | **未验证** | 需要往用户会话写数据才能验证，本次拒绝执行 |
| 运行中按 `Enter` 是否真走 queue | **未验证** | 同上 |
| 11 个动作的实际按键效果 | **未验证** | 需要把手柄/键盘事件真的打给正在运行的用户 App；本次只做到"读代码确认键位存在" |
| 打包后的 Swift App 的 Accessibility 授权 | **未验证** | 本次只证明了**当前终端**有 AX 权限；签名 App 的 TCC 授权是另一回事（Phase 1/2 待办） |
| 快捷键自定义（`set-codex-command-keybinding`）的落盘位置 | **未验证** | 只看到 IPC handler 存在；存储介质没追到底 |

**其它风险**

1. 桌面 App 是 Electron，按键注入要打给**有焦点的 webContents**；如果焦点在内置浏览器标签页或终端面板，同一个键的含义完全不同。Adapter 必须做 `Target application guard` + 面板级检测（spec §12 的意图在桌面 App 上更必要）。
2. `⌥Space`（Show pet）是 `os-global` 全局热键，会抢系统快捷键，配置手柄时要注意冲突。
3. `Ctrl+Shift+M` / `Ctrl+Shift+G` 这类无菜单项的命令由渲染进程处理，**窗口失焦即失效**；而原生菜单快捷键（如 `⌘N`）在 App 失焦时同样不触发。两种路径都要求 App 在前台——这点对手柄遥控是好事（安全），对"后台遥控"是限制。

---

## 附录 A（次要）—— Codex TUI `[tui.keymap]`：已实测，但对桌面 App 无用

> 上一轮的调研目标。结论保留在此，因为它是**唯一一条能完全消除按键注入不确定性的 Codex 路径**——但只对 `codex` TUI 有效。

**首要结论**：桌面 App **不跑 TUI**。它跑的是 Electron + React renderer + 私有的 `codex app-server`（§2.2）。`[tui.keymap]` 只影响 `codex` 这个终端 TUI 程序，**对桌面 App 零影响**。若将来只支持 TUI，可以完全依赖它。

### A.1 配置结构（【实测】隔离 `CODEX_HOME` + pty 跑 TUI 逐条验证）

写法和 `~/.codex/config.toml` 里的 `[tui.keymap]` 段。**12 个子段**（错误信息直接给出白名单）：

```
global, chat, composer, editor, vim_normal, vim_operator, vim_search,
vim_text_object, pager, list, agents, approval
```

逐段可绑定的 action（从二进制 rodata 抽出的完整列表，142 个）：

- `global`：`open_agents` `open_transcript` `open_external_editor` `copy` `clear_terminal` `toggle_vim_mode` `toggle_fast_mode` `toggle_raw_output` `toggle_side_conversation`
- `chat`：`interrupt_turn` `decrease_reasoning_effort` `increase_reasoning_effort` `previous_permission_mode` `next_permission_mode` `edit_queued_message` `prompt_stack_back` `skip_question`
- `composer`：`submit` `queue` `toggle_shortcuts` `history_search_previous` `history_search_next`
- `editor`：17 个（`insert_newline` `move_*` `delete_*` `kill_*` `yank` …）
- `vim_normal`（36）/ `vim_operator`（20）/ `vim_text_object`（9）/ `vim_search`（4）
- `pager`（10）：`scroll_up` `scroll_down` `page_up` `page_down` `half_page_up` `half_page_down` `jump_top` `jump_bottom` `close` `close_transcript`
- `agents`（6）：`resume` `search` `new_task` `rename` `stop` `toggle_grouping`
- `approval`（8）：`open_fullscreen` `open_thread` `approve` `approve_for_session` `approve_for_prefix` `deny` `decline` `cancel`
- `list`（10）：`move_up` `move_down` `accept` `cancel` `move_left` `move_right` `page_up` `page_down` `jump_top` `jump_bottom`

### A.2 值格式（【实测】38 组隔离用例）

| 写法 | 结果 |
|---|---|
| `submit = "ctrl-y"` | ✅ 接受 |
| `submit = ["ctrl-y", "ctrl-u", "ctrl-i"]` | ✅ 接受（一个 action 可绑多个键） |
| `submit = "ctrl-x ctrl-s"` | ✅ 接受（空格分隔的两段式 chord） |
| `submit = "ctrl-a"` / `"alt-y"` / `"shift-enter"` / `"enter"` / `"escape"` / `"page-down"` / `"pagedown"` / `"up"` / `"f1"` / `"f13"` / `"a"` / `"A"` / `"ctrl-/"` | ✅ 接受 |
| `submit = "cmd-y"` / `"super-y"` / `"meta-y"` / `"opt-y"` | ❌ 拒绝（**只有 ctrl / alt / shift 三个修饰键**，与错误文案一致） |
| `submit = "arrow-up"` / `"ctrl-xctrl-s"` / `""` / `3` / `true` / `{key=..,when=..}` | ❌ 拒绝（`data did not match any variant of untagged enum KeybindingsSpec`） |
| 未知 action | ❌ `unknown field \`bogus_action\`, expected one of \`submit\`, \`queue\`, \`toggle_shortcuts\`, … in \`tui.keymap.composer\`` |
| 未知子段 | ❌ `unknown field \`bogus\`, expected one of \`global\`, \`chat\`, \`composer\`, … in \`tui.keymap\`` |
| 同段两个 action 绑同一个键 | ✅ **启动时接受**（不报错） |
| `[tui.keymap]\ncomposer = { submit = "ctrl-y" }` / `tui.keymap.composer.submit = "ctrl-y"` | ✅ 接受（点号路径 / 内联表都行） |
| `[tui.keymap.composer.submit]\nkey = "ctrl-y"` | ❌ 拒绝（不是表） |

### A.3 最小示例、验证、回滚

```toml
# ~/.codex/config.toml
[tui.keymap.composer]
submit = "ctrl-y"
queue  = "ctrl-u"
```

**验证方法**（不碰用户配置，全隔离）：

```bash
mkdir -p /tmp/codex-keymap-test
cat > /tmp/codex-keymap-test/config.toml <<'EOF'
[tui.keymap.composer]
submit = "ctrl-y"
EOF
CODEX_HOME=/tmp/codex-keymap-test codex
# 合法 → 正常进入 TUI（登录页）
# 非法 → 立即退出并打印：
#   Error loading config.toml: data did not match any variant of untagged enum KeybindingsSpec
#     in `tui.keymap.composer.submit`
#   或 unknown field `bogus_action`, expected one of ... in `tui.keymap.composer`
```

相关错误文案（二进制内，【实测】触发到前两条）：
```
Error loading config.toml: ... in `tui.keymap.<section>.<action>`
Invalid `tui.keymap` configuration:
  Fix the config and retry.
  See the Codex keymap documentation for supported actions and examples.
Invalid `<section>` = `<value>`. Use values like `ctrl-a`, `shift-enter`, or `page-down`.
Ambiguous `tui.keymap.<...>` bindings: `<a>` and `<b>` use the same key.
Ambiguous `tui.keymap.<...>` bindings: `<a>` uses a key reserved by `<b>`.
Ambiguous `tui.keymap.<...>` bindings: `<a>` shadows `<b>` with the same key.
`<action>`: ctrl-z is reserved for suspend
Only ctrl, alt, and shift modifiers can be stored in `tui.keymap`.
Only printable ASCII keys can be stored in `tui.keymap`.
```

**回滚**：删掉 `[tui.keymap...]` 段即可（或恢复备份）。Codex 对未列出的 action 一律走内置默认键位，**未出现的 action 不会被改动**，所以只删自己加的行是安全的。

### A.4 TUI 默认键位：只挖到少量，其余未能确定

从二进制里能**确定**的只有这几条（相邻字符串，【代码】级）：

- `toggle_shortcuts`（快捷键面板）← `ctrl-/`、`ctrl-7`
- `close_transcript`（pager 段）← `ctrl-o`
- vim 文本对象段附近出现 `shift-right`、`ctrl-]`、`shift-down`

其余键位（`composer.submit` = Enter、`chat.interrupt_turn` = Esc 等常识性默认）**未能从二进制确定** ——
原因：Rust 的 `&str` 字面量在 rodata 里**首尾相连、没有 NUL 分隔**，默认键位表与 142 个 action 名混在同一个 6.6 KB 的连续块里，无法可靠切分；`strings -a | grep -F` 只能拿到"相邻出现过"，不能证明归属。
**没有做 `/keymap` TUI 交互抓屏**（会拉起长时间交互会话），所以这一项如实标为**未能确定**。

---

## 附录 B —— 复现命令清单

```bash
# 1) 进程与 socket
ps -ww -p 17110 -o args=
lsof -p 16965 | grep -i unix
lsof ~/.codex/ipc/ipc.sock
lsof -iTCP -sTCP:LISTEN -P | grep -iE 'codex|ChatGPT'
ls -la ~/.codex/ipc/ ~/.codex/app-server-control/ 2>&1

# 2) daemon 结论
codex app-server daemon version
codex agents
codex app-server --help
codex app-server daemon start --help

# 3) 会话目录（只读）
sqlite3 -readonly ~/.codex/state_5.sqlite ".schema threads"
sqlite3 -readonly ~/.codex/state_5.sqlite "select originator,count(*) from threads group by 1;"
sqlite3 -readonly ~/.codex/state_5.sqlite "select * from remote_control_enrollments;"

# 4) 协议 schema
codex app-server generate-json-schema --experimental --out /tmp/agentctl-research/schema
python3 -c "import json;d=json.load(open('/tmp/agentctl-research/schema/ClientRequest.json'));..."  # 见正文抽 method

# 5) app.asar 解包（自写 asar.py，纯 Python，无需 npm）
python3 asar.py /Applications/ChatGPT.app/Contents/Resources/app.asar list > asar-list.txt
python3 asar.py /Applications/ChatGPT.app/Contents/Resources/app.asar extract /.vite/build/main-DaMR-wdT.js main.js
python3 asar.py /Applications/ChatGPT.app/Contents/Resources/app.asar extract /native-menu-locales/zh-CN.json zh-CN.json
# 命令注册表在 src-CCXHtyvY.js，用括号匹配切出来后可被 node require 直接解析

# 6) IPC 总线只读探测
python3 ipc_probe.py 10          # 只发 initialize，之后只读

# 7) 菜单枚举（Accessibility）
osascript -e 'tell application "System Events" to tell process "ChatGPT" to get name of every menu bar item of menu bar 1'

# 8) TUI keymap 隔离实验
CODEX_HOME=/tmp/codex-keymap-test codex     # 见附录 A.3
```

**本次调研修改过的东西**：无。
没有改动 `~/.codex/config.toml`、没有改动 `~/.claude/` 下任何文件、没有新建/删除任何用户文件、没有 commit。
所有实验产物都在 `/tmp/agentctl-research/` 下（`ch1`、`ch_valid`、`ch_invalid`、`batch/*`、`schema/`、`asar-out/`、`vite/`、`wv/`、`codex.strings`、`claude.strings` 等）。
唯一对运行中 App 的接触是**只读的 `osascript` 菜单枚举**与**IPC 总线上的一次 `initialize` 注册**（会向其他 client 广播一条 `client-status-changed`，无副作用）。
