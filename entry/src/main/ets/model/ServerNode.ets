/**
 * ServerNode.ets
 * 节点（服务器）模型：字段对齐 v2rayN 的 `ProfileItem`（含 `TransportExtraItem` /
 * `ProtocolExtraItem` 两个展开项）与节点列表列
 * （协议 / 别名 / 地址 / 端口 / 传输 / TLS / 延迟 / 测速 / 今日与累计流量）。
 *
 * 关于「分组名」：v2rayN 的 ProfileItem 并没有独立的「组名字符串」字段，
 * 它用 `Subid` 表示节点属于哪一份配置项（订阅/手动）。本模型同样如此 ——
 * `subscriptionId` + `subscriptionName` 就是「配置项 / 分组」这一维度，
 * 编辑表单里的分组下拉直接写这两个字段，避免出现第二份会漂移的分组状态。
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
  /** REALITY spiderX */
  spiderX: string;
  /** ALPN，逗号分隔 */
  alpn: string;
  /** 跳过证书校验（对应 v2rayN 的 allowInsecure） */
  allowInsecure: boolean;

  /** raw/tcp 伪装类型（v2rayN TransportExtra.RawHeaderType） */
  rawHeaderType: string;
  /** kcp 伪装类型（v2rayN TransportExtra.KcpHeaderType） */
  kcpHeaderType: string;
  /** XHTTP 模式（v2rayN TransportExtra.XhttpMode） */
  xhttpMode: string;
  /** XHTTP 自定义 extra（v2rayN TransportExtra.XhttpExtra） */
  xhttpExtra: string;
  /** gRPC 模式（v2rayN TransportExtra.GrpcMode） */
  grpcMode: string;
  /** Finalmask（v2rayN ProfileItem.Finalmask） */
  finalmask: string;

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

  /** 是否开启 Mux 多路复用（v2rayN ProfileItem.MuxEnabled） */
  muxEnabled: boolean;

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
    spiderX: '',
    alpn: '',
    allowInsecure: false,
    rawHeaderType: 'none',
    kcpHeaderType: 'none',
    xhttpMode: 'auto',
    xhttpExtra: '',
    grpcMode: 'gun',
    finalmask: '',
    userId: '',
    alterId: 0,
    securityCipher: 'auto',
    password: '',
    flow: '',
    muxEnabled: false,
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

/**
 * 节点跨 C 边界的序列化形态。
 *
 * 用途：`ConfigService.Generate` 的 `extra` 参数（契约见 `docs/design/ipc-contract.md` §4）。
 * 之所以要显式声明一个 interface 而不是直接 `JSON.stringify(node)`：
 * ArkTS 严格模式要求对象字面量挂在显式类型上，且需要一条**稳定的字段清单**，
 * 否则模型加字段会悄悄改变发给内核的 JSON 形状。
 */
export interface NodeJson {
  id: string;
  remarks: string;
  protocol: string;
  address: string;
  port: number;
  transport: string;
  security: string;
  host: string;
  path: string;
  serviceName: string;
  rawHeaderType: string;
  kcpHeaderType: string;
  xhttpMode: string;
  xhttpExtra: string;
  grpcMode: string;
  finalmask: string;
  sni: string;
  fingerprint: string;
  alpn: string;
  allowInsecure: boolean;
  publicKey: string;
  shortId: string;
  spiderX: string;
  userId: string;
  alterId: number;
  securityCipher: string;
  password: string;
  flow: string;
  muxEnabled: boolean;
}

/** 节点 -> 可 JSON 化的显式结构 */
export function nodeToJson(node: ServerNode): NodeJson {
  const json: NodeJson = {
    id: node.id,
    remarks: node.remarks,
    protocol: node.protocol.toString(),
    address: node.address,
    port: node.port,
    transport: node.transport.toString(),
    security: node.security.toString(),
    host: node.host,
    path: node.path,
    serviceName: node.serviceName,
    rawHeaderType: node.rawHeaderType,
    kcpHeaderType: node.kcpHeaderType,
    xhttpMode: node.xhttpMode,
    xhttpExtra: node.xhttpExtra,
    grpcMode: node.grpcMode,
    finalmask: node.finalmask,
    sni: node.sni,
    fingerprint: node.fingerprint,
    alpn: node.alpn,
    allowInsecure: node.allowInsecure,
    publicKey: node.publicKey,
    shortId: node.shortId,
    spiderX: node.spiderX,
    userId: node.userId,
    alterId: node.alterId,
    securityCipher: node.securityCipher,
    password: node.password,
    flow: node.flow,
    muxEnabled: node.muxEnabled
  };
  return json;
}

/** 节点 -> JSON 文本（写进 `ConfigService.Generate` 的 `extra`） */
export function nodeToJsonText(node: ServerNode): string {
  return JSON.stringify(nodeToJson(node));
}

/** 浅拷贝一个节点（表单编辑用：避免未点保存就污染列表里的对象） */
export function cloneNode(node: ServerNode): ServerNode {
  const copy: ServerNode = createEmptyNode(node.id, node.createdAt);
  copy.remarks = node.remarks;
  copy.protocol = node.protocol;
  copy.address = node.address;
  copy.port = node.port;
  copy.transport = node.transport;
  copy.security = node.security;
  copy.path = node.path;
  copy.host = node.host;
  copy.serviceName = node.serviceName;
  copy.sni = node.sni;
  copy.fingerprint = node.fingerprint;
  copy.publicKey = node.publicKey;
  copy.shortId = node.shortId;
  copy.spiderX = node.spiderX;
  copy.alpn = node.alpn;
  copy.allowInsecure = node.allowInsecure;
  copy.rawHeaderType = node.rawHeaderType;
  copy.kcpHeaderType = node.kcpHeaderType;
  copy.xhttpMode = node.xhttpMode;
  copy.xhttpExtra = node.xhttpExtra;
  copy.grpcMode = node.grpcMode;
  copy.finalmask = node.finalmask;
  copy.userId = node.userId;
  copy.alterId = node.alterId;
  copy.securityCipher = node.securityCipher;
  copy.password = node.password;
  copy.flow = node.flow;
  copy.muxEnabled = node.muxEnabled;
  copy.subscriptionId = node.subscriptionId;
  copy.subscriptionName = node.subscriptionName;
  copy.enabled = node.enabled;
  copy.latencyMs = node.latencyMs;
  copy.speedBps = node.speedBps;
  copy.todayUp = node.todayUp;
  copy.todayDown = node.todayDown;
  copy.totalUp = node.totalUp;
  copy.totalDown = node.totalDown;
  copy.updatedAt = node.updatedAt;
  return copy;
}
