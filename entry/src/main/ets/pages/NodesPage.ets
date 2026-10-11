/**
 * NodesPage.ets
 * 节点 / 服务器列表页。列定义对齐 v2rayN 的 ProfilesView：
 * 协议 / 别名 / 地址:端口 / 传输 / TLS / 延迟 / 测速。
 * 动作栏对齐 v2rayN：过滤、排序、测试延迟、添加节点。
 * 添加 / 编辑使用底部半屏 Sheet（components/NodeEditSheet.ets），字段集对齐 AddServerWindow。
 */
import { nodeViewModel, NodeViewModel, NodeSortKey, SortDirection } from '../viewmodel/NodeViewModel';
import { NodeEditForm } from '../viewmodel/NodeEditForm';
import { ServerNode, nodeEndpointText } from '../model/ServerNode';
import { NodeId, protocolTagText } from '../model/Types';
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { Routes } from '../constants/Routes';
import { SUBSCRIPTION_ID_MANUAL, SUBSCRIPTION_NAME_MANUAL } from '../constants/Common';
import { PageHeader } from '../components/PageHeader';
import { LatencyBadge, ProtocolTag } from '../components/LatencyBadge';
import { EmptyState } from '../components/EmptyState';
import { NavigationBar } from '../components/NavigationBar';
import { NodeEditSheet } from '../components/NodeEditSheet';
import { validateNode, ValidationResult } from '../service/NodeValidator';
import { stringOf } from '../utils/TextFormat';
import { Toast } from '../utils/Toast';

@Entry
@ComponentV2
struct NodesPage {
  @Local vm: NodeViewModel = nodeViewModel;
  @Local sortIndex: number = 0;
  @Local ascending: boolean = true;
  /** Sheet 是否展开 */
  @Local sheetShown: boolean = false;
  /** 正在编辑的节点 id；空串 = 新增 */
  @Local editingId: NodeId = '';
  /** 表单状态（页面持有，Sheet 只读渲染） */
  @Local editForm: NodeEditForm = new NodeEditForm();
  /** 可选分组（订阅名），打开 Sheet 时快照一次 */
  @Local groupOptions: string[] = [];

  aboutToAppear(): void {
    this.vm.init();
  }

  /** 打开「添加节点」表单 */
  private openAddSheet(): void {
    this.editingId = '';
    this.groupOptions = this.vm.subscriptionNames();
    this.editForm = NodeEditForm.fromNode(this.vm.createDraft());
    this.sheetShown = true;
  }

  /** 打开「编辑节点」表单（NodeEditForm.fromNode 内部会克隆，未保存不污染列表） */
  private openEditSheet(node: ServerNode): void {
    this.editingId = node.id;
    this.groupOptions = this.vm.subscriptionNames();
    this.editForm = NodeEditForm.fromNode(node);
    this.sheetShown = true;
  }

  /** 保存表单：校验通过才落库 */
  private saveSheet(): void {
    const groupName: string = this.editForm.groupName;
    const isManual: boolean = groupName.length === 0;
    const subscriptionId: string = isManual ? SUBSCRIPTION_ID_MANUAL : this.vm.subscriptionIdOfName(groupName);
    const subscriptionName: string = isManual ? SUBSCRIPTION_NAME_MANUAL : groupName;
    const node: ServerNode = this.editForm.toNode(subscriptionId, subscriptionName);
    const validation: ValidationResult = validateNode(node);
    if (!validation.valid) {
      Toast.show(this.getUIContext().getPromptAction(), this.text('node_save_invalid'));
      return;
    }
    if (this.editingId.length === 0) {
      this.vm.addNode(node);
      Toast.show(this.getUIContext().getPromptAction(), this.text('node_added'));
    } else {
      this.vm.updateNode(node);
      Toast.show(this.getUIContext().getPromptAction(), this.text('node_saved'));
    }
    this.sheetShown = false;
  }

  /** Sheet 内容 */
  @Builder
  nodeEditSheetContent() {
    NodeEditSheet({
      form: this.editForm,
      isEdit: this.editingId.length > 0,
      groups: this.groupOptions,
      onSave: () => {
        this.saveSheet();
      },
      onCancel: () => {
        this.sheetShown = false;
      }
    })
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

  /** 排序方向（不能叫 direction：CustomComponent 基类已保留该属性名） */
  private sortDirection(): SortDirection {
    return this.ascending ? SortDirection.ASC : SortDirection.DESC;
  }

  private applySort(): void {
    this.vm.setSort(this.sortKey(), this.sortDirection());
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

        Button($r('app.string.nodes_add'))
          .fontSize(FontSizes.caption)
          .backgroundColor(Theme.surfaceAlt)
          .fontColor(Theme.brand)
          .width('100%')
          .onClick(() => {
            this.openAddSheet();
          })
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
    .bindSheet(this.sheetShown, this.nodeEditSheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      onDisappear: () => {
        this.sheetShown = false;
      }
    })
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
        Text($r('app.string.nodes_edit'))
          .fontSize(FontSizes.caption)
          .fontColor(Theme.brand)
          .onClick(() => {
            this.openEditSheet(node);
          })
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
