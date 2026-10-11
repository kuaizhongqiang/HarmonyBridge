# TODO — 已知问题与待办

> 这份清单记录**当前已知的、尚未解决的问题**，包括三类：挡住目标的硬阻塞、
> 代码/文档里已确认的缺陷、以及"不知道行不行"的未证实项。
>
> 最后更新：2026-10-11（与 `docs/00-技术路线可行性.md` §10.4、§11 同一轮）
> 上一轮修完的条目已移入 §3，**保留在这里是为了避免重复讨论**。
>
> **状态标记**
> - ❌ 未解决 / 未做
> - ⚠️ 已知，低优先级或可接受
> - ❓ 未证实（不知道行不行，需要真机或构建才能回答）
> - ✅ 已完成 / 已解除（只列与下面问题相关的，便于避免重复讨论）
>
> **本文件的纪律**：只有真的做了才标 ✅。任何"声称已改但实际没改"的条目
> 本身就是缺陷，必须记录，不能靠改状态糊过去。
> 本轮就是靠这条纪律发现 `main.go` 里那个**被注释吞掉的语句**（§4.6）。

---

## 0. 本轮（2026-10-11）做完的事 —— 一句话

把"**不需要真机就能验证的部分**"做完了：文档矛盾、Go 服务目录收敛、两处真 bug、
以及 tag → CI → 发布流水线。**真机相关的部分一件都没变**（没有真机是硬约束）。

而"本轮查出的新缺陷"几乎都有一个共同特征：**它们都被"看起来是绿的"掩盖着** ——
`go build ./...` 绿（因为 cgo 包被构建约束排除）、`TODO.md` 说"ArkTS 从未编译"
（所以没人去编）、契约说 `pid` 恒为 0（但 UI 拿它当成功判据）。详见 §4。

---

## 1. 挡住「绕过大陆」的硬阻塞

### 1.1 ❌ B2：Go → OHOS 工具链 —— 内核 `libcore.so` 编不出来

**位置**：`scripts/build-core.ps1` 头部注释

**现象**：Windows 宿主上交叉编译 `libcore.so` 失败。根因不是"缺参数"，而是
Go 标准库里的 `socklen_t` 与 OHOS musl 的 `typedef unsigned socklen_t` 宽度不一致，
**必须给 Go 打补丁**，不是加编译选项能解决的。

**为什么挡住目标**：没有 `libcore.so` 就没有内核 → 没有本地 SOCKS 入站 → 没有分流。

**怎么解**：在 Linux / WSL 上构建（脚本已按这条路写）。

> 👉 **完整的换机执行说明已单独成文**：[`docs/04-Linux构建任务书.md`](docs/04-Linux构建任务书.md)
> —— 环境准备、两个必须解决的障碍（`android/log.h` shim、`socklen_t` 补丁）、
> TLS 验收检查、报告模板都在那里。**这一节只记状态，操作步骤看那份。**

**当前状态**：本机（Windows）依然走不通。**这是最靠前的工程任务，因为它不需要真机。**

> ⚠️ **本轮新增的实测结论**：本机**连 WSL 都没装**（`wsl --status` 返回
> "未安装用于 Linux 的 Windows 子系统"），也没有 Docker。所以"在 Linux 上编"
> 这条路**本机当前一步都走不了** —— 先得装 WSL + 一个发行版，或者另找一台 Linux 机器。
> 这一点此前没有被记录过，导致"解 1.1"看起来比实际更容易。
>
> ✅ **同时澄清了两个被过度担心的点**（2026-10-11 核实上游仓库）：
> `socklen_t` 冲突与 Windows 无关，**Linux 上依然存在**（头文件约定冲突）；
> 但"NDK 路径含空格"和"8.3 短名"这些纯 Windows 麻烦在 Linux 上会消失。

---

### 1.2 ❌ B3：没有真机

**为什么挡住目标**：以下**全部**没有在真实设备上验证过 —— 网卡能否创建、内核能否启动、
tun2socks 能否接管 fd、分流规则是否真的生效。本机 SDK 也没有 `arm64-v8a` 的模拟器镜像
（U2 的模拟器路线在动手前就已断）。

**怎么解**：采购一台 arm64 OHOS 真机，然后按 `AGENT.md` §9 执行
（**注意：§9 第 4 步已在本轮改对**，不再是"把 fd 交给 Xray tun 入站"）。

**当前状态**：纯资源阻塞，没有技术手段可以绕过。

---

### 1.3 ❌ `libhevsocks5tun.so` 从未构建成功过

**位置**：`scripts/build-tun2socks.ps1` / `.sh`

**现象**：配方是按上游 Makefile + 本机 NDK 布局**推出来**的，从未执行成功。

> ✅ **两个原来的"未确认"已核实（2026-10-11，查上游仓库 `heiher/hev-socks5-tunnel` 2.18.0）**：
> 1. **上游确实提供 `build.mk`**（仓库根目录），且 `SRCFILES=$(call rwildcard,$(SRCDIR)/,*.c *.S)`
>    —— 所以"配方推错、SRCFILES 为空"这个担心**不成立**；
> 2. `src/` 下**确实有 .c 源码**（`hev-main.c` / `hev-socks5-tunnel.c` / `hev-tunnel-linux.c` …），
>    不是空壳；许可证是 **MIT**，与我们的边界兼容。
>
> ❓ **仍未验证**：`third-part/{lwip,yaml,hev-task-system}` 能否交叉到 OHOS musl；
> 上游 `-Werror` 会不会把交叉编译的告警变成硬失败（脚本已加 `-Wno-error`）。
> ⚠️ 另有一个结构细节：`.gitmodules` 里除了三个 `third-part/*` 还有 **`src/core`**，
> 脚本用 `git clone --recursive`，需确认嵌套 submodule 真的拉下来了。

**为什么挡住目标**：这是数据面的实现本体。没有它，`Tun2socksStart` 只能返回
`libhevsocks5tun.so is not available: …`。

**怎么解**：在 Linux 上跑 `bash scripts/build-tun2socks.sh <ndk>`（同样受 §1.1 的
WSL 未安装制约）。**如果失败，如实记录失败点**——那份记录本身就是本条的交付物，不要绕过。
操作细节见 [`docs/04-Linux构建任务书.md`](docs/04-Linux构建任务书.md) §7。

---

## 2. 代码 / 文档里已确认的缺陷（未修）

### 2.1 ❌ IPv6 泄漏面：`VpnAbility.ets#buildVpnConfig` 仍是"只接管 v4"

**位置**：`entry/src/main/ets/vpnability/VpnAbility.ets:359`（`isIPv6Accepted: false`）
与同函数只挂 IPv4 默认路由

`docs/00-技术路线可行性.md` §7.2 的风险表把这种形态专门点过名：
"IPv6 泄漏 | 中 | 中 | 始终接管 v6，空 gateway + `isDefaultRoute:false` | ❌ **未实施**"。
**现在依然是那个未实施的形态** —— 也就是说，真机上 IPv6 流量会绕过 VPN 直接出去。

**为什么只标这里而不是当硬阻塞**：它不影响"能不能连"，只影响"会不会漏"；
但它是一条真实的隐私/功能缺陷，不该被埋没。

**怎么解**：按 `docs/00` §7.2 给的做法接管 v6（空 gateway + `isDefaultRoute: false`），
并**在真机上确认 `statistics.getIface*Bytes` 的读数**。**需要真机。**

---

### 2.2 ⚠️ `blockedApplications` 已接线，但真机未验证

**位置**：`entry/src/main/ets/vpnability/VpnAbility.ets:366`

本轮把防环机制**真正接上了**（此前完全没接）：`blockedApplications: [APP_BUNDLE_NAME]`。
SDK 依据（🧪 本地 `.d.ts` 逐行核对）：
`@ohos.net.vpnExtension.d.ts:388` 声明 `blockedApplications?: Array<string>`（bundleName 字符串数组）；
`:378-381` 说明"只有**不在**列表里的应用才按 routes 被代理"；`:371`/`:383` 声明它与
`trustedApplications` **互斥**，因此只设前者。

**为什么仍是 ❓**：`VpnAbility.ets:335` 自己就标了"未验证"。**真机上"自身包名在
blockedApplications 里是否确实止住环路"没有任何证据。** 验不到的症状是"一连就断网"。

> 顺带：这条此前是**文档说已裁决、代码里根本没接**的状态 ——
> 文档写"改用 `blockedApplications` 防环"，而 `buildVpnConfig()` 里两个名单都没设。
> 这与 §3.2 的"声称已改"是同一类问题：**文档的结论被当成了实现**。

---

### 2.3 ⚠️ `CoreService.RuntimeInfo` 与 `PingService.SpeedTest` 是**占位**，不是功能

- `RuntimeInfo`：返回**最近一次 `CoreService.Start` 声明的**端口与配置文件路径。
  它**不探测**任何真实监听状态（因为本阶段没有监听）。
- `SpeedTest`：`speedBps` **恒为 0** + `notes` 说明。

契约 §4.1 明确允许这个形态（"不得伪造测量值"），所以这不是缺陷，**但它很容易被误读成
"已实现测速"**。UI 侧必须读 `notes` 再决定展示什么。真机 + 活内核之后才能有真值。

---

### 2.4 ⚠️ `docs/design/ui.md` §5.2 的 service 表仍是契约冻结前的旧写法

**位置**：`docs/design/ui.md:238-250` 附近

表里写的是 `version` / `startCore {configPath, assetPath}` / `testLatency {address,…}` /
`runtimeInfo {}` 这类**无点小驼峰**名字与旧参数名，与契约 §1/§4 和现在的
`Bridge.ets`（`Group.Method` + `configLocation`/`assetLocation`）**直接冲突**。
本轮只在同文件 §5.7 末尾加了提示，**没有改这张表**（它是 UI 工作流的产物，且改动面较大）。

**怎么解**：把该表按契约 §4 重写一次，或直接删表改为指向契约。

---

### 2.5 ⚠️ `wired=false` 没有独立的界面提示

`ConnectionViewModel.ets:46` 的注释已经把这件事写下来了：要加一条"本地入站未监听"
的界面提示，需要新增 `$r('app.string.*')` 资源（按 `AGENT.md` 第 3 节第 8 条，
文案必须走资源文件）。本轮把它落在 `@Trace coreWired` + 日志里，**界面上没有独立提示**。

---

## 3. 本轮已解决（记录在案，避免重复讨论）

### ✅ 3.1 `expectedRoutes` 漏了 `ConfigService.Generate`（原 §2.1）

已补齐为 **11 项**并严格字典序（`main_test.go`），另加"排序/漂移即失败"的断言。
`service/core/core_test.go` 里还有一份**不依赖 cgo** 的同源守卫
（`TestRegisteredCatalogueMatchesContract`），所以这个漂移在本机也能被拦住。

### ✅ 3.2 9 处跨文档矛盾**全部已改**（原 §2.2，最严重的那条）

`AGENT.md` ×3（另连带 `:61`、`:349-351`）、`01-架构设计.md` ×4（另连带 `:242`）、
`02-开发计划.md` ×3（含 `:75` 出口条件）、`core.md` §6.5。
逐行状态见 `docs/00-技术路线可行性.md` §10.4（该节也已从"几乎全部未修改"更新为"全部已改"）。

### ✅ 3.3 `PingService.Tcping` 的 `delayMs` → `latencyMs`（原 §2.3）

Go 结构体字段、json tag、README 表格全部改完。
**这不是纯改名，而是修了一个静默 bug**：ArkTS 侧 `Bridge.testLatency` **本来就在读
`latencyMs`**，所以真机上永远拿不到延迟。

### ✅ 3.4 `docs/design/core.md` §6.5 原句的错误表述（原 §2.4）

已就地标注"此句与事实不符"并指向 §7.4 的修正（`proxy/tun` 一直都在二进制里）。

### ✅ 3.5 ipc-contract §5「待收敛清单」七项全部落地（原 §2.5）

`fd` 降为 reserved、`socksPort`/`httpPort`、`RuntimeInfo`、`SpeedTest`、
`expectedRoutes`、`Status` 无 `fd`、`extra` 语义 —— 全部完成，
契约 §4/§5 的状态列已同步为 ✅（并有"不得把计划当已实现"的把关）。

### ✅ 3.6 `MOCK_BRIDGE = true` 仍是**正确状态**

`ets/core/Bridge.ets:97`。**理由已经变了**：不再是"原生侧没实现"（那部分做完了），
而是**没有真机、`libcore.so` 尚未产出、真实链路无法验证**。
**不要"顺手"把它改成 `false`** —— `NativeBridgeImpl` 仍返回 `native-bridge-not-linked`。

---

## 4. 本轮**新查出**的缺陷（都有证据，不是推测）

### 4.1 ❌→✅ `main.go` 里 `params := "{}"` 被注释吞掉（**已提交的编译错误**）

**位置**：`entry/src/main/golang/main.go:76`（本轮已修）

**事实**：原文件那一行是

```go
// A nil parameter pointer is the same as "no arguments".	params := "{}"
```

`params := "{}"` 被**粘进了行注释**（中间那个"空格"其实是个 Tab）。于是 `params`
**从未被声明**，而 `GoInvoke` 后面直接用它 → 只要 `CGO_ENABLED=1` 就必然
`undefined: params`。

**为什么一直没发现（这是本条最有价值的部分）**：`main.go` 与 `main_test.go` 都带
`//go:build cgo`，而本机没有 C 编译器 → `CGO_ENABLED=0` 下**整个 cgo 包被构建约束
排除**，`go build ./...` / `go vet ./...` / `go test ./...` **全是绿的**。
`git show HEAD:` 证明该 bug 在 HEAD 里就已存在。

**连带后果**：`main_test.go` 是**服务目录黄金列表**的唯一守卫，而这个包**根本编不过**
→ 它从来没跑过 → §3.1 那个"漏了一项"的错误才能长期存在。

**已做的修复与防线**：
1. 修好那一行；
2. **CI 增加了 `CGO_ENABLED=1` 的 Go 步骤**（`.github/workflows/verify.yml` 的 `go` job），
   hosted runner 自带 gcc，因此 `main.go` 会被真正编译、`main_test.go` 会被真正执行；
3. 该步骤**先断言 `main.go`/`main_test.go` 确实在编译集里**（`go list`），
   否则 cgo 被静默关掉时整步会"假装通过" —— 这正是原缺陷能发生的原因。

> ⚠️ **本机当初无法验证 cgo 侧**（PATH 上没有 gcc/clang/zig）。**后来找到了**：
> 本机 `C:\msys64\mingw64\bin` 有 MinGW gcc 16.1.0（之前探测时它在 PATH 之外，
> 而且不设 PATH 时调用会**静默失败**，看起来像"没有编译器"）。加上
> `$env:PATH="C:\msys64\mingw64\bin;$env:PATH"; $env:CGO_ENABLED=1; $env:CC="C:\msys64\mingw64\bin\gcc.exe"`
> 之后，**`CGO_ENABLED=1` 的完整测试在本机跑通了**：
>
> - `go build ./...`、`go vet .`、`go test ./... -count=1` 全绿；
> - **`main_test.go` 的 12 个用例全部 PASS —— 这是它历史上第一次被真正执行**，
>   并且 `TestVersionServiceReportsXrayVersion` 打印出
>   `xray-core=26.3.27 semver=26.3.27 bridge=1 go=go1.26.4`，说明 Xray 真的链接进来了。
>
> 所以 §6.2 的 ❓ 已解除。**但 CI 上的 cgo 仍未被验证过**（那是 ubuntu 的
> `CGO_ENABLED=1` 步骤，需要等第一次真实运行）—— 本机的验证是等价证据，不是同一件事。

### 4.2 ❌→✅ `invoke` 拒绝自己文档里说合法的空参数（**跑起来才发现的**）

**位置**：`entry/src/main/golang/main.go` 的 `invoke()`（本轮已修）

**事实**：`main_test.go` 的 `TestMalformedParamsAreRejected` 明确写：

```go
// "" must be accepted as "no parameters" so the UI can omit them.
```

而 `invoke()` 在规范化**之前**就做 `json.Valid([]byte(""))` → `""` 不是合法 JSON
→ 返回 `{"success":false,"error":"parameters are not valid JSON"}`。
`GoInvoke` 在 cgo 包装层把 nil/空 `*C.char` 映射成 `"{}"`，所以**C 入口点和 `invoke`
对同一个输入给出了不同答案**，而契约 §3.3 要求"返回值恒为合法 JSON、
调用方可省略参数"。

**为什么一直没发现**：这是 §4.1 的直接后果 —— cgo 包编不过，所以 `main_test.go`
**从来没跑过**。这是一条"测试写对了、但没人执行"的典型。

**已做的修复**：把"空串 = 无参数"的规范化**下沉到 `invoke` 内部**（`if paramsJSON == "" { paramsJSON = "{}" }`），
两个入口点从此一致；纯空白串仍走 `json.Valid` 被拒（那里没有歧义）。
修完 `main_test.go` 12/12 PASS。

### 4.3 ❌→✅ 我为 CI 写的 cgo 守卫**本身是坏的**（写的时候没跑，跑的时候才发现）

**位置**：`.github/workflows/verify.yml`（本轮已修）

**事实**：第一版守卫写的是 `go list -f '{{join .GoFiles "\n"}}' .`。
它在 Go 里**直接报错**：

```
template: main:1: unexpected "\\" in operand
```

Go 的 `text/template` **不支持字符串字面量里的 `\n` 转义**。也就是说：
**这条守卫会在 CI 第一次运行时炸**，而它本来是"防止 cgo 静默跳过"的。

**第二层坑（更隐蔽）**：即使把模板改对，`.GoFiles` 对这个包**是空的** ——
带 `//go:build cgo` 的文件被归到 `.CgoFiles`，`_test.go` 归到 `.TestGoFiles`。
任何只看 `.GoFiles` 的守卫都会**永远失败**。

**已做的修复**：守卫改成**不依赖模板转义、也不依赖文件清单**的确定性做法 ——
`go test . -run '^$' -count=1`（编译测试二进制、不跑用例并），
它既证明 `main.go`/`main_test.go` 都能编、也证明它们**确实在编译集里**。
另外仍打印 `CgoFiles`/`TestGoFiles` 两份清单便于读日志。

**两个方向都实测过**：cgo 打开 → `exit 0`；cgo 关闭 → `go list` 与 `go test` 双双非 0。
（本机没有真正的 bash，所以是在 PowerShell 里跑等价命令 + 核对字段名验证的；
Ubuntu runner 上的 bash 行为需要等首次运行确认。）

> 这条记在这里是为了留下一个教训：**"CI 守卫"本身也是要验证的代码**。
> 我写它的时候没有可运行的 Go 环境，差点交出一条一跑就红的守卫。

### 4.4 ❌→✅ ArkTS 侧**根本编译不过**，`Bridge.ets` 的 import 位置违规

**位置**：`entry/src/main/ets/core/Bridge.ets`（本轮已修）

**事实**：`import bridgeNative from 'libbridge.so';` 被写在**第 57 行**，即一大段非 import
代码之后。ArkTS 报 `arkts-no-misplaced-imports`：

```
Error Message: "import" statements after other statements are not allowed ... Bridge.ets:57:1
COMPILE RESULT:FAIL {ERROR:2 WARN:4}
BUILD FAILED
```

**性质**：这是 `docs/00-技术路线可行性.md` §11.3 所说的"那次 `import` 的启用是这一轮唯一
有'可能破坏构建'风险的改动"的**后果落地** —— 它**确实破坏了构建**，而因为
`TODO.md` 原 §3.2 说"本机没有 hvigorw，整个 HAP 从未构建"，**没有人去编过**。

**连带**：这也解释了为什么 `StartCoreResult.pid` 那个 bug（§4.3）能一直在代码里 ——
UI 从来没被编译过。

### 4.5 ❌→✅ `ConnectionViewModel` 用恒为 0 的 `pid` 判断"启动成功"

**位置**：`entry/src/main/ets/viewmodel/ConnectionViewModel.ets`（本轮已修）

**事实**：`StartCoreResult.pid` 的注释自己写着"**当前恒为 0**"
（内核跑在 VPN 扩展进程内，不是独立进程），而 `connect()` 却写：

```ts
if (started.pid <= 0) { this.lastError = 'start-core-failed'; /* 判为失败 */ }
```

**后果**：**即使原生启动完全成功，UI 也必然报失败**。而 `Bridge.startCore()` 在信封
`success=false` 时同样只返回 `{pid:0}` 且不抛错 → 调用方无从区分"内核没起来"与"桥断了"。

**已做的修复**：`StartCoreResult` 增加 `ok`（= `envelope.success && started===true`）、
`error`、`wired`、`notes`；`connect()` 改看 `ok`，失败信息带上原生 error；
`wired` 如实透出（并记日志），不再假装"已连通"。**`ok` 而不是抛异常**的理由写在
`Bridge.ets` 的接口注释里（Bridge 层约定"永不抛异常、失败编码进返回值"，契约 §3.3）。

### 4.6 ❌→✅ SOCKS 端口有**三到四份**各自写死的 10808

**位置**：`VpnAbility.ets`（`const SOCKS_PORT = 10808`）、`Bridge.ets` 的 mock、
`ConnectionViewModel`/`NodeViewModel` 的演示数据、`ConfigStore` 路径

**后果**：tun2socks 的 YAML 指向 A 端口、内核监听 B 端口 → **静默不通**，
而且没有任何一处会报错。三处"看起来一致"只是巧合。

**已做的修复**：`constants/Common.ets` 成为唯一来源（`CORE_SOCKS_PORT`/`CORE_HTTP_PORT`）；
权威值仍在 Go 的 `service/config.DefaultSocksPort`/`DefaultHTTPPort`，ArkTS 侧从
`ConfigService.Generate` / `CoreService.Start` 的**结果**回读，0 时回落到常量。

> **一处刻意的设计取舍**：没有把 `socksPort`/`httpPort` 加进
> `ConfigService.Generate` 的**参数**（契约 §4 里没有这两个字段，加了会被
> `encoding/json` 静默忽略，反而制造"ArkTS 能覆盖端口"的假象）。
> 端口只有 Go 一份权威，ArkTS 回读。

### 4.7 ❌→✅ 防环机制**文档说已裁决、代码里根本没接**

见 §2.2 —— 本轮接上了 `blockedApplications`，但真机行为仍 ❓。

### 4.8 ❌→✅ 文档把主分支写成 `master`，实际是 `main`

**位置**：`docs/design/ci.md`（3 处）、`CONTRIBUTING.md`（4 处）

**事实**：`git symbolic-ref refs/remotes/origin/HEAD` → `origin/main`，
且 6 次提交的历史全部在 `main` 上。文档却写"主分支 `master`"、
"禁止 push 到 `master`"、"从最新 `master` 切分支"。

**为什么算缺陷**：这是**可验证事实写错**（`AGENT.md` 第 8 节要求区分 ✅ 与 ❓，
而这里连 ✅ 都不是，是错的）。对按文档操作的人后果具体：`git switch -c feat/x master`
会直接失败。

**已做的修复**：7 处全部改为 `main`。`ci.yml` 的 `pull_request.branches` 保留
`[main, master]` 两个值 —— 那**不是笔误**，而是让门禁在"默认分支被改名"时仍然生效。

### 4.9 ⚠️ `MOCK_BRIDGE` 保持 `true` 的理由曾写在契约里，已过期

契约原句"在这些改动完成之前，UI 必须保持 `MOCK_BRIDGE = true`"——**前提已完成**。
文档已改为"仍保持 true，但理由是没有真机/内核未产出"。见 §3.6。

---

## 5. 工程债（不挡目标，但要知道）

### 5.1 ⚠️ `typeCheck` 未开启

`hvigor/hvigor-config.json5` 里 `typeCheck` 是注释状态。
后果：ArkTS 的类型错误没有编译期守卫，只能靠本机 lint 和真机发现。
（§4.2/§4.3 这两个缺陷正是"没有编译守卫 + 没人编译"的产物。）

### 5.2 ⚠️ `Bridge.ets` 的 `remote` 未使用告警（既有）

`onConnect: (elementName, remote) => {}`。属本轮改动**之前就存在**的告警，
按"不要顺手改无关既有告警"的纪律没有动它。

### 5.3 ✅ 仓库内现在**有**自动化在跑 Go 测试

原 §4.4 的建议已落实：`.github/workflows/verify.yml` 的 `go` job 跑
`gofmt` / `go build` / `go vet` / `go test`（`CGO_ENABLED=0` 与 `1` 两种配置）。
**但注意**：`libcore.so` 的交叉编译**不在此列**（需要 OHOS NDK，见 §1.1）。

### 5.4 ⚠️ `RuntimeInfo` 的"最近一次"语义是进程内的

`Stop` 会把它清零，所以冷启动后 `RuntimeInfo` 报的是默认端口 + 空 `configLocation`
（并带 `note` 说明）。这是**有意的**（不假装知道），但调用方要能读 `note`。

---

## 6. 未证实项（不知道行不行）

### 6.1 ❓ U3：`hev-socks5-tunnel` 在 OHOS 上能否处理 vNIC fd

**为什么关键**：这是整条数据面的**唯一**假设。hev 的后端是为 Linux/Android 写的，
OHOS 的 vNIC fd 能否被它正常读写，**没有任何证据**。

**怎么证实**：真机上跑 `Tun2socksStart`，看 `Tun2socksStop` 回传的 `exitCode` / `lastError`
（这两个字段就是为回答这个问题加的）。

### 6.2 ✅ cgo 侧代码**已经在本机编过并测过**了（原 ❓ 已解除）

本机 `C:\msys64\mingw64\bin` 有 MinGW gcc 16.1.0（首次探测时它在 PATH 之外，
且不设 PATH 时调用会静默失败，看起来像"没有编译器"）。设好 PATH 与 `CC` 之后：

| 命令（`CGO_ENABLED=1`） | 结果 |
| --- | --- |
| `go build ./...` | ✅ exit 0 |
| `go vet .` | ✅ exit 0 |
| `go test ./... -count=1` | ✅ 全部 `ok` |
| `go test . -count=1 -v` | ✅ **12/12 PASS** —— `main_test.go` 史上第一次真正执行 |

`TestVersionServiceReportsXrayVersion` 打印 `xray-core=26.3.27 semver=26.3.27
bridge=1 go=go1.26.4`，说明 Xray-core 真的链接进来了。

> **仍未证实**：CI 的 ubuntu `CGO_ENABLED=1` 步骤（等价证据，但不是同一次运行）。
> 另外这里**不是** `-buildmode=c-shared` 的 OHOS 交叉编译 ——
> `libcore.so` 依然卡在 §1.1。

### 6.2b ⚠️ 本机没有真正的 bash

`bash` 解析到 `C:\Windows\system32\bash.exe`，那是 **WSL 的桩**（一跑就提示去装 WSL），
不是 Git for Windows 的 bash。所以任何**只在 bash 下验证过**的脚本
（`scripts/*.sh`、`.githooks/*`、CI 里 `shell: bash` 的步骤）在本机都**无法复现** ——
只能靠 PowerShell 等价命令 + 字段名核对来逼近，真正的确认要等 CI。
这条以前没有被记录过，容易让人把"我跑过等价逻辑"当成"那个脚本通过"。

### 6.3 ❓ C++ 层只做了语法检查，没有链接与运行

**已做的**：用本机 OHOS NDK 的 `clang++ 15.0.4`，`--target=aarch64-linux-ohos ... -fsyntax-only`
检查 `napi_init.cpp` 与 `tun2socks_bridge.cpp`，**零告警通过**。

**没做的**：完整编译、链接、`dlopen` 实际加载、线程启停的真实行为。

### 6.4 ✅ ArkTS 侧**已经编译过**了（原 §3.2 已解除）

`clean` 后真实执行 `CompileArkTS`（不是 `UP-TO-DATE`）→ `BUILD SUCCESSFUL`，
产出未签名 HAP（2,535,152 字节）。命令与读数陷阱见 `docs/03-环境搭建.md` §5.2。

> **但"能编译"≠"能运行"**：`MOCK_BRIDGE` 仍为 true，真机链路一步都没跑过。

### 6.5 ❓ geo 资源的按需下载路径未在真机验证

`ets/service/GeoAssetService.ets` 已实现探测/下载/删除，但**下载路径从未在真机跑过**；
而且截至本轮，`.dat` **既没有打进 HAP、也没有从 Release 附带**。
`ConfigService.Generate` 在资源缺失时会降级并在 `notes` 里说明（这条有 Go 单测守着）。

---

## 7. 发布流水线（本轮新增）

### 7.1 流程

```
push tag v*  →  verify（托管 runner：仓库卫生 + 配置 + 不跑 cgo 的 Go）
             →  changelog（托管 ubuntu：tag↔app.json5 版本一致性 + 生成 RELEASE_NOTES.md）
             →  publish（[self-hosted, harmonyos, windows]：assembleHap → SHA256SUMS → gh release create）
```

另有两个入口：
- `workflow_dispatch` + `dry_run`：只校验版本、跑门禁、生成变更日志，**不构建不发布**；
- 本机无 runner 时：`pwsh -File scripts/release-local.ps1 -Tag v0.1.0`
  （`-Publish` 才建 Release，默认 **draft**）。

**发布语义的唯一定义处是 `scripts/release-metadata.json`**（tag 形态、产物名、路径、
构建参数），workflow / 本地脚本 / changelog 三者都读它，避免三套规则漂移。

### 7.2 ✅ self-hosted runner 已注册并跑通（2026-10-11）

`publish` job 的 `runs-on: [self-hosted, harmonyos, windows]` 现在有真实的 runner：

| 项 | 值 |
| --- | --- |
| 名称 | `DESKTOP-J1B0B8S-harmonybridge` |
| 安装位置 | `C:\actions-runner-harmonybridge`（**不在仓库内**） |
| 标签 | `self-hosted` `Windows` `X64` `harmonyos`（`self-hosted`/`Windows`/`X64` 自动打，只手工加了 `harmonyos`） |
| 启动方式 | **手动**：`C:\actions-runner-harmonybridge\run.cmd`。**没有装成 Windows 服务**（装服务要管理员权限），所以**机器重启后需要重新运行它** |
| 自动更新 | 未配置（`--disableupdate` 未加，但手动运行时按需处理） |

**一次真实的发布已经跑通**：tag `v0.1.0` → 门禁 → 变更日志 → 自托管构建 → 发布。
Release: <https://github.com/kuaizhongqiang/HarmonyBridge/releases/tag/v0.1.0>，
资产 `harmonybridge-0.1.0-unsigned.hap`（1,877,668 字节）与 `SHA256SUMS.txt`，
下载后**校验和与记录一致**。

### 7.2b ⚠️ 首次跑通暴露了 3 个我自己的接线缺陷（都已修）

这三个都**只能在真实运行时暴露** —— 本机逐件测试时全部漏掉了，值得记下来：

1. **`shell: pwsh` 在自托管 runner 上不存在**。`pwsh` 是 PowerShell 7+，
   GitHub 托管镜像自带，但普通 Windows 机器只有 5.1。报错是
   `##[error]pwsh: command not found`。已全部改为 `shell: powershell`
   （脚本本来就同时兼容 5.1/7）。**这是"本机跑过等价命令"≠"那个步骤会通过"的典型**。
2. **`DEVECO_HOME` 解析出来了却没传给下一步**。每个 step 是新进程，
   preflight 在默认路径下验证通过后，下一步拿到 `$null` →
   `Join-Path : Cannot bind argument to parameter 'Path'`。已改为写 `GITHUB_ENV`。
3. **`java` 必须在 `PATH` 上，不只是 `JAVA_HOME`**。只设 `JAVA_HOME` 时
   `assembleHap` 在 `PackageHap` 报 `Error Code: 00308018 Unknown Error` ——
   这条消息**完全不提 Java**（`docs/03-环境搭建.md` 早就记录了它就是
   `spawn java ENOENT`）。已改为把 `<jbr>\bin` 写进 `GITHUB_PATH`。

> **为什么本机没发现**：本机的开发者 shell **本来就有 java 在 PATH 上**，
> 而且我手动跑构建时也是这样。这就是"本地全绿"最容易骗人的地方。

### 7.2c ⚠️ 变更日志的"上一个 tag"曾经算错

第一版把**被发布的那个 tag 自己**当成了"上一个 tag"（它指向待发布提交，
从 HEAD 可达），于是把**本次要发布的提交又列了一遍**。已改为用
`git describe --tags --abbrev=0 --exclude=<当前tag> <当前tag>^`，
并**用一次模拟的第二次发布验证过**（结果只含新提交那一条）。

### 7.3 ⚠️ 产物是**未签名** HAP —— 这是决定，不是遗漏

按"仅自用、不对外发行"的既定决策与"签名材料不入库"的纪律，流水线**不签名**：
发布 `harmonybridge-<version>-unsigned.hap` + `SHA256SUMS.txt`，
并在 release notes 里写清如何自行签名/侧载。
`release.yml` 里有一条**反向断言**：如果产出的是已签名 HAP，直接失败。

### 7.4 ✅ 发布流水线**已经真实运行过**（原 ❓ 已解除）

本机逐件验证 + GitHub 上一次完整运行（见 §7.2）。剩下的长期项只有：
runner 是**手动运行的进程**（重启后需重新拉起），以及 `libcore.so` 仍未产出
（所以 HAP 里没有可用内核，见 §1.1）。

### 7.5 ⚠️ workflow YAML 没有自动化校验

`.github/**` 的 YAML 只由 GitHub 自己解析，写坏要到 push 之后才暴露。
本轮是用本机 PyYAML 手验的**结构**（`on`/`jobs`/`runs-on`/`needs`/`steps`），
**没有**进 CI —— 加它需要引入 YAML 依赖，而本仓库刻意零 Node 依赖。

---

## 8. 建议的执行顺序

1. **注册 self-hosted runner**（解 §7.2）—— 不需要真机、不需要 Linux，
   而且它会让 §4.1 的 cgo 修复**第一次被真正验证**；
2. **装 WSL + 一个发行版**（解 §1.1 的前置），然后在 Linux 上编 `libcore.so`
   —— 不需要真机，成败可验证；
3. 在 Linux 上试编 `libhevsocks5tun.so`（解 §1.3），失败也如实记录；
4. 采购真机（解 §1.2），然后按 **`AGENT.md` §9** 走 —— 第 4 步已改对（fd 交给 tun2socks）；
5. 真机到位后立刻验的三件事：`blockedApplications` 是否止住环路（§2.2）、
   IPv6 是否泄漏（§2.1）、hev 能否处理 vNIC fd（§6.1）。

> 第 2 步和第 4 步依然是本项目**最大的两个未知**。在真机上跑通之前，
> 任何人都不应对外宣称这个项目"可行"。
