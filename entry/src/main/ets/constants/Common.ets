/**
 * Common.ets
 * 全局常量：日志域、日志标签、MOCK 开关、公共尺寸，以及核心服务的「意图」定义。
 */

/** hilog 域号（与 EntryAbility 保持一致） */
export const LOG_DOMAIN: number = 0x0000;
/** hilog 业务标签 */
export const LOG_TAG: string = 'HarmonyBridge';

/**
 * VPN 扩展进程与 UI 进程之间约定的事件名。
 * 扩展进程用 commonEventManager.publish 发布，UI 进程订阅后刷新流量统计。
 * 事件 parameters 携带 TOTAL_UP / TOTAL_DOWN / SPEED_UP / SPEED_DOWN（字节 / 字节每秒）。
 */
export const VPN_TRAFFIC_EVENT: string = 'VPN_TRAFFIC';

/**
 * VPN 扩展进程 -> UI 进程的**内核状态**事件。
 *
 * 为什么必须有它（2026-10-12 真机实测的结论）：
 *   `libcore.so` 是**按进程各加载一份**的 —— 每个进程有自己的 Go 运行时、
 *   自己的服务注册表。内核跑在**扩展进程**里（见
 *   `ets/vpnability/VpnAbility.ets#startCoreInProcess`），所以在 UI 进程里调
 *   `CoreService.Status` / `LogService.Tail` 读到的只是 UI 进程那份**从未启动过**
 *   的空实例。内核的真实状态只能由扩展进程主动上报。
 *
 *   顺带：这也绕开了 Go 内核里 `wired` 恒为 false 的那句假话
 *   （`golang/service/core/core.go:110-114`、`:210`）—— 那句话在 Windows 上改不了，
 *   因为交叉编译不出 `.so`（TODO.md §1.1）。现在的 `wired` 由扩展进程自己算：
 *   「内核已启动」**且**「tun2socks 已运行」。
 *
 * parameters（发布端 VpnAbility#publishCoreState，解码端 core/CoreStateMonitor.ets）：
 *   CORE_STARTED    boolean  内核实例是否已启动
 *   CORE_WIRED      boolean  本地 SOCKS 入站已监听 **且** tun2socks 已运行
 *   CORE_VERSION    string   内核版本（拿不到时为空串）
 *   CORE_SOCKS_PORT number   内核本地 SOCKS 入站端口
 *   CORE_HTTP_PORT  number   内核本地 HTTP 入站端口
 *   CORE_ERROR      string   失败原因；成功时为空串
 */
export const VPN_CORE_STATE_EVENT: string = 'VPN_CORE_STATE';
export const CORE_STATE_STARTED: string = 'CORE_STARTED';
export const CORE_STATE_WIRED: string = 'CORE_WIRED';
export const CORE_STATE_VERSION: string = 'CORE_VERSION';
export const CORE_STATE_SOCKS_PORT: string = 'CORE_SOCKS_PORT';
export const CORE_STATE_HTTP_PORT: string = 'CORE_HTTP_PORT';
export const CORE_STATE_ERROR: string = 'CORE_ERROR';

/** VPN 扩展的 Want key（app 传给扩展的核心配置与资源路径） */
export const WANT_KEY_CONFIG_PATH: string = 'CONFIG_PATH';
export const WANT_KEY_ASSET_PATH: string = 'ASSET_PATH';
/**
 * app 把**内核实际使用的入站端口**告诉扩展进程（tun2socks 要连的就是它）。
 *
 * 为什么必须传而不是各写一份：`ConfigService.Generate` 的端口由 Go 侧
 * `config.DefaultSocksPort` / `DefaultHTTPPort` 决定（generated/config.go），
 * ArkTS 只是把它回显出来。扩展进程**拿不到** UI 进程的 `ConfigPathResult`
 * （它是另一个进程，只能通过 want 收参数），所以这里的数字必须由 UI 进程显式传递，
 * 否则就退化成"扩展进程自己猜一个端口"——两侧一旦漂移，症状是 tun2socks 连到
 * 一个没人在听的端口，**静默不通**，没有任何报错。
 */
export const WANT_KEY_SOCKS_PORT: string = 'SOCKS_PORT';
export const WANT_KEY_HTTP_PORT: string = 'HTTP_PORT';

/**
 * 内核本地入站端口的**唯一 ArkTS 来源**（回落值）。
 *
 * 权威值来自 Go 侧 `entry/src/main/golang/service/config/build.go` 的
 * `DefaultSocksPort` / `DefaultHTTPPort`，并随 `ConfigService.Generate` /
 * `CoreService.Start` 的结果回传；这两个常量只用于"原生没给端口"时的回落，
 * 以及扩展进程在 want 里没收到端口时的回落。
 *
 * 历史缺陷：这个数字曾经在**三处**各自写死（VpnAbility 的 tun2socks YAML、
 * Bridge 的 Start/Fake 默认值），且 Go 侧还有第四份。四份一旦漂移，
 * tun2socks 会连到一个没人在听的端口 —— 静默不通。现在只保留这里的回落值与
 * Go 侧那一份权威值。
 */
export const CORE_SOCKS_PORT: number = 10808;
export const CORE_HTTP_PORT: number = 10809;

/** VPN 虚拟网卡名（vpn-tun），statistics.getIfaceTxBytes/getIfaceRxBytes 使用 */
export const VPN_IFACE_NAME: string = 'vpn-tun';

/** TUN 虚拟网卡默认地址与网段 */
export const VPN_TUN_ADDRESS: string = '172.19.0.1';
export const VPN_TUN_PREFIX_LENGTH: number = 24;
/**
 * 交给系统的 VPN DNS 服务器地址。
 *
 * 🔴 **必须是真实可达的解析器，不能是 TUN 内网地址。**
 *
 * 真机实测（2026-10-12）：这里原本是 `172.19.0.2`，即 TUN 网段内的一个地址。
 * 但**没有任何进程在 `172.19.0.2:53` 上应答** —— Go 侧 `buildDNS`
 * （`service/config/build.go`）配的是 Xray 的**内部解析器**
 * （223.5.5.5 / 1.1.1.1 / DoH），那是"内核自己怎么解析域名"，
 * 不是"一台对外服务的 DNS"。于是全机的 DNS 查询被送进 TUN 后无人应答：
 *   * 症状：浏览器永久卡在"正在加载"；
 *   * 系统日志：`NETSTACK_RCP: errCode:1007900028, NetworkError-:dnsServerReturnNothing`；
 *   * 而隧道本身是**通的**（`vpn-tun` 的 RX/TX 双向计数都在增长）——
 *     所以这**只**是 DNS 的问题，不要误判成数据面没通。
 *
 * 现在指向一个真实解析器：查询会被路由进隧道，再按规则
 * （rule 模式下有 `port 53 -> proxy`）交给出站代理解析 —— 这正是"远程 DNS"应有的行为。
 *
 * ⚠️ 后续应当由设置页的「远程 DNS」驱动（经 `want.parameters` 传给扩展进程），
 * 而不是在这里写死一个值。
 */
export const VPN_TUN_DNS: string = '1.1.1.1';

/** VPN 扩展 Ability 名称（module.json5 里 extensionAbilities[].name） */
export const VPN_ABILITY_NAME: string = 'VpnAbility';
/** 应用包名（startVpnExtensionAbility 的 want.bundleName） */
export const APP_BUNDLE_NAME: string = 'com.kuaizhongqiang.harmonybridge';

/** 域名常量 */
export const PROJECT_URL: string = 'https://github.com/kuaizhongqiang/HarmonyBridge';

/**
 * 本地节点种子文件名（`entry/src/main/resources/rawfile/` 下）。
 *
 * 用途：真机联调时给应用喂**真实节点**，而**不必**把真实地址/凭据写进任何被 git
 * 跟踪的源文件。rawfile 会被打进 HAP，所以种子随本机构建进入设备；
 * 该文件本身在 `.gitignore` 里，永不入库（模板是 `local-nodes.example.txt`）。
 *
 * 文件缺失（全新 clone）时应用**静默回落**到内置演示节点，不报错、不白屏。
 */
export const LOCAL_NODES_RAWFILE: string = 'local-nodes.txt';

// ---------------------------------------------------------------------------
// 数据标签（不是 UI 文案，因此不放进 string.json；涉及 UI 展位的部分请在页面里用 $r 包装）
// ---------------------------------------------------------------------------

/** 订阅更新时写入节点的来源标记 */
export const SUBSCRIPTION_ID_CLIPBOARD: string = 'clipboard';
export const SUBSCRIPTION_NAME_CLIPBOARD: string = 'clipboard';
export const SUBSCRIPTION_ID_MANUAL: string = 'manual';
export const SUBSCRIPTION_NAME_MANUAL: string = 'manual';

/** 内核版本前缀（Mock） */
export const MOCK_CORE_VERSION: string = 'mock-core 0.1.0 (MOCK)';

