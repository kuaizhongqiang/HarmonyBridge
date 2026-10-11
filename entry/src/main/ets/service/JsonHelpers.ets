/**
 * JsonHelpers.ets
 * 从「解析结果对象」里安全取值的工具。
 * 背景：ArkTS 严格模式禁止 `any`，也不保证 `as Record<string, string>` 的转换结果可索引，
 * 因此这里返回可空类型，由调用方做非空判断，最终得到明确的 string / number。
 *
 * 实现说明：ArkTS 禁止对声明为 `Object` 的值做下标访问（arkts-no-props-by-index），
 * 但允许对 `Record<string, Object>` 做下标访问。所以三个取值函数在**入口处**
 * 先把 Object 收窄成 Record（JSON.parse 的结果本来就是「未知形状的 JSON 对象」），
 * 对外签名仍保持 Object，避免把 Record 类型扩散到 TrafficMonitor / ShareLinkParser 等调用方。
 */
function asFields(source: Object): Record<string, Object> {
  return source as Record<string, Object>;
}

/** 取字符串；键不存在或类型不符时返回空串 */
export function jsonStr(source: Object, key: string): string {
  const fields: Record<string, Object> = asFields(source);
  const value: Object | undefined = fields[key];
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value as string;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return value.toString();
  }
  return '';
}

/** 取字符串；缺失时返回 fallback */
export function jsonStrOr(source: Object, key: string, fallback: string): string {
  const value: string = jsonStr(source, key);
  if (value.length === 0) {
    return fallback;
  }
  return value;
}

/** 取数字；缺失或不是数字时返回 fallback */
export function jsonNum(source: Object, key: string, fallback: number): number {
  const fields: Record<string, Object> = asFields(source);
  const value: Object | undefined = fields[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value === 'number') {
    return value as number;
  }
  if (typeof value === 'string') {
    const text: string = value as string;
    const parsed: number = Number.parseInt(text, 10);
    if (isNaN(parsed)) {
      return fallback;
    }
    return parsed;
  }
  return fallback;
}

/** 取布尔；兼容 true / "true" / 1 */
export function jsonBool(source: Object, key: string, fallback: boolean): boolean {
  const fields: Record<string, Object> = asFields(source);
  const value: Object | undefined = fields[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  if (typeof value === 'string') {
    return (value as string).toLowerCase() === 'true';
  }
  if (typeof value === 'number') {
    return (value as number) !== 0;
  }
  return fallback;
}
