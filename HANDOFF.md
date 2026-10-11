# 交接文档（HANDOFF）

> **给新会话看的第一份文件。** 读完这份 + 下面三份文档，就能无缝继续，不需要任何前序上下文。
>
> 交接时间：2026-10-11 ｜ 仓库：`D:\Harmony\Project\Bridge`（HarmonyBridge）
> 上一轮会话的产出已全部 **commit + push**，`main` 干净、CI 绿。

---

## 1. 一句话：项目在哪、你该干什么

HarmonyBridge 是 **v2rayN 的鸿蒙原生版**（ArkTS 前端 + Go 内核 + tun2socks 数据面）。

**当前最重要的任务**：**自己做一个能编 OHOS 原生库的 Go 工具链**（路线 1A：把官方
OpenHarmony SIG 的 Go 移植**往前搬到 go1.26**）。这是整个项目唯一"不需要真机就能推进"的硬阻塞。

**你要做的下一件事**（不需要真机、不需要 Linux）：

1. → 读 [`08-OHOS移植执行笔记.md`](docs/08-OHOS移植执行笔记.md) §4，**手改两个文件**：
   - `src/internal/platform/supported.go`：把 `openharmony/arm64` 加进 `c-shared` 白名单（连同平台表）
   - `src/cmd/go/internal/work/init.go`：**go1.26 里没有 `tlsModel` 变量**（🧪 0 次出现）——
     要去 1.26 源码里找出"给汇编器注入 `-tls=GD`"的**正确位置**并让 openharmony 生效
2. → 按 [`08`](docs/08-OHOS移植执行笔记.md) §3 的清单，把 **73 个 DRIFT 文件**里的**生产代码**逐个重放
3. → 做完后，把工具链交给 Linux 机器验证（[`07-Linux机器工作清单.md`](docs/07-Linux机器工作清单.md) P2）

---

## 2. 三份必读文档（按顺序）

| 文档 | 看什么 |
| --- | --- |
| [`06-OHOS-Go工具链自研任务书.md`](docs/06-OHOS-Go工具链自研任务书.md) | **为什么这么做**：上游无 openharmony、官方 SIG 在哪、移植清单、验收标准、边界 |
| [`08-OHOS移植执行笔记.md`](docs/08-OHOS移植执行笔记.md) | **已经做到哪**：CLEAN-57 已实测可用、73 个待重放、两个卡成败的文件、踩过的坑 |
| [`07-Linux机器工作清单.md`](docs/07-Linux机器工作清单.md) | **Linux 机器那份**（P0–P4，给用户去执行的，不是你做） |

其他背景（按需）：[`AGENT.md`](AGENT.md)（作业手册）、[`TODO.md`](TODO.md) §0.2（决策记录）、
[`05-Linux构建执行报告-20261011.md`](docs/05-Linux构建执行报告-20261011.md)（A/B 两条路线的 TLS 实测对照）。

---

## 3. 已完成（**不要重做**）

| 项 | 状态 |
| --- | --- |
| tag `v0.1.0` + GitHub Release（未签名 HAP + SHA256SUMS） | ✅ 已上线，下载校验一致 |
| CI + 发布流水线（tag → 门禁 → 自托管构建 → 发布） | ✅ 已跑通，self-hosted runner 已注册 |
| Go 侧收敛到 IPC 契约 §5（`fd` reserved、`socksPort`/`httpPort`、`RuntimeInfo`、`SpeedTest`、`latencyMs`） | ✅ 完成，16 个新单测 |
| ArkTS 侧编译修复 + 两个真 bug | ✅ 完成，`assembleHap` 绿 |
| 9 处跨文档矛盾 | ✅ 全改 |
| 两个 `.so`（`libcore.so` + `libhevsocks5tun.so`） | ✅ 已交付在 `harmonybridge-so/`，Lead 已独立复验（TLS = `R_AARCH64_TLSDESC`） |
| **OHOS Go 移植：CLEAN-57 子集** | ✅ **patch 已实测干净套到 go1.26.5**，入库在 [`tools/ohos-port/`](tools/ohos-port/) |
| **OHOS Go 移植：73 个 DRIFT 文件** | ❌ **未做 —— 这就是你的活** |

---

## 4. 关键决策（**已定，不要推翻**）

1. **不用 `star4277/ohos-go` 作为生产工具链**（4 star 个人仓）。但**可以只读它的 diff** 搞清"要改什么"。
2. **基线用官方 OpenHarmony SIG 的移植**（`gitcode.com/openharmony-sig/ohos_golang_go`，BSD-3-Clause，
   移植在 `release-branch.go1.24`）。⚠️ 它的 `release-branch.go1.26` **还没有移植**。
3. **路线 1A**：把移植搬到 go1.26，**不降 xray-core**（可见范围内没有任何 xray 版本要求 ≤ go1.24）。
4. **参考实现只读、代码自己重写**（保留 BSD 版权声明；不整段粘贴不注明来源）。
5. **`-buildmode=c-shared` 必须可用**，且 TLS 必须是 **`TLSDESC`（GD 模型）** —— 这是验收的成败指标。

---

## 5. 立即可复现的环境（≈2 分钟）

```bash
mkdir -p ~/opt/ohos-port && cd ~/opt/ohos-port
git clone --depth 1 --branch go1.26.5 https://github.com/golang/go.git go-ourport
cd go-ourport
git apply /path/to/HarmonyBridge/tools/ohos-port/CLEAN-57-on-go1.26.5.patch
# 套完后：36 个文件含 openharmony，含 tls_arm64.h / rt0_openharmony_arm64.s / syslist.go 等
```

本机（Windows）上还有一个已经套好 patch 的工作区：
`%TEMP%\ohos-go-port\golang-go`（分支 `try-port`，HEAD `428ecea4`）。
⚠️ 在 `%TEMP%` 下，**可能被清理**；仓库里的 patch 才是权威来源。

### 🧪 三个已踩过的坑（别再踩）

1. **`git apply --check` 不能用来判断"能不能套"** —— 它不做三方合并，对上下文漂移**过于严格**
   （实测报 117/130 失败，全是假警报）。判断可行性要用"上游这两版有没有动过这个文件"的分类法。
2. **`--filter=blob:none` 会挡死 `--3way`**（`repository lacks the necessary blob`）。
3. **PowerShell 写 patch 会坏**（BOM + 掺入 stderr）→ 一律用 `cmd /c "git ... > file"`。
   另外 PowerShell 5.1 里「反引号 + 裸 LF」**不续行**，脚本要存 CRLF。

---

## 6. 未决 / 需要用户拍板

| # | 事项 | 说明 |
| --- | --- | --- |
| 1 | **预编译 `.so` 怎么进 CI/HAP** | CI 从 git 检出构建，而 `.so` 按纪律不入库 → 发布出的 HAP 里**没有**内核。需选：对象存储 / Release 资产回填 / runner 预置 |
| 2 | 移植是否**同时支持 amd64** | 我们只要 arm64；SIG 的 `rt0_openharmony_amd64.s` 不在我选定的路径里 |
| 3 | DRIFT 组的**测试桩**要不要全补 | 不阻塞构建，可最后做 |
| 4 | 真机采购 | 一切运行期验证的前提（`TODO.md` §1.2） |

---

## 7. 硬边界（违反即返工）

- ❌ 不要 commit 工具链产物 / `.so` / 大二进制（`.gitignore` + `verify-repo.ps1` 会拦）
- ❌ 不要把 `star4277/ohos-go` 的代码整段搬进来
- ❌ **不要照搬** SIG 分支里那 **36 个与 openharmony 无关**的文件（`archive/tar`、`database/sql`、
  `crypto/x509`、`net/http/cookie` …，+777/-167）—— 那是它附带的其他补丁
- ❌ **不要声称"能编 = 能用"** —— 真机验证仍然必需
- ✅ 只有**真的做了**才标 ✅；失败点本身是交付物（本仓库最硬的一条纪律）

---

## 8. 一句话给接手的你

**最难的部分已经跨过去了**：移植的技术核心（TLS_GD、musl 适配、rt0、平台注册）
已经实测落在 go1.26.5 的树里；剩下的是**有明确清单的工作量**（73 个文件的生产代码部分
+ 两个关键文件的手改），而不是未知。
