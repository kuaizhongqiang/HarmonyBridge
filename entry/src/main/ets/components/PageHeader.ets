/**
 * PageHeader.ets
 * 通用标题栏：左侧返回（可选）+ 标题 + 右侧动作。
 *
 * 为什么右侧动作不用 @BuilderParam：
 * ArkTS 状态管理 V2（@ComponentV2）目前不支持把「本组件的 @Builder 方法」直接赋给
 * @BuilderParam 字段这种默认值写法，跨组件 builder 注入在 V2 下不稳定。
 * 因此这里用两种受控方式替代：
 *   1) trailingText / onTrailingTap：右侧一个文字按钮（最常用）；
 *   2) 页面确实需要复杂动作时，自己在标题行里画，不使用本组件。
 */
import { Dimens, FontSizes } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { RouterHelper } from '../constants/Routes';

/** 通用标题栏 */
@ComponentV2
export struct PageHeader {
  /** 标题文案 */
  @Param title: Resource = $r('app.string.home_title');
  /** 是否显示返回按钮 */
  @Param showBack: boolean = true;
  /** 右侧动作文案；不传则不显示 */
  @Param trailingText: Resource | undefined = undefined;
  /** 右侧动作是否可用（置灰用） */
  @Param trailingEnabled: boolean = true;
  /** 右侧动作回调 */
  @Event onTrailingTap: () => void = () => {
  };

  build() {
    Row() {
      if (this.showBack) {
        Text($r('app.string.common_back'))
          .fontSize(FontSizes.body)
          .fontColor(Theme.brand)
          .margin({ right: Dimens.item })
          .onClick(() => {
            RouterHelper.back(this.getUIContext().getRouter());
          })
      }
      Text(this.title)
        .fontSize(FontSizes.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
      if (this.trailingText !== undefined) {
        Text(this.trailingText)
          .fontSize(FontSizes.caption)
          .fontColor(this.trailingEnabled ? Theme.brand : Theme.textTertiary)
          .onClick(() => {
            if (this.trailingEnabled) {
              this.onTrailingTap();
            }
          })
      }
    }
    .width('100%')
    .height(Dimens.titleBar)
    .padding({ left: Dimens.page, right: Dimens.page })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Theme.bg)
  }
}
