# OHOS Go 工具链自研任务书（路线 1）

> **本文档的用途**：把"自己做 OHOS 的 Go 移植"这件事完整交接给一台新机器 / 新的执行者。
> 读完这份就能独立开工、独立判断成败、独立交付。
>
> 最后更新：2026-10-11 ｜ 前置阅读：[`AGENT.md`](../AGENT.md)、
> [`04-Linux构建任务书.md`](04-Linux构建任务书.md)（那份是"编 `.so`"，这份是"造工具链"）
>
> **决策已定**（2026-10-11，项目负责人）：
> 1. **不使用** `star4277/ohos-go` 作为生产工具链；
> 2. 走**路线 1**：**以官方 OpenHarmony SIG 的移植为基线，自己维护 + 跟上游 rebase**；
> 3. 参考实现**只读**——可以读它的 diff 搞清楚"要改什么"，**代码自己重写**。
>
> **证据标记沿用 `AGENT.md` 第 8 节**：🧪 实测 ｜ ✅ 源码核实 ｜ 📄 官方 ｜ ❓ 未证实

---

## 0. 一句话说清你要干什么

**造出一个能编 OHOS 原生库的 Go 工具链，并且它是我们能自己维护的。**

具体目标产物是一个 **`GOOS=openharmony GOARCH=arm64` 的 Go 编译器+运行时**，
用它执行 `-buildmode=c-shared` 产出 `libcore.so`（代理内核）——也就是
[`04-Linux构建任务书.md`](04-Linux构建任务书.md) 里 T1 那条命令。

**为什么不能直接用官方 Go**：上游 `golang/go` **至今没有任何 openharmony 支持**（🧪 见 §1.1）。
所以任何方案都是"某个 fork"；本任务书要解决的是"**由谁维护、维护多少**"。

---

## 1. 起点：已核实的全部事实（**不要重复调研**）

### 1.1 上游 Go 没有 openharmony（🧪 2026-10-11 实测）

| 检查 | 结果 |
| --- | --- |
| `golang/go` master 的 `src/internal/syslist/syslist.go` | `openharmony` 出现 **0** 次 |
| master 的 `src/cmd/dist/build.go` | **0** 次 |
| master 的 `src/internal/platform/supported.go` | **0** 次 |
| master 的 `src/internal/goos/gengoos.go` | **0** 次 |

**推论**：不存在"等上游支持"这条路。必须维护一个移植。

### 1.2 官方 SIG 的移植**存在**，且在 GitCode（🧪 已可达）

| 项 | 值 |
| --- | --- |
| 仓库 | `https://gitcode.com/openharmony-sig/ohos_golang_go` |
| 许可证 | **BSD-3-Clause**（与 Go 上游同源，🧪 读了 LICENSE） |
| 移植所在分支 | **`release-branch.go1.24`** 与 `release-branch.go1.24_HiShell` |
| 该分支 `VERSION` | **`go1.24.5`**，`time 2025-07-02T21:47:15Z` |
| 官方 tag | `go1.24.5.ohosv1r1`、`go1.24.5_HiShell.ohosv1r1` |
| ⚠️ **`release-branch.go1.26`** | **存在，但里面 `openharmony` 出现 0 次** —— 那条分支还**没有**移植 |

> 🧪 **访问方式**（已实测）：
> - `git clone --depth 1 --branch release-branch.go1.24 https://gitcode.com/openharmony-sig/ohos_golang_go.git` ✅ 可用
> - 单文件读取走 `https://raw.gitcode.com/openharmony-sig/ohos_golang_go/raw/<branch>/<path>` ✅ 可用
> - ⚠️ `https://raw.gitcode.com/...` 加 `.git` 后缀会 404；clone 要用**不带 raw** 的主机名。

### 1.3 SIG 移植的**真实规模**（🧪 逐行数出来的）

`git diff upstream-go1.24.5 <SIG release-branch.go1.24>`：

| 类别 | 条目 | 改动行 |
| --- | --- | --- |
| **与 openharmony 相关**（运行时/工具链/构建） | ~131 | **+1985 / -512** |
| ⚠️ **与 openharmony 无关**（SIG 分支还带了别的上游补丁） | 36 | +777 / -167 |
| 合计 | 167 | +2768 / -679 |

⚠️ **重要**：那 36 个"无关"文件（`src/archive/tar/`、`src/database/sql/`、`src/crypto/x509/`、
`src/net/http/cookie.go`、`src/encoding/asn1/`、`src/os/user/user_windows_test.go` …）
**不属于移植**，是 SIG 分支附带的其他改动。**做移植时不要照搬这些文件** —— 只取 §2 的清单。

### 1.4 移植的核心文件清单（这些才是"要改什么"）

**A. openharmony 专属新文件（go1.26 里不存在，需新增）** —— 🧪 已确认上游无：

| 文件 | 行数 |
| --- | --- |
| `src/runtime/rt0_openharmony_arm64.s` | 64 |
| `src/runtime/cgo/gcc_musl_linux.c` | 29 |
| `src/runtime/cgo/callbacks_musl_linux.go` | 23 |
| `src/internal/goos/zgoos_openharmony.go` | 27 |
| `src/net/interface_table_openharmony.go` | 146 |
| `src/time/zoneinfo_openharmony.go` | 115 |
| `src/mime/type_openharmony.go` | 9 |

**B. 需要 merge 的既有文件（按子系统分组）**：

| 子系统 | 文件 | 大致规模 |
| --- | --- | --- |
| **TLS（最关键）** | `src/runtime/tls_arm64.{h,s}` | +47/-20 |
| 运行时 | `runtime/{proc,os_linux,runtime1,runtime2,malloc,mbitmap,extern}.go`、`asm_arm64.s` | ~250 行 |
| 目标注册 | `internal/goos/gengoos.go` + 20 个 `zgoos_*.go`、`internal/platform/{supported,zosarch}.go`、`internal/syslist/syslist.go` | ~120 行（多为机械 +1） |
| **汇编器** | `cmd/internal/obj/arm64/{obj7,asm7,a.out}.go`、`cmd/internal/objabi/{reloctype,reloctype_string,head}.go` | ~160 行 |
| **链接器** | `cmd/link/internal/ld/{lib,decodesym,link,outbuf_mmap}.go`、`cmd/link/internal/{arm64/asm,loader/loader}.go` | ~180 行 |
| go 命令 | `cmd/go/internal/{cfg,load,modindex,imports,bug,envcmd}/`、`cmd/go/internal/work/{exec,gccgo,init}.go` | ~50 行 |
| 构建 | `cmd/dist/{build,test}.go`、`go/build/{build,gc}.go`、`bootstrap.bash` | ~60 行 |
| 标准库适配 | `net/{cgo_unix_cgo,conf,interface_linux,interface_table_linux}.go`、`os/`、`os/exec/`、`time/zoneinfo_unix.go` | ~250 行 |
| 测试桩 | `cmd/cgo/internal/test/cgo_stubs_openharmony_test.go` 等 | 少量 |

**结论：核心移植 ≈ 1990 行新增 + 512 行修改。**
不是"从零写编译器"，是**接手一份约 2500 行的补丁集**。

### 1.5 TLS 的具体机制（这是移植的"技术核心"）

🧪 从 SIG 的 `src/runtime/tls_arm64.h` 与那个参考实现读出来的：

- 上游用 `MRS_TPIDR_R0`（`MRS TPIDR_EL0, R0`）取线程指针；
- **android 分支带 `#define TLSG_IS_VARIABLE`** —— 即把 g 的偏移放在变量 `tls_g` 里，
  指望**动态链接器加载时填入"分到的 TLS 槽号"**。这是 **Bionic 的模型**；
- **openharmony 分支故意【不】定义 `TLSG_IS_VARIABLE`**，改走 **`TLS_GD`（广义动态）**：
  把取偏移那条指令展开成 `ADRP;LDR;ADD;BLR`，`BLR` 调 `__tlsdesc_stub`，由动态链接器解析。

**为什么这件事决定成败**：musl **不提供** Bionic 那套按槽分发机制。所以
`TLSG_IS_VARIABLE` 那条路在 OHOS 上是**未定义行为**——这正是"官方 Go + `GOOS=android`"
（A 路线）产物的 `PT_TLS` 段与 TLS 重定位**都为空**的原因，也是它作为备选方案价值很低的理由。

**验收时必须验的就是这个**：`PT_TLS` 段存在 + `R_AARCH64_TLSDESC` 重定位存在。

---

## 2. 决策点：先解决"Go 版本鸿沟"

**这是开工前必须定的第一件事**，因为两条路的工作量差很多。

| | SIG 移植 | 我们的 xray-core |
| --- | --- | --- |
| Go 版本 | **go1.24.5** | `go.mod` 要求 **go1.26** |

🧪 已核实：xray-core 的版本—Go 要求史（从 `goproxy.cn` 取 `.mod`）：

| xray-core 版本 | 要求 |
| --- | --- |
| `v1.250910.0` ~ `v1.251208.0` | go **1.25** |
| `v1.260113.0` | go 1.25.5 |
| `v1.260206.0` | go 1.25.7 |
| `v1.260327.0`（我们锁定的） | go **1.26** |

**可见范围内没有任何 xray 版本要求 ≤ go1.24**。所以只有两条路：

### 路线 1A：把 SIG 的移植**往前搬**到 go1.26（✅ 推荐）

保留我们锁定的 xray-core，把移植从 go1.24.5 rebase 到 go1.26。

- **优点**：不牺牲内核版本；移植所需的那几个子系统（runtime TLS、链接器、objabi）
  在 1.24→1.26 之间**变动不大**（🧪 参考实现就是从 go1.24 树 merge 到 go1.26.5 成功的）。
- **代价**：要逐个文件把 SIG 的补丁重放到 go1.26 上，遇到冲突要自己判断。

### 路线 1B：**降 xray-core** 以匹配 go1.24.5

- **优点**：移植本身不用动，直接用 `release-branch.go1.24`。
- **代价**：**连 go1.25 的版本都不满足** → 要退到 2025 年中的 xray（甚至更早），
  意味着放弃半年多的上游修复，且研究报告 §8.5 记录过"xray 版本与 Go 版本互相锁死"的坑。
- **❓ 前置验证**（很便宜，建议先做）：**xray-core 到底有没有真的用到 go1.26 的语法特性？**
  `go.mod` 里的 `go 1.26` 只是声明。做法：在 Linux 机器上用 go1.24.5 直接
  `go build ./...`（把 `GOTOOLCHAIN=local` 固定住），看它是因为**语法/标准库 API** 失败，
  还是仅仅因为版本声明被拒（后者可用改 `go.mod` 绕过）。

> 📌 **建议**：**先花 10 分钟做 1B 的那个 ❓ 验证**。
> 如果 xray-core 在 go1.24.5 上能编，1B 立刻变成最省的路；
> 如果不能编，就坚定走 1A，不用再犹豫。

---

## 3. 怎么开工（按顺序，每步都要留下证据）

### 步骤 0：拿基线（🧪 已实测可行）

```bash
git clone --depth 1 --branch release-branch.go1.24 \
  https://gitcode.com/openharmony-sig/ohos_golang_go.git ohos-go
cd ohos-go
cat VERSION        # 应为 go1.24.5
```

再取上游用于对比（看清"移植到底改了什么"）：

```bash
git remote add upstream https://github.com/golang/go.git
git fetch --depth 1 upstream refs/tags/go1.24.5:refs/tags/upstream-go1.24.5
git diff --name-status upstream-go1.24.5 HEAD | wc -l     # 应为 167
```

> ⚠️ **务必自己跑这条 diff**。§1.3 的数字是我在另一台机器上量出来的；
> 你要在**你自己的克隆**上复现它，并把数字记进报告。

### 步骤 1：先证明基线能编（在任何改动之前）

```bash
cd src && GOROOT_BOOTSTRAP=<某个 go1.24.5+ 的官方 Go> ./make.bash
# 产出 ../../bin/go
../../bin/go version          # 应显示 linux/amd64（宿主）
```

**然后立刻验证它认 openharmony 目标**：

```bash
../../bin/go tool dist list | grep openharmony     # 期望看到 openharmony/arm64
```

> ⚠️ 若这一步就失败，**先如实记录，不要继续** —— 说明基线本身有问题，
> 先解决它，否则后面所有失败都无法归因。

### 步骤 2：用基线工具链编一次 `libcore.so`（**先要一个"已知可用"的参照**）

用 SIG 的 go1.24.5 工具链、`GOOS=openharmony`，对我们的 Go 代码做**语法/类型层面的编译**尝试：

```bash
# 注意：xray-core 声明 go1.26，这里预期会被版本声明挡住 —— 这正是步骤 3 要判定的事
GOTOOLCHAIN=local GOOS=openharmony GOARCH=arm64 CGO_ENABLED=0 \
  go build ./... 2>&1 | head -30
```

- 如果失败信息里**只有** `go.mod requires go >= 1.26` 之类 → 说明**只需处理版本声明**（往 1B 走）。
- 如果出现**真实语法/API 错误** → 说明 xray-core 真的用了新特性（走 1A）。

**把这个输出原样记进报告 —— 它是路线决策的直接依据。**

### 步骤 3：走 1A（搬到 go1.26）时的做法

1. 以 **上游 `go1.26.5`** 为基线建一棵树（`git clone` + `git checkout` 到该 tag）；
2. **逐个子系统**把 §1.4 清单里的移植重放上去。建议顺序（依赖关系）：
   1. `internal/goos` + `internal/platform` + `internal/syslist` + `cmd/dist` —— 让目标"被认识"
   2. `cmd/internal/objabi` + `cmd/internal/obj/arm64` + `cmd/link` —— 让汇编器/链接器"会生成"
   3. `runtime/*`（**含 TLS**）+ `rt0_openharmony_arm64.s` + `runtime/cgo/*musl*` —— 让它"能跑"
   4. `net/` `os/` `time/` `mime/` —— 标准库适配
   5. 测试桩（`*_stubs_openharmony_test.go`）—— 让测试套件不至于全红
3. **每完成一个子系统就编一次**（`make.bash`），别攒到最后。

> ⚠️ **许可证与署名**：Go 是 BSD-3-Clause。你**必须**保留原始版权声明。
> 由于我们有"参考实现只读、代码自己重写"的纪律（见 [`AGENT.md`](../AGENT.md) 第 6 节的思路），
> 建议：**移植代码自己写**，但在文件头注明"OHOS port, based on the OpenHarmony SIG port"
> 之类的出处说明。**不要把参考实现的代码整段粘进来却不注明来源。**

### 步骤 4：验收（**这是交付的核心，不是走过场**）

对你自己的工具链产出的 `libcore.so` 跑**与 04 任务书 §6.3 同一套检查**：

```bash
NDK=<你的 OHOS NDK>
"$NDK/llvm/bin/llvm-readelf" -h libcore.so | grep -E 'Class|Type|Machine'   # ELF64 / DYN / AArch64
"$NDK/llvm/bin/llvm-readelf" -l libcore.so | grep -i tls                    # 必须有 PT_TLS
"$NDK/llvm/bin/llvm-readelf" -r libcore.so | grep -i tls                    # 必须有 R_AARCH64_TLSDESC
"$NDK/llvm/bin/llvm-nm" -D --defined-only libcore.so | grep -E 'GoInvoke|GoFreeCString'
"$NDK/llvm/bin/llvm-readelf" -d libcore.so | grep NEEDED
```

**同时**做一个"工具链自身"的冒烟测试（证明你的 Go 运行时没坏）：

```bash
# 编一个最小的 c-shared 库，在 OHOS 上 dlopen 前先确认它形态正确
mkdir -p /tmp/smoke && cd /tmp/smoke
cat > main.go <<'EOF'
package main
import "C"
import "fmt"
//export Hello
func Hello() *C.char { return C.CString("hi from " + fmt.Sprint(42)) }
func main() {}
EOF
GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1 CC=$NDK/llvm/bin/clang \
  <你的go> build -buildmode=c-shared -o libsmoke.so .
"$NDK/llvm/bin/llvm-readelf" -r libsmoke.so | grep -i tls
```

> 💡 **这个冒烟测试很重要**：如果连 10 行的库都拿不到 `TLSDESC`，
> 就别急着用 33 MB 的 libcore.so 去排查 —— 先证明工具链本身对。

---

## 4. 验收清单（逐条勾）

- [ ] `go tool dist list` 里有 **`openharmony/arm64`**
- [ ] 自己的工具链 `make.bash` 成功，`go version` 可运行
- [ ] 最小 c-shared 冒烟库：`ELF64 AArch64 DYN` + **`PT_TLS`** + **`R_AARCH64_TLSDESC`**
- [ ] `libcore.so`：同上三条 + 导出 `GoInvoke` / `GoFreeCString`
- [ ] `DT_NEEDED` 恰好是 `libohcommonevent.so` / `libhilog_ndk.z.so` / `libtime_service_ndk.so` / `libc.so`
      （**多出 `liblog.so` 就是错的** —— 那是 A 路线的 bionic 残留）
- [ ] 与参考实现的产物做**同一套读数对比**（TLS 段/重定位/符号/NEEDED），差异逐条解释
- [ ] 报告按 §5 写完，每个结论带证据标记
- [ ] 工具链的**构建方式可复现**（记录：基线 commit/tag、`GOROOT_BOOTSTRAP` 版本、每条命令）

---

## 5. 怎么交付

```text
交付物
├── 1. 你自己的移植树（或其 patch 集 + 基线的确切 commit/tag）
├── 2. 用它能编出的 libcore.so（入不入库按项目纪律：不入库）
├── 3. 构建报告（按下面模板）
└── 4. 复现脚本（一条命令能重跑整个 make.bash + libcore.so 构建）
```

```markdown
# OHOS Go 工具链报告 — <日期> — <机器>

## 基线
- SIG 仓库/分支：<url> / <branch>，VERSION=<>，commit=<sha>
- 我的 tree 基于：上游 go<版本> <tag/sha>
- GOROOT_BOOTSTRAP：<官方 Go 版本>

## 路线判定（§2）
- xray-core 在 go1.24.5 下 `go build ./...` 的结果（**原样粘贴**）：
- 因此我走的是：1A（搬到 go1.26）/ 1B（降 xray）

## 移植清单（相对上游的 diff）
- 改动文件数 = ___（按子系统分组列出）
- 改动行数 = +___ / -___
- 与 SIG 移植的差异：<哪些文件我做法不同、为什么>

## 验收输出（原样粘贴）
- go tool dist list | grep openharmony：
- 冒烟库 readelf -l / -r 的 TLS 行：
- libcore.so 的 -h / -l / -r / -nm / -d：

## 我不确定的事（❓）
- <例如：真机没验；某个子系统我按 1.24 的做法重放，但 1.26 的语义变了我没吃透>

## 我确定没做的事
- <例如：没在真机上跑；没跑完整 go test 套件；没有验证 xx>
```

---

## 6. 明确不要做的事（边界）

| ❌ 不要 | 原因 |
| --- | --- |
| 不要把 `star4277/ohos-go` 当基线或长期依赖 | 负责人已决策（`AGENT.md` 第 6 节的"只读参考"纪律同理） |
| 不要整段粘贴参考实现代码且不注明来源 | BSD-3-Clause 要求保留版权；且违反本仓库纪律 |
| **不要照搬 §1.3 里那 36 个"与 openharmony 无关"的文件** | 那是 SIG 分支附带的其他补丁，混进来会污染我们的移植 |
| 不要声称"能编 = 能用" | 真机仍必然要验；`TLSDESC` 只是工具链级证据 |
| 不要为了让它编过而**关掉测试/删功能** | 失败点本身是交付物 |
| 不要 commit 工具链产物 / `.so` / 大二进制 | `AGENT.md` 第 1 节 + `.gitignore` + `verify-repo` 会拦 |

---

## 7. 参考资料

| 文档 | 看什么 |
| --- | --- |
| [`04-Linux构建任务书.md`](04-Linux构建任务书.md) | **先读**：拿 NDK、编 `.so`、TLS 验收、报告模板 |
| [`05-Linux构建执行报告-20261011.md`](05-Linux构建执行报告-20261011.md) | A/B 两条路线的**实测对照**（含 TLS 读数），本任务书的目标形态 |
| [`research/02-核心移植方案.md`](research/02-核心移植方案.md) §7–§8 | Go/OHOS 生态、fork 现状、TLS 墙、`-D__MUSL__` 承重墙 |
| [`design/core.md`](design/core.md) §6 | 交叉编译三个障碍的完整尸检 |
| [`../TODO.md`](../TODO.md) §0.1 | 当前状态：两个 `.so` 已交付、真机未验 |
