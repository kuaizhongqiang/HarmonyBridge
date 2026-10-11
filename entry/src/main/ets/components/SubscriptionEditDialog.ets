/**
 * SubscriptionEditDialog.ets
 * 订阅新增 / 编辑弹窗（CustomDialog）。名称、地址、启用、自动更新四项。
 * 由 SubscriptionsPage 通过 CustomDialogController 打开；确认后回调父页面写入 ViewModel。
 */
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';

@CustomDialog
export struct SubscriptionEditDialog {
  /** 弹窗控制器（框架注入） */
  controller?: CustomDialogController;
  /** 是否编辑模式（决定标题文案） */
  @Prop editing: boolean = false;
  /** 初始名称 */
  @Prop initialName: string = '';
  /** 初始地址 */
  @Prop initialUrl: string = '';
  /** 初始是否启用 */
  @Prop initialEnabled: boolean = true;
  /** 初始自动更新 */
  @Prop initialAutoUpdate: boolean = false;
  /** 确认回调 */
  onConfirm: (name: string, url: string, enabled: boolean, autoUpdate: boolean) => void = () => {
  };

  @State name: string = '';
  @State url: string = '';
  @State enabled: boolean = true;
  @State autoUpdate: boolean = false;

  aboutToAppear(): void {
    this.name = this.initialName;
    this.url = this.initialUrl;
    this.enabled = this.initialEnabled;
    this.autoUpdate = this.initialAutoUpdate;
  }

  build() {
    Column({ space: Dimens.item }) {
      Text(this.editing ? $r('app.string.subs_dialog_edit_title') : $r('app.string.subs_dialog_add_title'))
        .fontSize(FontSizes.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .width('100%')

      Column({ space: Dimens.tight }) {
        Text($r('app.string.subs_field_name'))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textSecondary)
        TextInput({ text: this.name, placeholder: $r('app.string.subs_name_hint') })
          .fontSize(FontSizes.body)
          .backgroundColor(Theme.surfaceAlt)
          .borderRadius(Radii.small)
          .onChange((value: string) => {
            this.name = value;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: Dimens.tight }) {
        Text($r('app.string.subs_field_url'))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textSecondary)
        TextInput({ text: this.url, placeholder: $r('app.string.subs_url_hint') })
          .fontSize(FontSizes.body)
          .backgroundColor(Theme.surfaceAlt)
          .borderRadius(Radii.small)
          .onChange((value: string) => {
            this.url = value;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row() {
        Text($r('app.string.subs_field_enabled'))
          .fontSize(FontSizes.body)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.enabled })
          .selectedColor(Theme.brand)
          .onChange((isOn: boolean) => {
            this.enabled = isOn;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text($r('app.string.subs_field_auto_update'))
          .fontSize(FontSizes.body)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoUpdate })
          .selectedColor(Theme.brand)
          .onChange((isOn: boolean) => {
            this.autoUpdate = isOn;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: Dimens.item }) {
        Button($r('app.string.subs_cancel'))
          .fontSize(FontSizes.body)
          .backgroundColor(Theme.surfaceAlt)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.subs_save'))
          .fontSize(FontSizes.body)
          .backgroundColor(Theme.brand)
          .fontColor(Theme.textOnBrand)
          .layoutWeight(1)
          .enabled(this.name.trim().length > 0 && this.url.trim().length > 0)
          .onClick(() => {
            this.onConfirm(this.name.trim(), this.url.trim(), this.enabled, this.autoUpdate);
            this.controller?.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Dimens.page)
    .backgroundColor(Theme.surface)
    .borderRadius(Radii.card)
  }
}
