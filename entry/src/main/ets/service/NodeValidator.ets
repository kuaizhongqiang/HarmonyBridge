/**
 * NodeValidator.ets
 * 节点合法性校验与去重（纯逻辑，无 UI）。
 * 对应 v2rayN 的「移除无效服务器 / 移除重复服务器」动作。
 */
import { ProxyProtocol, SecurityKind, TransportKind } from '../model/Types';
import { nodeEndpointText, ServerNode } from '../model/ServerNode';
/** 校验结果 */
export interface ValidationResult {
  valid: boolean;
  /** 错误原因（英文短标签，UI 侧按需展示；不上屏时可忽略） */
  issues: string[];
}

/** 单节点校验 */
export function validateNode(node: ServerNode): ValidationResult {
  const issues: string[] = [];
  if (node.address.trim().length === 0) {
    issues.push('missing-address');
  }
  if (node.port <= 0 || node.port > 65535) {
    issues.push('invalid-port');
  }
  if (node.remarks.trim().length === 0) {
    issues.push('missing-remarks');
  }
  if (node.protocol === ProxyProtocol.VMESS || node.protocol === ProxyProtocol.VLESS) {
    if (node.userId.trim().length === 0) {
      issues.push('missing-user-id');
    }
  }
  if (node.protocol === ProxyProtocol.SHADOWSOCKS) {
    if (node.securityCipher.trim().length === 0) {
      issues.push('missing-cipher');
    }
    if (node.password.length === 0) {
      issues.push('missing-password');
    }
  }
  if (node.protocol === ProxyProtocol.TROJAN || node.protocol === ProxyProtocol.HYSTERIA2) {
    if (node.password.length === 0) {
      issues.push('missing-password');
    }
  }
  if (node.security === SecurityKind.REALITY && node.publicKey.trim().length === 0) {
    issues.push('missing-public-key');
  }
  if (node.transport === TransportKind.GRPC && node.serviceName.trim().length === 0) {
    issues.push('missing-grpc-service-name');
  }
  if (node.protocol === ProxyProtocol.UNKNOWN) {
    issues.push('unknown-protocol');
  }
  const result: ValidationResult = { valid: issues.length === 0, issues: issues };
  return result;
}

/**
 * 节点去重关键字：协议 + 地址 + 端口 + 凭据 + 传输 + REALITY 参数。
 *
 * 为什么要带 `publicKey` / `shortId`：同一台服务器上不同 REALITY 站点（不同 pbk/sid）
 * 是**不同的出站配置**，只按 address:port 合并会把它们错误地吞掉。
 */
export function nodeDedupeKey(node: ServerNode): string {
  return node.protocol.toString() + '|' + node.address.toLowerCase() + '|' + node.port.toString() + '|' +
    node.userId + '|' + node.password + '|' + node.transport.toString() + '|' + node.path + '|' +
    node.serviceName + '|' + node.sni + '|' + node.publicKey + '|' + node.shortId;
}

/**
 * 去重：保留首次出现的节点（对齐 v2rayN 的「保留较早的去重」）。
 * @returns 去重后的列表
 */
export function dedupeNodes(nodes: ServerNode[]): ServerNode[] {
  const seen: Set<string> = new Set<string>();
  const result: ServerNode[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const node: ServerNode = nodes[i];
    const key: string = nodeDedupeKey(node);
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(node);
  }
  return result;
}

/** 过滤掉校验不通过的节点 */
export function filterValidNodes(nodes: ServerNode[]): ServerNode[] {
  const result: ServerNode[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const node: ServerNode = nodes[i];
    if (validateNode(node).valid) {
      result.push(node);
    }
  }
  return result;
}

/** 节点摘要文本（日志 / 调试用，例如 vmess 1.2.3.4:443） */
export function nodeSummary(node: ServerNode): string {
  return node.protocol.toString() + ' ' + nodeEndpointText(node);
}
