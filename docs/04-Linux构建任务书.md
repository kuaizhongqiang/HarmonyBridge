# Linux 构建任务书（换机器执行）

> **本文档的用途**：把"必须在 Linux 上做的那两件事"完整交接给一台新机器 / 新的执行者
> （人或 AI agent）。读完这份就能独立开工、独立判断成败、独立交付。
>
> 最后更新：2026-10-11 ｜ 前置阅读：[`AGENT.md`](../AGENT.md)（唯一权威作业手册）
>
> **证据标记沿用 `AGENT.md` 第 8 节**：🧪 实测 ｜ ✅ 本地 SDK/源码核实 ｜ 📄 官方文档 ｜ 🌐 社区来源 ｜ ❓ 未证实
>
> ⚠️ **本仓库最硬的一条纪律**：**没做的事不要说做了，没验证的不要说验证了。**
> "失败了，但把失败点精确定位并记录"是**合格交付**；"看起来编过了"但没验证 **不是**。

---

## 0. 一句话说清你要干什么

HarmonyBridge 是 v2rayN 的鸿蒙原生版。它需要两个**交叉编译出来的 .so**，而这两个
**都只能在 Linux 上产出**（或至少：Linux 是唯一被验证过"环境障碍消失"的宿主）：

| 任务 | 产物 | 用途 | 优先级 |
| --- | --- | --- | --- |
| **T1** | `libcore.so`（约 32 MB） | 代理内核（Xray-core），App 的"协议引擎" | **最高** |
| **T2** | `libhevsocks5tun.so`（小块头） | 数据面（tun2socks），把 TUN 流量交给内核 | 高 |

**两者都编出来，这个项目才第一次具备"真机上可能跑通"的完整条件。**
在此之前，App 能装、界面能点，但流量一步都过不去。

**先做 T1**，理由见 §5 的排序说明。

---

## 1. 30 秒总览：你要交付什么

```text
交付物
├── 1. libcore.so          ← 放 entry/libs/arm64-v8a/，不要 commit
├── 2. libhevsocks5tun.so  ← 同上
├── 3. 一份构建记录（报告）  ← 按 §9 模板，如实写
└── 4. （可选）你为了让构建通过而写的补丁/脚本改动，用 git diff 交出
```

**判定"成功"的标准**不只是"文件存在"，而是 §8 的验收清单——
特别是 `llvm-readelf` 看到的 **TLS 段与重定位类型**（那是这条路线的头号风险，见 §6.3）。

---

## 2. 环境准备（照抄即可）

### 2.1 一台 Linux 机器 / WSL2

- **首选原生 Linux**；Windows 用户用 **WSL2 + Ubuntu**（不要用 WSL1）。
- 磁盘预留 **≥ 20 GB**（xray-core 依赖树 + Go 工具链 + NDK 都不小）。
- 能联网（Go module 下载 + NDK 下载）。

> 🧪 **为什么必须换机器**：当前开发机（Windows）**连 WSL 都没装**
> （`wsl --status` 返回"未安装用于 Linux 的 Windows 子系统"），也没有 Docker。
> 所以"在 Linux 上编"这条路在原机器上一步都走不了。

### 2.2 OHOS NDK（**必须是 Linux 版**）

去华为开发者网站下载 **OpenHarmony / HarmonyOS SDK 的 Linux 版**，找到其中的 `native` 目录。
Windows 版那份**不能**直接用（工具链是 PE 可执行文件）。

放一个**路径不含空格**的地方，例如：

```bash
sudo mkdir -p /opt/ohos-sdk && sudo chown "$USER" /opt/ohos-sdk
# 把 native 目录放成：/opt/ohos-sdk/native
export OHOS_NDK_HOME=/opt/ohos-sdk/native
```

自检（必须全部通过，否则后面白费）：

```bash
ls "$OHOS_NDK_HOME/llvm/bin/clang"        # 必须存在且可执行
ls "$OHOS_NDK_HOME/sysroot/usr/include"   # 必须存在
"$OHOS_NDK_HOME/llvm/bin/clang" --version # 打印版本
```

> ℹ️ 当前 Windows 机上的 NDK 版本是 `OHOS (dev) clang version 15.0.4`。新机器版本不同**通常没问题**，
> 但若报错，先记录版本号。

### 2.3 Go

```bash
# 需要 Go 1.26+（xray-core v1.260327.0 的要求，见 entry/src/main/golang/go.mod）
go version
```

若没有：从 <https://go.dev/dl/> 装（或 `sudo snap install go --classic`）。
**不要**用发行版仓库里过旧的 Go。

> ⚠️ **一个重要分岔**：`go.mod` 写的是 `go 1.26` / `toolchain go1.26.4`。
> 但如果你最后决定走 §6.3 的 **B 路线（第三方 fork）**，那你用的**不是官方 Go**，
> 而是一个 `GOOS=openharmony` 的 fork。详见 §6.3。

### 2.4 其他工具

```bash
sudo apt-get update
sudo apt-get install -y git make file build-essential
```

`make` 是 T2（hev 用 Makefile）需要的；`file` 用于验收时看产物类型。

---

## 3. 拿代码

```bash
git clone https://github.com/kuaizhongqiang/HarmonyBridge.git
cd HarmonyBridge
git checkout main      # 或你想要的具体 tag
```

**不需要** `--recursive`：`third_party/v2rayN` 是只读参考 submodule，与构建无关
（`AGENT.md` §5.1 说明了为什么不需要）。

先跑一遍本机门禁，确认代码本身是干净的：

```bash
cd entry/src/main/golang
gofmt -l .                 # 必须为空
go build ./...             # 必须 0
go vet ./...               # 必须 0
go test ./... -count=1     # 必须全绿
cd ../../..
```

> 🧪 这几条在 Windows 上已验证全绿；Linux 上应当一致。若不一致，**先如实报差异**，不要继续。

---

## 4. T1：编译 `libcore.so`

### 4.1 先跑一次"原样脚本"，把真实失败点拿到手

**不要一上手就先改脚本。** 先跑原样的，把真实的报错原文记下来：

```bash
bash scripts/build-core.sh "$OHOS_NDK_HOME"
```

脚本行为（已读源码确认）：

- 解析 NDK（参数 → `$OHOS_NDK_HOME` → 若干默认路径）
- 检查 `clang clang++ llvm-ar ld.lld llvm-strip llvm-config` 是否齐全
- 设置 `CC/CXX/AR/LD/...`、`CFLAGS=-target aarch64-linux-ohos --sysroot=... -D__MUSL__`
- `CGO_ENABLED=1 GOOS=android GOARCH=arm64`
- `go build -tags "fts5 timetzdata" -ldflags "-s -w" -buildmode=c-shared -v -o libcore.so .`
- 把产物复制到 `entry/libs/arm64-v8a/libcore.so`

**预期**：它会在 **Go 标准库**里失败，报错形如

```text
.../go/src/net/cgo_resold.go:NN:NN:
cannot use _Ctype_size_t(len(b)) (value of type _Ctype_size_t)
as _Ctype_socklen_t value in argument to _C2func_getnameinfo
```

以及可能更早的：

```text
.../runtime/cgo/gcc_android.c:6:10: fatal error: 'android/log.h' file not found
```

**把这两条的真实原文（不要润色、不要省略路径）记进报告。** 这是交付物的一部分。

### 4.2 两个必须解决的问题（脚本没有帮你解决，需要你动手）

#### 问题 A：OHOS sysroot 里没有 `android/log.h`（可绕过）

因为 `GOOS=android`，Go 会编译 `runtime/cgo/gcc_android.c`，它 `#include <android/log.h>`。

🧪 **本机已核实**：整个 OHOS NDK 里**没有** `android/log.h`
（只有 `sysroot/usr/include/hilog/log.h`，那是华为自己的）。

**解法**：写一个两行 shim 头，经 `-I` 注入。内容只需声明：

```c
/* android-shim/android/log.h */
#pragma once
enum { ANDROID_LOG_FATAL = 6 };
static inline void __android_log_vprint(int prio, const char *tag, const char *fmt, ...) {
    (void) prio; (void) tag; (void) fmt;
}
```

再用 `CGO_CFLAGS` 里的 `-I<shim 目录>` 注入（放在 `$OHOS_NDK_HOME/sysroot` 之前无所谓，
因为 OHOS 里根本没有同名文件，不存在遮蔽问题）。

> ⚠️ 该文件同时定义了 `x_cgo_inittls`（Android 专用的 TLS slot 探测）。
> **在 OHOS 上它的正确性没有证据**，这属于 §6.3 的 TLS 风险的一部分。

#### 问题 B：`socklen_t` 类型不匹配（**真正的拦路石**）

🧪 **本机已逐个头文件核实**（这是硬证据，不是推测）：

| | 定义 | 位置 |
| --- | --- | --- |
| OHOS musl | `typedef unsigned socklen_t;`（**32 位**） | `sysroot/usr/include/aarch64-linux-ohos/bits/alltypes.h:375` |
| Go 的 android 端口假设 | `socklen_t` 与它传入的 `size_t` **同宽**（bionic 的约定） | `src/net/cgo_resold.go` |

cgo 生成的调用因此类型不匹配。**这不是加编译选项能解决的**，二选一：

**A 路线（改动最小、保留官方 Go）**：给 Go 标准库打一个强制转换补丁。

```bash
# 找到 Go 的源码目录
GOROOT="$(go env GOROOT)"
# 在报错的那个调用点，把 size_t 实参显式转成 socklen_t
# 具体行号以你的 Go 版本报错为准，不要照抄行号。
```

建议做成**可复现的补丁文件**（`*.patch`）并交出，而不是手工改 `GOROOT` 就算了。

**B 路线（不动 Go，做头文件覆盖层）**：提供一份让 `socklen_t` 与 bionic 同宽的
`bits/alltypes.h` 覆盖层，经 `-I` 或 `--sysroot` 顺序注入。

> ❓ **B 路线我尚未验证**，只提出假设。难点：`socklen_t` 定义在
> `bits/alltypes.h`，而该头被**大量**系统头包含，遮蔽它的连带影响必须实测。
> 若你走 B，请特别记录"有没有别的类型因此报错"。

### 4.3 你还有第三个选择：换工具链（见 §6.3 的 B 路线）

如果 A/B 都卡住，或者你更看重**运行期可靠性**，可以改用 `GOOS=openharmony` 的
**第三方 Go fork**。这不是"绕过去"，而是换一条**证据更强**的路 —— 详见 §6.3 与
[`research/02-核心移植方案.md`](research/02-核心移植方案.md) §7。

### 4.4 构建成功后立刻做的事

```bash
cd entry/src/main/golang
ls -la libcore.so
file libcore.so
"$OHOS_NDK_HOME/llvm/bin/llvm-readelf" -h libcore.so | head -20
```

必须看到：**ELF64 / AArch64 / DYN（共享库）**。

然后**必须做** §6.3 的 TLS 检查 —— 那才是这条路线的成色所在。

---

## 5. 为什么先做 T1（排序理由）

- T1 编不出来 → 内核不存在 → 本地 SOCKS 入站不存在 → **tun2socks 把流量交出去也没人接**，
  T2 编出来也无法验证任何东西。
- T1 的失败是**确定的、已定位到一行代码**的失败；T2 的失败是**配方层面的未知**。
  先啃确定的。
- 两者都需要 NDK，环境一次装好，先做难的。

---

## 6. 关键决策与已知坑（**这一节请务必读完再动手**）

### 6.1 五个已被前人踩过的坑（省你时间）

| # | 坑 | 状态 | 对你的影响 |
| --- | --- | --- | --- |
| 1 | Go 官方**没有** `GOOS=ohos` | ✅ 已证实，无法绕过 | 所以用 `GOOS=android` 借道，这是社区做法**不是官方支持** |
| 2 | `-D__MUSL__` 是承重墙 | ✅ 已证实 | 漏了**不会编译报错**，而是**运行期崩溃**。脚本已带 |
| 3 | NDK 路径含空格 → cgo 截断 `CC` | 🧪 实测（Windows 上致命） | Linux 上同样会坏（`$CFLAGS` 展开），**放无空格路径** |
| 4 | sysroot 无 `android/log.h` | 🧪 已核实 | 见 §4.2 问题 A，可绕过 |
| 5 | `socklen_t` 类型冲突 | 🧪 已核实 | 见 §4.2 问题 B，**拦路石** |

**已经排除的**：Windows 上那个"8.3 短名救不了"的
附加麻烦在 Linux 上不存在。交叉编译能力本身**没问题** ——
🧪 本机实测 `clang --target=aarch64-linux-ohos` 能产出 ELF64 AArch64 目标文件
（`docs/design/core.md:334`）。失败**只**发生在 Go 的 cgo 生成代码里。

### 6.2 `GOOS=android` 的三个代价（必须知道，不能假装没有）

1. Go runtime 编入 **android 分支**（`runtime/internal`、网络栈行为差异）；
2. `proxy/tun` 选中 **android 后端**而非 linux 后端；
3. **TLS 假设是按 Android bionic 写的** —— 见下条。

### 6.3 ⚠️ 头号风险：这是"能编" ≠ "真机不崩"的那条线

`GOOS=android` 借的是**为 bionic 写的 TLS 假设**（固定 TLS 槽）。OHOS 用 musl +
`R_AARCH64_TLSDESC`。🌐 有公开记录：**外来线程（ArkTS / VPN 扩展进程）调 cgo 时
概率性 SIGSEGV**。

**所以 T1 的验收必须包含 TLS 检查**（这是本任务书最有价值的部分）：

```bash
# 1) 程序头里有没有 TLS 段？
"$OHOS_NDK_HOME/llvm/bin/llvm-readelf" -l libcore.so | grep -i tls

# 2) 动态重定位里 TLS 用的是哪种类型？
"$OHOS_NDK_HOME/llvm/bin/llvm-readelf" -r libcore.so | grep -i tls

# 3) 导出符号在不在（这是 App 真正要用的两个）？
"$OHOS_NDK_HOME/llvm/bin/llvm-nm" -D --defined-only libcore.so | grep -E 'GoInvoke|GoFreeCString'
```

**判读**：

- 看到 `R_AARCH64_TLSDESC` 而不是 `R_AARCH64_TLS_TPREL*` → **好消息**，说明没有落到
  bionic 那套固定槽假设上。
- 看到 `GoInvoke` 与 `GoFreeCString` 都是 `T`（定义在本库、全局）→ 导出正确。
- **无论结果如何都如实记录原始输出** —— 这份记录本身就是下一步的输入。

**如果 TLS 检查结果不乐观，或你在真机前就想降低风险**，那就要考虑下面这条路线：

#### B 路线：改用 `GOOS=openharmony` 的第三方 Go fork

🌐 依据（详见 [`research/02-核心移植方案.md`](research/02-核心移植方案.md) §7）：

| 方案 | 版本能力 | 评价 |
| --- | --- | --- |
| 官方 OpenHarmony SIG fork | 封顶 **go1.24.5** | ❌ **编不动**本项目的 xray-core（要求 go1.26） |
| 🌐 `star4277/ohos-go` | **v1.26.5-beta1** | 事实上的可用工具链，但**是个人 fork（star 数极低）** |

⚠️ **两个必须写进报告的风险**：

1. **供应链风险**：现役可用工具链是个人 fork。用不用**需要人来拍板**，
   不该由执行者默默决定。
2. **`-buildmode=c-shared` 在 openharmony 目标上是否支持未证实** ——
   🌐 有论坛标题称不支持（未抓取正文，❓）。**若你要走 B，请先验证这一条**，
   否则可能白忙。

> 📌 **建议**：**先走 A 路线（官方 Go + 补丁）把 `libcore.so` 编出来**，
> 拿到 TLS 检查的真实数据；然后由项目负责人**基于数据**决定是否换 B 路线。
> 不要一上手就引入第三方工具链 —— 那会把"能不能编"和"该不该用"两件事混在一起。

---

## 7. T2：编译 `libhevsocks5tun.so`

上游：<https://github.com/heiher/hev-socks5-tunnel>（**MIT**，2.0k+ star）

🧪 **本机已核实的三件事**（原来的脚本头部把前两条列为"未确认"，现已确认）：

1. ✅ **上游确实提供 `build.mk`**（仓库根目录），并且 `SRCFILES=$(call rwildcard,$(SRCDIR)/,*.c *.S)`
   —— **所以"SRCFILES 为空"这个担心不成立**。
2. ✅ **`src/` 下确实有 .c 源码**（`hev-main.c`、`hev-socks5-tunnel.c`、
   `hev-tunnel-linux.c` …），不是空壳。
3. ✅ **许可证是 MIT** —— 与本仓库的 MIT + Xray-core(MPL-2.0) 边界**兼容**，
   不会失守（这一点当初是选它的硬理由之一）。

**仍未验证的**（你来做）：

- ❓ `third-part/lwip`、`third-part/yaml`、`third-part/hev-task-system` 能否**交叉到 OHOS musl**。
- ❓ 上游 `CCFLAGS` 默认带 `-Werror`（脚本已加 `-Wno-error` 缓解）——交叉编译的
  告警是否会变成硬失败。

**已知的一个结构细节**：`.gitmodules` 里除了三个 `third-part/*`，还有
**`src/core`（= heiher/hev-socks5-core）**。脚本用的是 `git clone --recursive`，
**请确认 `src/core` 也被拉下来了**（嵌套 submodule 有时不会自动递归）。

### 7.1 做法

```bash
bash scripts/build-tun2socks.sh "$OHOS_NDK_HOME"
```

**失败也要如实记录**。按项目既有纪律：**这份"失败点记录"本身就是交付物**，
不要绕过、不要为了让它绿而伪造产物。

### 7.2 验收

```bash
cd entry/libs/arm64-v8a
file libhevsocks5tun.so
"$OHOS_NDK_HOME/llvm/bin/llvm-readelf" -h libhevsocks5tun.so | head -20   # ELF64 AArch64 DYN
"$OHOS_NDK_HOME/llvm/bin/llvm-nm" -D --defined-only libhevsocks5tun.so | grep -i hev
```

`libbridge.so`（NAPI 桥）通过 `dlopen("libhevsocks5tun.so")` 加载它，再用 `dlsym`
解析 **3 个**符号（已读 `entry/src/main/cpp/tun2socks_bridge.cpp` 核实，逐字如下）：

```text
hev_socks5_tunnel_main_from_str
hev_socks5_tunnel_quit
hev_socks5_tunnel_stats
```

所以 `llvm-nm` 必须能看到**这三个**（任一缺失，真机上 `Tun2socksStart` 就只能
返回 `libhevsocks5tun.so is not available: …` 这类可读错误，数据面起不来）。

---

## 8. 验收清单（**逐条勾，别跳**）

### T1 · `libcore.so`

- [ ] `entry/libs/arm64-v8a/libcore.so` 存在，大小合理（数十 MB 量级）
- [ ] `file` 显示 **ELF 64-bit LSB shared object, ARM aarch64**
- [ ] `llvm-readelf -h` 的 `Type` 是 `DYN`
- [ ] `llvm-nm -D --defined-only` 能看到 **`GoInvoke`** 与 **`GoFreeCString`**
- [ ] **TLS 检查已做，原始输出已记录**（§6.3）—— 这是最重要的一条
- [ ] `llvm-readelf -d` 里**没有**未解析的 `libohcommonevent` / `libhilog_ndk.z` / `libtime_service_ndk` 之外的意外依赖
- [ ] 报告里写清：**用了 A 路线还是 B 路线**，以及具体改了什么

### T2 · `libhevsocks5tun.so`

- [ ] 文件存在、`file` 显示 ELF64 aarch64 共享库
- [ ] `llvm-nm -D --defined-only` 里能看到**全部 3 个**桥接符号
      （`hev_socks5_tunnel_main_from_str` / `_quit` / `_stats`）
- [ ] 若失败：**失败点（原始报错）+ 你判断的根因**，比"没成功"有价值得多

### 通用

- [ ] `git status` 里**没有** `.so` / 构建产物（必须保持 gitignored）
- [ ] 若你改了脚本或加了补丁：用 **`git diff` 或 `git format-patch` 交出**，
      commit message 用 Conventional Commits（`.githooks/commit-msg` 会拦）
- [ ] 报告按 §9 模板写完，**每个结论都带证据标记**

---

## 9. 怎么交付（报告模板）

**交付方式**：把产物放在 `entry/libs/arm64-v8a/`（**不入库**，交给项目负责人），
把**改动做成 patch**，把**报告**按下面模板写成一段文本（或 `docs/` 下新文件）。

```markdown
# Linux 构建报告 — <日期> — <机器/发行版>

## 环境
- 宿主：<Ubuntu 24.04 / WSL2 等>，arch
- NDK：<路径>，clang 版本 <x.y.z>（🧪 clang --version 输出）
- Go：<go version 输出>（或 fork 名称 + tag）

## T1 · libcore.so
- 结论：✅ 编出 / ❌ 未编出（**二选一，不许模糊**）
- 走的路线：A（官方 Go + 补丁）/ B（fork）
- 关键报错原文（若失败，**原样粘贴**）：
  ```
  ...
  ```
- 我改了什么：<patch 路径 / 具体文件:行 / 为什么>
- 验收输出（**原样粘贴**）：
  - file:
  - llvm-readelf -h（Type 那几行）：
  - llvm-nm（GoInvoke / GoFreeCString）：
  - **TLS 检查（-l 与 -r 的 tls 相关行）**：
- 产物：大小 <x> MB，路径 <...>

## T2 · libhevsocks5tun.so
- 结论：✅ / ❌
- 关键报错原文 / 我改了什么
- 符号核对：dlsym 目标 <符号名> 是否存在

## 我不确定的事（❓，务必写）
- <例如：TLS 重定位类型看着对，但真机外来线程调 cgo 仍未验证>

## 我确定没做的事（避免下一个人误判）
- <例如：没有在真机上跑过；没有验证 hev 处理 OHOS vNIC fd>
```

> **报告的价值排序**：**精确的失败 > 含糊的成功**。
> 如果你只做到"定位到某一行并给出补丁但没编过"，那依然是一次**成功的交付**，
> 因为下一个人的起点被你推近了。

---

## 10. 明确不要做的事（边界）

| ❌ 不要 | 原因 |
| --- | --- |
| 不要 commit `*.so` / `*.hap` | `AGENT.md` §1：不提交构建产物；`.gitignore` + `verify-repo.ps1` 会拦 |
| 不要为了让它编译过而**删功能 / 改配置** | 那是伪造。失败点本身是交付物 |
| 不要声称"能在真机上跑" | 没有真机。**"编出来"和"能用"是两件事** |
| 不要擅自引入第三方 Go fork 作为最终方案 | 供应链风险需**人**拍板（§6.3） |
| 不要越过许可边界 | Xray-core 是 MPL-2.0；hev 是 MIT；`third_party/v2rayN` 是 GPL-3.0 **只读参考** |
| 不要改 `third_party/` | 只读参考 submodule |
| 不要说"CI 绿了所以没问题" | CI **不**构建这两个 `.so`（需要 NDK），它只保证代码层门禁 |

---

## 11. 参考资料（按阅读顺序）

| 文档 | 看什么 |
| --- | --- |
| [`AGENT.md`](../AGENT.md) | **先读这份**：作业边界、硬约束、证据标记约定 |
| [`design/core.md`](design/core.md) §6 | 交叉编译三个障碍的**完整尸检**（含原始报错） |
| [`research/02-核心移植方案.md`](research/02-核心移植方案.md) §7–§8 | Go/OHOS 生态现状、fork 选项、TLS 墙 |
| [`00-技术路线可行性.md`](00-技术路线可行性.md) §4、§11 | 为什么数据面换成纯 C；B2 的范围如何缩小 |
| [`TODO.md`](../TODO.md) §1 | 这两件事在全局里的位置与前置条件 |
| [`03-环境搭建.md`](03-环境搭建.md) §5.3 | 原机器的构建命令（对照用） |
| [`design/ci.md`](design/ci.md) | CI/发布怎么跑（**不含**这两个 `.so`） |

---

## 12. 做完之后会发生什么（让你知道为什么值得做）

1. `libcore.so` + `libhevsocks5tun.so` 放进 `entry/libs/arm64-v8a/`
2. 打一个 tag → **CI 自动构建并发布 HAP**（这条流水线**已经跑通**，
   见 `docs/design/ci.md` §5；你不需要碰它）—— 但注意：Release 里的 HAP
   **不会**自动包含 `.so`，需要把它们放进构建目录后再构建，或由项目负责人决定
   是否改为"把预编译 `.so` 纳入构建"（**这是一个待决策项，不是你该默默做的改动**）
3. 拿到真机后，按 `AGENT.md` §9 走 6 步验证 —— 那时才第一次有人能说这个项目"能用"

> ⚠️ 第 2 点是个**真实的流程缺口**：当前 `.gitignore` 明确不跟踪 `.so`，
> 而 CI 从 git 检出代码后构建，所以 CI 产出的 HAP 里**没有这两个 `.so`**。
> 这不是 bug，是"还没决定怎么把预编译产物交给 CI"。
> **请把这一点写进你的报告**，让负责人决定（常见做法：CI secret 里的对象存储、
> Release 资产回填、或自托管 runner 上预置文件）。
