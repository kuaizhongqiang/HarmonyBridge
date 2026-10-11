/**
 * SubscriptionViewModel.ets
 * 订阅页状态：增删改订阅、手动更新（拉取 + 解析 + 写回节点）、剪贴板导入。
 * 与 NodeViewModel 是单向依赖（订阅 -> 节点），避免出现双向引用。
 */
import { SubscriptionId, Timestamp } from '../model/Types';
import { createSubscription, isNeverUpdated, Subscription } from '../model/Subscription';
import { ServerNode } from '../model/ServerNode';
import { fetchAndParseSubscription, parseClipboardPayload } from '../service/SubscriptionService';
import { SubscriptionParseResult } from '../service/SubscriptionParser';
import { generateId } from '../service/ShareLinkParser';
import { Clipboard } from '../utils/Clipboard';
import { Logger } from '../utils/Logger';
import { SUBSCRIPTION_ID_CLIPBOARD, SUBSCRIPTION_NAME_CLIPBOARD } from '../constants/Common';
import { nodeViewModel } from './NodeViewModel';

const TAG: string = 'SubscriptionViewModel';

/** 订阅页 ViewModel */
@ObservedV2
export class SubscriptionViewModel {
  @Trace subscriptions: Subscription[] = [];
  /** 正在更新的订阅 id 集合（空串表示「全部更新」进行中） */
  @Trace updatingIds: string[] = [];
  /** 最近一次操作结果（英文短标签，UI 侧决定文案） */
  @Trace lastMessage: string = '';
  /** 最近一次导入/更新得到的节点数 */
  @Trace lastNodeCount: number = 0;

  private seq: number = 0;
  private seeded: boolean = false;

  /** 幂等初始化：注入演示订阅 */
  init(): void {
    if (this.seeded) {
      return;
    }
    this.seeded = true;
    if (this.subscriptions.length === 0) {
      this.subscriptions = [buildMockSubscription()];
    }
    Logger.info(TAG, 'seeded ' + this.subscriptions.length.toString() + ' subscriptions');
  }

  /** 新增订阅；返回新建的订阅 */
  addSubscription(name: string, url: string): Subscription {
    this.seq = this.seq + 1;
    const id: SubscriptionId = generateId('sub', this.seq, Date.now());
    const sub: Subscription = createSubscription(id, name, url, Date.now());
    this.subscriptions = this.subscriptions.concat([sub]);
    Logger.info(TAG, 'added subscription ' + name);
    return sub;
  }

  /** 更新订阅的元信息（名称 / 地址 / 开关 / 自动更新） */
  updateSubscription(updated: Subscription): void {
    const next: Subscription[] = [];
    for (let i = 0; i < this.subscriptions.length; i++) {
      const sub: Subscription = this.subscriptions[i];
      next.push(sub.id === updated.id ? updated : sub);
    }
    this.subscriptions = next;
  }

  /** 删除订阅，并同步删除它带来的节点 */
  removeSubscription(id: SubscriptionId): void {
    this.subscriptions = this.subscriptions.filter((sub: Subscription) => {
      return sub.id !== id;
    });
    nodeViewModel.removeNodesOfSubscription(id);
  }

  /** 取订阅 */
  findById(id: SubscriptionId): Subscription | undefined {
    const matched: Subscription[] = this.subscriptions.filter((sub: Subscription) => {
      return sub.id === id;
    });
    return matched.length > 0 ? matched[0] : undefined;
  }

  /** 是否正在更新 */
  isUpdating(id: SubscriptionId): boolean {
    return this.updatingIds.indexOf(id) >= 0;
  }

  /** 立即更新一个订阅（拉取 -> 解析 -> 写回 NodeViewModel） */
  async updateSubscriptionNow(id: SubscriptionId): Promise<void> {
    const sub: Subscription | undefined = this.findById(id);
    if (sub === undefined || this.isUpdating(id)) {
      return;
    }
    this.updatingIds = this.updatingIds.concat([id]);
    this.lastMessage = '';
    const startedAt: Timestamp = Date.now();
    try {
      const result: SubscriptionParseResult = await fetchAndParseSubscription(sub.url, startedAt);
      const nextSub: Subscription = this.findById(id) ?? sub;
      if (result.error.length > 0 && result.nodes.length === 0) {
        nextSub.lastError = result.error;
        nextSub.lastUpdatedAt = startedAt;
        this.lastMessage = 'update-failed';
        this.lastNodeCount = 0;
        Logger.error(TAG, 'update failed: ' + sub.name + ' -> ' + result.error);
      } else {
        this.applyNodes(nextSub, result.nodes, startedAt);
        this.lastMessage = 'update-done';
        this.lastNodeCount = result.nodes.length;
        Logger.info(TAG, 'update done: ' + sub.name + ' -> ' + result.nodes.length.toString());
      }
      this.updateSubscription(nextSub);
    } finally {
      this.updatingIds = this.updatingIds.filter((value: string) => {
        return value !== id;
      });
    }
  }

  /** 更新全部启用的订阅 */
  async updateAll(): Promise<void> {
    const targets: Subscription[] = this.subscriptions.filter((sub: Subscription) => {
      return sub.enabled;
    });
    for (let i = 0; i < targets.length; i++) {
      await this.updateSubscriptionNow(targets[i].id);
    }
  }

  /**
   * 从剪贴板导入：
   * 1) 如果内容本身是订阅地址（http/https），直接新增一个订阅；
   * 2) 否则尝试按分享链接 / base64 列表解析成节点。
   */
  async importFromClipboard(): Promise<void> {
    const text: string = await Clipboard.readText();
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      this.lastMessage = 'clipboard-empty';
      return;
    }
    if (isSubscriptionUrl(trimmed)) {
      this.addSubscription(deriveNameFromUrl(trimmed), trimmed);
      this.lastMessage = 'clipboard-subscription';
      this.lastNodeCount = 0;
      return;
    }
    const result: SubscriptionParseResult = parseClipboardPayload(trimmed, Date.now());
    if (result.nodes.length === 0) {
      this.lastMessage = 'clipboard-empty';
      this.lastNodeCount = 0;
      return;
    }
    nodeViewModel.replaceNodesOfSubscription(
      SUBSCRIPTION_ID_CLIPBOARD,
      SUBSCRIPTION_NAME_CLIPBOARD,
      result.nodes
    );
    this.lastMessage = 'clipboard-imported';
    this.lastNodeCount = result.nodes.length;
  }

  /** 把解析出来的节点写回 NodeViewModel，并同步订阅的统计字段 */
  private applyNodes(sub: Subscription, nodes: ServerNode[], updatedAt: Timestamp): void {
    nodeViewModel.replaceNodesOfSubscription(sub.id, sub.name, nodes);
    sub.nodeCount = nodes.length;
    sub.lastUpdatedAt = updatedAt;
    sub.lastError = '';
  }
}

/** 全局单例 */
export const subscriptionViewModel: SubscriptionViewModel = new SubscriptionViewModel();

/** 是否像订阅地址 */
function isSubscriptionUrl(text: string): boolean {
  const lower: string = text.toLowerCase();
  if (lower.indexOf('://') > 0) {
    // 排掉分享链接
    return lower.startsWith('http://') || lower.startsWith('https://');
  }
  return false;
}

/** 从订阅 url 猜一个名称 */
function deriveNameFromUrl(url: string): string {
  const noScheme: string = url.substring(url.indexOf('://') + 3);
  const slashIndex: number = noScheme.indexOf('/');
  const host: string = slashIndex < 0 ? noScheme : noScheme.substring(0, slashIndex);
  return host.length > 0 ? host : 'subscription';
}

/** 演示订阅（内核/网络接入前填充 UI 用） */
function buildMockSubscription(): Subscription {
  const now: Timestamp = Date.now();
  const sub: Subscription = createSubscription('mock-sub-1', '演示机场 A', 'https://example.com/sub?token=demo', now);
  sub.nodeCount = 6;
  sub.lastUpdatedAt = now - 3600 * 1000;
  return sub;
}
