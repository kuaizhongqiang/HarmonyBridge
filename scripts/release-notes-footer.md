<!--
  scripts/release-notes-footer.md
  本文件会被 scripts/changelog.mjs 原样追加到每份 RELEASE_NOTES.md 的末尾。
  只写"发布即成立的事实"，不写任何取决于真机的性能/稳定性声明。
-->
## 安装与自签名（未签名 HAP）

本次发布的 `harmonybridge-<version>-unsigned.hap` **是未签名包**，因为本仓库的规则不允许把
签名材料（`.p12` / `.cer` / `.p7b` 及其口令）写进仓库或流水线（见 `AGENT.md` 第 1 节与
`docs/design/ci.md` 第 5 节）。未签名包**不能直接侧载**，请自行签名：

1. 用 DevEco Studio 26.0 打开本工程；工程会自行 `ohpm install` 与 sync。
2. 在 `Project Structure → Signing Configs` 里勾选自动签名（需要已登录的华为开发者账号），
   或手工填 `build-profile.json5` 的 `signingConfigs`。
3. `Build → Build Hap(s)` 产出你自己的已签名包。

自签名产物的 SHA-256 未必匹配本 Release 附带的 `SHA256SUMS.txt`（签名会改变内容），
请以 `SHA256SUMS.txt` 校验**下载到的那份未签名 HAP** 本身是否完整、有没有被篡改。

## 已知限制（发布即成立，非"将来会修"）

- 🔴 **本 Release 的 HAP 不包含代理内核与数据面。** `libcore.so`（约 34.5 MB）与
  `libhevsocks5tun.so`（约 287 KB）**都不入库**（`AGENT.md` 第 3 节第 5 条：构建产物不入库），
  而流水线是从 git 检出后构建的 —— 所以**从本 Release 下载的 HAP 装上也连不了**。
  要真正跑起来，必须自己构建（见上文），并把这两个 `.so` 放进 `entry/libs/arm64-v8a/`；
  构建方式见 `scripts/build-core.sh`（需 Linux）与 `scripts/build-tun2socks.*`。
- **`geoip.dat` / `geosite.dat` 未打包。** rule 模式下按国家/地区分流的规则**不会生成**，
  分流降级为「私有网段直连 + 其余走代理」（`TODO.md` §6.5）。
- **IPv6 未接管**，存在 IPv6 泄漏面（`TODO.md` §2.1、
  `docs/00-技术路线可行性.md` §7.2 风险表）。
- **节点不持久化**：节点只在内存里，冷启动后回到内置演示节点（`TODO.md` §9.5）。
- **设置页多数项未接线**：MTU / DNS / 分流模式 / 日志级别改了不生效（`TODO.md` §9.5）。
- **无前台常驻通知、无断线重连**：VPN 扩展被系统回收时用户不会被告知（`TODO.md` §9.5）。

> **关于"能不能跑"**：整条链路**已在真机上验证通过**（2026-10-12，HUAWEI `TYR-AL00` / API 24）：
> `libcore.so` 的 `dlopen` + `GoInvoke` 正常、`libhevsocks5tun.so` 接管 vNIC fd、
> TUN → tun2socks → 本地 SOCKS → 内核出站 端到端可上网。
> **但那验证的是本地构建（含那两个 `.so`）的产物，不是本 Release 的这一份。**
> 详见 `README.md` 的验证表与 `TODO.md` 第 0 节。

## 校验

```bash
sha256sum -c SHA256SUMS.txt
```
