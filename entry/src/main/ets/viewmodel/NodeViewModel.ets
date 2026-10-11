/**
 * NodeViewModel.ets
 * 节点列表状态：过滤 / 排序 / 选中 / 延迟测试 / 增删节点。
 * 所有数据先落在私有数组里，再统一重建 @Trace 的 viewNodes，
 * 避免在渲染路径上做排序与过滤。
 */
import { NodeId, ProxyProtocol, Timestamp } from '../model/Types';
import { createEmptyNode, ServerNode } from '../model/ServerNode';
import { dedupeNodes, nodeSummary, validateNode, ValidationResult } from '../service/NodeValidator';
import { generateId, parseShareLink } from '../service/ShareLinkParser';
import { Bridge, LatencyResult } from '../core/Bridge';
import { Logger } from '../utils/Logger';
import { SUBSCRIPTION_ID_MANUAL, SUBSCRIPTION_NAME_MANUAL } from '../constants/Common';

const TAG: string = 'NodeViewModel';
/** 并发测延迟的数量（串行分批，避免一次性打爆网络） */
const LATENCY_BATCH_SIZE: number = 4;
/** 单节点测延迟超时（毫秒） */
const LATENCY_TIMEOUT_MS: number = 3000;

/** 排序字段 */
export enum NodeSortKey {
  DEFAULT = 'default',
  NAME = 'name',
  LATENCY = 'latency'
}

/** 排序方向 */
export enum SortDirection {
  ASC = 'asc',
  DESC = 'desc'
}

/** 节点页 ViewModel */
@ObservedV2
export class NodeViewModel {
  /** 用于渲染的节点列表（已过滤 + 已排序） */
  @Trace viewNodes: ServerNode[] = [];
  /** 过滤关键字 */
  @Trace filterText: string = '';
  @Trace sortKey: NodeSortKey = NodeSortKey.DEFAULT;
  @Trace sortDirection: SortDirection = SortDirection.ASC;
  /** 当前选中节点 id */
  @Trace selectedNodeId: NodeId = '';
  /** 延迟测试进行中 */
  @Trace testing: boolean = false;
  /** 最近一次操作提示（英文短标签，UI 侧决定是否翻译展示） */
  @Trace lastMessage: string = '';

  /** 全量节点（含禁用的，私有，外部只读 viewNodes） */
  private allNodes: ServerNode[] = [];
  private seq: number = 0;
  private seeded: boolean = false;

  /** 幂等初始化：首次调用时注入 Mock 数据，保证 UI 有内容可看 */
  init(): void {
    if (this.seeded) {
      return;
    }
    this.seeded = true;
    this.allNodes = buildMockNodes();
    this.rebuild();
    Logger.info(TAG, 'seeded ' + this.allNodes.length.toString() + ' mock nodes');
  }

  /** 节点总数 */
  totalCount(): number {
    return this.allNodes.length;
  }

  /** 当前可见节点数 */
  visibleCount(): number {
    return this.viewNodes.length;
  }

  /** 取当前选中节点 */
  selectedNode(): ServerNode | undefined {
    return this.findById(this.selectedNodeId);
  }

  /** 按 id 取节点 */
  findById(id: NodeId): ServerNode | undefined {
    const matched: ServerNode[] = this.allNodes.filter((node: ServerNode) => {
      return node.id === id;
    });
    return matched.length > 0 ? matched[0] : undefined;
  }

  /** 设置过滤关键字 */
  setFilter(text: string): void {
    this.filterText = text;
    this.rebuild();
  }

  /** 设置排序 */
  setSort(key: NodeSortKey, direction: SortDirection): void {
    this.sortKey = key;
    this.sortDirection = direction;
    this.rebuild();
  }

  /** 选中节点 */
  selectNode(id: NodeId): void {
    this.selectedNodeId = id;
    const node: ServerNode | undefined = this.findById(id);
    if (node !== undefined) {
      Logger.info(TAG, 'selected ' + nodeSummary(node));
    }
  }

  /** 清空选择 */
  clearSelection(): void {
    this.selectedNodeId = '';
  }

  /** 手动新增节点（来自分享链接或表单） */
  addNodeFromLink(link: string): ServerNode | undefined {
    this.seq = this.seq + 1;
    const id: NodeId = generateId('manual', this.seq, Date.now());
    const node: ServerNode | undefined = parseShareLink(link, id, Date.now());
    if (node === undefined) {
      this.lastMessage = 'parse-failed';
      return undefined;
    }
    const validation: ValidationResult = validateNode(node);
    if (!validation.valid) {
      this.lastMessage = 'invalid-node';
      return undefined;
    }
    node.subscriptionId = SUBSCRIPTION_ID_MANUAL;
    node.subscriptionName = SUBSCRIPTION_NAME_MANUAL;
    this.allNodes.push(node);
    this.rebuild();
    this.lastMessage = 'added';
    return node;
  }

  /** 用订阅解析结果批量替换某订阅的节点（先删旧的，再插入新的） */
  replaceNodesOfSubscription(subscriptionId: string, subscriptionName: string, nodes: ServerNode[]): void {
    const others: ServerNode[] = this.allNodes.filter((node: ServerNode) => {
      return node.subscriptionId !== subscriptionId;
    });
    for (let i = 0; i < nodes.length; i++) {
      const node: ServerNode = nodes[i];
      node.subscriptionId = subscriptionId;
      node.subscriptionName = subscriptionName;
    }
    this.allNodes = dedupeNodes(others.concat(nodes));
    this.rebuild();
  }

  /** 删除节点 */
  removeNode(id: NodeId): void {
    this.allNodes = this.allNodes.filter((node: ServerNode) => {
      return node.id !== id;
    });
    if (this.selectedNodeId === id) {
      this.selectedNodeId = '';
    }
    this.rebuild();
  }

  /** 删除当前订阅下的全部节点 */
  removeNodesOfSubscription(subscriptionId: string): void {
    this.allNodes = this.allNodes.filter((node: ServerNode) => {
      return node.subscriptionId !== subscriptionId;
    });
    const selected: ServerNode | undefined = this.findById(this.selectedNodeId);
    if (selected === undefined) {
      this.selectedNodeId = '';
    }
    this.rebuild();
  }

  /** 更新单个节点的字段（编辑表单用） */
  updateNode(updated: ServerNode): void {
    const next: ServerNode[] = [];
    for (let i = 0; i < this.allNodes.length; i++) {
      const node: ServerNode = this.allNodes[i];
      if (node.id === updated.id) {
        next.push(updated);
      } else {
        next.push(node);
      }
    }
    this.allNodes = next;
    this.rebuild();
  }

  /** 新建一个空节点（供「手动添加」表单绑定） */
  createDraft(): ServerNode {
    this.seq = this.seq + 1;
    return createEmptyNode(generateId('draft', this.seq, Date.now()), Date.now());
  }

  /**
   * 测试全部（或仅可见）节点延迟。
   * @param visibleOnly true 时只测当前过滤结果
   */
  async testAllLatency(visibleOnly: boolean): Promise<void> {
    if (this.testing) {
      return;
    }
    this.testing = true;
    const targets: ServerNode[] = visibleOnly ? this.viewNodes.slice(0) : this.allNodes.slice(0);
    Logger.info(TAG, 'latency test start, ' + targets.length.toString() + ' nodes');
    for (let start = 0; start < targets.length; start = start + LATENCY_BATCH_SIZE) {
      const end: number = Math.min(start + LATENCY_BATCH_SIZE, targets.length);
      const batch: ServerNode[] = targets.slice(start, end);
      for (let i = 0; i < batch.length; i++) {
        await this.testSingleLatency(batch[i]);
      }
      this.rebuild();
    }
    this.testing = false;
    Logger.info(TAG, 'latency test done');
  }

  /** 测试单个节点延迟并写回结果 */
  async testSingleLatency(node: ServerNode): Promise<void> {
    const result: LatencyResult = await Bridge.testLatency(node.address, node.port, LATENCY_TIMEOUT_MS);
    if (result.timeout || result.latencyMs <= 0) {
      node.latencyMs = -1;
    } else {
      node.latencyMs = result.latencyMs;
    }
    node.updatedAt = Date.now();
  }

  /** 重建渲染列表：过滤 -> 排序 -> 赋值（只赋值一次，触发一次刷新） */
  private rebuild(): void {
    const keyword: string = this.filterText.trim().toLowerCase();
    let visible: ServerNode[] = this.allNodes;
    if (keyword.length > 0) {
      visible = this.allNodes.filter((node: ServerNode) => {
        const name: string = node.remarks.toLowerCase();
        const address: string = node.address.toLowerCase();
        const protocol: string = node.protocol.toString();
        return name.indexOf(keyword) >= 0 || address.indexOf(keyword) >= 0 || protocol.indexOf(keyword) >= 0;
      });
    }
    const sorted: ServerNode[] = visible.slice(0);
    if (this.sortKey === NodeSortKey.NAME) {
      sorted.sort((a: ServerNode, b: ServerNode) => {
        return this.sortDirection === SortDirection.ASC
          ? a.remarks.localeCompare(b.remarks)
          : b.remarks.localeCompare(a.remarks);
      });
    } else if (this.sortKey === NodeSortKey.LATENCY) {
      sorted.sort((a: ServerNode, b: ServerNode) => {
        const left: number = a.latencyMs <= 0 ? Number.MAX_SAFE_INTEGER : a.latencyMs;
        const right: number = b.latencyMs <= 0 ? Number.MAX_SAFE_INTEGER : b.latencyMs;
        return this.sortDirection === SortDirection.ASC ? left - right : right - left;
      });
    }
    this.viewNodes = sorted;
  }
}

/** 全局单例：跨页面共享（保证从首页跳转到节点页时状态一致） */
export const nodeViewModel: NodeViewModel = new NodeViewModel();

// ---------------------------------------------------------------------------
// Mock 数据（内核接入前用于填充 UI；MOCK_BRIDGE=false 后可删除）
// ---------------------------------------------------------------------------

/** 构造一条 Mock 节点 */
function mockNode(
  index: number,
  remarks: string,
  protocol: ProxyProtocol,
  address: string,
  port: number,
  subscriptionId: string,
  subscriptionName: string,
  latencyMs: number,
  now: Timestamp
): ServerNode {
  const node: ServerNode = createEmptyNode('mock-node-' + index.toString(), now);
  node.remarks = remarks;
  node.protocol = protocol;
  node.address = address;
  node.port = port;
  node.subscriptionId = subscriptionId;
  node.subscriptionName = subscriptionName;
  node.latencyMs = latencyMs;
  if (protocol === ProxyProtocol.VMESS || protocol === ProxyProtocol.VLESS) {
    node.userId = '00000000-0000-0000-0000-00000000000' + index.toString();
  }
  if (protocol === ProxyProtocol.SHADOWSOCKS) {
    node.securityCipher = 'aes-128-gcm';
    node.password = 'mock-password-' + index.toString();
  }
  if (protocol === ProxyProtocol.TROJAN || protocol === ProxyProtocol.HYSTERIA2) {
    node.password = 'mock-password-' + index.toString();
  }
  return node;
}

/** 生成演示用节点 */
function buildMockNodes(): ServerNode[] {
  const now: Timestamp = Date.now();
  const nodes: ServerNode[] = [
    mockNode(1, '香港 IEPL 01', ProxyProtocol.VMESS, 'hk01.example.com', 443, 'mock-sub-1', '演示机场 A', 86, now),
    mockNode(2, '香港 IEPL 02', ProxyProtocol.VLESS, 'hk02.example.com', 443, 'mock-sub-1', '演示机场 A', 132, now),
    mockNode(3, '日本 东京 01', ProxyProtocol.TROJAN, 'jp01.example.com', 8443, 'mock-sub-1', '演示机场 A', 218, now),
    mockNode(4, '新加坡 01', ProxyProtocol.SHADOWSOCKS, 'sg01.example.com', 8388, 'mock-sub-1', '演示机场 A', 356, now),
    mockNode(5, '美国 洛杉矶 01', ProxyProtocol.HYSTERIA2, 'us01.example.com', 443, 'mock-sub-1', '演示机场 A', 512, now),
    mockNode(6, '台湾 彰化 01', ProxyProtocol.VMESS, 'tw01.example.com', 443, 'mock-sub-1', '演示机场 A', -1, now),
    mockNode(7, '手动节点（本地 socks）', ProxyProtocol.SOCKS, '127.0.0.1', 10808, '', '', 1, now)
  ];
  return nodes;
}
