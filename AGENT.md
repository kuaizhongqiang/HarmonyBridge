# AGENT.md — HarmonyBridge 智能体作业手册

> 本文件是本仓库的**唯一权威作业约定**。任何 AI 智能体（以及新加入的人类开发者）在动手之前必须先读完本文件。
> 版本：v1（2026-10-11）｜适用 API 基线：`compatibleSdkVersion 6.1.1(24)` / `targetSdkVersion 26.0.0` / HarmonyOS

---

## 0. 一句话说明

**HarmonyBridge 是 v2rayN 的鸿蒙原生版本**：一个 ArkTS 前端 + Xray-core 原生代理内核，通过 HarmonyOS 的
`VpnExtensionAbility` 把内核接入系统 VPN 通道，让手机上的流量按规则走代理。

参考实现：`third_party/v2rayN`（只读 submodule，C#/WPF，GPL-3.0）。

---

## 1. 当前阶段与作业边界（最重要的一节）

项目处于**准备工作阶段**。请严格遵守以下边界，否则会产出无法验证、甚至误导后续开发的结论。

| 条件 | 状态 | 对作业的约束 |
|---|---|---|
| 鸿蒙真机 | ❌ 没有 | **不能**声称任何功能"已验证/可运行" |
| 鸿蒙模拟器 | ⚠️ 有（`DevEcoStudio26.0`/`Emulator`），但 VPN 能力大概率不可用 | 不得把模拟器当作 VPN 链路验证手段 |
| DevEco Studio | ✅ 26.0，位于 `D:\Harmony\DevEco Studio` | 可以用它查 SDK、查 API 定义 |
| HarmonyOS SDK | ✅ `D:\Harmony\DevEco Studio\sdk\default\openharmony` | **查 API 以本地 SDK 的 `.d.ts` 为准，不要凭记忆** |
| `ohpm` / `hvigorw` / `java` | ⚠️ 未加入 `PATH`，需用 DevEco 内置路径 | 不得假设直接敲命令就能构建 |
| Go | ✅ 1.26.4，`C:\Program Files\Go` | `go tool dist list` **没有** `ohos` 目标，见第 3 节 |

**因此在当前阶段，允许产出的东西是：**
✅ 仓库结构、配置、流水线、脚本、依赖声明
✅ 文档、架构设计、可行性论证、风险清单
✅ 可静态审查的代码骨架（ArkTS 页面、NAPI 桥、Go 服务层）
✅ 宿主平台上能真正跑起来的验证（`go build` / `go vet` / JSON 校验 / 仓库卫生门禁）

**不允许产出的东西是：**
❌ "构建通过/功能正常/已在设备上验证" 之类未经执行的结论
❌ 提交任何构建产物（`*.so` / `*.hap` / `*.hsp`）
❌ 提交任何签名材料、证书、私钥
❌ 未经许可决策就把 GPL 代码搬进本仓库

> **诚实性要求**：如果一件事没做，就写"未做"；如果只是推断，就写"推断"并给出依据。
> 本仓库的文档使用了统一的证据标记，见第 8 节，请沿用。

---

## 2. 已核实的技术路线（本项目的技术基石）

这条路线的**可行性已在本地 SDK 与一个可工作的开源参考实现上双向核实**。

### 2.1 系统侧：第三方 VPN 走 `vpnExtension`，不需要系统签名

本地 SDK 证据（请自行打开确认，不要采信二手描述）：

- `D:\Harmony\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.net.vpnExtension.d.ts`
  - 声明 `@syscap SystemCapability.Communication.NetManager.Vpn`，`@since 11`
  - 关键 API：
    - `startVpnExtensionAbility(want)` / `stopVpnExtensionAbility(want)` — 拉起/停止 VPN 扩展
    - `createVpnConnection(context): VpnConnection` — 建立 VPN 连接对象
    - `VpnConnection.create(config): Promise<number>` — **返回虚拟网卡（vNIC）的文件描述符**
    - `VpnConnection.protect(socketFd)` — 让指定 socket 绕过 VPN，**防回环必需**
    - `VpnConnection.protectProcessNet()`（`@since 22`）
    - `VpnConnection.destroy()` / `destroy(vpnId)`（`@since 20`）、`generateVpnId()`（多 VPN，仅 IPv4）
    - `createVpnObserver()` + `VpnObserver.onAuthorizationResult()`（`@since 26.0.0`）— 用户授权弹窗结果回执
  - `VpnConfig` 能力：`addresses`、`routes`、`dnsAddresses`、`searchDomains`、`mtu`（576–1500）、
    `isIPv4Accepted`、`isIPv6Accepted`、`isInternal`、`isBlocking`、`trustedApplications`、`blockedApplications`（按应用分流）
  - 官方注释原文要点：**"the connection tunnel process and internal connection protocols need to be implemented by the applications themselves"**
    —— 系统只给你虚拟网卡和路由配置，**隧道协议要自己实现**。这正是 v2rayN 的模型，因此本项目路线成立。

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

### 2.2 内核侧：Xray-core 交叉编译成 `libcore.so`

Go **没有** `GOOS=ohos` 目标（本机 Go 1.26.4，`go tool dist list` 无 `ohos`）。可工作的做法是
**借用 Go 的 `android/arm64` 端口 + OHOS NDK 的 clang 目标三元组 `aarch64-linux-ohos`**：

```bash
export CC=$OHOS_NDK_HOME/native/llvm/bin/clang
export CGO_ENABLED=1
export GOOS=android          # 关键：借道 android/arm64（非 glibc 端口）
export GOARCH=arm64
export CGO_CFLAGS="--target=aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/native/sysroot"
export CGO_LDFLAGS="--target=aarch64-linux-ohos -fuse-ld=lld -lohcommonevent -lhilog_ndk.z -ltime_service_ndk"
go build -buildmode=c-shared -ldflags "-s -w" -tags "fts5 timetzdata" -o libcore.so .
```

- OHOS 的 libc 是 **musl 系**（NDK 里带 `-D__MUSL__`），Go 的 `android` 端口本来就是为"非 glibc 平台"设计的，
  两者凑合可用 —— 这是**社区经验证的做法，不是官方支持**。稳定性风险见第 7 节。
- `-buildmode=c-shared` 产出 `libcore.so` + `libcore.h`，导出 C ABI。
- 产物放 `entry/libs/arm64-v8a/libcore.so`，**不入库**（约 32 MB，且会污染 ABI/许可）。
- 链接的 OHOS 专有库：`libohcommonevent`（公共事件，用于跨进程回传流量/日志）、`libhilog_ndk.z`（日志）、
  `libtime_service_ndk`（时间）。

> ❌ **但本配方在本机实测是失败的，且原因在 Go 标准库内部**（完整尸检见
> [`docs/design/core.md`](docs/design/core.md) §6 与 [`docs/00-技术路线可行性.md`](docs/00-技术路线可行性.md) §4）：
> 1. NDK 路径含空格 → Go 截断 `CC`（可用无空格 junction 绕过）；
> 2. OHOS sysroot 无 `android/log.h` → 需 shim 头；
> 3. **真正阻塞**：`net/cgo_resold.go:20` 的 `socklen_t` 类型冲突 —— OHOS musl 把 `socklen_t`
>    声明为 `unsigned`，Go 的 android 端口假设 bionic 宽度。**无编译开关可解，需 patch Go 标准库。**
> 4. 更深一层：`GOOS=android` 还有 **cgo TLS 墙**（bionic 固定 TLS 槽 vs musl），运行期**概率性 SIGSEGV**。
>
> 👉 因此 **`docs/design/core.md` 是这条链路的权威现状**，不要把上面的配方当成"已验证可用"。
> 👉 缓解方向：**把数据面换成纯 C（hev-socks5-tunnel），把 Go 面缩到最小** —— 见可行性文档 §4.5。

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
并返回明确错误，而不是直接链接失败。

### 2.4 端到端调用链

```
ArkTS 页面
  └─ viewmodel/（状态与意图）
       └─ core/Bridge.ets          唯一允许触碰原生的层
            └─ libbridge.so (NAPI C++, dlopen/dlsym)
                 └─ libcore.so (Go c-shared / Xray-core)
                      └─ 接管 vNIC fd，按 config.json 转发流量

拉起 VPN 的控制流（应用进程侧）：
  vpnExtension.startVpnExtensionAbility(want)      ← 触发用户授权弹窗
    → context.connectServiceExtensionAbility(want{parameters: CONFIG_LOCATION / ASSET_LOCATION})
      → [VPN 扩展进程] VpnExtensionAbility.onCreate
            · 只能依赖 onCreate / onDestroy（见下方警告）
            · createVpnConnection(context) → connection.create(VpnConfig) ⇒ vNIC fd
            · fd 交给 tun2socks（不是交给 Xray！见「数据面」）
      → 流量统计：statistics.getIfaceTxBytes('vpn-tun') → commonEventManager.publish('VPN_TRAFFIC', {...})
      → onDestroy: connection.destroy() + process.ProcessManager().exit(0)
```

> ⚠️ **生命周期警告（重要，已实测）**：本机 SDK 的 `@ohos.app.ability.VpnExtensionAbility.d.ts`
> **只声明 `onCreate` / `onDestroy`**，全 SDK 搜索**没有** `onConnect` / `onDisconnected`。
> 网络上流传的"标准生命周期 `onCreate→onConnect→onDisconnected→onDestroy`"**不是公开 API 契约**
> （参考实现 x4h 用了它们，说明商业版运行时可能提供，但照抄有风险）。
> **本项目只在 `onCreate` 里自驱动。**
> 另注：`onRequest` 同样未声明 —— **"能编译" ≠ "API 存在"**（该工程未开 `typeCheck`）。

> **数据面（架构裁决，见 [`docs/design/ipc-contract.md`](docs/design/ipc-contract.md) 第 2 节）**：
> vNIC fd **不交给 Xray**，而是交给 `tun2socks` → 本地 SOCKS → Xray 出站。
> 原因：tun 直通在 OHOS 上无成功先例（VPN fd 拒绝 `Fstat`），且其防环依赖的
> `protect(fd)` 在 Go 侧无 hook。改用**把自身包名加入 `blockedApplications`** 防环，
> **完全不需要 `protect()`**。

要点：
- VPN 扩展**跑在独立进程**，所以内核也在那个进程里；应用进程通过**公共事件 `VPN_TRAFFIC`** 拿流量数据。
- 虚拟网卡接口名实测为 **`vpn-tun`**。
- `ASSET_LOCATION` 指向 `resourceDir`（放 `geoip.dat` / `geosite.dat`），`CONFIG_LOCATION` 指向应用 files 目录下的 `config.json`。

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
   `scripts/verify-repo.ps1` 会拦截。
6. **参考边界不可越。** 见第 6 节。
7. **跨 C 边界的 Go 代码不得 panic 逃逸。** `GoInvoke` 内部必须 `recover` 并把错误塞进信封，否则整个应用进程崩。
8. **所有面向用户的文案走资源文件**（`$r('app.string.*')`），不得在 `.ets` 里硬编码中文字面量。

---

## 4. 仓库结构

```
Bridge/
├── AGENT.md                     ← 本文件
├── README.md                    ← 项目门面
├── CONTRIBUTING.md              ← 贡献流程 + 许可警告
├── .gitmodules                  ← 只读参考 submodule（v2rayN）
├── .githooks/                   ← pre-commit / commit-msg
├── .github/                     ← CI、PR/Issue 模板、CODEOWNERS
├── .gitattributes               ← 行尾规范 + Git LFS（*.so/*.dat）
├── build-profile.json5          ← 工程级构建配置（API 24 兼容 / 26 目标）
├── oh-package.json5             ← 工程级依赖
├── code-linter.json5            ← 静态检查规则
├── local.properties             ← 本机 SDK 路径（不入库）
├── AppScope/                    ← 应用级配置与资源（bundleName / 图标 / 名称）
├── entry/                       ← 唯一的 HAP 模块
│   ├── src/main/module.json5    ← 权限 + VpnExtensionAbility 声明
│   ├── src/main/ets/            ← ArkTS 前端（页面 / ViewModel / Bridge / 服务）
│   ├── src/main/cpp/            ← NAPI C++ 桥（libbridge.so）
│   ├── src/main/golang/         ← Go 内核包装（Xray-core → libcore.so）
│   ├── src/main/resources/      ← 资源、i18n、页面路由表、geoip/geosite
│   └── libs/arm64-v8a/          ← libcore.so 落点（产物，不入库）
├── docs/
│   ├── README.md                ← 文档索引
│   ├── 00-技术路线可行性.md      ← 可行性结论（先读这份）
│   ├── 01-架构设计.md
│   ├── 02-开发计划.md
│   ├── 03-环境搭建.md
│   ├── design/                  ← ui.md / core.md / ci.md（各工作流自述）
│   └── research/                ← 带引用的调研报告
├── scripts/                     ← check-env / bootstrap / verify-repo / build-core
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
| 仓库卫生 | `.\scripts\verify-repo.ps1` | 构建产物、签名材料、密钥、submodule 结构异常 |
| 环境自检 | `.\scripts\check-env.ps1` | SDK/NDK/工具链缺失 |
| 提交信息 | `.githooks/commit-msg` | 非规范提交信息 |
| 内核编译 | `cd entry/src/main/golang; go build ./...; go vet ./...` | Go 侧语法/静态问题（宿主可跑） |
| JSON5 合法性 | `node scripts/validate-json5.mjs` | 配置文件写坏 |
| CI | `.github/workflows/ci.yml` | 上述各项的自动化版本 |

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
| sing-box | **GPL-3.0** | 若改用 sing-box 作内核，整个应用的许可策略要重新评估 |

**规则：**
- ✅ 可以：阅读 v2rayN 理解信息架构、路由语义、配置字段含义，然后**用自己的话重新实现**
- ✅ 可以：引用 v2rayN 的行为作为设计依据并在文档里注明出处
- ❌ 不可以：复制粘贴其 C# 代码、资源、图标、文案
- ❌ 不可以：把它当依赖编译进产物
- ⚠️ **上架或分发之前**必须由人做一次明确的许可决策（MIT 还是 GPL-3.0；内核选 Xray 还是 sing-box）。
  在那之前，本文档不替决策，只记录约束。

---

## 7. 已知阻塞与风险（截至 v1）

### 阻塞项（没有它就无法推进到"能跑"）—— 按严重度排序

1. **B1 · 境内不可上架发行**（法律 + 备案 + 平台政策）。这不是"审核严一点"：
   《计算机信息网络国际联网管理暂行规定》第六/十四条 + 工信部 APP 备案制度 + 平台明文不收录 VPN 类应用。
   所有先例**无一例外走侧载**。**这是产品形态决策，必须由人先拍板**，详见
   [`docs/research/03-合规与上架风险.md`](docs/research/03-合规与上架风险.md)。
2. **B2 · Go→OHOS 工具链受阻**：`socklen_t` 标准库冲突（无编译开关可解）+ cgo TLS 墙（运行期概率性 SIGSEGV）。
   需要**第三方 Go fork**（现役可用的是低星个人 fork）→ 引入供应链风险，**需人决策**。
3. **B3 · 没有鸿蒙真机**（且模拟器大概率不支持 VPN、本机无镜像）。VPN 链路、授权弹窗、`vpn-tun`
   虚拟网卡、内核接入，全部只能在真机上验证。
4. **B4 · 许可决策未定**：本仓库 MIT、v2rayN GPL-3.0、Xray-core MPL-2.0、sing-box GPL-3.0。
   **在集成核心之前必须决定**（想保 MIT 就只能从 MPL-2.0 的 Xray-core 起步）。
5. **契约已冻结但实现未跟上**：见 [`docs/design/ipc-contract.md`](docs/design/ipc-contract.md) §5
   的《原生侧待收敛清单》。在此之前 `MOCK_BRIDGE` **必须保持 `true`**。

### 技术风险
| 风险 | 影响 | 缓解 |
|---|---|---|
| `GOOS=android` 借道不被官方支持 | 内核可能编译失败或运行期异常 | 锁定 Xray-core 版本；构建脚本带版本校验；预留 sing-box 备选 |
| `libcore.so` ~32 MB | HAP 体积大 | 按 ABI 拆分、release 剥离符号、评估裁剪功能集 |
| 跨 C 边界 panic | 整个 VPN 进程崩溃 | `GoInvoke` 内强制 `recover`；信封返回错误 |
| VPN 扩展进程被系统回收 | 断流 | 前台常驻通知 + 断线重连状态机 |
| 回环（代理流量又进 VPN） | 直接断网 | **必须**对出站 socket 调 `protect(fd)`；这是 xray tun 入站的硬要求 |
| 用户授权被拒 / 用户类型受限 | 无法建 VPN | 处理 `2203001` 与 `onAuthorizationResult`，给出可理解的提示 |
| geoip/geosite ~30 MB | 体积与 LFS 管理 | LFS 托管；或改为按需下载 |

---

## 8. 文档证据标记约定（请沿用）

写文档时必须区分"我验证过的"和"我听说的"：

| 标记 | 含义 |
|---|---|
| ✅ 已验证（本地 SDK/源码） | 在本地文件/代码里亲眼确认，可给出路径 |
| 📄 官方文档 | 华为官方文档中的明确表述，附 URL |
| 🧪 已验证（构建/命令输出） | 实际跑过命令得到的结果 |
| 🌐 社区来源 | 博客/论坛/第三方仓库，需标注可信度（中/低） |
| ❓ 未证实 / 推断 | 明确说明这是推断，并写出推断依据 |

**绝不允许**把 ❓ 写成 ✅。这份仓库的价值就在于它的结论可信。

---

## 9. 拿到鸿蒙真机后，立刻要做的验证（按顺序）

1. 用 DevEco Studio 打开工程，`ohpm install` + sync，确认能编译出未签名 HAP。
2. 真机开发者模式安装，先跑**空壳 VPN**：只 `createVpnConnection` + `create(VpnConfig)`，
   不做任何转发，确认授权弹窗出现、`vpn-tun` 接口被创建、`statistics.getIface*Bytes('vpn-tun')` 有读数。
   → 这一步能单独验证"平台能力"，与内核解耦，**务必先做**。
3. 编译 `libcore.so`（`scripts/build-core.*`），确认能 `dlopen` 并拿到 `GoInvoke` 符号；
   先跑 `VersionService.GetVersion` 这种无副作用的调用，验证桥接链路。
4. 把 vNIC fd 交给 Xray-core 的 tun 入站，最小配置（单节点 freedom/vless 出站 + tun 入站），
   确认能连通；**同时验证 `protect(fd)` 是否让出站流量真正绕开 VPN**（不做必断网）。
5. 补 `VPN_TRAFFIC` 公共事件回传，确认应用进程能显示上下行速率。
6. 最后才做规则分流（geoip/geosite）、订阅导入、按应用分流（`trustedApplications`/`blockedApplications`）。

> 第 2 步和第 4 步是本项目**最大的两个未知**。在真机上跑通这两步之前，
> 任何人都不应对外宣称这个项目"可行"。

---

## 10. 术语表

| 术语 | 说明 |
|---|---|
| **vNIC / vpn-tun** | `VpnConnection.create()` 返回的虚拟网卡 fd；接口名实测 `vpn-tun` |
| **VpnExtensionAbility** | 三方 VPN 的系统扩展 Ability，`type: "vpn"`，运行在独立进程 |
| **libcore.so** | Go 用 `-buildmode=c-shared` 编出的 Xray-core，导出 `GoInvoke` |
| **libbridge.so** | 本项目的 NAPI C++ 桥，把 ArkTS 调用转成对 `GoInvoke` 的调用 |
| **信封（envelope）** | 跨 C/JSON 边界的统一返回结构 `{success, result, error}` |
| **protect(fd)** | 让某个 socket 走物理网络、不进 VPN，防回环的关键 API |
| **OHOS NDK** | `...\sdk\default\openharmony\native`，含 clang/llvm 与 musl sysroot |
| **HAP** | HarmonyOS Ability Package，应用安装包 |

---

## 11. 给智能体的最后三条提醒

1. **先查本地 SDK，再写鸿蒙代码。** 幻觉 API 是这个项目最大的浪费来源。
2. **不知道就说不知道。** 用第 8 节的标记把不确定性显式化，比编一个漂亮答案有价值得多。
3. **不要越界写文件。** 动手前先确认自己负责的路径范围；跨层改动（尤其 C ABI 与 `module.json5`）
   必须一起改、一起说明。
