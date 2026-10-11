/**
 * Theme.ets
 * 主题常量：把 resources/base/element/color.json（含 dark 限定目录）里的颜色
 * 统一暴露成 $r('app.color.*')，UI 层只引用这里，不出现硬编码色值。
 */

/** 颜色（浅色 / 深色由系统 qualifier 自动选择，无需条件分支） */
export class Theme {
  // 背景与容器
  static readonly bg: Resource = $r('app.color.app_bg');
  static readonly surface: Resource = $r('app.color.app_surface');
  static readonly surfaceAlt: Resource = $r('app.color.app_surface_alt');
  static readonly divider: Resource = $r('app.color.app_divider');

  // 品牌色
  static readonly brand: Resource = $r('app.color.brand');
  static readonly brandPressed: Resource = $r('app.color.brand_pressed');
  static readonly brandOn: Resource = $r('app.color.brand_on');
  static readonly brandSoft: Resource = $r('app.color.brand_soft');

  // 文本
  static readonly textPrimary: Resource = $r('app.color.text_primary');
  static readonly textSecondary: Resource = $r('app.color.text_secondary');
  static readonly textTertiary: Resource = $r('app.color.text_tertiary');
  static readonly textOnBrand: Resource = $r('app.color.text_on_brand');

  // 状态
  static readonly success: Resource = $r('app.color.state_success');
  static readonly error: Resource = $r('app.color.state_error');
  static readonly warning: Resource = $r('app.color.state_warning');
  static readonly idle: Resource = $r('app.color.state_idle');

  // 延迟徽标
  static readonly latencyFast: Resource = $r('app.color.latency_fast');
  static readonly latencyMedium: Resource = $r('app.color.latency_medium');
  static readonly latencySlow: Resource = $r('app.color.latency_slow');
  static readonly latencyUnknown: Resource = $r('app.color.latency_unknown');
  static readonly latencyFastBg: Resource = $r('app.color.latency_fast_bg');
  static readonly latencyMediumBg: Resource = $r('app.color.latency_medium_bg');
  static readonly latencySlowBg: Resource = $r('app.color.latency_slow_bg');
  static readonly latencyUnknownBg: Resource = $r('app.color.latency_unknown_bg');

  // 日志级别
  static readonly logDebug: Resource = $r('app.color.log_debug');
  static readonly logInfo: Resource = $r('app.color.log_info');
  static readonly logWarn: Resource = $r('app.color.log_warn');
  static readonly logError: Resource = $r('app.color.log_error');
}

/** 延迟阈值（毫秒）：< FAST 视为优，< MEDIUM 视为良，其余视为差 */
export const LATENCY_FAST_MS: number = 200;
export const LATENCY_MEDIUM_MS: number = 500;

/** 文本颜色工具：按延迟给出徽标前景色 */
export function latencyColor(latencyMs: number): Resource {
  if (latencyMs <= 0) {
    return Theme.latencyUnknown;
  }
  if (latencyMs < LATENCY_FAST_MS) {
    return Theme.latencyFast;
  }
  if (latencyMs < LATENCY_MEDIUM_MS) {
    return Theme.latencyMedium;
  }
  return Theme.latencySlow;
}

/** 背景颜色工具：按延迟给出徽标底色 */
export function latencyBackgroundColor(latencyMs: number): Resource {
  if (latencyMs <= 0) {
    return Theme.latencyUnknownBg;
  }
  if (latencyMs < LATENCY_FAST_MS) {
    return Theme.latencyFastBg;
  }
  if (latencyMs < LATENCY_MEDIUM_MS) {
    return Theme.latencyMediumBg;
  }
  return Theme.latencySlowBg;
}
