/**
 * NodeOptions.ets
 * 节点编辑表单的下拉选项表，取值逐条对齐 v2rayN 的 `ServiceLib/Global.cs`
 * （`Networks` / `KcpHeaderTypes` / `XhttpMode` / `Fingerprints` / `Flows` /
 *  `VmessSecurities` / `SsSecuritiesInXray`，以及 AddServerWindow 里内联的
 *  raw 伪装类型 `{None, Http}` 与 gRPC 模式 `{gun, multi}`）。
 *
 * 这些是**协议标记值**（会被写进内核 config.json），不是面向用户的文案，
 * 因此按 v2rayN 原样保留英文；表单里各字段的**标题**才走 string.json。
 * 这样做也保证与节点列表已有的 `TCP / NONE` 这类原始枚举展示风格一致。
 */
import { ProxyProtocol, SecurityKind, TransportKind } from '../model/Types';

/** 可手动编辑的协议（顺序即下拉框顺序） */
export const PROTOCOL_OPTIONS: string[] = [
  ProxyProtocol.VMESS.toString(),
  ProxyProtocol.VLESS.toString(),
  ProxyProtocol.TROJAN.toString(),
  ProxyProtocol.SHADOWSOCKS.toString(),
  ProxyProtocol.HYSTERIA2.toString(),
  ProxyProtocol.SOCKS.toString(),
  ProxyProtocol.HTTP.toString()
];

/**
 * 底层传输方式。
 * 注：v2rayN 的 `Networks` 首项是 `raw`，本项目枚举里叫 `tcp`（`transportFromText` 两者都接受），
 * 这里用本项目枚举值，保证「读入 -> 表单 -> 写回」不丢信息。
 */
export const TRANSPORT_OPTIONS: string[] = [
  TransportKind.TCP.toString(),
  TransportKind.WS.toString(),
  TransportKind.GRPC.toString(),
  TransportKind.H2.toString(),
  TransportKind.HTTP_UPGRADE.toString(),
  TransportKind.XHTTP.toString(),
  TransportKind.KCP.toString(),
  TransportKind.QUIC.toString()
];

/** 传输层安全 */
export const SECURITY_OPTIONS: string[] = [
  SecurityKind.NONE.toString(),
  SecurityKind.TLS.toString(),
  SecurityKind.REALITY.toString()
];

/** raw 伪装类型（v2rayN: `new List<string> { Global.None, Global.RawHeaderHttp }`） */
export const RAW_HEADER_OPTIONS: string[] = ['none', 'http'];

/** kcp 伪装类型（v2rayN: `Global.KcpHeaderTypes`，补上 none） */
export const KCP_HEADER_OPTIONS: string[] = ['none', 'srtp', 'utp', 'wechat-video', 'dtls', 'wireguard', 'dns'];

/** XHTTP 模式（v2rayN: `Global.XhttpMode`） */
export const XHTTP_MODE_OPTIONS: string[] = ['auto', 'packet-up', 'stream-up', 'stream-one'];

/** gRPC 模式（v2rayN: `{Global.GrpcGunMode, Global.GrpcMultiMode}`） */
export const GRPC_MODE_OPTIONS: string[] = ['gun', 'multi'];

/** uTLS 指纹（v2rayN: `Global.Fingerprints`） */
export const FINGERPRINT_OPTIONS: string[] = [
  'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random', 'randomized'
];

/** VLESS flow（v2rayN: `Global.Flows`，首项为空串表示不使用） */
export const FLOW_OPTIONS: string[] = ['', 'xtls-rprx-vision', 'xtls-rprx-vision-udp443'];

/** VMess 加密方式（v2rayN: `Global.VmessSecurities`） */
export const VMESS_SECURITY_OPTIONS: string[] = ['aes-128-gcm', 'chacha20-poly1305', 'auto', 'none', 'zero'];

/** Shadowsocks 加密方式（v2rayN: `Global.SsSecuritiesInXray`） */
export const SS_CIPHER_OPTIONS: string[] = [
  'aes-256-gcm',
  'aes-128-gcm',
  'chacha20-poly1305',
  'chacha20-ietf-poly1305',
  'xchacha20-poly1305',
  'xchacha20-ietf-poly1305',
  'none',
  'plain',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305'
];

/** 在选项表里定位某个值；找不到返回 0 */
export function optionIndexOf(options: string[], value: string): number {
  const index: number = options.indexOf(value);
  return index < 0 ? 0 : index;
}
