# 01 · VPN 能力与权限

> 回答 Lead 问题 1–6。核心结论：**三方 VPN 是公开能力，只需 `ohos.permission.INTERNET` + 用户一次性授权**；`2203001` 与"用户类型"指的是 **GUEST（访客）账户**，不是应用签名或企业资质。

---

## 1. 官方流程与生命周期

### 1.1 模型

OpenHarmony 为三方应用提供的 VPN 能力**只负责两件事**：创建虚拟网卡（vNIC）+ 配置 VPN 路由。**隧道协议与内部连接由应用自己实现**。原文：

> 当前提供三方VPN能力主要用于创建虚拟网卡及配置VPN路由信息，连接隧道过程及内部连接的协议需要应用内部自行实现。
> —— 📄 [net-vpnExtension 官方开发指南](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/network/net-vpnExtension.md)

这直接决定了架构：系统给你一个 tun fd，**数据面（用户态 TCP/IP 栈）必须你自己提供**（tun2socks / 内核自带 tun 栈 / 自写栈）。

### 1.2 module.json5 声明

```json5
"extensionAbilities": [
  { "name": "MyVpnExtAbility", "srcEntry": "./ets/vpnability/VPNExtentionAbility.ets", "type": "vpn" }
]
```

权限：**只需 `ohos.permission.INTERNET`**（📄 同上指南「使用该功能需要 ohos.permission.INTERNET 权限」）。

- ✅ 本地 SDK 已确认 `"vpn"` 是合法 `extensionAbilities.type` 枚举值：`D:\Harmony\DevEco Studio\sdk\default\openharmony\toolchains\modulecheck\module.json` 第 679 / 2086 行的 type 枚举里含 `"vpn"`。
- 📄 指南另有一条历史坑：若 IDE 报「不能识别 `"type": "vpn"`」，需手动在 SDK 的 `toolchains\modulecheck\module.json` 里补枚举并清缓存重启。**本机 SDK 已含该值，无需手工补丁。**

### 1.3 授权弹窗

> 在VPN应用首次启动连接之前，系统会显示VPN连接授权对话框。该对话框会提示用户是否信任该VPN应用并接受VPN连接请求。
> 当VPN启动连接成功时，状态栏显示一个VPN (钥匙) 图标…
> —— 📄 [同指南](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/network/net-vpnExtension.md)

✅ 源码侧印证：授权结果被持久化到 settingsdata，键 `vpnext_mode`，**值为 `"1"` 即视为已授权**，并带进程内缓存（见 §2.2）。

### 1.4 生命周期 —— ⚠️ 与常见说法不一致

| 回调 | 是否在本地 SDK（API 26）声明 | 证据 |
| --- | --- | --- |
| `onCreate(want: Want): void` | ✅ 是，`@since 11` | `@ohos.app.ability.VpnExtensionAbility.d.ts` |
| `onDestroy(): void` | ✅ 是，`@since 11` | 同上 |
| `onConnect(want): Promise<rpc.RemoteObject>` | ❌ **本地 SDK 未声明** | 全 SDK 搜索无 `onConnect`/`onDisconnected` |
| `onDisconnected(): Promise<void>` | ❌ **本地 SDK 未声明** | 同上 |

📄 官方 API 参考同样只列 `onCreate` / `onDestroy`：[@ohos.app.ability.VpnExtensionAbility（三方VPN能力）](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/js-apis-VpnExtensionAbility.md)。

**但**：`arror/x4h` 确实实现了 `onConnect` / `onDisconnected` 并在其中 `create()` 与 `destroy()`（🌐 [VpnAbility.ets](https://github.com/arror/x4h/blob/main/entry/src/main/ets/vpnability/VpnAbility.ets)）。这说明 HarmonyOS 商业版运行时**很可能**提供了这套扩展生命周期，但**未反映在 OpenHarmony API 面**。

> ❓ **推断**：`onConnect`/`onDisconnected` 可能是 HarmonyOS（闭源）侧的能力，OpenHarmony 上游未同步。**风险**：依赖未文档化回调 = 依赖未承诺契约，跨版本可能失效。
>
> ✅ **已验证的替代做法**（推荐）：`popsiclelmlm/Hey` 只用 `onCreate` + `onRequest` + `onDestroy`，在 `onCreate` 里从 `want.parameters` 取配置、**自己 async 启动 VPN**（🌐 [HeyVpnAbility.ets](https://github.com/popsiclelmlm/Hey/blob/main/entry/src/main/ets/vpn/HeyVpnAbility.ets)）。本机 SDK 的 `ExtensionAbility` 基类也未声明 `onRequest`，但它在实现类里存在且项目可发布 → 说明该工程**未开启严格 typeCheck**（`hvigor-config.json5` 中 `typeCheck` 默认为 `false`）。这条路径可在公开 API 面内实现，**建议采用**。

### 1.5 关键生命周期约束（📄 官方）

> 为了保障设备的网络连接，当系统观察到VPN相关应用出现异常时会主动停止VPN连接：
> - 当调用 startVpnExtensionAbility 接口的应用进程退出时。
> - 当VPN服务进程销毁时。
> —— [同指南](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/network/net-vpnExtension.md)

两条工程含义：
1. **主进程不能退出**（必须保活/前台任务），否则 VPN 被拆。
2. **只允许一个 VPN 连接服务**：`目前系统仅支持启动一个VPN连接服务`（📄 同上）；重复启动收到拒绝错误（对应 2203002）。API 20+ 起有 `vpnId` 多 VPN 能力，但 📄 官方注明**当前系统多VPN能力仅支持 IPv4**。

---

## 2. ⭐ 最关键问题：普通应用能否创建 VPN？

**结论：能。不需要系统签名、不需要 `MANAGE_VPN`、不需要 ACL、不需要企业 MDM。置信度：高。**

### 2.1 官方文档层面的权限要求

📄 [net-vpnExtension 指南](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/network/net-vpnExtension.md) 明确只要求 `ohos.permission.INTERNET`。
✅ Lead 已核实：参考实现 `arror/x4h` 的 `module.json5` 只 `requestPermissions: [{"name": "ohos.permission.INTERNET"}]`，**不含 `MANAGE_VPN`**。
✅ 我另行核实 `popsiclelmlm/Hey` 的 `module.json5` 同样**不含 `MANAGE_VPN`**（只含 INTERNET / GET_BUNDLE_INFO / GET_WIFI_INFO / APPROXIMATELY_LOCATION）；`collaborative-creation/etohos` 亦不含。

`MANAGE_VPN` 的定位：✅ 本地 `PermissionDefinitions.json` 中为 `grantMode: system_grant`、`availableLevel: system_basic`、`availableType: SYSTEM` → **普通三方应用无法申请**。

### 2.2 源码层面的真实门禁（✅ 决定性证据）

OpenHarmony VPN 管理器源码 [networkvpn_service.cpp](https://github.com/openharmony/communication_netmanager_ext/blob/master/services/vpnmanager/src/networkvpn_service.cpp) 里的授权链路：

```cpp
// 非系统调用方 → 走 VPN 扩展授权校验
bool NetworkVpnService::CheckSystemCall(const std::string &bundleName) {
    if (!NetManagerPermission::IsSystemCaller()) {
        return CheckVpnExtPermission(bundleName);
    }
    return true;
}

// 有 MANAGE_VPN 就直接放行；否则落到 VPN 扩展授权
bool NetworkVpnService::CheckVpnPermission(const std::string &bundleName) {
    if (!NetManagerPermission::CheckPermission(Permission::MANAGE_VPN)) {
        return CheckVpnExtPermission(bundleName);
    }
    return true;
}

// 真正的门禁：查 settingsdata 的 vpnext_mode 键，值 "1" 视为已授权
bool NetworkVpnService::CheckVpnExtPermission(int32_t uid, const std::string &bundleName) {
    // key = bundleName（SUPPORT_SYSVPN 时为 bundleName + "_" + userId）
    ret = NetDataShareHelperIface::Query(VPNEXT_MODE_URI, key, vpnExtMode);
    if (ret != NETMANAGER_EXT_SUCCESS || vpnExtMode != "1") {
        return false;                     // 未授权
    }
    vpnExtPermissionCache_[key] = true;
    return true;
}
```

其中 `VPNEXT_MODE_URI = "datashare:///com.ohos.settingsdata/...&key=vpnext_mode"`。

**读法**：普通三方应用的通行证就是「用户在授权弹窗点了同意」→ 系统把 `vpnext_mode` 置为 `"1"` → 此后 `create()` / `startVpnExtensionAbility()` 全部放行。**没有出现任何"厂商白名单/审核名单"作为硬门禁。**

> ⚠️ 但源码里**确实存在两个白名单集合**，需澄清其作用（避免过度乐观）：
> `allowConnectVpnBundleName_` 与 `allowVpnStartWithoutCheckPermissions_`，由
> `NotifyAllowConnectVpnBundleNameChanged(...)` 注入；在 `StartVpnExtensionAbility()` 中，
> 只有**命中 `allowConnectVpnBundleName_` 的包**才会被 `ConnectAbilityWithExtensionType` 提前"连接"。
> ✅ 该注入方在 OpenHarmony 仓库内**找不到调用者**（`networkvpn_service_iface.cpp` 只做转发）→
> ❓ 推断：这是给 HarmonyOS 闭源侧（如华为自家 VPN/系统 VPN 常驻服务）使用的**加强通道**，不是三方应用的准入门禁。
> 同时 `IsSetUpReady()` 开头有 `persist.edm.vpn_disable` 参数检查 → 企业 MDM 可**禁用** VPN，但不构成普通设备的准入要求。

### 2.3 `2203001 "please check the user type"` 的真实含义

**不是**"用户类型=企业/白名单"，而是 **GUEST（访客）账户**。

📄 官方错误码文档原文：

> **可能原因**：登录系统的用户类型不匹配，GUEST用户不能调用setUp接口。
> —— [VPN错误码](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/errorcode-net-vpn.md)

✅ 源码印证（[networkvpn_service.cpp](https://github.com/openharmony/communication_netmanager_ext/blob/master/services/vpnmanager/src/networkvpn_service.cpp)）：

```cpp
int32_t NetworkVpnService::CheckCurrentAccountType(int32_t &userId, std::vector<int32_t> &activeUserIds) {
    ...
    AccountSA::OsAccountType accountType;
    if (AccountSA::OsAccountManager::GetOsAccountType(userId, accountType) != ERR_OK) { ... }
    if (accountType == AccountSA::OsAccountType::GUEST) {
        NETMGR_EXT_LOG_E("The guest user cannot execute the VPN interface.");
        return NETWORKVPN_ERROR_REFUSE_CREATE_VPN;   // → 2203001
    }
    return NETMANAGER_EXT_SUCCESS;
}
```

**结论**：2203001 = ①当前登录的是访客账户，或 ②调用方 userId 既不在 `[0, 99]` 也不是活跃用户。
→ **对持有正常华为账号的零售机用户，此错误不应出现。** 置信度：高（📄+✅ 双向）。

### 2.4 社区/实证：真机是否真的可跑

| 项目 | 真机证据 | 可信度 |
| --- | --- | --- |
| Hey | 排查文档记录真机 **ALN-AL80 / HarmonyOS 6.1.0.117(SP6C00E115R4P9) / API 23** 上 VPN 连上且流量走通 | 🌐中（含崩溃栈、型号、版本，细节丰富） |
| Karing HarmonyOS HAP | RELEASE_NOTES：「API 23 模拟器完成…VPN 启动路径检查；**API 26 真机完成安装验证**」 | 🌐中 |
| etohos | 代码含 `deviceInfo.productModel === "emulator"` 分支直接拒绝 → 暗示真机可用 | 🌐中 |
| x4h | README 附真机截图；`process.ProcessManager().exit(0)` 在 `onDestroy` 清理 | 🌐低（README 仅 168 字节，无文字说明） |
| 华为开发者问答 | 「**如何集成vpn功能？**」「**VPN功能开发验证过程中的几个问题**」等提问大量存在，且未见"三方应用不允许"的官方否定答复 | 🌐低（论坛页 JS 渲染，**未能抓取正文**） |

> ❓ **未证实之处（必须实测）**：没有找到任何**华为官方**文字正面承诺"零售机三方应用可创建 VPN"。所有正面证据都来自社区实现与源码推断。请在拿到设备后第一时间验证：`startVpnExtensionAbility` → 弹窗 → `create()` 返回合法 fd ≥ 0。

### 2.5 是否存在 Huawei 审批/白名单流程

| 可能形态 | 结论 | 依据 |
| --- | --- | --- |
| 申请受限权限（如 `MANAGE_VPN`） | **不需要**，也申请不到（system_basic/SYSTEM） | ✅ `PermissionDefinitions.json` |
| ACL（acess control list）提权 | **未发现需要**。VPN 能力不依赖受限权限 | ✅ 三个参考项目均未使用 |
| 企业开发者证书 / MDM 登记 | **不需要**。`ENTERPRISE_VPN`（`@since 26.0.0`）是**另一条**留给 MDM 的路，`availableType: MDM`、`deviceTypes: ["2in1"]` | ✅ 本地 `PermissionDefinitions.json` |
| 应用市场上架资质 | **需要，且基本不可能拿到** | 📄 见 [03 文档](03-合规与上架风险.md) |

**注意别把两件事混淆**：`MANAGE_VPN` / `ENTERPRISE_VPN` 是**给系统应用与 MDM 的**"系统 VPN / 企业 VPN"接口；三方 VPN 走的是 `vpnExtension` 这条完全独立的、公开的、靠用户授权的路。Lead 的本地结论是正确的，此处补上源码级证明。

---

## 3. VpnConfig 字段语义与 API 分级

📄 官方 API 参考：[js-apis-net-vpnExtension.md](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/js-apis-net-vpnExtension.md)（✅ 与本地 `@ohos.net.vpnExtension.d.ts` 一致）

| 字段 | 类型 | 可选 | `@since` | 语义 / 关键限制 |
| --- | --- | --- | --- | --- |
| `addresses` | `Array<LinkAddress>` | 否 | 11 | vNIC 的 IP。**API 23 前最多 64 个；API 23 起最多 2000 个** |
| `vpnId` | `string` | 是 | 20 | 多 VPN 唯一标识（需 `generateVpnId()`）。**系统多 VPN 能力当前仅支持 IPv4** |
| `routes` | `Array<RouteInfo>` | 是 | 11 | 路由。**API 23 前最多 1024 条；API 23 起最多 10000 条** |
| `dnsAddresses` | `Array<string>` | 是 | 11 | ⚠️ **不是"系统级 DNS"**。原文：配置后"**被代理的应用**上网时"使用该 DNS 查询 |
| `searchDomains` | `Array<string>` | 是 | 11 | DNS 搜索域 |
| `mtu` | `number` | 是 | 11 | **取值范围 [576, 1500]** |
| `isIPv4Accepted` | `boolean` | 是 | 11 | 默认 `true`。**若为 true 必须在 `addresses` 里配 IPv4 地址** |
| `isIPv6Accepted` | `boolean` | 是 | 11 | 默认 `false`。**若为 true 必须在 `addresses` 里配 IPv6 地址** |
| `isInternal` | `boolean` | 是 | 11 | "是否支持内置 VPN"，默认 `false` |
| `isBlocking` | `boolean` | 是 | 11 | "是否阻塞模式"，默认 `false` |
| `trustedApplications` | `Array<string>` | 是 | 11 | 包名列表。配置后**仅列表内应用**按 `routes` 被代理。**API 23 前 ≤64，23 起 ≤256** |
| `blockedApplications` | `Array<string>` | 是 | 11 | 包名列表。列表内应用**不被代理**，其余按 `routes` 代理。同上限额 |

### 3.1 `isInternal` / `isBlocking` —— 官方只有一句话

📄 官方对二者的描述**仅有一句中文**（"是否支持内置VPN" / "是否阻塞模式"），**没有进一步语义定义**。

> ❓ **未证实**：我**没有**找到 `isInternal`、`isBlocking` 的权威行为定义、默认值来源或推荐取值。
> 可以确定的只有：默认均为 `false`；两个参考实现（x4h、Hey）在 `VpnConfig` 里**都没有设置这两个字段**（即用默认 `false`）。
> **建议**：初期沿用默认；若遇到 tun 读写阻塞语义问题再单独排查，不要凭猜测设置。

### 3.2 trustedApplications / blockedApplications（per-app 代理）—— 实测语义

📄 官方语义同上表，且**二者互斥，不能同时配置**。

🌐 真实实现给出的工程细节（[Hey `VpnConstants.ets`](https://github.com/popsiclelmlm/Hey/blob/main/entry/src/main/ets/vpn/VpnConstants.ets)，可信度中）：

```ts
if (!perAppEnabled || selectedApps.length === 0) {
  blockedApps = [selfBundle];            // 默认：屏蔽自己，防路由环路
} else if (bypassMode) {
  blockedApps = [selfBundle, ...selectedApps];   // 绕过模式
} else {
  trustedApps = selectedApps;            // 仅代理模式：把自身包名从列表剔除
}
```

三条可复用经验：
1. **必须把自己包名放进 `blockedApplications`**（或在 trusted 模式下确保不在 trusted 列表里），否则核心的出站连接会被自己的 VPN 抓回来 → 环路。
2. `trustedApplications` 与 `blockedApplications` **不能同时设置**，代码必须二选一。
3. 🌐 per-app 页面**无法枚举已安装应用**：Hey README 明确写「HarmonyOS NEXT 不向外三方应用暴露通用的已安装应用枚举路径」，只能让用户手工输入包名（可信度中）。这会影响"像 v2rayN 一样按进程分流"的 UI 设计。

---

## 4. tun fd 契约

### 4.1 返回的是什么

📄 `VpnConnection.create(config)` 的返回值定义：

> `Promise<number>`：以 Promise 形式返回获取结果，返回**指定虚拟网卡的文件描述符 fd**。
> —— [js-apis-net-vpnExtension.md](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/js-apis-net-vpnExtension.md)

✅ 本地 SDK 英文注释同义：`Promise used to return the result, which is the file descriptor of the virtual network interface card (vNIC).`

**性质**：这是**虚拟网卡（TUN）设备的 fd**，可 `read`/`write`（readv/writev）IP 包。

### 4.2 接口名 = `vpn-tun`（✅ 双源确认）

📄 官方示例注释原文：

```ts
routes: [{
  // VPN虚拟网卡接口名固定为“vpn-tun”。
  interface: 'vpn-tun',
  ...
}]
```

- ✅ x4h 用 `statistics.getIfaceTxBytes('vpn-tun')` / `getIfaceRxBytes('vpn-tun')` 读流量计数。
- ✅ Hey 定义 `export const VPN_INTERFACE_NAME: string = 'vpn-tun';`
- ✅ etohos 里 Rust 侧配置 `dev_name = "vpn-tun"`。

→ **`vpn-tun` 是硬编码约定，三方应用可据此读内核网卡计数器做流量统计**（这是最省事的流量统计方案）。

### 4.3 怎么把 fd 交给核心 —— 两条路线，各有代价

| 路线 | 做法 | 代价 / 风险 |
| --- | --- | --- |
| **A. 直接交给核心** | `create()` 拿 fd → 通过 NAPI 传给 Go 侧 → 核心用 tun inbound（Xray `proxy/tun` + `platform.TunFdKey`，或 `CGoSetTunFd`） | ❌ HarmonyOS VPN fd **拒绝 `Fstat`**，gVisor `fdbased` endpoint 的 `isSocketFD()` 判socket 会失败，**必须打补丁**；且现役 libXray **不再导出** `CGoSetTunFd`（🌐 [Hey building-native-cores §3.1](https://github.com/popsiclelmlm/Hey/blob/main/docs/building-native-cores.md)）。**无已证实的成功案例。** |
| **B. tun2socks（推荐）** | fd → tun2socks（gVisor 或 hev-socks5-tunnel）→ 本地 SOCKS 入站 `127.0.0.1:PORT` → Xray/sing-box outbound | ✅ 核心只需提供 SOCKS 入站，与协议栈解耦；代价是多一层用户态转发（性能/内存）。🌐 Hey 与 etohos 均走此路。**有真机跑通记录。** |

> 🔎 **重要架构结论**：`arror/x4h` 走的是路线 A（`Core.run({fd: fd, ...})`，把 fd 交给 Go），
> 而**最完整的 Hey 项目明确放弃了 A、回到 B**。因此"把 tun fd 直接交给 Xray tun inbound"
> 这条最优雅的路线，**目前没有可复现的公开成功案例**。Lead 若以此为路线前提，风险较高。

### 4.4 `protect(socketFd)` —— 为什么是强制的

📄 官方定义：

> 保护套接字不受VPN连接影响，通过该套接字发送的数据将直接基于物理网络收发，因此其流量不会通过VPN转发。
> —— [js-apis-net-vpnExtension.md](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/js-apis-net-vpnExtension.md)

**必须调用的原因（环路预防）**：VPN 起来后默认路由指向 `vpn-tun`。核心要连真实服务器，如果这个 socket 也被抓进 tun，就形成
`核心出站 → tun → 核心自己 → tun → …` 的无限递归，表现是"核心已启动但流量/连接数始终为 0"（🌐 Karing RELEASE_NOTES 1.11.0 正好记录了修复「套接字绕过 VPN 失败仍被当作成功…核心已启动但手机没有真实代理流量」，可信度中）。

两类保护 API：
- `protect(socketFd: number)`（`@since 11`）：按 socket 保护。📄 参数需由 `socket.TCPSocket.getSocketFd()` 获取。
- `protectProcessNet(): Promise<void>`（`@since 22`）：**按进程**保护整个应用进程的网络不过 VPN。**在三方 VPN 场景里更实用**——一次性保护核心/隧道进程，不必逐个 socket 处理。

> 设计含义：如果采用「VPN 扩展进程内加载核心」（即路线 A/B 都在同进程），用 `protectProcessNet()`
> 就能一次解决；但若核心跑在 `childProcessManager` 子进程，是否继承保护**未证实**（见 [02 文档 §替代路线](02-核心移植方案.md)）。

### 4.5 错误码速查

| 错误码 | 消息 | 含义 |
| --- | --- | --- |
| 2200001 | Invalid parameter value | 参数越界（如 mtu 不在 [576,1500]、routes 超限） |
| 2200002 | Failed to connect to the service | VPN SA 异常 |
| 2200003 | System internal error | 内部错误 |
| **2203001** | **VPN creation denied, please check the user type** | **GUEST 用户 / 非活跃 user** |
| 2203002 | VPN exist already, please execute destroy first | 已有 VPN，先 `destroy()` |
| 2203004 | Invalid socket file descriptor | `protect()` 传入的 fd 无效（tcp 链路未建立） |
| 19900001/19900002 | Invalid parameter / System internal error | `generateVpnId()` / `destroy(vpnId)` 专用 |

📄 来源：[errorcode-net-vpn.md](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/errorcode-net-vpn.md)

---

## 5. 实用约束汇总

### 5.1 MTU

- 📄 合法区间 **[576, 1500]**。
- 实践值：📄 官方示例 `1400`；x4h 与 Hey 用 `1400`/`1500`（Hey `DEFAULT_VPN_MTU`）；etohos 写死 `1500`。
- ❓ 没有官方推荐值。考虑到多一层 tun2socks 与协议封装开销，**建议 ≤1400** 并在真机测分片。

### 5.2 DNS：**不是系统级**

⚠️ 这是最容易误解的一点。📄 官方原文限定语是**"被代理的应用上网时"**：

> `dnsAddresses`: DNS服务器地址信息。配置DNS服务器地址后，VPN启动状态下，**被代理的应用**上网时，使用配置的DNS服务器进行DNS查询。

→ **不是** Android `VpnService` 那种"设置系统 DNS 就全局生效"。因此：
- 只有进入 VPN 的应用的 DNS 查询会走 `dnsAddresses`；
- 未进入 VPN 的应用仍用物理网卡 DNS → **存在 DNS 泄漏面**；
- 🌐 Karing 1.11.0 的修复记录印证了这个坑：「订阅节点域名解析进入本地 DNS 自引用的问题。VPN 创建前使用系统网络解析节点域名，并注入静态 DNS 映射」（可信度中）——即核心自己解析节点域名时必须**绕开**自己搭建的 DNS。

### 5.3 IPv6

- 📄 默认 `isIPv6Accepted: false`；开启时必须在 `addresses` 里配 IPv6 地址。
- ✅ 本地 SDK 强调同一句 Note。
- 🌐 **实战坑（Hey `VpnConstants.ets`，可信度中）**：要让 `::/0` 真的装到 TUN 上，需要用「**空 gateway + `isDefaultRoute: false`**」的写法，否则全局 v6 会从物理网卡直出**泄漏**。Hey 的做法是**始终接管 v6**（不论用户开关），再由核心决定转发还是 blackhole。这是一条高价值经验。
- 📄 多 VPN（`vpnId`）能力**仅支持 IPv4**。

### 5.4 进程模型

- ✅ **`VpnExtensionAbility` 运行在独立进程**：🌐 Hey 的崩溃栈明确显示进程名 `com.lmlm.hey:vpn`（`VPN_EXTENSION_LABEL = ":vpn"` 在源码里也出现），且注释直接写「VPN 扩展进程持续存活」「VPN 扩展进程后台存活」。可信度中高。
- ✅ x4h 在 `onDestroy()` 里调 `process.ProcessManager().exit(0)` —— 与"独立进程"判断一致：销毁时把整个扩展进程结束掉，避免残留。
  > ❓ 但**没有官方文档**说明"必须在 onDestroy 里 exit(0)"。Hey 的做法是**不 exit**，只做幂等 `cleanup()`（停 tun2socks/核心/`destroy()`）。**建议采用 Hey 的幂等清理**，不要无条件 `exit(0)`（可能影响进程复用与快速重连）。
- 🌐 有价值的副作用：VPN 扩展进程是「HarmonyOS 唯一会在后台保活的组件」（Hey 注释），因此**后台轮询/定时器应放在扩展进程内**，而不是主进程。

### 5.5 VpnExtensionAbility 内**禁止**引用的模块（📄 官方明确列出）

> 以下模块**不支持在VpnExtensionAbility中引用，可能会导致程序异常退出**：
> - `@ohos.contact`（联系人）
> - `@ohos.geolocation`、`@ohos.geoLocationManager`（位置服务）
> - `@ohos.multimedia.audio`（音频管理）
> - `@ohos.multimedia.camera`（相机管理）
> - `@ohos.telephony.call`（拨打电话）
> - `@ohos.telephony.sim`（SIM卡管理）
> - `@ohos.telephony.sms`（短信服务）
> —— [js-apis-net-vpnExtension.md](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-network-kit/js-apis-net-vpnExtension.md)

**工程含义**：VPN 扩展进程**要按"精简运行时"设计**——不能在里面做位置/音频/相机/电话/SIM/短信相关逻辑。这与"网络场景自动化"功能冲突：Hey 用 `NetworkProbe` 在扩展进程里读网络上下文/SSID，**避开了 `@ohos.geoLocationManager` 与 `@ohos.multimedia.audio`**。若需要位置类信息，应放在主进程获取后通过 `want.parameters` 传进来。

---

## 6. 待验证清单（真机）

1. 零售机 + 普通华为账号：`startVpnExtensionAbility` 是否弹窗？授权后 `create()` 是否返回 fd ≥ 0？→ 排除 2203001。
2. `onConnect` / `onDisconnected` 在本机运行时是否被调用？（打印 hilog 验证）→ 决定生命周期架构 A/B。
3. `protectProcessNet()` 是否保护到同进程内的 Go 核心？子进程是否继承？
4. `isInternal` / `isBlocking` 置 `true` 的实际行为。
5. `dnsAddresses` 对未进入 VPN 的应用是否真的不生效（DNS 泄漏实测）。
6. per-app 模式 + 自身包名 blocked 后，环路是否消失。

*本文档所有 ❓ 条目均无权威来源，请勿在 Lead 的可行性结论中作为既定事实引用。*
