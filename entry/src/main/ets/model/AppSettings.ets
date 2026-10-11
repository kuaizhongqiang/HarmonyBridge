/**
 * AppSettings.ets
 * 应用设置模型：只保留 v2rayN 设置项里在 HarmonyOS 端真正有意义的部分，
 * 并映射到 VpnConfig（MTU / DNS / trustedApplications / blockedApplications）。
 *
 * 注意：字段是扁平结构（而不是嵌套 class），因为 ArkTS 的 @Trace 只观察实例自身
 * 属性，扁平结构能保证每一项设置变更都被观察到。
 */
import { AppProxyMode, LogLevel, RoutingMode } from './Types';

/** 默认远程 DNS（走代理解析） */
export const DEFAULT_DNS_REMOTE: string = 'https://1.1.1.1/dns-query';
/** 默认直连 DNS（国内解析） */
export const DEFAULT_DNS_DIRECT: string = '223.5.5.5';
/** TUN 默认 MTU（系统允许范围 576~1500） */
export const DEFAULT_MTU: number = 1500;
/** MTU 下限 / 上限 */
export const MTU_MIN: number = 576;
export const MTU_MAX: number = 1500;

/** 应用设置 */
export interface AppSettings {
  // ---- 路由 ----
  /** 路由模式：全局 / 规则 / 直连 */
  routingMode: RoutingMode;
  /** 是否启用自定义规则集 */
  customRulesEnabled: boolean;
  /** 中国大陆域名/IP 直连 */
  bypassChina: boolean;

  // ---- VPN / TUN ----
  /** 是否启用 TUN 模式（关闭时只提供本地 socks/http 入站） */
  tunEnabled: boolean;
  /** MTU，取值 576~1500 */
  mtu: number;
  /** 是否允许 IPv6 */
  ipv6Enabled: boolean;
  /** 是否允许局域网连接（对应 v2rayN 的 allowLAN） */
  allowLan: boolean;

  // ---- DNS ----
  remoteDns: string;
  directDns: string;
  /** 是否启用流量嗅探 */
  sniffingEnabled: boolean;
  /** 嗅探结果是否覆盖目标地址 */
  sniffingOverrideDestination: boolean;

  // ---- 分应用代理 ----
  appProxyMode: AppProxyMode;
  /** 分应用清单（bundle 名） */
  appProxyList: string[];

  // ---- 日志 ----
  logLevel: LogLevel;
  logToFile: boolean;

  // ---- 内核（占位，供后续实现） ----
  coreAutoRestart: boolean;
}

/** 默认设置 */
export function defaultSettings(): AppSettings {
  const settings: AppSettings = {
    routingMode: RoutingMode.RULE,
    customRulesEnabled: false,
    bypassChina: true,
    tunEnabled: true,
    mtu: DEFAULT_MTU,
    ipv6Enabled: false,
    allowLan: false,
    remoteDns: DEFAULT_DNS_REMOTE,
    directDns: DEFAULT_DNS_DIRECT,
    sniffingEnabled: true,
    sniffingOverrideDestination: true,
    appProxyMode: AppProxyMode.OFF,
    appProxyList: [],
    logLevel: LogLevel.INFO,
    logToFile: false,
    coreAutoRestart: false
  };
  return settings;
}
