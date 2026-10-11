/**
 * DateFormat.ets
 * 时间与日期格式化：日志时间戳、订阅「上次更新」的绝对时间与相对时间。
 * 相对时间需要本地化文案，本文件返回「单位 + 数值」结构，由调用方（UI）拼接 $r('app.string.*')。
 */
import { Timestamp } from '../model/Types';

/** 相对时间的单位 */
export enum RelativeUnit {
  NEVER = 'never',
  JUST_NOW = 'just_now',
  MINUTES = 'minutes',
  HOURS = 'hours',
  DAYS = 'days'
}

/** 相对时间结果 */
export interface RelativeTime {
  unit: RelativeUnit;
  value: number;
}

/** 两位补零 */
function pad2(value: number): string {
  if (value < 10) {
    return '0' + value.toString();
  }
  return value.toString();
}

/** 毫秒时间戳 -> "MM-dd HH:mm" */
export function formatShortDateTime(timestamp: Timestamp): string {
  if (timestamp <= 0) {
    return '';
  }
  const date: Date = new Date(timestamp);
  return pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) + ' ' + pad2(date.getHours()) + ':' +
    pad2(date.getMinutes());
}

/** 毫秒时间戳 -> "HH:mm:ss"（日志行） */
export function formatLogTime(timestamp: Timestamp): string {
  if (timestamp <= 0) {
    return '';
  }
  const date: Date = new Date(timestamp);
  return pad2(date.getHours()) + ':' + pad2(date.getMinutes()) + ':' + pad2(date.getSeconds());
}

/** 毫秒时间戳 -> "yyyy-MM-dd HH:mm:ss"（复制到剪贴板时用） */
export function formatFullDateTime(timestamp: Timestamp): string {
  if (timestamp <= 0) {
    return '';
  }
  const date: Date = new Date(timestamp);
  return date.getFullYear().toString() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) + ' ' +
    pad2(date.getHours()) + ':' + pad2(date.getMinutes()) + ':' + pad2(date.getSeconds());
}

/** 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 从未 */
export function relativeTime(timestamp: Timestamp, now: Timestamp): RelativeTime {
  if (timestamp <= 0) {
    const neverResult: RelativeTime = { unit: RelativeUnit.NEVER, value: 0 };
    return neverResult;
  }
  const diffSeconds: number = Math.floor((now - timestamp) / 1000);
  if (diffSeconds < 60) {
    const justNowResult: RelativeTime = { unit: RelativeUnit.JUST_NOW, value: 0 };
    return justNowResult;
  }
  const diffMinutes: number = Math.floor(diffSeconds / 60);
  if (diffMinutes < 60) {
    const minutesResult: RelativeTime = { unit: RelativeUnit.MINUTES, value: diffMinutes };
    return minutesResult;
  }
  const diffHours: number = Math.floor(diffMinutes / 60);
  if (diffHours < 24) {
    const hoursResult: RelativeTime = { unit: RelativeUnit.HOURS, value: diffHours };
    return hoursResult;
  }
  const daysResult: RelativeTime = { unit: RelativeUnit.DAYS, value: Math.floor(diffHours / 24) };
  return daysResult;
}
