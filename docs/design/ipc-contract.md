# IPC 契约（冻结）

> **状态：FROZEN v2** ｜ 冻结人：Lead ｜ 日期：2026-10-12
> 本文件是 ArkTS 与原生内核之间**唯一的权威契约**。任何一方单独改动即为缺陷。
> 标记约定见 [`AGENT.md`](../../AGENT.md) 第 8 节。
>
> **v2 变更（2026-10-12）：真机验证完成。**
> **§4 的服务目录本身（服务名 / 参数 / 结果）一字未改** —— 只是把"实现状态"那一列从
> "静态核对"升级为"🧪 真机已验证"。改动集中在：
> §2 的防环结论（`protect()` → `protectProcessNet()`）、§4.1 的 `wired` 语义
> （并新增公共事件契约）、§5 的 `MOCK_BRIDGE` 状态、§6 的验证顺序（已完成）。

---

## 0. 为什么需要这份文件

两个并行工作流在没有冻结契约的情况下各自实现，产出了**互不兼容**的两套约定：

| | 服务名形式 | Start 模型 |
|---|---|---|
| 原生侧（`golang/` + `cpp/`） | `Group.Method`（如 `CoreService.Start`） | 传入 tun fd |
| UI 侧（`ets/core/Bridge.ets`） | 无点驼峰（如 `version`、`startCore`） | 本地 SOCKS/HTTP 入站 |

后果：UI 传 `"version"` 会被 `ipc.SplitService` 直接判为非法服务名，**UI 的每一次调用都必然失败**。
本文件即为该问题的裁决。

---

## 1. 裁决一：服务名一律用 `Group.Method`

**理由（非偏好，是硬约束）**：原生侧的 `ipc.Registry` 用 `strings.LastIndex(name, ".")` 拆分服务名，
无点名称直接返回错误信封；且 `main_test.go` 的 `expectedRoutes` 已把该形式固化为黄金列表。

👉 **UI 侧改名，原生侧保持不变。**

## 2. 裁决二：数据面采用「本地 SOCKS/HTTP 入站」模型，不用 tun fd 直通

**这是架构级裁决，依据如下（来自 `docs/research/`）：**

| 证据 | 内容 |
|---|---|
| 🌐 Hey（`popsiclelmlm/Hey`，有真机日志） | **主动放弃**把 tun fd 交给内核：HarmonyOS 的 VPN fd **拒绝 `Fstat`**，导致 gVisor `fdbased` 的 socket 判定失败；且现役 libXray 不再导出 `CGoSetTunFd` |
| 🌐 全部先例（x4h / Hey / Karing / etohos） | 可验证的数据面都是 `TUN → tun2socks → 本地 SOCKS → 核心出站` |
| ❓ x4h 的 tun 直通 | Star 1、README 168 字节、**无人验证**（见 `research/README.md` U3） |
| 环路问题 | 原方案依赖 `VpnConnection.protect(fd)`，但 Go 侧**没有任何 hook** 能把自建 socket 交给 ArkTS（见 `docs/design/core.md` §6.5）。**🧪 真机解法（2026-10-12）**：用官方的 `VpnConnection.protectProcessNet()`（`@since 22`，**进程级、不需要 fd**）作**主手段**，`VpnConfig.blockedApplications`（把自身包名加入）作第二层兜底。证据：内核出站源地址是**蜂窝网卡地址**而非 tun 地址 |

**结论**：核心只负责「本地 SOCKS/HTTP 入站 → 出站转发」，**不接管 tun**。
tun→SOCKS 的桥接由 `hev-socks5-tunnel` 承担（纯 C，MIT）。
🧪 **真机已验证它「能」接管 OHOS 的 vNIC fd** —— 这曾是本项目最大的未知之一。

> 若将来要回到 tun 直通，必须先在真机上证明 OHOS 的 VPN fd 能被 gVisor 的 `fdbased` 接受，
> 且必须先解决 `protect()` 的 hook 问题 —— 不得因为"x4h 这么做"就回退。

---

## 3. 通用约定

### 3.1 C ABI（Go ↔ C++）

```c
char* GoInvoke(const char* service, const char* parameters);  // JSON 进，JSON 出
void  GoFreeCString(char* result);                            // 必须恰好释放一次
```

### 3.2 NAPI（C++ ↔ ArkTS）

```ts
// entry/src/main/cpp/types/libbridge/Index.d.ts
export const Invoke: (service: string, paramsJson: string) => string;
export const CoreAvailable: () => string;   // diag: '' | 'unknown' | 绝对路径
```

### 3.3 信封

```json
{ "success": true,  "result": { }, "error": "" }
{ "success": false, "error": "human readable" }
```

- `success` 恒在；`result` 在失败时**整个字段省略** → ArkTS 侧必须用
  `Bridge.ets#decodeEnvelope` 补齐默认值，**不得直接 `JSON.parse` 后取字段**。
- 返回值恒为合法 JSON，且**永不 panic**（Go 侧 `Registry.Invoke` 与 `GoInvoke` 双重兜底）。

---

## 4. 服务目录（冻结）

`实现` 列标注当前代码的真实状态，**不得把"计划"当成"已实现"**。

| 服务名 | 参数 | 结果 | 实现 |
|---|---|---|---|
| `VersionService.GetVersion` | `{}` | `{version, semver, bridge, go}` | ✅ 原生已实现 |
| `CoreService.Start` | `{configLocation, assetLocation, start?, fd?（reserved，不读）, socksPort?, httpPort?}` | `{started, configLoaded, configBytes, wired, socksPort, httpPort, version, notes[]}` | ✅ 已收敛（静态核对）：`fd` 降为 reserved 且不再读取（`golang/service/core/core.go:71-76`）；`socksPort`/`httpPort` 在入参与结果中（同文件 `:87-91`、`:117-121`）。🧪 真机已验证。**⚠️ `wired` 与 `notes` 不可信**，见 §4.1 |
| `CoreService.Stop` | `{}` | `{stopped}` | ✅ |
| `CoreService.Status` | `{}` | `{running, version, lastError?}` | ✅（`fd` 字段已移除，见 `golang/service/core/core.go:132`） |
| `CoreService.RuntimeInfo` | `{}` | `{socksPort, httpPort, configLocation?, note?}` | ✅ 已实现并注册（`golang/service/core/core.go:154-170`、`:354-387`，注册于 `:425`）。**本行已按实现修正**：原写的 `logPath` 没有数据源，改回 `configLocation`（它确实是"最近一次 Start 读取的配置文件"） |
| `ConfigService.Generate` | `{nodeId, routingMode, extra, assetDir, bypassChina?}` | `{configJson, socksPort, httpPort, outboundTag, protocol, transport, security, geoAssets, notes[]}` | ✅ 已实现（`golang/service/config`） |
| `LogService.Tail` | `{limit}` | `{lines[], count}` | ✅ |
| `LogService.Clear` | `{}` | `{cleared}` | ✅ |
| `PingService.Tcping` | `{host, port, timeoutMs?}` | `{latencyMs, reachable, address, ip?, resolveMs?, error?}` | ✅ 已改名 `latencyMs`（`golang/service/ping/ping.go:57-61`） |
| `PingService.SpeedTest` | `{}` | `{speedBps, notes[]}` | ✅ 已实现为**符合 §4.1 的占位**：`speedBps` 恒 0 + `notes` 说明，不伪造数值（`golang/service/ping/ping.go:167-194`，注册于 `:216`）；真机测速仍未实现 |
| `ValidatorService.ValidateConfig` | `{config?, configLocation?, configPath?}` | `{valid, errors[], inboundTags[], outboundTags[]}` | ✅ |

### 4.1 关键语义

- `CoreService.Start` 的 `start` 缺省 **false** = 只读配置 + 校验，不启动（保留原生侧现有语义，很有用）。
- `wired` 的**契约语义**是「**出站可路由**（本地 SOCKS/HTTP 入站已监听）」，
  **不再表示**"tun 入站已挂载"。
  🔴 **但当前实现里它是坏的**：`golang/service/core/core.go:110-114` 的字段注释与 `:210` 的硬编码
  声称"没有任何入站真的在监听"，而它下面 **20 行**的 `:288-301` 其实**真的启动了 Xray**
  （配置里就含本地 SOCKS/HTTP 入站）。🧪 真机证据：`127.0.0.1:10808 LISTEN` + 20+ 条
  `ESTABLISHED` + 浏览器可正常出网。
  **因此 UI 侧不得采信这个字段**：改为由扩展进程按「内核已启动 **且** tun2socks 已运行」推算，
  经 `VPN_CORE_STATE` 上报（见 §4.2）。与它配套的 `notes` 里那两句同样是错的。
  👉 根治要改 Go 并重编 `.so`，见 [`../../TODO.md`](../../TODO.md) §2.6。
- **🔴 进程边界（最容易写错的一条）**：`libcore.so` **按进程各加载一份**，服务注册表也是各是各的。
  内核跑在 **VPN 扩展进程**里，所以从 **UI 进程**调 `CoreService.Status` / `LogService.Tail`
  只会读到自己那份**从未启动过**的空实例。跨进程状态**只能**走 §4.2 的公共事件。
- `PingService.Tcping` 是**裸 TCP 握手**，不经过 Xray → 它测的是"设备到目标"的连通性，
  **不是**"该节点能否翻墙"。后者需要核心起来之后另行实现。
  ⚠️ 另有一层：本应用在 `VpnConfig.blockedApplications` 里，**自身 egress 本来就绕过 VPN**，
  所以**从应用内测任何域名都验证不了隧道**（`TODO.md` §9.5）。
- `PingService.SpeedTest` 允许返回 `{speedBps: 0}` 并在 `notes` 说明，**但不得填假数据**。仍是占位。

### 4.2 公共事件契约（跨进程，**必须有**）

内核在扩展进程、UI 在另一进程，所以下面两个事件是**契约的一部分**，改动同样要走 §7 的流程。

| 事件 | 发布方 | 参数 | 消费方 |
|---|---|---|---|
| `VPN_TRAFFIC` | `VpnAbility`（扩展进程） | `{TOTAL_UP, TOTAL_DOWN, SPEED_UP, SPEED_DOWN}`（字节 / 字节每秒） | `ets/core/TrafficMonitor.ets` |
| `VPN_CORE_STATE` | `VpnAbility`（扩展进程） | `{CORE_STARTED, CORE_WIRED, CORE_VERSION, CORE_SOCKS_PORT, CORE_HTTP_PORT, CORE_ERROR}` | `ets/core/CoreStateMonitor.ets` |

- 两个事件都用 **emitter + commonEventManager 双通道**订阅：emitter 覆盖同进程调试，
  commonEventManager 覆盖真实跨进程。解码逻辑复用，重复回调只刷新同一份状态。
- 常量定义在 `ets/constants/Common.ets`，**发布端与消费端共用**，不得各自写字面量。
- `CORE_WIRED` 的定义是：**内核已启动 且 tun2socks 已运行** —— 这是对 §4.1 里那个坏字段的替代。

---

## 5. 原生侧待收敛清单（2026-10-11 复核：第 1–7 项已全部落地）

`entry/src/main/golang/` **已不再持有 tun fd**（`fd` 降为 reserved，数据面走 tun2socks）。
逐项落地状态如下（2026-10-11 复核）：

> **证据分级（沿用 `AGENT.md` 第 8 节）**：
> - 🧪 **本机已跑过（不是静态核对）**：`gofmt -l` 空、`go build ./...`、`go vet ./...`、
>   `go test ./... -count=1` 全绿。本机没有 C 编译器，所以这条是 **`CGO_ENABLED=0`** 路径。
> - ⚠️ **`main_test.go`（`//go:build cgo`）在本机编不了**：本机没有 gcc/clang，cgo 包被构建约束整体排除。
>   它现在由 CI 的 `CGO_ENABLED=1` 步骤覆盖（该步先断言 `main.go`/`main_test.go` **确实在编译集里**，
>   再跑 `go test .`），因为在 `CGO_ENABLED=0` 下这个包的编译错误是**隐形**的 —— 历史上就有一个
>   `main.go` 的编译错误这样混进了 `main`（见 `TODO.md` §2.6）。
> - 🧪 **真机已验证（2026-10-12）**：本地 SOCKS/HTTP 入站**确实在监听**（`127.0.0.1:10808 LISTEN`），
>   整条链路跑通。**但内核返回的 `wired` 仍恒为 `false`，且它的说明文字是错的** ——
>   那是内核里的一个真缺陷，见 §4.1 与 [`../../TODO.md`](../../TODO.md) §2.6。

1. ✅ **已落地** `CoreService.Start`：`fd` 已从必填改为可选并标注 reserved、当前不读取
   （`golang/service/core/core.go:70-76`），新增结果字段 `socksPort` / `httpPort`
   （同文件 `:87-91`、`:117-121`）。**`wired` 的实现缺陷**（恒为 false + 说明文字与代码矛盾）
   见 §4.1；UI 侧已改用 `VPN_CORE_STATE` 推算，**不采信这个字段**。
2. ✅ **已落地** `registry/registry.go`：已空白导入 `proxy/socks` 与 `proxy/http`
   （`:45`、`:48`）；`proxy/tun` 的真相与"缺的不是 import"见该文件 `:71-89` 的注释。
3. ✅ **已落地** `PingService.Tcping`：结果字段已是 `latencyMs`（保留 `reachable`），
   见 `golang/service/ping/ping.go:57-61`。
4. ✅ **已落地** 三条路由：`CoreService.RuntimeInfo`（`service/core/core.go:354-387`，
   注册于 `:425-431`）、`ConfigService.Generate`（`service/config/config.go:161`）、
   `PingService.SpeedTest`（`service/ping/ping.go:179-194`，注册于 `:216-220`）。
5. ✅ **已落地**：`main_test.go:29-41` 的 `expectedRoutes` 与 `service/core/core_test.go:36-48`
   的 `contractRoutes` 都已是 **11 条**，与代码实际注册的 11 条路由逐字对应（含
   `ConfigService.Generate`、`CoreService.RuntimeInfo`、`PingService.SpeedTest`），
   并各有一条"排序/漂移即失败"的断言（`main_test.go:43`、`core_test.go:53`）。
6. ✅ **已落地** `CoreService.Status` 已移除 `fd` 字段，见 `service/core/core.go:130-138`。
7. ~~**`ConfigService.Generate` 的 `extra` 语义待确认**~~ **已确认并实现**：
   `extra` = 节点完整字段的 JSON（`model/ServerNode.ets` 的 `NodeJson` / `nodeToJsonText`），
   `nodeId` 仅用于日志与回显 —— Go 侧没有也不应该有节点表。实现见
   `entry/src/main/golang/service/config/{config.go,build.go}`，两侧字段名的守卫是
   `config_test.go` 的 `TestParseNodeMatchesArktsFieldNames`。
   **后续又补了 `bypassChina`（可选）**：只在 `routingMode=rule` 时有意义，
   `true` = 白名单「绕过大陆」（大陆直连、其余走代理），`false` = 黑名单
   （已知被墙走代理、其余直连），对应 v2rayN 的 `Sample/custom_routing_white` /
   `custom_routing_black`。它是 `*bool`：**字段缺失按 `true` 处理**，理由是 ArkTS 侧
   `AppSettings.bypassChina` 的默认值就是 `true`，漏传若退化成黑名单会变成
   "用户以为在绕过大陆、实际不是"的静默降级。这个字段此前在 UI 上存在但**从未传过来**，
   是一个空开关（已修）。

   同批新增的 `assetDir` 参数用于探测 `geoip.dat` / `geosite.dat`：**缺文件时内核会拒绝
   含 `geoip:`/`geosite:` 规则的整份配置**（不是忽略那一条），因此 rule 模式必须先探测
   再决定是否生成按国家分流的规则。结果里的 `configJson` 由 ArkTS 侧落盘
   （`ets/core/ConfigStore.ets`）后交给 `CoreService.Start` 的 `configLocation` ——
   沙箱布局只有 ArkTS 知道，原生侧不掺和。相关 UI 侧说明见 [`ui.md`](ui.md) §5.5。

   **`extra` 的字段清单是活的**（改字段必须两侧同改，守卫测试会拦）。此后新增过一轮
   安全层字段：`pinnedPeerCertSha256` / `verifyPeerCertByName` / `disableSystemRoot` /
   `echConfigList` / `tlsCertificates`，用来替代已被内核删除的 `allowInsecure`
   （`allowInsecure` 本身**保留**在字段清单里，但只做导入兼容、生成时绝不写入）。
   见 [`ui.md`](ui.md) §5.6 与 [`core.md`](core.md) §7.4.5.1。

> `MOCK_BRIDGE` **已置为 `false`（2026-10-12 更正）**。此前写的是"仍必须保持 `true`"，
> 其理由是"没有真机 / `libcore.so` 尚未产出 / 真实链路无法验证" —— **三条全部不再成立**：
> 真机有了、`.so` 已产出并进 HAP、端到端已跑通。
> `NativeBridgeImpl.invoke` 现在真实走 `libbridge.so` → `dlopen("libcore.so")` → `GoInvoke`。
> 见 `entry/src/main/ets/core/Bridge.ets` 里 `MOCK_BRIDGE` 的注释与
> [`../../TODO.md`](../../TODO.md) §3.6。

---

## 6. 真机验证的顺序（与契约的对应关系）—— 🧪 2026-10-12 已全部执行

| 步骤 | 调用 | 期望 | 结果 |
|---|---|---|---|
| 1 | `VersionService.GetVersion` | 返回真实 Xray 版本 → 证明 dlopen/dlsym/C ABI 全通 | ✅ 返回 `26.3.27` |
| 2 | `ValidatorService.ValidateConfig` | 最小 freedom 配置 `valid:true` → 证明 Xray 管线可用 | ✅ |
| 3 | `CoreService.Start`（`start:false`） | 配置读取与校验通过 | ✅ |
| 4 | `PingService.Tcping` | 拿到真实 RTT | ✅（注意：裸 TCP，不经代理） |
| 5 | `CoreService.Start`（`start:true`） | 入站端口**可连** → **数据面成立** | ✅ `127.0.0.1:10808 LISTEN`。⚠️ **期望列原本写的是 `wired:true` —— 这个字段是坏的（§4.1），不能作为判据**；正确判据是端口可连 |
| 6 | 端到端 | TUN → tun2socks → SOCKS 出网成功；自身 egress 不回到 TUN，无环路 | ✅ 浏览器实测可加载网页；内核出站源地址是蜂窝网卡地址 |

> 🧪 **新增的第 7 步（本轮才出现）**：`VPN_TRAFFIC` 与 `VPN_CORE_STATE` 两个公共事件都能
> 在 UI 进程收到，速率与状态显示正确（§4.2）。

---

## 7. 变更流程

改动本文件即改契约，必须：
1. 同一次提交内改完**四处**：`golang/`、`cpp/`、`types/libbridge/Index.d.ts`、`ets/core/Bridge.ets`；
2. 更新 §4 表格与 `main_test.go` 的 `expectedRoutes`；
3. 在提交信息里写 `contract!:` 前缀或 `BREAKING CHANGE:` 尾注。

> **§4.2 的公共事件（`VPN_TRAFFIC` / `VPN_CORE_STATE`）也属于契约**，但它们不跨 C 边界，
> 所以改动面是**两处同改**：`ets/vpnability/VpnAbility.ets`（发布端）与
> `ets/core/{TrafficMonitor,CoreStateMonitor}.ets`（消费端），常量统一放
> `ets/constants/Common.ets`。**改了事件名或参数键就必须两边同时改，并把本节的表一起更新。**
