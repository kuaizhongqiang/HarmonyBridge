# 贡献指南（Contributing）

本文面向**要往本仓库提交代码的人**（人类或智能体）。
它只讲流程、规范与红线；环境安装细节一律引用 `docs/03-环境搭建.md`，不在这里复制。

> **先读这三份**（按顺序）：
> 1. `AGENT.md` —— 当前阶段、作业边界、硬约束、许可红线
> 2. `docs/03-环境搭建.md` —— 环境搭建、签名与证书、构建与命令行跑法
> 3. `docs/design/ci.md` —— CI/CD 设计与「为什么 CI 不产出 HAP」

---

## 1. 开发环境

### 1.1 首次上手（一条命令）

```powershell
git clone https://github.com/kuaizhongqiang/HarmonyBridge.git
cd Bridge
.\scripts\bootstrap.ps1
```

`bootstrap.ps1` 做四件事（可重复执行）：校验 `git`/`git-lfs` → `git lfs install --local`
→ 拉取 `third_party/v2rayN`（shallow，**不带 `--recursive`**）→ 调用 `check-env.ps1` 做环境自检。

```powershell
.\scripts\bootstrap.ps1 -SkipSubmodules   # 离线，或不需要参考 submodule
.\scripts\bootstrap.ps1 -Recursive        # 真的要连嵌套 submodule 一起拉
```

### 1.2 环境自检

```powershell
.\scripts\check-env.ps1
.\scripts\check-env.ps1 -Json        # 机器可读输出，便于排查/脚本化
```

它逐项打印**实际找到的路径与版本**：DevEco Studio 安装目录与版本、HarmonyOS SDK 目录与 API
版本、`build-profile.json5` 里的 `compatibleSdkVersion`/`targetSdkVersion`、NDK `clang` 与
`llvm-config`、`node`/`npm`、`ohpm` 与 `hvigorw`（PATH 与 DevEco 安装目录两处都找）、`git`、
`git-lfs`、`go`、`java`、`hap-sign-tool.jar`。

退出码：**有硬失败返回非 0**，只有警告返回 0。
`-RequireGo` / `-RequireJava` 可把 go / JDK 缺失从警告升级为硬失败（给内核、发布两条流水线用）。

环境安装的完整步骤（SDK 版本、`local.properties`、依赖、签名与证书、命令行构建）
见 **`docs/03-环境搭建.md`**。

### 1.3 安装 Git 钩子（一次性）

```powershell
.\scripts\install-hooks.ps1              # 等价于 git config core.hooksPath .githooks
.\scripts\install-hooks.ps1 -Status      # 只看当前配置
.\scripts\install-hooks.ps1 -Uninstall   # 还原
```

钩子放在版本化的 `.githooks/` 里，通过 `core.hooksPath` 生效，
因此 **不需要可执行位**、也不会和 `git lfs install` 写进 `.git/hooks` 的钩子互相覆盖。
原因与取舍见 `.githooks/README.md`。

> Linux/macOS 或 Git Bash：等价命令是
> `git config core.hooksPath .githooks`，或 `bash scripts/install-hooks.sh`。

---

## 2. 分支与提交规范

### 2.1 分支

| 分支 | 用途 |
| --- | --- |
| `master` | 主分支，始终保持可构建；只接受 PR 合入 |
| `feat/<主题>` | 新功能 |
| `fix/<主题>` | 缺陷修复 |
| `docs/<主题>` / `chore/<主题>` | 文档、工程杂项 |

- 一个 PR 只做一件事。跨工作流的大改请拆开，或先在 issue 里说明。
- **不要**在 PR 里顺手改别的模块的代码；`entry/**`、`AppScope/**` 由对应工作流负责。
- 禁止 `git push --force` 到 `master`。

### 2.2 提交信息（Conventional Commits，由钩子强制）

```
<type>(<scope>): <subject>
```

- **type**：`feat` `fix` `docs` `style` `refactor` `perf` `test` `build` `ci` `chore` `revert`
- **scope（建议）**：`repo` `submodule` `ci` `ui` `core` `bridge` `docs` `vpn`
  `subscription` `settings`
- 标题 **≤ 100 字符**，中文或英文皆可，但同一 PR 保持一致
- 破坏性变更在 type 后加 `!`（如 `feat(vpn)!: ...`），正文写清影响与迁移方式
- `Merge` / `Revert` / `fixup!` / `squash!` 由钩子放行

```text
feat(ui): 服务器列表支持按延迟排序
fix(bridge): 修复 GoFreeCString 在空指针时崩溃
chore(deps)!: 移除未使用的 hypium mock 依赖
```

PR 标题同样会被 CI 检查（`amannn/action-semantic-pull-request`），所以标题也要合规。

---

## 3. 本地质量门禁

**提交前请全部跑一遍**（钩子只覆盖前两项中与暂存区相关的部分）：

```powershell
.\scripts\check-env.ps1         # 环境自检
.\scripts\verify-repo.ps1       # 仓库卫生（全量索引）
node scripts\validate-json5.mjs # 配置文件语法 + 跨文件一致性
```

| 门禁 | 命令 | 拦什么 |
| --- | --- | --- |
| 仓库卫生 | `.\scripts\verify-repo.ps1` | 构建产物、签名材料、疑似密钥、submodule 结构异常 |
| 环境自检 | `.\scripts\check-env.ps1` | SDK / NDK / 工具链缺失 |
| 提交信息 | `.githooks/commit-msg` | 非规范提交信息 |
| 暂存区卫生 | `.githooks/pre-commit` | 本次提交新增的违禁文件 |
| 配置合法性 | `node scripts\validate-json5.mjs` | `build-profile.json5` / `oh-package.json5` / `app.json5` / `module.json5` 写坏 |
| 静态检查 | DevEco Studio → Code Linter（规则见 `code-linter.json5`） | ArkTS 规范与安全问题 |
| 内核编译 | `cd entry\src\main\golang; go build ./...; go vet ./...` | Go 侧语法 / 静态问题 |
| CI | `.github/workflows/ci.yml` | 上述各项的自动化版本 |

`verify-repo.ps1` 的具体规则（单一事实来源是 `scripts/forbidden-patterns.txt`）：

1. 禁止跟踪构建产物与密钥：`*.so` `*.hap` `*.hsp` `*.har` `*.p12` `*.cer` `*.keystore`
   `*.jks` `*.pem` `local.properties`，以及任何 `build/` 目录下的文件；
2. `third_party/` 下**只允许 submodule gitlink**，不得有普通文件；
3. `.gitmodules` 里声明的每个 path 都必须在索引中存在（否则新克隆会静默缺东西）；
4. 跟踪的文本文件里出现明显的凭据特征（`AKIA…`、`sk-…`、`ghp_…`、私钥头、
   `accessKeyId = "…"`）即失败。

> 第 4 条是**窄口径**启发式，不是通用熵扫描器：只抓几个经典前缀，
> 宁可漏报也不误报。真正的密钥扫描请交给独立的工具/CI。

有 bash 环境时可用等价实现：`bash scripts/verify-repo.sh [--staged-only] [--json]`。

**绕过钩子**：`git commit --no-verify`。CI 会对**全量索引**跑同一套规则，
所以绕过只是把失败推迟到 PR，不会让它消失。

---

## 4. PR 流程

1. **开 issue 或确认已有 issue**（小的文档/笔误可跳过）。
2. 从最新 `master` 切分支：`git switch -c feat/ui-server-sort`。
3. 提交前跑完第 3 节的门禁。
4. 推送并开 PR，按 `.github/PULL_REQUEST_TEMPLATE.md` 填写：
   变更类型 / 关联 issue / 变更说明 / **验证方式** / 影响面与回归风险 / 截图（UI 改动）。
5. **如实说明验证程度**。没有鸿蒙真机就勾选
   「本机无鸿蒙设备，未做实机验证」，并写清替代手段（编译通过、单元测试、日志推演）。
   —— 说不清楚怎么验证的 PR，比说「没验证」的 PR 更危险。
6. 等 CI 绿 + 至少一位 CODEOWNERS 中的评审者批准。
7. 用 **Squash and merge**（标题即最终提交信息，所以仍须符合规范）。

### 4.1 评审清单（评审者用）

- [ ] PR 只做了一件事，标题与内容一致
- [ ] 提交信息符合 Conventional Commits，破坏性变更有 `!` 且正文说明了迁移方式
- [ ] 作者给出的验证方式是**可复现**的（命令、步骤、观察结果），而不是「应该没问题」
- [ ] 无真机时，是否明确勾选了未实机验证，并说明了降低风险的手段
- [ ] 未提交构建产物 / 密钥 / 证书；`verify-repo` 在 CI 通过
- [ ] 未从 `third_party/v2rayN`（GPL-3.0）复制代码、资源、图标或文案
- [ ] 改动 C ABI 契约时，Go 导出、C++ 桥、ArkTS 类型声明在**同一提交**内一起改
      （见 `AGENT.md` 5.4）
- [ ] 影响 `module.json5` 声明（权限、ability、扩展）时，已在描述里点明
- [ ] 新增的「未实现」部分没有伪装成已完成；占位实现有明确标注

### 4.2 明确不做的事

- ❌ 不在 PR 里提交 `*.so` / `*.hap` / 任何构建产物
- ❌ 不提交签名材料、证书、私钥、`local.properties`
- ❌ 不为了让 CI 变绿而放宽 `.github/**`、`.githooks/**`、`scripts/verify-repo.*` 里的检查
      （这类改动需要单独评审并在描述里说明理由）
- ❌ 不直接 `git push` 到 `master`
- ❌ 不修改 `third_party/v2rayN` 的内容

---

## 5. 依赖升级

`ohpm` 管理的依赖（`oh-package.json5` / `oh-package-lock.json5`）**没有**自动化升级：

> Dependabot 没有 `ohpm` 生态（也**不存在**可以配置的 `package-ecosystem: ohpm`）。
> 见 `.github/dependabot.yml` 里的说明。目前只自动跟踪 `github-actions`。

升级步骤：本地 `ohpm update` → 跑通构建与 Code Linter → 单独提一个 `chore(deps)` PR，
并在描述里写明升级原因与验证方式。SDK / DevEco 版本变更属于更大的决策，请先开 issue 讨论。

---

## 6. 许可证与第三方代码（法律红线）

> **本节内容与 `AGENT.md` 第 6 节一致；如两者出现分歧，以 `AGENT.md` 为准。**

| 组件 | 许可 | 对本项目的含义 |
| --- | --- | --- |
| 本仓库源码 | **MIT**（见 `LICENSE`） | 现状，不是最终决定 |
| `third_party/v2rayN` | **GPL-3.0** | **只读参考**。把它的代码搬进本仓库 = 本项目需整体转 GPL-3.0 |
| Xray-core | **MPL-2.0** | 文件级 copyleft；作为独立依赖链接通常可接受，但必须保留声明与许可文本 |
| sing-box | **GPL-3.0** | 若改用 sing-box 作内核，整个应用的许可策略需重新评估 |

**因此：**

- ✅ 可以：阅读 `third_party/v2rayN` 理解信息架构、路由语义、配置字段含义，
  然后**用自己的话与自己的代码重新实现**。
- ✅ 可以：把它的**行为**作为设计依据，并在文档里注明出处。
- ❌ 不可以：复制粘贴其 C# 代码、资源、图标、界面文案。
- ❌ 不可以：把它当依赖编译进产物，或在 `entry/**` 里直接引用它的文件。
- ❌ 不可以：把 `third_party/v2rayN` 从 submodule 改成 vendored 源码
  （`scripts/verify-repo.ps1` 会直接拒绝）。
- ⚠️ **上架或分发之前，必须由人做一次明确的许可决策**：本项目最终是 MIT 还是 GPL-3.0？
  内核选 Xray-core（MPL-2.0）还是 sing-box（GPL-3.0）？
  在那之前，本文件只记录约束，**不替这个决策**，也不对法律后果作任何结论。

引入任何新的第三方依赖时，请在 PR 描述里写明其**名称、版本、许可证与链接**。
许可证不明或为 GPL 系列时，先开 issue 讨论，不要先合代码。

---

## 7. 其它约定

- **文本编码与换行**：UTF-8；文本文件一律 LF（`*.ps1`/`*.bat`/`*.cmd` 例外，保持 CRLF）。
  由 `.gitattributes` 与 `.editorconfig` 共同保证，见 `.editorconfig` 顶部说明。
- **大二进制**：`*.so` `*.dat` `*.har` `*.p12` 走 Git LFS（`.gitattributes` 已配置）。
  即便如此，**构建产物仍然不入库**。
- **文档**：面向使用者的文档用中文；代码注释、提交信息、CI 里对机器说的文本用英文皆可，
  但**同一个文件内保持一致**。
- **不要为了让检查通过而修改检查**。若规则本身不合理，另开 issue 讨论并单独提交。
- **智能体（AI）提交**：与人类提交同样适用本指南；不得把「未实现」描述成「已实现」，
  不得伪造验证结果（无法验证就写无法验证，并说明原因）。
