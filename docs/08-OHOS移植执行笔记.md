# OHOS Go 移植 · 执行笔记（1A 进行中）

> **这份记录 + [`06` 任务书](06-OHOS-Go工具链自研任务书.md) + [`07` Linux 清单](07-Linux机器工作清单.md) 三份合起来，
> 就是"接手就能继续干"的完整状态。**
>
> 最后更新：2026-10-11 ｜ 路线：**1A**（把官方 SIG 移植往前搬到 go1.26）
>
> 证据标记：🧪 实测 ｜ ✅ 源码核实 ｜ ❓ 未证实

---

## 1. 这一轮真的做出来了什么

| 产出 | 状态 |
| --- | --- |
| `go1.26.5` + SIG 移植的 **CLEAN-57 子集**，实测**干净应用** | 🧪 成功 |
| 可复现的 **patch 文件**（`format-patch` 产物，48,503 B） | 🧪 已生成 |
| 移植范围的**逐文件分类**（57 CLEAN / 73 DRIFT） | 🧪 已量出 |
| DRIFT 组里**最关键两个文件**的现状与要改什么 | ✅ 已定位 |

**意义**：移植不再是"一片未知的 2500 行"，而是拆成了**能机械套上的 57 个** +
**需要人工重放的 73 个**（后者有明确的上游漂移量排序，见 §3）。

---

## 2. 已实测可用的 patch

### 2.1 仓库里的正式副本（**推荐从这里取**）

```text
tools/ohos-port/CLEAN-57-on-go1.26.5.patch   （48,503 B，git format-patch 格式，已入库）
```

这是**入库的、可复现的**那一份。用法：

```bash
git clone --depth 1 --branch go1.26.5 https://github.com/golang/go.git go-ourport
cd go-ourport
git apply /path/to/CLEAN-57-on-go1.26.5.patch      # 或 git am
```

### 2.2 本机上的工作区（**可复现，但可能被清理**）

| 项 | 值 |
| --- | --- |
| 位置 | `%TEMP%\ohos-go-port\golang-go`（`%TEMP%` 有被清理风险；仓库里的 patch 才是权威副本） |
| 分支 | `try-port` |
| HEAD | `428ecea4 OHOS port: apply CLEAN-57 from official SIG (go1.26.5 base)` |
| 基线 tag | `go1.26.5` = `c19862e5`；`up-go1.24.5` = `9d828e80`；`sig-go1.24` = `302a5306` |
| 工作区 | 干净 |

### 2.3 patch 内容与实测结果

```text
基线：upstream go1.26.5（c19862e5）
内容：SIG 移植中「上游 1.24→1.26 未改动过」的 57 个文件
实测：git apply 干净通过；落地 36 个文件含 openharmony 字符串
```

**已落地的关键文件**（🧪 逐个核对过）：

| 文件 | openharmony 出现 |
| --- | --- |
| `src/runtime/rt0_openharmony_arm64.s` | 13 次（**新增文件**） |
| `src/runtime/tls_arm64.h` | 1 次（**TLS_GD 的开关**） |
| `src/runtime/tls_arm64.s` | — |
| `src/runtime/cgo/gcc_musl_linux.c` | **新增** |
| `src/runtime/cgo/callbacks_musl_linux.go` | **新增** |
| `src/internal/goos/zgoos_openharmony.go` | **新增** |
| `src/internal/syslist/syslist.go` | 2 次 |
| `src/mime/type_openharmony.go` | **新增** |
| `src/time/zoneinfo_openharmony.go` | **新增** |
| `src/net/interface_table_openharmony.go` | **新增** |

---

## 3. 移植范围分类（🧪 逐文件量出）

| 组 | 数量 | 含义 |
| --- | --- | --- |
| **CLEAN** | **57** | 上游 go1.24→1.26 **没动过**这些文件 → patch 可直接套 ✅ 已完成 |
| **DRIFT** | **73** | 上游动过 → **必须人工把移植语义重放到 1.26** |

**DRIFT 组的上游漂移量（前 15，越大越麻烦）**：

| 上游改动 | 文件 |
| --- | --- |
| +1280 / -548 | `src/runtime/proc.go` |
| +676 / -595 | `src/cmd/internal/obj/arm64/asm7.go` |
| +684 / -262 | `src/runtime/malloc.go` |
| +574 / -356 | `src/cmd/go/internal/work/exec.go` |
| +677 / -51 | `src/cmd/link/link_test.go` |
| +337 / -128 | `src/runtime/runtime2.go` |
| +262 / -86 | `src/runtime/asm_arm64.s` |
| +184 / -163 | `src/net/url/url.go` |
| +154 / -169 | `src/cmd/go/internal/load/pkg.go` |
| +45 / -261 | `src/cmd/internal/obj/arm64/obj7.go` |
| +122 / -37 | `src/cmd/link/internal/ld/lib.go` |
| +117 / -11 | `src/cmd/internal/objabi/reloctype.go` |
| +105 / -19 | `src/runtime/os_linux.go` |
| +92 / -33 | `src/cmd/dist/test.go` |

**DRIFT 组合计上游漂移：12,695 行。**

> ⚠️ **但不要被 12,695 吓到**：那 73 个文件里**很多是测试**（`*_test.go`、`testdata/`）。
> 真正影响"能不能编出 `.so`"的是**生产代码**那几个，见 §4。
> 建议先把生产代码做完、让工具链能跑，测试桩最后补。

---

## 4. ⚠️ 两个"卡住成败"的文件（都在 DRIFT 组，**必须手改**）

### 4.1 `src/internal/platform/supported.go` —— 不加它，`-buildmode=c-shared` 直接报不支持

**现状**（🧪 已核对 go1.26.5 原文）：`case "c-shared"` 的平台白名单里**没有 openharmony**：

```go
case "c-shared":
    switch platform {
    case "linux/amd64", "linux/arm", ... "android/amd64", "android/arm", "android/arm64", "android/386",
        "freebsd/amd64", "darwin/amd64", "darwin/arm64",
        "windows/amd64", "windows/386", "windows/arm64",
        "wasip1/wasm":
        return true
    }
    return false
```

**要做什么**：把 `"openharmony/arm64"`（以及 `"openharmony/amd64"`）加进这个白名单。
同文件还有 `c-archive`、`default`、`pie` 等分支，以及 `distInfo`/`zosarch.go` 里的平台表 ——
**都要一起加**，否则 `go tool dist list` 认不出目标。

### 4.2 `src/cmd/go/internal/work/init.go` —— 不加它，TLS 模型不对（无 `TLSDESC`）

**现状**（🧪 已核对）：`case "c-shared"` 里

```go
case "c-shared":
    pkgsFilter = oneMainPkg
    if gccgo {
        codegenArg = "-fPIC"
    } else {
        switch cfg.Goos {
        case "linux", "android", "freebsd":
            codegenArg = "-shared"
        case "windows":
            cfg.ExeSuffix = ""
        }
    }
    ldBuildmode = "c-shared"
```

**注意**：go1.26.5 里 **`tlsModel` 这个变量根本不存在**（🧪 `tlsModel` 出现 **0** 次）——
gccgo 分支用的是 `codegenArg`，而 TLS 模型在 1.26 里由**别处注入汇编器 flag**
（`platform.DefaultPIE` + asmflags 那条线）。

> 👉 **所以这个文件不能照搬 SIG/go1.24 的 patch**，必须：
> 1. 先搞清 **go1.26 里"给汇编器注入 `-tls=GD`"的正确位置**是哪里（读 1.26 源码，不是猜）；
> 2. 在那处对 `cfg.Goos == "openharmony"` 生效。
>
> **这是整个移植里最需要动脑的一步**，也是唯一"必须读 1.26 语义才能做对"的地方。

**参考实现是怎么做的**（只读参考，**不要抄**）：SIG/go1.24 与那个第三方 fork 都在
`init.go` 里引入 `tlsModel` 变量并给 arm64 设 `"GD"`，再据此给汇编器加 `-tls=GD -D=TLS_GD`。
**在 1.26 里要找到对等的注入点重写。**

---

## 5. 复现这一轮（任何人可重跑）

```bash
# 1) 建工作区（blobless 省流量；但注意：做 3-way 需要 blob，见下方坑）
mkdir -p ~/opt/ohos-port && cd ~/opt/ohos-port
git init -q golang-go && cd golang-go
git remote add origin https://github.com/golang/go.git
git remote add sig https://gitcode.com/openharmony-sig/ohos_golang_go.git
git fetch --depth 1 origin refs/tags/go1.26.5:refs/tags/go1.26.5
git fetch --depth 1 origin refs/tags/go1.24.5:refs/tags/up-go1.24.5
git fetch --depth 1 sig release-branch.go1.24
git tag -f sig-go1.24 FETCH_HEAD
git checkout -q go1.26.5

# 2) 取 patch（本机已生成，48,503 B）
#    %TEMP%\ohos-go-port\ohos-port-CLEAN-57.patch
git apply /path/to/ohos-port-CLEAN-57.patch
```

### 🧪 这一轮踩过的三个坑（省你时间）

1. **`--filter=blob:none` 会挡死 `--3way`**：报
   `repository lacks the necessary blob to perform 3-way merge`。
   做三方合并要么老老实实全量 fetch，要么别指望 `--3way`。
2. **不要用 `git apply --check` 判断"能不能套"**：它不做三方合并，对上下文漂移**过于严格**
   （实测 130 个文件里 117 个"失败"，但真正的问题是它根本没用 3way）。
   判断可行性的正确做法是 §3 那种**"上游这两版之间有没有动过这个文件"**的分类。
3. **PowerShell 写 patch 文件会坏**：`Set-Content -Encoding UTF8` 会加 BOM / 掺入 stderr，
   生成出 `System.Management.Automation.RemoteException` 这种垃圾行，`git apply` 直接失败。
   生成 patch 一律用 **`cmd /c "git ... > file"`**。
   （另：PowerShell 5.1 里「反引号 + 裸 LF」**不会续行**，会把 LF 转义掉 —— 脚本存 CRLF。）

---

## 6. 下一步（按顺序）

| # | 做什么 | 在哪做 |
| --- | --- | --- |
| 1 | 把 §4.1 `supported.go` 的平台表加全（含 `zosarch.go`、`distInfo`） | **本机** |
| 2 | 读 go1.26 源码，找到汇编器 TLS flag 的注入点，让 openharmony 走 **GD**（§4.2） | **本机** |
| 3 | 把 DRIFT 组里的**生产代码**逐个重放（先 runtime / objabi / link / obj/arm64） | **本机** |
| 4 | 交给 Linux 机器 `make.bash` + 冒烟库 + `libcore.so` 验收 | **Linux**（见 [`07`](07-Linux机器工作清单.md) P2） |
| 5 | 补 DRIFT 组里的**测试桩**（不阻塞构建，放最后） | 任一侧 |
| 6 | 真机验证（`AGENT.md` §9） | 需设备 |

**判断"第 1–3 步做完了"的标准**：Linux 机器上 `./bin/go tool dist list | grep openharmony`
出现 `openharmony/arm64`，且最小 c-shared 冒烟库能拿到 `PT_TLS` + `R_AARCH64_TLSDESC`。

---

## 7. 未证实的事（❓）

1. **CLEAN-57 之后，工具链能不能真编出来** —— 目前只证明"patch 能套上"，
   **没有编译验证过**（本机是 Windows，且有 73 个文件的移植还没做）。
2. **DRIFT 组里有没有"语义上也必须改"而我没识别的** —— 我只按"上游是否动过这个文件"分类，
   没有逐行判断移植的**语义**在 1.26 上是否仍然成立。
3. **`rt0_openharmony_amd64.s`**：SIG 那边似乎没有这个文件（或不在我选定的路径里），
   而那个第三方 fork 里有。amd64 不是我们的目标（只要 arm64），**但要在最终移植里明确"只支持 arm64"还是"也补 amd64"**。
4. **真机**：一切运行期行为仍未验证。
