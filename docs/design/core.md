# 原生代理内核设计（proxy-core skeleton）

> 状态：**准备阶段骨架**。宿主侧 Go 代码已通过 `go build` / `go vet` 与 `gofmt`；
> OHOS 交叉编译尚未产出可用 `.so`（原因见 §6.3）；tun fd 尚未打通。
> 本文记录**已实现的事实**、**契约**与**未决问题**，三者分开写，不混淆。

## 1. 分层

```
┌───────────────────────────────────────────────────────────────────────────┐
│ ArkTS / ArkUI                                                             │
│   pages/…  ViewModel                                                      │
│      ↓ 只依赖 Bridge.ets 暴露的强类型方法，不直接碰 JSON                     │
├───────────────────────────────────────────────────────────────────────────┤
│ Bridge.ets （ArkTS 侧门面，属于另一个工作流）                                │
│   职责：拼 JSON、调 Invoke、解析信封、把错误转成本地化的提示                   │
│      ↓ import bridge from 'libbridge.so'                                  │
├───────────────────────────────────────────────────────────────────────────┤
│ libbridge.so —— NAPI C++ 垫片（entry/src/main/cpp）                        │
│   · Invoke(service, paramsJson): string        ← 唯一入口                  │
│   · dlopen("libcore.so") + dlsym("GoInvoke")   ← 惰性、缓存、可失败        │
│   · 参数类型校验；free() 掉 Go 返回的缓冲区                                  │
│   · 任何失败都返回 {"success":false,"error":…}，绝不抛异常/闪退              │
├───────────────────────────────────────────────────────────────────────────┤
│ libcore.so —— Go 内核（entry/src/main/golang，-buildmode=c-shared）        │
│   GoInvoke → ipc.HandleRequest → Registry → Service.Method → JSON 信封     │
│   · 单一 panic 兜底点，panic 绝不穿越 C ABI                                  │
├───────────────────────────────────────────────────────────────────────────┤
│ Xray-core（dispatcher / proxyman / dns / router / vless / vmess / …）      │
│   由 registry 包的空白导入注册进全局工厂                                     │
└───────────────────────────────────────────────────────────────────────────┘
```

**为什么中间要放一层 NAPI C++，而不是让 ArkTS 直接调 Go？**

ArkTS 只能通过 NAPI 调用原生代码，而 Go 的 `c-shared` 产物是一个普通的 ELF
共享库，不会自己注册 NAPI 模块。所以必须有一个 C/C++ 模块把「JS 调用」翻译成
「C 函数调用」。

**为什么不走仓颉（Cangjie）`@Interop[ArkTS]`？**

参考实现 `arror/x4h` 用的是仓颉 `@Interop[ArkTS]`。那样做要多引入一整套仓颉
工具链与 `cjpm.toml` 构建，而收益只是省掉一个几十行的 C++ 文件。本项目改用
**纯 NAPI C++**（与 DevEco 模板 `entry/src/main/cpp/napi_init.cpp` 完全同构），
结论是全项目**不含任何仓颉依赖**。

## 2. C ABI 契约

`libcore.so` 只导出两个符号（见 `entry/src/main/golang/main.go`）：

```go
//export GoInvoke
func GoInvoke(service, parameters *C.char) *C.char

//export GoFreeCString
func GoFreeCString(result *C.char)
```

| 项 | 约定 |
| --- | --- |
| `service` | `"Group.Method"`，如 `"CoreService.Start"`；NULL 视为错误 |
| `parameters` | JSON 文本；NULL 或 `""` 等价于 `{}` |
| 返回值 | **永远非 NULL**，永远是合法 JSON 信封 |
| 返回值所有权 | 归调用方，必须用 `GoFreeCString` 或 `free(3)` 释放**恰好一次** |
| 异常 | 不抛异常、不返回错误码；所有错误都进 `error` 字段 |
| 线程 | 可被任意线程调用；Go 侧各服务自行加锁 |

`libbridge.so` 侧**自己重复声明**这两个原型，而不是 `#include "libcore.h"`：

```cpp
extern "C" char *GoInvoke(char *service, char *parameters);
extern "C" void GoFreeCString(char *result);
```

这样做是为了让 `libcore.h`（cgo 生成的构建垃圾）可以被安全删除，也让 NAPI 模块
在没有 Go 工具链的机器上依然能编译。

### 2.1 内存所有权

| 环节 | 分配者 | 释放者 |
| --- | --- | --- |
| ArkTS 传入的 `string` | V8 堆 | V8 GC |
| 传给 Go 的 `char*` | `libbridge` 的 `std::vector<char>` | `libbridge`（栈） |
| Go 返回的 `char*` | Go `C.CString` → `malloc` | `libbridge` `free()` / `GoFreeCString` |
| 回到 ArkTS 的 `string` | V8 | V8 GC |

关键事实：`C.CString` 用的是**系统分配器**，因此 libc 的 `free()` 就是正确配对。
不需要任何跨运行时簿记。

## 3. IPC 信封格式

成功：

```json
{ "success": true, "result": { } }
```

失败：

```json
{ "success": false, "error": "service not found: Nope.Missing" }
```

规则：

* `success` **恒定存在**。
* `result` 在 `success=false` 或缺省结果时**整个字段省略**（`omitempty`）。
* `error` 在成功时省略。
* 返回 JSON 无法序列化时，退化为字面量信封，绝不返回空串。

`ipc.HandleRequest` 是唯一的字符串出口，其契约是
**「永不 panic、永不返回空串、永远返回合法 JSON」**，并有测试
（`main_test.go` 的 `TestHandleRequestAlwaysReturnsJSON`、
`ipc_test.go` 的 `TestInvokeRecoversFromPanic`）守着。

### 3.1 panic 策略

panic 穿越 C ABI 会让进程直接 abort，UI 连提示都来不及显示。因此：

* 允许在实现深处 panic（`assert.Must` / `assert.Must2`），代码更干净；
* 在**两个**地方兜底：`ipc.Registry.Invoke` 与 `main.GoInvoke`；
* 兜底产出统一的错误信封。

## 4. 服务目录（已实现）

| 服务名 | 参数 | 结果 | 备注 |
| --- | --- | --- | --- |
| `VersionService.GetVersion` | `{}` | `{version, semver, bridge, go}` | `bridge` 是 IPC 契约版本，用于发现新旧不匹配 |
| `CoreService.Start` | `{configLocation, assetLocation, start?, fd?（reserved）, socksPort?, httpPort?}` | `{started, configLoaded, configBytes, wired, socksPort, httpPort, version, notes[]}` | `start` 缺省 **false**（只校验）。**没有 `fd`**：字段保留但不读，见 §5.1/§6.5 |
| `CoreService.Stop` | `{}` | `{stopped}` | 幂等；会把 RuntimeInfo 的端口与配置路径一并清零 |
| `CoreService.Status` | `{}` | `{running, version, lastError?}` | **无 `fd`**（契约 §5.6） |
| `CoreService.RuntimeInfo` | `{}` | `{socksPort, httpPort, configLocation?, note?}` | 从未 Start 过时返回默认端口 + 空路径 + 说明 |
| `ConfigService.Generate` | `{nodeId, routingMode, extra, assetDir, bypassChina?}` | `{configJson, socksPort, httpPort, outboundTag, protocol, transport, security, geoAssets, notes[]}` | 返回**文本**，落盘由 ArkTS 做 |
| `LogService.Tail` | `{limit}` | `{lines[], count}` | 环形缓冲，默认 512 行，不落盘（隐私） |
| `LogService.Clear` | `{}` | `{cleared}` | |
| `PingService.Tcping` | `{host, port, timeoutMs?}` | `{latencyMs, reachable, address, ip, resolveMs, error?}` | 裸 TCP 握手耗时，**不经过 Xray** |
| `PingService.SpeedTest` | `{}` | `{speedBps, notes[]}` | **占位**：`speedBps` 恒 0，`notes` 说明原因；**绝不填假数据** |
| `ValidatorService.ValidateConfig` | `{config?, configLocation?, configPath?}` | `{valid, errors[], inboundTags[], outboundTags[]}` | 交给 Xray 自己的管线判定 |

这份清单被 `main_test.go` 的 `expectedRoutes` 固化：增删路由会导致测试失败，
因为对 ArkTS 来说那是破坏性变更。**本表已于 2026-10-11 与契约 §4 对齐**（11 条路由）；
权威描述仍是 [`ipc-contract.md`](ipc-contract.md) §4。

### 4.1 为什么 `CoreService.Start` 默认不启动

`start` 缺省为 `false`，只做「读配置 → 用 Xray 的 loader 解析 → 校验」。

⚠️ **理由已随裁决更新（原表述过时）**：原文写的是"目前没有任何可用方式把 tun fd 交给
Xray 的入站"。冻结裁决（[`ipc-contract.md`](ipc-contract.md) §2）**不再走这条路** ——
vNIC fd 交给 tun2socks，内核只做本地 SOCKS/HTTP 入站。真实理由是：**本地 SOCKS/HTTP
入站的监听与 tun2socks 都还没有实现**，此刻启动只会得到一个**没有任何进程在监听**的进程，
比不启动更难排查。所以 `wired` 目前**恒为 false**，骨架先保证「配置对不对」这个最有价值的
判断可用。

## 5. 构建管线

### 5.1 依赖

| 项 | 值 |
| --- | --- |
| 模块名 | `harmonybridge/core` |
| Xray-core | **`v1.260327.0`**（固定 tag，非伪版本） |
| Go | `go.mod` 的 `go` 指令被 `go mod tidy` 提升为 **1.26**（xray-core 自己声明 `go 1.26`，无法下调），本机实测 1.26.4 |
| 第三方（运行时） | 无。仅标准库 + xray-core |
| 仓颉 | **无** |

选 `v1.260327.0` 而不是参考实现的伪版本
`v1.260327.1-0.20260415235634-c5edc122b70e`：tag 可复现、可审计，
且 CI 不会因为上游 force-push 而漂移。

### 5.2 宿主侧（不需要 NDK，任何开发者机器）

```bash
cd entry/src/main/golang
export GOFLAGS=-mod=mod
go build ./...
go vet ./...
gofmt -l .
go test ./...     # ipc 包必过；根包需要 cgo + 本机 C 编译器
```

**实测结果（本机，2026-10-11）**：

| 命令 | 结果 |
| --- | --- |
| `go build ./...` | **通过**（exit 0） |
| `go vet ./...` | **通过**（exit 0） |
| `gofmt -l .` | **空**（全部已格式化） |
| `go test ./...` | `ipc` 包 **ok**；根包因 `CGO_ENABLED=0` 被 build tag 排除 |

`main.go` 带 `//go:build cgo`，因此 `CGO_ENABLED=0` 的环境也能编译其余包。

> **根包测试需要 cgo + 一个能生成本机可执行文件的 C 编译器。**
> 本机没有 gcc/clang（PATH 里都没有），NDK 自带的 `clang.exe` **不能**代替——
> 它是交叉编译器，既无 MSVC 头也无 MinGW 的 Windows 目标支持
> （实测 `#include <stdio.h>` 直接失败）。因此根包测试（会真正加载整个
> Xray 特性注册表，是「服务目录有没有接上」的唯一自动验证）需在 Linux/WSL CI
> 里以 `CGO_ENABLED=1` 运行。`ipc` 包的测试**不依赖 cgo**，随处可跑。

### 5.3 OHOS 交叉编译

见 `scripts/build-core.sh` / `scripts/build-core.ps1` 与
`entry/src/main/golang/README.md`。核心配方（参考实现已验证的路线）：

```bash
GOOS=android GOARCH=arm64 CGO_ENABLED=1
CC=$OHOS_NDK_HOME/native/llvm/bin/clang
CFLAGS="-target aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/native/sysroot -D__MUSL__"
CGO_CFLAGS="-g -O2 $(llvm-config --cflags) --target=aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/native/sysroot"
CGO_LDFLAGS="--target=aarch64-linux-ohos -fuse-ld=lld -lohcommonevent -lhilog_ndk.z -ltime_service_ndk"
go build -tags "fts5 timetzdata" -ldflags "-s -w" -buildmode=c-shared -o libcore.so .
```

产物落到 `entry/libs/arm64-v8a/libcore.so`，**不入库**（`.gitignore` 已排除，
仅保留 `.gitkeep`）。

### 5.4 NAPI 侧

由 hvigor 经 `entry/build-profile.json5` 的 `externalNativeOptions` 驱动，
`CMakeLists.txt` 产出 `libbridge.so`。它**故意不链接** `libcore.so`：

1. `libcore.so` 是不入库的产物，链接它会让没跑过构建脚本的机器 configure 失败；
2. 链接失败是加载期错误（闪退），`dlopen` 失败是可展示的错误信封；
3. 避免 c-shared 的 `init` 与 OHOS 加载器的时序耦合。

`CMakeLists.txt` 里保留了 `-Wl,--allow-shlib-undefined`，因为 HarmonyOS 的
native 模块默认以 `-z now` 链接。

## 6. 风险与未决问题

> 这一节是本文最重要的部分。以下每条都标注了**已证实 / 未证实**。

### 6.1 Go 没有 `GOOS=ohos` —— 【已证实，且是根本性约束】

Go 官方不支持 OHOS 目标。只能借用 `GOOS=android GOARCH=arm64`：OHOS 内核是
Linux、libc 是 musl，而 Go 的 android 端口本身就是「linux + 非 glibc」，因此
二进制能跑。代价有三：

1. Go runtime 会编入 android 分支（`runtime/internal`、网络栈的若干行为差异）；
2. `proxy/tun` 选中的实现不同（见 §6.5）；
3. Go 的 android 端口是按 **Android bionic** 的头文件约定写的，与 OHOS 的
   musl 头文件存在真实冲突（见 §6.3 问题 3）。

**这条无法通过工程手段消除**，只能记录并与参考实现保持一致。

### 6.2 `-D__MUSL__` 是承重墙 —— 【已证实】

OHOS 的 libc 是 musl。若干依赖用这个宏切换实现（尤其 DNS 解析、pthread、
`resolv` 相关路径）。漏掉它**不会报编译错误**，而是运行期出现难以定位的崩溃。
`CFLAGS` / `CXXFLAGS` / `CGO_CFLAGS` 三处都必须带上。

### 6.3 交叉编译被三个具体问题挡住 —— 【已逐一实测定位】

这是本次准备工作的**最重要结论**。三个问题按被触发的顺序排列，前两个可绕，
第三个是真正的拦路石。

**问题 1：NDK 路径含空格（致命，且报错极具误导性）**

本机 NDK 在 `D:\Harmony\DevEco Studio\sdk\default\openharmony\native`。
Go 在 Windows 上**无法正确处理 `CC` / `CFLAGS` 里的空格**：

```
cgo: C compiler "D:\\Harmony\\DevEco" not found:
     exec: "D:\\Harmony\\DevEco": executable file not found in %PATH%
```

Go 在空格处截断了路径。给 `CC` 加引号**不能**解决，只会把失败点后移：

```
clang: error: no such file or directory: 'Studio/sdk/default/openharmony/native/llvm/include'
clang: error: no such file or directory: 'Studio\sdk\default\openharmony\native\sysroot'
```

因为 `--sysroot` 与 `llvm-config --cflags` 产出的 `-I` 路径同样含空格。
8.3 短名**也救不了**：本机 D 卷**关闭了短名生成**，`%~sI` 原样返回长名。

实测唯一有效的办法是**做一条无空格的 junction**（不复制数据）：

```powershell
cmd /c mklink /J "%LOCALAPPDATA%\ohos-ndk-nospace" "D:\Harmony\DevEco Studio\sdk\default\openharmony\native"
powershell -File scripts\build-core.ps1 -NdkHome "$env:LOCALAPPDATA\ohos-ndk-nospace"
```

两个构建脚本都会在检测到空格时打印这条提示。

**问题 2：OHOS sysroot 里没有 `android/log.h`（致命）**

因为 `GOOS=android`，Go 会编译 `runtime/cgo/gcc_android.c`，它 `#include <android/log.h>`：

```c
#include <android/log.h>          // OHOS 没有这个头，也没有 liblog
...
__android_log_vprint(ANDROID_LOG_FATAL, "runtime/cgo", format, ap);
```

实测报错：

```
gcc_android.c:6:10: fatal error: 'android/log.h' file not found
```

用一个两行声明、把 `__android_log_vprint` 做成 no-op 的 shim 头
（经 `-I` 注入）可以**通过**这一步。注意该文件同时定义了
`x_cgo_inittls`（Android 专用的 TLS slot 探测），在 OHOS 上的正确性**未验证**。

**问题 3：Go 标准库 `net` 的 `socklen_t` 类型不匹配（真正的拦路石）**

过了问题 2 之后，构建死在 **Go 自己的标准库**里：

```
C:\Program Files\Go\src\net\cgo_resold.go:20:76:
cannot use _Ctype_size_t(len(b)) (value of type _Ctype_size_t)
as _Ctype_socklen_t value in argument to (_C2func_getnameinfo)
```

根因（已核对头文件）：

| | 定义 |
| --- | --- |
| OHOS musl（`sysroot/usr/include/alltypes.h:375`） | `typedef unsigned socklen_t;` |
| Go android 端口的假设 | `socklen_t` 与它传入的 `size_t` 宽度一致（bionic 的约定） |

Go 的 android 端口假定的是 **Android bionic** 的头文件约定，而 OHOS 的 musl
头文件把 `socklen_t` 定义成 `unsigned int`，与 `size_t`（64 位）宽度不同，
于是 cgo 生成的调用类型不匹配。

**这不是加个编译选项能解决的**——需要给 Go 标准库打补丁（一个强制转换），
或者提供一个能让 `socklen_t` 与 bionic 宽度一致的头文件覆盖层。

**结论：`GOOS=android` + OHOS 头文件的组合，在本机（Windows 宿主 + Windows NDK）
上无法产出 `libcore.so`。** 这与「Windows 的 clang 能不能交叉到 OHOS」无关——
实测那个能力是**具备**的：

```
clang.exe -target aarch64-linux-ohos --sysroot=<ndk>/sysroot -D__MUSL__ -c probe.c -o probe.o
-> exit 0, ELF64, Machine: AArch64
```

`libbridge.so` 侧不受影响；`entry/libs/arm64-v8a/` 目前只有 `.gitkeep`，
仓库里没有任何 `.so`。

**参考实现 `arror/x4h` 是怎么过的？** 它的 `build.sh` 与我们的配方**逐字相同**
（同样的 `-D__MUSL__`、同样的 `CGO_LDFLAGS`、同样 `GOOS=android`），且其仓库里
**确实提交了一份约 32 MB 的 `libcore.so`**。但它的 Go 源码里**没有任何**
`android/log.h` 的 shim，也没有对 `net` 包的替代实现。因此可以推断它在构建时
**在仓库之外**对 Go 工具链做了处理（例如打过补丁的 Go，或一个 bionic 风格的
sysroot 覆盖层）。这一点**未能证实**，是下一阶段应当优先向该项目求证的问题。
`scripts/build-core.*` 保留原样，等这条链打通后即可直接产出。

### 6.4 为什么只支持 arm64-v8a —— 【已证实的设计决定】

`libcore.so` 是交叉编译到 `aarch64-linux-ohos` 的产物，**没有 x86_64 版本**。
模板默认的 `abiFilters: ["arm64-v8a", "x86_64"]` 会让模拟器分支去同步一个根本
不存在的 `libcore.so`，报出含义不明的错误。因此固定为 `["arm64-v8a"]`。

代价：**模拟器不可用**，只能在真机（或 arm64 模拟器镜像，若有）上验证原生层。

### 6.5 tun fd 交接 —— 【已查明机制，但 OHOS 上未证实，当前最大阻塞点】

Xray 的 tun 入站通过**环境变量**接收 fd，而不是通过配置：

```go
// xray-core/common/platform/platform.go
TunFdKey      = "xray.tun.fd"
AssetLocation = "xray.location.asset"
```

`proxy/tun` 按 build tag 选择后端：

| 文件 | build tag | 是否被 `GOOS=android` 选中 |
| --- | --- | --- |
| `tun_android.go` | `android` | **是** ← 实际会编入的就是它 |
| `tun_linux.go` | `linux && !android` | 否 |
| `tun_darwin.go` | `darwin` | 否 |
| `tun_windows.go` | `windows` | 否 |
| `tun_default.go` | `!linux && !windows && !android && !darwin` | 否 |

即：在 OHOS 上我们只能用 **Android 后端**（读 `xray.tun.fd`，用
`gvisor.dev/gvisor/pkg/tcpip/link/fdbased` 包装 fd）。参考实现
`arror/x4h` 也是这么走的（`os.Setenv(platform.TunFdKey, …)`），说明**路线可行**，
但：

* 这部分**完全没有 OHOS 侧实测**；
* `CoreService.Start` 因此把结果里的 `wired` 恒置为 `false`，并在 `notes` 里
  明确写出「实例已启动但没有可用入站」；
* ⚠️ **`CoreService.Start` 现在连 `xray.tun.fd` 都不再设置了**（2026-10-11）：
  `StartRequest.Fd` 降为 **reserved 字段、只读不写**（`golang/service/core/core.go:71-76`、
  `:245-254`），传了也只在 `notes` 里如实说明"保留、未使用"。所以上表里"实际会编入
  Android 后端"这件事，**在本项目的代码路径上已经不会被触发** —— 保留它是为了解释
  "为什么当初没走通"，不是待办；
* ⚠️ ~~在没有真机验证之前，`registry` 包**刻意不导入** `proxy/tun`（否则只会引入
  默认空实现，徒增体积与误导）~~ —— **此句与事实不符**：`proxy/tun` 一直在二进制里
  （`registry` → `main/json` → `infra/conf` **直接**导入并使用 `proxy/tun`，其
  `init()` 会 `RegisterConfig`）。事实修正见本文件 §7.4 第 3 条。

> ⚠️ **这条链本身也已改判（冻结裁决 `ipc-contract.md` §2）**：下面这份"把 fd 交给 Xray 的
> tun 入站"的清单**不再是要做的事** —— vNIC fd 改交 **tun2socks**，内核只做本地
> SOCKS/HTTP 入站（见 `docs/00-技术路线可行性.md` §11）。清单保留为历史记录。

**打通这条链需要做的（留给下一阶段）**：

1. ArkTS 侧 `VpnExtensionAbility` 创建 tun，把 fd 通过 `CoreService.Start`
   传进来；
2. 确认 fd 在本进程内有效（`VpnConnection` 的 fd 通常需要 `dup` 到当前进程）；
3. 在配置里写入 `proxy/tun`（或 `dokodemo-door` + `freedom` 的组合）入站；
4. `registry/registry.go` 里加上 `_ "github.com/xtls/xray-core/proxy/tun"`；
5. 真机实测：`Wired=true`、能 ping 通、能解析 DNS。

### 6.6 socket protect（`VpnConnection.protect`）—— 【未解决，且目前无接口】

> ⚠️ **改判（冻结裁决 `ipc-contract.md` §2）**：本项目**不再解决这个问题，也不再使用
> `protect()`** —— 防环改由把自身包名放进 `VpnConfig.blockedApplications` 实现。
> 下面记录的是"原方案为什么走不通"的证据，保留不改；**该问题已不在关键路径上**。

Android 上 Xray 生成的每个出站 socket 都必须 `protect()`，否则内核把它重新吞回
tun，形成**无限路由环路**（表现为连接卡死而非报错）。

OHOS 的对应物是 `VpnConnection.protect(socket)`。但当前存在两个问题：

1. **Go 侧目前没有任何 hook 点把 socket 交给 ArkTS。** 上游
   `transport/internet` 在 android 上通过 protect 相关的 cgo 回调实现，本项目
   尚未接；`registry` 包也没有引入对应包。
2. `VpnConnection` 是 ArkTS 侧对象，而 socket 是 Go 侧创建的裸 fd。跨语言的
   「创建后立即回调保护」需要在 socket 创建路径上插入回调（例如
   `internet.RegisterDialerController` 一类的机制），**这部分设计尚未完成**。

在 §6.5 与 §6.6 都解决之前，**原生内核无法真正承载流量**。这也是
`CoreService.Start` 默认只校验的原因之一。

### 6.7 NAPI 垫片未编译验证 —— 【未证实】

`entry/src/main/cpp/napi_init.cpp` 与 `CMakeLists.txt` 是照着 OHOS NAPI NDK 写的
（`napi/native_api.h`、`libace_napi.z.so`、`libdl.so`），但**本机没有跑过 hvigor
的原生构建**，因此：

* `-Wl,--allow-shlib-undefined` 是否足以让 `-z now` 下的 dlsym 模块链接通过，
  未在真机构建中确认；
* `dlopen("libcore.so")` 的搜索路径（先按文件名、再按 libbridge.so 同目录）在
  OHOS 加载器上的实际行为未确认。

这两条都需要一次真实的 `hvigorw assembleHap`。

### 6.8 依赖下载的网络脆弱性 —— 【已证实，环境问题】

本机 `goproxy.cn` 在下载较大的 `.zip` 时频繁报
`local error: tls: bad record MAC`（HTTP/TLS 中间层对长连接的干扰）；
`cloudflare/circl@v1.6.3` 更是三个代理全部失败，最后靠
`GOPROXY=direct` 重试 7 次才从 GitHub 取到。这不影响代码正确性，但会让
`go mod tidy` 反复失败。建议：

* 用 `GOSUMDB=off GODEBUG=http2client=0` 并重试；
* 或配置一个稳定的私有代理 / 供应商镜像；
* CI 里预热 module cache 并做持久化。

### 6.9 其他待办

* `CoreService` 的日志走 `app/log` 的 handler creator，已指向内存环形缓冲；
* `PingService` **不经过 Xray**，因此它测的是「设备到目标的裸 TCP」，不是
  「这个节点能不能翻墙」——后者的实现依赖 §6.5 完成；
* `ValidatorService` 返回的 `inboundTags` / `outboundTags` 目前恒为空数组，
  待 `conf.Config.Build()` 的 tag 提取补齐；
* 真机需要验证：Go runtime 的 GC 在 OHOS 上的行为、`-s -w` 剥离后崩溃栈是否
  还可读（建议 debug 构建时不要 `-s -w`）。

## 7. ⚠ 跨工作流契约不一致（需要 Lead 裁决）

**现状：原生侧与 UI 侧各自定义了一套互不相同、且无法直接互通的契约。**
这是当前最需要立即处理的集成风险，比 §6.3 的交叉编译问题更紧急，因为它是
**双方各自按自己的假设写完了代码**才暴露出来的。

### 7.1 两侧的实际契约

| | 原生侧（本工作流，已实现） | UI 侧（`entry/src/main/ets/core/Bridge.ets`，已实现 Mock） |
| --- | --- | --- |
| 服务名格式 | `Group.Method`，如 `CoreService.Start` | 无点号小驼峰，如 `startCore` |
| 服务名清单 | `CoreService.Start/Stop/Status`、`VersionService.GetVersion`、`LogService.Tail/Clear`、`PingService.Tcping`、`ValidatorService.ValidateConfig` | `version`、`startCore`、`stopCore`、`coreStatus`、`testLatency`、`testSpeed`、`generateConfig`、`runtimeInfo`、`validateNode` |
| `startCore` 参数 | `{fd, assetLocation, configLocation, start}`（**tun fd 模型**） | `{configPath, assetPath}`（**本地 socks/http 入站模型**） |
| `startCore` 结果 | `{started, configLoaded, configBytes, wired, fd, version, notes[]}` | `{pid, socksPort, httpPort}` |
| 版本结果 | `{version, semver, bridge, go}` | `{version}` |
| 状态结果 | `{running, version, fd, lastError?}` | `{running, pid, version}` |
| 延迟测试 | `PingService.Tcping` + `{host, port, timeoutMs}` → `{latencyMs, reachable, address, ip, resolveMs, error?}`（字段原名 `delayMs`，2026-10-11 已按契约 §5.3 改名） | `testLatency` + `{address, port, timeoutMs}` → `{latencyMs, timeout}` |
| 配置校验 | `ValidatorService.ValidateConfig` + `{config, configLocation, configPath}` → `{valid, errors[], …}` | `validateNode` + `?` → `{valid}` |
| 未实现的能力 | — | `testSpeed`、`runtimeInfo`（`generateConfig` 见 §7.4） |

服务名支持**大小写敏感**的精确匹配；`BridgeService.VERSION = 'version'` 这样的名字
在原生侧会被 `ipc.SplitService` 直接判为「不是 Group.Method 形式」并返回错误信封。

### 7.2 根因

`docs/design/ui.md`（UI 工作流拥有）里并没有把服务名与结果结构冻结成一份双方共用的
接口清单。UI 侧先写了 `MOCK_BRIDGE = true` 的内存实现（`Bridge.ets` 第 52 行），
原生侧则按任务书与参考实现 `arror/x4h` 的命名实现。两边都没有错，
只是**缺少一份权威契约**。

### 7.3 建议（供 Lead 裁决，本工作流不擅自改动对方文件）

1. **先冻结一份契约文档**（服务名 + 请求/结果字段），放进 `docs/design/`，
   两侧都以其为准；
2. 几何形状上，`Group.Method` 命名更适合本仓库（可容纳多组服务，
   且已经写进测试 `expectedRoutes`），建议 UI 侧对齐原生侧；
3. `startCore` 的模型差异是**架构级**的，必须明确选择：
   * **tun 模型**（本工作流实现、参考实现采用）：核心持有 tun fd，全局透明代理；
     结果里不该有 `socksPort/httpPort`，而应是 `{started, wired, …}`；
     UI 需要把 `VpnExtensionAbility` 拿到的 fd 传进来。
   * **本地 socks/http 模型**（UI 侧 Mock 假设）：核心监听 127.0.0.1 的 socks/http
     端口，应用自己走代理。这个模型**不需要 tun**，也就绕开了 §6.5 与 §6.6，
     实现难度低得多，但**不是全局 VPN**。
   两者对 `VpnAbility.ets` 与配置生成的影响完全不同，必须先定。
4. `generateConfig` / `runtimeInfo` / `testSpeed` 按职责应属于 ArkTS 侧的
   `CoreConfigManager`（配置生成本就是纯字符串处理），或作为原生侧的**新增服务**
   显式立项；目前它们既不在原生实现里，也没有在契约里。
5. 在契约对齐之前，UI 侧应保持 `MOCK_BRIDGE = true`（现状即如此），
   否则 `NativeBridgeImpl` 只会返回 `native-bridge-not-linked`。

### 7.4 现状更新（2026-10-11）

§7.1~§7.3 记录的是两侧分歧当时的快照，**保留不改**。此后发生的变化登记在此：

1. **契约已收敛**：权威定义在 [`ipc-contract.md`](ipc-contract.md)，UI 侧
   `Bridge.ets` 已全部改为 `Group.Method` 命名。§7.1 表里的"未实现的能力"
   （`testSpeed`、`runtimeInfo`）**已于 2026-10-11 实现并注册** ——
   见 `golang/service/ping/ping.go`（`SpeedTest`，占位：`speedBps` 恒 0 + `notes`）
   与 `golang/service/core/core.go`（`RuntimeInfo`，返回最近一次 Start 声明的端口
   与配置文件路径）。契约 §5 的《原生侧待收敛清单》**七项已全部落地**。

2. **`generateConfig` 的归属已裁决：放在原生侧，不是 ArkTS 侧的 `CoreConfigManager`。**
   §7.3 第 4 条给了两个选项，选后者的理由只有一条但足够硬：**只有 Go 侧能链接
   Xray 自己的 loader**，于是"生成 → 用内核的 loader 验收"可以闭环在同一个
   `go test` 里跑。在 OHOS 工具链打通前这是唯一的自动化验证手段。
   实现见 `golang/service/config/{config.go,build.go}`，验收见 `config_test.go`
   （12 组协议/传输组合必须被 `xcore.LoadConfig` 接受，外加 4 组"内核已删除的特性"
   反向断言）。

3. **`proxy/tun` 其实一直都在二进制里**，§6.5 结尾那句"`registry` 包刻意不导入
   `proxy/tun`（否则只会引入默认空实现）"**与事实不符**，`registry/registry.go`
   的注释也已同步修正。真实链路是：
   `registry` → `main/json` → `infra/conf` →（**直接**导入并使用 `tun.Config`）
   `proxy/tun`，而 `proxy/tun/handler.go` 的 `init()` 会 `RegisterConfig`。
   另外 `tun_android.go` 的 build tag 是 `//go:build android`，空实现是
   `tun_default.go`（`!linux && !windows && !android && !darwin`），GOOS=android
   下选中的并不是空实现。**§6.5 的 TODO 第 4 步（往 registry 里加 proxy/tun）因此
   已经自动满足**。~~剩下要做的只有 fd handoff 与 socket protect 本身~~ —— ⚠️ 这两项
   **均已被冻结裁决取代**：fd 交给 tun2socks（内核不接管 tun）、防环改用
   `VpnConfig.blockedApplications`，见 `ipc-contract.md` §2。

4. **rule 模式在没有 geo 资源时会主动降级**：内核装载 `geoip:`/`geosite:` 规则时
   缺文件是**硬失败**（`failed to open file: geoip.dat`，会让整份配置被拒），
   所以 `ConfigService.Generate` 先探测 `assetDir`，资源不在就不生成按国家分流的
   规则，改为「显式私有网段 CIDR 直连 + 其余走代理」，并在 `notes` 里说明。
   §6.5 里没有预料到这一点，属于新增结论。

5. **本版本内核删掉的东西（对 UI/模型有直接影响）**：`h2`/`h3`/`http` 传输、
   `quic` 传输、`tlsSettings.allowInsecure`、`kcp header & seed`（搬到了
   `finalmask`）。这些在 `build.go` 里都有对应的挡板与 `notes`，反向断言见
   `config_test.go` 的 `TestRemovedFeaturesAreRejectedByCore`。

   5.1（2026-10-11 后续）**挡板从"生成时报错"下沉到"UI 里就不给选"**，并补齐
   `allowInsecure` 的替代字段。此前的问题不是挡住了，而是**三处自相矛盾**：
   UI 下拉仍提供 `h2`/`quic`、分享链接解析也接受它们，一路走到生成才失败；同时
   UI 有一个 `allowInsecure` 开关、内核却已把它变成"写入即整份配置失效"。
   现在：
   - `constants/NodeOptions.ets#TRANSPORT_OPTIONS` 与 v2rayN 的 `Global.Networks`
     逐项一致（`tcp/ws/grpc/httpupgrade/xhttp/kcp`，不含 h2/quic）；
     `TransportKind.H2/QUIC` 仅保留用于忠实解析导入链接 + 精确报错；
   - `TLSSettings` 补齐 `pinnedPeerCertSha256` / `verifyPeerCertByName` /
     `disableSystemRoot` / `echConfigList` / `certificates`（对齐 v2rayN 的
     `Models/CoreConfigs/V2rayConfig.cs:342-346`），`allowInsecure` 明确降级为
     "导入兼容 + 告警、绝不落配置"（语义同 v2rayN `NodeValidator.cs:135-144`）；
   - 新增 `TestTlsReplacementFieldsReachStreamSettings` /
     `TestTlsCertificatesJSONIsValidated`，两者都带反向断言。
   UI 侧说明见 [`ui.md`](ui.md) §5.6。

   5.2（2026-10-11 后续）**「绕过大陆」从"只是开关"变成真的会分流。**
   审计发现它此前**完全不成立**，有三条独立原因，都已修：

   - **`bypassChina` 是空开关**：`AppSettings.bypassChina` 存在、设置页有开关，
     但 `ConnectionViewModel.connect()` 调 `generateConfig` 时没传，
     `GenerateRequest` 里也没有这个字段 —— 拨动开关行为完全不变。现在贯通
     ArkTS → 契约 → `Options.BypassChina`，并按 v2rayN 的两份预设分成
     **白名单**（`custom_routing_white`：大陆直连、其余走代理）与
     **黑名单**（`custom_routing_black`：已知被墙走代理、其余直连）。
     静态数据（中国/海外公共 DNS 的 IP 与域名、私有网段、bittorrent 兜底）
     集中放在 `service/config/rules_data.go`，逐条标注了上游出处行号。

   - **DNS 没有国内外分流，而且 DNS 全走代理**：原先固定 `1.1.1.1 / 8.8.8.8`，
     rule 模式里还有一条 `port 53 → proxy`。配合 `domainStrategy=IPIfNonMatch`
     （域名先解析成 IP 再匹配 `geoip:cn`），等于**用国外 DNS 解析国内域名、
     再拿结果去匹配 `geoip:cn`** —— 规则必然失配。现在按
     `Sample/dns_v2ray_normal` 生成：`geosite:cn → 223.5.5.5 + expectIPs geoip:cn`、
     `geosite:google → 1.1.1.1`（`skipFallback`），并用 `hosts` 给 DoH 域名做静态
     映射避免引导环；`dns.tag = dns-module` 让 routing 能只对 DNS 查询定向。
     国内 DNS 之所以仍能直连，是因为白名单里的「中国公共 DNS IP/域名直连」
     规则排在 DNS 规则**之前**（内核取首个命中，顺序有意义）。

   - **geo 资源一个都没有**：`entry/src/main/resources/rawfile/` 是空的，
     全仓库没有任何 `.dat`，`hasGeoAssets` 恒为 false，`geosite:cn` / `geoip:cn`
     从未进入配置。落地方案是**按需下载**（与 v2rayN 的 `Global.GeoUrl` 同源：
     `Loyalsoldier/v2ray-rules-dat`），而不是把约 15 MB 资源塞进 HAP：
     新增 `service/GeoAssetService.ets`（探测 / 下载 / 删除，写 `.part` 再改名，
     避免半截文件被当成"已就位"），设置页路由分组下新增一行状态 + 点击下载。
     资源目录仍然只有 `<filesDir>/assets` 一处定义（`ConfigStore.assetsDirPath`），
     它同时喂给 `ConfigService.Generate` 的 `assetDir` 与 `CoreService.Start` 的
     `assetLocation`。

   顺带对齐了 v2rayN 对 TUN 入站的处理：`sniffing.routeOnly = true`，
   嗅探出的域名只用于路由匹配、不改写实际目的地（`V2rayInboundService.cs:90`）。
   另注：本版内核的嗅探器是**内建**的（`app/dispatcher/sniffer.go:39-44` 固定注册
   http/tls/bittorrent/quic/utp），因此黑名单的 `protocol: ["bittorrent"]` 规则
   确实会生效；而 `destOverride` **不能**写 bittorrent ——
   `infra/conf/xray.go:75-86` 只接受 http/tls/quic/fakedns。

   **仍未验证**：以上全是配置语义层面的改动，`go test` 只能证明"内核 loader 接受
   这份配置"，**没有任何一条在真机上跑过流量**，所以"大陆域名确实直连了"
   依旧属于 ❓ 而非 ✅。资源就位后的分支更是连 loader 都过不了
   （本地没有 `.dat`），只有一条负向断言守着它（见下）。

### 7.5 现状更新（2026-10-11，契约 §5 收敛这一轮）

本轮把 [TODO.md](../../TODO.md) 里**能在本机验证的部分**做完了，并顺带查出四个既有缺陷。
登记在此，避免下次重复讨论：

1. **`main.go` 曾有一个已提交的编译错误**（本轮修复，属**新发现**）：
   `params := "{}"` 被粘进了上一行的注释里，于是 `params` **从未声明**，
   而 `GoInvoke` 后面直接使用它 → 只要 `CGO_ENABLED=1` 就必然 `undefined: params`。
   **为什么一直没发现**：`main.go` 与 `main_test.go` 都带 `//go:build cgo`，
   而本机没有 C 编译器 → `CGO_ENABLED=0` 下**整个 cgo 包被构建约束排除**，
   `go build ./...` 于是绿着，报错完全隐形。修好后 cgo 侧仍**未在本机验证**
   （没有 gcc/clang），改由 CI 的 `CGO_ENABLED=1` 步骤覆盖（见
   `.github/workflows/verify.yml` 的 `go` job）。已记入 `TODO.md` §2.6。

2. **`CoreService.Start` 不再设置 `xray.tun.fd`**：`fd` 降为 reserved，见 §6.5。

3. **端口现在只有一份权威来源**：`service/config` 的 `DefaultSocksPort` /
   `DefaultHTTPPort`（10808 / 10809）。`CoreService.Start` 接受可选的
   `socksPort`/`httpPort`（非法值回落到默认，并在 `notes` 里说明），
   `ConfigService.Generate` 把同一对端口写进生成的配置里。ArkTS 侧此前有
   **三到四处各自写死的 10808**，现已统一（见 `docs/design/ui.md` §5.7）。

4. **`PingService.Tcping` 的 `delayMs` → `latencyMs` 已落地**，ArkTS 侧本来就按
   `latencyMs` 解析，所以这条改的是**真 bug**（否则真机上一辈子拿不到延迟）。

5. **`Wired` 仍然恒为 false，这是正确的**：本地 SOCKS/HTTP 监听与 tun2socks
   都没有实现，所以"没有任何进程真的在监听"。`SpeedTest` 同理返回 0 + `notes`。
   **不要把这两个值"顺手填上"**。

## 8. 测试与验收

宿主侧（已具备）：

```bash
cd entry/src/main/golang
go test ./...             # ipc 包必过
CGO_ENABLED=1 go test .   # 根包，需本机 C 编译器（Linux/WSL/CI）
```

覆盖内容：服务目录完整性、未知服务/坏 JSON/panic 的错误信封、
版本服务确实拿到 Xray 版本、校验器接受最小 freedom 配置并拒绝垃圾与未知协议、
`CoreService.Status` 与 `Stop` 的幂等性。

真机侧（**待补**，需要一台 HarmonyOS 设备）：

1. `hvigorw assembleHap` 能通过（含 NAPI 原生构建）；
2. App 启动后 `Invoke("VersionService.GetVersion","{}")` 返回真实 Xray 版本；
3. 缺 `libcore.so` 时返回可读错误而不是闪退；
4. tun fd 打通后：`Wired=true`、建立连接、DNS 正常、无路由环路。
