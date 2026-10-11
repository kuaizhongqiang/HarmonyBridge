# 原生代理内核（Go / libcore.so）

本目录是 HarmonyOS 客户端**原生侧的全部 Go 代码**。编译产物是一个 C 共享库
`libcore.so`，内嵌 Xray-core，通过两个 C ABI 符号暴露给上层的 NAPI 桥
（`entry/src/main/cpp`）。

```
ArkTS  →  libbridge.so (NAPI C++)  →  libcore.so (Go, c-shared)  →  Xray-core
```

## 目录结构

| 路径 | 作用 |
| --- | --- |
| `main.go` | C ABI 入口：`GoInvoke` / `GoFreeCString`，含 panic 兜底 |
| `ipc/` | 服务注册表 + JSON 信封编解码（`Group.Method` 路由） |
| `app/app.go` | 汇总导入：所有服务 + 特性注册表 |
| `registry.go` | 空白导入 Xray 的代理/传输/特性包，保证二进制功能完整 |
| `service/core/` | `CoreService.Start / Stop / Status / RuntimeInfo` —— 内核生命周期与本地入站端口 |
| `service/config/` | `ConfigService.Generate` —— 节点 JSON -> `config.json`（生成后立即用 Xray 自己的 loader 自检；返回文本，落盘由 ArkTS 侧的 `ConfigStore` 完成） |
| `service/version/` | `VersionService.GetVersion` —— 报告 Xray-core 版本 |
| `service/log/` | 环形缓冲日志 + `LogService.Tail / Clear` |
| `service/ping/` | `PingService.Tcping`（TCP 连接延迟测试）+ `PingService.SpeedTest`（本阶段是**明确的桩**：`speedBps` 恒为 0，不伪造测量值） |
| `service/validator/` | `ValidatorService.ValidateConfig` —— 用 Xray 自己的管线校验配置 |
| `assert/` | 供 C 边界使用的 panic-on-error 小工具 |

## 服务目录（IPC 契约）

服务名格式为 `Group.Method`，参数与返回值都是 JSON。统一信封：

```json
{ "success": true,  "result": { } }
{ "success": false, "error": "描述" }
```

| 服务名 | 参数 | 结果 |
| --- | --- | --- |
| `CoreService.Start` | `{fd?:int(reserved), assetLocation:string, configLocation:string, socksPort?:int, httpPort?:int, start:bool}` | `{started, configLoaded, configBytes, wired, socksPort, httpPort, version, notes[]}` |
| `CoreService.Stop` | `{}` | `{stopped:bool}` |
| `CoreService.Status` | `{}` | `{running, version, lastError?}` |
| `CoreService.RuntimeInfo` | `{}` | `{socksPort, httpPort, configLocation?, note?}` |
| `VersionService.GetVersion` | `{}` | `{version, semver, bridge, go}` |
| `LogService.Tail` | `{limit:int}` | `{lines:[string], count:int}` |
| `LogService.Clear` | `{}` | `{cleared:int}` |
| `PingService.Tcping` | `{host:string, port:int, timeoutMs?:int}` | `{latencyMs, reachable, address, ip, resolveMs, error?}` |
| `PingService.SpeedTest` | `{}` | `{speedBps, notes[]}`（`speedBps` 恒为 0 = 未测量） |
| `ValidatorService.ValidateConfig` | `{config?:string, configLocation?:string, configPath?:string}` | `{valid, errors[], inboundTags[], outboundTags[]}` |

> `CoreService.Start` 默认只做**校验不启动**（`start` 缺省为 `false`）。
>
> **数据面契约**（`docs/design/ipc-contract.md` §2）：vNIC fd **不交给内核**，链路是
> `tun → tun2socks → 本地 SOCKS/HTTP 入站 → Xray 出站`，内核只拥有本地入站。
> 因此 `fd` 是**保留字段、当前未使用**（传了也只会出现在 `notes` 里），
> `socksPort` / `httpPort` 缺省回落到 `service/config` 的
> `DefaultSocksPort`(10808) / `DefaultHTTPPort`(10809)。
> `wired` 的语义是「本地 SOCKS/HTTP 入站已监听、出站可路由」——**本阶段没有任何东西真的在监听，
> 所以 `wired` 恒为 `false`**；`notes` 每次都把这一点说明白。
> `PingService.SpeedTest` 同理：结果里的 0 表示"没测"，不是"测出来是 0 bit/s"。

## 主机侧自检（不需要 NDK）

在**任何**装有 Go 1.26+ 的机器上都可以先验证代码本身是好的：

```bash
cd entry/src/main/golang
export GOFLAGS=-mod=mod
go build ./...
go vet ./...
gofmt -l .          # 应输出为空
go test ./...       # 不依赖 cgo 也能跑：见下方「主机侧测试」一节
```

`main.go` 带 `//go:build cgo` 标签，因此 `CGO_ENABLED=0` 的环境也能编译其余部分。

> **注意：仓库根包（`harmonybridge/core`）的测试需要 cgo。**
>
> `main_test.go` 与 `main.go` 同包，而后者带 `//go:build cgo`，所以：
>
> * `CGO_ENABLED=0` 时 `go build ./...` 正常工作，但根包不会出现在
>   `go list ./...` 里，`go test .` 会报
>   `build constraints exclude all Go files`；
> * 要真正执行根包测试，需要
>   `CGO_ENABLED=1` **且本机有一个能生成本机可执行文件的 C 编译器**
>   （Linux 上是 gcc/clang；Windows 上需要 MinGW-w64 或 MSVC）。
>
> 在 Windows 上只装了 OHOS NDK 的机器上，NDK 自带的 `clang.exe`
> **无法**代替：它是交叉编译器，既没有 MSVC 头，也没有 MinGW 的
> Windows 目标支持（实测 `#include <stdio.h>` 即失败），因此不能用来构建
> 本机的 cgo 测试二进制。这种情况下请改用 WSL 或 Linux CI 跑根包测试。

### 主机侧测试（不依赖 cgo，也无真机）

| 测试 | 位置 | 覆盖 |
| --- | --- | --- |
| 服务目录黄金列表 | `service/core/core_test.go` | 空白导入 `app` 后比对 `ipc.Default.Names()` 与契约 §4 的 11 项（含字典序）——`main_test.go` 的 cgo 版本在同一台**没有 C 编译器**的机器上跑不了，这份是它的无 cgo 替身 |
| `CoreService.*` | `service/core/core_test.go` | RuntimeInfo 未启动/已 Stop 的取值；Status 不含 `fd`；Start 诊断路径（`started=false`、`wired=false`、端口默认/给定、非法端口回落、`notes` 说明） |
| `PingService.*` | `service/ping/ping_test.go` | 在真实 `127.0.0.1` 监听上验证 Tcping 成功路径；参数校验；SpeedTest 不伪造测量值；`latencyMs`/`socksPort`/`httpPort` 等字段名防漂移 |
| 信封与路由 | `ipc/ipc_test.go` | 服务名拆分、未知服务、非法 JSON |

## 交叉编译到 OHOS（aarch64-linux-ohos）

**不要**手工敲这一段——用仓库根目录的脚本：

```bash
scripts/build-core.sh        # Linux / macOS (或 WSL / MSYS)
powershell scripts\build-core.ps1   # Windows
```

脚本做的事就是下面这套已验证的配方：

```bash
export CC=$OHOS_NDK_HOME/native/llvm/bin/clang
export CXX=$OHOS_NDK_HOME/native/llvm/bin/clang++
export AR=$OHOS_NDK_HOME/native/llvm/bin/llvm-ar
export LD=$OHOS_NDK_HOME/native/llvm/bin/ld.lld
export STRIP=$OHOS_NDK_HOME/native/llvm/bin/llvm-strip
export CFLAGS="-target aarch64-linux-ohos --sysroot=${OHOS_NDK_HOME}/native/sysroot -D__MUSL__"
export LLVMCONFIG=$OHOS_NDK_HOME/native/llvm/bin/llvm-config
export CGO_ENABLED=1
export GOOS=android          # Go 没有 GOOS=ohos；android/arm64 是最接近的非 glibc 端口
export GOARCH=arm64
export CGO_CFLAGS="-g -O2 `$LLVMCONFIG --cflags` --target=aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/native/sysroot"
export CGO_LDFLAGS="--target=aarch64-linux-ohos -fuse-ld=lld -lohcommonevent -lhilog_ndk.z -ltime_service_ndk"
export GOFLAGS=-mod=mod

go build -tags "fts5 timetzdata" -ldflags "-s -w" -buildmode=c-shared -v -o libcore.so .
```

产物：

```
libcore.so   →   entry/libs/arm64-v8a/libcore.so
libcore.h    →   自动删除（构建垃圾，且不属于 git）
```

`libcore.so` 是**构建产物，永不入库**（见根目录 `.gitignore`）。每个 ABI 约 32 MB，
且内含 GPL/MPL 代码，入库会污染整个仓库历史。

## 交叉编译的坑（务必先读）

1. **Go 没有 `GOOS=ohos`。** 只能借用 `GOOS=android`。这条路可用的原因是
   OHOS 用 musl libc、内核为 Linux，而 Go 的 android 端口本身就是
   “linux + 非 glibc”。代价是 Go 会把 runtime 里的 android 分支编进来，
   并且在 `proxy/tun` 里选中的是 **`tun_android.go`**（该文件用
   `golang.org/x/sys/unix` 的 `fdbased`）而不是 `tun_linux.go`
   （其 build tag 是 `linux && !android`）。两个后端在 OHOS 上的实际行为
   **未经验证**。

2. **`-D__MUSL__` 不是装饰。** OHOS 的 libc 是 musl，某些依赖用它来切换
   实现（尤其涉及 `getaddrinfo`、`pthread` 与 `resolv`）。漏掉它会得到运行期
   的诡异崩溃而不是编译错误。

3. **`CGO_LDFLAGS` 里的三个 -l 是有原因的。** `libohcommonevent`、
   `libhilog_ndk.z`、`libtime_service_ndk` 是 OHOS 的 NDK 库；Go runtime 在
   android 端口下会引用它们（公共事件、hilog、时间服务）。它们必须在链接期
   可见，否则报 undefined reference。

4. **Windows 宿主机的 clang 能否当 `CC`。** 见 `scripts/build-core.ps1` 头部的
   实测结论。要点是 Go 的 cgo 会直接 exec `CC` 并把 `CGO_CFLAGS` 传给它——
   `D:\Harmony\DevEco Studio\...\llvm\bin\clang.exe` 是一个能正确交叉到
   `aarch64-linux-ohos` 的**原生 Windows 可执行文件**（Target 为
   `x86_64-w64-windows-gnu`，但通过 `--target=` 交叉），因此理论上可用；
   实际是否通过见脚本运行结果与 `docs/design/core.md` 的“风险”一节。

5. **不要加 `-buildmode=c-archive`。** 我们要的是 `c-shared`，因为它是通过
   `dlopen` 在运行期加载的。
