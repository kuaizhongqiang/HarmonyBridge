# HarmonyBridge

**鸿蒙原生的 v2rayN** —— 一个 ArkTS 前端 + Xray-core 原生内核的 HarmonyOS 代理客户端。

> **当前状态：已在真机上跑通端到端链路（自用，pre-alpha）。**
> 2026-10-12 于 HUAWEI `TYR-AL00`（nova 14 活力版 / HarmonyOS 6.1.0.145(C00E120R2P5) / API 24）
> 完成验证：签名 HAP 可安装启动；`libcore.so` 可 `dlopen`、`GoInvoke` 可调、Xray 26.3.27 正常运行；
> `libhevsocks5tun.so` 能接管系统 vNIC fd；**TUN → tun2socks → 本地 SOCKS → 内核出站** 全链路可出网。
>
> 但它**还不是一个可用的产品**：分流资源（`geoip.dat`/`geosite.dat`）未打包，IPv6 未接管，
> 节点无持久化，设置页多数项未接线。详见 [`TODO.md`](TODO.md)。
> 未经许可决策之前，本项目**仅供自用，不对外发行**（见下方「发行限制」）。

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
| 数据面 | C / hev-socks5-tunnel（`libhevsocks5tun.so`） | 接管 vNIC fd，把 TUN 流量转成本地 SOCKS |
| 接入 | `VpnExtensionAbility` | 系统 VPN 扩展；内核与数据面都跑在**扩展进程**内 |

## 技术路线（含已核实证据）

1. **系统能力具备**：本地 SDK 中 `@ohos.net.vpnExtension`（`@since 11`）提供第三方 VPN 所需的
   `startVpnExtensionAbility` / `createVpnConnection` / `VpnConnection.create(VpnConfig) → vNIC fd`。
   官方注释明确系统只提供虚拟网卡与路由配置、**隧道协议由应用自行实现** —— 这正是 v2rayN 的模型。
   三方 VPN **不需要** `MANAGE_VPN`（该权限是 `system_basic`）；门禁就是**用户授权弹窗**。
2. **数据面用「本地 SOCKS + tun2socks」**：vNIC fd **不交给 Xray**，而是交给 `tun2socks`
   （hev-socks5-tunnel），由它转成 `127.0.0.1:<socksPort>` 的 SOCKS 连接，Xray 只做本地入站 + 出站。
   防环用**官方 `VpnConnection.protectProcessNet()`**（`@since 22`，进程级、无需 fd），
   并同时保留 `blockedApplications`（把自身包名加入）双重兜底。
   裁决见 [`docs/design/ipc-contract.md`](docs/design/ipc-contract.md)。🧪 真机已验证。
3. **内核交叉编译已解决**：Go 官方**没有** `GOOS=ohos`，项目在 Linux 上自建了一份支持
   `c-shared` 的 OHOS Go 工具链，产出 `libcore.so`（约 34.5 MB，ELF64/AArch64）。
   过程记录见 [`docs/04-Linux构建任务书.md`](docs/04-Linux构建任务书.md) ~
   [`docs/08-OHOS移植执行笔记.md`](docs/08-OHOS移植执行笔记.md)。
4. **有真机先例**：社区已有至少 4 个 Xray/sing-box 的鸿蒙客户端实现，其中两个记录了真机型号与系统版本。

### 已验证到哪一步（2026-10-12，真机）

| 步骤 | 结果 |
|---|---|
| 编译 → 自动签名 → `hdc install` | ✅ HAP 37.7 MB，安装并启动成功 |
| `libcore.so` `dlopen` + `dlsym("GoInvoke")` | ✅ 返回 Xray `26.3.27` |
| 授权弹窗 / `vpn-tun` 网卡 | ✅ 网卡 `172.19.0.1/24`，MTU 1280 |
| `libhevsocks5tun.so` 接管 vNIC fd | ✅ 双向计数增长，20+ 条 SOCKS 连接建立 |
| 端到端出网 | ✅ 第三方应用浏览器可正常加载网页 |
| 流量回传（`VPN_TRAFFIC`） | ✅ 界面显示真实上下行 |

**仍然缺的**：`geoip.dat`/`geosite.dat`（按国家分流降级）、IPv6 接管（有 v6 泄漏）、
节点持久化、设置页接线、内核 `wired` 字段的权威性（现由 ArkTS 侧推算）。
完整清单见 [`TODO.md`](TODO.md)。

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

前置条件、DevEco Studio / SDK / NDK 配置与**签名**（必须用 DevEco 自动签名，AGC 签发）见
[`docs/03-环境搭建.md`](docs/03-环境搭建.md)。

> ⚠️ `libcore.so` / `libhevsocks5tun.so` **不入库**（各约 34.5 MB / 287 KB）。
> 从源码构建见 [`scripts/build-core.sh`](scripts/build-core.sh)（需 Linux）与
> [`scripts/build-tun2socks.*`](scripts/build-tun2socks.ps1)。

## 仓库导航

| 文档 | 内容 |
|---|---|
| [`AGENT.md`](AGENT.md) | **先读这个**：作业边界、硬约束、ABI 契约、许可红线、证据标记约定 |
| [`TODO.md`](TODO.md) | 未完成项与已知缺陷的完整清单（按严重度） |
| [`HANDOFF.md`](HANDOFF.md) | 交接笔记：做到哪、下一步是什么 |
| [`docs/00-技术路线可行性.md`](docs/00-技术路线可行性.md) | 可行性结论、决定性证据、阻塞项与风险 |
| [`docs/01-架构设计.md`](docs/01-架构设计.md) | 分层架构、端到端调用链、模块职责、数据模型 |
| [`docs/02-开发计划.md`](docs/02-开发计划.md) | 里程碑、工作分解、验收标准、真机验证清单 |
| [`docs/03-环境搭建.md`](docs/03-环境搭建.md) | DevEco/SDK/NDK/签名/构建命令 |
| [`docs/design/`](docs/design/) | 各工作流的设计与契约：`ipc-contract.md` / `core.md` / `ui.md` / `ci.md` |
| [`docs/04`~`08`](docs/) | OHOS Go 工具链自研与 `libcore.so` / `libhevsocks5tun.so` 的构建记录 |
| [`docs/research/`](docs/research/) | 带引用的专项调研（VPN 能力、内核移植、合规风险、工具链） |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 分支/提交规范、PR 流程、**许可警告** |

## 许可

本仓库代码为 **MIT**（见 [`LICENSE`](LICENSE)）。

但请注意：只读参考实现 [`third_party/v2rayN`](third_party/v2rayN) 是 **GPL-3.0**，
内核 **Xray-core 是 MPL-2.0**，**sing-box 是 GPL-3.0**。
**在分发或上架之前必须先做一次明确的许可决策**，详见 [`AGENT.md`](AGENT.md) 第 6 节与 [`CONTRIBUTING.md`](CONTRIBUTING.md)。
