# AGENT.md — HarmonyBridge 智能体作业手册

> 本文件是本仓库的**唯一权威作业约定**。任何 AI 智能体（以及新加入的人类开发者）在动手之前必须先读完本文件。
> 版本：**v2（2026-10-12）**｜适用 API 基线：`compatibleSdkVersion 6.1.1(24)` / `targetSdkVersion 26.0.0` / HarmonyOS
>
> v2 相对 v1 的变化：真机验证已完成（`libcore.so` / `libhevsocks5tun.so` 已编出、端到端链路已跑通）。
> v1 里"没有真机 / 工具链受阻 / 不可声称已验证"的边界**已作废**，见第 1 节。

---

## 0. 一句话说明

**HarmonyBridge 是 v2rayN 的鸿蒙原生版本**：一个 ArkTS 前端 + Xray-core 原生代理内核，通过 HarmonyOS 的
`VpnExtensionAbility` 把内核接入系统 VPN 通道，让手机上的流量按规则走代理。

参考实现：`third_party/v2rayN`（只读 submodule，C#/WPF，GPL-3.0）。

---

## 1. 当前阶段与作业边界（最重要的一节）

项目已进入**真机可运行**阶段。作业边界如下：

| 条件 | 状态 | 对作业的约束 |
|---|---|---|
| 鸿蒙真机 | ✅ **有**：HUAWEI `TYR-AL00`（nova 14 活力版），`6.1.0.145(C00E120R2P5)`，API 24 | **已做过的事可以声称"已验证"，但必须附第 8 节的证据标记与命令/日志出处** |
| `libcore.so` | ✅ **已产出**（约 34.5 MB，Xray-core 26.3.27，ELF64/AArch64），见第 2.2 节 | 不要再写"工具链受阻" |
| `libhevsocks5tun.so` | ✅ **已产出**（约 287 KB），已接管真机 vNIC fd | 同上 |
| 端到端链路 | ✅ **已跑通**：TUN → tun2socks → 本地 SOCKS → 内核出站 | 结论可直接引用，出处见 `README.md` 的验证表 |
| 鸿蒙模拟器 | ⚠️ 有，但 VPN 能力大概率不可用 | 不得把模拟器当作 VPN 链路验证手段 |
| DevEco Studio | ✅ 26.0，位于 `D:\Harmony\DevEco Studio` | 可以用它查 SDK、查 API 定义 |
| HarmonyOS SDK | ✅ `D:\Harmony\DevEco Studio\sdk\default\openharmony` | **查 API 以本地 SDK 的 `.d.ts` 为准，不要凭记忆** |
| `ohpm` / `hvigorw` / `java` | ⚠️ 未加入 `PATH`，需用 DevEco 内置路径 | 不得假设直接敲命令就能构建 |
| Go | ✅ 1.26.4，`C:\Program Files\Go` | `go tool dist list` **没有** `ohos` 目标 —— 但项目已自建工具链，见第 2.2 节 |

**允许产出的东西：**
✅ 仓库结构、配置、流水线、脚本、依赖声明
✅ 文档、架构设计、可行性论证、风险清单
✅ 可静态审查的代码（ArkTS 页面、NAPI 桥、Go 服务层、C 数据面）
✅ **真机上实际跑出来的验证结论**（附命令与日志）

**不允许产出的东西：**
❌ 未执行的结论（"应该能行"不许写成"已验证"）
❌ 提交任何构建产物（`*.so` / `*.hap` / `*.hsp`）
❌ 提交任何签名材料、证书、私钥
❌ **提交任何真实节点的地址 / 端口 / UUID / REALITY 公钥**（见第 9 节）
❌ 未经许可决策就把 GPL 代码搬进本仓库

> **诚实性要求**：如果一件事没做，就写"未做"；如果只是推断，就写"推断"并给出依据。
> 本仓库的文档使用了统一的证据标记，见第 8 节，请沿用。

---

## 2. 已核实的技术路线（本项目的技术基石）

这条路线的**可行性已在本地 SDK、真机日志与一个可工作的开源参考实现上三方核实**。

### 2.1 系统侧：第三方 VPN 走 `vpnExtension`，不需要系统签名

本地 SDK 证据（请自行打开确认，不要采信二手描述）：

- `D:\Harmony\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.net.vpnExtension.d.ts`
  - 声明 `@syscap SystemCapability.Communication.NetManager.Vpn`，`@since 11`
  - 关键 API：
    - `startVpnExtensionAbility(want)` / `stopVpnExtensionAbility(want)` — 拉起/停止 VPN 扩展
    - `createVpnConnection(context): VpnConnection` — 建立 VPN 连接对象
    - `VpnConnection.create(config): Promise<number>` — **返回虚拟网卡（vNIC）的文件描述符**
    - `VpnConnection.protectProcessNet()`（`@since 22`）— **让本应用进程的 egress 绕过 VPN**。
      这是本项目的**防环主手段**（进程级、不需要 fd）。
    - `VpnConnection.protect(socketFd)` — 让**单个 socket** 绕过 VPN。本项目数据面不用它（拿不到
      hev / Go 内部 socket 的 fd），改用上面那个进程级接口。
    - `VpnConnection.destroy()` / `destroy(vpnId)`（`@since 20`）、`generateVpnId()`（多 VPN，仅 IPv4）
    - `createVpnObserver()` + `VpnObserver.onAuthorizationResult()`（`@since 26.0.0`）— 用户授权弹窗结果回执。
      ⚠️ **`.d.ts` 里有，真机运行时没有**：调用会抛 `createVpnObserver is not callable`。所以必须
      `try/catch` 并如实记日志 —— **"能编译" ≠ "API 存在"**，见第 3.1 节规则 16。
  - `VpnConfig` 能力：`addresses`、`routes`、`dnsAddresses`、`searchDomains`、`mtu`（576–1500）、
    `isIPv4Accepted`、`isIPv6Accepted`、`isInternal`、`isBlocking`、`trustedApplications`、`blockedApplications`（按应用分流）
  - 官方注释原文要点：**"the connection tunnel process and internal connection protocols need to be implemented by the applications themselves"**
    —— 系统只给你虚拟网卡和路由配置，**隧道协议要自己实现**。这正是 v2rayN 的模型，因此本项目路线成立。
  - 官方注释另一要点：**`want.parameters` 只在"首次启动 VPN"时被传递**（`:78`）。因此扩展进程
    **不能**依赖 want 里的路径，必须自己从 `context.filesDir` 推算（见第 2.4 节）。

- `D:\Harmony\DevEco Studio\sdk\default\openharmony\toolchains\lib\PermissionDefinitions.json`
  - `ohos.permission.MANAGE_VPN`：`grantMode: system_grant`、`availableLevel: **system_basic**`、`availableType: SYSTEM`
  - `ohos.permission.ENTERPRISE_VPN`（`@since 26.0.0`）：`system_basic`、`availableType: MDM`、仅 `2in1`
  - 👉 **普通三方应用拿不到 `MANAGE_VPN`**，也**不需要**它。三方 VPN 走的是
    `VpnExtensionAbility` + **用户授权弹窗** 的路径（错误码 `2203001 - VPN creation denied, please check the user type`）。

- 声明方式（`entry/src/main/module.json5`）：
  ```json5
  "requestPermissions": [{ "name": "ohos.permission.INTERNET" }],
  "extensionAbilities": [
    { "name": "VpnAbility", "srcEntry": "./ets/vpnability/VpnAbility.ets", "type": "vpn" }
  ]
  ```
  注意：**只有 `INTERNET`，没有 `MANAGE_VPN`**。

### 2.2 内核侧：Xray-core 交叉编译成 `libcore.so`（✅ 已解决）

Go **没有** `GOOS=ohos` 目标。可工作的做法是**借用 Go 的 `android/arm64` 端口 + OHOS NDK 的
clang 目标三元组 `aarch64-linux-ohos`**：

```bash
export CC=$OHOS_NDK_HOME/native/llvm/bin/clang
export CGO_ENABLED=1
export GOOS=android          # 关键：借道 android/arm64（非 glibc 端口）
export GOARCH=arm64
export CGO_CFLAGS="--target=aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/native/sysroot"
export CGO_LDFLAGS="--target=aarch64-linux-ohos -fuse-ld=lld -lohcommonevent -lhilog_ndk.z -ltime_service_ndk"
go build -buildmode=c-shared -ldflags "-s -w" -tags "fts5 timetzdata" -o libcore.so .
```

> **走这条官方 Go 是走不通的**（本机与 Linux 上均已尸检），障碍在 Go 标准库内部：
> 1. NDK 路径含空格 → Go 截断 `CC`（可用无空格 junction 绕过）；
> 2. OHOS sysroot 无 `android/log.h` → 需 shim 头；
> 3. **`net/cgo_resold.go:20` 的 `socklen_t` 类型冲突** —— OHOS musl 把 `socklen_t` 声明为
>    `unsigned`，Go 的 android 端口假设 bionic 宽度。**无编译开关可解，需 patch Go 标准库。**
> 4. 更深一层：`GOOS=android` 还有 **cgo TLS 墙**（bionic 固定 TLS 槽 vs musl），运行期**概率性 SIGSEGV**。
>
> 👉 **项目的解法是自建一份支持 `c-shared` 的 OHOS Go 工具链**（不是改用第三方低星 fork 的成品，
> 而是自己 forward-port 并留档）。完整记录见
> [`docs/04-Linux构建任务书.md`](docs/04-Linux构建任务书.md) ~ [`docs/08-OHOS移植执行笔记.md`](docs/08-OHOS移植执行笔记.md)，
> 以及 [`docs/design/core.md`](docs/design/core.md) §6。
>
> **产物**：`libcore.so` 约 **34.5 MB**、ELF64/AArch64/DYN、TLS 重定位为 `R_AARCH64_TLSDESC`；
> 与 `libhevsocks5tun.so` 一起放在 `harmonybridge-so/`（该目录在 `.gitignore` 里），
> 构建/安装时由 `scripts/` 拷进 `entry/libs/arm64-v8a/`。**两者都不入库。**

### 2.3 桥接层：ArkTS → NAPI(C++) → Go

C ABI 契约（**固定不变，改动必须同步三处**）：

```go
//export GoInvoke
func GoInvoke(service, parameters *C.char) *C.char   // JSON 进，JSON 出
//export GoFreeCString
func GoFreeCString(result *C.char)
```

- `service` 形如 `"CoreService.Start"`，`parameters` 是 JSON 字符串
- 返回值是统一信封：`{"success": bool, "result": object, "error": string}`
- 返回的 `char*` 由 Go 用 `C.CString` 分配，**必须**回调 `GoFreeCString` 释放，否则跨 C 边界泄漏

**本项目的改进（相对参考实现）**：参考实现用 **Cangjie（仓颉）`@Interop[ArkTS]`** 做桥接，引入了整套仓颉工具链。
本项目改用 **纯 NAPI C++**（`napi/native_api.h`，与 DevEco 模板同款）：
用 `dlopen("libcore.so")` + `dlsym("GoInvoke")` 解析符号 —— 好处是内核 `.so` 缺失时应用仍能编译和启动，
并返回明确错误，而不是直接链接失败。🧪 真机已验证 `dlopen` 与 `GoInvoke` 均成功。

### 2.4 端到端调用链（🧪 真机已验证）

```
ArkTS 页面
  └─ viewmodel/（状态与意图）
       └─ core/Bridge.ets          唯一允许触碰原生的层
            └─ libbridge.so (NAPI C++, dlopen/dlsym)
                 └─ libcore.so (Go c-shared / Xray-core)
                      └─ 只做本地 SOCKS/HTTP 入站（不知道 tun 的存在）
```

**进程与数据流**（这是本项目最关键、也最容易踩错的一张图）：

```
[UI 进程]  ConnectionViewModel
    │  1. ConfigService.Generate  -> 生成 config.json 并写入沙箱
    │  2. vpnExtension.startVpnExtensionAbility(want)   ← 触发用户授权弹窗
    │  3. 等扩展进程经公共事件 VPN_CORE_STATE 上报真实状态
    │     （内部只用 CoreStateMonitor；**不**自己启动内核，**不**再连 ServiceExtension）
    ▼
[VPN 扩展进程]  VpnAbility
    · createVpnConnection(context) → vpnConnection
    · vpn.create(VpnConfig)                        ⇒ vNIC fd          ← 有 8 秒看门狗，见下
    · protectProcessNet()                          ⇒ 本进程 egress 绕过 VPN（防环主手段）
    · CoreService.Start(configPath, assets, ...)   ⇒ 内核起来、本地 SOCKS/HTTP 入站开始监听
    · DataPlane.start(tun2socks.yaml, vfd)         ⇒ hev 接管 vNIC fd
    · commonEventManager.publish('VPN_TRAFFIC')    ⇒ 流量回传 UI
    · commonEventManager.publish('VPN_CORE_STATE') ⇒ 状态回传 UI
    · onDestroy: 随进程退出一并释放

数据流： 应用 → vpn-tun → hev(lwip) → 127.0.0.1:<socksPort> → Xray 出站 → 代理服务器
```

> **三条必须记住的约束（都来自真机踩坑）**
>
> 1. **不要对 VpnExtensionAbility 调 `connectServiceExtensionAbility`。** 它是**错误用法**：
>    会以 ServiceExtension 语义触发扩展的 `onRequest`，随即连接被系统断开，并且让
>    `vpn.create()` **既不 resolve 也不 reject** —— 而系统层 VPN 已经生效（`vpn-tun` 建好、
>    默认路由被接管），于是所有应用流量进 TUN 却没人处理 → **手机静默断网且无任何报错**。
>    撤掉之后 `vpn.create()` 立即返回 vfd。
> 2. **内核必须跑在扩展进程里。** 曾经由 UI 进程调 `CoreService.Start`，用户切到别的应用后
>    UI 进程被系统**冻结**（`/proc/<pid>/stat` 的 cpuTicks 10 秒内 delta 恰好为 0），Xray 的
>    accept 循环随之停摆；而扩展进程里的 tun2socks 仍在往 `127.0.0.1:<socksPort>` 送流量。
>    症状：`SYN_SENT` 堆积、accept 队列堵死、**上行计数照涨而下行归零**。
> 3. **`libcore.so` 是按进程各加载一份的**，服务注册表也各是各的。所以 UI 进程里读
>    `CoreService.Status` / `LogService.Tail` 只会读到自己那份**从未启动过**的空实例。
>    跨进程状态只能走公共事件（`VPN_TRAFFIC` / `VPN_CORE_STATE`）。

> ⚠️ **生命周期（已实测修正）**：本机 SDK 的 `@ohos.app.ability.VpnExtensionAbility.d.ts`
> **只声明 `onCreate` / `onDestroy`**，全 SDK 搜索**没有** `onConnect` / `onDisconnected` / `onRequest`。
> 但 🧪 真机日志证明 **`onConnect` 与 `onRequest` 确实会被回调**（"能编译 ≠ API 存在"的反面）。
> 本项目仍然**只在 `onCreate` 里自驱动建网卡** —— 那是 SDK 契约保证的入口；`onConnect` 仅作幂等兜底。

> **数据面裁决（见 [`docs/design/ipc-contract.md`](docs/design/ipc-contract.md) 第 2 节）**：
> vNIC fd **不交给 Xray**，而是交给 `tun2socks` → 本地 SOCKS → Xray 出站。
> 原因：tun 直通在 OHOS 上无成功先例（VPN fd 拒绝 `Fstat`），且其防环依赖的
> `protect(fd)` 在 Go 侧无 hook。防环改用**官方的 `protectProcessNet()`**，
> 并同时把自身包名加入 `blockedApplications` 做第二层兜底。🧪 真机已验证源地址是蜂窝 IP 而非 tun 地址。

> ⚠️ **`vpn.create()` 需要看门狗。** 真机上它曾经挂死（既不 resolve 也不 reject），而系统层
> VPN 已生效 → 断网且无报错。现在有 8 秒超时：未建成则 `processManager.exit(0)` 结束扩展进程，
> 让系统撤销 VPN，把用户网络还回去。**宁可"连接失败"，也不许"静默断网"。**

> ⚠️ **隧道 MTU 必须小于上行网卡 MTU。** 实测上行 `rmnet0` MTU=**1400**；而内层满段会被包上
> REALITY/TLS 头（约 +73 字节）再走外层。故 `MSS ≤ 1400 − 73 = 1327` ⇒ `MTU ≤ 1367`。
> 现取 **1280**（MSS 1240，外层 ≤ 1313）。用 1500 会让每个满段在外层被重切一刀，大流量下
> 包数翻倍 —— 表现为"上行正常、下行几乎不动"。

要点：
- VPN 扩展**跑在独立进程**，**内核与数据面都在那个进程里**；应用进程通过公共事件拿流量与状态。
- 虚拟网卡接口名实测为 **`vpn-tun`**。
- 扩展进程的配置路径**自己推算**：`<filesDir>/core/config.json` 与 `<filesDir>/assets`。
  唯一来源是 `entry/src/main/ets/core/ConfigStore.ets`（`configFilePath` / `assetsDirPath`）。

> **本项目的取舍（与参考实现不同，已落地）**：`assetLocation` 用
> **`<filesDir>/assets`**，而不是只读的 `resourceDir`。理由：geo 资源改为**按需下载**
> 而不是打进 HAP，只有可写目录才放得下。路径的唯一来源是
> `entry/src/main/ets/core/ConfigStore.ets#assetsDirPath`，它同时喂给
> `ConfigService.Generate` 的 `assetDir`（探测资源是否就位）与 `CoreService.Start` 的
> `assetLocation`（原生侧把它 export 成 `xray.location.asset`，见
> `golang/service/core/core.go:135-143`）。两处若拼出不同路径，症状是"下载了但内核说找不到"。
> 见 [`docs/design/core.md`](docs/design/core.md) §7.4.5.2。

---

## 3. 硬约束（违反即为缺陷）

1. **API 以本地 SDK 为准。** 任何 `@kit.*` / `@ohos.*` 符号，必须先在
   `D:\Harmony\DevEco Studio\sdk\default\openharmony\ets\api\` 或 `.../kits/` 下 grep 到声明再用。
   训练数据里的鸿蒙 API 大量过时或不存在。
2. **ArkTS 不是 TypeScript。** 禁止 `any`、结构化类型取巧、对象字面量直接当接口用、动态属性访问、
   `Object.keys` 遍历取属性、对象展开。一律显式 `interface` + 显式类型 + `class`（ViewModel 用 `@ObservedV2`/`@Trace`）。
3. **ABI 只保留 `arm64-v8a`。** Go 内核只有 arm64 产物，`x86_64` 会让 sync 失败且毫无意义。
4. **不新增第三方 ohpm 依赖。** 参考实现用了 `@pura/harmony-utils`，本项目不跟。只用 `@kit.*`，把依赖风险压到零。
5. **构建产物不入库。** `*.so` / `*.hap` / `*.hsp` / `*.har` / 签名材料全部在 `.gitignore` 里；
   `scripts/verify-repo.ps1` 会拦截（并已装为 `pre-commit` 钩子）。
6. **参考边界不可越。** 见第 6 节。
7. **跨 C 边界的 Go 代码不得 panic 逃逸。** `GoInvoke` 内部必须 `recover` 并把错误塞进信封，否则整个应用进程崩。
8. **所有面向用户的文案走资源文件**（`$r('app.string.*')`），不得在 `.ets` 里硬编码中文字面量。
9. **真实节点数据不得进仓库。** 地址 / 端口 / UUID / REALITY 公钥一律不得写进任何被跟踪的文件
   （含注释）。真机联调用的本地种子走 `entry/src/main/resources/rawfile/local-nodes.txt`，
   该文件在 `.gitignore` 里，模板见 `local-nodes.example.txt`。**详见第 9 节。**

### 3.1 编译器与运行时教给我们的硬规则

前半部分（9–14）是**编译器实际报错**才发现的；15 之后是**真机运行期**才发现的。踩过的坑不要再踩：

| # | 规则 | 反例 → 正解 |
|---|---|---|
| 9 | **禁止索引访问字段**（`arkts-no-props-by-index`）。声明类型是 `Object`/class/interface 时，`obj['k']` 直接编译失败 | `result: Object` → `result: Record<string, Object>`；必要时写一个 `asFields()` 收窄辅助函数 |
| 10 | **对象字面量必须挂到显式声明的类型**（`arkts-no-untyped-obj-literals`） | `return success({ version: v })` 报错 → 用带引号的 Record 字面量 `{ 'version': v }`，或声明 `interface` 后标注 |
| 11 | **`direction` / `enabled` 等是 `CustomComponent` 的保留属性名**，组件里不能声明同名成员变量 | `@State direction` → `@State sortDirection`；`@State enabled` → `@State isEnabled` |
| 12 | **`@Builder` / `build()` 体内不能调用「函数类型的参数」**。想做"把 UI 片段传进来"必须用 `@BuilderParam` + 尾随闭包 | `@Builder Card(content: () => void)` ❌ → 定义 `@ComponentV2 struct X { @BuilderParam contentSection: () => void }`，调用处 `X() { ... }` ✅（尾随闭包里的 `this` 仍绑定**父组件**） |
| 13 | **NDK/`@kit` 类型要用对**：`router.Router` 不存在；类型要从 `@kit.ArkUI` 导入。`router.RouterOptions` 仍要保留 `@ohos.router` 的那个（与 `@system.router` 的同名类型不同） | `import { Router } from '@kit.ArkUI'` |
| 14 | **`process.ProcessManager` 要 `new`**；`exit()` 是实例方法 | `new process.ProcessManager().exit(0)` |
| 15 | **`VpnConfig` 的数组字段全是可选的**，直接取 `.length` 会报 `possibly 'undefined'` | `config.routes.length` ❌ → 先收窄再取，或干脆不打印它 |
| 16 | **`.d.ts` 里有 ≠ 运行时存在。** `vpnExtension.createVpnObserver`（`@since 26.0.0`）在真机上抛 `is not callable` | 一切"新 API"都要 `try/catch` + 记日志，**不能让可选的诊断能力把主流程带崩** |
| 17 | **`.d.ts` 里没有 ≠ 运行时不存在。** `VpnExtensionAbility` 的 `onConnect` / `onRequest` SDK 未声明，但真机确实会回调 | 只把**契约保证**的入口（`onCreate`）当作驱动点，其余当幂等兜底 |
| 18 | **读 rawfile 的正解**：`getRawFileContentSync` 抛异常表示文件不存在（属正常路径），解码用 `util.TextDecoder.create('utf-8').decodeToString()` | `import { util } from '@kit.ArkTS'` |
| 19 | **跨进程只有 `commonEventManager`**；`emitter` 只在同进程内回调 | 两者都订阅、解码逻辑复用，见 `core/TrafficMonitor.ets` / `core/CoreStateMonitor.ets` |
| 20 | **`libcore.so` 按进程各加载一份**，服务注册表也各是各的 | 内核状态/日志只能在**持有内核的那个进程**里读；跨进程靠公共事件 |

**验证方式**：`.ets` 的正确性**没有廉价替代品**，只有真编译才算数。纯 TypeScript 解析器**不可用**于
含声明式 UI 的文件（`Column(){ }` 不是合法 TS），详见 [`docs/design/ci.md`](docs/design/ci.md) §6.2。
**改完 UI 代码必须跑一次 `assembleHap`**（命令见 [`docs/03-环境搭建.md`](docs/03-环境搭建.md) §5.2）。

---

## 4. 仓库结构

```
Bridge/
├── AGENT.md                     ← 本文件
├── README.md                    ← 项目门面
├── TODO.md                      ← 未完成项与已知缺陷（按严重度）
├── HANDOFF.md                   ← 交接笔记
├── CONTRIBUTING.md              ← 贡献流程 + 许可警告
├── .gitmodules                  ← 只读参考 submodule（v2rayN）
├── .githooks/                   ← pre-commit（跑 verify-repo）/ commit-msg
├── .github/                     ← CI（ci/release/verify）、PR/Issue 模板、CODEOWNERS
├── .gitattributes               ← 行尾规范 + Git LFS（*.so/*.dat）
├── build-profile.json5          ← 工程级构建配置（API 24 兼容 / 26 目标）
│                                  ⚠️ DevEco 自动签名会把口令与本机路径写进这里，
│                                  提交前必须排除（本地构建产物，见第 9 节）
├── oh-package.json5             ← 工程级依赖
├── code-linter.json5            ← 静态检查规则
├── local.properties             ← 本机 SDK 路径（不入库）
├── AppScope/                    ← 应用级配置与资源（bundleName / 版本号 / 图标 / 名称）
├── entry/                       ← 唯一的 HAP 模块
│   ├── src/main/module.json5    ← 权限 + VpnExtensionAbility 声明
│   ├── src/main/ets/            ← ArkTS 前端（页面 / ViewModel / Bridge / 服务）
│   │   ├── core/                ← Bridge / ConfigStore / TrafficMonitor / CoreStateMonitor
│   │   └── vpnability/          ← VpnExtensionAbility（扩展进程：内核 + 数据面）
│   ├── src/main/cpp/            ← NAPI C++ 桥（libbridge.so）+ tun2socks 装载器
│   ├── src/main/golang/         ← Go 内核包装（Xray-core → libcore.so）
│   ├── src/main/resources/      ← 资源、i18n、页面路由表
│   │   └── rawfile/             ← local-nodes.txt（本地种子，**不入库**）+ 模板
│   └── libs/arm64-v8a/          ← libcore.so / libhevsocks5tun.so 落点（产物，不入库）
├── docs/
│   ├── README.md                ← 文档索引
│   ├── 00-技术路线可行性.md      ← 可行性结论（先读这份）
│   ├── 01-架构设计.md
│   ├── 02-开发计划.md
│   ├── 03-环境搭建.md
│   ├── 04~08                    ← OHOS Go 工具链自研与两个 .so 的构建记录
│   ├── design/                  ← ipc-contract.md / core.md / ui.md / ci.md（各工作流自述）
│   └── research/                ← 带引用的调研报告
├── scripts/                     ← check-env / bootstrap / verify-repo / build-core / build-tun2socks
└── third_party/v2rayN/          ← 只读参考 submodule（不要改它）
```

---

## 5. 开发流程

### 5.1 新克隆上手

```powershell
git clone https://github.com/kuaizhongqiang/HarmonyBridge.git
cd Bridge
.\scripts\bootstrap.ps1      # git lfs install + submodule + 环境自检
.\scripts\check-env.ps1      # 单独看环境是否齐备
```

> `third_party/v2rayN` 自带一个嵌套 submodule `v2rayN/GlobalHotKeys`（Windows 全局热键，与本项目无关），
> 拉取时**不需要** `--recursive`，只取 `third_party/v2rayN` 即可。

### 5.2 提交规范

Conventional Commits，由 `.githooks/commit-msg` 强制：

```
<type>(<scope>): <subject>
```

- type：`feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert`
- scope 建议：`repo` `submodule` `ci` `ui` `core` `bridge` `docs` `vpn` `subscription` `settings`
- 标题 ≤ 100 字符，描述用中文或英文皆可但要一致
- 破坏性变更在 type 后加 `!`，正文写清影响与迁移方式

### 5.3 质量门禁

安装钩子（一次性）：

```powershell
.\scripts\install-hooks.ps1     # 等价于 git config core.hooksPath .githooks
```

| 门禁 | 命令 | 拦什么 |
|---|---|---|
| 仓库卫生 | `.\scripts\verify-repo.ps1` | 构建产物、签名材料、密钥、submodule 结构异常。**已装为 pre-commit，提交时自动跑** |
| 环境自检 | `.\scripts\check-env.ps1` | SDK/NDK/工具链缺失 |
| 提交信息 | `.githooks/commit-msg` | 非规范提交信息 |
| 内核编译 | `cd entry/src/main/golang; go build ./...; go vet ./...` | Go 侧语法/静态问题（宿主可跑） |
| JSON5 合法性 | `node scripts/validate-json5.mjs` | 配置文件写坏 |
| CI | `.github/workflows/ci.yml` | 上述各项的自动化版本 |

> ⚠️ **`verify-repo.ps1` 的 `[secrets]` 规则只覆盖通用凭据前缀**（AWS/GitHub/Slack token、
> 私钥头、Huawei AK/SK），**不包含节点地址/UUID/公钥**。也就是说 **CI 抓不到节点泄漏**，
> 提交前必须按第 9 节人工核对。

**改动 UI 或内核后，必须**：说明改了哪一层、是否影响 C ABI 契约、是否影响 `module.json5` 声明。

### 5.4 改动 C ABI 契约的流程

`GoInvoke` / `GoFreeCString` / 服务名 / 信封格式一旦变化，**三处必须同一提交内一起改**：
1. `entry/src/main/golang/main.go`（Go 导出）
2. `entry/src/main/cpp/`（NAPI 桥的声明与调用）
3. `entry/src/main/cpp/types/libbridge/Index.d.ts` + `entry/src/main/ets/core/Bridge.ets`（ArkTS 侧类型）

---

## 6. 许可与引用边界（法律红线，务必遵守）

| 组件 | 许可 | 对本项目的含义 |
|---|---|---|
| 本仓库代码 | **MIT**（见 `LICENSE`） | 现状 |
| `third_party/v2rayN` | **GPL-3.0** | **只读参考**。把它的代码搬进本仓库 = 本项目要整体转 GPL-3.0 |
| Xray-core | **MPL-2.0** | 文件级 copyleft，作为依赖链接通常可接受，但需保留声明 |
| hev-socks5-tunnel | **MIT** | 数据面，可自由链接 |
| sing-box | **GPL-3.0** | 若改用 sing-box 作内核，整个应用的许可策略要重新评估 |

**规则：**
- ✅ 可以：阅读 v2rayN 理解信息架构、路由语义、配置字段含义，然后**用自己的话重新实现**
- ✅ 可以：引用 v2rayN 的行为作为设计依据并在文档里注明出处
- ❌ 不可以：复制粘贴其 C# 代码、资源、图标、文案
- ❌ 不可以：把它当依赖编译进产物
- ⚠️ **上架或分发之前**必须由人做一次明确的许可决策（MIT 还是 GPL-3.0；内核选 Xray 还是 sing-box）。
  在那之前，本文档不替决策，只记录约束。

---

## 7. 已知阻塞与风险（截至 v2）

> **已决策（2026-10-11）：本项目仅供自用，不对外发行。**
> 由此 B1（不可上架）与 B4（许可决策）从"阻塞"降级为"已定"。

### 已解除的阻塞

| 原编号 | 内容 | 现状 |
|---|---|---|
| ~~B2~~ | Go→OHOS 工具链受阻（`socklen_t` 冲突 + cgo TLS 墙） | ✅ **已解决**：自建支持 `c-shared` 的 OHOS Go 工具链，已产出 `libcore.so`（34.5 MB）并在真机上 `dlopen` + `GoInvoke` 成功。见第 2.2 节 |
| ~~B3~~ | 没有鸿蒙真机 | ✅ **已解决**：HUAWEI `TYR-AL00`，API 24；签名/安装/运行均通过 |
| ~~B5~~ | `MOCK_BRIDGE` 必须保持 `true` | ✅ **已置为 `false`**：`NativeBridgeImpl.invoke` 真实走 `libbridge.so` → `dlopen` → `GoInvoke` |

### 已解除的疑问（不再当成风险）

- ✅ **ArkTS + NAPI 桥能真实编译并打包**（2026-10-11 实测 `BUILD SUCCESSFUL`）。
- ✅ **`libcore.so` 在 OHOS 上能 `dlopen`、`GoInvoke` 可调、Xray 能运行**（🧪 真机，返回 `26.3.27`）。
- ✅ **`libhevsocks5tun.so` 能接管 OHOS 的 vNIC fd**（🧪 真机，双向计数增长）。
- ✅ **`protectProcessNet()` 能止住环路**（🧪 真机：`netstat` 显示内核出站源地址是蜂窝 IP 而非 tun 地址）。
- ✅ **端到端能出网**（🧪 真机：第三方应用浏览器可正常加载网页）。
- ✅ **`blockedApplications` 里的自身包名确实让应用 egress 不进 TUN**（同上，两重兜底都验证过）。
- ✅ **签名方案确定**：SDK 自带的 OpenHarmony 演示证书会被华为真机拒绝
  （`9568257 fail to verify pkcs7 file`）；**必须用 DevEco 自动签名（AGC 签发）**。

### 技术风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| `GOOS=android` 借道不被官方支持（自建 fork 的长期维护成本） | 内核可能在未来 Xray 版本上升级失败 | 锁定 Xray-core 版本；构建脚本带版本校验；`docs/04`~`08` 留了完整移植记录；预留 sing-box 备选 |
| `libcore.so` ~34.5 MB | HAP 体积大（实测 37.7 MB） | 按 ABI 拆分、release 剥离符号、评估裁剪功能集 |
| 跨 C 边界 panic | 整个 VPN 进程崩溃 | `GoInvoke` 内强制 `recover`；信封返回错误 |
| VPN 扩展进程被系统回收 | 断流 | 前台常驻通知 + 断线重连状态机（**TODO：尚未实现**） |
| 回环（代理流量又进 VPN） | 直接断网 | 已用 `protectProcessNet()` + `blockedApplications` 双重兜底，🧪 已验证。接线见 `ets/vpnability/VpnAbility.ets#protectOwnProcessNet` 与 `#buildVpnConfig` |
| `vpn.create()` 挂死 | 系统层 VPN 已生效但无人处理 → **断网** | 8 秒看门狗：超时结束扩展进程，系统随之撤销 VPN（🧪 已实现；触发过一次真实故障，见第 2.4 节） |
| 内核 `wired` 字段在 Go 侧恒为 `false` 且描述错误 | UI 显示"未连通"但实际已通 | ArkTS 侧不再采信它，改由「内核已启动 **且** tun2socks 已运行」推算，经 `VPN_CORE_STATE` 上报。**根治要重编 `.so`** |
| 用户授权被拒 / 用户类型受限 | 无法建 VPN | 处理 `2203001`，给出可理解的提示（`onAuthorizationResult` **运行时不存在**，不能依赖） |
| geoip/geosite 未打包 | 按国家分流降级为"私有网段直连 + 其余走代理" | **已裁决：按需下载**（不打包）。落点 `<filesDir>/assets`。缺失时生成器会降级并在 `notes` 里说明 |
| IPv6 未接管 | IPv6 流量绕过 VPN（有泄漏） | 见 `TODO.md`；短期可在配置里显式不声明 v6 |

---

## 8. 文档证据标记约定（请沿用）

写文档时必须区分"我验证过的"和"我听说的"：

| 标记 | 含义 |
|---|---|
| ✅ 已验证（本地 SDK/源码） | 在本地文件/代码里亲眼确认，可给出路径 |
| 📄 官方文档 | 华为官方文档中的明确表述，附 URL |
| 🧪 已验证（真机/构建/命令输出） | 实际跑过命令或真机操作得到的结果 |
| 🌐 社区来源 | 博客/论坛/第三方仓库，需标注可信度（中/低） |
| ❓ 未证实 / 推断 | 明确说明这是推断，并写出推断依据 |

**绝不允许**把 ❓ 写成 ✅。这份仓库的价值就在于它的结论可信。
反过来说：**已经 🧪 验证过的事，也不许继续写成 ❓** —— 那同样是失真，而且会误导后续开发。

---

## 9. 真实数据与提交纪律（🔴 提交流程必读）

本仓库会公开托管在 GitHub 上，而它的用途决定了它必然会接触到**真实节点凭据**。

**绝不允许进仓库的东西**（含注释、文档、测试数据、示例）：

- 代理服务器地址 / 端口
- 用户 UUID / 密码
- REALITY 公钥（`pbk`）、`shortId`、`SNI` 等能组合定位到某台服务器的字段
- 完整分享链接（`vless://...` / `vmess://...`）
- 签名材料（`.p12` / `.p7b` / `.cer`）与口令
- `build-profile.json5` 被 DevEco 自动签名写入后的版本（含 `storePassword` / `keyPassword` 与本机绝对路径）

**真机联调怎么喂节点**：把分享链接（一行一条）写进
`entry/src/main/resources/rawfile/local-nodes.txt`。该文件：

- 在 `.gitignore` 里，**永不入库**；模板是 `local-nodes.example.txt`（只有占位值）；
- 会被打进 HAP，所以真实值随**本机构建**进入设备，而不出现在任何被跟踪的源文件里；
- 由 `ets/viewmodel/NodeViewModel.ets#loadLocalNodes` 读取，复用与手工粘贴完全相同的解析/校验路径。

**提交前必须做的核对**：

```powershell
git status --porcelain                 # 确认 build-profile.json5 未 stage
git diff --cached --stat               # 确认文件清单

# 扫「形状」，不要扫「具体值」：
# 把真实地址/UUID/公钥写进这条命令行本身**就是二次泄漏** —— 本文档自己踩过
# （曾在此处内嵌真实 UUID 与 REALITY 公钥的前缀）。
git diff --cached | findstr /i /r "vless:// vmess:// pbk= sid= BEGIN"   # 无输出才算干净

# 更彻底的一步：拿本机的真实种子逐行比对（真实值全程不落文档）。
# local-nodes.txt 在 .gitignore 里、不入库，只用于本地。
Get-Content entry/src/main/resources/rawfile/local-nodes.txt -ErrorAction SilentlyContinue |
  Where-Object { $_ -notmatch '^\s*#' -and $_.Trim().Length -gt 0 } |
  ForEach-Object { git diff --cached | Select-String -SimpleMatch $_ }
```

> ⚠️ **`scripts/verify-repo.ps1` 抓不到节点泄漏**（它只查通用凭据前缀）。这一步没有自动化替代品。
> 另外：**提交时不要用 `git add -A` / `git add .`**，用显式文件白名单。

---

## 10. 真机验证清单（🧪 2026-10-12 已完成 1–6，7 以后待做）

已完成（按依赖顺序）：

1. ✅ `ohpm install` + sync + `assembleHap` 出 HAP。
2. ✅ DevEco **自动签名**（AGC）→ `hdc install` 成功。
   （曾卡在 `9568320 no signature file` 与 `9568257 fail to verify pkcs7 file`，根因都是签名材料，见第 7 节。）
3. ✅ 用 DevEco Studio 打开工程，`ohpm install` + sync，确认能编译出 HAP。
4. ✅ 真机开发者模式安装 + 授权弹窗出现 + **`vpn-tun` 接口被创建** + `statistics.getIface*Bytes('vpn-tun')` 有读数。
5. ✅ `libcore.so` 能 `dlopen` 并拿到 `GoInvoke` 符号；`VersionService.GetVersion` 返回 `26.3.27`。
6. ✅ vNIC fd 交给 **tun2socks**（`libhevsocks5tun.so`），内核只做本地 SOCKS/HTTP 入站；
   **TUN → tun2socks → `127.0.0.1:<socksPort>` → 内核出站** 的出网链路连通（第三方应用实测）。
   同时验证了防环：内核出站源地址是蜂窝 IP，未回到 TUN。
7. ✅ `VPN_TRAFFIC` 公共事件回传，应用进程能显示上下行速率。

待做：

8. ⏳ 规则分流（geoip/geosite 需先接入下载）、订阅导入、按应用分流（`trustedApplications`/`blockedApplications` 的 UI 化）。
9. ⏳ IPv6 接管、节点持久化、设置页接线、前台常驻通知与断线重连。

> 历史上这一节的第 4 步（当时编号 2）与第 6 步（当时编号 4）曾被称为"本项目最大的两个未知" ——
> **两者均已由真机给出肯定答案**。

---

## 11. 术语表

| 术语 | 说明 |
|---|---|
| **vNIC / vpn-tun** | `VpnConnection.create()` 返回的虚拟网卡 fd；接口名实测 `vpn-tun` |
| **VpnExtensionAbility** | 三方 VPN 的系统扩展 Ability，`type: "vpn"`，运行在独立进程 |
| **libcore.so** | Go 用 `-buildmode=c-shared` 编出的 Xray-core，导出 `GoInvoke`。**按进程各加载一份** |
| **libbridge.so** | 本项目的 NAPI C++ 桥，把 ArkTS 调用转成对 `GoInvoke` 的调用 |
| **libhevsocks5tun.so** | hev-socks5-tunnel（MIT），本项目的数据面：把 TUN 流量转成本地 SOCKS |
| **信封（envelope）** | 跨 C/JSON 边界的统一返回结构 `{success, result, error}` |
| **`protectProcessNet()`** | SDK 提供的「让**本应用进程**的 egress 绕过 VPN、走物理网络」的 API（`@since 22`）。**本项目的防环主手段** |
| **`protect(fd)`** | SDK 提供的「让**单个 socket** 绕过 VPN」的 API。本项目数据面不用它（拿不到内部 socket 的 fd）。保留该词条是为了让人知道**为什么不用**它 |
| **`blockedApplications`** | `VpnConfig` 字段：列表里的应用不按 `routes` 被代理。本项目的第二层防环兜底 |
| **`MOCK_BRIDGE`** | `ets/core/Bridge.ets` 的总开关。**现为 `false`**（走真实原生链路） |
| **OHOS NDK** | `...\sdk\default\openharmony\native`，含 clang/llvm 与 musl sysroot |
| **HAP** | HarmonyOS Ability Package，应用安装包 |

---

## 12. 给智能体的最后三条提醒

1. **先查本地 SDK，再写鸿蒙代码。** 幻觉 API 是这个项目最大的浪费来源；
   同时记住第 3.1 节规则 16/17：`.d.ts` 与运行时**可能双向不一致**。
2. **不知道就说不知道。** 用第 8 节的标记把不确定性显式化，比编一个漂亮答案有价值得多。
   **反过来，验证过的事也别说成没验证过。**
3. **不要越界写文件。** 动手前先确认自己负责的路径范围；跨层改动（尤其 C ABI 与 `module.json5`）
   必须一起改、一起说明。**提交前先过第 9 节。**
