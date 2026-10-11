# HarmonyBridge

**鸿蒙原生的 v2rayN** —— 一个 ArkTS 前端 + Xray-core 原生内核的 HarmonyOS 代理客户端。

> **当前状态：准备工作阶段（pre-alpha），不可安装、不可运行。**
> 本仓库目前**没有可运行的产物**：工程内没有鸿蒙真机验证过的代码，内核尚未在 OHOS 上完成交叉编译，
> VPN 链路未在真机上跑通。这里产出的是**架构、约束、流水线和可静态审查的骨架**。
> 在真机验证之前，请不要把本项目当作可用工具，也不要把本 README 的描述当成已实现的功能。

---

## 这是什么

v2rayN 是 Windows 上使用最广的 Xray/sing-box 图形客户端之一。本项目把它的**信息架构与使用模型**
移植到 HarmonyOS：手机上导入订阅、选节点、按规则分流，流量通过系统 VPN 通道交给 Xray-core 处理。

与"套壳"不同，本项目是**原生实现**：

| 层 | 技术 | 说明 |
|---|---|---|
| 前端 | ArkTS / ArkUI（stage 模型） | 原生页面、原生状态管理，无 WebView |
| 桥接 | NAPI C++（`libbridge.so`） | `dlopen` + `dlsym` 调用内核导出符号 |
| 内核 | Go / Xray-core（`libcore.so`） | `-buildmode=c-shared` 交叉编译到 `aarch64-linux-ohos` |
| 接入 | `VpnExtensionAbility` | 系统 VPN 扩展，`vpnExtension.createVpnConnection` → vNIC fd |

## 技术路线（已核实，含已知阻塞）

1. **系统能力具备**：本地 SDK 中 `@ohos.net.vpnExtension`（`@since 11`）提供第三方 VPN 所需的
   `startVpnExtensionAbility` / `createVpnConnection` / `VpnConnection.create(VpnConfig) → vNIC fd`。
   官方注释明确系统只提供虚拟网卡与路由配置、**隧道协议由应用自行实现** —— 这正是 v2rayN 的模型。
   三方 VPN **不需要** `MANAGE_VPN`（该权限是 `system_basic`）；门禁就是**用户授权弹窗**。
2. **数据面用「本地 SOCKS + tun2socks」**：tun fd **不直接交给 Xray**。原因是 tun 直通在鸿蒙上
   没有成功先例（VPN fd 拒绝 `Fstat`），且其防环依赖的 `protect(fd)` 在 Go 侧无 hook。
   改用**把自身包名放入 `blockedApplications`** 防环，无需 `protect()`。
   裁决见 [`docs/design/ipc-contract.md`](docs/design/ipc-contract.md)。
3. **⚠️ 内核交叉编译当前受阻**：Go 官方**没有** `GOOS=ohos`；社区借道 `GOOS=android/arm64` 的配方
   在本机已被尸检到**标准库 `socklen_t` 冲突**（无编译开关可解）以及运行期 **cgo TLS 墙**。
   完整尸检见 [`docs/design/core.md`](docs/design/core.md) §6。
4. **有真机先例**：社区已有至少 4 个 Xray/sing-box 的鸿蒙客户端实现，其中两个记录了真机型号与系统版本。

> **⛔ 发行限制（重要）**：中国大陆的法规与主流应用商店政策**均不接纳 VPN/代理类应用**，
> 且 APP 备案是强制前置。**境内上架发行这条路是封死的**，不应作为路线前提。
> 详见 [`docs/00-技术路线可行性.md`](docs/00-技术路线可行性.md) 与
> [`docs/research/03-合规与上架风险.md`](docs/research/03-合规与上架风险.md)（风险识别，非法律意见）。

完整论证、证据与**风险清单**见 [`docs/00-技术路线可行性.md`](docs/00-技术路线可行性.md)。

## 快速开始（开发环境）

```powershell
git clone https://github.com/kuaizhongqiang/HarmonyBridge.git
cd Bridge
.\scripts\bootstrap.ps1     # Git LFS + 参考 submodule + 环境自检
.\scripts\check-env.ps1     # 单独查看工具链是否齐备
```

前置条件、DevEco Studio / SDK / NDK 配置与签名说明见 [`docs/03-环境搭建.md`](docs/03-环境搭建.md)。

## 仓库导航

| 文档 | 内容 |
|---|---|
| [`AGENT.md`](AGENT.md) | **先读这个**：作业边界、硬约束、ABI 契约、许可红线、证据标记约定 |
| [`docs/00-技术路线可行性.md`](docs/00-技术路线可行性.md) | 可行性结论、决定性证据、阻塞项与风险 |
| [`docs/01-架构设计.md`](docs/01-架构设计.md) | 分层架构、端到端调用链、模块职责、数据模型 |
| [`docs/02-开发计划.md`](docs/02-开发计划.md) | 里程碑、工作分解、验收标准、真机验证清单 |
| [`docs/03-环境搭建.md`](docs/03-环境搭建.md) | DevEco/SDK/NDK/签名/构建命令 |
| [`docs/research/`](docs/research/) | 带引用的专项调研（VPN 能力、内核移植、合规风险、工具链） |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 分支/提交规范、PR 流程、**许可警告** |

## 许可

本仓库代码为 **MIT**（见 [`LICENSE`](LICENSE)）。

但请注意：只读参考实现 [`third_party/v2rayN`](third_party/v2rayN) 是 **GPL-3.0**，
内核 **Xray-core 是 MPL-2.0**，**sing-box 是 GPL-3.0**。
**在分发或上架之前必须先做一次明确的许可决策**，详见 [`AGENT.md`](AGENT.md) 第 6 节与 [`CONTRIBUTING.md`](CONTRIBUTING.md)。
