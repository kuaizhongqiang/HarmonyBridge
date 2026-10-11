/**
 * ServerNode.ets
 * 节点（服务器）模型：字段对齐 v2rayN 的 ProfileItem 与节点列表列
 * （协议 / 别名 / 地址 / 端口 / 传输 / TLS / 延迟 / 测速 / 今日与累计流量）。
 */
import { NodeId, ProxyProtocol, SecurityKind, SubscriptionId, Timestamp, TransportKind } from './Types';

/** 一个可连接的代理节点 */
export interface ServerNode {
  id: NodeId;
  /** 展示用名称（对应 v2rayN 的 Remarks） */
  remarks: string;
  protocol: ProxyProtocol;
  address: string;
  port: number;

  /** 传输层 */
  transport: TransportKind;
  /** 传输层安全 */
  security: SecurityKind;
  /** WebSocket / gRPC / h2 路径 */
  path: string;
  /** WebSocket / h2 Host 头 */
  host: string;
  /** gRPC serviceName 或 kcp seed */
  serviceName: string;
  /** TLS SNI */
  sni: string;
  /** TLS 指纹（uTLS） */
  fingerprint: string;
  /** REALITY publicKey */
  publicKey: string;
  /** REALITY shortId */
  shortId: string;
  /** ALPN，逗号分隔 */
  alpn: string;

  /** VMess/VLESS 用户 ID */
  userId: string;
  /** VMess alterId */
  alterId: number;
  /** Shadowsocks 加密方式 */
  securityCipher: string;
  /** 密码（SS / Trojan / Hysteria2） */
  password: string;
  /** VLESS flow */
  flow: string;

  /** 来源订阅 id；空字符串表示手动添加 */
  subscriptionId: SubscriptionId;
  /** 来源订阅名称（列表冗余字段，避免每次都查订阅表） */
  subscriptionName: string;
  /** 是否启用 */
  enabled: boolean;

  /** 延迟测试结果（毫秒）；-1 表示超时；0 表示未测试 */
  latencyMs: number;
  /** 最近一次测速结果（字节/秒） */
  speedBps: number;
  /** 今日 / 累计流量 */
  todayUp: number;
  todayDown: number;
  totalUp: number;
  totalDown: number;

  createdAt: Timestamp;
  updatedAt: Timestamp;
}

/** 是否已测过延迟 */
export function hasLatency(node: ServerNode): boolean {
  return node.latencyMs !== 0;
}

/** 是否延迟超时 */
export function isLatencyTimeout(node: ServerNode): boolean {
  return node.latencyMs < 0;
}

/** 节点地址展示：address:port */
export function nodeEndpointText(node: ServerNode): string {
  return node.address + ':' + node.port.toString();
}

/** 构造一个空节点，供「手动添加 / 编辑」形态使用 */
export function createEmptyNode(id: NodeId, now: Timestamp): ServerNode {
  const node: ServerNode = {
    id: id,
    remarks: '',
    protocol: ProxyProtocol.VMESS,
    address: '',
    port: 443,
    transport: TransportKind.TCP,
    security: SecurityKind.NONE,
    path: '',
    host: '',
    serviceName: '',
    sni: '',
    fingerprint: '',
    publicKey: '',
    shortId: '',
    alpn: '',
    userId: '',
    alterId: 0,
    securityCipher: 'auto',
    password: '',
    flow: '',
    subscriptionId: '',
    subscriptionName: '',
    enabled: true,
    latencyMs: 0,
    speedBps: 0,
    todayUp: 0,
    todayDown: 0,
    totalUp: 0,
    totalDown: 0,
    createdAt: now,
    updatedAt: now
  };
  return node;
}
