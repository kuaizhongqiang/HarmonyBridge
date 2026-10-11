/**
 * LogsPage.ets
 * 日志页：滚动日志视图 + 级别过滤 + 复制到剪贴板 + 清空。
 * 数据来自 LogViewModel（已订阅 utils/Logger 的输出）。
 */
import { LogEntry } from '../model/LogEntry';
import { LogLevel } from '../model/Types';
import { logViewModel, LogViewModel } from '../viewmodel/LogViewModel';
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { Routes } from '../constants/Routes';
import { Clipboard } from '../utils/Clipboard';
import { Toast } from '../utils/Toast';
import { PageHeader } from '../components/PageHeader';
import { EmptyState } from '../components/EmptyState';
import { NavigationBar } from '../components/NavigationBar';
import { formatLogTime } from '../utils/DateFormat';
import { stringOf, stringOfArgs } from '../utils/TextFormat';
import { resourceManager } from '@kit.LocalizationKit';

@Entry
@ComponentV2
struct LogsPage {
  @Local vm: LogViewModel = logViewModel;
  /** 过滤下拉框的选中索引；0=全部 */
  @Local levelIndex: number = 0;

  aboutToAppear(): void {
    this.levelIndex = 0;
    this.vm.filterEnabled = false;
  }

  private manager(): resourceManager.ResourceManager | undefined {
    return this.getUIContext().getHostContext()?.resourceManager;
  }

  private text(name: string): string {
    const mgr = this.manager();
    if (mgr === undefined) {
      return '';
    }
    return stringOf(mgr, name);
  }

  /** 带格式参数的资源文案 */
  private textArgs(name: string, args: Array<string | number>): string {
    const mgr = this.manager();
    if (mgr === undefined) {
      return '';
    }
    return stringOfArgs(mgr, name, args);
  }

  /** 级别 -> 颜色 */
  private levelColor(level: LogLevel): Resource {
    if (level === LogLevel.DEBUG) {
      return Theme.logDebug;
    }
    if (level === LogLevel.INFO) {
      return Theme.logInfo;
    }
    if (level === LogLevel.WARN) {
      return Theme.logWarn;
    }
    return Theme.logError;
  }

  /** 下拉选择 -> 过滤状态 */
  private applyLevelFilter(index: number): void {
    this.levelIndex = index;
    if (index === 0) {
      this.vm.filterEnabled = false;
      return;
    }
    this.vm.filterEnabled = true;
    if (index === 1) {
      this.vm.filterLevel = LogLevel.DEBUG;
    } else if (index === 2) {
      this.vm.filterLevel = LogLevel.INFO;
    } else if (index === 3) {
      this.vm.filterLevel = LogLevel.WARN;
    } else {
      this.vm.filterLevel = LogLevel.ERROR;
    }
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.logs_title'),
        trailingText: $r('app.string.logs_clear'),
        trailingEnabled: this.vm.visibleCount() > 0,
        onTrailingTap: () => {
          this.vm.clear();
          Toast.show(this.getUIContext().getPromptAction(), this.text('logs_cleared'));
        }
      })

      // ---------------- 级别过滤 ----------------
      Row({ space: Dimens.item }) {
        Select([
          { value: this.text('logs_filter_all') },
          { value: this.text('settings_log_level_debug') },
          { value: this.text('settings_log_level_info') },
          { value: this.text('settings_log_level_warn') },
          { value: this.text('settings_log_level_error') }
        ])
          .selected(this.levelIndex)
          .value(this.levelIndex === 0
            ? this.text('logs_filter_all')
            : (this.levelIndex === 1
              ? this.text('settings_log_level_debug')
              : (this.levelIndex === 2
                ? this.text('settings_log_level_info')
                : (this.levelIndex === 3
                  ? this.text('settings_log_level_warn')
                  : this.text('settings_log_level_error')))))
          .font({ size: FontSizes.caption })
          .onSelect((index: number) => {
            this.applyLevelFilter(index);
          })
        Text($r('app.string.logs_copy'))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.brand)
          .onClick(async () => {
            const payload: string = this.vm.exportText();
            await Clipboard.writeText(payload);
            Toast.show(
              this.getUIContext().getPromptAction(),
              this.textArgs('logs_copied', [this.vm.visibleCount()])
            );
          })
        Text(this.vm.visibleCount().toString())
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .padding({ left: Dimens.page, right: Dimens.page, bottom: Dimens.item })

      // ---------------- 日志列表 ----------------
      if (this.vm.visibleCount() === 0) {
        EmptyState({
          title: $r('app.string.logs_empty'),
          hint: $r('app.string.logs_empty_hint')
        })
      } else {
        List({ space: 2 }) {
          ForEach(this.vm.visibleEntries(), (entry: LogEntry) => {
            ListItem() {
              Row({ space: Dimens.tight }) {
                Text(formatLogTime(entry.timestamp))
                  .fontSize(FontSizes.caption)
                  .fontColor(Theme.textTertiary)
                Text(entry.level.toString().toUpperCase())
                  .fontSize(FontSizes.caption)
                  .fontColor(this.levelColor(entry.level))
                  .width(44)
                Column({ space: 2 }) {
                  Text(entry.tag)
                    .fontSize(FontSizes.caption)
                    .fontColor(Theme.textSecondary)
                  Text(entry.message)
                    .fontSize(FontSizes.body)
                    .fontColor(Theme.textPrimary)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(Dimens.tight)
              .backgroundColor(Theme.surface)
              .borderRadius(Radii.small)
              .alignItems(VerticalAlign.Top)
            }
          }, (entry: LogEntry) => entry.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Dimens.page, right: Dimens.page })
        .scrollBar(BarState.Auto)
      }

      NavigationBar({ current: Routes.LOGS })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
