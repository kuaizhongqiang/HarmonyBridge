# TODO — 已知问题与待办

> 这份清单记录**当前已知的、尚未解决的问题**，包括三类：挡住目标的硬阻塞、
> 代码/文档里已确认的缺陷、以及"不知道行不行"的未证实项。
>
> 最后更新：**2026-10-12**（真机验证完成；与 `README.md` / `AGENT.md` v2 同一轮）
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
> 反过来也一样：**已经真机验证过的事，不许继续挂在 ❓ 下面** —— 那会把下一个人引向
> 一个已经不用解决的问题。本轮的整理重点就是后者。

---

## 0. 本轮（2026-10-12）做完的事 —— 一句话

**真机验证完成：整条链路从"编出来"走到了"能用"。**

已解除（细节见各条目的 ✅ 标注与 §9）：

| 原条目 | 内容 | 结果 |
|---|---|---|
| §1.2 / §0.1.4 | 没有真机 → `dlopen` / `GoInvoke` / 授权弹窗 / `vpn-tun` | ✅ HUAWEI `TYR-AL00`（API 24），全部通过 |
| §1.1 / §6.2 | `libcore.so` 的 OHOS 交叉编译 | ✅ 34.5 MB 产物在真机上 `dlopen` 成功，返回 Xray `26.3.27` |
| §1.3 | `libhevsocks5tun.so` 从未构建成功 | ✅ 已构建，且**在真机上接管了 vNIC fd** |
| §6.1 | **U3**：hev 能否处理 OHOS 的 vNIC fd | ✅ **能** —— 这是原先"最大的两个未知"之一 |
| §2.2 | `blockedApplications` 是否止住环路 | ✅ 已验证（内核出站源地址是蜂窝 IP，不是 tun 地址） |
| §3.6 | `MOCK_BRIDGE` 保持 `true` | ✅ 已置为 `false`，走真实原生链路 |
| §7.4 | 发布流水线 | ✅ `v0.2.0` 已发布，verify / changelog / publish 全绿 |

本轮**新查出并修掉**的真机缺陷（都是运行期才暴露的，详见 §9）：
ServiceExtension 误连导致 `vpn.create()` 哑火并**静默断网**；内核跑在 UI 进程、切后台被系统冻结；
隧道 MTU 与上行网卡不匹配；扩展进程依赖只在首次传递的 `want.parameters`。

**仍然未解决**的：§2.1（IPv6 泄漏）、§2.3（`SpeedTest` 仍是占位）、§2.4（`ui.md` 的 service 表）、
§6.3（C++ 未做真实链接与运行）、§6.5（geo 下载未在真机验证），以及 §9.5 列出的新缺口。

---

## 0.0 上一轮（2026-10-11）做完的事 —— 留档

把"**不需要真机就能验证的部分**"做完了：文档矛盾、Go 服务目录收敛、两处真 bug、
以及 tag → CI → 发布流水线。**真机相关的部分一件都没变**（当时没有真机是硬约束；现已解除）。

而"那一轮查出的新缺陷"几乎都有一个共同特征：**它们都被"看起来是绿的"掩盖着** ——
`go build ./...` 绿（因为 cgo 包被构建约束排除）、`TODO.md` 说"ArkTS 从未编译"
（所以没人去编）、契约说 `pid` 恒为 0（但 UI 拿它当成功判据）。详见 §4。

---

## 0.1 ✅ Linux 构建已交付（2026-10-11 21:19）—— 两个 `.so` 都拿到了

**交付位置**：`harmonybridge-so/`（仓库根下，**未入库**）。这是本项目**第一次**
同时拿到可用的内核与数据面。

**Lead 已独立复验**（用 NDK 的 `llvm-readelf` / `llvm-nm`，不是采信交付说明）：

| 检查项 | `libcore.so` (T1) | `libhevsocks5tun.so` (T2) |
| --- | --- | --- |
| ELF 头 | ✅ ELF64 / AArch64 / **DYN** | ✅ ELF64 / AArch64 / **DYN** |
| 大小 | 34,527,768 B（33 MB） | 286,736 B |
| 导出符号 | ✅ `GoInvoke` / `GoFreeCString`（都是 `T`） | ✅ **3 个 dlsym 目标全在**：`hev_socks5_tunnel_main_from_str` / `_quit` / `_stats` |
| **TLS 形态** | ✅ TLS 段存在；重定位是 **`R_AARCH64_TLSDESC`** | — |
| `DT_NEEDED` | `libohcommonevent.so` / `libhilog_ndk.z.so` / `libtime_service_ndk.so` / `libc.so` | **只有 `libc.so`** |
| SHA-256 | ✅ 与 `SHA256SUMS.txt` 记录**一致** | ✅ **一致** |
| 内容真实性 | ✅ `.gopclntab` 11.9 MB、`.text` 12.6 MB；含 `Xray` / `xray-core` / `VLESS` / `VMess` / `shadowsocks` / `trojan` / `go1.26` 特征串 | — |

**`R_AARCH64_TLSDESC` 是这次最关键的读数**：它说明产物落在**广义动态 TLS** 上，
**没有**落进 `docs/design/core.md` §6.3 记录的"bionic 固定槽 + 外来线程调 cgo
概率性 SIGSEGV"那条路。交付用的正是 §6.3 的 **B 路线（fork + `GOOS=openharmony`）**。

### 0.1.1 ✅ 报告已到（并**更正我此前的一个误判**）

执行报告：[`docs/05-Linux构建执行报告-20261011.md`](docs/05-Linux构建执行报告-20261011.md)
（356 行，Ubuntu 22.04.5 **原生 Linux**，基准 commit `c7810cd`）。

> 🔧 **更正**：我此前写"交付不完整、缺 A 路线产物与 3sibling 变体"——**那是我读错了范围**。
> `harmonybridge-so/` 里放的本来就是**推荐组合**（自包含的两个 `.so`）；
> A 路线那个 33 MB 的对照产物与 3sibling 变体**留在 Linux 机器的**
> `/home/kuai/opt/hb-runs/` 与 `/home/kuai/opt/hb-delivery/`，**没有往仓库搬**。
> 而 **A 路线的对照数据已完整写进报告**（原样粘贴的 `readelf -l/-r` 输出），
> 所以"无法独立复验 A 路线无 TLS 段"这一点，靠报告里的原始输出已经足够。

**报告的核心数据（A vs B 的 TLS 对比 —— 任务书 §6.3 要的就是这份）：**

| | A 路线（官方 Go，`GOOS=android`） | B 路线（fork，`GOOS=openharmony`） |
| --- | --- | --- |
| 干预次数 | **3 处** hack | **0 处** |
| `PT_TLS` 段 | **无** | **有**（0x10 字节） |
| TLS 重定位 | **无** | **1 条 `R_AARCH64_TLSDESC`** |
| 大小 | 33.0 MB | 34.5 MB |

**Lead 补做的一步（报告未做）**：检查 B 产物的未定义符号，确认它**不引用**
`__get_tls` / `__stack_chk_guard` 等 bionic 专用机制 —— 它走的是**标准 ELF TLS**
（`PT_TLS` + `TLSDESC`，musl 支持）。A 产物两者皆空：既没有自己的 TLS 镜像，
也不是标准 ELF TLS 形态。

> ⚠️ **仍然只是工具链级证据**。`TLSDESC` 说明"没掉进 bionic 固定槽假设"，
> **不等于**真机上外来线程调 cgo 一定不崩。**真机验证依然必需。**

### 0.1.2 🆕 报告新查出的两个缺陷（任务书**没有**提到）

**（a）A 路线其实有第三个障碍：链接期 `-llog`**

```text
ld.lld: error: unable to find library -llog
```

根因（✅ 已核实）：官方 Go 的 **android/arm64 端口在链接期无条件追加 `-llog`**
（bionic 的 liblog），而 OHOS sysroot 没有 liblog、只有 `libhilog_ndk.z`。
**加 `-lhilog_ndk.z` 不能替代** —— 那个 `-llog` 是 Go 链接器自己加的，不受 `CGO_LDFLAGS` 控制。
绕过办法是造一个 **0 成员的空 `liblog.a`** 让它被解析到。

**（b）`scripts/build-tun2socks.sh` 的产物不是自包含的**（⚠️ **真机 `dlopen` 会失败**）

Lead 已复核脚本源码：`:106` 只有 `cp -f "${BUILT_SO}" ...`，**只复制主库**。
而上游 `make shared` 会把三个第三方库编成**独立 .so** 并写进 `DT_NEEDED`：

```text
NEEDED: libyaml.so / liblwip.so / libhev-task-system.so / libc.so
```

→ **三个 dlsym 符号都在，但真机上库加载不起来**（找不到那三个兄弟库）。
报告已实做一版**自包含替代品**（`make tp-static` + 手工重链三个 `.a`，
286,736 B，`NEEDED` 只剩 `libc.so`）—— **仓库里交付的就是它**。

> ❌ **不要直接把 `build-tun2socks.sh` 的产物丢进 HAP**，除非同时把三个兄弟 `.so`
> 也放进去（它们在原 Linux 机器的 `siblings-3sibling-variant/`）。
> 👉 建议把这条**写进脚本头部注释**，否则下一个人还会踩（见 §7.6）。

### 0.1.3 ⚠️ 一条容易被忽略的语义差异：两条路线的 `GOOS` 不是一回事

B 路线用的是**独立 GOOS `openharmony`**，所以 xray-core 里 `//go:build linux` 的文件
**不会被选中**（A 路线选中的是 android 后端）。本次**没有**编译错误，
但两条路线的**运行期行为不完全可比**：构建期 `GOOS=openharmony`，
而 fork 的 `zgoos_openharmony.go` 里 `const GOOS = "linux"`。❓ 真机行为未验证。

### 0.1.4 ✅ 曾经的三条 ❓ 已由真机全部回答（2026-10-12）

拿到 `.so` 当时确实"不改变那一条"。现在真机跑过了，三条全有答案：

- ✅ 真机 `dlopen` 成功、`GoInvoke` 可调 → 返回 Xray `26.3.27`；
- ✅ **外来线程（VPN 扩展进程）调 cgo 没有 SIGSEGV** —— 内核现在就跑在扩展进程里，
  连续多轮连接/断开均稳定；`R_AARCH64_TLSDESC` 那条工具链级推断得到了运行期印证；
- ✅ hev 能处理 OHOS 的 vNIC fd（U3，见 §6.1）—— **能**。

### 0.1.5 ✅ 已接线并进 HAP（原"仍未接线"）

`entry/libs/arm64-v8a/` 曾经**只有 `.gitkeep`**；现在两个 `.so` 已就位并打进 HAP
（HAP 由 2.6 MB → **37.7 MB**，`hdc install` 成功）：

```powershell
copy harmonybridge-so\libcore.so         entry\libs\arm64-v8a\
copy harmonybridge-so\libhevsocks5tun.so entry\libs\arm64-v8a\
```

- ✅ `entry/libs/**/*.so` 已被 `.gitignore` 挡住（**产物不入库**，正确）；
  `/harmonybridge-so/` 也已加入 ignore（防 `git add -A` 误装 34 MB）。
- ✅ 已用 `SHA256SUMS.txt` 逐个校验过完整性。
- ⚠️ **发布流水线的 HAP 里仍然不会有这两个 `.so`**：CI 从 git 检出后构建，而这俩不入库
  —— 这是**有意的**（产物不入库是硬规则）。意味着**从 Release 下载的 HAP 不含内核**，
  只能自己构建。见 §7.6。

---

### 0.2 🔨 工具链路线已决策：**自己做 OHOS Go 移植，不用第三方 fork**

**决策（2026-10-11，项目负责人）**：
1. ❌ **不使用** `star4277/ohos-go` 作为生产工具链；
2. ✅ 走**路线 1**：**以官方 OpenHarmony SIG 的移植为基线，自己维护 + 跟上游 rebase**；
3. ✅ 参考实现**只读**：可以读它的 diff 搞清"要改什么"，**代码自己重写**。

**任务书**：[`docs/06-OHOS-Go工具链自研任务书.md`](docs/06-OHOS-Go工具链自研任务书.md)

**Lead 已完成的侦察（免得下一个人重复调研）**：

| 事实 | 值 |
| --- | --- |
| 上游 Go 有 openharmony 吗 | **没有**（master 的 `syslist.go`/`dist/build.go`/`supported.go` 全是 0 次）→ 任何方案都是 fork |
| 官方 SIG 仓库 | `gitcode.com/openharmony-sig/ohos_golang_go`，**BSD-3-Clause**，git 可直接 clone 🧪 |
| 移植在哪条分支 | `release-branch.go1.24`（`VERSION=go1.24.5`，2025-07-02） |
| ⚠️ `release-branch.go1.26` | 存在，但**里面 openharmony 出现 0 次** —— 那条还没移植 |
| 官方 tag | `go1.24.5.ohosv1r1` |
| **移植真实规模** | **+1985 / -512**（关于 openharmony 的部分，~131 文件）；另有 **36 个与移植无关**的文件（+777/-167）**不要照搬** |

**开工前必须先定的"Go 版本鸿沟"**：SIG 移植停在 **go1.24.5**，而我们的 xray-core 要求 **go1.26**。
🧪 已核实：**可见范围内没有任何 xray 版本要求 ≤ go1.24**（最老的可见版要 go1.25）。
所以只有两条路 —— **1A：把移植往前搬到 go1.26**（推荐）；
**1B：降 xray-core**（代价大，但要先花 10 分钟验证"xray 是否真的用到 go1.26 语法"）。
详见任务书 §2。

---

### 1.1 ✅ B2 已解除：内核 `libcore.so` **已编出**（2026-10-11，B 路线）

> **状态变更**：这一条从"硬阻塞"降级为**已解决** —— 但请先读 §0.1 与 §0.1.4：
> **没有真机验证**，所以"编出来"≠"能用"。

**原现象**（留档）：Windows 宿主上交叉编译失败。根因不是"缺参数"，而是 Go 标准库里的
`socklen_t` 与 OHOS musl 的 `typedef unsigned socklen_t` 宽度不一致，
**必须给 Go 打补丁**，不是加编译选项能解决的。

**最终怎么解的**：走 **B 路线** —— 换 `GOOS=openharmony` 的 Go fork
（`star4277/ohos-go` `v1.26.5-beta1`），**一次编过、零干预**：
目标不再是 android，于是 `socklen_t` 与 `android/log.h` 两个障碍自然消失。
完整报告见 [`docs/05-Linux构建执行报告-20261011.md`](docs/05-Linux构建执行报告-20261011.md)。

**✅ 真机行为已确认（2026-10-12）**：产物在真机上 `dlopen` 成功、`GoInvoke` 可调、
Xray 正常运行，内核现在就在 VPN 扩展进程里持续工作。
**仍未定的只剩一项**：**是否接受个人 fork 作为长期工具链**（供应链决策，见 §0.1.1 与 §0.2）——
这是**管理决策，不是技术阻塞**。
A 路线（官方 Go）也能编出，但要 **3 处 hack**（shim + stdlib 补丁 + 空 `liblog.a`），
且产物 `PT_TLS` 段与 TLS 重定位**都是空的** —— 见 §0.1.1 的对比表。

**为什么曾经挡住目标**：没有 `libcore.so` 就没有内核 → 没有本地 SOCKS 入站 → 没有分流。

**怎么解**：在 Linux / WSL 上构建（脚本已按这条路写）。

> 👉 **完整的换机执行说明已单独成文**：[`docs/04-Linux构建任务书.md`](docs/04-Linux构建任务书.md)
> —— 环境准备、两个必须解决的障碍（`android/log.h` shim、`socklen_t` 补丁）、
> TLS 验收检查、报告模板都在那里。**这一节只记状态，操作步骤看那份。**

**当前状态**：✅ **已解除**。Windows 宿主上依然不能直接编（这一点没变，也不再重要），
但产物已在 Linux 上编出、进了 HAP、并在真机上跑通。**本条不再是工程任务。**

> ⚠️ **本轮新增的实测结论**：本机**连 WSL 都没装**（`wsl --status` 返回
> "未安装用于 Linux 的 Windows 子系统"），也没有 Docker。所以"在 Linux 上编"
> 这条路**本机当前一步都走不了** —— 先得装 WSL + 一个发行版，或者另找一台 Linux 机器。
> 这一点此前没有被记录过，导致"解 1.1"看起来比实际更容易。
>
> ✅ **同时澄清了两个被过度担心的点**（2026-10-11 核实上游仓库）：
> `socklen_t` 冲突与 Windows 无关，**Linux 上依然存在**（头文件约定冲突）；
> 但"NDK 路径含空格"和"8.3 短名"这些纯 Windows 麻烦在 Linux 上会消失。

---

### 1.2 ✅ B3 已解除：有真机了（2026-10-12）

**设备**：HUAWEI `TYR-AL00`（nova 14 活力版），`6.1.0.145(C00E120R2P5)`，API 24。
**结果**：签名 HAP 可安装启动；授权弹窗出现；`vpn-tun` 网卡被创建；内核与数据面均正常。

**为什么曾经挡住目标**：网卡能否创建、内核能否启动、tun2socks 能否接管 fd，
**全部**只能在真实设备上回答。本机 SDK 也没有 `arm64-v8a` 的模拟器镜像。
→ 现在全部有答案，见 §0 的表格与 §6.1。

**仍然不适用于模拟器**：模拟器不作为 VPN 链路的验证手段（这条判断没变）。

---

### 1.3 ✅ `libhevsocks5tun.so` 已构建成功并接管了 vNIC fd（2026-10-12）

**位置**：`scripts/build-tun2socks.ps1` / `.sh`

**结论**：产物 286,736 B、`DT_NEEDED` 只有 `libc.so`（自包含），
🧪 **真机上 `libhevsocks5tun.so` 成功加载并在 vNIC fd 上运行**，`vpn-tun` 双向计数持续增长。

> 历史上两个担心**都已消解**（2026-10-11 查上游 `heiher/hev-socks5-tunnel` 2.18.0）：
> 1. 上游确实提供 `build.mk`，`SRCFILES` 由 `rwildcard` 展开 → "配方推错"不成立；
> 2. `src/` 下确实有 `.c` 源码，许可证 **MIT**，与我们的边界兼容。
>
> ⚠️ **仍然成立的注意事项**：`scripts/build-tun2socks.sh` 直接产出的主库**不是自包含的**
> （`DT_NEEDED` 含 `libyaml.so` / `liblwip.so` / `libhev-task-system.so`），
> 真机 `dlopen` 会因找不到兄弟库而失败。仓库交付用的是报告里那版自包含替代品
> （`make tp-static` + 手工重链三个 `.a`）。**不要直接把脚本的默认产物丢进 HAP。**

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

### 2.2 ✅ 防环已验证，且已升级为"官方接口 + 名单"双层（2026-10-12）

**位置**：`entry/src/main/ets/vpnability/VpnAbility.ets`（`buildVpnConfig` / `protectOwnProcessNet`）

**真机结论**：`netstat` 显示内核对代理服务器的出站**源地址是蜂窝网卡的地址，而不是
tun 地址（`172.19.0.1`）** → 本应用进程的 egress 确实没有回到 TUN，**环路不存在**。

现在用的是**两层**：

1. **官方 `VpnConnection.protectProcessNet()`**（`@since 22`，**进程级、不需要 fd**）
   —— 这是防环的**主手段**。`🧪 真机日志：protectProcessNet ok: this process bypasses the VPN`；
2. `blockedApplications: [APP_BUNDLE_NAME]` 作为第二层兜底（`@ohos.net.vpnExtension.d.ts:388`；
   `:378-381` 说明"只有**不在**列表里的应用才按 routes 被代理"；与 `trustedApplications` 互斥）。

> **为什么当初漏了 `protectProcessNet`**：早期调研只知道 `protect(socketFd)`（需要 fd，
> 而 Go/hev 内部 socket 的 fd 拿不到），于是退而用 `blockedApplications` 并把当时的断言
> 标为 ❓。`protectProcessNet` 是 `@since 22`，比那次调研新，且正好解决"拿不到 fd"的问题。
> 👉 **教训**：`.d.ts` 要按当前 SDK 版本重新通读，不能沿用旧调研的 API 清单。

> 顺带记录：这条此前曾是**"文档说已裁决、代码里根本没接"**的状态 ——
> 文档写"改用 `blockedApplications` 防环"，而 `buildVpnConfig()` 里两个名单都没设。
> 这与 §3.2 的"声称已改"是同一类问题：**文档的结论被当成了实现**。

---

### 2.3 ⚠️ `CoreService.RuntimeInfo` 与 `PingService.SpeedTest` 仍是**占位**，不是功能

- `RuntimeInfo`：返回**最近一次 `CoreService.Start` 声明的**端口与配置文件路径。
  它**不探测**真实监听状态。（本地 SOCKS/HTTP 入站现在**确实在监听**了，所以这个字段
  比过去更容易被误读成"它报告了监听状态"——它没有。）
- `SpeedTest`：`speedBps` **恒为 0** + `notes` 说明。**仍是占位**。
- `CoreService.Start` 返回的 `wired`：Go 侧**恒为 false 且描述错误**（说"没有任何入站真的在监听"，
  但它下面 20 行其实真的启动了 Xray）。详见 §2.6。

契约 §4.1 明确允许"占位但不得伪造测量值"这一形态，所以这不是缺陷，
**但它们很容易被误读成"已实现"**。UI 侧必须读 `notes` 再决定展示什么。
**根治 `wired` 需要重编 `libcore.so`**（改 `core.go`），见 §2.6。

---

### 2.4 ⚠️ `docs/design/ui.md` §5.2 的 service 表仍是契约冻结前的旧写法

**位置**：`docs/design/ui.md:238-250` 附近

表里写的是 `version` / `startCore {configPath, assetPath}` / `testLatency {address,…}` /
`runtimeInfo {}` 这类**无点小驼峰**名字与旧参数名，与契约 §1/§4 和现在的
`Bridge.ets`（`Group.Method` + `configLocation`/`assetLocation`）**直接冲突**。
本轮只在同文件 §5.7 末尾加了提示，**没有改这张表**（它是 UI 工作流的产物，且改动面较大）。

**怎么解**：把该表按契约 §4 重写一次，或直接删表改为指向契约。

---

### 2.5 ⚠️ `wired` 没有独立的界面提示

**现状（2026-10-12 更新）**：`wired` 不再采信内核那个恒为 `false` 的字段，
而由**扩展进程**按「内核已启动 **且** tun2socks 已运行」推出，经公共事件
`VPN_CORE_STATE` 上报给 UI（`ets/core/CoreStateMonitor.ets`）。

**仍然缺的**：界面上**没有独立提示**"本地入站未监听 / 数据面没起来"。
要做需要新增 `$r('app.string.*')` 资源（按 `AGENT.md` 第 3 节第 8 条，文案必须走资源文件）。
目前只落在 `@Trace coreWired` + 日志里。

---

### 2.6 ⚠️ Go 内核的 `wired` 字段恒为 `false`，而且它的说明文字是**错的**

**位置**：`entry/src/main/golang/service/core/core.go:110-114`（字段注释）与 `:210`（硬编码）

**事实**：该字段注释断言"**Nothing in this build listens on a port yet** —— 本阶段没有任何进程
真的在监听"，但它下面 **20 行**的 `:288-301` 的 `xcore.New(config)` + `instance.Start()`
**真的启动了 Xray**，而生成的配置里就含本地 SOCKS/HTTP 入站。

🧪 真机证据：`netstat` 显示 `127.0.0.1:10808 LISTEN`（uid 属本应用），
20+ 条到该端口的 `ESTABLISHED` 连接，浏览器可正常出网。**"没有任何入站真的在监听"是假的。**

**为什么没改**：改它要重编 `libcore.so`，而本机（Windows）交叉编译不出来
（见 §1.1）。所以当前做的是**绕过**，不是根治：

- ArkTS 侧不再采信内核的 `wired`，改由扩展进程按「内核已启动 **且** tun2socks 已运行」推算；
- 内核返回的 `notes` 里那两句误导性说明**由 UI 侧标注为"内核自述，已知不准"**。

**怎么根治**：在 Linux 上改 `core.go`（把 `Wired` 改成真探测，并改掉那两句注释/notes）后重编。
**这是同一类"文档/注释当成了实现"的缺陷，而且这次是内核自己在说假话。**

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

### ✅ 3.6 `MOCK_BRIDGE` 已置为 `false`（2026-10-12 更正）

`ets/core/Bridge.ets`。上一轮这里写的是"仍是**正确状态**，**不要顺手**把它改成 `false`"
—— **那条已被真机验证推翻**，在此更正：

- `NativeBridgeImpl.invoke` 现在**真的**走 `bridgeNative.Invoke` → `libbridge.so` →
  `dlopen("libcore.so")` → `GoInvoke`，不再返回 `native-bridge-not-linked`；
- `libcore.so` 已产出并进 HAP，真机上 `VersionService.GetVersion` 返回 `26.3.27`。

切到 `false` 的真实后果（都是**有意暴露**、不再由 MOCK 掩盖的）：VPN 扩展会被真的拉起，
数据面不通时症状就是断网。**§9 那些缺陷能被发现，正是因为这个开关被打开了。**

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

### 6.1 ✅ U3 已证实：**能** —— hev 可以处理 OHOS 的 vNIC fd（2026-10-12）

这是原先被称为"本项目最大的两个未知"之一。**答案是肯定的。**

🧪 真机日志（VPN 扩展进程）：

```text
VpnAbility vpn created, vfd=29
VpnAbility starting tun2socks on fd=29 socksPort=10808
VpnAbility tun2socks running (lib=libhevsocks5tun.so)
```

🧪 旁证：`ifconfig vpn-tun` 的 RX/TX 双向计数持续增长（不是只出不进）；
`netstat` 出现 20+ 条 `127.0.0.1:10808` 的 `ESTABLISHED`（hev 把还原后的连接交给了内核）；
第三方应用浏览器可正常加载网页。

**为什么当初是关键**：hev 的后端是为 Linux/Android 写的，而 OHOS 的 vNIC fd 是否兼容
**没有任何先例**。它要是不行，整条"TUN → tun2socks → 本地 SOCKS"的数据面就得换设计。

**`Tun2socksStart` / `Stats` 回传的 `exitCode` / `lastError` 仍然有用**：它们是这条链路的
常规可观测点，别再当成"回答 U3"的工具。

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
> 另外这里**不是** `-buildmode=c-shared` 的 OHOS 交叉编译 —— 那一项见 §1.1，
> **已于 2026-10-12 在 Linux 上完成并在真机上验证**（产物 `dlopen` 成功、返回 `26.3.27`）。

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

### 6.4 ✅ ArkTS 侧**已经编译并真机运行**了（原 §3.2 已解除）

`clean` 后真实执行 `CompileArkTS`（不是 `UP-TO-DATE`）→ `BUILD SUCCESSFUL`。
命令与读数陷阱见 `docs/03-环境搭建.md` §5.2。

> **"能编译"→"能运行"这一跳已经完成（2026-10-12）**：`MOCK_BRIDGE` 已置为 `false`，
> 签名 HAP 已在真机上安装、启动、并跑通了完整链路（见 §0 与 §6.1）。
> 曾经的"真机链路一步都没跑过"**不再成立**。

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

本机逐件验证 + GitHub 上一次完整运行（见 §7.2）。剩下的长期项只有一项：
**runner 是手动运行的进程**（没有装成 Windows 服务，重启后需重新拉起）。

`libcore.so` 那一条**已不再成立**：产物已交付（但**不入库**，见 §0.1.5），
所以**从 Release 下载的 HAP 里仍然没有内核** —— 这是"产物不入库"规则的必然结果，属有意设计。

> ⚠️ **2026-10-12 实测到的一个操作细节**：推 `v0.2.0` 标签时，`verify` 与
> `changelog` 两个作业在托管 runner 上全部通过
> （含 `v0.2.0 agrees with AppScope/app.json5 versionName=0.2.0`），
> 但 `build + publish` **一直排队** —— 因为自托管 runner
> `DESKTOP-J1B0B8S-harmonybridge` 当时是 **offline**。
> 也就是说：**推标签前要先手动把 runner 跑起来**（`C:\actions-runner-harmonybridge\run.cmd`），
> 否则发布只会停在排队状态。

### 7.5 ⚠️ workflow YAML 没有自动化校验

`.github/**` 的 YAML 只由 GitHub 自己解析，写坏要到 push 之后才暴露。
本轮是用本机 PyYAML 手验的**结构**（`on`/`jobs`/`runs-on`/`needs`/`steps`），
**没有**进 CI —— 加它需要引入 YAML 依赖，而本仓库刻意零 Node 依赖。

---

## 8. 建议的执行顺序（2026-10-12 重排）

上一版的 5 步（注册 runner → 装 Linux 编两个 `.so` → 采购真机 → 按 `AGENT.md` §9 走）
**已全部完成**，包括曾经被称为"最大的两个未知"的 §6.1（hev 接管 vNIC fd）与端到端出网。

现在的优先级：

1. **修 IPv6 泄漏**（§2.1）—— 当前最实在的隐私缺陷，且**不需要重编内核**
   （只动 `ets/vpnability/VpnAbility.ets#buildVpnConfig`）；
2. **补 `geoip.dat` / `geosite.dat` 并验证按需下载**（§6.5）—— 没有它，"绕过大陆"是降级形态
   （只剩"私有网段直连 + 其余走代理"）；
3. **把设置页接线**：MTU / DNS / 分流模式 / 日志级别目前多数**改了不生效**（§9.5）；
4. **节点持久化** + **前台常驻通知 / 断线重连**（§9.5）；
5. **根治内核 `wired` 假话**（§2.6）—— 需要在 Linux 上改 `core.go` 后重编 `.so`；
6. `docs/design/ui.md` 的 service 表按契约 §4 重写（§2.4）。

> ⚠️ **每次推 tag 前先手动启动 self-hosted runner**
> （`C:\actions-runner-harmonybridge\run.cmd`），否则 `publish` 会一直排队，见 §7.4。

---

## 9. 本轮（2026-10-12）已修复的**真机**缺陷

这些**全都只在真机上暴露**：本机的编译、单测、静态检查一条都抓不到。值得逐条记住 ——
它们的共同形态是"**看起来一切正常，实际已经坏了**"。

### 9.1 ✅ 对 VpnExtensionAbility 调 `connectServiceExtensionAbility` 是错误用法

**症状**：点"连接"后，系统层 VPN **已经生效**（`vpn-tun` 建好、默认路由被接管），
但 `vpn.create()` **既不 resolve 也不 reject**，`DataPlane.start()` 因此从未被调用 →
所有应用流量进 TUN 却没人处理 → **手机断网，且没有任何一处报错**。

**证据**：`onRequest` 被以 ServiceExtension 语义触发，**6 ms 后连接即被系统断开**。

**修复**：删掉该调用，只保留 `startVpnExtensionAbility`；`vpn.create()` 立刻返回 vfd
（实测 27 / 29）。并加了 **8 秒看门狗**：未建成则 `processManager.exit(0)` 结束扩展进程，
让系统撤销 VPN —— **"宁可连接失败，也不许静默断网"**。

### 9.2 ✅ 内核跑错了进程（UI 进程 → 扩展进程）

**症状**：用户切到别的应用后，**上行计数照涨、下行归零**；扩展进程 ~100% CPU 空转；
`SYN_SENT` 堆积、`127.0.0.1:10808` 的 accept 队列堵死。

**根因**：`CoreService.Start` 由 **UI 进程**调用，而 UI 进程退到后台后被系统**冻结**
（`/proc/<pid>/stat` 的 cpuTicks 在 10 秒内 delta **恰好为 0**）；与此同时扩展进程里的
tun2socks 仍在往 SOCKS 送流量。净效果是"**盯着它时能用、一切后台就废**"。

**修复**：内核改由**扩展进程**自己拉起（这本就是 `ConnectionViewModel` 头注释写明的设计，
此前实现与它不符），状态经新公共事件 `VPN_CORE_STATE` 跨进程上报。

### 9.3 ✅ 隧道 MTU 与上行网卡不匹配

**症状**：下行极慢（数十秒只有几百字节），上行正常。

**根因**：上行 `rmnet0` 实测 MTU **1400**，而隧道 MTU 是 **1500**。内层满段被包上
REALITY/TLS 头（约 +73 字节）后超过 1400，在外层还要被重新切一刀 → 大流量下包数翻倍。

**修复**：隧道 MTU → **1280**（MSS 1240，外层 ≤ 1313）。推导见 `AGENT.md` §2.4。

### 9.4 ✅ 扩展进程依赖只在首次传递的 `want.parameters`

**根因**：SDK 注释写明 `want.parameters` **只在首次启动 VPN 时传递**
（`@ohos.net.vpnExtension.d.ts:78`）。第二次连接起扩展收不到配置路径 →
`CoreService.Start` 拿到空 `configLocation` 会**退化成"纯诊断调用"、静默不启动内核**。

**修复**：扩展进程改为自己从 `context.filesDir` 推算路径（`ConfigStore` 提供唯一来源）。

### 9.5 🆕 顺带查出的新缺口（**尚未修**）

| 缺口 | 说明 |
|---|---|
| **没有"真正经隧道"的应用内自检** | `PingService.Tcping` 是**裸 TCP、不经代理**，且本应用在 `blockedApplications` 里 → **从应用内测任何域名都验证不了隧道**。要补一个"经 `127.0.0.1:<socksPort>` 的 SOCKS5 CONNECT 探测"（覆盖内核+出站，但仍**不**覆盖 TUN+hev） |
| **内核日志级别锁死在 `warning`** | `ConfigService.Generate` 没把 `Options.LogLevel` 传下去（`config.go:126-130`），设置页的"日志级别"对内核**完全无效** → 内核报错在设备侧看不到 |
| **`createVpnObserver` 运行时不存在** | `.d.ts` 标 `@since 26.0.0`，真机 `is not callable` → 授权结果目前拿不到回执 |
| **节点无持久化** | 节点只在内存里，冷启动后回到内置演示节点。真机联调靠 `rawfile/local-nodes.txt` 种子（不入库） |
| **设置页多数项未接线** | MTU / DNS / 分流模式 / 日志级别改了不生效（`SettingsViewModel` 只存在内存里） |
| **无前台常驻通知、无断线重连** | VPN 扩展被系统回收时用户不会被告知 |
