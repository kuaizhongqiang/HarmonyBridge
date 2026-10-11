# Linux 机器工作清单（P0–P4）

> **这份是给"另一台 Linux 机器"的独立清单**：每一步都能复制粘贴，都写了预期输出与失败怎么记。
> 背景与设计依据见 [`06-OHOS-Go工具链自研任务书.md`](06-OHOS-Go工具链自研任务书.md)。
>
> **分工（2026-10-11 定）**
>
> | 谁 | 干什么 |
> | --- | --- |
> | **本机（Windows）** | 移植的**开发**工作：拿上游 Go 树、写移植、生成 patch 系列 |
> | **Linux 机器** | **构建与验证**：`make.bash` 编工具链、用工具链编 `libcore.so`、跑 TLS 验收 |
>
> **为什么这么分**：移植本身是"改代码"，不需要 Linux；而"能不能编出可用产物"**只能**在 Linux 上验。
> Linux 机器不用做判断性工作，只要**如实带回构建输出**。
>
> **路线已定：1A** —— 把官方 SIG 的移植**往前搬到 go1.26**，不降 xray-core。

---

## 0. 严格边界

| 规则 | 说明 |
| --- | --- |
| ❌ **不要改本仓库的文件** | 你的产物不 commit；要改的东西由本机出 patch |
| ❌ **不要把移植代码粘贴进仓库** | 移植树独立放在 `~/opt/` 下，不进仓库 |
| ✅ **每个命令的原始输出都留着** | 失败点就是交付物；**不要润色、不要删路径** |
| ✅ **不要跳过验收** | 尤其 TLS 那两条 —— 那是整件事的成败指标 |
| ⚠️ **不要沿用那个第三方 fork** | `star4277/ohos-go` 已决策不用（见任务书 §6） |

---

## P0 · 先确认基线能编（**30 分钟，决定后面所有事**）

目的是拿到一个**已知能编**的参照，否则后面所有失败都无法归因。

```bash
# 0.1 环境
mkdir -p ~/opt && cd ~/opt

# 0.2 官方 Go 作为 bootstrap（SIG 的 go1.24 树需要一个 go1.24.5+ 来引导）
#     用官方 linux/amd64 包即可
curl -LO https://go.dev/dl/go1.26.9.linux-amd64.tar.gz
mkdir -p ~/opt/go1.26.9 && tar -C ~/opt/go1.26.9 --strip-components=1 -xzf go1.26.9.linux-amd64.tar.gz
~/opt/go1.26.9/bin/go version        # 期望: go version go1.26.9 linux/amd64

# 0.3 取 SIG 的移植树（git 可直连，已实测）
git clone --depth 1 --branch release-branch.go1.24 \
  https://gitcode.com/openharmony-sig/ohos_golang_go.git ~/opt/ohos-go-sig
cd ~/opt/ohos-go-sig && cat VERSION   # 期望: go1.24.5 / time 2025-07-02...

# 0.4 编它（这一步只证明"官方移植本身是能编的"）
cd ~/opt/ohos-go-sig/src
GOROOT_BOOTSTRAP=~/opt/go1.26.9 ./make.bash
# 期望: 结尾 "Installed Go for linux/amd64"，无 error
cd .. && ./bin/go version             # 期望: go1.24.5 linux/amd64
./bin/go tool dist list | grep openharmony
# ★ 期望看到: openharmony/arm64
```

**记录**：`make.bash` 的最后 10 行 + `tool dist list | grep openharmony` 的输出。

> ⚠️ 若 0.4 失败，**停下并如实报告** —— 基线编不动的话，我们的移植也无从谈起。

---

## P1 · 用 SIG 工具链编一次我们的内核（**拿到"已知可用"的对照读数**）

这一步是为了得到一个"**正确的参照产物**"，后面我们自己的移植要跟它对齐。

```bash
# 1.1 需要一个 OHOS NDK（若已有就跳过；见 04 任务书的 NDK 获取方式）
export OHOS_NDK_HOME=~/opt/ohos-sdk-6.1-Release/linux/native
ls "$OHOS_NDK_HOME/llvm/bin/clang"     # 必须存在

# 1.2 拿我们的代码
git clone https://github.com/kuaizhongqiang/HarmonyBridge.git ~/opt/HarmonyBridge
cd ~/opt/HarmonyBridge/entry/src/main/golang

# 1.3 先看 xray-core 对 Go 版本的要求会不会挡住 go1.24.5
#     注意 GOTOOLCHAIN=local 必须设，否则它会去下官方工具链（没有 openharmony）
export PATH=~/opt/ohos-go-sig/bin:$PATH
export GOTOOLCHAIN=local GOFLAGS=-mod=mod GOPROXY=https://goproxy.cn,direct
go version                              # 期望: go1.24.5 linux/amd64
GOOS=openharmony GOARCH=arm64 CGO_ENABLED=0 go build ./... 2>&1 | head -40
```

**把这段输出原样贴回来。** 它会告诉我们：xray-core 是被**版本声明**挡住（只报 `requires go >= 1.26`），
还是**真的用了 go1.26 的语法/标准库**（报 `syntax error` / `undefined:`）。

> 💡 这一步的结论本来会决定"1A 还是 1B"。**路线已定为 1A**，所以这一步现在的作用变成：
> **记录 go1.24.5 挡不住/挡得住什么**，作为我们移植到 go1.26 的旁证。

```bash
# 1.4 用 SIG 工具链 + NDK 编一次 libcore.so
export CC=$OHOS_NDK_HOME/llvm/bin/clang
export AR=$OHOS_NDK_HOME/llvm/bin/llvm-ar
export CGO_ENABLED=1 GOOS=openharmony GOARCH=arm64
export CGO_CFLAGS="-g -O2 $($OHOS_NDK_HOME/llvm/bin/llvm-config --cflags) --target=aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/sysroot"
export CGO_LDFLAGS="--target=aarch64-linux-ohos -fuse-ld=lld -lohcommonevent -lhilog_ndk.z -ltime_service_ndk"
go build -tags "fts5 timetzdata" -ldflags "-s -w" -buildmode=c-shared -o libcore-sig.so . 2>&1 | tail -40
ls -la libcore-sig.so
```

**不管成功失败，把最后 40 行贴回来。**

```bash
# 1.5 验收（★ 这是最重要的两条）
B=$OHOS_NDK_HOME/llvm/bin
$B/llvm-readelf -h libcore-sig.so | grep -E 'Class|Type|Machine'
$B/llvm-readelf -l libcore-sig.so | grep -i tls          # ★ 期望: 有 TLS 段
$B/llvm-readelf -r libcore-sig.so | grep -i tls          # ★ 期望: R_AARCH64_TLSDESC
$B/llvm-nm -D --defined-only libcore-sig.so | grep -E 'GoInvoke|GoFreeCString'
$B/llvm-readelf -d libcore-sig.so | grep NEEDED          # ★ 不应出现 liblog.so
```

**这五条的输出就是 P1 的交付物。**

---

## P2 · 编"我们自己的移植"（等本机出 patch 后再做）

本机会把一个 **patch 系列**（基于上游 `go1.26.5` + 我们自己的移植）交给你。

```bash
# 2.1 上游树
git clone --filter=blob:none --branch go1.26.5 --single-branch \
  https://github.com/golang/go.git ~/opt/go-ourport
cd ~/opt/go-ourport && git checkout go1.26.5

# 2.2 套我们的 patch（文件名以实际交付为准）
git apply --3way /path/to/our-ohos-port.patch
# 若有冲突：不要自己"猜着修" —— 把冲突文件列表与 git diff 原文贴回来，本机处理

# 2.3 编
cd src && GOROOT_BOOTSTRAP=~/opt/go1.26.9 ./make.bash
cd .. && ./bin/go version                      # 期望: go1.26.x linux/amd64
./bin/go tool dist list | grep openharmony     # ★ 期望: openharmony/arm64
```

```bash
# 2.4 冒烟测试：先证明"工具链本身对"，再碰 33 MB 的内核
mkdir -p ~/opt/smoke && cd ~/opt/smoke
cat > main.go <<'EOF'
package main

import "C"

import "fmt"

//export Hello
func Hello() *C.char { return C.CString("hi " + fmt.Sprint(42)) }

func main() {}
EOF
$B/clang --version >/dev/null   # B 见 P1
GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1 CC=$B/clang \
  ~/opt/go-ourport/bin/go build -buildmode=c-shared -o libsmoke.so .
$B/llvm-readelf -r libsmoke.so | grep -i tls    # ★ 期望: R_AARCH64_TLSDESC
$B/llvm-readelf -l libsmoke.so | grep -i tls    # ★ 期望: 有 TLS 段
```

> ⚠️ **如果 10 行的冒烟库都拿不到 `TLSDESC`，就别去查 libcore.so** —— 先修工具链。

```bash
# 2.5 用我们的工具链编 libcore.so，跑与 P1 完全相同的五条验收
cd ~/opt/HarmonyBridge/entry/src/main/golang
export PATH=~/opt/go-ourport/bin:$PATH
# ...（与 1.4 相同的 env）+ 输出 libcore-ours.so
```

**把 P1 与 P2 的验收输出并排放回来** —— 差异逐条解释，这是最有价值的交付。

---

## P3 · 跑一次工具链自检（证明不是"只能编我们这一个项目"）

```bash
cd ~/opt/go-ourport/src
# 只跑最小集合，不求全绿；目的是暴露"移植哪里还漏了"
../bin/go test -count=1 -run 'TestTLS|TestG' runtime 2>&1 | tail -30
../bin/go build std 2>&1 | tail -20
```

**报告里写清**：哪些包编不过、报什么错。**这些错就是移植还缺什么**。

---

## P4 · 若还有余力：真机（**需要设备，不算本次 P0**）

拿到 OHOS arm64 真机后，按 [`AGENT.md`](../AGENT.md) §9 的 6 步走。
**这一步不属于本清单**，列在这里只是让你知道后面还有什么。

---

## 每步都要带回的"三件套"

1. **命令**（你实际敲的那条）
2. **原始输出**（不润色；错误信息尤其要完整路径与行号）
3. **你的判断**（✅ 通过 / ❌ 失败 / ❓ 不确定，以及为什么）

## 报告统一模板

```markdown
# Linux 构建报告 — <日期> — <发行版/内核>

## 环境
- 宿主：<uname -a>
- bootstrap Go：<go version 输出>
- SIG 基线：<commit sha>，VERSION=<>
- NDK：<路径>，clang <版本>

## P0 基线能编
- make.bash 结尾：<原样>
- go tool dist list | grep openharmony：<原样>

## P1 · SIG 工具链编 libcore
- xray-core 在 go1.24.5 下的 go build ./... 输出：<原样>
- libcore-sig.so 编出？（是/否）+ 最后 40 行：<原样>
- 五条验收输出：<原样>

## P2 · 我们的移植
- patch 应用结果：<干净 / 冲突文件列表>
- make.bash：<结尾原样>
- 冒烟库 TLS：<原样>
- libcore-ours.so 五条验收：<原样>
- **与 P1 的差异**：<逐条解释>

## P3 · 工具链自检
- 编不过的包与错误：<原样>

## 我不确定的事（❓）
## 我确定没做的事
```

---

## 与本机（开发侧）的接口

| 本机交给你 | 你交给本机 |
| --- | --- |
| `our-ohos-port.patch`（基于上游 go1.26.5） | 每个 P 的**原始输出** |
| 需要时的修订 patch | 冲突文件列表 + `git diff` 原文 |
| 报告模板与判读标准 | 最终报告（按上面模板） |

**不要自己决定"移植怎么做"**，也不要在冲突时猜着改 —— 那属于开发侧。
你只要**如实带回构建事实**，判读与修正由本机完成。
