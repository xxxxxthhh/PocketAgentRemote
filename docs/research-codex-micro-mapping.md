# Codex Micro ↔ IINE L1162 映射调研

> 只读调研。未修改 `~/.codex/`、`~/.claude/`、`/Applications/ChatGPT.app` 下任何文件；
> 未启动任何 GUI App、未跑 Codex 交互式会话、未提交 git。
> 所有提取物落在 `/tmp/agentctl-micro/`。
>
> 目标 App：`/Applications/ChatGPT.app`，bundle id `com.openai.codex`，app.asar 大小 322,016,862 字节（2026-09-13 01:10 构建）。
> 目标硬件：IINE L1162（6 键 BLE HID 手柄：↑↓←→ + A + B）。

## 0. 证据等级约定

| 标记 | 含义 |
|---|---|
| **实测验证** | 本次调研实际执行命令并看到该输出（命令与片段均附在正文） |
| **静态推断** | 从打包 JS / 二进制反汇编 / i18n 文案直接读出，未运行时验证行为 |
| **未验证** | 无法从现有素材判定，本文不做结论 |

**特别注意**：打包 JS 与二进制里的字符串常首尾相连，本调研全程使用**子串匹配**，未使用 `grep -x`。

---

## 1. 可行性判定：L1162 能不能被 Codex 当成 Codex Micro 接受？

### 结论（先给结论）

> ## ❌ 不可行。
> L1162 固件不可改、无法改 VID/PID/HID 描述符，而 Codex 桌面 App 在 macOS 上的设备发现是
> **IOKit 匹配字典硬过滤 `VendorID=12346(0x303A)` + `ProductID ∈ {0x8360, 0x8297, 0x8298}` + HID `usagePage=0xFF00`**，
> 三重条件全部硬编码在原生插件 `hid-topology-watcher.node` 里。
> **「困难」不等于「可能」：这条路在 L1162 上没有任何可达路径。**
> 唯一的理论旁路（用 `IOHIDUserDevice` 造一个虚拟设备冒充 Codex Micro）不是「让 L1162 被识别」，
> 而是「另造一个假的 Codex Micro」，且需要 Apple 受限 entitlement（`com.apple.developer.hid.virtual.device`），
> 还要自己实现整套私有 RPC 设备端协议 —— 在本项目条件下判定为**不可行且不值得**。
>
> 现实路线仍然是本项目既定方案：**L1162 → 我们的 Swift App → CGEvent 键盘注入 → Codex 公开命令体系**（见第 2 节）。

### 1.1 macOS 上 App 实际的发现链路（不是 `WLDeviceDiscovery`）

`CodexMicroService` 在 macOS 上**根本不走** `WLDeviceDiscovery.findWLDevices()`，而是走原生插件。

**证据 A（实测验证）** — `service-tYAbfsGu.js`（`.vite/build/service-tYAbfsGu.js`，29630 字节，单行）开头：

```bash
$ head -c 1200 /tmp/agentctl-research/vite/service-tYAbfsGu.js
```
```js
var c=`hid-topology-watcher.node`,l=`hid_topology_watcher.node`,u=(0,s.createRequire)(__filename);
function d(e){return p().watch(e)}
function f(){return p().findCodexMicroInterfaces()}
...
var h=12346,g=33632,_=[33431,33432],v=[g,..._],y=65280,b=(0,s.createRequire)(__filename),...
async function te(){return ne(process.platform===`linux`?(await Promise.all(v.map(async e=>(await T().devicesAsync(h,e)).map(t=>({...t,productId:e}))))).flat():await f())}
function ne(e){return e.flatMap(e=>{let t=re(e.productId);
return e.path==null||e.usagePage!==y||t==null?[]:[{portPath:e.path,devicePid:String(e.productId),...,deviceType:t,...}]})...}
function re(e){return e===g?C.CodexMicro:_.some(t=>t===e)?C.CreatorMicroV2:null}
```

解读（**实测验证** —— 常量就在打包产物里）：

* `platform === 'linux'` 才用 `node-hid` 的 `devicesAsync(12346, pid)` 枚举；
* **macOS/Windows 走原生插件 `hid-topology-watcher.node` 的 `findCodexMicroInterfaces()`**；
* 之后 JS 侧再过一道：`path != null` 且 `usagePage === 65280 (0xFF00)` 且 `productId ∈ {33632, 33431, 33432}`；
* PID 映射：`33632 (0x8360) → CodexMicro`，`33431 (0x8297) / 33432 (0x8298) → CreatorMicroV2`。

**证据 B（实测验证）** — 原生插件的 IOKit 匹配字典。插件在
`/Applications/ChatGPT.app/Contents/Resources/native/hid-topology-watcher.node`。

```bash
$ strings -a .../hid-topology-watcher.node | grep -iE 'work|louder|usag|vendor|product|codex|micro|hid'
com.openai.codex.hid-topology-watcher
DeviceUsagePage
DeviceUsagePairs
Failed to find Codex Micro HID interfaces
findCodexMicroInterfaces
HidTopologyWatcher
IOHIDDevice
PrimaryUsagePage
productId
ProductID
usagePage
VendorID
```

```bash
$ otool -tV .../hid-topology-watcher.node | grep -nE '#0x303a|#0x8360|#0x8297|#0x8298|#0xff00'
5069:  mov  w2, #0x8360      # 33632  CodexMicro
5098:  mov  w2, #0x8297      # 33431
5126:  mov  w2, #0x8298      # 33432
5563:  mov  w9, #0xff00      # 65280
5678:  mov  w9, #0xff00
5792:  mov  w8, #0xff00
5837:  mov  w8, #0xff00
```

`CreateCodexMicroMatchingDictionary(int productId)` 的反汇编显示它构造
`IOServiceMatching("IOHIDDevice")` 后 `CFDictionarySetValue` 两个键（section 字符串表里就是
`VendorID` / `ProductID`），另有一个 int32 常量来自 `__const`：

```bash
$ python3 - <<'EOF'
f=open('/Applications/ChatGPT.app/Contents/Resources/native/hid-topology-watcher.node','rb').read()
base=28316  # __const 的 file offset，vaddr 0x6e9c
off = base + (0x6f38-0x6e9c)
print(f[off:off+4].hex(), int.from_bytes(f[off:off+4],'little'))
EOF
3a300000 12346
```

即 **`VendorID = 12346 (0x303A)`**。usagePage 过滤也在插件内部做了（`cmp w8, #0xff00; b.ne <skip>`，
命中后才把 `usagePage=0xFF00` 写进返回结构）。

**证据 C（实测验证）** — 库侧（`wl-index.js`）的等价逻辑，作为交叉印证：

```bash
$ sed -n '5180,5245p' /tmp/agentctl-research/kit/wl-index.js
```
```js
var DEVICE_REGISTRY = new Map([
  ...
  [33431, { type: "creator_micro_v2", layout: "universal" }],
  [33432, { type: "creator_micro_v2", layout: "universal" }],
  [33632, { type: "codex_micro",     layout: "universal" }],
  ...
]);
var WL_VID = 12346;
var WL_MANUFACTURER = ["Work Louder", "Work_Louder"];
...
filterWLDevices(hidDevices) {
  let workLouderDevices = hidDevices.filter(d => d.manufacturer !== undefined &&
    WL_MANUFACTURER.some(m => d.manufacturer.includes(m)) && d.vendorId === WL_VID);
  if (workLouderDevices.length === 0) {
    workLouderDevices = hidDevices.filter(d => d.vendorId === WL_VID);   // 厂家名可缺省
  }
  return workLouderDevices.map(d => {
    if (!d.path || !d.productId || d.usagePage !== 65280) return;        // 0xFF00
    const wlDevice = DEVICE_REGISTRY.get(d.productId);
    if (!wlDevice) return;                                               // PID 白名单
    ...
  }).filter(Boolean);
}
```

Bootloader（DFU）侧的过滤条件（`findWLBootloaderDevices`）同样要求 `vendorId === 12346`，
再按 `manufacturer === "Espressif"` 或（Windows）序列号以 `0000` 结尾判定：

```js
if (isNaN(vendorId) || vendorId !== WL_VID) return;
...
if (isWin && port.serialNumber?.endsWith("0000")) { ... }
else if (port.manufacturer === "Espressif") { ... }
```

### 1.2 需要什么条件才能被认出来

要进入 `CodexMicroService` 的设备候选集，**必须同时满足**：

| # | 条件 | 值 | 来源 |
|---|---|---|---|
| 1 | USB HID 设备出现在 IORegistry（`IOHIDDevice`） | — | 原生插件 `IOServiceMatching("IOHIDDevice")` |
| 2 | `VendorID` | **12346 / 0x303A** | 插件 `__const` 0x6f38 = `3a300000` |
| 3 | `ProductID` | **0x8360 / 0x8297 / 0x8298** 之一 | 插件 `mov w2,#0x8360` 等 |
| 4 | HID `PrimaryUsagePage`（或 `DeviceUsagePairs` 中某项）= `0xFF00` | 65280 | 插件 `cmp ...,#0xff00`；JS 侧二次校验 |
| 5 | 有可打开的 HID `path` | — | `service-tYAbfsGu.js`：`e.path==null` 直接丢弃 |
| 6 | （伪装通讯）能说私有协议 | 见 1.4 | `wl-index.js` `parseHIDReport` / `WLRPCClient` |

第 4 条尤其关键：Work Louder 用的是 **vendor-defined usage page `0xFF00`**，而不是标准 HID
键盘（`0x01`）或消费类控制（`0x0C`）。普通 BLE 手柄的 HID 报告描述符里根本没有 `0xFF00`。

### 1.3 固件不可改的第三方 BLE HID 手柄有没有可能满足？

**没有。** 逐条对照：

| 条件 | L1162 现状 | 可改？ |
|---|---|---|
| VID = `0x303A` | IINE 自己的 VID（非 Espressif/Work Louder） | ❌ 固件不可改 |
| PID ∈ {0x8360, 0x8297, 0x8298} | 不匹配 | ❌ 固件不可改 |
| HID `usagePage = 0xFF00` | BLE HID，标准 usage（Generic Desktop / Button），无 `0xFF00` 集合 | ❌ HID 描述符由固件生成 |
| `manufacturer` 含 "Work Louder" | 不匹配 | ❌（且此项在本 App 的 macOS 链路上根本不被检查） |
| BLE vs USB | L1162 是 BLE HID | macOS 的 IOHIDDevice 也会暴露 BLE 设备（`Transport=Bluetooth`），**但 VID/PID/usagePage 仍然全部不匹配** |

结论：**BLE 不是障碍，VID/PID/usagePage 才是。这三个都锁在固件里。**

补充：即使某个手柄碰巧 VID 相同，`DEVICE_REGISTRY` 里没有对应 PID 也会被丢弃；即使 PID 相同，
`usagePage !== 0xFF00` 也会被丢弃。三条是 AND 关系。

### 1.4 如果要「伪造」，需要什么？哪些在本项目条件下不可行

按可行性从低到高排列，逐条给结论：

| 方案 | 需要什么 | 本条件下可行性 |
|---|---|---|
| **A. 刷 L1162 固件改 VID/PID/HID 描述符** | 厂商 Bootloader / DFU 入口、固件签名、逆向协议 | **❌ 不可行**。L1162 无公开 DFU，前序硬件探测也未发现可写路径；改 HID 描述符等于重写固件 |
| **B. 中间人代理 USB 流量** | 硬件 USB 中间人（如 Facedancer/Raspberry Pi Pico 冒充 host） | **❌ 不可行**。蓝牙 BLE HID 不经 USB 线，且需要伪造一个完整 USB 设备栈 + 私有 RPC 设备端 |
| **C. 打补丁改 `app.asar` / 注入 Electron** | 破坏代码签名、可能触发 asar integrity 校验、违反 ToS | **❌ 不可行（也不应做）**。任务纪律明确禁止改 `/Applications/ChatGPT.app` |
| **D. 写 DriverKit / IOKit HID 驱动冒充** | 需要 `com.apple.developer.hid.virtual.device`（**Apple 受限 entitlement，需申请审批**）+ 开发者签名 + 系统扩展审批（macOS 上 HID 驱动走 DriverKit + 用户批准） | **❌ 不可行**。本项目是自签 ad-hoc 的菜单栏 App（`scripts/make-app.sh`），拿不到该 entitlement |
| **E. `IOHIDUserDevice`（用户态虚拟 HID 设备）** | 同上 entitlement `com.apple.developer.hid.virtual.device`；且要自己实现设备端：`device.status` / `lights.preview` 等 JSON-RPC 响应 + 主动上报 `AG00`–`AG05` 按键事件 | **❌ 本条件下不可行**（缺 entitlement）。即便拿到，也只是**另造一个假 Codex Micro**，L1162 本体仍不被识别 |
| **F. 直接把按键注入 Codex（本项目现行路线）** | CGEvent / AX API | ✅ **可行**，见第 2 节 |

**私有协议的门槛（实测验证）** —— 即便设备被发现，App 还要能跟它说话：

```bash
$ sed -n '5694,5700p' /tmp/agentctl-research/kit/wl-index.js
```
```js
parseHIDReport(data) {
  const channel = data[1];          // 1 = debug, 2 = rpc
  const length  = data[2];
  const payload = data.slice(3, 3 + length);
  return { channel, length, payload: Buffer.from(payload).toString("utf8") };
}
```

* 64 字节 HID report；`byte[0]`=report id、`byte[1]`=channel、`byte[2]`=长度、`byte[3..]`=UTF-8；
* 换行分隔的 JSON-RPC；已知方法名（`grep -o 'method: "[^"]*"' wl-index.js | sort -u`）：
  `device.status`、`sys.version`、`sys.bootloader`、`sys.selftest`、`lights.preview`、
  `fs.list/read/write/...`、`mp.write_info`、`appmgr.list_active`、`host.focused_app`、`ui.active_screen` 等；
* App 侧连接成功还要求 `device.status` 等 RPC 正常返回（`CodexMicroService` 在
  `setDeviceState({status:'connected'})` 之前会先 `applyLatestLighting()`，失败会降级为 `detected`/`error`）。

按键事件也是私有格式：主进程侧用正则识别 agent 键。

```bash
$ sed -n '236,241p' /tmp/agentctl-micro/service.pretty.js   # 由 service-tYAbfsGu.js 拆行得到
```
```js
handleHidEvent(e){
  ...
  let t=/^AG0([0-5])$/.exec(e.key), n = t==null?null:Number(t[1]);
  ...
}
```

即设备上报的 key 名是 `AG00`…`AG05`（6 个 agent 键，范围由正则 `/^AG0([0-5])$/` 给出，
打包产物里只有 `AG00` 是字面量）/ `ACT06`…`ACT12` / `ENC_CW`·`ENC_CC` 这类**私有字符串**，
不是标准键盘 usage。字面量出现位置（实测验证）：

```bash
$ grep -oE 'AG0[0-5]|ACT[0-9]{2}|ENC_[A-Z]+' /tmp/agentctl-micro/codex-micro-bridge-*.js | sort -u
ACT10
ACT11
AG00
ENC_CC
ENC_CW

$ grep -oE 'ACT[0-9]{2}' /tmp/agentctl-micro/codex-micro-layout-*.js | sort -u
ACT06 ACT07 ACT08 ACT09 ACT10 ACT11 ACT12
```

### 1.5 小结

| 问题 | 答案 |
|---|---|
| L1162 能被 Codex 当作 Codex Micro 接受吗？ | **不能** |
| 需要什么条件？ | VID `0x303A` + PID ∈ {`0x8360`,`0x8297`,`0x8298`} + `usagePage 0xFF00` + 能说私有 JSON-RPC over HID |
| 固件不可改的第三方 BLE HID 手柄有可能满足吗？ | **没有**（VID/PID/usagePage 三项全锁在固件） |
| 伪造需要什么？ | 受限 entitlement 的虚拟 HID 设备 或 改 App（都不被允许/不可得）；刷固件路径不存在 |
| 当前项目条件下 | **不可行**，应当放弃「被识别为 Codex Micro」，走按键注入路线 |

---

## 2. 动作映射：33 个 `keycaps.*` 动作逐条结论

### 2.0 动作清单的真实来源与完整集合

App 里这些 `settings.codexMicro.keycaps.*` 是**键帽槽位/可分配动作的显示名**，真正的执行语义由
`codex-micro-layout-*.js` 里的 keycap → action 定义决定（**实测验证**）：

```bash
$ cd /tmp/agentctl-micro && sed -n '1,140p' layout.pretty.js   # 由 codex-micro-layout-ce53c0b4e6f2.js 拆行
```
```js
s=[
 {id:`FAST`,  action:{type:`command`,command:`composer.toggleFastMode`}},
 {id:`APPR`,  action:{type:`command`,command:`approval.approve`}},
 {id:`REJ`,   action:{type:`command`,command:`approval.decline`}},
 {id:`SPLIT`, action:{type:`command`,command:`forkThread`}},
 {id:`MIC`,   action:{type:`named`,label:`Push to talk`}},
 {id:`MIC1`,  action:{type:`named`,label:`Push to talk`}},
 {id:`CODEX`, action:{type:`command`,command:`composer.submit`}},
 {id:`BUG`,   action:{type:`command`,command:`feedback`}},
 {id:`OAI`,   action:{type:`external-url`,label:`Open OpenAI docs`,url:`https://developers.openai.com`}},
 {id:`TERM`,  action:{type:`command`,command:`toggleTerminal`}},
 {id:`DWN`,   action:{type:`command`,command:`copyConversationMarkdown`}},
 {id:`DEL`,   action:{type:`command`,command:`archiveThread`}},
 {id:`NEW`,   action:{type:`command`,command:`newTask`}},
 {id:`NAV`,   action:{type:`command`,command:`openBrowserTab`}},
 {id:`MAGIC`, action:{type:`command`,command:`toggleThreadPin`}},
 {id:`DIFF`,  action:{type:`command`,command:`toggleReviewTab`}},
 {id:`PLAY`,  action:{type:`command`,command:`environmentAction1`}},
 {id:`GIT`,   action:{type:`command`,command:`git.commit`}},
 {id:`BRCH`,  action:{type:`command`,command:`git.createDraftPullRequest`}},
 {id:`BRANCH`,action:{type:`command`,command:`git.createBranch`}},
 {id:`MRG`,   action:{type:`command`,command:`git.mergePullRequest`}},
 {id:`PR`,    action:{type:`command`,command:`git.createPullRequest`}},
 {id:`PAINT`, action:{type:`command`,command:`composer.addPhotos`}},
 {id:`LAB`,   action:{type:`command`,command:`settings`}},
 {id:`PARTY`, action:{type:`command`,command:`openSideChat`}},
 {id:`TIME`,  action:{type:`command`,command:`manageTasks`}},
 {id:`MIND+`, action:{type:`command`,command:`composer.increaseReasoningEffort`}},
 {id:`MIND-`, action:{type:`command`,command:`composer.decreaseReasoningEffort`}},
 {id:`EMPT1..4`,action:{type:`custom-shortcut`}},
 {id:`SETUP`, action:{type:`command`,command:`settings`}},
 {id:`FOLD`,  action:{type:`command`,command:`openFolder`}},
 {id:`UPL`,   action:{type:`command`,command:`composer.addFiles`}},
 {id:`APPS`,  action:{type:`command`,command:`openSkills`}},
 {id:`YOLO`,  action:{type:`composer-text`,label:`Write :yolo: in the composer`,text:`:yolo:`}},
 {id:`YEET`,  action:{type:`composer-text`,label:`Write :yeet: in the composer`,text:`:yeet:`}},
 {id:`EMPT5`, action:{type:`custom-shortcut`}}
]
```

`*` — 默认布局共 **39** 个键帽槽（实测计数），其中 `EMPT*`/`MIC*` 不是「可分配动作」，是槽位行为。
可分配动作标签（`settings.codexMicro.keycaps.*` 去掉 `.description`）共 **33** 条：

```
addPhotos, approve, apps, attachFiles, automations, branch, bug, codex, custom, customComposerText,
decreaseReasoningEffort, increaseReasoningEffort, delete, download, draftPullRequest, fast, folder,
git, mergePullRequest, navigation, new, oai, pinThread, pullRequest, review, runAction, settings,
sideChat, split, terminal, yeet, yolo
```

> 注：任务描述里给的清单漏了 **`addPhotos`**（`PAINT` 键帽，映射到 `composer.addPhotos`）。

### 2.1 三条外部可触发路径（先讲清楚机制）

#### 路径 ①：默认快捷键（Electron 桌面窗口的 accelerator）

**关键机制（实测验证）**：`browser.defaultKeybindings` **在桌面 App 里不生效**。

```bash
$ python3 - <<'EOF'   # 从 app-initial-9b95fa538c62.js 提取
import re; s=open('/tmp/agentctl-micro/app-initial.js',encoding='utf-8',errors='replace').read()
i=s.find('function lMi('); print(s[i:i+520])
EOF
```
```js
function lMi({commandId:e,windowType:t,keymapState:n,isMacOS:r}){
  if(t!==`electron`){ ... 只有非 electron 才看 browser.defaultKeybindings ... }
  return uMi({commandId:e,keymapState:n,isMacOS:r})   // electron 直接走这里
}
function uMi({commandId:e,keymapState:t,isMacOS:n}){
  ... let i=t?.bindings.filter(t=>t.command===e);       // 1) 用户自定义键位优先
  if(i!=null&&i.length>0){ ... }
  ... 否则回落到 electron.platformDefaultKeybindings.macOS / electron.defaultKeybindings
}
```

推论（**静态推断**）：`searchChats` 的 `CmdOrCtrl+K`、`composer.addFiles` 的 `CmdOrCtrl+U`
都写在 `browser` 段里 → **在桌面 App 上不生效**。这也解释了为什么 `commands.tsv` 里这两条
的「electron 键位」列是空的。

#### 路径 ②：命令面板（`Cmd+K` / `Cmd+Shift+P`）

**实测验证** —— 命令面板确实存在：

```bash
$ python3 - <<'EOF'
import re; s=open('/tmp/agentctl-micro/app-initial.js',encoding='utf-8',errors='replace').read()
i=s.find('{id:`openCommandMenu`'); print(s[i:i+330])
EOF
{id:`openCommandMenu`,descriptionIntlId:`codex.commandDescription.openCommandMenu`,
 electron:{menuTitle:`Open command menu`,menuTitleIntlId:`codex.commandMenuTitle.openCommandMenu`,
 defaultKeybindings:[{key:`CmdOrCtrl+K`},{key:`CmdOrCtrl+Shift+P`}]}}
```

面板 i18n（实测提取）：

| id | 文案 |
|---|---|
| `codex.commandMenu.title` | `Command menu` |
| `codex.commandMenu.dialogDescription` | `Search commands and past chats.` |
| `codex.commandMenu.unifiedSearchPlaceholder` | `Search chats or run a command` |
| `codex.commandMenu.noResults` | `No matches` |

**行过滤机制**：面板用一个 filter 回调做模糊匹配。

```js
// app-initial.js, yAo() 的 <Dialog> 参数
$4.Dialog,{ ..., shouldFilter: ce, filter: mwo, ... }
// mwo(value, search, keywords) = Math.max(m3(value,search), ...keywords.map(...))
// 每行: <l3 value:{title} keywords:[description,...searchKeywords] onSelect={...Tz(r.id,`command_menu`)} />
```

**哪些命令会出现在面板里**（实测验证 + 静态推断）：

* 硬性要求 `kind === 'webview' && commandMenu === true`：

```js
function $ji(e){return e.kind===`webview`&&`commandMenu`in e&&e.commandMenu===!0}
// 面板列表: mG.filter(e => !$ji(e) || ... ? false : hAo(e))
```

* 131 条命令里满足 `commandMenu === true` 的共 **63 条**（实测计数）；
* 另有少数命令（`thread1..9`、`navigateBrowserBack/Forward`）i18n 描述写的是
  "Command menu item …" 但注册表没有该标志位，判定为**运行时动态注册**的行动态项（**静态推断**）；
* 因此「命令面板里一定有某条命令」不能用「它有 i18n 标题」来推，必须看 `commandMenu` 标志位。

**反过来的强证据**：i18n 描述文案把命令分成了两类，措辞泾渭分明（实测提取）：

* 面板项 → `Command menu item to …`
* 仅快捷键设置项 → `Shortcut settings row for …`

#### 路径 ③：Settings → Keyboard Shortcuts 里自行绑定

**实测验证** —— 存在一个可搜索、可逐命令录制快捷键的设置页：

```bash
$ ls /tmp/agentctl-micro/kb-settings.js kb-dialog.js   # 从 asar 提取
/webview/assets/keyboard-shortcuts-settings-10f7592e9ebf.js  (23294 B)
/webview/assets/keyboard-shortcuts-dialog-da1589dfcdde.js    ( 8100 B)
```
```js
// keyboard-shortcuts-settings：U = Rt.filter(t).map(a).sort(kt)   ← Rt 即完整命令注册表
// 每行一个 <快捷键录制控件>，captureAriaLabel = "Shortcut capture for {commandTitle}"
// 提交走 IPC: set-codex-command-keybinding / reset-codex-command-keybindings
//             （state key: `codex-command-keymap-state`）
```
```js
function tMi(e){return !hMi(e) && !(`shortcutConfigurable`in e && e.shortcutConfigurable===!1)}
```

```bash
$ node -e "const r=require('/tmp/agentctl-micro/registry_raw.cjs');
  console.log(r.filter(c=>c.shortcutConfigurable===false).map(c=>c.id))"
[ 'composer.captureAppshot', 'codexMicroSettings' ]
```

即：**除了显式标 `shortcutConfigurable:false` 的两条命令
（`composer.captureAppshot`、`codexMicroSettings`），其余 129 条都可以在设置里绑自定义键。** 绑定后就走 `keymapState.bindings`，
在任何窗口（含 electron）都生效（`uMi` 第一优先级）。

> ⚠️ 这条对项目很重要：第 2.3 节里 C 类动作**不是做不到**，而是**需要用户先在 App 里绑一次键**。

### 2.2 逐条映射表

列含义：**键帽 / 动作标签 / 实际命令 id / macOS 默认键位 / 命令面板可搜到？ / 面板标题（英文原文） / 可达方式**

| 键帽 | 动作标签 | 命令注册表 id | macOS 默认键位 | 命令面板 | 面板标题（= 搜索用原文） | 可达方式 |
|---|---|---|---|---|---|---|
| `FAST` | Toggle Fast mode | `composer.toggleFastMode` | — | ❌ | — | **C**（需自行绑键） |
| `APPR` | Approve | `approval.approve` | `Enter` | ❌ | — | **A**（上下文限定） |
| `REJ` | Reject | `approval.decline` | `Escape` | ❌ | — | **A**（上下文限定） |
| `SPLIT` | Fork chat | `forkThread` | — | ❌ | — | **C** |
| `CODEX` | Send message | `composer.submit` | — | ❌ | — | **C**（另有 composer 内 `Enter`，见注） |
| `BUG` | Open feedback | `feedback` | — | ✅ | `Feedback` | **B** |
| `OAI` | Open OpenAI docs | （非命令）`external-url` | — | — | — | **D**（打开 URL） |
| `TERM` | Toggle terminal | `toggleTerminal` | `` Control+` `` | ✅ | `Open terminal` | **A** |
| `DWN` | Copy chat as Markdown | `copyConversationMarkdown` | — | ❌ | — | **C** |
| `DEL` | Archive chat | `archiveThread` | `CmdOrCtrl+Shift+A` | ✅ | `Archive chat` | **A** |
| `NEW` | New chat | `newTask` | `CmdOrCtrl+N` / `CmdOrCtrl+Shift+O` | ✅ | `New chat` | **A** |
| `NAV` | Open browser tab | `openBrowserTab` | `CmdOrCtrl+T` | ✅ | `Open browser tab` | **A** |
| `MAGIC` | Pin or unpin chat | `toggleThreadPin` | `CmdOrCtrl+Alt+P` | ✅ | `Toggle pin` | **A** |
| `DIFF` | Toggle review | `toggleReviewTab` | — | ❌ | — | **C** |
| `BRCH` | Create draft PR | `git.createDraftPullRequest` | — | ✅ | `Create draft PR` | **B** |
| `BRANCH` | Create branch | `git.createBranch` | — | ✅ | `Create branch` | **B** |
| `MRG` | Merge PR | `git.mergePullRequest` | — | ✅ | `Merge PR` | **B** |
| `GIT` | Commit or push | `git.commit` | — | ✅ | `Commit or push` | **B** |
| `PR` | Create PR | `git.createPullRequest` | — | ✅ | `Create PR` | **B** |
| `PLAY` | Run primary action | `environmentAction1` | `Command+Shift+D` | ❌ | — | **A′**（键位在、处理器未找到，见注） |
| `LAB`/`SETUP` | Open Settings | `settings` | `CmdOrCtrl+,` | ✅* | `Settings` | **A** |
| `PARTY` | Open side chat | `openSideChat` | `CmdOrCtrl+Alt+S` | ✅ | `Open side chat` | **A** |
| `FOLD` | Open folder | `openFolder` | `CmdOrCtrl+O` | ✅ | `Open folder` | **A** |
| `UPL` | Attach files and folders | `composer.addFiles` | —（`Cmd+U` 只在 browser 段） | ❌ | — | **C** |
| `APPS` | Open plugins | `openSkills` | — | ✅ | `Go to skills` | **B** |
| `PAINT` | Add photos | `composer.addPhotos` | — | ❌ | — | **C** |
| `TIME` | Open Scheduled | `manageTasks` | — | ✅ | `Manage scheduled tasks` | **B** |
| `MIND+` | Increase reasoning effort | `composer.increaseReasoningEffort` | — | ❌ | — | **C** |
| `MIND-` | Decrease reasoning effort | `composer.decreaseReasoningEffort` | — | ❌ | — | **C** |
| `YEET` | Write `:yeet:` in the composer | （非命令）`composer-text` | — | — | — | **D**（注入文本 `:yeet:`） |
| `YOLO` | Write `:yolo:` in the composer | （非命令）`composer-text` | — | — | — | **D**（注入文本 `:yolo:`） |
| `EMPT*` | Assign any shortcut | （非命令）`custom-shortcut` | — | — | — | **D**（任意键，纯转发） |
| — | Insert text | （非命令）`composer-text`（自定义） | — | — | — | **D**（注入自定义文本） |

`*` `settings` 在面板里被排除（`e.id==='settings' || mcpSettings || personalitySettings || keyboardShortcuts → false`），
它作为「Settings 分组」另行渲染；实际**用 `Cmd+,` 就行**。

**注 `CODEX`（composer.submit）**：注册表里**没有**默认键位；App 里它是通过
`n0('composer.submit', g, {enabled:_})` 注册的处理器（**实测验证**，见 `app-primary.js`）。
composer 聚焦时的回车提交是组件内部逻辑，不是注册表键位（**静态推断**，未逐字验证按键分发分支）。
因此更稳的做法是给它绑一个自定义键。

**注 `PLAY`（environmentAction1）**：注册表有键位，但**全 App 打包产物里搜不到
`environmentAction*` 的处理器注册**（只在 `app-initial.js` 的注册表和 i18n 里出现）→ 该键位
很可能依赖工作区配置的 environment action 才有意义（**静态推断 / 语义未验证**）。

### 2.3 汇总统计

| 类别 | 数量 | 动作 |
|---|---|---|
| **A. 有 macOS 默认快捷键 → 可直接按键注入** | **11** | approve(`Enter`)、reject(`Escape`)、terminal(`` Control+` ``)、delete(`⌘⇧A`)、new(`⌘N`)、navigation(`⌘T`)、pinThread(`⌥⌘P`)、settings(`⌘,`)、sideChat(`⌥⌘S`)、folder(`⌘O`)、runAction(`⇧⌘D`，语义未验证) |
| **B. 无默认键位，但命令面板可搜到（`⌘K` → 输入标题 → `Enter`）** | **8** | bug、draftPullRequest、branch、mergePullRequest、git、pullRequest、apps、automations |
| **C. 无默认键位、面板也没有 → 需在 Settings→Keyboard Shortcuts 自己绑一次键，之后即可按键注入** | **9** | fast、split、codex、download、review、attachFiles、addPhotos、increaseReasoningEffort、decreaseReasoningEffort |
| **D. 非 Codex 命令机制（注入文本 / 打开 URL / 纯键转发）** | **5** | yeet、yolo、oai、custom、customComposerText |
| **完全不可达** | **0** | — |
| 合计 | 33 | |

> **最重要的修正**：前序调研里写「`toggleFastMode` …只能 `⌘K` 命令面板或点 UI」——**这条是错的**。
> `composer.toggleFastMode` 没有 `commandMenu:true`，i18n 描述是
> `Shortcut settings row for toggling Fast mode`，**它不在命令面板里**。
> 正确路线是 **C 类：在 Settings → Keyboard Shortcuts 里绑一个键**。

### 2.4 逐条证据索引

* 全部 131 条命令的注册表原始数据：`/tmp/agentctl-research/vite/registry_raw.js`
  （`module.exports=[{id,titleIntlId,descriptionIntlId,commandMenu,commandMenuGroupKey,availableIn,shortcutScope,requiredAccess,electron:{menuTitle,defaultKeybindings,platformDefaultKeybindings},browser:{defaultKeybindings}}...]`）
* 派生的 TSV（本次新生成，含解析后的 macOS 键位）：`/tmp/agentctl-micro/registry.tsv`
* keycap → action 默认布局：`/tmp/agentctl-micro/codex-micro-layout-ce53c0b4e6f2.js`（+ 拆行版 `layout.pretty.js`）
* 键帽/动作标签 i18n：`/tmp/agentctl-micro/codex-micro-settings.js`（+ `cms.pretty.js`）
* 命令标题 i18n（面板搜索原文）：`/tmp/agentctl-micro/cmd-titles.json`（130 条）
* HID 事件 → 动作分发：`/tmp/agentctl-micro/codex-micro-bridge-d8b3d2dc46bd.js`（+ `bridge.pretty.js`）

---

## 3. 体验差距：Codex Micro 体验里我们复刻得了什么、复刻不了什么

我们的硬件只有 **6 个数字输入、无 RGB、无摇杆、无旋钮、无屏幕**。

### 3.1 ❌ 复刻不了（硬件能力缺口）

| Codex Micro 体验 | 证据 | 为什么复刻不了 |
|---|---|---|
| **每键 / 每线程 RGB 状态灯** | `RPCApiOAI.sendThreadsLighting(ThreadLighting[])`、`sendLightingConfig({keys,ambient})`、`ThreadLighting{syncKeysLighting,syncAmbientLighting}`；`settings.codexMicro.agentKeyPreview.status.{idle,working,awaitingApproval,awaitingResponse,unread,error,off}` | L1162 **无 RGB**；且这套灯效走设备私有协议（`lights.preview` + OAI 专有 effect 枚举），外部无法驱动 |
| **摇杆模拟输入 + 模拟命令** | `onJoystickMove(JoystickPos{angle,distance})`；`settings.codexMicro.analog.commands.{app,configure,navigation,panels,skills,thread,workspace}`；`analog.direction.{up,down,left,right}` | L1162 十字键是**数字**信号，没有角度/位移；`analog` 的 8 方向可编程语义（"摇杆拨到某方向执行某命令"）需要模拟量 |
| **旋钮（encoder）** | `settings.codexMicro.keyboardLayout.knobByDevice`、`knobTooltip.{turnLeft,turnRight,click,pressAndHold}`、`knob.configureByDevice`；HID key 名 `ENC_CW`/`ENC_CC`/`ENC*` | L1162 没有旋钮 |
| **6 个 agent 键的按线程绑定** | `agentKeys.{pinnedChats,priorityChats,recentChats,customChats,singleTap}`；主进程 `CodexMicroServiceManager.updateAgentThreadKeys(agentThreadKeys, agentKeyKinds, singleTapAgentKeys)`；`agentKeyKinds[slot] === 'recent-thread' \| 'action'` | 这是**设备固件侧**的槽位绑定（`AG00`–`AG05` → 具体 threadKey），并且依赖键帽上的灯/屏显示"哪个键是哪个线程"。我们的 6 键没有显示，也无法让 App 把绑定下发到我们设备 |
| **单击 / 双击 agent 键区分** | 主进程 `HN=350`（ms）双击窗口、`singleTapAgentKeys`、`lastAgentTap` | 属于设备端手势 + 灯效反馈；本项目有自己的手势引擎（`GestureRecognizer`），**语义可以自己实现**，但"App 原生识别"复刻不了 |
| **键帽外观/图标体系** | `codex-micro-layout` 里每个 keycap 带 `icon:`（`lightning-outline`/`check-circle`/`worktree`…）、`size:single\|double` | 纯硬件外观，与我们无关 |
| **麦克风键 / Push-to-Talk / Voice Chat** | keycap `MIC`/`MIC1` → `{type:'named',label:'Push to talk'}`；`realtimeVoice.toggleMicrophoneMute`、`composer.startVoiceMode`、`settings.codexMicro.microphoneKey.{label,description}`、`separateMicrophoneKeys`、`microphoneKeyPushToTalk`/`microphoneKeyVoiceChat` | L1162 无麦克风键；不过 `Ctrl+Shift+V`（`composer.startVoiceMode`）是可用替代（**静态推断**） |
| **设备状态展示**（固件版本/电量/连接态） | `WLDeviceStatus{firmwareVersion,batteryPercentage,isCharging}`；前端 `codexMicro.battery.percentage` / `codexMicro.battery.charging` | 只有 Work Louder 硬件会出现在 UI 里 |
| **固件更新 / 烧录** | `WLDeviceProgrammer.flashDeviceFirmware` + `findWLBootloaderDevices()`；`WLRelease` | 同上，且我们不需要 |

### 3.2 ✅ 可以复刻

| 可复刻项 | 怎么复刻 | 依据 |
|---|---|---|
| **「6 个可编程动作键」的核心体验** | 我们的 6 个输入 → 语义动作 → 键注入。第 2 节里 **33 条动作全部可达**（19 条开箱即用或面板可达，9 条绑一次键，5 条走文本/URL） | 第 2 节 |
| **设备按键 → 命令面板兜底** | 把某个键映射成 `⌘K`，再注入命令标题 + `Enter`。注意：**面板行是可模糊匹配标题的** | `$4.Dialog{filter:mwo}` + `value:{title}`；`cmd-titles.json` |
| **Sticky / 长按 / 双击手势层** | 项目已有 `GestureRecognizer` + `GestureConfiguration`；语义与 Micro 的单/双击思想一致 | `Sources/PocketAgentCore/Gesture/` |
| **每键上下文相关动作**（按前台 App / 当前是否在生成中切换语义） | 项目已有 `ToolProfile` + adapter 设计；Micro 用 `enabled` 门控（如 `composer.queue` 仅在有回复进行中时 enabled）——可以做同构的"上下文守卫" | `app-primary.js`: `n0('composer.queue', S, {enabled:y})`，`y = r&&!i&&!m&&!c&&s==='submit'` |
| **"输入后处理成文本"类动作** | `:yeet:` / `:yolo:` / 自定义 composer text 都只是**往输入框写文本**，CGEvent 注入即可 | `codex-micro-layout`: `{type:'composer-text',text:':yeet:'}` |
| **`custom`（任意快捷键）体验** | 我们自己就是"任意键转发器"，等价甚至更强（可带手势/长按） | — |
| **面板快捷入口（Settings/Terminal/Review/Side chat…）** | 全部有默认键位或面板可达 | 第 2 节 A/B 类 |

---

## 4. 对现有语义动作层的启示

现有 11 个语义动作（`Sources/PocketAgentCore/Domain/AgentAction.swift`）：
`navigateUp/Down/Left/Right`、`submit`、`cancelOrInterrupt`、`queueFollowUp`、
`cyclePermissionMode`、`toggleFastMode`、`openModelPicker`、`inspectChanges`。

### 4.1 与 Micro 动作清单的对等关系

| 现有语义动作 | Micro 动作清单里的对等项 | 落地命令 / 键位 | 证据等级 |
|---|---|---|---|
| `navigateUp/Down/Left/Right` | **无直接对等**（Micro 用摇杆 `analog.direction.*` 表达方向，不是十字键） | 桌面 App 侧仍可用 `↑↓←→`；Micro 侧是 `analog` 模拟量 | 实测验证（Micro 动作清单里无 navigation 类方向动作） |
| `submit` | ✅ `codex`（"Send message"） | `composer.submit`（无默认键位；`⌘↵` 是另一个命令 `composer.submitInBackground`） | 实测验证 |
| `cancelOrInterrupt` | ✅ `reject`（"Reject"） | `approval.decline` = `Escape` | 实测验证 |
| `queueFollowUp` | **不在 Micro 动作清单里**，但 App 里有对应命令 | `composer.queue`（"Queue prompt"，设置页可绑键） | 实测验证（命令与处理器都存在） |
| `cyclePermissionMode` | **❌ 无对等项**（详见 4.3） | — | 实测验证 |
| `toggleFastMode` | ✅ `fast`（"Toggle Fast mode"） | `composer.toggleFastMode`（无默认键位、面板无、**设置页可绑键**） | 实测验证 |
| `openModelPicker` | **❌ 无对等项**（Micro 动作清单里没有 model picker） | `composer.openModelPicker` = `Ctrl+Shift+M` | 实测验证 |
| `inspectChanges` | ✅ `review`（"Toggle review"）/ 相关 `draftPullRequest` 等 | `toggleReviewTab`（无默认键位、面板无、设置页可绑）/ `toggleSidePanel` = `⌥⌘B` | 实测验证 |
| （新增候选）`app` | ✅ `approve` | `approval.approve` = `Enter` | 实测验证 |

**值得注意的反向缺口**：Micro 的动作清单里**没有** `openModelPicker`。也就是说，
"打开模型选择器"在 Codex Micro 的官方体验里**不是一个可分配动作**；
Micro 只给了 `increaseReasoningEffort` / `decreaseReasoningEffort`（`MIND+` / `MIND-`）。
这提示：`openModelPicker` 在 Codex 上属于"能靠默认键位做到，但不属于 Micro 语义集"。

### 4.2 Micro 动作清单里值得我们新增的语义动作

按「性价比 / 影响面」排序（越靠前越建议先做）：

| 优先级 | 建议新增语义动作 | 落地 | 键位 | 为什么值得 |
|---|---|---|---|---|
| 🥇 | `approve` / `reject` | `approval.approve` / `approval.decline` | `Enter` / `Escape` | 目前项目用 `submit`/`cancelOrInterrupt` 复用 A/B 键；显式区分后可以在**审批卡上下文**里给出更明确的动作名与风险等级（`ActionRisk`），并且和 Micro 的 `APPR`/`REJ` 完全对齐 |
| 🥇 | `queueFollowUp`（其实已存在，但被标为「做不到」） | `composer.queue` | 用户自定义键（设置页可绑） | **修正前序结论**：Codex 桌面 App 里 `composer.queue` 是真实命令且有处理器，绑一个键就能用。建议把它从「做不到」升级为「需一次性绑定」 |
| 🥈 | `forkThread`（`split`） | `forkThread` | 自定义键 | 会话分叉是高频操作；Micro 用 `SPLIT` 键 |
| 🥈 | `newChat`（`new`） | `newTask` | `⌘N` | 开箱即用，零成本 |
| 🥈 | `archiveChat`（`delete`） | `archiveThread` | `⌘⇧A` | 开箱即用 |
| 🥈 | `openTerminal`（`terminal`） | `toggleTerminal` | `` ⌃` `` | 开箱即用 |
| 🥈 | `openSideChat`（`sideChat`） | `openSideChat` | `⌥⌘S` | 开箱即用 |
| 🥉 | `attachFiles`（`attachFiles`） | `composer.addFiles` | 自定义键（`⌘U` 只在 browser 段，桌面不生效） | 需要先绑键 |
| 🥉 | `increaseReasoningEffort` / `decreaseReasoningEffort` | `composer.increaseReasoningEffort` / `…decrease…` | 自定义键 | Micro 的 `MIND+`/`MIND-`；对推理预算做细粒度控制 |
| 🥉 | `toggleReviewTab`（`review`） | `toggleReviewTab` | 自定义键 | 与 `inspectChanges` 是同一族，建议合并为一个动作 + 两种落地 |
| — | `copyConversationMarkdown`（`download`） | `copyConversationMarkdown` | 自定义键 | 价值一般 |
| — | `openSkills`（`apps`）、`manageTasks`（`automations`）、`feedback`（`bug`） | 同名命令 | 面板 `⌘K` 可达 | 低频，用面板兜底即可 |
| — | `git.commit` / `createPR` / `createDraftPR` / `createBranch` / `mergePR` | 同名命令 | 面板 `⌘K` 可达，且需 `codexLocal` 与 git 工作区上下文 | 低频高危，建议**保留在面板**，不要给手柄键 |

### 4.3 对 `cyclePermissionMode` 的判断（基于 Micro 动作清单）

**结论：Micro 动作清单从第三个独立角度再次确认 —— Codex 桌面 App 没有「权限模式循环」这个动作。**

三个互相独立的证据链：

1. **131 条命令注册表**：只有 `approval.approve` / `approval.decline`，没有任何
   permission-mode / sandbox-mode / mode-cycle 类命令（**实测验证**）。
2. **Micro 的 33 条可分配动作清单**：只有 `approve` / `reject` 这种**一次性审批**语义，
   没有"切换权限模式"（**实测验证**）。Work Louder 与 OpenAI 一起设计键帽时都没有给出这个动作。
3. **Codex 桌面 App 的审批模型**：审批是**按请求（per-request）** 的 `approve` / `decline`，
   不是"当前会话处于哪种权限档位"的状态机（**静态推断**，与 1、2 一致）。

因此，`cyclePermissionMode` 在 **Codex profile 下应当明确标记为「不支持」**，
而不是保留一个做不到的映射。可选处理：

* 该动作在 Codex profile 下返回明确的"不可用"（与项目 `OutputRecipe` / `ActionRisk` 的
  "做不到"表达能力一致，spec §5 的语义动作层本就允许表达"做不到"）；
* 或者把它在 Codex profile 下重映射为 `approval.approve`（等价于"批准当前请求"），
  但这会**改变语义**，建议不要静默替换，而是在 profile 里显式声明；
* Claude profile 下保留原有的"打开菜单 + 数字选择"路线（那是 Claude 自己的机制）。

---

## 5. 附录

### 5.1 关键结论速查

| 问题 | 结论 | 等级 |
|---|---|---|
| L1162 能被识别为 Codex Micro？ | **不可行**（VID/PID/usagePage 三重硬过滤） | 实测验证 |
| macOS 上 App 用 `WLDeviceDiscovery` 找设备？ | **不用**，用原生插件 `hid-topology-watcher.node` | 实测验证 |
| 有命令面板（`⌘K`）吗？ | **有**，`openCommandMenu`，`⌘K` / `⌘⇧P`，"Command menu" | 实测验证 |
| 面板按标题模糊匹配吗？ | 是（`filter:mwo`，行 `value` = 命令标题） | 静态推断 |
| 面板包含全部命令吗？ | **不包含**，要求 `kind==='webview' && commandMenu===true`（63/131） | 实测验证 |
| 没有默认键位的命令能绑键吗？ | **能**（Settings → Keyboard Shortcuts，`shortcutConfigurable!==false`） | 实测验证 |
| `browser.defaultKeybindings` 在桌面 App 生效吗？ | **不生效**（`windowType!=='electron'` 才看） | 实测验证 |
| 33 条 Micro 动作外部可达？ | 全部可达（11 直接键位 / 8 面板 / 9 需绑键 / 5 文本或 URL） | 见 §2 |
| Codex 有权限模式循环动作吗？ | **没有**（三条独立证据） | 实测验证 + 静态推断 |

### 5.2 本次生成的提取物（均在 `/tmp/agentctl-micro/`）

```text
app-initial.js                                  9.8MB  /webview/assets/app-initial-9b95fa538c62.js
app-primary.js                                  5.3MB  /webview/assets/app-primary-44ec287874b7.js
cms.pretty.js                                          codex-micro-settings 拆行版
codex-micro-bridge-d8b3d2dc46bd.js / bridge.pretty.js   HID 事件 → 动作
codex-micro-layout-ce53c0b4e6f2.js / layout.pretty.js   keycap → command 默认映射
codex-micro-settings.js                                键帽/动作 i18n 标签
kb-settings.js / kb.pretty.js                          Settings → Keyboard Shortcuts
kb-dialog.js / kbd.pretty.js                           Keyboard Shortcuts 弹窗
service.pretty.js                                      service-tYAbfsGu.js 拆行版
manager.txt                                            CodexMicroServiceManager 片段
registry_raw.cjs / registry.tsv                        131 条命令注册表 + 解析结果
cmd-titles.json                                        130 条命令英文标题
zh-CN.js                                               中文语言包
```

### 5.3 复现命令

```bash
A=/Applications/ChatGPT.app/Contents/Resources/app.asar

# 提取 webview 资源
python3 /tmp/agentctl-research/asar.py "$A" extract \
  /webview/assets/codex-micro-layout-ce53c0b4e6f2.js /tmp/agentctl-micro/codex-micro-layout.js

# 原生插件的 VID/PID
otool -tV /Applications/ChatGPT.app/Contents/Resources/native/hid-topology-watcher.node \
  | grep -nE '#0x303a|#0x8360|#0x8297|#0x8298|#0xff00'

# 原生插件匹配字典里的 VendorID 常量
python3 - <<'EOF'
f=open('/Applications/ChatGPT.app/Contents/Resources/native/hid-topology-watcher.node','rb').read()
base=28316; off=base+(0x6f38-0x6e9c)
print(int.from_bytes(f[off:off+4],'little'))   # -> 12346
EOF

# 命令注册表结构化 dump
node -e "console.log(require('/tmp/agentctl-micro/registry_raw.cjs').length)"   # -> 131

# 私有 RPC 方法名
grep -o 'method: \"[^\"]*\"' /tmp/agentctl-research/kit/wl-index.js | sort -u

# 设备端按键名（私有）
grep -oE 'AG0[0-5]|ACT[0-9]{2}|ENC_[A-Z]+' /tmp/agentctl-micro/codex-micro-bridge-*.js | sort -u
grep -oE 'ACT[0-9]{2}' /tmp/agentctl-micro/codex-micro-layout-*.js | sort -u
```

### 5.4 未能验证的点（明确列出，不做结论）

1. **命令面板按标题模糊匹配的具体得分阈值**：只确认了 filter 回调是 `mwo`（`Math.max(m3(value), m3(keywords...))`），
   未运行验证"输入部分标题能否命中"的边界行为。
2. **`environmentAction1`（`runAction`）的真实语义**：注册表有默认键位 `Command+Shift+D`，
   但未在打包产物里找到其处理器注册；实际行为取决于工作区 environment action 配置。
3. **`composer.submit`（`CODEX` 键）在 composer 聚焦时回车提交的具体分支**：未逐字验证按键分发代码，
   仅确认该命令无注册表默认键位、且以 `n0('composer.submit', handler, {enabled})` 注册。
4. **`:yeet:` / `:yolo:` 写入输入框之后的后续处理**（是否有 skill 展开、是否有特殊语义）：
   只确认这两个动作是"插入字面文本"，未验证下游。
5. **`approval.approve`/`approval.decline` 的 `enabled` 门控具体实现**：
   已知它们在"审批卡上下文"生效，未逐行验证门控条件。
