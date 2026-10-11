/**
 * ShareLinkParser.ets
 * 分享链接 -> ServerNode 解析（纯逻辑，无 UI / 无网络）。
 * 支持 scheme：vmess://(base64 JSON) / vless:// / trojan:// / ss:// / hysteria2:// / socks://
 * 与 v2rayN 的 ShareLink 解析保持一致：解析失败一律返回 undefined，由调用方跳过该条。
 */
import { buffer } from '@kit.ArkTS';
import {
  NodeId,
  ProxyProtocol,
  SecurityKind,
  Timestamp,
  TransportKind,
  protocolFromScheme
} from '../model/Types';
import { createEmptyNode, ServerNode } from '../model/ServerNode';
import { jsonNum, jsonStr, jsonStrOr } from './JsonHelpers';
import { Logger } from '../utils/Logger';

const TAG: string = 'ShareLinkParser';
/** 未指定时的默认代理端口 */
const DEFAULT_PROXY_PORT: number = 443;

/** 分享链接解析结果（携带原始链接，便于调试与去重） */
export interface ParsedShareLink {
  node: ServerNode;
  rawLink: string;
}

/** 去掉两端的空白与引号 */
export function trimToken(text: string): string {
  let s: string = text.trim();
  while (s.startsWith('"') || s.startsWith('\'')) {
    s = s.substring(1);
  }
  while (s.endsWith('"') || s.endsWith('\'') || s.endsWith(',')) {
    s = s.substring(0, s.length - 1);
  }
  return s.trim();
}

/** Base64 解码；失败返回空串 */
export function decodeBase64(text: string): string {
  try {
    return buffer.from(text, 'base64').toString('utf-8');
  } catch (error) {
    Logger.warn(TAG, 'base64 decode failed: ' + Logger.describe(error as Object));
    return '';
  }
}

/** Base64 编码（vmess 导出用） */
export function encodeBase64(text: string): string {
  return buffer.from(text, 'utf-8').toString('base64');
}

/**
 * 规整 base64 文本：支持 base64url（-/_）与缺失的 padding，并去掉换行。
 * 订阅内容常见「整段 base64」与「base64url」两种形态。
 */
export function normalizeBase64(text: string): string {
  let s: string = text.replace(/[\r\n\t ]/g, '');
  s = s.replace(/-/g, '+');
  s = s.replace(/_/g, '/');
  const remainder: number = s.length % 4;
  if (remainder === 2) {
    s = s + '==';
  } else if (remainder === 3) {
    s = s + '=';
  } else if (remainder === 1) {
    // 非法长度，直接返回原串让上层判定失败
    return text;
  }
  return s;
}

/** URI 百分号解码；失败返回原串 */
export function percentDecode(text: string): string {
  if (text.indexOf('%') < 0) {
    return text;
  }
  try {
    return decodeURIComponent(text);
  } catch (error) {
    Logger.warn(TAG, 'percentDecode failed: ' + Logger.describe(error as Object));
    return text;
  }
}

/** 去掉链接的 #fragment，返回 [主干, 名称] */
function splitFragment(link: string): string[] {
  const hashIndex: number = link.indexOf('#');
  if (hashIndex < 0) {
    return [link, ''];
  }
  const body: string = link.substring(0, hashIndex);
  const name: string = percentDecode(link.substring(hashIndex + 1));
  return [body, name];
}

/**
 * 解析 `key=value&...` 查询串，写回节点字段。
 * 支持 vless/trojan/hysteria2 的常见参数：
 *   type/security/sni/host/path/serviceName/flow/pbk/sid/spx/fp/alpn/encryption
 *   headertype（raw / kcp 伪装类型）、mode（XHTTP / gRPC 模式）、extra（XHTTP extra）
 *   insecure/allowinsecure（跳过证书校验）、fm（Finalmask）、mux（Mux 开关）
 *
 * `mode` 在 v2rayN 里同时用于 gRPC 与 XHTTP，具体落到哪个字段取决于**最终**的传输方式，
 * 而查询串里 `mode` 可能出现在 `type` 之前，所以先记在局部变量里，循环结束后再归属。
 */
export function applyQueryOptions(node: ServerNode, query: string): void {
  if (query.length === 0) {
    return;
  }
  let modeText: string = '';
  const pairs: string[] = query.split('&');
  for (let i = 0; i < pairs.length; i++) {
    const pair: string = pairs[i];
    if (pair.length === 0) {
      continue;
    }
    const eqIndex: number = pair.indexOf('=');
    let key: string = eqIndex < 0 ? pair : pair.substring(0, eqIndex);
    let value: string = eqIndex < 0 ? '' : pair.substring(eqIndex + 1);
    key = key.toLowerCase();
    value = percentDecode(value);

    if (key === 'type' || key === 'net') {
      node.transport = transportFromText(value);
    } else if (key === 'security' || key === 'tls') {
      node.security = securityFromText(value);
    } else if (key === 'sni' || key === 'peer') {
      node.sni = value;
    } else if (key === 'host') {
      node.host = value;
    } else if (key === 'path') {
      node.path = value;
    } else if (key === 'servicename') {
      node.serviceName = value;
    } else if (key === 'flow') {
      node.flow = value;
    } else if (key === 'pbk' || key === 'publickey') {
      node.publicKey = value;
    } else if (key === 'sid' || key === 'shortid') {
      node.shortId = value;
    } else if (key === 'spx' || key === 'spiderx') {
      node.spiderX = value;
    } else if (key === 'fp' || key === 'fingerprint') {
      node.fingerprint = value;
    } else if (key === 'alpn') {
      node.alpn = value;
    } else if (key === 'encryption') {
      node.securityCipher = value;
    } else if (key === 'headertype' || key === 'header') {
      // raw 与 kcp 的伪装类型共用链接参数名，按传输方式归属
      if (node.transport === TransportKind.KCP) {
        node.kcpHeaderType = value;
      } else {
        node.rawHeaderType = value;
      }
    } else if (key === 'mode') {
      modeText = value;
    } else if (key === 'extra') {
      node.xhttpExtra = value;
    } else if (key === 'insecure' || key === 'allowinsecure') {
      node.allowInsecure = value.toLowerCase() === 'true' || value === '1';
    } else if (key === 'fm' || key === 'finalmask') {
      node.finalmask = value;
    } else if (key === 'mux') {
      node.muxEnabled = value.toLowerCase() === 'true' || value === '1';
    }
  }

  if (modeText.length > 0) {
    if (node.transport === TransportKind.GRPC) {
      node.grpcMode = modeText;
    } else if (node.transport === TransportKind.XHTTP) {
      node.xhttpMode = modeText;
    }
  }
}

/** 传输层文本 -> 枚举 */
export function transportFromText(text: string): TransportKind {
  const value: string = text.toLowerCase();
  if (value === 'ws' || value === 'websocket') {
    return TransportKind.WS;
  }
  if (value === 'grpc') {
    return TransportKind.GRPC;
  }
  if (value === 'httpupgrade') {
    return TransportKind.HTTP_UPGRADE;
  }
  if (value === 'h2' || value === 'http') {
    return TransportKind.H2;
  }
  if (value === 'quic') {
    return TransportKind.QUIC;
  }
  if (value === 'kcp' || value === 'mkcp') {
    return TransportKind.KCP;
  }
  if (value === 'xhttp' || value === 'splithttp') {
    return TransportKind.XHTTP;
  }
  if (value === 'tcp' || value === 'raw' || value === 'none') {
    return TransportKind.TCP;
  }
  return TransportKind.UNKNOWN;
}

/** 安全层文本 -> 枚举 */
export function securityFromText(text: string): SecurityKind {
  const value: string = text.toLowerCase();
  if (value === 'tls' || value === 'xtls' || value === '1' || value === 'true') {
    return SecurityKind.TLS;
  }
  if (value === 'reality') {
    return SecurityKind.REALITY;
  }
  return SecurityKind.NONE;
}

/**
 * 解析一条分享链接。
 * @param link 分享链接
 * @param id 节点 id（由调用方生成，保持 id 生成策略单一）
 * @param now 当前时间戳
 * @returns 解析成功的节点；不支持的 scheme 或格式错误返回 undefined
 */
export function parseShareLink(link: string, id: NodeId, now: Timestamp): ServerNode | undefined {
  const raw: string = trimToken(link);
  const schemeIndex: number = raw.indexOf('://');
  if (schemeIndex <= 0) {
    return undefined;
  }
  const scheme: string = raw.substring(0, schemeIndex).toLowerCase();
  const protocol: ProxyProtocol = protocolFromScheme(scheme);
  if (protocol === ProxyProtocol.UNKNOWN) {
    return undefined;
  }
  if (protocol === ProxyProtocol.VMESS) {
    return parseVmess(raw, id, now);
  }
  if (protocol === ProxyProtocol.SHADOWSOCKS) {
    return parseShadowsocks(raw, id, now);
  }
  return parseStandardUri(raw, scheme, protocol, id, now);
}

/** vmess://<base64(JSON)> */
function parseVmess(raw: string, id: NodeId, now: Timestamp): ServerNode | undefined {
  const body: string = raw.substring('vmess://'.length);
  const decoded: string = decodeBase64(body);
  if (decoded.length === 0 || !decoded.trim().startsWith('{')) {
    return undefined;
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(decoded) as Object;
  } catch (error) {
    Logger.warn(TAG, 'vmess json parse failed: ' + Logger.describe(error as Object));
    return undefined;
  }
  const node: ServerNode = createEmptyNode(id, now);
  node.protocol = ProxyProtocol.VMESS;
  node.remarks = jsonStr(parsed, 'ps');
  node.address = jsonStr(parsed, 'add');
  node.port = jsonNum(parsed, 'port', DEFAULT_PROXY_PORT);
  node.userId = jsonStr(parsed, 'id');
  node.alterId = jsonNum(parsed, 'aid', 0);
  node.securityCipher = jsonStrOr(parsed, 'scy', 'auto');
  node.transport = transportFromText(jsonStr(parsed, 'net'));
  node.host = jsonStr(parsed, 'host');
  node.path = jsonStr(parsed, 'path');
  node.sni = jsonStr(parsed, 'sni');
  node.alpn = jsonStr(parsed, 'alpn');
  node.fingerprint = jsonStr(parsed, 'fp');
  // vmess 的 type 是「伪装类型」：kcp 与 raw/tcp 共用，按传输方式归属
  const headerText: string = jsonStr(parsed, 'type');
  if (headerText.length > 0) {
    if (node.transport === TransportKind.KCP) {
      node.kcpHeaderType = headerText;
    } else {
      node.rawHeaderType = headerText;
    }
  }
  const tlsText: string = jsonStr(parsed, 'tls');
  if (tlsText.length > 0) {
    node.security = securityFromText(tlsText);
  }
  if (node.address.length === 0) {
    return undefined;
  }
  return node;
}

/** ss://<base64(method:password)>@host:port#name 或 ss://base64(method:password@host:port)#name */
function parseShadowsocks(raw: string, id: NodeId, now: Timestamp): ServerNode | undefined {
  const parts: string[] = splitFragment(raw);
  let body: string = parts[0].substring('ss://'.length);
  const name: string = parts[1];

  // 去掉查询串（plugin 等暂不支持，仅忽略）
  const queryIndex: number = body.indexOf('?');
  if (queryIndex >= 0) {
    body = body.substring(0, queryIndex);
  }

  let credential: string = '';
  let endpoint: string = '';
  const atIndex: number = body.lastIndexOf('@');
  if (atIndex >= 0) {
    credential = body.substring(0, atIndex);
    endpoint = body.substring(atIndex + 1);
    // SIP002：userinfo 可能是 base64(cipher:password)
    if (credential.indexOf(':') < 0) {
      const decoded: string = decodeBase64(normalizeBase64(credential));
      if (decoded.indexOf(':') > 0) {
        credential = decoded;
      }
    }
  } else {
    // 旧格式：整段 base64
    const decoded: string = decodeBase64(normalizeBase64(body));
    const decodedAt: number = decoded.lastIndexOf('@');
    if (decodedAt < 0) {
      return undefined;
    }
    credential = decoded.substring(0, decodedAt);
    endpoint = decoded.substring(decodedAt + 1);
  }

  const colonIndex: number = credential.indexOf(':');
  if (colonIndex < 0) {
    return undefined;
  }
  const endpointParts: string[] = splitHostPort(endpoint);
  if (endpointParts.length !== 2) {
    return undefined;
  }

  const node: ServerNode = createEmptyNode(id, now);
  node.protocol = ProxyProtocol.SHADOWSOCKS;
  node.remarks = name;
  node.securityCipher = credential.substring(0, colonIndex);
  node.password = credential.substring(colonIndex + 1);
  node.address = endpointParts[0];
  node.port = parsePortText(endpointParts[1]);
  if (node.address.length === 0 || node.port <= 0) {
    return undefined;
  }
  return node;
}

/** vless:// / trojan:// / hysteria2:// / socks:// 等 userinfo@host:port?query#name 形式 */
function parseStandardUri(
  raw: string,
  scheme: string,
  protocol: ProxyProtocol,
  id: NodeId,
  now: Timestamp
): ServerNode | undefined {
  const parts: string[] = splitFragment(raw);
  const body: string = parts[0].substring(scheme.length + 3);
  const name: string = parts[1];

  const queryIndex: number = body.indexOf('?');
  const query: string = queryIndex < 0 ? '' : body.substring(queryIndex + 1);
  const authorityAndUser: string = queryIndex < 0 ? body : body.substring(0, queryIndex);

  const atIndex: number = authorityAndUser.lastIndexOf('@');
  if (atIndex < 0) {
    return undefined;
  }
  const userInfo: string = percentDecode(authorityAndUser.substring(0, atIndex));
  const endpoint: string = authorityAndUser.substring(atIndex + 1);
  const endpointParts: string[] = splitHostPort(endpoint);
  if (endpointParts.length !== 2) {
    return undefined;
  }

  const node: ServerNode = createEmptyNode(id, now);
  node.protocol = protocol;
  node.remarks = name;
  node.address = endpointParts[0];
  node.port = parsePortText(endpointParts[1]);
  if (node.address.length === 0 || node.port <= 0) {
    return undefined;
  }

  if (protocol === ProxyProtocol.VLESS) {
    node.userId = userInfo;
    node.security = SecurityKind.TLS;
  } else if (protocol === ProxyProtocol.TROJAN) {
    node.password = userInfo;
    node.security = SecurityKind.TLS;
  } else if (protocol === ProxyProtocol.HYSTERIA2) {
    // hysteria2 的 userinfo 可能形如 `user:pass` 或只有 `pass`
    const colonIndex: number = userInfo.indexOf(':');
    node.password = colonIndex >= 0 ? userInfo.substring(colonIndex + 1) : userInfo;
    if (colonIndex >= 0) {
      node.userId = userInfo.substring(0, colonIndex);
    }
    node.security = SecurityKind.TLS;
  } else if (protocol === ProxyProtocol.SOCKS) {
    const colonIndex: number = userInfo.indexOf(':');
    if (colonIndex >= 0) {
      node.userId = userInfo.substring(0, colonIndex);
      node.password = userInfo.substring(colonIndex + 1);
    } else {
      node.userId = userInfo;
    }
  }

  applyQueryOptions(node, query);
  return node;
}

/** 拆分 host:port，兼容 [ipv6]:port */
function splitHostPort(endpoint: string): string[] {
  const text: string = endpoint.trim();
  if (text.length === 0) {
    return [];
  }
  if (text.startsWith('[')) {
    const closeIndex: number = text.indexOf(']');
    if (closeIndex < 0) {
      return [];
    }
    const host: string = text.substring(1, closeIndex);
    const rest: string = text.substring(closeIndex + 1);
    const port: string = rest.startsWith(':') ? rest.substring(1) : '';
    return [host, port];
  }
  const colonIndex: number = text.lastIndexOf(':');
  if (colonIndex < 0) {
    return [text, DEFAULT_PROXY_PORT.toString()];
  }
  return [text.substring(0, colonIndex), text.substring(colonIndex + 1)];
}

/** 端口文本 -> 数字；非法返回 0 */
function parsePortText(text: string): number {
  const value: number = Number.parseInt(text, 10);
  if (isNaN(value) || value <= 0 || value > 65535) {
    return 0;
  }
  return value;
}

/** 从一段文本里提取全部分享链接行 */
export function extractLinks(text: string): string[] {
  const result: string[] = [];
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = trimToken(lines[i]);
    if (line.indexOf('://') > 0) {
      result.push(line);
    }
  }
  return result;
}

/** 供订阅解析复用的「唯一 id」生成（时间戳 + 序号，避免依赖随机数可复现性问题） */
export function generateId(prefix: string, index: number, now: Timestamp): string {
  return prefix + '-' + now.toString(36) + '-' + index.toString();
}
