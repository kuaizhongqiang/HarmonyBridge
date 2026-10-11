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
| `CoreService.Start` | `{configLocation, assetLocation, start?}` | `{started, configLoaded, configBytes, wired, socksPort, httpPort, version, notes[]}` | ⚠️ 原生为 fd 模型，待收敛（§5） |
| `CoreService.Stop` | `{}` | `{stopped}` | ✅ |
| `CoreService.Status` | `{}` | `{running, version, lastError?}` | ✅（`fd` 字段随 §5 移除） |
| `CoreService.RuntimeInfo` | `{}` | `{socksPort, httpPort, logPath?}` | ❌ 待实现 |
| `ConfigService.Generate` | `{nodeId, routingMode, extra, assetDir}` | `{configJson, socksPort, httpPort, outboundTag, protocol, transport, security, geoAssets, notes[]}` | ✅ 已实现（`golang/service/config`） |
| `LogService.Tail` | `{limit}` | `{lines[], count}` | ✅ |
| `LogService.Clear` | `{}` | `{cleared}` | ✅ |
| `PingService.Tcping` | `{host, port, timeoutMs?}` | `{latencyMs, reachable, address, ip?, resolveMs?, error?}` | ⚠️ 字段名为 `delayMs`，待改名 |
| `PingService.SpeedTest` | `{}` | `{speedBps}` | ❌ 待实现（**不得伪造测量值**） |
| `ValidatorService.ValidateConfig` | `{config?, configLocation?, configPath?}` | `{valid, errors[], inboundTags[], outboundTags[]}` | ✅ |

### 4.1 关键语义

- `CoreService.Start` 的 `start` 缺省 **false** = 只读配置 + 校验，不启动（保留原生侧现有语义，很有用）。
- `wired` = **出站可路由**（本地 SOCKS/HTTP 入站已监听），**不再表示**"tun 入站已挂载"。
- `PingService.Tcping` 是**裸 TCP 握手**，不经过 Xray → 它测的是"设备到目标"的连通性，
  **不是**"该节点能否翻墙"。后者需要核心起来之后另行实现。
- `PingService.SpeedTest` 在本阶段允许返回 `{speedBps: 0}` 并在 `notes` 说明，**但不得填假数据**。

---

## 5. 原生侧待收敛清单（明确欠债，不是"已完成"）

`entry/src/main/golang/` 当前仍是 **fd 直通模型**。需按下列改动收敛到本契约：

1. `CoreService.Start`：把 `fd` 从**必填改为可选**（保留字段以备将来，注释标明当前未使用），
   新增结果字段 `socksPort` / `httpPort`；`wired` 语义改为"本地入站已监听"。
2. `registry/registry.go`：不再准备 `proxy/tun`，改为空白导入 **`proxy/socks` 与 `proxy/http`**，
   使本地入站真实存在。
3. `PingService.Tcping`：结果字段 `delayMs` → `latencyMs`（保留 `reachable`）。
4. 新增 `CoreService.RuntimeInfo`、`ConfigService.Generate`、`PingService.SpeedTest`。
5. `main_test.go` 的 `expectedRoutes` 同步更新，并**保持"漂移即失败"的严格性**。
6. `CoreService.Status` 移除 `fd` 字段（或标注为 reserved）。
7. ~~**`ConfigService.Generate` 的 `extra` 语义待确认**~~ **已确认并实现**：
   `extra` = 节点完整字段的 JSON（`model/ServerNode.ets` 的 `NodeJson` / `nodeToJsonText`），
   `nodeId` 仅用于日志与回显 —— Go 侧没有也不应该有节点表。实现见
   `entry/src/main/golang/service/config/{config.go,build.go}`，两侧字段名的守卫是
   `config_test.go` 的 `TestParseNodeMatchesArktsFieldNames`。
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

> 在这些改动完成之前，UI 必须保持 `MOCK_BRIDGE = true`。
> 这不是"临时妥协"，而是**正确的当前状态**：契约已冻结，实现尚未跟上，且这一点被明确记录。

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
