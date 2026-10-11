# libbridge.so —— ArkTS ↔ NAPI ↔ Go 调用链

本目录是原生侧的**桥接层**。它对上层提供两个互不相干的调用面：

1. **控制面**（`Invoke`）：解析入参、把请求转交给 Go 内核、把结果转成 JS 字符串。
2. **数据面**（`Tun2socks*`，见下文"数据面"一节）：加载并驱动 tun2socks，把系统交给
   扩展的 vNIC fd 接到 `127.0.0.1:<socksPort>` —— 也就是内核的本地 SOCKS 入站。

它自己不实现任何代理逻辑，也没有 TCP/IP 栈：协议栈在 Xray-core 里，
用户态 TCP/IP 栈在 hev-socks5-tunnel 里。

```
┌──────────────────────────────────────────────────────────────────┐
│ ArkTS / ArkUI                                                    │
│   import bridge from 'libbridge.so'                              │
│   const raw = bridge.Invoke("CoreService.Start", '{"fd":42}')    │
└────────────────────────────┬─────────────────────────────────────┘
                             │ napi_call_function
┌────────────────────────────▼─────────────────────────────────────┐
│ libbridge.so   （napi_init.cpp，本目录）                          │
│   Invoke(service, paramsJson): string                            │
│     · napi_typeof / napi_get_value_string_utf8 校验入参            │
│     · dlopen("libcore.so") + dlsym("GoInvoke")   （惰性、缓存）    │
│     · free() 掉 Go 返回的缓冲区                                    │
└────────────────────────────┬─────────────────────────────────────┘
                             │ char* GoInvoke(char*, char*)
┌────────────────────────────▼─────────────────────────────────────┐
│ libcore.so   （Go，-buildmode=c-shared）                          │
│   GoInvoke → ipc.HandleRequest → 服务处理器 → JSON 信封            │
└────────────────────────────┬─────────────────────────────────────┘
                             │ Go API
┌────────────────────────────▼─────────────────────────────────────┐
│ Xray-core（dispatcher / inbound / outbound / dns / …）            │
└──────────────────────────────────────────────────────────────────┘
```

## 为什么用 dlopen 而不是链接 libcore.so

CMake 里**故意没有** `target_link_libraries(bridge ... libcore.so)`：

1. `libcore.so` 是 Go 交叉编译出来的构建产物，**不入库**。链接它会让
   hvigor 在没有 Go 工具链、还没跑过 `scripts/build-core.*` 的机器上直接
   configure 失败，而这恰恰是新同事 clone 后的第一件事。
2. 链接失败是**加载期**错误：整个 HAP 起不来，用户看到的是闪退而不是提示。
   用 `dlopen` 则退化为一个正常的错误信封，UI 可以弹出“内核尚未构建”。
3. 避免 c-shared 的 `init` 与 OHOS 加载器之间的时序耦合。

`CMakeLists.txt` 里保留了 `-Wl,--allow-shlib-undefined`，因为 HarmonyOS 的
native 模块默认以 `-z now` 链接，未解析符号会变成硬链接错误。

## 数据面：tun2socks（libhevsocks5tun.so）

冻结契约（`docs/design/ipc-contract.md` §2）规定数据面是
`TUN fd → tun2socks → 127.0.0.1:<socksPort> → libcore.so`，**不是**把 fd 交给内核。

实现用 `heiher/hev-socks5-tunnel`（**纯 C、MIT**）。选它的两个理由：

- 纯 C → 不需要 Go 工具链 fork，绕开 B2（Go 没有 `GOOS=ohos` 目标）；
- MIT → 仓库保持 MIT + Xray-core(MPL-2.0) 的边界，GPL 版会失守。

它和 `libcore.so` 一样用 `dlopen`/`dlsym` **惰性**加载，原因也相同：

- 没有它也能构建、能启动，`Tun2socksStart` 只是返回一个可读的错误信封
  （内含 `dlerror()` 文本），而不是加载期崩溃；
- 它**不存在于本仓库**：由 `scripts/build-tun2socks.*` 编到
  `entry/libs/arm64-v8a/libhevsocks5tun.so`，与 `libcore.so` 同目录、同一套查找逻辑。

**线程模型**：`hev_socks5_tunnel_main_from_str()` 是**阻塞**的（直到
`hev_socks5_tunnel_quit()` 被调用或出错），所以 `Tun2socksStart` 把它放到一个
`std::thread` 上跑并立即返回；`Tun2socksStop` 从 JS 线程调 `quit()` 再 join，并把
隧道线程的退出码/错误一起回传 —— 真机上这是唯一能区分"我们停的"与"它自己挂了"的地方。

⚠️ **未验证**：这套代码与那个 `.so` 都没有在真机上跑过。hev 的后端能否处理 OHOS 的
vNIC fd，就是公开问题 U3。

## 内存契约

| 步骤 | 谁分配 | 谁释放 |
| --- | --- | --- |
| `service` / `params` 入参 | ArkTS（V8 堆） | V8 |
| 传给 Go 的 `char*` | 本模块的 `std::vector<char>` | 本模块（栈上） |
| Go 返回值 `char*` | Go，`C.CString` → `malloc` | 本模块 `free()`（或 Go 导出的 `GoFreeCString`） |
| 返回给 ArkTS 的字符串 | V8 | V8（GC） |

关键点：`C.CString` 用的是**系统分配器**，所以 libc 的 `free()` 就是正确的
配对释放；不需要任何跨运行时的簿记。本模块优先调用 Go 导出的
`GoFreeCString`（如果 dlsym 到了），否则回退到 `free()`——两者等价。

## 导出的符号

`libbridge.so` 对 ArkTS 导出（见 `types/libbridge/Index.d.ts`）：

| 符号 | 说明 |
| --- | --- |
| `Invoke(service, paramsJson) => string` | 控制面入口，**永远返回字符串**，永不抛异常 |
| `CoreAvailable() => string` | 已加载的 `libcore.so` 绝对路径 / 空串 / `"unknown"` |
| `GoFreeCString(ptr) => void` | 仅为 C ABI 对齐而导出；ArkTS 拿不到裸指针，实际不使用 |
| `Tun2socksStart(configYaml, tunFd) => string` | 在 vNIC fd 上启动隧道，**立即返回**（主循环在独立线程） |
| `Tun2socksStop() => string` | 停止隧道；幂等，并回传隧道线程的退出码 / 错误 |
| `Tun2socksStats() => string` | 隧道收发计数（`hev_socks5_tunnel_stats`） |
| `Tun2socksAvailable() => string` | `libhevsocks5tun.so` 的绝对路径 / 空串 / `"unknown"` |

前三个属于控制面、后四个属于数据面。`Tun2socks*` 全部返回与 Go 内核**同形**的信封
（`{success, result, error}`），所以 ArkTS 侧只有一条解析路径。

`Invoke` 在任何失败路径上都返回 `{"success":false,"error":"…"}`，包括：
入参不是字符串、service 为空、`libcore.so` 缺失、`dlsym` 失败、Go 侧 panic。
因此 ArkTS 侧只需要一条 `JSON.parse` + 判断 `success` 的代码路径，
不需要 try/catch 原生异常，也不会因为缺 .so 而闪退。

## 构建

由 hvigor 通过 `entry/build-profile.json5` 的 `externalNativeOptions` 驱动：

```
entry/build-profile.json5
  └─ externalNativeOptions.path = ./src/main/cpp/CMakeLists.txt
       └─ add_library(bridge SHARED napi_init.cpp tun2socks_bridge.cpp)  →  libbridge.so
```

`abiFilters` 固定为 `arm64-v8a`：Go 内核只有 aarch64 版本，列出 `x86_64`
只会让模拟器同步出一个含义不明的“缺少 libcore”错误。

## 排查

| 现象 | 原因 |
| --- | --- |
| `Invoke` 返回 `libcore.so is not available…` | 没跑 `scripts/build-core.ps1`，或产物不在 `entry/libs/arm64-v8a/` |
| 返回 `dlsym(GoInvoke) failed` | `libcore.so` 存在但不是本项目的产物（或架构不对） |
| 返回 `the service name must be a string` | ArkTS 传了非字符串（例如把 JSON 对象直接传进来了） |
| 返回 `service not found: X.Y` | 服务名拼错，或 `app/app.go` 里漏了服务的空白导入 |
| `Tun2socksStart` 返回 `libhevsocks5tun.so is not available: …` | 没跑 `scripts/build-tun2socks.*`，或产物不在 `entry/libs/arm64-v8a/`。错误里的 `dlerror()` 文本会指明是"文件不存在"还是"架构不对" |
| `Tun2socksStop` 返回 `has no hev_socks5_tunnel_quit` | 那个 `.so` 不是 hev-socks5-tunnel 2.4.6+ 的产物（更早的版本没有 `quit`）。为防挂死，此时**不**去 join 线程 |
