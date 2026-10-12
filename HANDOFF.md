# 交接文档（HANDOFF）

> **给新会话看的第一份文件。** 读完这份 + 下面三份文档，就能无缝继续，不需要任何前序上下文。
>
> 交接时间：**2026-10-12**（第三轮）｜ 仓库：`D:\Harmony\Project\Bridge`（HarmonyBridge）
>
> **本轮最重要的变化：真机验证完成 —— 整条链路在真机上跑通了。**
> "编出来"到"能用"这一跳已经完成，两个曾经的"最大未知"（内核能否在 OHOS 上跑、
> hev 能否接管 vNIC fd）**都有了肯定答案**。
>
> ⚠️ 本文下面 §1 之后的内容多为**上一轮（2026-10-11）**的交接记录，
> 其中涉及"等真机 / 工具链未完成"的表述**已过时**。当前状态以本节、
> [`README.md`](README.md) 的验证表与 [`TODO.md`](TODO.md) §0 为准。

---

## 1. 一句话：项目在哪、你该干什么

HarmonyBridge 是 **v2rayN 的鸿蒙原生版**（ArkTS 前端 + Go 内核 + tun2socks 数据面）。

**当前状态（2026-10-12）**：**真机验证已完成。** 在 HUAWEI `TYR-AL00`（nova 14 活力版 / API 24）上：

- 自动签名（AGC）→ `hdc install` → 启动：✅
- `libcore.so`（34.5 MB）`dlopen` + `GoInvoke` 成功，Xray `26.3.27` 正常运行：✅
- `libhevsocks5tun.so` 接管 OHOS 的 vNIC fd：✅（**这曾是"最大未知"之一**）
- TUN → tun2socks → `127.0.0.1:10808` → 内核出站，第三方应用可正常上网：✅

版本 **0.2.0**，已打 tag `v0.2.0`。

**你现在可以做的下一件事（按价值排序）**：

1. → **修 IPv6 泄漏**（[`TODO.md`](TODO.md) §2.1）：**不需要重编内核**，当前最实在的隐私缺陷；
2. → **补 `geoip.dat` / `geosite.dat` 并验证按需下载**（[`TODO.md`](TODO.md) §6.5）：
   没有它，"绕过大陆"是降级形态（只剩"私有网段直连 + 其余走代理"）；
3. → **把设置页接线 + 节点持久化 + 前台常驻通知**（[`TODO.md`](TODO.md) §9.5）；
4. → **根治内核 `wired` 假话**（[`TODO.md`](TODO.md) §2.6）：需在 Linux 上改 `core.go` 后重编 `.so`；
5. → **待拍板**：长期是否接受**自建 Go fork** 作为工具链（供应链决策，[`TODO.md`](TODO.md) §0.1.1）。

> ⚠️ 每次推 tag 前先手动启动 self-hosted runner（`C:\actions-runner-harmonybridge\run.cmd`），
> 否则 `publish` 会一直排队 —— 见 [`TODO.md`](TODO.md) §7.4。

---

## 2. 三份必读文档（按顺序）

| 文档 | 看什么 |
| --- | --- |
| [`08-OHOS移植执行笔记.md`](docs/08-OHOS移植执行笔记.md) | **已经做到哪 + 这一轮的全部实测结果**：交付物、TLS 注入点、两个 go1.24→1.26 陷阱、❓未证实清单 |
| [`06-OHOS-Go工具链自研任务书.md`](docs/06-OHOS-Go工具链自研任务书.md) | **为什么这么做**：上游无 openharmony、官方 SIG 在哪、移植清单、验收标准、边界 |
| [`07-Linux机器工作清单.md`](docs/07-Linux机器工作清单.md) | **Linux 机器那份**（P0–P4，给用户去执行的，不是你做） |

其他背景（按需）：[`AGENT.md`](AGENT.md)（作业手册）、[`TODO.md`](TODO.md) §0.2（决策记录）、
[`05-Linux构建执行报告-20261011.md`](docs/05-Linux构建执行报告-20261011.md)（A/B 两条路线的 TLS 实测对照）。

---

## 3. 已完成（**不要重做**）

| 项 | 状态 |
| --- | --- |
| tag `v0.1.0` + GitHub Release（未签名 HAP + SHA256SUMS） | ✅ 已上线 |
| CI + 发布流水线（tag → 门禁 → 自托管构建 → 发布） | ✅ 已跑通 |
| Go 侧收敛到 IPC 契约 §5（`fd` reserved、`socksPort`/`httpPort`、`RuntimeInfo`、`SpeedTest`、`latencyMs`） | ✅ 完成，16 个新单测 |
| ArkTS 侧编译修复 + 两个真 bug | ✅ 完成，`assembleHap` 绿 |
| 跨文档矛盾 | ✅ 全改 |
| **OHOS Go 移植：CLEAN-57 子集** | ✅ 已并入本轮的**全量 patch** |
| **OHOS Go 移植：DRIFT 组生产代码（33 文件）** | ✅ **本轮做完** |
| **工具链在 Windows 上编出来** | ✅ **本轮实测**（`make.bat` 成功） |
| **`go tool dist list` ⊃ `openharmony/arm64`**（`CgoSupported: true`） | ✅ **本轮实测** |
| **冒烟库 `libsmoke.so`：`PT_TLS` + `R_AARCH64_TLSDESC`** | ✅ **本轮实测** |
| **生产 `libcore.so`：五条验收全过**（含 `GoInvoke`/`GoFreeCString`，`DT_NEEDED` 无 `liblog.so`） | ✅ **本轮实测** |
| **可复现验收脚本** `scripts/verify-ohos-port.ps1` | ✅ **本轮实测 ALL CHECKS PASSED** |

### 本轮新增的交付物

| 文件 | 说明 |
| --- | --- |
| `tools/ohos-port/our-ohos-port-on-go1.26.5.patch` | **全量移植补丁**（102,735 B，90 文件，+1349/−234），基于上游 `go1.26.5`，**已实测从全新树干净套用** |
| `tools/ohos-port/CLEAN-57-on-go1.26.5.patch` | 上一轮的 CLEAN-57 子集（保留作历史；已被上面那份包含） |
| `tools/ohos-port/reloctype-stringer/` | 重生成 `reloctype_string.go` 的小程序（Go 模块，~180 行）。**不能照抄 SIG 那份**，理由见 [`08`](docs/08-OHOS移植执行笔记.md) §5.4 |
| `scripts/verify-ohos-port.ps1` | 一条命令：编工具链 → 查目标 → 编冒烟库 → 验 `PT_TLS`/`TLSDESC` |

---

## 4. 关键决策（**已定，不要推翻**）

1. **不用 `star4277/ohos-go` 作为生产工具链**。可以只读它的 diff。
2. **基线用官方 OpenHarmony SIG 的移植**（`gitcode.com/openharmony-sig/ohos_golang_go`，BSD-3-Clause，
   移植在 `release-branch.go1.24`）。它的 `release-branch.go1.26` **至今没有移植**。
3. **路线 1A**：移植搬到 go1.26，**不降 xray-core**。
4. **参考实现只读、代码自己重写**（保留 BSD 版权声明）。
5. **`-buildmode=c-shared` 必须可用，TLS 必须是 `TLSDESC`（GD 模型）** —— 这是验收的成败指标。
6. **明确只支持 `arm64`**（amd64 不在本次范围）。
7. **`openharmony/arm64` 不标 `FirstClass`**（三方移植不该自封一等公民）。

---

## 5. 立即可复现（≈ 一条命令 + 一次构建）

```bash
git clone --depth 1 --branch go1.26.5 https://github.com/golang/go.git go-ourport
cd go-ourport
git apply /path/to/HarmonyBridge/tools/ohos-port/our-ohos-port-on-go1.26.5.patch
cd src && GOROOT_BOOTSTRAP=<官方 go1.26.x> ./make.bash
cd .. && ./bin/go tool dist list | grep openharmony    # 期望 openharmony/arm64
```

Windows 一条命令跑完全部验收（含 TLS 检查）：

```powershell
# NDK 路径不能有空格 —— 这是硬性要求（Go 在 Windows 会在第一个空格处截断 CC）
cmd /c mklink /J C:\ohndk "D:\Harmony\DevEco Studio\sdk\default\openharmony\native"
.\scripts\verify-ohos-port.ps1 -GoTree <patched-go> -BootstrapGo <go1.26.x> -Ndk C:\ohndk
```

### 🧪 六个已踩过的坑（别再踩）

1. **`git apply --check` 不能用来判断"能不能套"** —— 不做三方合并，对上下文漂移过于严格
   （上一轮实测报 117/130 失败，全是假警报）。可行性要用"上游这两版有没有动过这个文件"分类。
2. **`--filter=blob:none` 会挡死 `--3way`**（`repository lacks the necessary blob`）。
3. **PowerShell 写 patch 会坏**（BOM + 掺入 stderr）→ 一律用 `cmd /c "git ... > file"`。
   PowerShell 5.1 里「反引号 + 裸 LF」**不续行**，脚本要存 CRLF。
4. 🔴 **"分类完了" ≠ "真的落进树里"**。`runtime/extern.go` 被归入 CLEAN 却**实际缺失**，
   直到编译器报 `undefined: runtime.IsOpenharmony` 才暴露。**只有编译器算数。**
5. 🔴 **go build cache 会跨 GOROOT 树复用 `runtime` 目标文件**。改完汇编器后，
   在**全新树**里构建仍报 `bad reloc size 0x10`；同一棵树 + 全新 `GOCACHE` 立刻通过。
   一个陈旧 cache 与"移植是坏的"**症状完全一样** → 验收脚本默认隔离 cache。
6. **`Set-Content -Encoding UTF8` 会给 `go.mod` 加 BOM** → `unexpected input character '\ufeff'`。
   写 Go 源文件用 `[System.IO.File]::WriteAllText(path, text, UTF8Encoding($false))`。

### 🔴 两个 go1.24→1.26 的移植陷阱（照搬 SIG patch 一定踩）

1. **汇编器 opcode `108` 在 1.26 已被 `ABTI` 占用** → 必须换号（本移植用 **109**）。
2. **reloc record 的 `Siz` 上限是 8**（`cmd/link/internal/ld/data.go` 的通用读取只认 1/2/4/8）→
   `optab.size_` 保持 16（4 条指令的 PC 步进），但 `obj.Reloc.Siz` 用 **8**。

细节与证据见 [`08`](docs/08-OHOS移植执行笔记.md) §4.3。

---

## 6. 未决 / 需要用户拍板

| # | 事项 | 说明 |
| --- | --- | --- |
| 1 | **预编译 `.so` 怎么进 CI/HAP** | CI 从 git 检出构建，而 `.so` 按纪律不入库 → 发布出的 HAP 里**没有**内核。需选：对象存储 / Release 资产回填 / runner 预置 |
| 2 | DRIFT 组的**测试桩**要不要全补 | 不阻塞构建，可最后做 |
| 3 | 是否补 **amd64** 支持 | 当前**明确只支持 arm64**；SIG 似乎没有 `rt0_openharmony_amd64.s` |
| 4 | ~~真机采购~~ | ✅ **已到位**：HUAWEI `TYR-AL00`（2026-10-12 完成端到端验证） |
| 5 | ~~移植是否同时支持 amd64~~ / ~~Go 版本鸿沟~~ | ✅ 已定（arm64；1A） |

---

## 7. 硬边界（违反即返工）

- ❌ 不要 commit 工具链产物 / `.so` / 大二进制（`.gitignore` + `verify-repo.ps1` 会拦）
- ❌ 不要把 `star4277/ohos-go` 的代码整段搬进来
- ❌ **不要照搬** SIG 分支里那 **36 个与 openharmony 无关**的文件（`net/url`、`net/http/cookie`、
  `os/user`、runtime GC 微调 …）—— 那是它附带的其他补丁
- ❌ **不要声称"能编 = 能用"** —— 真机验证仍然必需。`PT_TLS`/`TLSDESC` 只是**工具链级**证据
- ✅ 只有**真的做了**才标 ✅；失败点本身是交付物（本仓库最硬的一条纪律）

---

## 8. 一句话给接手的你

**最难的部分已经跨过去了，而且这次是"跑通了的难"，不是"想通了而已"。**

从上游 `go1.26.5` tag 开始，套一份 patch、编一次、跑一条脚本，
就能拿到一个**能编 OHOS arm64 原生 `c-shared` 库、且 TLS 走 TLSDESC** 的 Go 工具链；
`libcore.so` 已经用它在 Windows 上编出来了（五条验收全过）。

**剩下的是"验证与加固"**（Linux 复核、测试桩），而不是"未知"。

> ✅ **那个"不能靠代码回答的问题"已经有答案了（2026-10-12）**：**它在真机上能跑。**
> 内核在 VPN 扩展进程内 `dlopen`、`GoInvoke` 可调、Xray `26.3.27` 运行正常；
> `hev` 接管 vNIC fd；端到端可出网。见 [`README.md`](README.md) 的验证表。
