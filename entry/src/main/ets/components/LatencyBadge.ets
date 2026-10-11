/**
 * LatencyBadge.ets
 * 延迟徽标：按阈值给出颜色（<200ms 绿 / <500ms 橙 / 其它红 / 未测灰）。
 * 文案来自 string.json：latency_untested / latency_timeout / latency_value。
 */
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme, latencyBackgroundColor, latencyColor } from '../constants/Theme';

/** 延迟徽标 */
@ComponentV2
export struct LatencyBadge {
  /** 延迟毫秒；0=未测，-1=超时 */
  @Param latencyMs: number = 0;

  private text(): ResourceStr {
    if (this.latencyMs === 0) {
      return $r('app.string.latency_untested');
    }
    if (this.latencyMs < 0) {
      return $r('app.string.latency_timeout');
    }
    return $r('app.string.latency_value', this.latencyMs);
  }

  build() {
    Text(this.text())
      .fontSize(FontSizes.caption)
      .fontColor(latencyColor(this.latencyMs))
      .backgroundColor(latencyBackgroundColor(this.latencyMs))
      .borderRadius(Radii.chip)
      .padding({ left: Dimens.tight, right: Dimens.tight, top: 2, bottom: 2 })
      .textAlign(TextAlign.Center)
      .constraintSize({ minWidth: Dimens.latencyBadgeWidth })
  }
}

/** 协议标签 */
@ComponentV2
export struct ProtocolTag {
  @Param text: string = '';

  build() {
    Text(this.text)
      .fontSize(FontSizes.caption)
      .fontColor(Theme.brand)
      .backgroundColor(Theme.brandSoft)
      .borderRadius(Radii.small)
      .padding({ left: Dimens.tight, right: Dimens.tight, top: 2, bottom: 2 })
  }
}
