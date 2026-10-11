/**
 * SettingRow.ets
 * 设置页的三类行：
 *   - SettingSwitchRow：标题 + 副标题 + Toggle
 *   - SettingValueRow：标题 + 右侧值 + 点击
 *   - SettingTextRow：标题 + 输入框
 * 全部通过 @Param / @Event 与外部通信，不在组件内部持有业务状态。
 */
import { Dimens, FontSizes } from '../constants/Dimens';
import { Theme } from '../constants/Theme';

/** 开关行 */
@ComponentV2
export struct SettingSwitchRow {
  @Param title: Resource = $r('app.string.settings_title');
  @Param subtitle: Resource | undefined = undefined;
  @Param checked: boolean = false;
  @Event onToggle: (value: boolean) => void = (value: boolean) => {
  };

  build() {
    Row() {
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(FontSizes.body)
          .fontColor(Theme.textPrimary)
        if (this.subtitle !== undefined) {
          Text(this.subtitle)
            .fontSize(FontSizes.caption)
            .fontColor(Theme.textSecondary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .selectedColor(Theme.brand)
        .onChange((isOn: boolean) => {
          this.onToggle(isOn);
        })
    }
    .width('100%')
    .padding({ top: Dimens.item, bottom: Dimens.item })
    .alignItems(VerticalAlign.Center)
  }
}

/** 值行（点击进入二级选择） */
@ComponentV2
export struct SettingValueRow {
  @Param title: Resource = $r('app.string.settings_title');
  @Param value: string = '';
  @Param clickable: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Row() {
      Text(this.title)
        .fontSize(FontSizes.body)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
      Text(this.value)
        .fontSize(FontSizes.body)
        .fontColor(Theme.textSecondary)
        .maxLines(1)
      if (this.clickable) {
        Text('›')
          .fontSize(FontSizes.subtitle)
          .fontColor(Theme.textTertiary)
          .margin({ left: Dimens.tight })
      }
    }
    .width('100%')
    .padding({ top: Dimens.item, bottom: Dimens.item })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.clickable) {
        this.onTap();
      }
    })
  }
}

/** 文本输入行 */
@ComponentV2
export struct SettingTextRow {
  @Param title: Resource = $r('app.string.settings_title');
  @Param hint: Resource = $r('app.string.settings_dns_hint');
  @Param value: string = '';
  @Event onValueChange: (value: string) => void = (value: string) => {
  };

  build() {
    Column({ space: Dimens.tight }) {
      Text(this.title)
        .fontSize(FontSizes.body)
        .fontColor(Theme.textPrimary)
      TextInput({ text: this.value, placeholder: this.hint })
        .fontSize(FontSizes.body)
        .backgroundColor(Theme.surfaceAlt)
        .borderRadius($r('app.float.radius_small'))
        .onChange((value: string) => {
          this.onValueChange(value);
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: Dimens.item, bottom: Dimens.item })
  }
}

/** 分组标题 */
@ComponentV2
export struct SettingGroupTitle {
  @Param title: Resource = $r('app.string.settings_title');

  build() {
    Text(this.title)
      .fontSize(FontSizes.caption)
      .fontColor(Theme.textSecondary)
      .width('100%')
      .padding({ top: Dimens.card, bottom: Dimens.tight })
  }
}
