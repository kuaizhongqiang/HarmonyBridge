/**
 * BytesFormat.ets
 * 字节数与速率的展示格式化。
 * 注意：单位本身（B/KB/MB/GB、/s）不是本地化文案，因此不进 string.json；
 * 需要本地化的部分由调用方拼接 $r('app.string.*')。
 */

const UNITS: string[] = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
const KILO: number = 1024;
/** 速率单位后缀 */
export const SPEED_SUFFIX: string = '/s';

/**
 * 字节数 -> 可读字符串，例如 1536 -> "1.50 KB"。
 * @param bytes 字节数
 * @param fractionDigits 小数位（默认 2）
 */
export function formatBytes(bytes: number, fractionDigits: number = 2): string {
  if (!isFinite(bytes) || bytes <= 0) {
    return '0 B';
  }
  let value: number = bytes;
  let unitIndex: number = 0;
  while (value >= KILO && unitIndex < UNITS.length - 1) {
    value = value / KILO;
    unitIndex = unitIndex + 1;
  }
  if (unitIndex === 0) {
    return value.toFixed(0) + ' ' + UNITS[unitIndex];
  }
  return value.toFixed(fractionDigits) + ' ' + UNITS[unitIndex];
}

/** 速率 -> 可读字符串，例如 1024 -> "1.00 KB/s" */
export function formatSpeed(bytesPerSecond: number, fractionDigits: number = 2): string {
  return formatBytes(bytesPerSecond, fractionDigits) + SPEED_SUFFIX;
}
