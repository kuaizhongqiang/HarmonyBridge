# OHOS Go 移植 · 执行笔记（1A 已跑通工具链）

> **这份记录 + [`06` 任务书](06-OHOS-Go工具链自研任务书.md) + [`07` Linux 清单](07-Linux机器工作清单.md) 三份合起来，
> 就是"接手就能继续干"的完整状态。**
>
> 最后更新：2026-10-11（第二轮） ｜ 路线：**1A**（把官方 SIG 移植往前搬到 go1.26）
>
> 证据标记：🧪 实测 ｜ ✅ 源码核实 ｜ ❓ 未证实

---

## 0. 当前结论（一句话）

**移植已经做完，而且工具链级验收全过。** 🧪

在**本机 Windows** 上，用交付的 patch 树：

1. `make.bat` 编出 **go1.26.5 windows/amd64** 工具链（🧪 成功）；
2. `go tool dist list` 出现 **`openharmony/arm64`**，且 `CgoSupported: true`（🧪）；
3. 编出 10 行 `-buildmode=c-shared` 冒烟库 `libsmoke.so`：**`ELF64 AArch64 DYN` + `PT_TLS` + `R_AARCH64_TLSDESC`**（🧪）；
4. 编出**真的** `libcore.so`（34,560,600 B）：同样三条 + 导出 `GoInvoke`/`GoFreeCString`，
   `DT_NEEDED` **恰好** 4 个且**没有 `liblog.so`**（🧪）。

交付物：`tools/ohos-port/our-ohos-port-on-go1.26.5.patch`（102,735 B，90 文件，+1349/−234），
**已实测从全新 `go1.26.5` 干净套用**（`git apply --check` 通过，🧪）。

**剩下没验的**：真机运行（无设备，见 `TODO.md` §1.2）、完整 `go test` 套件、Linux 机器复核。

### 0.1 这一轮实测用的确切环境（复现请对齐）

| 项 | 值 |
| --- | --- |
| 宿主 | Windows（amd64） |
| 基线 | 上游 `go1.26.5` tag = `c19862e5` |
| bootstrap Go | 官方 **go1.26.4** windows/amd64（`GOROOT_BOOTSTRAP`） |
| OHOS NDK | DevEco 自带 `sdk/default/openharmony/native`，**clang 15.0.4**（`llvm-project 00dcd9cd`），sysroot `aarch64-linux-ohos` |
| NDK 路径 | 经 **junction** 映射到 `C:\ohndk`（**必须无空格**，否则 Go 会截断 `CC`） |
| cgo 目标 | `--target=aarch64-linux-ohos --sysroot=<ndk>/sysroot -fuse-ld=lld` |
| 构建缓存 | **全新 `GOCACHE`**（见 §5 坑 5） |

> ⚠️ 上一轮文档里"本机是 Windows，编不出工具链"的结论**已被推翻**：
> Windows 完全能编，只要有 bootstrap Go；**OHOS NDK 的 clang 也是 Windows 原生可执行文件**
> （所以连交叉编译都不需要 Linux）。这是本轮能"在 Windows 上跑完全部验收"的原因。

---

## 1. 这一轮真的做出来了什么

| 产出 | 状态 |
| --- | --- |
| **完整移植 patch**（`go1.26.5` 基线，90 文件，+1349/−234） | 🧪 已入库并实测干净套用 |
| **本机编出工具链**（`make.bat`，go1.26.5 windows/amd64） | 🧪 成功 |
| `go tool dist list` ⊃ `openharmony/arm64`（`CgoSupported: true`） | 🧪 成功 |
| **冒烟库** `libsmoke.so`：`PT_TLS` + `R_AARCH64_TLSDESC` | 🧪 成功 |
| **生产 `libcore.so`**：五条验收全过（含 `GoInvoke`、`DT_NEEDED` 无 `liblog.so`） | 🧪 成功 |
| 回归：宿主 `go build std` + 6 个目标交叉编译不受影响 | 🧪 成功 |
| **可复现验收脚本** `scripts/verify-ohos-port.ps1` | 🧪 已实测跑通 |
| CLEAN-57 子集（上一轮） | 🧪 保留在 patch 内 |

**意义**：这条"造工具链"的路**已经不是未知**了 —— 从上游 tag 到 `.so` 是一条
**已跑通、可复现、带脚本**的命令链。

---

## 2. 交付物与用法

### 2.1 仓库里的正式副本（**权威来源**）

```text
tools/ohos-port/our-ohos-port-on-go1.26.5.patch    （102,735 B，90 文件，+1349/−234）
tools/ohos-port/CLEAN-57-on-go1.26.5.patch         （48,503 B，上一轮的 CLEAN-57 子集，已被上面那份包含）
tools/ohos-port/reloctype-stringer/                （重生成 reloctype_string.go 的小工具，见 §5.4）
scripts/verify-ohos-port.ps1                       （一条命令跑完"编工具链 + 验收"，见 §2.3）
```

**它是全量补丁**：包含 CLEAN-57 的 57 个文件 + 本轮重放的 DRIFT 生产代码，
从**全新 `go1.26.5`** 一步到位。

```bash
git clone --depth 1 --branch go1.26.5 https://github.com/golang/go.git go-ourport
cd go-ourport
git apply /path/to/our-ohos-port-on-go1.26.5.patch
cd src && GOROOT_BOOTSTRAP=<go1.26.x 官方工具链> ./make.bash
```

🧪 **已实测**：在**全新 `go1.26.5` worktree** 上 `git apply --check` 通过、`git apply` 干净落地 90 个文件、
`make.bat` 编出 go1.26.5 工具链、`tool dist list` 出 `openharmony/arm64`、冒烟库拿到 `PT_TLS` + `R_AARCH64_TLSDESC`。

### 2.2 本机工作区（可复现，但 `%TEMP%` 有被清理风险）

| 项 | 值 |
| --- | --- |
| 位置 | `%TEMP%\ohos-go-port\golang-go`（分支 `try-port`） |
| 基线 tag | `go1.26.5` = `c19862e5`；`sig-go1.24` = `302a5306`；`up-go1.24.5` = `9d828e80` |
| 上一轮 commit | `428ecea4`（CLEAN-57，工作区基线） |

### 2.3 一条命令复现全部验收

```powershell
# 需要一个无空格的 NDK 路径：cmd /c mklink /J C:\ohndk "<DevEco>\sdk\default\openharmony\native"
.\scripts\verify-ohos-port.ps1 -GoTree <patched-go> -BootstrapGo <go1.26.x> -Ndk C:\ohndk
```

🧪 实测输出（全新树）：5 项前置检查 + `make.bat` + `dist list` + 2 条 cgo 断言 +
6 条 ELF/TLS 断言 = **ALL CHECKS PASSED**。

---

## 3. 移植范围与分类（🧪 逐文件量出）

| 组 | 数量 | 本状态 |
| --- | --- | --- |
| **CLEAN** | **57** | 上游 go1.24→1.26 没动过 → 原样套用 ✅ |
| **DRIFT** | **73** | 上游动过 → 人工重放语义 ✅ **本轮完成** |
| SIG 分支里**与 openharmony 无关**的附带改动 | 36 | ❌ **不取**（`net/url`、`net/http/cookie`、`os/user`、runtime GC 微调等） |

> ⚠️ 上一轮把 `runtime/extern.go` 归类为 CLEAN，但它**并没有真的落进树里**
> （`IsOpenharmony` 缺失），直到第一次 `make.bat` 才暴露：
> `go/build/build.go:373: undefined: runtime.IsOpenharmony`。
> **教训：分类不等于落地，必须用编译器验收。** 本轮已补上。

**为什么"73 个"听起来吓人但实际可控**：那 73 个里绝大多数是测试
（`*_test.go`、`testdata/`、`testshared`）。真正决定"能不能编出 `.so`"的生产代码只有
**33 个文件**，本轮全部重放完毕。

---

## 4. 两个"卡住成败"的文件 —— 本轮都做完了，而且比预想更微妙

### 4.1 平台注册：让 openharmony 被认识、且 `c-shared` 被允许 ✅

go1.26 与 go1.24 的**结构不同**，所以不是"照 SIG 加几行"：

| 位置 | 1.26 的实际情况 | 本移植的做法 |
| --- | --- | --- |
| `internal/platform/zosarch.go` | 平台表是**生成**的（`go generate`），且 1.26 里 `freebsd/riscv64` 已标 Broken、`windows/arm` 已删 | 手改 `List` + `distInfo`，给 `openharmony/arm64` 标 `CgoSupported: true`；**故意不给 `FirstClass`**（三方移植不该自封一等公民） |
| `internal/platform/supported.go` | `distInfo` 查表 + `c-shared`/`c-archive`/`pie` 白名单 + `MustLinkExternal` | 四处都加；`MustLinkExternal` 对 openharmony 返回 true（musl 下 cgo 必须外部链接） |
| `cmd/dist/build.go` | `okgoos`、`clangos`、`unixOS`、`cgoEnabled`、`mustLinkExternal`、`matchtag` | 全部补 `openharmony`；`cgoEnabled["openharmony/arm64"]=true` 是 `dist list` 能列出它的**唯一**来源（`cmdlist` 直接遍历这个 map） |
| `cmd/dist/test.go` | `buildModeSupported` / `raceDetectorSupported` / `internalLink(PIE)` 的另一份副本 | 同步（注释里写明"必须与 internal/platform 保持一致"） |

🧪 验收：`go tool dist list` 出 `openharmony/arm64`，`dist list -json` 里 `CgoSupported: true`。

### 4.2 TLS 模型注入：**go1.26 里确实没有 `tlsModel`** —— 本轮的答案 ✅

**注入点 = `cmd/go/internal/work/init.go` 的 `buildModeInit()`，写在 `codegenArg` 处理块之后**：

```go
if tlsModel != "" {
    forcedAsmflags = append(forcedAsmflags, "-tls="+tlsModel, "-D=TLS_"+tlsModel)
}
```

**为什么是这里（而不是"别处"）**：

- `forcedAsmflags` 是**唯一**能到达 `cmd/asm` 的通道，而 `buildModeInit` 是**唯一**按 buildmode
  分叉的初始化函数 —— 所以"按 c-shared 决定 TLS 模型"只能落在这里；
- 位置必须在 `codegenArg` 块**之后**，否则会被 `append([]string{codegenArg}, forcedAsmflags...)`
  的前插顺序搅乱；
- `-tls=GD` 给汇编器（新增的 `cmd/asm` 顶层 flag → `obj.Link.Tls`），
  `-D=TLS_GD` 给**汇编器预处理器**（决定 `runtime/tls_arm64.h` 走哪条宏路径）。**两个都要**。

**链路（本移植新增/改动的完整一条）**：

```text
cmd/go/internal/work/init.go   c-shared + openharmony/arm64 -> tlsModel="GD"
  -> forcedAsmflags  -tls=GD -D=TLS_GD
     -> cmd/asm/internal/flags/flags.go   新增 -tls flag
     -> cmd/asm/main.go                   校验后写入 ctxt.Tls
        -> cmd/internal/obj/link.go       Link 新增 Tls 字段
           -> cmd/internal/obj/arm64/asm7.go  STLSBSS 且 Tls=="GD" -> C_TLS_GD
              -> asmout case 109          生成 ADRP;LDR;ADD;BLR + R_ARM64_TLS_GD(one reloc, size 8)
                 -> cmd/link/internal/arm64/asm.go  elfreloc1 展开成 4 条 R_AARCH64_TLSDESC_*
                    -> 动态链接器经 __tlsdesc_stub 解析
     -> 汇编器预处理 -D=TLS_GD
        -> runtime/tls_arm64.h  LOAD_TLS_G_R0 走 GD 宏（SUB/ADD $16,RSP 包裹调用）
```

### 4.3 ⚠️ 两个 go1.24→1.26 的**真实陷阱**（照搬 SIG patch 一定踩）

这两条是本轮最实际的发现，**SIG/go1.24 的 patch 原样套会坏事**：

| # | 陷阱 | 🧪 实测症状 | 本移植的解法 |
| --- | --- | --- | --- |
| 1 | **opcode 号 108 在 1.26 已被 `ABTI` 占用** | SIG 的 `{AMOVD,C_TLS_GD,...,108,16,...}` 会**覆盖 `bti` 指令** | 改用 **109**（先扫 `optab` 与 `case N:` 全表取空号） |
| 2 | **reloc record 的 `Siz` 上限是 8** | `runtime.load_g: bad reloc size 0x10 for runtime.tls_g`（`cmd/link/internal/ld/data.go:285` 的通用读取只认 1/2/4/8） | `optab` 的 `size_` 保持 **16**（4 条指令的 PC 步进），但 `obj.Reloc.Siz` 用 **8**（只覆盖会被读回的 ADRP;LDR；ADD 与 BLR 由 `elfreloc1` 按偏移就地重定位，不需要读回） |

> 陷阱 2 是排查最久的一处：报错像"工具链坏了"，实际是"reloc 元数据粒度写错了"。

### 4.4 `runtime/tls_arm64.h`：一个被顺手修掉的**潜在断裂**

SIG 把线程指针宏从 `MRS_TPIDR_R0` 改名成 `MRS_TPIDR_R27`（GD 模型下 R0 要留给
`__tlsdesc_stub` 返回的偏移），但 `runtime/race_arm64.s` **仍在用旧名**（SIG 漏改）。
虽然 race detector 不为 openharmony 构建，本移植仍补了一行兼容定义，避免将来一开 `-race` 就炸。

---

## 5. 复现这一轮（任何人可重跑）

### 5.1 最短路径（推荐）

```bash
# 1) 全新上游树
git clone --depth 1 --branch go1.26.5 https://github.com/golang/go.git go-ourport
cd go-ourport

# 2) 套我们的全量 patch
git apply /path/to/HarmonyBridge/tools/ohos-port/our-ohos-port-on-go1.26.5.patch

# 3) 编工具链
cd src && GOROOT_BOOTSTRAP=<官方 go1.26.x> ./make.bash
cd .. && ./bin/go tool dist list | grep openharmony      # 期望 openharmony/arm64
```

Windows 侧等价物是一条命令：

```powershell
.\scripts\verify-ohos-port.ps1 -GoTree <patched-go> -BootstrapGo <go1.26.x> -Ndk C:\ohndk
```

### 5.2 想自己量出"哪些文件漂了"（可选，用于将来 rebase 到 go1.27）

```bash
git remote add sig https://gitcode.com/openharmony-sig/ohos_golang_go.git
git fetch --depth 1 origin refs/tags/go1.24.5:refs/tags/up-go1.24.5
git fetch --depth 1 sig release-branch.go1.24
git tag -f sig-go1.24 FETCH_HEAD
# 对 SIG 移植里的每个文件，看上游 go1.24.5→go1.26.5 有没有动过它：
#   没动过 = CLEAN（可原样套）；动过 = DRIFT（需人工重放语义）
git diff --name-only up-go1.24.5 go1.26.5 -- <每个候选文件>
```

### 5.3 交付物已经包含什么

`our-ohos-port-on-go1.26.5.patch` = CLEAN-57 的 57 个文件 **+** 本轮重放的 DRIFT 生产代码
= 90 个文件、+1349/−234，从**全新 `go1.26.5`** 一步到位。

### 🧪 上一轮踩过、本轮仍然有效的坑

1. **`--filter=blob:none` 会挡死 `--3way`**：报
   `repository lacks the necessary blob to perform 3-way merge`。
2. **不要用 `git apply --check` 判断"能不能套"**：它不做三方合并，对上下文漂移**过于严格**
   （实测 130 个文件里 117 个"假失败"）。判断可行性要用"上游这两版之间有没有动过这个文件"的分类。
3. **PowerShell 写 patch 文件会坏**：`Set-Content -Encoding UTF8` 会加 BOM → `git apply` 直接失败。
   生成 patch 一律用 **`cmd /c "git ... > file"`**（本轮的 `our-ohos-port-on-go1.26.5.patch` 就是这么生成的，🧪 首 4 字节 `diff` 无 BOM）。

### 🧪 本轮新踩的三个坑（比上一轮更贵）

4. **`Classification ≠ applied`** —— `runtime/extern.go` 被归入 CLEAN，**实际没落进树**。
   第一次 `make.bat` 才暴露 `undefined: runtime.IsOpenharmony`。
   👉 **分类是纸面工作，只有编译器算数。**
5. **go build cache 会跨 GOROOT 树复用 runtime 目标文件**。
   改完汇编器后，在**全新树**里构建仍报 `bad reloc size 0x10`，而同一棵树 + 全新 `GOCACHE` 立刻通过。
   👉 验收脚本因此**默认隔离 cache**（`scripts/verify-ohos-port.ps1` 的 `-IsolateBuildCache`）。
   一个陈旧 cache 与"移植是坏的"**症状完全一样**，这类歧义必须在脚本层面消掉。
6. **PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会给 `go.mod` 加 BOM** →
   `go.mod:1: unexpected input character '\ufeff'`。写 Go 源文件要用
   `[System.IO.File]::WriteAllText(path, text, UTF8Encoding($false))`。

### 5.4 `reloctype_string.go` 为什么不能照抄 SIG 那份

`R_ARM64_TLS_GD` 插在 `RelocType` 常量块**中间**，会让其后**所有**常量的数值 +1。
SIG 的 `reloctype_string.go` 是按 **go1.24 的常量表**生成的，直接拿来会把名字与数值**错配**。
所以本移植**重新生成**：`tools/ohos-port/reloctype-stringer/` 是一个 ~180 行的小程序，
按 `RelocType` 的实际常量顺序重建 stringer 输出。
🧪 **自校验**：在未改动的 `reloctype.go` 上跑它，产出与仓库里那份**逐字节相同**
（103 个常量），证明生成逻辑与 stringer 一致，然后才用于 104 个常量的新版本。

---

## 6. 下一步（本轮之后）

| # | 做什么 | 在哪做 | 优先级 |
| --- | --- | --- | --- |
| 1 | **Linux 机器复核**：同一 patch 跑 `make.bash` + 验收脚本 + `go build std` / `go test` 抽样 | Linux（[`07`](07-Linux机器工作清单.md) P2/P3） | 高 |
| 2 | 补 **DRIFT 组的测试桩**（`*_stubs_openharmony_test.go` 等；不阻塞构建） | 任一侧 | 中 |
| 3 | 跑完整 `go test` 套件，把"移植还缺什么"暴露出来 | Linux | 中 |
| 4 | 决定是否补 **`rt0_openharmony_amd64.s`**（当前**明确只支持 arm64**） | 本机 | 低 |
| 5 | **真机验证**（`AGENT.md` §9） | 需设备 | 阻塞项 |
| 6 | 未决：预编译 `.so` 怎么进 CI/HAP（`HANDOFF.md` §6 第 1 条） | 待拍板 | 中 |

**"工具链做完了"的判据已经满足**（🧪 本机实测）：
`go tool dist list` 出 `openharmony/arm64` + 冒烟库与 `libcore.so` 都拿到
`PT_TLS` + `R_AARCH64_TLSDESC`。**Linux 复核属于"加固"，不是"补做"。**

---

## 7. 未证实的事（❓）—— 老实列出来

1. **真机运行**：`PT_TLS`/`TLSDESC` 只是**工具链级**证据。`.so` 在 OHOS 上能不能被
   `dlopen`、TLS 描述符能不能被 musl 正确解析、`xray-core` 能不能实际转发流量，
   **全部未验证**（无设备）。**不要声称"能编 = 能用"。**
2. **完整测试套件没跑**：只跑了 `go build std`（宿主）+ 6 个目标各编一个 hello。
   `go test` 全量、`runtime` 的 TLS 相关测试都**没跑**。
3. **musl 适配是"照参考实现重放 + 我理解了逻辑"，但没有真机反证**：
   `libmusl` 探测、`/proc/self/{cmdline,environ}` 兜底、信号 43 的豁免 ——
   后者我在代码注释里标了"未能独立复现，依据是参考实现"。
4. **`exec.go`/`gccgo.go`/`bootstrap.bash` 等只服务 gccgo 的改动**：只为完整性重放，
   **从未被执行过**（我们不用 gccgo 编 OHOS）。
5. **amd64**：**明确不支持**（只做了 arm64；SIG 的 `rt0_openharmony_amd64.s` 不在所选路径里）。
6. **Linux 机器尚未复核**：本轮的构建与验收全部在 **Windows** 上完成。
   同一 patch 在 Linux 上应等价，但**未实测**。
