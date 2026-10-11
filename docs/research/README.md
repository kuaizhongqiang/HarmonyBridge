# 鸿蒙原生代理客户端（v2rayN 等价物）技术路线研究

> 本目录为 `docs/00-技术路线可行性.md` 的证据底座。所有非显然结论均带来源链接。
> **不使用 git 提交**（由 Lead 统一处理）；本目录为 research workstream 独占写入范围。

## 标记约定（全目录统一）

| 标记 | 含义 |
| --- | --- |
| ✅ 已验证（本地 SDK/源码） | 在本机 SDK、二进制或已下载源码中直接读到，可复核 |
| 📄 官方文档 | Huawei / OpenHarmony / 政府机关等一手文档 |
| 🌐 社区来源（可信度中） | 公开仓库源码、可复核的第三方技术文档 |
| 🌐 社区来源（可信度低） | 论坛问答、博客、二手转述；方向可信、细节待验证 |
| ❓ 未证实/推断 | 明确标注为推理或未找到权威来源 |

**可信度排序**：✅ > 📄 > 🌐中 > 🌐低 > ❓。凡标 ❓ 的内容不得被 Lead 当作既定事实引用。

---

## 结论摘要 / Verdict

### (a) 路线是否可行

**结论：技术上「可行但有条件」（yes-with-conditions），产品上「境内不可上架发行」。**

这两件事必须分开说，否则会得出错误决策：

1. **技术侧 = 可行。** 决定性证据：`VpnExtensionAbility` 是**面向三方应用的公开能力**，普通应用只需 `ohos.permission.INTERNET`，不需要 `MANAGE_VPN`、不需要系统签名、不需要企业 MDM。OpenHarmony 官方开发指南明确写「使用该功能需要 `ohos.permission.INTERNET` 权限」([net-vpnExtension 官方指南](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/network/net-vpnExtension.md))；VPN 管理器源码中，非系统调用方走的是「用户授权落库校验」而不是权限白名单（见 [01 文档](01-VPN能力与权限.md)）。已有至少 4 个公开项目在真机上跑通了这条路（[x4h](https://github.com/arror/x4h)、[Hey](https://github.com/popsiclelmlm/Hey)、[Karing HarmonyOS HAP](https://github.com/ks-lm-kf/harmony-kslmkf-karing-hap)、[etohos](https://github.com/collaborative-creation/etohos)），且其中两个**明确记录了真机型号与系统版本**。
2. **发行侧 = 不可行。** 境内应用商店对 VPN/翻墙类应用是**明文排除**：小米商店《暂不收录类应用》第 4 条即「存在VPN、翻墙、涉恐涉暴内容或功能的应用」([小米官方](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1354))；华为开发者侧答复同样引用了「应用不得含未经批准自行建立或租用专线（含虚拟专用网络VPN）等其他信道开展跨境经营活动的内容」([华为开发者问答转述](https://bbs.itying.com/topic/694107aea899160047f62733)，🌐低)。叠加《计算机信息网络国际联网管理暂行规定》第六条/第十四条（📄 [司法部国家行政法规库](https://xzfg.moj.gov.cn/front/law/detail?LawID=1713)）与工信部 APP 备案制度（📄 [工信部信管〔2023〕105号](https://nmca.miit.gov.cn/zwgk/zcwj/wjfb/art/2023/art_1e97112f056141ffba534dfe9e822063.html)），境内发行这条路是**法律与平台双重封死**的，不是"审核严一点"的问题。

**因此推荐定位：** 明确定位为**面向境外/开源分发、自带服务器（BYO-server）的通用网络工具**，例如 GitHub Release 侧载 HAP（Karing 的实际做法）；或者干脆只做**协议调试/自用工具**，不做大众发行。**不要**以「境内上架 AppGallery」作为路线前提——那会让整个项目的可行性判断失真。

### (b) Top 3 Blockers（按严重度排序）

| # | Blocker | 严重度 | 证据 |
| --- | --- | --- | --- |
| **B1** | **境内上架与合规红线**：AppGallery/主流商店不收 VPN 类应用；APP 备案是强制前置；《暂行规定》第六/十四条直接针对"自行建立或使用其他信道进行国际联网"。 | **致命**（决定产品形态，不是技术选型能绕过的） | [小米不收录清单](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1354) 📄；[工信部105号文](https://nmca.miit.gov.cn/zwgk/zcwj/wjfb/art/2023/art_1e97112f056141ffba534dfe9e822063.html) 📄；[司法部法规库](https://xzfg.moj.gov.cn/front/law/detail?LawID=1713) 📄 |
| **B2** | **Go-on-HarmonyOS 的 cgo TLS 墙**：标准 `GOOS=android` 编出的 `.so` 在**外来线程**（ArkTS/VPN 扩展）调 cgo 时可能 SIGSEGV；必须改用 `GOOS=openharmony` 的第三方 Go fork + TLSDESC 产物。这否定了本地 `go1.26.4` 直接出可用产物的可能，且引入第三方工具链依赖。 | **高**（可解，但有明确的踩坑成本与回归风险） | [Hey `docs/harmonyos-go-tls-wall.md`](https://github.com/popsiclelmlm/Hey/blob/main/docs/harmonyos-go-tls-wall.md) 🌐中；[`building-native-cores.md`](https://github.com/popsiclelmlm/Hey/blob/main/docs/building-native-cores.md) 🌐中 |
| **B3** | **本地 SDK（API 26）未声明 `onConnect`/`onDisconnected`**：`VpnExtensionAbility` 在 `D:\Harmony\DevEco Studio\sdk\...\@ohos.app.ability.VpnExtensionAbility.d.ts` 中**只有 `onCreate`/`onDestroy`**。x4h 用了 `onConnect`，Hey 没用——说明网络资料中的"标准生命周期 `onCreate→onConnect→onDisconnected→onDestroy`"**不是公开 SDK 契约**。照抄会编译失败或行为不定。 | **中高**（架构决策，需按 `onCreate` 自驱动） | ✅ 本地 SDK；[Hey `HeyVpnAbility.ets`](https://github.com/popsiclelmlm/Hey/blob/main/entry/src/main/ets/vpn/HeyVpnAbility.ets) 🌐中 |

> 补充（不单列 Top3，但需 Lead 知悉）：**模拟器很可能不支持 VPN 系统能力**，本地也未下载任何模拟器镜像 → 本机可能**完全无法做 VPN 端到端验证**（详见 04 文档）。

### (c) Top 3 需要真机才能解决的未知

| # | 未知 | 为什么必须真机 |
| --- | --- | --- |
| **U1** | **零售机（非企业机/非定制机）上三方应用能否真的 `create()` 出 tun fd** | 源码层面的门禁是「用户授权记录」（可满足）与「GUEST 用户禁止」（普通账号不受影响），但**没有任何公开文档正面承诺零售机放行**。error 2203001 的措辞与 `IsSetUpReady()` 里的 EDM 开关（`persist.edm.vpn_disable`）暗示设备策略可能介入。**必须在目标机型上实测**。 |
| **U2** | **模拟器是否声明 `SystemCapability.Communication.NetManager.Vpn`** | 官方《模拟器与真机差异》无法抓取（JS 渲染）、本地无镜像。社区与竞品代码存在**互相矛盾的信号**（etohos 直接拒绝模拟器；Karing 旧版提供 x86_64 模拟器 ABI 并声称在 API 23 模拟器走过 VPN 启动路径）。这是"能否在本机开发闭环"的分水岭。 |
| **U3** | **不带 tun2socks 的 native-TUN 直通是否可用/可持续** | 现有最完整的实现（Hey）**主动放弃**了把 TUN fd 交给核心，理由是 `CGoSetTunFd` 未导出、HarmonyOS VPN fd **拒绝 `Fstat`**（需打 gVisor 补丁）。这意味着"Xray tun inbound 直通"这条最优雅的路线**没有已证实的成功案例**。 |

### (d) 分组置信度

| 结论组 | 置信度 | 依据 |
| --- | --- | --- |
| 三方 VPN 能力的公开性（只需 INTERNET）；VpnConfig 字段语义与 API 分级 | **高** | ✅ 本地 SDK + 📄 官方文档双向一致 |
| 2203001 的真实语义 = GUEST 用户限制 | **高** | 📄 官方错误码 + ✅ OpenHarmony 源码双重确认 |
| Go 工具链现状（主线无 ohos；存在 fork） | **高** | ✅ `go tool dist list` + 📄/🌐 多个 fork 仓库 |
| `GOOS=android` 路线在深路径上会崩 | **中高** | 🌐中 一手排查记录（含崩溃栈、真机型号），但我方**未独立复现** |
| prior art 的构建方式与发行形态 | **中高** | 🌐 直接读了 manifest / 构建脚本 / README |
| 模拟器是否支持 VPN | **低（存在矛盾）** | 无一手文档；众包信号冲突 |
| 境内上架的合规结论 | **中高（方向确定，细节需律师）** | 📄 法规 + 📄 平台政策；但华为自家"不收录清单"页面**未能抓取**，仅有转述 |
| 真机零售放行 | **低（未证实）** | ❓ 无一手承诺，只能实测 |

---

## 文档索引

| 文档 | 内容 | 主要回答 |
| --- | --- | --- |
| [01-VPN能力与权限.md](01-VPN能力与权限.md) | VpnExtensionAbility 模型、用户授权、2203001、`MANAGE_VPN` 对比、tun fd 契约、`protect()`、per-app 代理、MTU/DNS/IPv6、进程模型与禁引用模块 | 问题 1–6 |
| [02-核心移植方案.md](02-核心移植方案.md) | Go for HarmonyOS 官方支持现状、`GOOS=android` 缺陷分析、Xray vs sing-box、替代路线（C/C++/Rust、ChildProcess、tun2socks、纯 ArkTS）、prior art 逐一拆解 | 问题 7–11 |
| [03-合规与上架风险.md](03-合规与上架风险.md) | 法规原文、APP 备案、平台审核实践、三层事实分离、工程级缓解建议、待律师确认问题清单 | 问题 12 |
| [04-构建与工具链.md](04-构建与工具链.md) | 本机构建能力实测、DevEco/SDK→API 映射、hvigor/ohpm/hap-sign-tool、签名与未签名安装、模拟器 blocker、NDK 细节、API 级别要求 | 问题 13–14 |

## 本机环境事实（供交叉引用，✅ 已验证）

| 项 | 值 | 采集方式 |
| --- | --- | --- |
| 工程根 | `D:\Harmony\Project\Bridge` | `Get-Location` |
| `compatibleSdkVersion` / `targetSdkVersion` | `6.1.1(24)` / `26.0.0` | `build-profile.json5` |
| `nativeCompiler` | `BiSheng` | `build-profile.json5` |
| DevEco Studio | `26.0.0.851`（build `DS-261.23567.138.36.2600851`） | `product-info.json` |
| 已装 SDK | HarmonyOS `26.0.0` / apiVersion `26` / `26.0.0.105` | `sdk/default/sdk-pkg.json` |
| NDK | `<sdk>/default/openharmony/native`（llvm + sysroot，含 `libohcommonevent.so`、`libhilog_ndk.z.so`） | 目录枚举 |
| hvigor / ohpm / node / JBR | `tools/hvigor/bin/hvigorw.bat`；ohpm `26.0.0.630`；node `v24.14.1`；JBR `25.0.2` | 实际执行 |
| `hap-sign-tool.jar` | `sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar`（可执行，支持 generate-keypair/sign-app/verify-app 等） | 实际执行 |
| Go | `go1.26.4 windows/amd64`；`go tool dist list` **无** `ohos`/`openharmony`（仅有 `android/*`） | 实际执行 |
| 设备 | `hdc list targets` → `[Empty]`（**无真机、无已下载模拟器镜像**） | 实际执行 |
| 模拟器包 | `tools/emulator` version `26.0.0.402`，`supportVersion 7.0-hos-single-6`；用户目录仅 `productConfig.json`/`.emu_config`，**无系统镜像** | 实际执行 |
