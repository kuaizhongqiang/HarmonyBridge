/**
 * NodeEditForm.ets
 * 「添加 / 编辑节点」表单的状态模型（对齐 v2rayN 的 AddServerWindow 字段集）。
 *
 * 为什么是一个 @ObservedV2 表单对象而不是组件内部的一堆 @Local：
 * 表单字段有 20+ 个，若把状态放在 Sheet 组件内部，就需要依赖「Sheet 内容每次打开都会重建」
 * 这个生命周期假设；把状态放在**页面持有、表单组件只读**的对象里，
 * 无论 Sheet 内容是否复用，绑定的值都一定是最新的，且输入即时生效（@Trace 驱动重渲染）。
 *
 * 表单外的字段（id / 订阅归属以外的统计值 / 延迟 / 流量）由 `base` 携带，
 * 保存时 `toNode()` 以 `base` 为底覆盖表单字段，避免「编辑表单把流量统计清零」这类事故。
 */
import { NodeId, ProxyProtocol, SecurityKind, SubscriptionId, TransportKind } from '../model/Types';
import { cloneNode, createEmptyNode, ServerNode } from '../model/ServerNode';
import { securityFromText, transportFromText } from '../service/ShareLinkParser';

/** 协议值 -> 枚举；未知时退回 VMess（表单里协议一定来自固定下拉，不会真的走到这里） */
function protocolFromValue(value: string): ProxyProtocol {
  const text: string = value.toLowerCase();
  if (text === 'vless') {
    return ProxyProtocol.VLESS;
  }
  if (text === 'trojan') {
    return ProxyProtocol.TROJAN;
  }
  if (text === 'shadowsocks' || text === 'ss') {
    return ProxyProtocol.SHADOWSOCKS;
  }
  if (text === 'hysteria2') {
    return ProxyProtocol.HYSTERIA2;
  }
  if (text === 'socks') {
    return ProxyProtocol.SOCKS;
  }
  if (text === 'http') {
    return ProxyProtocol.HTTP;
  }
  return ProxyProtocol.VMESS;
}

/** 文本 -> 非负整数；非法返回 fallback */
function parseIntOr(text: string, fallback: number): number {
  const value: number = Number.parseInt(text, 10);
  if (isNaN(value)) {
    return fallback;
  }
  return value;
}

/** 节点编辑表单状态 */
@ObservedV2
export class NodeEditForm {
  // ---- 基础 ----
  @Trace remarks: string = '';
  @Trace protocol: string = ProxyProtocol.VMESS.toString();
  @Trace address: string = '';
  /** 端口以文本承载，便于 TextInput 直接双向绑定与校验 */
  @Trace portText: string = '443';
  /** 分组（对应 v2rayN 的「配置项」/ Subid）；空串 = 手动添加 */
  @Trace groupName: string = '';
  @Trace enabled: boolean = true;

  // ---- 协议参数 ----
  @Trace userId: string = '';
  @Trace password: string = '';
  @Trace securityCipher: string = 'auto';
  @Trace alterIdText: string = '0';
  @Trace flow: string = '';
  @Trace muxEnabled: boolean = false;

  // ---- 底层传输方式 ----
  @Trace transport: string = TransportKind.TCP.toString();
  @Trace host: string = '';
  @Trace path: string = '';
  @Trace serviceName: string = '';
  @Trace rawHeaderType: string = 'none';
  @Trace kcpHeaderType: string = 'none';
  @Trace grpcMode: string = 'gun';
  @Trace xhttpMode: string = 'auto';
  @Trace xhttpExtra: string = '';
  @Trace finalmask: string = '';

  // ---- 传输层安全 ----
  @Trace security: string = SecurityKind.NONE.toString();
  @Trace sni: string = '';
  @Trace fingerprint: string = '';
  @Trace alpn: string = '';
  @Trace allowInsecure: boolean = false;
  @Trace publicKey: string = '';
  @Trace shortId: string = '';
  @Trace spiderX: string = '';

  /** 原节点：承载 id、订阅归属、延迟与流量统计等「表单不编辑」的字段 */
  private base: ServerNode = createEmptyNode('', 0);

  /** 空表单（供组件参数默认值使用） */
  static blank(): NodeEditForm {
    return new NodeEditForm();
  }

  /** 由节点构造表单（内部先深拷贝，编辑期间不会污染列表里的对象） */
  static fromNode(node: ServerNode): NodeEditForm {
    const form: NodeEditForm = new NodeEditForm();
    const copy: ServerNode = cloneNode(node);
    form.base = copy;
    form.remarks = copy.remarks;
    form.protocol = copy.protocol.toString();
    form.address = copy.address;
    form.portText = copy.port.toString();
    form.groupName = copy.subscriptionName;
    form.enabled = copy.enabled;
    form.userId = copy.userId;
    form.password = copy.password;
    form.securityCipher = copy.securityCipher;
    form.alterIdText = copy.alterId.toString();
    form.flow = copy.flow;
    form.muxEnabled = copy.muxEnabled;
    form.transport = copy.transport.toString();
    form.host = copy.host;
    form.path = copy.path;
    form.serviceName = copy.serviceName;
    form.rawHeaderType = copy.rawHeaderType;
    form.kcpHeaderType = copy.kcpHeaderType;
    form.grpcMode = copy.grpcMode;
    form.xhttpMode = copy.xhttpMode;
    form.xhttpExtra = copy.xhttpExtra;
    form.finalmask = copy.finalmask;
    form.security = copy.security.toString();
    form.sni = copy.sni;
    form.fingerprint = copy.fingerprint;
    form.alpn = copy.alpn;
    form.allowInsecure = copy.allowInsecure;
    form.publicKey = copy.publicKey;
    form.shortId = copy.shortId;
    form.spiderX = copy.spiderX;
    return form;
  }

  /** 表单 -> 节点（以 base 为底，只覆盖表单可编辑字段） */
  toNode(subscriptionId: SubscriptionId, subscriptionName: string): ServerNode {
    const node: ServerNode = cloneNode(this.base);
    node.remarks = this.remarks.trim();
    node.protocol = protocolFromValue(this.protocol);
    node.address = this.address.trim();
    node.port = parseIntOr(this.portText, 0);
    node.subscriptionId = subscriptionId;
    node.subscriptionName = subscriptionName;
    node.enabled = this.enabled;
    node.userId = this.userId.trim();
    node.password = this.password;
    node.securityCipher = this.securityCipher;
    node.alterId = parseIntOr(this.alterIdText, 0);
    node.flow = this.flow;
    node.muxEnabled = this.muxEnabled;
    node.transport = transportFromText(this.transport);
    node.host = this.host.trim();
    node.path = this.path.trim();
    node.serviceName = this.serviceName.trim();
    node.rawHeaderType = this.rawHeaderType;
    node.kcpHeaderType = this.kcpHeaderType;
    node.grpcMode = this.grpcMode;
    node.xhttpMode = this.xhttpMode;
    node.xhttpExtra = this.xhttpExtra.trim();
    node.finalmask = this.finalmask.trim();
    node.security = securityFromText(this.security);
    node.sni = this.sni.trim();
    node.fingerprint = this.fingerprint;
    node.alpn = this.alpn.trim();
    node.allowInsecure = this.allowInsecure;
    node.publicKey = this.publicKey.trim();
    node.shortId = this.shortId.trim();
    node.spiderX = this.spiderX.trim();
    node.updatedAt = Date.now();
    return node;
  }

  /** 当前协议是否用 userId（VMess / VLESS） */
  isIdProtocol(): boolean {
    return this.protocol === ProxyProtocol.VMESS.toString() || this.protocol === ProxyProtocol.VLESS.toString();
  }

  /** 当前协议是否有「加密方式」字段（VMess / Shadowsocks） */
  hasCipherField(): boolean {
    return this.protocol === ProxyProtocol.VMESS.toString() ||
      this.protocol === ProxyProtocol.SHADOWSOCKS.toString();
  }

  /** 当前协议是否需要密码（SS / Trojan / Hysteria2） */
  hasPasswordField(): boolean {
    return this.protocol === ProxyProtocol.SHADOWSOCKS.toString() ||
      this.protocol === ProxyProtocol.TROJAN.toString() ||
      this.protocol === ProxyProtocol.HYSTERIA2.toString();
  }

  /** 当前传输是否需要 Host / Path（WS / h2 / XHTTP / HTTPUpgrade） */
  hasHostPathField(): boolean {
    return this.transport === TransportKind.WS.toString() ||
      this.transport === TransportKind.H2.toString() ||
      this.transport === TransportKind.XHTTP.toString() ||
      this.transport === TransportKind.HTTP_UPGRADE.toString();
  }

  /** 是否处于 TLS / REALITY（决定 SNI / 指纹等字段是否展示） */
  hasTlsField(): boolean {
    return this.security !== SecurityKind.NONE.toString();
  }
}

/** 供「新增」入口使用的 id 占位（真正 id 由 NodeViewModel.createDraft 生成） */
export const EMPTY_NODE_ID: NodeId = '';
