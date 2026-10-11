/**
 * Subscription.ets
 * 订阅（机场）模型：对齐 v2rayN 的 SubItem（名称 / 地址 / 是否启用 / 自动更新 / 节点数 / 最近更新时间）。
 */
import { SubscriptionId, Timestamp } from './Types';

/** 订阅项 */
export interface Subscription {
  id: SubscriptionId;
  /** 订阅名称 */
  name: string;
  /** 订阅地址 */
  url: string;
  /** 是否启用 */
  enabled: boolean;
  /** 是否自动更新 */
  autoUpdate: boolean;
  /** 自动更新间隔（小时） */
  autoUpdateIntervalHours: number;
  /** 最近更新结果：节点数 */
  nodeCount: number;
  /** 最近一次更新时间戳（毫秒）；0 表示从未更新 */
  lastUpdatedAt: Timestamp;
  /** 最近一次更新的错误信息；空串表示成功 */
  lastError: string;
  createdAt: Timestamp;
}

/** 构造一个新订阅 */
export function createSubscription(
  id: SubscriptionId,
  name: string,
  url: string,
  now: Timestamp
): Subscription {
  const sub: Subscription = {
    id: id,
    name: name,
    url: url,
    enabled: true,
    autoUpdate: false,
    autoUpdateIntervalHours: 12,
    nodeCount: 0,
    lastUpdatedAt: 0,
    lastError: '',
    createdAt: now
  };
  return sub;
}

/** 是否从未更新过 */
export function isNeverUpdated(sub: Subscription): boolean {
  return sub.lastUpdatedAt <= 0;
}
