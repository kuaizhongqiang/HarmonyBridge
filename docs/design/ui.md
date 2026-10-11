# HarmonyBridge UI / 信息架构设计

> 版本：v1（UI 脚手架阶段）
> 参考实现：`third_party/v2rayN`（C# / .NET WPF，GPL-3.0）
> 本文档描述**已落地**的页面结构、分层、状态模型与约定，并明确列出当前仍是 Mock 的部分与真实原生契约。

---

## 1. 页面 / 路由表

采用 **页面路由（UIContext Router）**：`entry/src/main/ets/constants/Routes.ets` 集中定义路由常量，
`entry/src/main/resources/base/profile/main_pages.json` 注册全部页面，
`EntryAbility.onWindowStageCreate` 仍然 `windowStage.loadContent('pages/Index')`。

> 为什么不是 `Navigation` + `NavDestination`：
> 1) 每个页面需要独立入口并注册进 `main_pages.json`，页面路由天然满足；
> 2) 全局 `@ohos.router` 自 API 18 起 deprecated，官方替代 `UIContext.getRouter()` 才是推荐用法，
>    本项目统一走 `this.getUIContext().getRouter()`（见 `RouterHelper`）；
> 3) 页面栈 + 模块级单例 ViewModel 让状态在导航间自然存活（首页 ←→ 节点 ←→ 订阅），无需额外跨页传参。
> 底部 Tab 由 `components/NavigationBar.ets` 实现（首页/节点/订阅/设置），日志页从首页快捷入口进入。

| 路由 | 文件 | 对应 v2rayN | 主要内容 |
| --- | --- | --- | --- |
| `pages/Index` | `pages/Index.ets` | MainWindow + StatusBarView | 当前节点（名称/协议/地址/延迟）、连接-断开大按钮、路由模式、上/下行速率、累计流量、内核版本、四个快捷入口、底部 Tab |
| `pages/NodesPage` | `pages/NodesPage.ets` | ProfilesView + AddServerWindow | 节点列表（协议标签 / 别名 / 地址:端口 / 传输 / TLS / 延迟徽标 / 来源订阅 / 选中高亮）、关键字过滤、排序（默认/名称/延迟 + 升降序）、测试延迟、添加节点、编辑节点、删除、切换当前节点。添加/编辑走底部半屏 Sheet（见 §5.5） |
| `pages/SubscriptionsPage` | `pages/SubscriptionsPage.ets` | SubSettingWindow + 订阅菜单 | 订阅列表（名称 / 地址 / 节点数 / 上次更新 / 上次错误）、新增与编辑弹窗、单条更新、全部更新、启用开关、剪贴板导入 |
| `pages/SettingsPage` | `pages/SettingsPage.ets` | OptionSettingWindow / RoutingSettingWindow / DNSSettingWindow | 路由（模式、大陆直连、自定义规则集）、VPN/TUN（TUN、MTU 滑杆、IPv6、允许局域网）、DNS 与嗅探、分应用代理、日志（级别、写文件）、关于（应用版本、内核版本、许可、仓库） |
| `pages/LogsPage` | `pages/LogsPage.ets` | MsgView | 级别过滤（全部/Debug/Info/Warn/Error）、滚动日志、复制到剪贴板、清空 |

页面之外的文件：

- `vpnability/VpnAbility.ets` —— VPN 扩展（不属于页面，由 `module.json5` 的 `extensionAbilities` 声明）。

---

## 2. 分层结构

```
        ┌──────────────────────────────────────────────┐
        │  UI 层（pages/ + components/）                │
        │  只做渲染 + 把用户意图转发给 ViewModel         │
        │  不出现业务逻辑、不直接读 native              │
        └───────────────┬──────────────────────────────┘
                        │ 读取 @Trace 状态 / 调用 intent 方法
        ┌───────────────▼──────────────────────────────┐
        │  ViewModel 层（viewmodel/）                   │
        │  @ObservedV2 + @Trace，模块级单例              │
        │  NodeViewModel / SubscriptionViewModel /      │
        │  ConnectionViewModel / SettingsViewModel /    │
        │  LogViewModel                                 │
        └───────────────┬──────────────────────────────┘
                        │ 纯数据 / 纯逻辑调用
        ┌───────────────▼──────────────────────────────┐
        │  Service 层（service/）纯逻辑，无 IO 之外副作用│
        │  ShareLinkParser / SubscriptionParser /       │
        │  SubscriptionService(http 拉取) /             │
        │  NodeValidator / JsonHelpers                  │
        └───────────────┬──────────────────────────────┘
                        │
        ┌───────────────▼──────────────────────────────┐
        │  Core 层（core/）                             │
        │  Bridge.ets          ← 唯一接触原生内核的地方  │
        │  TrafficMonitor.ets  ← 订阅 VPN_TRAFFIC 事件   │
        └───────────────┬──────────────────────────────┘
                        │  NAPI（尚未接入）
        ┌───────────────▼──────────────────────────────┐
        │  libbridge.so（另一工作流实现，当前不存在）     │
        │  + VpnExtensionAbility 进程（VpnAbility.ets）  │
        └──────────────────────────────────────────────┘
```

支撑层：

- `constants/`：`Common.ets`（日志域、VPN_TRAFFIC 事件名、Want key、TUN 常量、数据标签）、
  `Routes.ets`（路由常量 + `RouterHelper`）、`Theme.ets`（颜色 `$r('app.color.*')` + 延迟配色规则）、
  `Dimens.ets`（字号 `$r('app.float.*')` + 数值间距）。
- `utils/`：`Logger.ets`（hilog + 回调给 LogViewModel）、`BytesFormat.ets`、`DateFormat.ets`、
  `TextFormat.ets`（`stringOf` / `stringOfArgs`）、`Clipboard.ets`、`Toast.ets`。
- `model/`：`Types.ets`（枚举与基础类型）、`ServerNode.ets`、`Subscription.ets`、`AppSettings.ets`、`LogEntry.ets`。

**依赖方向是单向的**：`UI → viewmodel → service → core`，以及所有层 → `model/constants/utils`。
`core/Bridge.ets` 不依赖任何 viewmodel，`service/` 不依赖 UI，从而保证可单测、可替换。

---

## 3. 状态模型

### 3.1 单例与生命周期

| ViewModel | 单例导出 | 职责 |
| --- | --- | --- |
| `NodeViewModel` | `nodeViewModel` | 节点全量集合、过滤/排序后的 `viewNodes`、选中节点、延迟测试 |
| `SubscriptionViewModel` | `subscriptionViewModel` | 订阅增删改、拉取更新、剪贴板导入；更新成功后调用 `nodeViewModel.replaceNodesOfSubscription` |
| `ConnectionViewModel` | `connectionViewModel` | 连接状态机、流量统计、路由模式；连接时依次调用 Bridge 的三个方法 |
| `SettingsViewModel` | `settingsViewModel` | 扁平设置字段（每项都是 `@Trace`）、快照导出、MTU 夹紧 |
| `LogViewModel` | `logViewModel` | 最近 500 条日志、级别过滤、导出文本 |

因为都是**模块级单例**（`export const xxx = new XxxViewModel()`），页面被销毁重建时状态不丢，
这也是选择「页面路由 + 单例 ViewModel」而不是「把状态挂在 Navigation 栈参数上」的原因。

### 3.2 连接状态机（`ConnectionState`）

```
DISCONNECTED ──connect()──▶ CONNECTING ──成功──▶ CONNECTED
      ▲                          │                  │
      │                          └──失败──▶ ERROR   │ toggle()/disconnect()
      │                                             ▼
      └──────────── 成功 ──────── DISCONNECTING ◀───┘
```

- `connect()`：`Bridge.generateConfig` → `Bridge.connectVpn`（`startVpnExtensionAbility`
  + `context.connectServiceExtensionAbility`）→ `Bridge.startCore`；任一步失败进入 `ERROR`。
- `disconnect()`：`Bridge.stopCore` → `Bridge.disconnectVpn`（断开连接 + `stopVpnExtensionAbility`）。
- 过渡态（`CONNECTING` / `DISCONNECTING`）由 `isBusy()` 暴露，首页大按钮据此禁用，避免重复触发。

### 3.3 流量统计

```
VpnAbility（扩展进程）
   setInterval 1s ──▶ statistics.getIfaceTxBytes/RxBytes('vpn-tun')
                  ──▶ commonEventManager.publish('VPN_TRAFFIC',
                        { TOTAL_UP, TOTAL_DOWN, SPEED_UP, SPEED_DOWN })
                                     │
core/TrafficMonitor ◀────────────────┘（同时监听 emitter，便于同进程调试）
   ──▶ ConnectionViewModel.traffic（@Trace TrafficStats）
   ──▶ 首页 StatCard ×4（字节/秒与累计字节）
```

### 3.4 关键数据流

- **订阅更新**：`SubscriptionsPage → SubscriptionViewModel.updateSubscriptionNow()`
  → `SubscriptionService.fetchAndParseSubscription()`（`@kit.NetworkKit` http）
  → `SubscriptionParser.parseSubscriptionBody()`（base64 / 明文 / Clash 三态识别）
  → `NodeValidator.dedupeNodes + filterValidNodes`
  → `NodeViewModel.replaceNodesOfSubscription()`（按订阅 id 整体替换）。
- **剪贴板导入**：内容若是 `http(s)://` 则新增订阅；否则按分享链接/base64 列表解析成节点，落到
  标签为 `clipboard` 的伪订阅分组下。

---

## 4. 约定

### 4.1 i18n

- 所有用户可见文案放在 `element/string.json`，代码里只用 `$r('app.string.*')` 或
  `stringOf(mgr, 'xxx')`；**`.ets` 中不允许出现中文字符串字面量**（自检脚本已验证为 0）。
- 语言目录：
  - `resources/base/element/string.json` —— 中文（与参考实现一样，中文为默认）
  - `resources/zh_CN/element/string.json` —— 中文（与 base 完全一致，提供显式限定符集合）
  - `resources/en_US/element/string.json` —— 英文
  - `AppScope/resources/{base,zh_CN,en_US}/element/string.json` —— 应用名
- 三套字符串的 **key 集合完全一致**（143 项，脚本校验无差异）。
- 需要运行时拼接本地化文案时用 `stringOf` / `stringOfArgs`：
  之所以不用 `getStringSync(resource: Resource)`，是因为该重载**自 API 20 起已废弃**
  （官方建议 `getStringSync(resId: number)` / `getStringByNameSync(resName: string)`），
  而 `$r()` 返回的 `Resource` 是不透明对象取不到稳定数字 id，故统一用资源名。

### 4.2 主题

- 颜色/尺寸资源：`resources/base/element/color.json`、`float.json`，深色在 `resources/dark/element/color.json`
  （**key 与 base 一一对应**，共 29 个颜色），由系统按深浅色自动选择，代码里不需要条件分支。
- 代码只通过 `constants/Theme.ets`、`constants/Dimens.ets` 引用，禁止硬编码色值与魔法尺寸。
- 延迟配色规则（`Theme.ets`）：
  - `< 200ms` 绿（`latency_fast` / `latency_fast_bg`）
  - `< 500ms` 橙（`latency_medium`）
  - `>= 500ms` 红（`latency_slow`）
  - `0` 未测 / `-1` 超时 → 灰（`latency_unknown`）

### 4.3 ArkTS 严格模式

- 不出现 `any` / `unknown`；不用对象展开、不用动态属性名、不遍历 `Object.keys`、不用 `Function.apply`。
- 所有 `interface` 字段显式声明类型；对象字面量都带显式类型注解的变量接收。
- `import type` 一律用普通 `import`（ArkTS 兼容），只从 `@kit.*` 引入。
- 需要「按 key 取 JSON 值」时走 `service/JsonHelpers.ets`（`jsonStr/jsonStrOr/jsonNum/jsonBool`），
  把不安全的索引访问收敛到一处。

### 4.4 页面结构惯例

- 每个页面：`Column { PageHeader/NavBar, 内容（Scroll 或 List，layoutWeight(1)）, NavigationBar }`。
- 二级页面用 `PageHeader`（带返回），首页与设置页 `showBack: false`（它们是 Tab 顶级页）。
- **标题栏右侧动作不用 `@BuilderParam` 注入**：状态管理 V2（`@ComponentV2`）下把本组件 `@Builder`
  赋给 `@BuilderParam` 字段作为默认值的写法不受支持。`PageHeader` 改为 `trailingText` +
  `trailingEnabled` + `@Event onTrailingTap` 三个受控参数；需要多个动作时页面自己在标题行里画。
- 空态统一用 `components/EmptyState.ets`。
- 表单/选择统一用 `components/OptionPickerDialog.ets`（路由模式 / 分应用模式 / 日志级别）与
  `components/SubscriptionEditDialog.ets`（订阅新增编辑）。选项文案以 `string[]` 传入，
  key 由弹窗内按 `kind` 固定枚举，避免「运行时可变的选项数组 + 弹窗不同步」。
- 节点「添加 / 编辑」用 **底部半屏 Sheet**（`bindSheet` + `components/NodeEditSheet.ets`，
  见 §5.5）。该表单的 20+ 个字段**不放在 Sheet 组件内部**，而是由页面持有一个
  `viewmodel/NodeEditForm.ets` 的 `@ObservedV2` 表单对象、以 `@Param` 传入只读渲染 ——
  这样无论 Sheet 内容是否随开关重建，绑定值一定是最新的，也避免依赖「Sheet 每次打开都重建」
  这一生命周期假设。

---

## 5. 仍是 Mock 的部分 & 真实原生契约

### 5.1 当前 Mock 清单

| 位置 | Mock 内容 | 开关 |
| --- | --- | --- |
| `core/Bridge.ets` | `MOCK_BRIDGE = true`，`MockBridgeImpl` 内存实现全部 service（version/startCore/stopCore/coreStatus/testLatency/generateConfig/…），`NativeBridgeImpl` 在未接入时一律返回失败 | `export const MOCK_BRIDGE` |
| `viewmodel/NodeViewModel.ets` | `buildMockNodes()` 注入 7 个演示节点 | `init()` 内，接入后删除 |
| `viewmodel/SubscriptionViewModel.ets` | `buildMockSubscription()` 注入 1 个演示订阅 | 同上 |
| `viewmodel/ConnectionViewModel.ets` | MOCK 模式下用 `setInterval` 产生模拟速率/累计流量并走 `TrafficMonitor.publish` | `MOCK_BRIDGE` |
| `viewmodel/SettingsViewModel.ets` | 设置只存内存，`save()` 不落盘 | 后续接 `@kit.ArkData` preferences |
| `vpnability/VpnAbility.ets` | 只建网卡 + 上报流量，**不拉起内核** | `TODO(native)` |
| `pages/SettingsPage.ets` 关于区 | 内核版本显示 MOCK 占位；仓库地址写死 | — |

MOCK 模式下首页会显示醒目的「当前为 MOCK 模式」横幅（`$r('app.string.home_mock_banner')`），
便于人工确认当前跑的不是真实内核。

### 5.2 真实原生契约（libbridge.so）

> 状态更新：原生侧（另一工作流）**已经落地** —— `entry/src/main/cpp/CMakeLists.txt` 的
> `add_library(bridge SHARED ...)` 产出 `libbridge.so`，并在
> `entry/src/main/cpp/types/libbridge/Index.d.ts` 声明了导出。本节的表就是**双方共同契约**。

原生模块名：**`libbridge.so`**（NAPI）

```ts
export const Invoke: (service: string, paramsJson: string) => string;
/** 诊断用：'' = 尝试加载过 libcore.so 但失败；'unknown' = 尚未触发惰性 dlopen；其它 = libcore.so 绝对路径 */
export const CoreAvailable: () => string;
```

返回 **JSON 信封**（字符串）：

```json
{ "success": true,  "result": { }, "error": "" }
{ "success": false, "error": "错误描述" }
```

⚠️ 注意失败信封**没有 `result` 字段**（见 `napi_init.cpp` 的 `makeErrorEnvelope`），
所以 ArkTS 侧一律通过 `core/Bridge.ets` 的 `decodeEnvelope(raw)` 收窄（它会补默认值），
**不要**直接 `JSON.parse(raw) as NativeEnvelope` 后就去读 `envelope.result[...]`。

`service` 名称与入参/出参约定（`BridgeService` 常量，禁止改名）：

| service | params（JSON） | result |
| --- | --- | --- |
| `version` | `{}` | `{ "version": string }` |
| `coreStatus` | `{}` | `{ "running": boolean, "pid": number, "version": string }` |
| `generateConfig` | `{ "nodeId": string, "routingMode": string, "extra": string }` | `{ "configPath": string, "assetPath": string }` |
| `startCore` | `{ "configPath": string, "assetPath": string }` | `{ "pid": number, "socksPort": number, "httpPort": number }` |
| `stopCore` | `{}` | `{}` |
| `testLatency` | `{ "address": string, "port": number, "timeoutMs": number }` | `{ "latencyMs": number, "timeout": boolean }`（超时 `latencyMs <= 0`） |
| `testSpeed` | `{ "address": string, "port": number }` | `{ "speedBps": number }` |
| `runtimeInfo` | `{}` | `{ "socksPort": number, "httpPort": number }` |
| `validateNode` | `{ "nodeId": string }` | `{ "valid": boolean }` |

切入真实桥接（两步，`core/Bridge.ets` 顶部注释里同步记录）：

1. 取消 `core/Bridge.ets` 中 `// import bridgeNative from 'libbridge.so';` 的注释；
2. `NativeBridgeImpl.invoke` 里把 `return failure(...)` 换成
   `return decodeEnvelope(bridgeNative.Invoke(service, JSON.stringify(params)));`。

之后把 `MOCK_BRIDGE` 置为 `false` 即整体切到真实内核；两个 ViewModel 里的 Mock 数据函数
（`buildMockNodes` / `buildMockSubscription`）与 `ConnectionViewModel` 的模拟流量定时器可一并删除。

### 5.3 VPN 扩展契约

- 扩展声明（已写入 `entry/src/main/module.json5`）：

```json5
{ "name": "VpnAbility", "srcEntry": "./ets/vpnability/VpnAbility.ets", "type": "vpn" }
```

- 权限：`ohos.permission.INTERNET`、`ohos.permission.READ_PASTEBOARD`（剪贴板导入用，user_grant）。
  **不需要也不可用** `ohos.permission.MANAGE_VPN`（system_basic，普通应用不可申请）。
  > `READ_PASTEBOARD` 是 user_grant 权限：未授权时 `pasteboard.getData()` 抛 201，
  > `utils/Clipboard.ets` 会降级为空串，订阅页提示「剪贴板中没有可用的订阅地址或分享链接」。
  > 完整的运行时授权弹窗（`requestPermissionsFromUser`）留待后续工作流补上。
- 拉起与连接（`core/Bridge.ets` 的 `connectVpn`）：
  `vpnExtension.startVpnExtensionAbility(want)` → `context.connectServiceExtensionAbility(want, options)`；
  `want.parameters` 携带 `CONFIG_PATH` / `ASSET_PATH`。
- 流量事件：`VPN_TRAFFIC`，`parameters = { TOTAL_UP, TOTAL_DOWN, SPEED_UP, SPEED_DOWN }`（字节 / 字节每秒）。
- 设备类型：`["phone", "tablet"]`。

### 5.4 尚未实现（后续工作流）

1. 内核进程的拉起与保活（当前 `VpnAbility.onConnect` 里是 `TODO(native)`）。
2. 测速（`testSpeed`）与 UDP 测试、路由规则集编辑（当前设置里只有开关）。
3. 设置持久化（preferences）与订阅自动更新调度。
4. 分享链接导出 / 二维码（v2rayN 的 `menuAddServerViaScan` / `QrcodeView` 对应能力）。

### 5.5 节点编辑表单（已落地）

入口与形态：

- 入口：`pages/NodesPage.ets` 动作栏的「添加节点」按钮 + 每个节点行的「编辑」文字动作。
- 形态：`bindSheet(this.sheetShown, this.nodeEditSheetContent(), { height: SheetSize.MEDIUM })`
  → 底部半屏、内容可滚动；关闭后 `onDisappear` 回写 `sheetShown = false`（单向 `isShow`，
  不使用 `$$`，避免依赖两向绑定的编译期支持）。
- 组件：`components/NodeEditSheet.ets`（渲染 + 四个内部小结构体 `NodeTextField` /
  `NodeSelectField` / `NodeSwitchField` / `NodeFormSection`）。
- 状态：`viewmodel/NodeEditForm.ets`（`@ObservedV2` + `@Trace`），由页面持有、Sheet 以 `@Param` 只读渲染。
- 选项表：`constants/NodeOptions.ets`，取值逐条对齐 v2rayN `ServiceLib/Global.cs` 与
  `AddServerWindow` 的内联列表（协议 / 传输 / 安全 / raw 伪装类型 / kcp 伪装类型 / XHTTP 模式 /
  gRPC 模式 / 指纹 / flow / VMess 与 SS 加密方式）。

字段集（对齐 v2rayN AddServerWindow，按条件显隐）：

| 分组 | 字段 |
| --- | --- |
| 基础 | 分组（`subscriptionName` == v2rayN 的 `Subid`）、别名、协议、地址、端口 |
| 协议参数 | 用户 ID（含「生成」UUID 按钮）、密码、加密方式、alterId、flow、开启 Mux |
| 底层传输方式 | 传输协议、Host、路径、serviceName、raw 伪装类型、kcp 伪装类型、gRPC 模式、XHTTP 模式、XHTTP extra、Finalmask |
| 传输层安全 | 传输层安全（none/tls/reality）、SNI、Fingerprint、Alpn、跳过证书验证（**已废弃，只告警**）、PublicKey、ShortId、SpiderX |
| 传输层安全（仅 `tls`） | `pinnedPeerCertSha256`、`verifyPeerCertByName`、ECH (`echConfigList`)、`disableSystemRoot`、`certificates`（JSON 文本） |

`ServerNode` 因此新增字段：`muxEnabled` / `rawHeaderType` / `kcpHeaderType` / `grpcMode` /
`xhttpMode` / `xhttpExtra` / `finalmask` / `allowInsecure` / `spiderX`。

### 5.6 传输方式与 TLS：两处对齐 v2rayN 的修正（2026-10-11）

**(a) 传输方式下拉不再提供 `h2` / `quic`。**
`constants/NodeOptions.ets` 的 `TRANSPORT_OPTIONS` 现在与 v2rayN 的
`Global.Networks`（`Global.cs:331-339`）**逐项一致**：`tcp / ws / grpc / httpupgrade / xhttp / kcp`。
本版内核已在 `infra/conf/transport_internet.go:1015-1018` 用 `PrintRemovedFeatureError`
删除了 `h2` / `h3` / `http` / `quic`，把它们留在下拉里等于提供一个必然失败的选项。
`TransportKind.H2/QUIC` 枚举值**保留**，用途只有一个：导入含 `type=h2` 的分享链接时仍能忠实
记录并给出精确报错（`build.go` 返回"已被内核删除，改用 XHTTP stream-one"），而不是静默降级成 tcp。
表单用 `transportOptionsFor(current)`：当前值不在可选列表时把它顶到首位如实显示。
另外 raw 伪装类型只跟着 `tcp` 显示（内核只在 raw/tcp 下读它）。

**(b) `allowInsecure` 被降级为「导入兼容 + 告警」，取而代之的是四个真实字段。**
本版内核在 `2026-06-01` 之后遇到 `allowInsecure: true` 会**直接拒绝整份配置**
（`infra/conf/transport_internet.go:709-716` `PrintRemovedFeatureError`），所以它不是一个
"能生效的开关"。处理方式与 v2rayN 一致 —— v2rayN 的 `NodeValidator.cs:135-144` 也只发
`MsgAllowInsecureDeprecated` 警告、不拦保存，因为它还要负责链接的导入/导出：

- 字段保留在 `ServerNode` 里（分享链接的 `insecure=1` / `pcs` / `vcn` 要能读进来再原样导出）；
- 表单保留开关，但打开时在下方显示告警文案（`node_allow_insecure_deprecated`）；
- 生成配置时一律不写入，并往 `notes` 里追加一条含替代方案名的提示；
- 真正生效的是 `pinnedPeerCertSha256`（链接 `pcs`）/ `verifyPeerCertByName`（`vcn`）/
  `echConfigList`（`ech`）/ `disableSystemRoot` / `certificates`，字段集对齐 v2rayN 的
  `Models/CoreConfigs/V2rayConfig.cs:342-346`。

**(c) 路由分组里新增「分流资源」一行，且「绕过大陆」开关从空开关变成真生效。**
同一批改动（详见 [`core.md`](core.md) §7.4.5.2）：

- 设置页 · 路由 下新增 `settings_geo_assets` 一行：显示 `geoip.dat` / `geosite.dat`
  是否就位与体积，点击即从 `Loyalsoldier/v2ray-rules-dat` 下载（与 v2rayN 的
  `Global.GeoUrl` 同源）到 `<filesDir>/assets`。之所以把这件事前置到 UI：
  资源缺失时 rule 模式会**静默降级**成"私有网段直连 + 其余走代理"，
  只在 `notes` 里留一句话 —— 这是最难排查的那类问题。
- `settings_bypass_cn`（中国大陆域名/IP 直连）这个开关此前**完全无效**：
  `AppSettings.bypassChina` 从没被传进 `generateConfig`。现在它决定 rule 模式
  走白名单（大陆直连、其余走代理）还是黑名单（已知被墙走代理、其余直连），
  对应 v2rayN 的两份预设路由。缺省 `true`（与 `defaultSettings()` 一致）。

> 注意 `pinnedPeerCertSha256` 的内核约束：逗号分隔的每一项必须是 32 字节（64 位十六进制）
> sha256，长度不对整份配置会被拒（`transport_internet.go:717-733`）。我们不做前置校验，
> 靠生成后的 `xcore.LoadConfig` 自检把内核的原话回传（🧪 已在 `config_test.go` 里用反向断言固化）。

**为什么没有单独的「分组名」字段**：v2rayN 的 `ProfileItem` 本身没有组名字符串，它用 `Subid`
表示节点属于哪一份配置项；本项目对应 `subscriptionId` + `subscriptionName`。
表单的分组下拉直接读写这两个字段，避免出现第二份会漂移的分组状态。

同批同步的解析链：

- `service/ShareLinkParser.ets`：`applyQueryOptions` 新增 `headertype` / `mode` / `extra` /
  `insecure|allowinsecure` / `fm|finalmask` / `mux` / `spx`；vmess JSON 的 `type` 按传输方式
  落到 `rawHeaderType` 或 `kcpHeaderType`。
  后续又补了 `pcs`（证书公钥钉扎）/ `vcn`（按名校验证书）/ `ech`（ECH），三个 key 名与
  v2rayN 的 `Handler/Fmt/BaseFmt.cs:67-77,209-211` 完全一致；vmess JSON 侧读 `pcs` / `vcn` /
  `insecure`（`VmessFmt.cs:70-71,146-147`）。
- `service/SubscriptionParser.ets`：Clash 条目新增 `skip-cert-verify` / `client-fingerprint` /
  `alpn` / `header-type`，并把这些字段带进拼接出的分享链接。
- `service/NodeValidator.ets`：去重关键字补上 `sni` / `publicKey` / `shortId`（同一台服务器上不同
  REALITY 站点是不同出站，不应被合并）；新增 `transport == grpc && serviceName 为空` 的校验项。

生成配置链路：`ConnectionViewModel.connect()` 把 `nodeToJsonText(node)`（`model/ServerNode.ets` 的
`NodeJson` 显式结构）作为 `ConfigService.Generate` 的 `extra` 参数发送；返回的 `configJson`
由 `core/ConfigStore.ets` 落盘到 `<filesDir>/core/config.json`，路径再交给 `CoreService.Start`。
该参数的**内容已冻结并实现** —— 原生侧见 `entry/src/main/golang/service/config/`，
两侧字段名的守卫是它 `config_test.go` 里的 `TestParseNodeMatchesArktsFieldNames`；
契约见 [`ipc-contract.md`](ipc-contract.md) §4/§5。

**验证状态**：ArkTS 侧已通过一次**全量 clean 构建**（🧪 2026-10-11，`hvigorw clean` + `assembleHap`
→ `32 executed`，产出 2.4 MB 未签名 HAP，`BUILD SUCCESSFUL`）；原生侧 `go build` / `go vet` /
`go test` 通过（🧪）。

§5.6 这几处修正之后又验过一次（🧪 同日）：`CompileArkTS` **实际执行** 7.29s（不是 `UP-TO-DATE`）
→ `BUILD SUCCESSFUL`，`19 executed / 14 up-to-date`；`go build` / `go vet` / `go test ./...` 全绿，
其中新增的 `TestTlsReplacementFieldsReachStreamSettings` 与 `TestTlsCertificatesJSONIsValidated`
都带**反向断言**（长度非法的 `pcs`、非数组的 `certificates` 必须被拒），避免测试变成空转。

(2) 的 (c) 之后又验过一次（🧪 同日）：`CompileArkTS` 实际执行 4.28s → `BUILD SUCCESSFUL`
（`33 tasks in total: 19 executed, 14 up-to-date`）；`go build` / `go vet` / `go test ./...` 全绿，
新增的 `TestBypassChinaWhitelistRules` / `TestBlacklistRulesWhenBypassChinaOff` /
`TestBypassChinaDefaultsToWhitelistWhenAbsent` / `TestDNSIsSplitOnlyWithGeoAssets` /
`TestGeoEnabledConfigFailsWithoutGeoFiles` 都通过，最后一条是**负向断言**
（含 `geoip:`/`geosite:` 的配置在没有 `.dat` 的目录下必须加载失败），
用来证明 `Options.GeoAssets` 这个开关是载重的而不是保守起见。

**两侧均未在真机上运行过**，上述全部只是"能编译 + 内核 loader 接受这份配置"，
没有任何一条跑过真实流量；下载分流资源这一步同样**未在真机验证**。
