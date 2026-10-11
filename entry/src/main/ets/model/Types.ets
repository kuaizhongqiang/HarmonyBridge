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

/**
 * 传输层类型（对齐 v2rayN 的 `Network` 字段）。
 *
 * ⚠️ `H2` 与 `QUIC` 在本版内核（xray-core v1.260327.0）里**已被删除**：
 * `infra/conf/transport_internet.go:1015-1018` 对 `h2`/`h3`/`http`/`quic` 直接
 * 走 `PrintRemovedFeatureError`。v2rayN 的 `Global.Networks`（Global.cs:331-339）
 * 也**只保留** `raw / xhttp / kcp / grpc / ws / httpupgrade`。
 *
 * 因此这两个取值**不出现在表单下拉里**（见 constants/NodeOptions.ets 的
 * TRANSPORT_OPTIONS）。保留枚举的意义是：导入一份含 `type=h2` 的分享链接时
 * 仍能**忠实记录**它的传输方式，从而在生成配置时给出精确报错（"已被内核删除，
 * 改用 XHTTP stream-one"），而不是静默降级成 tcp 去连一个连不上的东西。
 */
export enum TransportKind {
  TCP = 'tcp',
  WS = 'ws',
  GRPC = 'grpc',
  HTTP_UPGRADE = 'httpupgrade',
  /** 内核已删除；仅用于忠实解析与精确报错，不可选 */
  H2 = 'h2',
  /** 内核已删除；仅用于忠实解析与精确报错，不可选 */
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
