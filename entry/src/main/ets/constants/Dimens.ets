/**
 * Dimens.ets
 * 尺寸常量：把 resources/base/element/float.json 里定义的 vp 尺寸暴露成 $r('app.float.*')，
 * UI 层只引用这里，避免散落的魔法数字。
 */

/** 字号 */
export class FontSizes {
  static readonly display: Resource = $r('app.float.font_display');
  static readonly title: Resource = $r('app.float.font_title');
  static readonly subtitle: Resource = $r('app.float.font_subtitle');
  static readonly body: Resource = $r('app.float.font_body');
  static readonly caption: Resource = $r('app.float.font_caption');
}

/** 圆角 */
export class Radii {
  static readonly card: Resource = $r('app.float.radius_card');
  static readonly chip: Resource = $r('app.float.radius_chip');
  static readonly small: Resource = $r('app.float.radius_small');
}

/** 间距与关键尺寸（数值型，便于参与四则运算） */
export class Dimens {
  static readonly page: number = 16;
  static readonly card: number = 14;
  static readonly item: number = 10;
  static readonly tight: number = 6;

  static readonly connectButton: number = 168;
  static readonly navBar: number = 56;
  static readonly titleBar: number = 52;
  static readonly latencyBadgeWidth: number = 64;
}
