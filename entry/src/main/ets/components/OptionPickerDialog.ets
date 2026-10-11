/**
 * OptionPickerDialog.ets
 * 通用单选弹窗，设置页的路由模式 / 分应用代理模式 / 日志级别共用。
 *
 * 设计要点：
 * 1) 选项文案通过 `labels: string[]` 传入（页面 aboutToAppear 时按当前语言求值一次），
 *    而不是传 Resource 数组或「运行时替换列表」，避免 @Prop 只构造时求值导致不同步；
 * 2) 选项的 key 在弹窗内部按 kind 固定枚举（routing / appProxy / logLevel），
 *    所以调用方只需要给 labels 顺序与 selectedKey，不需要自己拼 key。
 *
 * labels 顺序约定：
 *   ROUTING   : [global, rule, direct]
 *   APP_PROXY : [off, allowList, blockList]
 *   LOG_LEVEL : [debug, info, warn, error]
 */
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { AppProxyMode, LogLevel, RoutingMode } from '../model/Types';

/** 选择器类别 */
export enum PickerKind {
  ROUTING = 'routing',
  APP_PROXY = 'appProxy',
  LOG_LEVEL = 'logLevel'
}

/** 内部单选行 */
@ComponentV2
struct PickerRow {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Event onPick: () => void = () => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(FontSizes.body)
        .fontColor(this.selected ? Theme.brand : Theme.textPrimary)
        .layoutWeight(1)
      if (this.selected) {
        Text('✓')
          .fontSize(FontSizes.body)
          .fontColor(Theme.brand)
      }
    }
    .width('100%')
    .padding({ top: Dimens.item, bottom: Dimens.item })
    .onClick(() => {
      this.onPick();
    })
  }
}

@CustomDialog
export struct OptionPickerDialog {
  controller?: CustomDialogController;
  /** 弹窗标题 */
  @Prop title: string = '';
  /** 当前选中的 key */
  @Prop selectedKey: string = '';
  /** 类别，决定展示哪一组固定选项 */
  @Prop kind: string = PickerKind.ROUTING;
  /** 选项文案，顺序见文件头注释 */
  @Prop labels: string[] = [];
  /** 选中回调（参数是 key，取值来自 RoutingMode / AppProxyMode / LogLevel） */
  onPick: (key: string) => void = (key: string) => {
  };

  /** 安全取文案（越界返回空串，避免 undefined） */
  private labelAt(index: number): string {
    if (index < 0 || index >= this.labels.length) {
      return '';
    }
    return this.labels[index];
  }

  /** 统一的选中处理 */
  private pick(key: string): void {
    this.onPick(key);
    this.controller?.close();
  }

  build() {
    Column({ space: Dimens.tight }) {
      Text(this.title)
        .fontSize(FontSizes.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
        .width('100%')
        .padding({ bottom: Dimens.item })

      if (this.kind === PickerKind.ROUTING) {
        this.RoutingOptions()
      } else if (this.kind === PickerKind.APP_PROXY) {
        this.AppProxyOptions()
      } else {
        this.LogLevelOptions()
      }
    }
    .width('100%')
    .padding(Dimens.page)
    .backgroundColor(Theme.surface)
    .borderRadius(Radii.card)
  }

  @Builder
  RoutingOptions() {
    PickerRow({
      label: this.labelAt(0),
      selected: this.selectedKey === RoutingMode.GLOBAL.toString(),
      onPick: () => {
        this.pick(RoutingMode.GLOBAL.toString());
      }
    })
    PickerRow({
      label: this.labelAt(1),
      selected: this.selectedKey === RoutingMode.RULE.toString(),
      onPick: () => {
        this.pick(RoutingMode.RULE.toString());
      }
    })
    PickerRow({
      label: this.labelAt(2),
      selected: this.selectedKey === RoutingMode.DIRECT.toString(),
      onPick: () => {
        this.pick(RoutingMode.DIRECT.toString());
      }
    })
  }

  @Builder
  AppProxyOptions() {
    PickerRow({
      label: this.labelAt(0),
      selected: this.selectedKey === AppProxyMode.OFF.toString(),
      onPick: () => {
        this.pick(AppProxyMode.OFF.toString());
      }
    })
    PickerRow({
      label: this.labelAt(1),
      selected: this.selectedKey === AppProxyMode.ALLOW_LIST.toString(),
      onPick: () => {
        this.pick(AppProxyMode.ALLOW_LIST.toString());
      }
    })
    PickerRow({
      label: this.labelAt(2),
      selected: this.selectedKey === AppProxyMode.BLOCK_LIST.toString(),
      onPick: () => {
        this.pick(AppProxyMode.BLOCK_LIST.toString());
      }
    })
  }

  @Builder
  LogLevelOptions() {
    PickerRow({
      label: this.labelAt(0),
      selected: this.selectedKey === LogLevel.DEBUG.toString(),
      onPick: () => {
        this.pick(LogLevel.DEBUG.toString());
      }
    })
    PickerRow({
      label: this.labelAt(1),
      selected: this.selectedKey === LogLevel.INFO.toString(),
      onPick: () => {
        this.pick(LogLevel.INFO.toString());
      }
    })
    PickerRow({
      label: this.labelAt(2),
      selected: this.selectedKey === LogLevel.WARN.toString(),
      onPick: () => {
        this.pick(LogLevel.WARN.toString());
      }
    })
    PickerRow({
      label: this.labelAt(3),
      selected: this.selectedKey === LogLevel.ERROR.toString(),
      onPick: () => {
        this.pick(LogLevel.ERROR.toString());
      }
    })
  }
}
