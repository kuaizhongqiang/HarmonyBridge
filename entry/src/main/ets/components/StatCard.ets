/**
 * StatCard.ets
 * 指标卡：标题 + 数值 + 可选副标题。首页的「上传/下载速度、累计流量」用它排成 2x2 网格。
 */
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';

/** 指标卡 */
@ComponentV2
export struct StatCard {
  @Param label: Resource = $r('app.string.home_up_speed');
  @Param value: string = '';
  @Param subValue: string = '';
  @Param valueColor: Resource = Theme.textPrimary;

  build() {
    Column({ space: Dimens.tight }) {
      Text(this.label)
        .fontSize(FontSizes.caption)
        .fontColor(Theme.textSecondary)
        .maxLines(1)
      Text(this.value)
        .fontSize(FontSizes.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.valueColor)
        .maxLines(1)
      if (this.subValue.length > 0) {
        Text(this.subValue)
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textTertiary)
          .maxLines(1)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(Dimens.item)
    .layoutWeight(1)
    .backgroundColor(Theme.surfaceAlt)
    .borderRadius(Radii.small)
  }
}
