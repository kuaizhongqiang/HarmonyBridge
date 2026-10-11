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
| L2 本机完整 | 手动 / 推之前 | `scripts/check-env.ps1`、`scripts/verify-repo.ps1`（全量索引）、`node scripts/validate-json5.mjs` | 与 CI 同一套规则，提前发现问题 |
| L3 PR / push | `.github/workflows/ci.yml` | `repo-hygiene`(windows) + `conventional-pr`(ubuntu，仅 PR) + `manifests`(ubuntu) | 不可绕过的自动化门禁 |
| L4 标签发布 | `.github/workflows/release.yml` | 版本号校验 + 干跑（`workflow_dispatch`）；真正的构建/签名**尚未实现** | 发布流程的骨架与显式失败 |
| L5 自托管 | `[self-hosted, harmonyos, windows]` | DevEco 构建、`hap-sign-tool.jar` 签名、真机 instrumentation | **待搭建**，见第 4 节 |

**为什么"检查"和"构建"要分开？** 因为它们的**可运行前提完全不同**。L3 的三项只需要
`git` / `node` / `pwsh`，任何托管 runner 都有；而真正的 HAP 构建需要几个 GB 的 SDK 和
许可受限的签名材料。把两者塞进同一个 job 的后果是：要么整个 CI 因为没有 SDK 而常年红着，
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

### 3.4 `build-hap`：**刻意不可运行**

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
- 每个待实现步骤都带 `# TODO(setup):`，并写清预期命令与产物路径。

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

### 4.2 签名材料（**绝不入库**）

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
   （与 `.github/workflows/ci.yml` / `release.yml` 里的 `runs-on` 对应）。
2. 设 `DEVECO_HOME`、`SDK_HOME`、`JAVA_HOME` 环境变量。
3. 把签名材料放进受限目录，用环境变量指向它（例如 `HB_SIGN_KEYSTORE`、
   `HB_SIGN_PROFILE` —— `release.yml` 的 preflight 已经按这些名字检查）。
4. 去掉 `.github/workflows/ci.yml` 里 `build-hap` job 的 `if: false`，
   并把它 steps 里 `# TODO(setup):` 的部分替换为真实命令。
5. 先在一个分支上验证，再放开到 `master`。

> **不要**把自托管 runner 直接暴露给来自 fork 的 PR：那等于让任意代码在装有签名材料的
> 机器上执行。本项目用 `pull_request`（不是 `pull_request_target`）+ 托管 runner 跑
> L3 全部检查，自托管 runner 只承接 `workflow_dispatch` 与 tag 触发的发布 —— 就是为了避开
> 这个问题。

---

## 5. L4：发布流程（`.github/workflows/release.yml`）

### 5.1 已实现

| 步骤 | 说明 |
| --- | --- |
| 触发 | `push` tag `v*`；或 `workflow_dispatch`（带 `dry_run` 输入） |
| 版本解析 | 从 tag 取 `v<semver>`，与 `AppScope/app.json5` 的 `versionName` **比对**；不一致直接失败并说明"先改清单再打 tag" |
| 清单复检 | 再跑一次 `scripts/validate-json5.mjs` |
| 干跑 | `workflow_dispatch` 时跑 `verify-repo.sh`，并把"构建/签名/发布都未执行"写进 job summary |
| preflight | 真发布路径会检查 DevEco、签名密钥库、profile 是否就绪；缺任何一项 → `::error::` + 非 0 退出 |
| 权限 | 默认 `contents: read`；只有 `release` job 提权到 `contents: write` |

### 5.2 未实现（带 `# TODO(setup):`，且会显式失败）

1. 编译原生内核（`scripts/build-core.ps1`，属原生工作流）
2. `hvigorw ... assembleHap` 产出**未签名** HAP
3. `hap-sign-tool.jar sign-app` 签名
4. 生成 `SHA256SUMS.txt`
5. 创建 GitHub Release 并附带产物（`softprops/action-gh-release@v3`）

**为什么让它失败而不是跳过？** 因为"跳过"会让 tag 打完之后看起来发布成功了，
而 Releases 页面空空如也——这种静默失败比一次明确的红色 job 昂贵得多。

### 5.3 版本号约定

- tag 形式：`v<major>.<minor>.<patch>`（可带 `-rc.1` 之类的后缀，正则已允许）。
- **tag 必须与 `AppScope/app.json5` 的 `versionName` 一致**，且 `versionCode` 单调递增。
- 打 tag 前请在本地跑通 `docs/03-环境搭建.md` 第 5 节的命令行构建。

---

## 6. 刻意推迟 / 已知缺口（**这一节请勿当作已完成**）

| 缺口 | 现状 | 影响 | 何时能补 |
| --- | --- | --- | --- |
| **不产出 HAP** | `build-hap` 为 `if: false`；`release` job 的构建/签名步骤是 TODO | CI **不能**替代本机构建；PR 合入前必须有人在 DevEco 里真构建过 | 搭好自托管 runner 后 |
| **不跑 `ohosTest`** | 无设备、无模拟器 | 只能靠本机实测；PR 模板里有"未做实机验证"勾选项要求如实标注 | 有真机或模拟器后 |
| **静态检查未进 CI** | DevEco Code Linter（`code-linter.json5`）需要在 DevEco 内运行 | ArkTS 规则只能靠本机跑；`repo-hygiene` 查不到 ArkTS 问题 | 找到可在命令行调用 codelinter 的方式后（**待确认**：DevEco 的 codelinter CLI 接口未在本机验证） |
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

---

## 7. 分支 / 标签 / 发布策略

### 7.1 分支

| 分支 | 说明 |
| --- | --- |
| `master` | 主分支，始终可构建；只接受 PR（Squash and merge） |
| `feat/*` `fix/*` `docs/*` `chore/*` | 短期分支，用完即删 |

当前**没有** `develop` 分支，也**不需要**：项目处于早期，`master` + tag 足够。
将来若需要"预发布通道"，再引入 `release/*` 分支，并同步修改
`.github/workflows/release.yml` 的 tag 过滤与本文档。

### 7.2 标签

- `v<major>.<minor>.<patch>`：正式版本，触发 `release.yml`。
- 预发布用 `v1.2.3-rc.1` 形式（正则允许后缀）。
- **打 tag 前**：`master` 上 CI 全绿 + 本地真机验证过 + `AppScope/app.json5` 版本号已更新。

### 7.3 发布产物（目标形态）

一旦自托管 runner 就绪，一次发布预期产出：

```
harmonybridge-<version>.hap        已签名，可侧载
SHA256SUMS.txt                     上述文件的 SHA-256
```

Release notes 由 `.github/release.yml` 按 **PR 标签**归类（GitHub 的生成器只看标签，
看不到 commit type，所以 `.github/release.yml` 里的 label 名与 commit type 保持一致）。

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

```bash
# bash 等价物
bash scripts/verify-repo.sh [--staged-only] [--json]
bash scripts/install-hooks.sh [--status|--uninstall]
```

```powershell
# 只跑 CI 里那一项（排查"为什么 CI 红"）
.\scripts\verify-repo.ps1 -Json            # 机器可读
.\scripts\verify-repo.ps1 -StagedOnly      # 复现 pre-commit 的视角
```
