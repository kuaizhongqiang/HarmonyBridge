/**
 * SubscriptionsPage.ets
 * 订阅页：列表（名称 / 地址 / 节点数 / 上次更新）、新增与编辑、立即更新、全部更新、剪贴板导入。
 * 对应 v2rayN 的 SubSettingWindow + 「订阅」菜单。
 */
import { Subscription, isNeverUpdated } from '../model/Subscription';
import { SubscriptionId, Timestamp } from '../model/Types';
import { subscriptionViewModel, SubscriptionViewModel } from '../viewmodel/SubscriptionViewModel';
import { SettingsViewModel, settingsViewModel } from '../viewmodel/SettingsViewModel';
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { Routes } from '../constants/Routes';
import { formatShortDateTime, relativeTime } from '../utils/DateFormat';
import { relativeTimeText, stringOf, stringOfArgs } from '../utils/TextFormat';
import { Toast } from '../utils/Toast';
import { PageHeader } from '../components/PageHeader';
import { EmptyState } from '../components/EmptyState';
import { NavigationBar } from '../components/NavigationBar';
import { SubscriptionEditDialog } from '../components/SubscriptionEditDialog';
import { resourceManager } from '@kit.LocalizationKit';

@Entry
@ComponentV2
struct SubscriptionsPage {
  @Local vm: SubscriptionViewModel = subscriptionViewModel;
  @Local settings: SettingsViewModel = settingsViewModel;
  @Local editing: boolean = false;
  @Local draftName: string = '';
  @Local draftUrl: string = '';
  @Local draftEnabled: boolean = true;
  @Local draftAutoUpdate: boolean = false;

  private editingId: SubscriptionId = '';

  private dialogController: CustomDialogController = new CustomDialogController({
    builder: SubscriptionEditDialog({
      editing: this.editing,
      initialName: this.draftName,
      initialUrl: this.draftUrl,
      initialEnabled: this.draftEnabled,
      initialAutoUpdate: this.draftAutoUpdate,
      onConfirm: (name: string, url: string, enabled: boolean, autoUpdate: boolean) => {
        this.commitDraft(name, url, enabled, autoUpdate);
      }
    }),
    autoCancel: true,
    customStyle: true
  });

  aboutToAppear(): void {
    this.vm.init();
    this.settings.init();
  }

  /** 资源管理器（本地化文案用） */
  private manager(): resourceManager.ResourceManager | undefined {
    return this.getUIContext().getHostContext()?.resourceManager;
  }

  /** 提交新增 / 编辑 */
  private commitDraft(name: string, url: string, enabled: boolean, autoUpdate: boolean): void {
    if (this.editing && this.editingId.length > 0) {
      const existing: Subscription | undefined = this.vm.findById(this.editingId);
      if (existing !== undefined) {
        existing.name = name;
        existing.url = url;
        existing.enabled = enabled;
        existing.autoUpdate = autoUpdate;
        this.vm.updateSubscription(existing);
        Toast.show(this.getUIContext().getPromptAction(), this.text('subs_save'));
      }
      this.editing = false;
      this.editingId = '';
      return;
    }
    const created: Subscription = this.vm.addSubscription(name, url);
    created.enabled = enabled;
    created.autoUpdate = autoUpdate;
    this.vm.updateSubscription(created);
    this.editing = false;
  }

  /** 上次更新时间展示 */
  private lastUpdateText(sub: Subscription): string {
    if (isNeverUpdated(sub)) {
      return this.text('subs_never_updated');
    }
    const resourceMgr = this.manager();
    if (resourceMgr === undefined) {
      return formatShortDateTime(sub.lastUpdatedAt);
    }
    const now: Timestamp = Date.now();
    return formatShortDateTime(sub.lastUpdatedAt) + ' (' +
      relativeTimeText(resourceMgr, relativeTime(sub.lastUpdatedAt, now)) + ')';
  }

  /** 资源名 -> 字符串（Select / Toast 需要 string） */
  private text(name: string): string {
    const manager = this.manager();
    if (manager === undefined) {
      return '';
    }
    return stringOf(manager, name);
  }

  /** 带格式参数的资源名 -> 字符串 */
  private textArgs(name: string, args: Array<string | number>): string {
    const manager = this.manager();
    if (manager === undefined) {
      return '';
    }
    return stringOfArgs(manager, name, args);
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.subs_title'),
        trailingText: this.vm.updatingIds.length > 0
          ? $r('app.string.subs_updating')
          : $r('app.string.subs_update_all'),
        trailingEnabled: this.vm.updatingIds.length === 0,
        onTrailingTap: async () => {
          await this.vm.updateAll();
          this.notifyResult();
        }
      })

      // ---------------- 动作栏 ----------------
      Row({ space: Dimens.item }) {
        Button($r('app.string.subs_add'))
          .fontSize(FontSizes.caption)
          .backgroundColor(Theme.brand)
          .fontColor(Theme.textOnBrand)
          .onClick(() => {
            this.editing = false;
            this.editingId = '';
            this.draftName = '';
            this.draftUrl = '';
            this.draftEnabled = true;
            this.draftAutoUpdate = false;
            this.dialogController.open();
          })
        Button($r('app.string.subs_import_clipboard'))
          .fontSize(FontSizes.caption)
          .backgroundColor(Theme.surfaceAlt)
          .fontColor(Theme.textPrimary)
          .onClick(async () => {
            await this.vm.importFromClipboard();
            this.notifyResult();
          })
        Button($r('app.string.subs_update_all'))
          .fontSize(FontSizes.caption)
          .backgroundColor(Theme.surfaceAlt)
          .fontColor(Theme.textPrimary)
          .enabled(this.vm.updatingIds.length === 0)
          .onClick(async () => {
            await this.vm.updateAll();
            this.notifyResult();
          })
      }
      .width('100%')
      .padding({ left: Dimens.page, right: Dimens.page, bottom: Dimens.item })

      // ---------------- 列表 ----------------
      if (this.vm.subscriptions.length === 0) {
        EmptyState({
          title: $r('app.string.subs_empty'),
          hint: $r('app.string.subs_empty_hint')
        })
      } else {
        List({ space: Dimens.tight }) {
          ForEach(this.vm.subscriptions, (sub: Subscription) => {
            ListItem() {
              this.SubscriptionRow(sub)
            }
          }, (sub: Subscription) => sub.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Dimens.page, right: Dimens.page })
        .scrollBar(BarState.Off)
      }

      NavigationBar({ current: Routes.SUBSCRIPTIONS })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 单条订阅卡片 */
  @Builder
  SubscriptionRow(sub: Subscription) {
    Column({ space: Dimens.tight }) {
      Row({ space: Dimens.tight }) {
        Text(sub.name)
          .fontSize(FontSizes.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .maxLines(1)
          .layoutWeight(1)
        Text($r('app.string.subs_node_count', sub.nodeCount))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textSecondary)
      }
      .width('100%')

      Text(sub.url)
        .fontSize(FontSizes.caption)
        .fontColor(Theme.textTertiary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: Dimens.tight }) {
        Text($r('app.string.subs_last_update'))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textSecondary)
        Text(sub.lastError.length > 0 ? sub.lastError : this.lastUpdateText(sub))
          .fontSize(FontSizes.caption)
          .fontColor(sub.lastError.length > 0 ? Theme.error : Theme.textTertiary)
          .layoutWeight(1)
          .maxLines(1)
      }
      .width('100%')

      Row({ space: Dimens.item }) {
        if (this.vm.isUpdating(sub.id)) {
          Text($r('app.string.subs_updating'))
            .fontSize(FontSizes.caption)
            .fontColor(Theme.textTertiary)
        } else {
          Text($r('app.string.subs_update'))
            .fontSize(FontSizes.caption)
            .fontColor(Theme.brand)
            .onClick(async () => {
              await this.vm.updateSubscriptionNow(sub.id);
              this.notifyResult();
            })
        }
        Text($r('app.string.subs_edit'))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.brand)
          .onClick(() => {
            this.editing = true;
            this.editingId = sub.id;
            this.draftName = sub.name;
            this.draftUrl = sub.url;
            this.draftEnabled = sub.enabled;
            this.draftAutoUpdate = sub.autoUpdate;
            this.dialogController.open();
          })
        Text($r('app.string.subs_delete'))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.error)
          .onClick(() => {
            this.vm.removeSubscription(sub.id);
          })
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: sub.enabled })
          .selectedColor(Theme.brand)
          .onChange((isOn: boolean) => {
            sub.enabled = isOn;
            this.vm.updateSubscription(sub);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(Dimens.item)
    .backgroundColor(Theme.surface)
    .borderRadius(Radii.card)
    .border({ width: 1, color: Theme.divider })
  }

  /** 统一把 ViewModel 的 lastMessage 转成 toast 文案 */
  private notifyResult(): void {
    const action = this.getUIContext().getPromptAction();
    const message: string = this.vm.lastMessage;
    if (message === 'clipboard-empty') {
      Toast.show(action, this.text('subs_clipboard_empty'));
    } else if (message === 'clipboard-imported') {
      Toast.show(action, this.textArgs('subs_clipboard_imported', [this.vm.lastNodeCount]));
    } else if (message === 'clipboard-subscription') {
      Toast.show(action, this.text('subs_add'));
    } else if (message === 'update-done') {
      Toast.show(
        action,
        this.textArgs('subs_update_done', ['OK', this.vm.lastNodeCount])
      );
    } else if (message === 'update-failed') {
      Toast.show(action, this.textArgs('subs_update_failed', ['subscription', 'network']));
    }
  }
}
