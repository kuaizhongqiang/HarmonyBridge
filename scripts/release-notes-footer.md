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

- **没有在真机上验证过。** 本项目当前没有 arm64 OHOS 真机，也没有 arm64 模拟器镜像。
  VPN 授权弹窗、`vpn-tun` 网卡、`tun2socks` 能否处理 VPN fd、分流是否真的生效，
  **全部未经实测**。详见 `TODO.md` 第 1 节与第 6 节。
- **`libcore.so` 尚未产出。** 关键流程依赖"在 Linux / WSL 上交叉编译 Go 内核"，
  该步骤目前**未执行成功**（原因已定位到 Go 标准库的 `socklen_t` 类型冲突，见 `TODO.md` §1.1）。
  因此本 Release 的 HAP **不包含可用的代理内核**。
- **`libhevsocks5tun.so` 从未构建成功过。** 数据面配方是从上游 Makefile 推出的，
  从未执行成功（`TODO.md` §1.3）。
- **UI 仍运行在 `MOCK_BRIDGE = true`。** 界面可以点，但走的是内存实现，
  不触碰原生内核；这是当前**正确**的状态，不是 bug（`TODO.md` §3.6）。
- **IPv6 未接管**，存在 IPv6 泄漏面（`TODO.md` §2.1、
  `docs/00-技术路线可行性.md` §7.2 风险表）。

## 校验

```bash
sha256sum -c SHA256SUMS.txt
```
