/**
 * EmptyState.ets
 * 空态占位：标题 + 说明。图标位置用短横线占位（不引入额外图片资源）。
 */
import { Dimens, FontSizes } from '../constants/Dimens';
import { Theme } from '../constants/Theme';

/** 空态 */
@ComponentV2
export struct EmptyState {
  @Param title: Resource = $r('app.string.nodes_empty');
  @Param hint: Resource = $r('app.string.nodes_empty_hint');

  build() {
    Column({ space: Dimens.item }) {
      Text('—')
        .fontSize(FontSizes.display)
        .fontColor(Theme.textTertiary)
      Text(this.title)
        .fontSize(FontSizes.subtitle)
        .fontColor(Theme.textPrimary)
      Text(this.hint)
        .fontSize(FontSizes.caption)
        .fontColor(Theme.textSecondary)
        .textAlign(TextAlign.Center)
        .padding({ left: Dimens.page, right: Dimens.page })
    }
    .width('100%')
    .padding({ top: 48, bottom: 48 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
