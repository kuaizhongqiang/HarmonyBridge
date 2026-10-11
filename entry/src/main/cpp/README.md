# libbridge.so —— ArkTS ↔ NAPI ↔ Go 调用链

本目录是原生侧的**桥接层**。它自己不实现任何代理逻辑，只做三件事：
解析入参、把请求转交给 Go 内核、把结果转成 JS 字符串。

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
| `Invoke(service, paramsJson) => string` | 唯一入口，**永远返回字符串**，永不抛异常 |
| `CoreAvailable() => string` | 已加载的 `libcore.so` 绝对路径 / 空串 / `"unknown"` |
| `GoFreeCString(ptr) => void` | 仅为 C ABI 对齐而导出；ArkTS 拿不到裸指针，实际不使用 |

`Invoke` 在任何失败路径上都返回 `{"success":false,"error":"…"}`，包括：
入参不是字符串、service 为空、`libcore.so` 缺失、`dlsym` 失败、Go 侧 panic。
因此 ArkTS 侧只需要一条 `JSON.parse` + 判断 `success` 的代码路径，
不需要 try/catch 原生异常，也不会因为缺 .so 而闪退。

## 构建

由 hvigor 通过 `entry/build-profile.json5` 的 `externalNativeOptions` 驱动：

```
entry/build-profile.json5
  └─ externalNativeOptions.path = ./src/main/cpp/CMakeLists.txt
       └─ add_library(bridge SHARED napi_init.cpp)   →  libbridge.so
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
