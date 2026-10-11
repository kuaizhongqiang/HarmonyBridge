/**
 * Index.ets
 * 首页 / 连接页（EntryAbility 加载的入口页）。
 * 内容对齐 v2rayN 主窗口：当前节点 + 运行状态 + 实时速率/累计流量 + 路由模式 + 快捷入口。
 * UI 只负责渲染，所有状态来自 viewmodel/* 的单例。
 */
import { common } from '@kit.AbilityKit';
import { ConnectionState, RoutingMode } from '../model/Types';
import { ServerNode, nodeEndpointText } from '../model/ServerNode';
import { connectionViewModel, ConnectionViewModel } from '../viewmodel/ConnectionViewModel';
import { nodeViewModel, NodeViewModel } from '../viewmodel/NodeViewModel';
import { subscriptionViewModel } from '../viewmodel/SubscriptionViewModel';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { RouteParams, RouterHelper, Routes } from '../constants/Routes';
import { ConnectionStatusBadge } from '../components/ConnectionStatusBadge';
import { LatencyBadge, ProtocolTag } from '../components/LatencyBadge';
import { StatCard } from '../components/StatCard';
import { NavigationBar } from '../components/NavigationBar';
import { formatBytes, formatSpeed } from '../utils/BytesFormat';
import { Logger } from '../utils/Logger';

const TAG: string = 'IndexPage';

@Entry
@ComponentV2
struct Index {
  @Local connection: ConnectionViewModel = connectionViewModel;
  @Local nodes: NodeViewModel = nodeViewModel;

  aboutToAppear(): void {
    this.nodes.init();
    subscriptionViewModel.init();
    settingsViewModel.init();
    this.connection.init();
    Logger.info(TAG, 'home page ready, mock=' + this.connection.mockMode.toString());
  }

  /** 当前选中的节点（供模板使用） */
  private currentNode(): ServerNode | undefined {
    return this.nodes.selectedNode();
  }

  /** 首页大按钮的文案 */
  private connectButtonText(): ResourceStr {
    if (this.connection.state === ConnectionState.CONNECTED) {
      return $r('app.string.home_disconnect');
    }
    if (this.connection.state === ConnectionState.CONNECTING) {
      return $r('app.string.home_connecting');
    }
    if (this.connection.state === ConnectionState.DISCONNECTING) {
      return $r('app.string.home_disconnecting');
    }
    return $r('app.string.home_connect');
  }

  /** 路由模式展示文案 */
  private routingModeText(mode: RoutingMode): ResourceStr {
    if (mode === RoutingMode.GLOBAL) {
      return $r('app.string.routing_global');
    }
    if (mode === RoutingMode.DIRECT) {
      return $r('app.string.routing_direct');
    }
    return $r('app.string.routing_rule');
  }

  private uiContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: Dimens.card }) {
          // ---------------- 标题 ----------------
          Row() {
            Text($r('app.string.home_title'))
              .fontSize(FontSizes.title)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary)
              .layoutWeight(1)
            ConnectionStatusBadge({ state: this.connection.state })
          }
          .width('100%')
          .height(Dimens.titleBar)
          .alignItems(VerticalAlign.Center)

          // ---------------- MOCK 提示 ----------------
          if (this.connection.mockMode) {
            Text($r('app.string.home_mock_banner'))
              .fontSize(FontSizes.caption)
              .fontColor(Theme.warning)
              .backgroundColor(Theme.surfaceAlt)
              .borderRadius(Radii.small)
              .padding(Dimens.item)
              .width('100%')
          }

          // ---------------- 当前节点 ----------------
          Column({ space: Dimens.item }) {
            Text($r('app.string.home_current_node'))
              .fontSize(FontSizes.caption)
              .fontColor(Theme.textSecondary)
              .width('100%')

            if (this.currentNode() !== undefined) {
              Row({ space: Dimens.tight }) {
                Text(this.currentNode()!.remarks)
                  .fontSize(FontSizes.subtitle)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.textPrimary)
                  .maxLines(1)
                  .layoutWeight(1)
                ProtocolTag({ text: this.currentNode()!.protocol.toString().toUpperCase() })
                LatencyBadge({ latencyMs: this.currentNode()!.latencyMs })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Text(nodeEndpointText(this.currentNode()!))
                .fontSize(FontSizes.caption)
                .fontColor(Theme.textSecondary)
                .width('100%')
            } else {
              Text($r('app.string.home_no_node'))
                .fontSize(FontSizes.subtitle)
                .fontColor(Theme.textPrimary)
                .width('100%')
              Text($r('app.string.home_no_node_hint'))
                .fontSize(FontSizes.caption)
                .fontColor(Theme.textSecondary)
                .width('100%')
            }
          }
          .width('100%')
          .padding(Dimens.card)
          .backgroundColor(Theme.surface)
          .borderRadius(Radii.card)

          // ---------------- 连接按钮 ----------------
          Column({ space: Dimens.card }) {
            Button(this.connectButtonText())
              .fontSize(FontSizes.subtitle)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textOnBrand)
              .backgroundColor(this.connection.isConnected() ? Theme.error : Theme.brand)
              .width(Dimens.connectButton)
              .height(Dimens.connectButton)
              .borderRadius(Dimens.connectButton / 2)
              .enabled(!this.connection.isBusy())
              .onClick(() => {
                this.connection.toggle(this.uiContext());
              })

            Row({ space: Dimens.item }) {
              Text($r('app.string.home_routing_mode'))
                .fontSize(FontSizes.caption)
                .fontColor(Theme.textSecondary)
              Text(this.routingModeText(this.connection.routingMode))
                .fontSize(FontSizes.caption)
                .fontColor(Theme.brand)
                .onClick(() => {
                  this.cycleRoutingMode();
                })
            }
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)

          // ---------------- 速率 / 流量 ----------------
          Row({ space: Dimens.item }) {
            StatCard({
              label: $r('app.string.home_up_speed'),
              value: formatSpeed(this.connection.traffic.speedUp)
            })
            StatCard({
              label: $r('app.string.home_down_speed'),
              value: formatSpeed(this.connection.traffic.speedDown)
            })
          }
          .width('100%')

          Row({ space: Dimens.item }) {
            StatCard({
              label: $r('app.string.home_total_up'),
              value: formatBytes(this.connection.traffic.totalUp)
            })
            StatCard({
              label: $r('app.string.home_total_down'),
              value: formatBytes(this.connection.traffic.totalDown)
            })
          }
          .width('100%')

          // ---------------- 快捷入口 ----------------
          Column({ space: Dimens.tight }) {
            Text($r('app.string.home_quick_actions'))
              .fontSize(FontSizes.caption)
              .fontColor(Theme.textSecondary)
              .width('100%')
            this.QuickAction($r('app.string.home_action_nodes'), Routes.NODES)
            this.QuickAction($r('app.string.home_action_subscriptions'), Routes.SUBSCRIPTIONS)
            this.QuickAction($r('app.string.home_action_settings'), Routes.SETTINGS)
            this.QuickAction($r('app.string.home_action_logs'), Routes.LOGS)
          }
          .width('100%')
          .padding(Dimens.card)
          .backgroundColor(Theme.surface)
          .borderRadius(Radii.card)

          // ---------------- 内核版本 ----------------
          Row() {
            Text($r('app.string.home_core_version'))
              .fontSize(FontSizes.caption)
              .fontColor(Theme.textSecondary)
              .layoutWeight(1)
            Text(this.connection.coreVersion.length > 0 ? this.connection.coreVersion : '-')
              .fontSize(FontSizes.caption)
              .fontColor(Theme.textTertiary)
          }
          .width('100%')
          .padding({ left: Dimens.tight, right: Dimens.tight })
        }
        .width('100%')
        .padding({ left: Dimens.page, right: Dimens.page, bottom: Dimens.page })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      NavigationBar({ current: Routes.INDEX })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 循环切换路由模式：规则 -> 全局 -> 直连 -> 规则 */
  private cycleRoutingMode(): void {
    const current: RoutingMode = this.connection.routingMode;
    let next: RoutingMode = RoutingMode.RULE;
    if (current === RoutingMode.RULE) {
      next = RoutingMode.GLOBAL;
    } else if (current === RoutingMode.GLOBAL) {
      next = RoutingMode.DIRECT;
    }
    this.connection.setRoutingMode(next);
  }

  /** 快捷入口行 */
  @Builder
  QuickAction(label: Resource, route: string) {
    Row() {
      Text(label)
        .fontSize(FontSizes.body)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
      Text('›')
        .fontSize(FontSizes.subtitle)
        .fontColor(Theme.textTertiary)
    }
    .width('100%')
    .padding({ top: Dimens.item, bottom: Dimens.item })
    .onClick(() => {
      const params: RouteParams = {};
      RouterHelper.push(this.getUIContext().getRouter(), route, params);
    })
  }
}
