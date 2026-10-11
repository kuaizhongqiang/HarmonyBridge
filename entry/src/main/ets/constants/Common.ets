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
export const VPN_TUN_DNS: string = '172.19.0.2';

/** VPN 扩展 Ability 名称（module.json5 里 extensionAbilities[].name） */
export const VPN_ABILITY_NAME: string = 'VpnAbility';
/** 应用包名（startVpnExtensionAbility 的 want.bundleName） */
export const APP_BUNDLE_NAME: string = 'com.kuaizhongqiang.harmonybridge';

/** 域名常量 */
export const PROJECT_URL: string = 'https://github.com/kuaizhongqiang/HarmonyBridge';

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

