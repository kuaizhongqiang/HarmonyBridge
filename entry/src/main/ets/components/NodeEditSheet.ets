/**
 * NodeEditSheet.ets
 * 节点「添加 / 编辑」表单（底部半屏 Sheet 内容），字段集对齐 v2rayN 的 AddServerWindow：
 *   基础（别名 / 地址 / 端口 / 分组）
 *   协议参数（用户 ID + 生成 / 密码 / 加密方式 / alterId / flow / Mux）
 *   底层传输方式（传输协议 / Host / 路径 / serviceName / raw 伪装类型 / kcp 伪装类型 /
 *                 gRPC 模式 / XHTTP 模式 / XHTTP extra / Finalmask）
 *   传输层安全（TLS / SNI / Fingerprint / Alpn / 跳过证书校验 / PublicKey / ShortId / SpiderX）
 *
 * 状态不放在本组件内部：表单对象由页面持有并作为 `@Param` 传入（见 viewmodel/NodeEditForm.ets），
 * 因此与 Sheet 内容的创建/销毁时机无关，字段一定能显示成最新值。
 *
 * 行为约定：本组件只负责「渲染 + 编辑表单对象」，校验与落库由页面完成（onSave / onCancel）。
 */
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import {
  FINGERPRINT_OPTIONS,
  FLOW_OPTIONS,
  GRPC_MODE_OPTIONS,
  KCP_HEADER_OPTIONS,
  optionIndexOf,
  PROTOCOL_OPTIONS,
  RAW_HEADER_OPTIONS,
  SECURITY_OPTIONS,
  SS_CIPHER_OPTIONS,
  TRANSPORT_OPTIONS,
  VMESS_SECURITY_OPTIONS,
  XHTTP_MODE_OPTIONS
} from '../constants/NodeOptions';
import { NodeEditForm } from '../viewmodel/NodeEditForm';
import { ProxyProtocol, SecurityKind, TransportKind } from '../model/Types';
import { stringOf } from '../utils/TextFormat';

/** 把 string[] 转成 Select 需要的 SelectOption[] */
function toSelectOptions(list: string[]): SelectOption[] {
  const options: SelectOption[] = [];
  for (let i = 0; i < list.length; i++) {
    const option: SelectOption = { value: list[i] };
    options.push(option);
  }
  return options;
}

/** 纯文本框（标签在上，输入框在下） */
@ComponentV2
struct NodeTextField {
  @Param label: Resource = $r('app.string.node_label_remarks');
  @Param value: string = '';
  @Param placeholder: Resource = $r('app.string.node_placeholder_empty');
  @Param numeric: boolean = false;
  @Event onValue: (value: string) => void = () => {
  };

  build() {
    Column({ space: Dimens.tight }) {
      Text(this.label)
        .fontSize(FontSizes.caption)
        .fontColor(Theme.textSecondary)
      TextInput({ text: this.value, placeholder: this.placeholder })
        .type(this.numeric ? InputType.Number : InputType.Normal)
        .fontSize(FontSizes.body)
        .backgroundColor(Theme.surfaceAlt)
        .borderRadius(Radii.small)
        .onChange((value: string) => {
          this.onValue(value);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 下拉选择框 */
@ComponentV2
struct NodeSelectField {
  @Param label: Resource = $r('app.string.node_label_network');
  @Param options: string[] = [];
  @Param value: string = '';
  @Event onValue: (value: string) => void = () => {
  };

  build() {
    Column({ space: Dimens.tight }) {
      Text(this.label)
        .fontSize(FontSizes.caption)
        .fontColor(Theme.textSecondary)
      Select(toSelectOptions(this.options))
        .selected(optionIndexOf(this.options, this.value))
        .value(this.value)
        .font({ size: FontSizes.body })
        .width('100%')
        .backgroundColor(Theme.surfaceAlt)
        .onSelect((index: number) => {
          if (index >= 0 && index < this.options.length) {
            this.onValue(this.options[index]);
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 开关行 */
@ComponentV2
struct NodeSwitchField {
  @Param label: Resource = $r('app.string.node_label_mux');
  @Param isOn: boolean = false;
  @Event onToggle: (value: boolean) => void = () => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(FontSizes.body)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(Theme.brand)
        .onChange((isOn: boolean) => {
          this.onToggle(isOn);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

/** 分组标题 */
@ComponentV2
struct NodeFormSection {
  @Param title: Resource = $r('app.string.node_section_protocol');

  build() {
    Text(this.title)
      .fontSize(FontSizes.subtitle)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.textPrimary)
      .width('100%')
      .margin({ top: Dimens.item })
  }
}

/** 节点编辑表单（Sheet 内容） */
@ComponentV2
export struct NodeEditSheet {
  /** 表单状态（页面持有） */
  @Param form: NodeEditForm = new NodeEditForm();
  /** 是否编辑模式（决定标题） */
  @Param isEdit: boolean = false;
  /** 可选分组名（订阅名）；空数组表示只支持「手动添加」 */
  @Param groups: string[] = [];
  @Event onSave: () => void = () => {
  };
  @Event onCancel: () => void = () => {
  };

  /** 分组下拉的展示项：第 0 项固定是「手动添加」 */
  private groupLabels(): string[] {
    const labels: string[] = [this.text('node_group_manual')];
    for (let i = 0; i < this.groups.length; i++) {
      labels.push(this.groups[i]);
    }
    return labels;
  }

  /** 当前分组在展示项里的下标 */
  private groupIndex(): number {
    const index: number = this.groups.indexOf(this.form.groupName);
    return index < 0 ? 0 : index + 1;
  }

  /** 展示项下标 -> 分组名（空串 = 手动添加） */
  private applyGroupIndex(index: number): void {
    if (index <= 0 || index > this.groups.length) {
      this.form.groupName = '';
      return;
    }
    this.form.groupName = this.groups[index - 1];
  }

  /** 资源名 -> 字符串（Select 的选项文案需要 string） */
  private text(name: string): string {
    const manager: resourceManager.ResourceManager | undefined =
      this.getUIContext().getHostContext()?.resourceManager;
    if (manager === undefined) {
      return '';
    }
    return stringOf(manager, name);
  }

  build() {
    Column() {
      // ---------------- 标题 ----------------
      Row() {
        Text(this.isEdit ? $r('app.string.node_edit_title_edit') : $r('app.string.node_edit_title_add'))
          .fontSize(FontSizes.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: Dimens.page, right: Dimens.page, top: Dimens.card })

      // ---------------- 表单 ----------------
      Scroll() {
        Column({ space: Dimens.item }) {
          // ===== 基础 =====
          NodeSelectField({
            label: $r('app.string.node_label_group'),
            options: this.groupLabels(),
            value: this.groupLabels()[this.groupIndex()],
            onValue: (value: string) => {
              const index: number = this.groupLabels().indexOf(value);
              this.applyGroupIndex(index);
            }
          })

          NodeTextField({
            label: $r('app.string.node_label_remarks'),
            value: this.form.remarks,
            placeholder: $r('app.string.node_placeholder_remarks'),
            onValue: (value: string) => {
              this.form.remarks = value;
            }
          })

          NodeSelectField({
            label: $r('app.string.node_label_protocol'),
            options: PROTOCOL_OPTIONS,
            value: this.form.protocol,
            onValue: (value: string) => {
              this.form.protocol = value;
            }
          })

          NodeTextField({
            label: $r('app.string.node_label_address'),
            value: this.form.address,
            placeholder: $r('app.string.node_placeholder_address'),
            onValue: (value: string) => {
              this.form.address = value;
            }
          })

          NodeTextField({
            label: $r('app.string.node_label_port'),
            value: this.form.portText,
            placeholder: $r('app.string.node_placeholder_port'),
            numeric: true,
            onValue: (value: string) => {
              this.form.portText = value;
            }
          })

          // ===== 协议参数 =====
          NodeFormSection({ title: $r('app.string.node_section_protocol') })

          if (this.form.isIdProtocol()) {
            Column({ space: Dimens.tight }) {
              Text($r('app.string.node_label_user_id'))
                .fontSize(FontSizes.caption)
                .fontColor(Theme.textSecondary)
              Row({ space: Dimens.item }) {
                TextInput({ text: this.form.userId, placeholder: $r('app.string.node_placeholder_uuid') })
                  .fontSize(FontSizes.body)
                  .backgroundColor(Theme.surfaceAlt)
                  .borderRadius(Radii.small)
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.form.userId = value;
                  })
                Button($r('app.string.node_label_generate'))
                  .fontSize(FontSizes.caption)
                  .backgroundColor(Theme.brandSoft)
                  .fontColor(Theme.brand)
                  .onClick(() => {
                    this.form.userId = util.generateRandomUUID();
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          if (this.form.hasPasswordField()) {
            NodeTextField({
              label: $r('app.string.node_label_password'),
              value: this.form.password,
              placeholder: $r('app.string.node_placeholder_password'),
              onValue: (value: string) => {
                this.form.password = value;
              }
            })
          }

          if (this.form.hasCipherField()) {
            NodeSelectField({
              label: $r('app.string.node_label_encryption'),
              options: this.form.protocol === ProxyProtocol.SHADOWSOCKS.toString()
                ? SS_CIPHER_OPTIONS
                : VMESS_SECURITY_OPTIONS,
              value: this.form.securityCipher,
              onValue: (value: string) => {
                this.form.securityCipher = value;
              }
            })
          }

          if (this.form.protocol === ProxyProtocol.VMESS.toString()) {
            NodeTextField({
              label: $r('app.string.node_label_alter_id'),
              value: this.form.alterIdText,
              placeholder: $r('app.string.node_placeholder_zero'),
              numeric: true,
              onValue: (value: string) => {
                this.form.alterIdText = value;
              }
            })
          }

          if (this.form.protocol === ProxyProtocol.VLESS.toString()) {
            NodeSelectField({
              label: $r('app.string.node_label_flow'),
              options: FLOW_OPTIONS,
              value: this.form.flow,
              onValue: (value: string) => {
                this.form.flow = value;
              }
            })
          }

          NodeSwitchField({
            label: $r('app.string.node_label_mux'),
            isOn: this.form.muxEnabled,
            onToggle: (value: boolean) => {
              this.form.muxEnabled = value;
            }
          })

          // ===== 底层传输方式 =====
          NodeFormSection({ title: $r('app.string.node_section_transport') })

          NodeSelectField({
            label: $r('app.string.node_label_network'),
            options: TRANSPORT_OPTIONS,
            value: this.form.transport,
            onValue: (value: string) => {
              this.form.transport = value;
            }
          })

          if (this.form.transport === TransportKind.GRPC.toString()) {
            NodeTextField({
              label: $r('app.string.node_label_service_name'),
              value: this.form.serviceName,
              placeholder: $r('app.string.node_placeholder_service_name'),
              onValue: (value: string) => {
                this.form.serviceName = value;
              }
            })
            NodeSelectField({
              label: $r('app.string.node_label_grpc_mode'),
              options: GRPC_MODE_OPTIONS,
              value: this.form.grpcMode,
              onValue: (value: string) => {
                this.form.grpcMode = value;
              }
            })
          }

          if (this.form.hasHostPathField()) {
            NodeTextField({
              label: $r('app.string.node_label_host'),
              value: this.form.host,
              placeholder: $r('app.string.node_placeholder_host'),
              onValue: (value: string) => {
                this.form.host = value;
              }
            })
            NodeTextField({
              label: $r('app.string.node_label_path'),
              value: this.form.path,
              placeholder: $r('app.string.node_placeholder_path'),
              onValue: (value: string) => {
                this.form.path = value;
              }
            })
          }

          if (this.form.transport === TransportKind.XHTTP.toString()) {
            NodeSelectField({
              label: $r('app.string.node_label_xhttp_mode'),
              options: XHTTP_MODE_OPTIONS,
              value: this.form.xhttpMode,
              onValue: (value: string) => {
                this.form.xhttpMode = value;
              }
            })
            NodeTextField({
              label: $r('app.string.node_label_xhttp_extra'),
              value: this.form.xhttpExtra,
              placeholder: $r('app.string.node_placeholder_empty'),
              onValue: (value: string) => {
                this.form.xhttpExtra = value;
              }
            })
          }

          if (this.form.transport === TransportKind.KCP.toString()) {
            NodeSelectField({
              label: $r('app.string.node_label_kcp_header'),
              options: KCP_HEADER_OPTIONS,
              value: this.form.kcpHeaderType,
              onValue: (value: string) => {
                this.form.kcpHeaderType = value;
              }
            })
          }

          if (this.form.transport === TransportKind.TCP.toString() ||
            this.form.transport === TransportKind.H2.toString()) {
            NodeSelectField({
              label: $r('app.string.node_label_raw_header'),
              options: RAW_HEADER_OPTIONS,
              value: this.form.rawHeaderType,
              onValue: (value: string) => {
                this.form.rawHeaderType = value;
              }
            })
          }

          NodeTextField({
            label: $r('app.string.node_label_finalmask'),
            value: this.form.finalmask,
            placeholder: $r('app.string.node_placeholder_empty'),
            onValue: (value: string) => {
              this.form.finalmask = value;
            }
          })

          // ===== 传输层安全 =====
          NodeFormSection({ title: $r('app.string.node_section_tls') })

          NodeSelectField({
            label: $r('app.string.node_label_stream_security'),
            options: SECURITY_OPTIONS,
            value: this.form.security,
            onValue: (value: string) => {
              this.form.security = value;
            }
          })

          if (this.form.hasTlsField()) {
            NodeTextField({
              label: $r('app.string.node_label_sni'),
              value: this.form.sni,
              placeholder: $r('app.string.node_placeholder_sni'),
              onValue: (value: string) => {
                this.form.sni = value;
              }
            })
            NodeSelectField({
              label: $r('app.string.node_label_fingerprint'),
              options: FINGERPRINT_OPTIONS,
              value: this.form.fingerprint,
              onValue: (value: string) => {
                this.form.fingerprint = value;
              }
            })
            NodeTextField({
              label: $r('app.string.node_label_alpn'),
              value: this.form.alpn,
              placeholder: $r('app.string.node_placeholder_alpn'),
              onValue: (value: string) => {
                this.form.alpn = value;
              }
            })
            NodeSwitchField({
              label: $r('app.string.node_label_allow_insecure'),
              isOn: this.form.allowInsecure,
              onToggle: (value: boolean) => {
                this.form.allowInsecure = value;
              }
            })
          }

          if (this.form.security === SecurityKind.REALITY.toString()) {
            NodeTextField({
              label: $r('app.string.node_label_public_key'),
              value: this.form.publicKey,
              placeholder: $r('app.string.node_placeholder_public_key'),
              onValue: (value: string) => {
                this.form.publicKey = value;
              }
            })
            NodeTextField({
              label: $r('app.string.node_label_short_id'),
              value: this.form.shortId,
              placeholder: $r('app.string.node_placeholder_empty'),
              onValue: (value: string) => {
                this.form.shortId = value;
              }
            })
            NodeTextField({
              label: $r('app.string.node_label_spider_x'),
              value: this.form.spiderX,
              placeholder: $r('app.string.node_placeholder_empty'),
              onValue: (value: string) => {
                this.form.spiderX = value;
              }
            })
          }

          NodeSwitchField({
            label: $r('app.string.node_label_enabled'),
            isOn: this.form.enabled,
            onToggle: (value: boolean) => {
              this.form.enabled = value;
            }
          })
        }
        .width('100%')
        .padding({ left: Dimens.page, right: Dimens.page, top: Dimens.item, bottom: Dimens.card })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // ---------------- 底部动作 ----------------
      Row({ space: Dimens.item }) {
        Button($r('app.string.subs_cancel'))
          .fontSize(FontSizes.body)
          .backgroundColor(Theme.surfaceAlt)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
          .onClick(() => {
            this.onCancel();
          })
        Button($r('app.string.subs_save'))
          .fontSize(FontSizes.body)
          .backgroundColor(Theme.brand)
          .fontColor(Theme.textOnBrand)
          .layoutWeight(1)
          .onClick(() => {
            this.onSave();
          })
      }
      .width('100%')
      .padding({ left: Dimens.page, right: Dimens.page, top: Dimens.item, bottom: Dimens.page })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.surface)
  }
}
