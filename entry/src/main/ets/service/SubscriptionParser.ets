/**
 * SubscriptionParser.ets
 * 订阅内容解析（纯逻辑）：base64 机场订阅 / 纯文本分享链接 / 简易 Clash YAML。
 * 无 UI、无网络（网络拉取在 SubscriptionService.ets 里，二者分离便于单测）。
 */
import { NodeId, Timestamp } from '../model/Types';
import { ServerNode } from '../model/ServerNode';
import { dedupeNodes, filterValidNodes } from './NodeValidator';
import {
  decodeBase64,
  encodeBase64,
  extractLinks,
  generateId,
  normalizeBase64,
  parseShareLink,
  trimToken
} from './ShareLinkParser';
import { Logger } from '../utils/Logger';

const TAG: string = 'SubscriptionParser';

/** 订阅内容形态 */
export enum SubscriptionFormat {
  /** 整段 base64，解码后是分享链接列表（v2rayN 最常见的机场格式） */
  BASE64 = 'base64',
  /** 纯文本分享链接列表 */
  PLAIN = 'plain',
  /** Clash / Mihomo YAML */
  CLASH = 'clash',
  /** 无法识别 */
  UNKNOWN = 'unknown'
}

/** 解析结果 */
export interface SubscriptionParseResult {
  format: SubscriptionFormat;
  nodes: ServerNode[];
  /** 被跳过的行数（格式不支持或校验失败） */
  skipped: number;
  /** 解析失败时的原因 */
  error: string;
}

/** 解析订阅正文 */
export function parseSubscriptionBody(body: string, now: Timestamp): SubscriptionParseResult {
  const text: string = body === undefined || body === null ? '' : body;
  if (text.trim().length === 0) {
    const emptyResult: SubscriptionParseResult = {
      format: SubscriptionFormat.UNKNOWN,
      nodes: [],
      skipped: 0,
      error: 'empty-body'
    };
    return emptyResult;
  }

  const format: SubscriptionFormat = detectFormat(text);
  let links: string[] = [];
  if (format === SubscriptionFormat.BASE64) {
    const decoded: string = decodeBase64(normalizeBase64(text));
    links = extractLinks(decoded);
  } else if (format === SubscriptionFormat.PLAIN) {
    links = extractLinks(text);
  } else if (format === SubscriptionFormat.CLASH) {
    const clashNodes: ServerNode[] = parseClashProxies(text, now);
    const clashResult: SubscriptionParseResult = {
      format: SubscriptionFormat.CLASH,
      nodes: dedupeNodes(filterValidNodes(clashNodes)),
      skipped: 0,
      error: clashNodes.length === 0 ? 'no-clash-proxies' : ''
    };
    return clashResult;
  } else {
    const unknownResult: SubscriptionParseResult = {
      format: SubscriptionFormat.UNKNOWN,
      nodes: [],
      skipped: 0,
      error: 'unknown-format'
    };
    return unknownResult;
  }

  const nodes: ServerNode[] = [];
  let skipped: number = 0;
  for (let i = 0; i < links.length; i++) {
    const id: NodeId = generateId('node', i, now);
    const node: ServerNode | undefined = parseShareLink(links[i], id, now);
    if (node === undefined) {
      skipped = skipped + 1;
      continue;
    }
    node.subscriptionName = '';
    nodes.push(node);
  }

  const result: SubscriptionParseResult = {
    format: format,
    nodes: dedupeNodes(filterValidNodes(nodes)),
    skipped: skipped,
    error: ''
  };
  Logger.info(TAG, 'parsed ' + result.nodes.length.toString() + ' nodes, skipped ' + skipped.toString());
  return result;
}

/** 识别订阅内容形态 */
export function detectFormat(text: string): SubscriptionFormat {
  const trimmed: string = text.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return SubscriptionFormat.UNKNOWN;
  }
  // Clash：出现 proxies: 顶层键
  if (containsClashMarker(trimmed)) {
    return SubscriptionFormat.CLASH;
  }
  if (looksLikeShareLinks(trimmed)) {
    return SubscriptionFormat.PLAIN;
  }
  // 整体 base64 判定：解码后必须出现 "://"
  const decoded: string = decodeBase64(normalizeBase64(trimmed));
  if (decoded.indexOf('://') > 0) {
    return SubscriptionFormat.BASE64;
  }
  return SubscriptionFormat.UNKNOWN;
}

/** 是否包含 Clash 的顶层 proxies: 标记 */
function containsClashMarker(text: string): boolean {
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    if (line.startsWith('proxies:') || line.startsWith('proxy-groups:')) {
      return true;
    }
  }
  return false;
}

/** 是否已经是明文分享链接列表 */
function looksLikeShareLinks(text: string): boolean {
  const links: string[] = extractLinks(text);
  return links.length > 0;
}

// ---------------------------------------------------------------------------
// 简易 Clash YAML 解析（不引入第三方 yaml 依赖，只覆盖 proxies 列表的必要字段）
// ---------------------------------------------------------------------------

/** Clash 代理条目 */
interface ClashProxy {
  name: string;
  type: string;
  server: string;
  port: number;
  cipher: string;
  password: string;
  uuid: string;
  network: string;
  tls: boolean;
  sni: string;
  wsPath: string;
  wsHost: string;
  grpcServiceName: string;
  alterId: number;
  /** 跳过证书校验（skip-cert-verify） */
  skipCertVerify: boolean;
  /** uTLS 指纹（client-fingerprint） */
  fingerprint: string;
  /** ALPN（alpn） */
  alpn: string;
  /** 伪装类型（kcp-opts.header / 顶层 header-type） */
  headerType: string;
}

/**
 * 解析 Clash 的 proxies: 段。
 * 只做「够用」的解析：按缩进识别列表项，按 `key: value` 读取标量字段，
 * 忽略嵌套对象里除 ws-opts 之外的复杂结构。复杂配置请改用 v2ray 订阅。
 */
function parseClashProxies(text: string, now: Timestamp): ServerNode[] {
  const lines: string[] = text.split('\n');
  const proxies: ClashProxy[] = [];
  let inProxies: boolean = false;
  let current: ClashProxy | undefined = undefined;
  let inWsOpts: boolean = false;

  for (let i = 0; i < lines.length; i++) {
    const rawLine: string = lines[i].replace('\r', '');
    const line: string = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) {
      continue;
    }
    if (!inProxies) {
      if (line.startsWith('proxies:')) {
        inProxies = true;
      }
      continue;
    }
    // 顶层列表项："- { name: xxx" 或 "- name: xxx"
    if (line.startsWith('- ') || line === '-') {
      if (current !== undefined) {
        proxies.push(current);
      }
      current = newClashProxy();
      inWsOpts = false;
      const inline: string = line.substring(1).trim();
      if (inline.length > 0) {
        applyClashPair(current, inline, inWsOpts);
      }
      continue;
    }
    // proxies 段结束（出现新的顶层键）
    if (!rawLine.startsWith(' ') && !rawLine.startsWith('\t') && !rawLine.startsWith('-')) {
      inProxies = false;
      if (current !== undefined) {
        proxies.push(current);
        current = undefined;
      }
      continue;
    }
    if (current === undefined) {
      continue;
    }
    if (line.startsWith('ws-opts:')) {
      inWsOpts = true;
      continue;
    }
    if (line.startsWith('grpc-opts:')) {
      inWsOpts = false;
      continue;
    }
    applyClashPair(current, line, inWsOpts);
  }
  if (current !== undefined) {
    proxies.push(current);
  }

  const nodes: ServerNode[] = [];
  for (let i = 0; i < proxies.length; i++) {
    const node: ServerNode | undefined = clashProxyToNode(proxies[i], i, now);
    if (node !== undefined) {
      nodes.push(node);
    }
  }
  return nodes;
}

/** 新建一个空的 Clash 代理条目 */
function newClashProxy(): ClashProxy {
  const proxy: ClashProxy = {
    name: '',
    type: '',
    server: '',
    port: 0,
    cipher: '',
    password: '',
    uuid: '',
    network: '',
    tls: false,
    sni: '',
    wsPath: '',
    wsHost: '',
    grpcServiceName: '',
    alterId: 0,
    skipCertVerify: false,
    fingerprint: '',
    alpn: '',
    headerType: ''
  };
  return proxy;
}

/** 把一个 `key: value` 对写进 Clash 代理条目 */
function applyClashPair(proxy: ClashProxy, line: string, inWsOpts: boolean): void {
  const colonIndex: number = line.indexOf(':');
  if (colonIndex <= 0) {
    return;
  }
  const key: string = line.substring(0, colonIndex).trim();
  const value: string = trimToken(line.substring(colonIndex + 1));
  if (key === 'name') {
    proxy.name = value;
  } else if (key === 'type') {
    proxy.type = value.toLowerCase();
  } else if (key === 'server') {
    proxy.server = value;
  } else if (key === 'port') {
    const port: number = Number.parseInt(value, 10);
    proxy.port = isNaN(port) ? 0 : port;
  } else if (key === 'cipher') {
    proxy.cipher = value;
  } else if (key === 'password') {
    proxy.password = value;
  } else if (key === 'uuid') {
    proxy.uuid = value;
  } else if (key === 'alterId' || key === 'alterid') {
    const aid: number = Number.parseInt(value, 10);
    proxy.alterId = isNaN(aid) ? 0 : aid;
  } else if (key === 'network') {
    proxy.network = value.toLowerCase();
  } else if (key === 'tls') {
    proxy.tls = value.toLowerCase() === 'true';
  } else if (key === 'sni' || key === 'servername') {
    proxy.sni = value;
  } else if (key === 'path') {
    if (inWsOpts) {
      proxy.wsPath = value;
    }
  } else if (key === 'host') {
    if (inWsOpts) {
      proxy.wsHost = value;
    }
  } else if (key === 'grpc-service-name') {
    proxy.grpcServiceName = value;
  } else if (key === 'skip-cert-verify') {
    proxy.skipCertVerify = value.toLowerCase() === 'true';
  } else if (key === 'client-fingerprint') {
    proxy.fingerprint = value;
  } else if (key === 'alpn') {
    proxy.alpn = value;
  } else if (key === 'header-type' || key === 'header') {
    // kcp-opts.header 与顶层 header-type 都是「伪装类型」
    proxy.headerType = value;
  }
}

/** Clash 条目 -> ServerNode；不支持的 type 返回 undefined */
function clashProxyToNode(proxy: ClashProxy, index: number, now: Timestamp): ServerNode | undefined {
  const id: NodeId = generateId('clash', index, now);
  let link: string = '';
  if (proxy.type === 'vmess') {
    // 借助 vmess 分享链接复用解析逻辑，避免维护第二套字段映射
    const jsonText: string = '{"ps":"' + proxy.name + '","add":"' + proxy.server + '","port":"' +
      proxy.port.toString() + '","id":"' + proxy.uuid + '","aid":"' + proxy.alterId.toString() + '","net":"' +
      proxy.network + '","type":"' + proxy.headerType + '","path":"' + proxy.wsPath + '","host":"' +
      proxy.wsHost + '","tls":"' + (proxy.tls ? 'tls' : '') + '","sni":"' + proxy.sni + '","scy":"' +
      proxy.cipher + '","fp":"' + proxy.fingerprint + '","alpn":"' + proxy.alpn + '"}';
    link = 'vmess://' + encodeBase64(jsonText);
  } else if (proxy.type === 'vless') {
    link = buildStandardLink('vless', proxy.uuid, proxy, index);
  } else if (proxy.type === 'trojan') {
    link = buildStandardLink('trojan', proxy.password, proxy, index);
  } else if (proxy.type === 'ss' || proxy.type === 'shadowsocks') {
    link = buildStandardLink('ss', proxy.cipher + ':' + proxy.password, proxy, index);
  } else {
    Logger.warn(TAG, 'unsupported clash proxy type: ' + proxy.type);
    return undefined;
  }
  return parseShareLink(link, id, now);
}

/** 拼接 vless/trojan/ss 形式的链接 */
function buildStandardLink(scheme: string, credential: string, proxy: ClashProxy, index: number): string {
  const query: string = '?type=' + (proxy.network.length > 0 ? proxy.network : 'tcp') +
    (proxy.tls ? '&security=tls' : '') +
    (proxy.sni.length > 0 ? '&sni=' + proxy.sni : '') +
    (proxy.wsPath.length > 0 ? '&path=' + proxy.wsPath : '') +
    (proxy.wsHost.length > 0 ? '&host=' + proxy.wsHost : '') +
    (proxy.grpcServiceName.length > 0 ? '&serviceName=' + proxy.grpcServiceName : '') +
    (proxy.fingerprint.length > 0 ? '&fp=' + proxy.fingerprint : '') +
    (proxy.alpn.length > 0 ? '&alpn=' + proxy.alpn : '') +
    (proxy.headerType.length > 0 ? '&headertype=' + proxy.headerType : '') +
    (proxy.skipCertVerify ? '&insecure=true' : '');
  return scheme + '://' + credential + '@' + proxy.server + ':' + proxy.port.toString() + query + '#' +
    proxy.name + '-' + index.toString();
}
