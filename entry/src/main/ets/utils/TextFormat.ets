/**
 * TextFormat.ets
 * 需要 resourceManager 参与的本地化文本拼接工具。
 *
 * 为什么用「资源名字符串」而不是 $r()：
 * ResourceManager.getStringSync(resource: Resource) 这个重载自 API 20 起已废弃，
 * 官方建议改用 getStringSync(resId: number) / getStringByNameSync(resName: string)。
 * $r() 返回的 Resource 是不透明对象，拿不到稳定数字 id，因此统一用资源名调用
 * getStringByNameSync('app.string.xxx')——它没有废弃，且多语言解析规则一致。
 */
import { resourceManager } from '@kit.LocalizationKit';
import { RelativeTime, RelativeUnit } from './DateFormat';

/** 命名空间前缀，避免每次手写 */
export const STRING_PREFIX: string = 'app.string.';

/** 把简称补全成全名 */
function fullName(name: string): string {
  return name.startsWith(STRING_PREFIX) ? name : STRING_PREFIX + name;
}

/**
 * 读取字符串资源；资源缺失时返回资源名本身（调用方会看到可诊断的占位文本，而不是崩溃）。
 * @param mgr 资源管理器（来自 UIContext.getHostContext()?.resourceManager）
 * @param name 资源名，可写全名 'app.string.x' 或简称 'x'
 */
export function stringOf(mgr: resourceManager.ResourceManager, name: string): string {
  try {
    return mgr.getStringByNameSync(fullName(name));
  } catch (error) {
    return name;
  }
}

/**
 * 读取带格式参数的字符串资源（如 "共 %d 个节点"）。
 * @param args 依次替换 %d / %s / %f
 */
export function stringOfArgs(
  mgr: resourceManager.ResourceManager,
  name: string,
  args: Array<string | number>
): string {
  try {
    return mgr.getStringByNameSync(fullName(name), ...args);
  } catch (error) {
    return name;
  }
}

/**
 * 把相对时间结构翻译成当前语言的一句话。
 */
export function relativeTimeText(mgr: resourceManager.ResourceManager, relative: RelativeTime): string {
  if (relative.unit === RelativeUnit.NEVER) {
    return stringOf(mgr, 'common_relative_never');
  }
  if (relative.unit === RelativeUnit.JUST_NOW) {
    return stringOf(mgr, 'common_relative_just_now');
  }
  if (relative.unit === RelativeUnit.MINUTES) {
    return stringOfArgs(mgr, 'common_relative_minutes', [relative.value]);
  }
  if (relative.unit === RelativeUnit.HOURS) {
    return stringOfArgs(mgr, 'common_relative_hours', [relative.value]);
  }
  return stringOfArgs(mgr, 'common_relative_days', [relative.value]);
}
