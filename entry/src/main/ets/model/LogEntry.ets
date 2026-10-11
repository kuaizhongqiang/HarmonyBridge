/**
 * LogEntry.ets
 * 日志条目模型：UI 直接渲染的不可变结构（由 LogViewModel 维护列表）。
 */
import { LogId, LogLevel, Timestamp } from './Types';

/** 一条日志 */
export interface LogEntry {
  id: LogId;
  /** 产生时间戳（毫秒） */
  timestamp: Timestamp;
  level: LogLevel;
  /** 来源标签，例如 Core / Bridge / Vpn */
  tag: string;
  message: string;
}

/** 日志级别的数值权重，用于过滤时比较 */
export function logLevelWeight(level: LogLevel): number {
  if (level === LogLevel.DEBUG) {
    return 10;
  }
  if (level === LogLevel.INFO) {
    return 20;
  }
  if (level === LogLevel.WARN) {
    return 30;
  }
  return 40;
}
