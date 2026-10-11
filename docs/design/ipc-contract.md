# IPC 契约（冻结）

> **状态：FROZEN v1** ｜ 冻结人：Lead ｜ 日期：2026-10-11
> 本文件是 ArkTS 与原生内核之间**唯一的权威契约**。任何一方单独改动即为缺陷。
> 标记约定见 [`AGENT.md`](../../AGENT.md) 第 8 节。

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
| 环路问题 | 原方案依赖 `VpnConnection.protect(fd)`，但 Go 侧**没有任何 hook** 能把自建 socket 交给 ArkTS（见 `docs/design/core.md` §6.5）；改用**把自身包名放进 `VpnConfig.blockedApplications`** 即可让应用自身egress 不回到 TUN，**彻底不需要 `protect()`** |

**结论**：核心只负责「本地 SOCKS/HTTP 入站 → 出站转发」，**不接管 tun**。
tun→SOCKS 的桥接是独立的后续组件（`hev-socks5-tunnel` 纯 C 方案，或打过 `Fstat` 补丁的 gVisor tun2socks）。

> 若将来要回到 tun 直通，必须先在真机上证明 U3，且必须先解决 `protect()` hook ——
> 不得因为"x4h 这么做"就回退。

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
| `CoreService.Start` | `{configLocation, assetLocation, start?, fd?（reserved，不读）, socksPort?, httpPort?}` | `{started, configLoaded, configBytes, wired, socksPort, httpPort, version, notes[]}` | ✅ 已收敛（静态核对）：`fd` 降为 reserved 且不再读取（`golang/service/core/core.go:71-76`）；`socksPort`/`httpPort` 在入参与结果中（同文件 `:87-91`、`:117-121`） |
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
- `wired` = **出站可路由**（本地 SOCKS/HTTP 入站已监听），**不再表示**"tun 入站已挂载"。
- `PingService.Tcping` 是**裸 TCP 握手**，不经过 Xray → 它测的是"设备到目标"的连通性，
  **不是**"该节点能否翻墙"。后者需要核心起来之后另行实现。
- `PingService.SpeedTest` 在本阶段允许返回 `{speedBps: 0}` 并在 `notes` 说明，**但不得填假数据**。

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
> - ❓ **真机未验证**：`wired` 仍恒为 false，没有任何进程真的在监听。

1. ✅ **已落地** `CoreService.Start`：`fd` 已从必填改为可选并标注 reserved、当前不读取
   （`golang/service/core/core.go:70-76`），新增结果字段 `socksPort` / `httpPort`
   （同文件 `:87-91`、`:117-121`）；`wired` 语义见 §4.1（当前恒为 false，因为还没有进程真的监听）。
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

> `MOCK_BRIDGE` **仍必须保持 `true`**，但理由已经变了（2026-10-11 复核）：不再是"原生侧
> 没实现"，而是**没有真机、`libcore.so` 尚未产出、真实链路无法验证** —— 见
> `entry/src/main/ets/core/Bridge.ets` 里 `MOCK_BRIDGE` 的注释。这仍是**正确的当前状态**，
> 且被明确记录。

---

## 6. 真机验证的顺序（与契约的对应关系）

| 步骤 | 调用 | 期望 |
|---|---|---|
| 1 | `VersionService.GetVersion` | 返回真实 Xray 版本 → 证明 dlopen/dlsym/C ABI 全通 |
| 2 | `ValidatorService.ValidateConfig` | 最小 freedom 配置 `valid:true` → 证明 Xray 管线可用 |
| 3 | `CoreService.Start`（`start:false`） | 配置读取与校验通过 |
| 4 | `PingService.Tcping` | 拿到真实 RTT |
| 5 | `CoreService.Start`（`start:true`） | `started:true` 且 `wired:true`、入站端口可连 → **数据面成立** |
| 6 | 端到端 | TUN → tun2socks → SOCKS 出网成功；自身包名在 `blockedApplications` 中，无环路 |

---

## 7. 变更流程

改动本文件即改契约，必须：
1. 同一次提交内改完**四处**：`golang/`、`cpp/`、`types/libbridge/Index.d.ts`、`ets/core/Bridge.ets`；
2. 更新 §4 表格与 `main_test.go` 的 `expectedRoutes`；
3. 在提交信息里写 `contract!:` 前缀或 `BREAKING CHANGE:` 尾注。
