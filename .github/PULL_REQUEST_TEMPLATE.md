<!--
  感谢贡献！请按下面的结构填写，信息不全的 PR 会被要求补充。

  提交前请先在本机跑过：
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-repo.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-env.ps1
  以及 DevEco Studio 的 Code Linter（或 `code-linter.json5` 对应的检查命令）。
-->

## 变更类型

<!-- 勾选一项，与 PR 标题的 Conventional Commits 类型保持一致 -->

- [ ] `feat` 新功能
- [ ] `fix` 缺陷修复
- [ ] `docs` 文档
- [ ] `style` 格式（不影响逻辑）
- [ ] `refactor` 重构（不新增功能、不修缺陷）
- [ ] `perf` 性能
- [ ] `test` 测试
- [ ] `build` 构建系统 / 依赖
- [ ] `ci` CI 配置
- [ ] `chore` 其他杂项
- [ ] `revert` 回滚

## 关联 issue

<!-- 例如：Closes #12 / Refs #34。没有关联 issue 时写「无」并简述背景。 -->

Closes #

## 变更说明

<!--
  做了什么、为什么这样做。
  涉及 UI 的请说明页面/组件路径；涉及原生核心的请说明影响的 ABI 与 .so 产物。
-->

## 验证方式

<!--
  写清楚「怎么证明它是对的」，而不是「应该没问题」。
  至少包含：跑了什么命令 / 点了哪些界面 / 观察到什么结果。
-->

- [ ] 已在本机执行 `scripts/check-env.ps1`，结果为 READY
- [ ] 已在本机执行 `scripts/verify-repo.ps1`，结果为 PASS
- [ ] 已通过 Code Linter（`code-linter.json5`）
- [ ] 已补充/更新相应测试（若适用）

实测环境：

| 项目 | 值 |
| --- | --- |
| DevEco Studio 版本 | <!-- 例如 26.0.0.851，见 DevEco Studio → Help → About --> |
| SDK / API 版本 | <!-- 例如 compatibleSdkVersion=6.1.1(24)，targetSdkVersion=26.0.0 --> |
| 设备或模拟器 | <!-- 例如 Mate 60 Pro / HarmonyOS 6.0.0 / 无设备 --> |
| 核心版本 | <!-- 例如 xray-core 1.8.x；未改动核心时写「未涉及」 --> |

> **本机无鸿蒙设备，未做实机验证** —— 勾选此项表示本次改动只在编辑器/静态检查层面验证过。
> 请同时说明已经用哪些替代手段降低风险（编译通过、单元测试、日志推演等）。
>
> - [ ] 本机无鸿蒙设备，未做实机验证

## 影响面 / 回归风险

<!--
  可能被波及的模块、需要重点回归的路径、是否有行为变更或兼容性影响。
  改到 third_party/ 说明、许可证、构建脚本时请特别注明。
-->

- 影响模块：
- 需要重点回归：
- 是否涉及破坏性变更（`!`）：否 / 是（说明：）

## 截图（UI 变更必填）

<!-- 变更前后的对照截图；纯逻辑改动可删除本节。 -->

| 变更前 | 变更后 |
| --- | --- |
|  |  |

## 检查清单

- [ ] 我已阅读 `CONTRIBUTING.md`，并遵守其中的提交信息与分支规范
- [ ] 已过 `scripts/verify-repo.ps1`（无构建产物、无密钥、无第三方源码混入）
- [ ] 已过 linter（`code-linter.json5`）
- [ ] 未提交任何构建产物 / 密钥 / 证书（`*.so`、`*.hap`、`*.p12`、`*.cer`、`local.properties` 等）
- [ ] 未从 `third_party/v2rayN`（GPL-3.0）复制代码到 MIT 源码中
- [ ] 没有把 `# TODO(setup):` 之类的占位实现伪装成已完成功能
