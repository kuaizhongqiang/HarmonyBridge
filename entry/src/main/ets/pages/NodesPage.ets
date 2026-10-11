/**
 * NodesPage.ets
 * 节点 / 服务器列表页。列定义对齐 v2rayN 的 ProfilesView：
 * 协议 / 别名 / 地址:端口 / 传输 / TLS / 延迟 / 测速。
 * 动作栏对齐 v2rayN：过滤、排序、测试延迟、快速测速（占位）。
 */
import { nodeViewModel, NodeSortKey, SortDirection } from '../viewmodel/NodeViewModel';
import { ServerNode, nodeEndpointText } from '../model/ServerNode';
import { NodeId, protocolTagText } from '../model/Types';
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { Routes } from '../constants/Routes';
import { PageHeader } from '../components/PageHeader';
import { LatencyBadge, ProtocolTag } from '../components/LatencyBadge';
import { EmptyState } from '../components/EmptyState';
import { NavigationBar } from '../components/NavigationBar';
import { stringOf } from '../utils/TextFormat';

@Entry
@ComponentV2
struct NodesPage {
  @Local vm: NodeViewModel = nodeViewModel;
  @Local sortIndex: number = 0;
  @Local ascending: boolean = true;

  aboutToAppear(): void {
    this.vm.init();
  }

  /** 当前排序键 */
  private sortKey(): NodeSortKey {
    if (this.sortIndex === 1) {
      return NodeSortKey.NAME;
    }
    if (this.sortIndex === 2) {
      return NodeSortKey.LATENCY;
    }
    return NodeSortKey.DEFAULT;
  }

  /** 排序方向 */
  private direction(): SortDirection {
    return this.ascending ? SortDirection.ASC : SortDirection.DESC;
  }

  private applySort(): void {
    this.vm.setSort(this.sortKey(), this.direction());
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.nodes_title'),
        trailingText: this.vm.testing ? $r('app.string.nodes_testing') : $r('app.string.nodes_test_latency'),
        trailingEnabled: !this.vm.testing,
        onTrailingTap: () => {
          this.vm.testAllLatency(false);
        }
      })

      // ---------------- 动作栏 ----------------
      Column({ space: Dimens.tight }) {
        TextInput({ text: this.vm.filterText, placeholder: $r('app.string.nodes_filter_hint') })
          .fontSize(FontSizes.body)
          .backgroundColor(Theme.surface)
          .borderRadius(Radii.small)
          .onChange((value: string) => {
            this.vm.setFilter(value);
          })

        Row({ space: Dimens.item }) {
          Select([
            { value: this.text('nodes_sort_default') },
            { value: this.text('nodes_sort_name') },
            { value: this.text('nodes_sort_latency') }
          ])
            .selected(this.sortIndex)
            .value(this.text(this.sortIndex === 1
              ? 'nodes_sort_name'
              : (this.sortIndex === 2 ? 'nodes_sort_latency' : 'nodes_sort_default')))
            .font({ size: FontSizes.caption })
            .onSelect((index: number) => {
              this.sortIndex = index;
              this.applySort();
            })

          Button(this.ascending ? $r('app.string.nodes_sort_asc') : $r('app.string.nodes_sort_desc'))
            .fontSize(FontSizes.caption)
            .backgroundColor(Theme.surfaceAlt)
            .fontColor(Theme.textPrimary)
            .onClick(() => {
              this.ascending = !this.ascending;
              this.applySort();
            })

          Button(this.vm.testing ? $r('app.string.nodes_testing') : $r('app.string.nodes_test_latency'))
            .fontSize(FontSizes.caption)
            .backgroundColor(Theme.brand)
            .fontColor(Theme.textOnBrand)
            .enabled(!this.vm.testing)
            .onClick(() => {
              this.vm.testAllLatency(true);
            })
        }
        .width('100%')

        Text($r('app.string.nodes_count', this.vm.visibleCount()))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textSecondary)
          .width('100%')
      }
      .width('100%')
      .padding({ left: Dimens.page, right: Dimens.page, bottom: Dimens.item })

      // ---------------- 列表 ----------------
      if (this.vm.visibleCount() === 0) {
        EmptyState({
          title: $r('app.string.nodes_empty'),
          hint: $r('app.string.nodes_empty_hint')
        })
      } else {
        List({ space: Dimens.tight }) {
          ForEach(this.vm.viewNodes, (node: ServerNode) => {
            ListItem() {
              this.NodeRow(node)
            }
          }, (node: ServerNode) => node.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Dimens.page, right: Dimens.page })
        .scrollBar(BarState.Off)
        .listDirection(Axis.Vertical)
      }

      NavigationBar({ current: Routes.NODES })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 单行节点卡片 */
  @Builder
  NodeRow(node: ServerNode) {
    Column({ space: Dimens.tight }) {
      Row({ space: Dimens.tight }) {
        ProtocolTag({ text: protocolTagText(node.protocol) })
        Text(node.remarks)
          .fontSize(FontSizes.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .maxLines(1)
          .layoutWeight(1)
        LatencyBadge({ latencyMs: node.latencyMs })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: Dimens.tight }) {
        Text(nodeEndpointText(node))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
          .maxLines(1)
        if (node.subscriptionName.length > 0) {
          Text(node.subscriptionName)
            .fontSize(FontSizes.caption)
            .fontColor(Theme.textTertiary)
            .maxLines(1)
        }
      }
      .width('100%')

      Row({ space: Dimens.item }) {
        Text(node.transport.toString().toUpperCase() + ' / ' + node.security.toString().toUpperCase())
          .fontSize(FontSizes.caption)
          .fontColor(Theme.textTertiary)
          .layoutWeight(1)
        if (this.vm.selectedNodeId === node.id) {
          Text($r('app.string.nodes_selected'))
            .fontSize(FontSizes.caption)
            .fontColor(Theme.success)
        } else {
          Text($r('app.string.nodes_use'))
            .fontSize(FontSizes.caption)
            .fontColor(Theme.brand)
            .onClick(() => {
              this.select(node.id);
            })
        }
        Text($r('app.string.nodes_delete'))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.error)
          .onClick(() => {
            this.vm.removeNode(node.id);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(Dimens.item)
    .backgroundColor(this.vm.selectedNodeId === node.id ? Theme.brandSoft : Theme.surface)
    .borderRadius(Radii.card)
    .border({
      width: 1,
      color: this.vm.selectedNodeId === node.id ? Theme.brand : Theme.divider
    })
    .onClick(() => {
      this.select(node.id);
    })
  }

  /** 选中节点并单测延迟 */
  private select(id: NodeId): void {
    this.vm.selectNode(id);
    const node: ServerNode | undefined = this.vm.findById(id);
    if (node !== undefined) {
      this.vm.testSingleLatency(node);
    }
  }

  /** 资源 -> 字符串（Select 的 value 需要 string） */
  private text(name: string): string {
    const manager = this.getUIContext().getHostContext()?.resourceManager;
    if (manager === undefined) {
      return '';
    }
    return stringOf(manager, name);
  }
}
