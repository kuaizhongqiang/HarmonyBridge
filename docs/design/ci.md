# CI / CD 设计

> 本文回答三个问题：**哪些检查在哪里跑、为什么在那儿跑、什么被刻意推迟了。**
> 一句话原则：**不假装产出了没产出的东西。** 在托管 runner 上做不了的事（签名 HAP、
> 实机 instrumentation 测试），就明确标记为「未实现」，而不是让流水线绿着却什么都没有。

相关文档：`docs/03-环境搭建.md`（本机环境与构建）、`AGENT.md`（阶段边界与许可红线）、
`CONTRIBUTING.md`（提交规范与本地门禁）。

---

## 1. 现状与前提（实测）

| 项目 | 实测值 | 来源 |
| --- | --- | --- |
| DevEco Studio | `26.0.0.851`（`DS-261.23567.138.36.2600851`） | `DevEco Studio/product-info.json` |
| HarmonyOS SDK | `native` `apiVersion=26`，`platformVersion=26.0.0` | `sdk/default/openharmony/native/oh-uni-package.json` |
| 工程 API 基线 | `compatibleSdkVersion=6.1.1(24)`，`targetSdkVersion=26.0.0` | `build-profile.json5` |
| NDK clang / llvm | `OHOS (dev) clang version 15.0.4` / `llvm 15.0.4` | `scripts/check-env.ps1` |
| ohpm / hvigorw | `26.0.0.630` / `6.26.8`（都在 DevEco 安装目录内，**不在 PATH**） | `scripts/check-env.ps1` |
| Node / Go / git / git-lfs | `v24.14.0` / `go1.26.4` / `2.53.0.windows.2` / `3.7.1` | `scripts/check-env.ps1` |
| JDK | JBR `OpenJDK 25.0.2`（DevEco 自带） | `scripts/check-env.ps1` |
| 签名工具 | `sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar`（存在） | `scripts/check-env.ps1` |
| 真机 / 模拟器 | **没有** | 项目现状 |

由此推出整个设计的出发点：

- **`ohpm` / `hvigorw` / `java` 都不在 PATH 上**，它们只存在于 DevEco 安装目录内。
  所以任何脚本都必须**显式探测 DevEco 安装位置**，不能假设 `hvigorw` 能直接调用。
- **没有签名材料、没有设备**，所以托管 runner 上无法产出可安装的 HAP，也无法跑
  `ohosTest`。
- **没有 `pwsh`**（本机只有 Windows PowerShell 5.1），所以 `scripts/*.ps1` 必须同时兼容
  5.1 与 7+；CI 用 `pwsh` 7（`windows-latest` 自带）。

---

## 2. 分层：哪些检查在哪里跑

| 层 | 触发点 | 跑什么 | 目的 |
| --- | --- | --- | --- |
| L0 编辑器 | 保存时 | `.editorconfig`、DevEco Code Linter | 最便宜的反馈 |
| L1 本机提交前 | `git commit` | `.githooks/pre-commit`（只查**暂存区**）、`.githooks/commit-msg` | 拦住"差点提交进去"的产物与不规范信息 |
| L2 本机完整 | 手动 / 推之前 | `scripts/check-env.ps1`、`scripts/verify-repo.ps1`（全量索引）、`node scripts/validate-json5.mjs`、`scripts/release-preflight.ps1` | 与 CI 同一套规则，提前发现问题 |
| L3 PR / push | `.github/workflows/ci.yml` → `verify.yml` | `repo-hygiene`(windows) + `manifests`(ubuntu) + `go`(ubuntu) + `conventional-pr`(ubuntu，仅 PR) | 不可绕过的自动化门禁 |
| L4 标签发布 | `.github/workflows/release.yml` | `verify`（复用 L3 的门禁）+ 版本号校验 + 生成变更日志 + **自托管构建/发布** | 一条命令出 Release |
| L5 自托管 | `[self-hosted, harmonyos, windows]` | DevEco `assembleHap` → `SHA256SUMS.txt` → `gh release create` | **待注册 runner**，见第 4 节 |

### 2.1 为什么门禁放在**可复用 workflow** 里

`repo-hygiene` / `manifests` / `go` 三项定义在 **`.github/workflows/verify.yml`**
（`on: workflow_call`），由 `ci.yml` 与 `release.yml` 共同调用。

理由很直接：**tag 不应该买到一条 push 买不到的门禁**。如果 `release.yml` 把这三步各抄一遍，
两份就会漂移 —— 于是"PR 会被拦下的东西"可以从 Release 溜出去。现在只有一份定义。

**为什么"检查"和"构建"要分开？** 因为它们的**可运行前提完全不同**。L3 只需要
`git` / `node` / `pwsh` / Go（hosted runner 都有）；而真正的 HAP 构建需要几个 GB 的
SDK 和一个 DevEco 安装。把两者塞进同一个 job 的后果是：要么整个 CI 因为没有 SDK 而常年红着，
要么为了让它绿而把构建步骤删掉——两种结果都比"明说做不了"更糟。

---

## 3. L3：`.github/workflows/ci.yml` 逐项说明

### 3.1 `repo-hygiene`（`windows-latest`，`pwsh`）

跑 `scripts/verify-repo.ps1`，检查四件事：

1. **禁止跟踪的产物**：`*.so` `*.so.*` `*.hap` `*.hsp` `*.har` `*.p12` `*.cer` `*.p7b`
   `*.keystore` `*.jks` `*.pem`、`local.properties`、任何 `build/` 下的文件。
2. **`third_party/` 只能是 submodule gitlink**：出现普通文件即失败（许可证边界，见
   `AGENT.md` 第 6 节）。
3. **`.gitmodules` 完整性**：声明的每个 `path` 必须在索引中存在，否则新克隆会静默缺东西。
4. **疑似凭据**：对**索引内容**做窄口径正则匹配（`AKIA…` / `ASIA…` / `sk-…` / `ghp_…` /
   `github_pat_…` / `xox?-…` / 私钥头 / `accessKeyId = "…"`）。

**为什么用 Windows 而不是 Ubuntu？** 因为 `scripts/verify-repo.ps1` 是**权威实现**
（本项目在 Windows 上开发，作者本机只有 PowerShell 5.1，没有 `pwsh`），
`windows-latest` 自带 `pwsh` 7。`scripts/verify-repo.sh` 是给 Linux/macOS 贡献者的等价实现，
由本地 `pre-commit` 走它（Git for Windows 用自带 bash 执行钩子）。**同一套规则只在一个
地方定义**：`scripts/forbidden-patterns.txt`，两个实现都读它，所以不可能漂移。

**规则的具体口径**（避免误解）：

- `git grep` 读的是**索引**（`--cached`），也就是"这次提交会写进去的内容"，不是工作区。
- 二进制文件被 `-I` 跳过；超过 300 字符的行不参与凭据匹配（压缩/生成文件只会产生误报）。
- 凭据检查**不是**通用熵扫描器。真正的密钥扫描应交给专门工具，见第 6 节。

### 3.2 `conventional-pr`（`ubuntu-latest`，仅 `pull_request`）

用 `amannn/action-semantic-pull-request@v6` 校验 **PR 标题**符合 Conventional Commits。
与本地 `.githooks/commit-msg` 同一套 type 列表（`feat|fix|docs|style|refactor|perf|test|
build|ci|chore|revert`），并开启 `validateSingleCommit`——因为仓库用 **Squash and merge**，
单个提交的标题很容易被当成最终提交信息误合进去。

- 权限只要 `contents: read` + `pull-requests: read`（`AGENTS` 里对该 action 的常见建议是
  `pull-requests: write`，那是为了写评论；本项目不需要写评论，所以按最小权限给）。
- 只在 `pull_request` 上跑：push 到分支时没有 PR 标题可查。

### 3.3 `manifests`（`ubuntu-latest`，纯 Node）

跑 `node scripts/validate-json5.mjs`：

- **语法**：手写 JSON5 解析器（注释、尾逗号、单引号、无引号键、`0x`、`+` 号），
  失败时给出 `文件:行:列`。零依赖、零网络、无 `npm install`。
- **跨文件一致性**（这是它比"能不能解析"更有价值的部分）：
  - 每个 product 有 `name`，且声明了 `compatibleSdkVersion` 或 `targetSdkVersion`；
  - `modules[].srcPath` 指向的目录下确实有 `build-profile.json5`；
  - `modules[].targets[].applyToProducts` 引用的 product 真实存在；
  - `AppScope/app.json5` 有非空 `bundleName` / `versionName`；
  - 每个 `module.json5` 落在某个已声明模块的 `srcPath` 之内。

**为什么不用现成的 JSON5 库？** 那需要 `package.json` + `npm install` + 锁文件，
也就是给一个目前还没有 Node 依赖的仓库引入供应链面。手写解析器的代价是"不是规范完备"，
这一点是**已知缺口**，见第 6 节。

### 3.4 `go`（`ubuntu-latest`）—— 两种配置，缺一不可

这是**最容易做错、也最值得讲清**的一项。Go 侧的构建有两条互不覆盖的路径：

| 配置 | 编到什么 | 覆盖了什么 | 漏掉了什么 |
| --- | --- | --- | --- |
| `CGO_ENABLED=0` | 纯 Go 半边 | 服务层（`ipc`/`service/*`）能编、能测 | **`main.go` / `main_test.go` 整体被构建约束排除** |
| `CGO_ENABLED=1` | 含 cgo 半边 | `main.go` 会被真正类型检查；`main_test.go` 会真正运行 | 仍需 OHOS NDK 才能交叉编 `libcore.so` |

**为什么必须两个都跑**：`main.go` 与 `main_test.go` 都带 `//go:build cgo`。
在 `CGO_ENABLED=0` 下它们**根本不在编译集里**，所以那里的编译错误是**完全隐形**的。

> 🧪 **这不是假想**：仓库里真的有一个 `main.go` 的编译错误
> （`params := "{}"` 被粘进了上一行的注释里）这样混进了 `main`，
> 于是**服务目录黄金列表的唯一守卫 `main_test.go` 从来没跑过**，
> 一个"漏了一项"的错误因此长期存在。见 `TODO.md` §4.1。

因此 `CGO_ENABLED=1` 的步骤里有一条**额外的守卫**：

```bash
go list -f '  CgoFiles={{.CgoFiles}} TestGoFiles={{.TestGoFiles}}' .
go test . -run '^$' -count=1     # 编译测试二进制、不跑用例并
```

`go test -run '^$'` 是这个守卫的实质：它**编译** `main.go` 与 `main_test.go`，
因此 `main.go` 编不过会立刻红。没有它，一旦 runner 上没有 `cc`，cgo 会被静默关掉，
而后续 `go build ./...` / `go test ./...` 会**"假装通过"** —— 那正是原缺陷得以发生的原因。
另有一条 `go env CGO_ENABLED` 断言与一条 `cc --version`，让"cgo 到底有没有生效"成为**显式事实**。

> 🧪 **这条守卫自己也是要验证的代码，而且第一版是坏的**（写它时本机还跑不了 Go）：
> 1. 最初写成 `go list -f '{{join .GoFiles "\n"}}'` —— Go 的 `text/template`
>    **不支持字符串里的 `\n` 转义**，这条命令直接报
>    `template: main:1: unexpected "\\" in operand`，**守卫会在第一次运行就炸**；
> 2. 而且 `.GoFiles` 对这个包**是空的**：带 `//go:build cgo` 的文件归 `.CgoFiles`，
>    `_test.go` 归 `.TestGoFiles`。任何只看 `.GoFiles` 的守卫都会永远失败。
>
> 两个坑都是**真的跑了一遍**才发现的。教训记在 `TODO.md` §4.3。

`release.yml` 调用 `verify.yml` 时传 `cgo: false`（见第 5 节）：cgo 只在**分支 CI**上
是硬门禁；一条 tag 是否发布，由仓库卫生、配置合法性与版本一致性决定。
**这不代表 cgo 失败可以接受** —— 它代表"main 必须绿"是 push 的责任，不是发布的责任。

### 3.4.1 本机也能跑 cgo（2026-10-11 补）

本机 `C:\msys64\mingw64\bin` 有 MinGW gcc 16.1.0。设好之后
`CGO_ENABLED=1 go test ./... -count=1` **在本机全绿**，`main_test.go` 12/12 PASS ——
这是它历史上第一次被执行。所以"cgo 只能靠 CI 验证"这句话**在本机是不成立的**：

```powershell
$env:PATH = "C:\msys64\mingw64\bin;$env:PATH"
$env:CGO_ENABLED = '1'
$env:CC = 'C:\msys64\mingw64\bin\gcc.exe'
cd entry\src\main\golang
go test ./... -count=1
```

⚠️ **注意陷阱**：不把 `C:\msys64\mingw64\bin` 放进 `PATH` 时，直接调用那个 `gcc.exe`
会**静默失败**（无输出、exit 1），很容易被误判成"这台机器没有 C 编译器"。
首次探测时正是这样错过它的。

⚠️ 本机 `bash` 是 **WSL 的桩**（`C:\Windows\system32\bash.exe`），不是 Git for Windows 的 bash。
所以 `shell: bash` 的步骤与 `scripts/*.sh` **在本机无法复现**，只能靠等价逻辑核对。

### 3.5 `build-hap`：**刻意不可运行**

```yaml
if: false
runs-on: [self-hosted, harmonyos, windows]
```

- GitHub Actions **不支持 job 级别的 `workflow_dispatch`**，所以这个 job 只能是
  workflow 级的 `workflow_dispatch`（会跑本文件里所有 job），再靠 `if: false` 关掉。
- `runs-on: [self-hosted, harmonyos, windows]` 是**默认不存在的 runner 标签**。
  即使放开 `if: false`，在没有对应自托管 runner 的环境里，这个 job 会一直 pending
  而不是"悄悄成功"。
- job 内的第一步是一条 `exit 1`，输出明确的 `::error::`：**这是有意为之**——
  宁可红得震耳欲聋，也不要绿得毫无意义。
- **HAP 构建已经不在这个 job 里了**：它搬到了 `release.yml` 的 `publish` job。
  这里保持禁用，是因为"每次 push 都编 HAP"不是本项目的需要，而"打 tag 出包"是。
  本 job 保留为**手动入口的骨架**（放开 `if` 即可复用，命令见同文件注释）。

---

## 4. L5：自托管 HarmonyOS runner 需要什么

要真正在 CI 里产出 HAP，需要一台（或一组）**自托管 runner**，具备：

### 4.1 工具链

| 需求 | 具体内容 | 备注 |
| --- | --- | --- |
| DevEco Studio | 26.0 及兼容版本，安装目录需可被 `scripts/check-env.ps1` 探测到 | 建议设 `DEVECO_HOME`，比注册表探测可靠 |
| HarmonyOS SDK | `apiVersion 26`（与工程 `compatibleSdkVersion` 对齐，见 `docs/03-环境搭建.md` 3.1） | 许可受限，数 GB |
| `ohpm` | `<DevEco>/tools/ohpm/bin/ohpm(.bat)`，需要**能联网**到 OHPM 仓库 | 首次需要，之后可预热缓存 |
| `hvigorw` | `<DevEco>/tools/hvigor/bin/hvigorw(.bat)` | 也可用工程内生成的 wrapper |
| JDK / JBR | DevEco 自带 JBR 即可（实测 `OpenJDK 25.0.2`） | 用于 `hap-sign-tool.jar` |
| NDK | `<SDK>/native/llvm/bin/clang`、`llvm-config`、`<SDK>/native/build-tools/cmake` | 原生核心交叉编译；Go 侧见 `docs/design/core.md` |
| Go | 用于编译 `libcore.so`（`GOOS=linux` + `-D__MUSL__`，见 `docs/design/core.md` 6.1/6.2） | **目前没有 `GOOS=ohos`** |
| `git-lfs` | `*.so` / `*.p12` 等 LFS 过滤器 | 本仓库不存 LFS 对象，但 `git lfs install` 仍需 |

### 4.2 签名材料（**本流水线不需要，且绝不入库**）

⚠️ **本项目当前的发布策略是"未签名 HAP + 自行签名指引"**（决策理由见第 5 节），
所以**注册 runner 时不需要准备下面任何东西**。本节保留，是为了将来若要改成
"流水线内签名"时知道需要什么：

| 需求 | 内容 |
| --- | --- |
| 密钥库 | `.p12`（含私钥）+ 别名 + 密钥口令 + 库口令 |
| 证书 | `.cer`（调试或发布证书） |
| Profile | `.p7b` 授权文件 |
| 注入方式 | runner 上的环境变量 / 受限目录 / GitHub Encrypted Secrets（**不要**写进 `build-profile.json5` 并提交；`.gitignore` 已忽略 `/signature/`、`*.p12`、`*.cer`、`*.p7b`） |
| 工具 | `<SDK>/toolchains/lib/hap-sign-tool.jar`（已确认存在） |

### 4.3 设备（仅 instrumentation 测试需要）

`entry/src/ohosTest/**` 的测试需要真机或模拟器。真机要通过 `hdc` 连接，
并保持**解锁 + 已授权调试**状态；VPN 相关的用例还需要用户确认系统 VPN 授权弹窗，
因此**不能无人值守地跑 VPN 链路测试**（见 `docs/design/core.md` 第 7 节）。

### 4.4 runner 侧的接线方式

1. 在机器上注册 self-hosted runner，**打上 `harmonyos` 与 `windows` 标签**
   （与 `.github/workflows/release.yml` 里的 `runs-on` 对应）。
   `scripts/release-preflight.ps1` 会逐项检查下面这些条件，缺什么直接说清。
2. 设 `DEVECO_HOME`（其余 `DEVECO_SDK_HOME` / `JAVA_HOME` 可由它推导，
   preflight 与 `release-local.ps1` 都会兜底）。
3. **不需要签名材料**（第 4.2 节）。
4. **什么都不用改 workflow**：`release.yml` 的 `publish` job 就是完整实现。
   注册好 runner 之后，`git push` 一个 `v*` tag 即触发。
5. 先在一个分支/预发布 tag（如 `v0.1.0-rc.1`）上验证，再打正式 tag。

**没有 runner 时的替代路径**（本机就是 runner）：

```powershell
pwsh -File scripts/release-local.ps1 -Tag v0.1.0              # 构建 + 生成产物，不发布
pwsh -File scripts/release-local.ps1 -Tag v0.1.0 -Publish     # 建 draft Release
```

它与 CI 路径读**同一份** `scripts/release-metadata.json`，所以产物名与版本规则不会漂移。

> **不要**把自托管 runner 直接暴露给来自 fork 的 PR：那等于让任意代码在那台机器上执行。
> 本项目用 `pull_request`（不是 `pull_request_target`）+ 托管 runner 跑 L3 全部检查，
> 自托管 runner **只承接 tag 触发的发布** —— 就是为了避开这个问题。

---

## 5. L4：发布流程（`.github/workflows/release.yml`）

### 5.1 流程

```
push tag v*
  ├─ verify     (托管)  复用 verify.yml 的门禁：仓库卫生 + 配置合法性（cgo 不参与，见 3.4）
  ├─ changelog  (托管)  tag ↔ AppScope/app.json5 versionName 一致性；生成 RELEASE_NOTES.md
  └─ publish    (自托管) release-preflight → ohpm install → hvigorw clean + assembleHap
                        → 改名为 harmonybridge-<version>-unsigned.hap → SHA256SUMS.txt
                        → gh release create（带 notes 与两个产物）
```

| 步骤 | 说明 |
| --- | --- |
| 触发 | `push` tag `v*`；或 `workflow_dispatch`（`dry_run` 默认 true，只校验+生成 notes） |
| 版本校验 | 唯一实现是 `scripts/changelog.mjs --validate-only`，CI 与本地脚本**共用**它（不再各写一段 node 内联脚本） |
| 变更日志 | `scripts/changelog.mjs` 读 **commit log**，按 Conventional Commit 类型分组 |
| preflight | `scripts/release-preflight.ps1 -RequireDeveco`，逐项检查 DevEco / hvigorw / ohpm / SDK / Java / metadata |
| 构建 | `clean` **之后** `assembleHap`（release 模式）—— 增量任务可能只报 `UP-TO-DATE`，那证明不了任何事 |
| 产物 | `harmonybridge-<version>-unsigned.hap` + `SHA256SUMS.txt`（`sha256sum -c` 可直接用） |
| 权限 | 默认 `contents: read`；只有 `publish` job 提权到 `contents: write` |

### 5.2 为什么**必须自己**生成变更日志

`.github/release.yml` 配置的是 GitHub 自带的生成器，而它**按 PR 标签分类、且只能列 PR**。
本仓库是**直接提交到 `main`**、没有一变更一 PR，所以用它会得到一个**几乎空白**的
变更日志。`scripts/changelog.mjs` 改读 commit log —— 那是这里唯一真实存在的记录。

`.github/release.yml` 仍然保留（手工在 GitHub 上点"Generate release notes"时会用到），
文件头已注明它**不再是本流水线的产出**。

### 5.3 为什么产物是**未签名** HAP（决定，不是遗漏）

三条理由，任何一条都足够：

1. **既定决策**：本项目"仅自用、不对外发行"（`AGENT.md` §7），没有签名分发的需要；
2. **纪律**：`.p12` / `.cer` / `.p7b` 及口令**不许入库**（`AGENT.md` §1），
   而把 6 个 secret 接进流水线只为了让自用产物"看起来正式"，收益不抵复杂度；
3. **诚实**：与其造一个"已签名"的假象，不如发未签名包并**在 release notes 里
   写清怎么自行签名**。`RELEASE_NOTES.md` 末尾由
   `scripts/release-notes-footer.md` 追加这段指引（含"自签名后 SHA-256 会变，
   `SHA256SUMS.txt` 校验的是下载到的**未签名**包本身"这种容易踩的坑）。

`release.yml` 里有一条**反向断言**：如果产出的是已签名 HAP，直接失败 ——
因为那意味着签名被静默启用、与文档策略不符。

### 5.4 为什么 tag 打完之后**必须**红，而不是"跳过"

`publish` job 跑在不存在的 runner 标签上。没有 runner 时，job 会一直 **pending**
（`docs/00-技术路线可行性.md` 里的判断：宁可红得震耳欲聋，也不要绿得毫无意义）。

**为什么不让它"优雅跳过"？** 因为跳过会让 tag 打完之后看起来发布成功了，
而 Releases 页面空空如也 —— 这种**静默失败**比一次明确的红色 job 昂贵得多。

### 5.5 版本号约定

- tag 形式：`v<major>.<minor>.<patch>`，预发布用后缀（如 `v0.1.0-rc.1`，会被自动标 `--prerelease`）。
- **tag 必须与 `AppScope/app.json5` 的 `versionName` 完全相等**（`changelog.mjs` 会强制检查）。
- `versionCode` 需单调递增 —— 这条**只有人工保证**，脚本只提醒不强制（见
  `scripts/release-metadata.json` 的 `versionCodeRule`）。
- 打 tag 前请在本地跑通 `docs/03-环境搭建.md` 第 5 节的命令行构建，
  或直接用 `scripts/release-local.ps1` 的干跑。

---

## 6. 刻意推迟 / 已知缺口（**这一节请勿当作已完成**）

| 缺口 | 现状 | 影响 | 何时能补 |
| --- | --- | --- | --- |
| **托管 runner 上不产出 HAP** | HAP 只在 `release.yml` 的 `publish`（自托管）里构建；`ci.yml` 的 `build-hap` 仍 `if: false` | `CI` 不能替代分支上的本机构建；PR 合入前必须有人在 DevEco 里真构建过 | 让每次 push 都编 HAP 是**有意的非目标**；若要，放开 `build-hap` 的 `if` |
| **发布流水线从未在 GitHub 上真实运行过** | 每个零件都已在本机验证（见第 8 节），但"tag → runner → Release"整链未跑 | 首次打 tag 时可能暴露 YAML/runner 配置问题 | 注册 runner 后打一个 `v*-rc.1` |
| **`libcore.so` 不在任何流水线里** | 交叉编译需要 OHOS NDK，且当前被 `socklen_t` 冲突挡住（`TODO.md` §1.1） | 产出的 HAP **不含可用内核** | 解决 `TODO.md` §1.1 之后 |
| **不跑 `ohosTest`** | 无设备、无模拟器 | 只能靠本机实测；PR 模板里有"未做实机验证"勾选项要求如实标注 | 有真机或模拟器后 |
| **静态检查未进 CI** | DevEco Code Linter（`code-linter.json5`）需要在 DevEco 内运行 | ArkTS 规则只能靠本机跑；`repo-hygiene` 查不到 ArkTS 问题 | 找到可在命令行调用 codelinter 的方式后（**待确认**：DevEco 的 codelinter CLI 接口未在本机验证） |
| **workflow YAML 无自动校验** | `.github/**` 的 YAML 只由 GitHub 自己解析 | 写坏要到 push 之后才暴露 | **本轮是用本机 PyYAML 手验的结构**（`on`/`jobs`/`runs-on`/`needs`/`steps`），未进 CI —— 加它需要引入 YAML 依赖，与本仓库"零 Node 依赖"冲突，**待决策** |
| **ArkTS 无 CodeQL 支持** | CodeQL 不支持 ArkTS / `.ets` | **本仓库没有配置 `codeql.yml`**，这是有意的决定，不是遗漏 | 见下 |
| **工作流 YAML 无自动校验** | `.github/**` 的 YAML 目前只由 GitHub 自己解析 | YAML 写坏要到 push 之后才暴露 | 可考虑加一个只读 YAML 解析的 job（**待确认**：是否愿意为此引入 npm 依赖，或接受手写解析器的局限） |
| **JSON5 解析器非规范完备** | `scripts/validate-json5.mjs` 覆盖注释/尾逗号/单引号/无引号键/`0x`/`+` 号等常用子集 | 极端 JSON5 写法可能被误判 | 需要时换成成熟库（要引入 Node 依赖） |
| **`verify-repo.sh` 未被 CI 覆盖** | 它只在本地 `pre-commit`（Git for Windows 的 bash）里跑 | 有人只用 bash 时，实现可能悄悄与 PowerShell 版不一致 | 可加一个 ubuntu job 跑它并比对结果 |
| **`pwsh` 5.1 / 7 的行为差异** | 本机是 5.1，CI 是 7 | 脚本必须两边都跑通；已按此编写并在 5.1 上实测 | 本机装上 `pwsh` 后可再对齐一次 |
| **Dependabot 不覆盖 `ohpm`** | `.github/dependabot.yml` 只配了 `github-actions` | HarmonyOS 依赖需人工升级，见 `CONTRIBUTING.md` 第 5 节 | Dependabot 支持 `ohpm` 之前（当前**不存在**该生态，勿臆造） |
| **无覆盖率门槛** | 没有单测覆盖率采集 | 测试覆盖靠评审判断 | 有设备/可在命令行跑测试后 |
| **CVE 扫描缺失** | 无 Go / 原生依赖的漏洞扫描 | 内核依赖的已知漏洞靠人工跟踪 | 原生工作流加入 `go.mod` 后可加 `govulncheck` 等 |

### 6.1 关于 CodeQL：为什么不加 `codeql.yml`

CodeQL 的受支持语言清单里**没有 ArkTS / `.ets`**，而本仓库的主体就是 ArkTS。
如果硬加一个 `codeql.yml`：

- 配 `languages: javascript-typescript` 只会扫到极少数 `.mjs` 工具脚本，
  与"安全扫描"的实际意图不符；
- 一旦仓库里出现任何无法被 CodeQL 构建的语言（或未来加入 Go 时未配好 autobuild），
  **每个 push 都会因为"没有可分析源码"而报错**，属于"加了比不加更糟"。

**结论**：现在**不加**。等原生 Go 内核（`entry/src/main/golang/**`）落地后再评估——
届时可以配 `languages: go`，那才是 CodeQL 真正有价值的语言，且 `autobuild` 能在
ubuntu runner 上完成。在那之前，安全扫描依赖：
`verify-repo.ps1` 的凭据启发式 + 人工评审 + 依赖清单人工跟踪。

### 6.2 ArkTS 语法门禁：可行但有明确边界（集成阶段实测）

集成阶段为了确认 44 个 `.ets` 文件没有语法破损，实测了三种办法，结论如下（**供后续补 CI 时直接用，避免重复踩坑**）：

1. **花括号配平（朴素计数）——不可用。** 把注释、字符串、模板串剥掉后统计 `{}`/`()`/`[]`，
   仍会对**正则字面量**误报：`ShareLinkParser.ets`、`SubscriptionParser.ets`、`SubscriptionService.ets`、
   `SubscriptionViewModel.ets` 四个文件被报不配平，但**用真正的解析器检查全部通过** → 确认是假阳性。

2. **用 DevEco 自带的 TypeScript 做真解析——推荐，但需两步处理。**
   DevEco 安装目录内自带 TypeScript：
   `plugins/codelinter/arkPerfCheck/node_modules/typescript`（另有 4 处副本）。
   做法：`ts.createSourceFile(...)`，读 `sourceFile.parseDiagnostics`。
   - **必须**先把 `struct` 替换为 `class`（ArkUI 的 `struct` 不是 TS 语法）；
   - **限制**：ArkUI 的声明式语法 `Column({...}) { ... }`（函数调用后紧跟代码块）**不是合法 TS**，
     因此含声明式 UI 的 `components/**` 与 `pages/**` 会被误报。实测 44 个文件里 **13 个误报，
     全部落在 `components/` 与 `pages/`**；`model/`、`service/`、`utils/`、`constants/`、
     `vpnability/` 全部通过。

3. **结论**：该办法目前只能当作**非 UI 层 `.ets` 的语法冒烟测试**。
   要真正覆盖 UI 层，需要 ArkTS 自己的编译器（`ets-loader`）或 DevEco codelinter 的命令行接口 ——
   后者**尚未验证**（见上表）。在补齐之前，UI 层的语法正确性**只能靠 DevEco 内打开工程 sync 来确认**。

> 集成阶段的实际结论：44 个 `.ets` 文件中**未发现真实语法缺陷**；上述 13 个报错与 4 个配平报错
> 均已被证明是工具局限导致的假阳性。

### 6.3 ⚠️ 上一节的前提已被推翻：ArkTS 侧其实**能**编译

上面整节讨论的是"如何在**没有 DevEco 的机器上**给 `.ets` 做语法门禁"。
但本项目**一直**能在本机跑真编译 —— `docs/03-环境搭建.md` §5.2 早就记录了
`hvigorw assembleHap` 打通（`BUILD SUCCESSFUL`）。

**误导来源**：`TODO.md` 旧 §3.2 写的是"**本机没有 `hvigorw`，整个 HAP 从未构建**"。
这与 §5.2 的实测记录**直接矛盾**，而它让人以为"编译验证做不到" —— 于是
**一个会让构建彻底失败的改动**（`Bridge.ets` 里 `import` 位置违规，
`arkts-no-misplaced-imports`）就这样留在了 `main` 上，没人发现。

**现在的做法**：ArkTS 的正确性用**真编译**验证，不用任何近似手段：

```powershell
$dev = "D:\Harmony\DevEco Studio"
$env:DEVECO_SDK_HOME = "$dev\sdk"; $env:JAVA_HOME = "$dev\jbr"
& "$dev\tools\hvigor\bin\hvigorw.bat" clean --no-daemon
# 重定向到文件再读；不要用 PowerShell 管道抓 hvigor 输出（会截断 文件:行:列）
cmd /c "`"$dev\tools\hvigor\bin\hvigorw.bat`" --mode module -p product=default -p buildMode=debug assembleHap --no-daemon > `"$env:TEMP\build.log`" 2>&1"
```

**`clean` 是必须的**：只看 `UP-TO-DATE` 的构建证明不了任何事（它可能吃增量缓存）。

**它仍然进不了 CI** —— 托管 runner 上没有 DevEco。所以这条门禁的形态是
"**改完 `.ets` 必须本机 `clean` + `assembleHap` 一次**"（`AGENT.md` §3.1 末尾已写明），
而不是一个自动化 job。这是**已知缺口**，不是遗漏。

---

## 7. 分支 / 标签 / 发布策略

### 7.1 分支

| 分支 | 说明 |
| --- | --- |
| `main` | 主分支（**实测 `origin/HEAD` 就是 `main`**），始终可构建；只接受 PR（Squash and merge） |
| `feat/*` `fix/*` `docs/*` `chore/*` | 短期分支，用完即删 |

当前**没有** `develop` 分支，也**不需要**：项目处于早期，`main` + tag 足够。
将来若需要"预发布通道"，再引入 `release/*` 分支，并同步修改
`.github/workflows/release.yml` 的 tag 过滤与本文档。

> ⚠️ **2026-10-11 修正**：本文档与 `CONTRIBUTING.md` 此前把主分支写成 `master`，
> 但仓库实际的是 **`main`**。已全部改正。`ci.yml` 的 `pull_request.branches`
> 保留 `[main, master]` 两个值 —— 那**不是**笔误，而是让"万一有人把默认分支改名"
> 时门禁仍然生效（多写一个不存在的分支名没有任何代价）。

### 7.2 标签

- `v<major>.<minor>.<patch>`：正式版本，触发 `release.yml`。
- 预发布用 `v1.2.3-rc.1` 形式（正则允许后缀，会自动标成 GitHub prerelease）。
- **打 tag 前**：`main` 上 CI 全绿 + `AppScope/app.json5` 版本号已更新。
  真机验证**不再是前置条件**：项目还没有真机，而 tag 的意义是记录里程碑
  （未签名 HAP + 已知限制写进 release notes，见第 5.3 节）。

### 7.3 发布产物（目标形态 = 已实现形态）

一次发布产出（未签名，理由见第 5.3 节）：

```
harmonybridge-<version>-unsigned.hap    未签名；需自行签名后侧载
SHA256SUMS.txt                          上述文件的 SHA-256（sha256sum -c 可直接用）
RELEASE_NOTES.md                        由 scripts/changelog.mjs 生成（含"已知限制"小节）
```

Release notes 由 `scripts/changelog.mjs` 从 **commit log** 生成并按 Conventional Commit
类型分组。`.github/release.yml`（GitHub 自带的、按 **PR 标签**分类的生成器）仍然保留但
**不再是本流水线的产出** —— 本仓库直接提交到 `main`，用它只会得到空白日志。见第 5.2 节。

### 7.4 回滚

- **代码**：`git revert` 后再打一个 patch tag；**不要**移动或重打已有的 tag。
- **构建产物**：Releases 上删掉对应 Release 与资产，并在下一个 Release notes 中说明。

---

## 8. 维护者速查

```powershell
# 本机（= CI 的同一套规则）
.\scripts\bootstrap.ps1            # 首次：lfs + submodule + 环境自检
.\scripts\check-env.ps1            # 环境是否齐备
.\scripts\verify-repo.ps1          # 仓库卫生（全量）
.\scripts\install-hooks.ps1        # 装钩子（core.hooksPath=.githooks）
node scripts\validate-json5.mjs    # 配置语法 + 跨文件一致性
```

```powershell
# 发布（自托管 runner 未就绪时走这条；产物名与版本规则与 CI 完全一致）
.\scripts\release-preflight.ps1 -RequireDeveco     # 这台机器能不能编 HAP
.\scripts\release-local.ps1 -Tag v0.1.0            # 构建 + 生成产物（不发布）
.\scripts\release-local.ps1 -Tag v0.1.0 -SkipBuild # 只重跑产物打包
.\scripts\release-local.ps1 -Tag v0.1.0 -Publish   # 建 draft Release（-Draft:$false 直接发）
node scripts\changelog.mjs --tag v0.1.0            # 只预览变更日志
node scripts\changelog.mjs --tag v0.1.0 --validate-only   # 只校验 tag↔版本号
```

```bash
# bash 等价物
bash scripts/verify-repo.sh [--staged-only] [--json]
bash scripts/install-hooks.sh [--status|--uninstall]
```

```powershell
# 只跑 CI 里那一项（排查"为什么 CI 红"）
.\scripts\verify-repo.ps1 -Json            # 机器可读
.\scripts\verify-repo.ps1 -StagedOnly      # 复现 pre-commit 的视角
cd entry\src\main\golang                   # Go 门禁（本机无 C 编译器 → 只有 CGO_ENABLED=0 那一半）
gofmt -l .; go build ./...; go vet ./...; go test ./... -count=1
```

> ⚠️ 上面 Go 那行**只覆盖纯 Go 半边**：`main.go` / `main_test.go` 带 `//go:build cgo`，
> 本机没有 C 编译器，所以它们**根本不在编译集里**。完整覆盖在 CI（见 3.4 节）。
