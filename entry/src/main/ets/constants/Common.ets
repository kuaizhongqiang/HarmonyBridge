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

