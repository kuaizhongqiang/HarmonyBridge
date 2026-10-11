/**
 * Types.ets
 * 全局共享的基础类型、枚举与标识别名。所有 model / viewmodel / service / UI 层都从这里取类型，
 * 保证只有一个定义来源（避免 ArkTS 循环引用与重复声明）。
 */

/** 节点 id */
export type NodeId = string;
/** 订阅 id */
export type SubscriptionId = string;
/** 毫秒时间戳 */
export type Timestamp = number;
/** 日志 id */
export type LogId = string;

/** 代理协议类型（对齐 v2rayN 的 EConfigType，只保留 HarmonyOS 端需要的核心协议） */
export enum ProxyProtocol {
  VMESS = 'vmess',
  VLESS = 'vless',
  TROJAN = 'trojan',
  SHADOWSOCKS = 'shadowsocks',
  HYSTERIA2 = 'hysteria2',
  SOCKS = 'socks',
  HTTP = 'http',
  UNKNOWN = 'unknown'
}

/** 传输层类型（对齐 v2rayN 的 Network 字段） */
export enum TransportKind {
  TCP = 'tcp',
  WS = 'ws',
  GRPC = 'grpc',
  HTTP_UPGRADE = 'httpupgrade',
  H2 = 'h2',
  QUIC = 'quic',
  KCP = 'kcp',
  XHTTP = 'xhttp',
  UNKNOWN = 'unknown'
}

/** 传输层安全（对齐 v2rayN 的 StreamSecurity 字段） */
export enum SecurityKind {
  NONE = 'none',
  TLS = 'tls',
  REALITY = 'reality'
}

/** 连接状态机：未连接 -> 连接中 -> 已连接 -> 断开中 -> 未连接 */
export enum ConnectionState {
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  DISCONNECTING = 'disconnecting',
  ERROR = 'error'
}

/** 路由模式：对应 v2rayN 的全局 / 规则 / 直连 */
export enum RoutingMode {
  GLOBAL = 'global',
  RULE = 'rule',
  DIRECT = 'direct'
}

/** 分应用代理模式（映射到 VpnConfig 的 trustedApplications / blockedApplications） */
export enum AppProxyMode {
  OFF = 'off',
  ALLOW_LIST = 'allow_list',
  BLOCK_LIST = 'block_list'
}

/** 日志级别 */
export enum LogLevel {
  DEBUG = 'debug',
  INFO = 'info',
  WARN = 'warn',
  ERROR = 'error'
}

/** 实时流量统计（由 VPN 扩展进程通过 VPN_TRAFFIC 公共事件上报） */
export interface TrafficStats {
  /** 上行瞬时速度，字节/秒 */
  speedUp: number;
  /** 下行瞬时速度，字节/秒 */
  speedDown: number;
  /** 本次连接累计上行字节 */
  totalUp: number;
  /** 本次连接累计下行字节 */
  totalDown: number;
  /** 最近一次上报时间戳（毫秒） */
  updatedAt: Timestamp;
}

/** 空统计，避免 UI 里到处写魔法值 */
export function emptyTrafficStats(): TrafficStats {
  const stats: TrafficStats = {
    speedUp: 0,
    speedDown: 0,
    totalUp: 0,
    totalDown: 0,
    updatedAt: 0
  };
  return stats;
}

/** 协议 -> 展示短名（协议标签） */
export function protocolTagText(protocol: ProxyProtocol): string {
  if (protocol === ProxyProtocol.VMESS) {
    return 'VMess';
  }
  if (protocol === ProxyProtocol.VLESS) {
    return 'VLESS';
  }
  if (protocol === ProxyProtocol.TROJAN) {
    return 'Trojan';
  }
  if (protocol === ProxyProtocol.SHADOWSOCKS) {
    return 'SS';
  }
  if (protocol === ProxyProtocol.HYSTERIA2) {
    return 'Hy2';
  }
  if (protocol === ProxyProtocol.SOCKS) {
    return 'Socks';
  }
  if (protocol === ProxyProtocol.HTTP) {
    return 'HTTP';
  }
  return 'Unknown';
}

/** 分享链接 scheme -> 协议枚举 */
export function protocolFromScheme(scheme: string): ProxyProtocol {
  const s: string = scheme.toLowerCase();
  if (s === 'vmess') {
    return ProxyProtocol.VMESS;
  }
  if (s === 'vless') {
    return ProxyProtocol.VLESS;
  }
  if (s === 'trojan' || s === 'trojan-go') {
    return ProxyProtocol.TROJAN;
  }
  if (s === 'ss' || s === 'shadowsocks') {
    return ProxyProtocol.SHADOWSOCKS;
  }
  if (s === 'hysteria2' || s === 'hy2') {
    return ProxyProtocol.HYSTERIA2;
  }
  if (s === 'socks' || s === 'socks5') {
    return ProxyProtocol.SOCKS;
  }
  if (s === 'http' || s === 'https') {
    return ProxyProtocol.HTTP;
  }
  return ProxyProtocol.UNKNOWN;
}

/** 日志级别 -> 展示短名 */
export function logLevelText(level: LogLevel): string {
  if (level === LogLevel.DEBUG) {
    return 'DEBUG';
  }
  if (level === LogLevel.INFO) {
    return 'INFO';
  }
  if (level === LogLevel.WARN) {
    return 'WARN';
  }
  return 'ERROR';
}
