/**
 * SettingsPage.ets
 * 设置页。分组对齐 v2rayN 的 OptionSettingWindow 中在 HarmonyOS 端有意义的项：
 *   路由（全局/规则/直连、绕过大陆）、VPN/TUN（TUN、MTU、IPv6、允许局域网）、
 *   DNS 与嗅探、分应用代理（trusted/blocked applications）、日志、关于。
 * 所有改动都直接写回 SettingsViewModel，跨页面共享。
 */
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppProxyMode, LogLevel, RoutingMode } from '../model/Types';
import { settingsViewModel, SettingsViewModel } from '../viewmodel/SettingsViewModel';
import { connectionViewModel } from '../viewmodel/ConnectionViewModel';
import { logViewModel } from '../viewmodel/LogViewModel';
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { PROJECT_URL } from '../constants/Common';
import { MTU_MAX, MTU_MIN } from '../model/AppSettings';
import { Routes } from '../constants/Routes';
import { PageHeader } from '../components/PageHeader';
import { NavigationBar } from '../components/NavigationBar';
import { SettingGroupTitle, SettingSwitchRow, SettingTextRow, SettingValueRow } from '../components/SettingRow';
import { OptionPickerDialog, PickerKind } from '../components/OptionPickerDialog';
import { stringOf } from '../utils/TextFormat';
import { resourceManager } from '@kit.LocalizationKit';
import { GeoAssetService, GeoAssetStatus, GeoDownloadResult } from '../service/GeoAssetService';

@Entry
@ComponentV2
struct SettingsPage {
  @Local vm: SettingsViewModel = settingsViewModel;
  @Local pickerTitle: string = '';
  @Local pickerSelectedKey: string = '';
  @Local pickerKind: string = PickerKind.ROUTING;
  /** 选择项文案（在 aboutToAppear 里按当前语言求值一次；语言运行中变更会重建页面） */
  @Local pickerLabels: string[] = [];
  /** 分流资源（geoip.dat / geosite.dat）的状态文案 */
  @Local geoAssetText: string = '';
  /** 是否正在下载分流资源（防重复触发） */
  @Local geoBusy: boolean = false;

  private pickerController: CustomDialogController = new CustomDialogController({
    builder: OptionPickerDialog({
      title: this.pickerTitle,
      selectedKey: this.pickerSelectedKey,
      kind: this.pickerKind,
      labels: this.pickerLabels,
      onPick: (key: string) => {
        this.applyPick(key);
      }
    }),
    autoCancel: true,
    customStyle: true
  });

  aboutToAppear(): void {
    this.vm.init();
    this.loadAppVersion();
    this.loadPickerLabels();
    this.refreshGeoAssets();
  }

  // ---------------------- 分流资源（geoip.dat / geosite.dat） ----------------------

  /** 应用沙箱的 filesDir；拿不到 context 时返回空串（此时不做任何文件操作） */
  private filesDir(): string {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      return '';
    }
    return context.filesDir;
  }

  /**
   * 刷新分流资源状态。
   *
   * 这件事必须让用户看得见：资源缺失时 rule 模式的「绕过大陆」会**降级**
   * （生成器只给"私有网段直连 + 其余走代理"，并在 notes 里说明），
   * 而不是报错 —— 静默降级正是最难排查的那类问题。
   */
  private refreshGeoAssets(): void {
    const status: GeoAssetStatus = GeoAssetService.status(this.filesDir());
    if (status.present) {
      this.geoAssetText = this.text('settings_geo_state_ready') + '  ' +
        GeoAssetService.formatBytes(status.geoip.bytes) + ' / ' +
        GeoAssetService.formatBytes(status.geosite.bytes);
    } else {
      this.geoAssetText = this.text('settings_geo_state_missing');
    }
  }

  /** 下载（或重新下载）分流资源 */
  private async downloadGeoAssets(): Promise<void> {
    if (this.geoBusy) {
      return;
    }
    const dir: string = this.filesDir();
    if (dir.length === 0) {
      logViewModel.append(LogLevel.WARN, 'SettingsPage', 'geo download skipped: no filesDir');
      return;
    }
    this.geoBusy = true;
    this.geoAssetText = this.text('settings_geo_downloading');
    try {
      const result: GeoDownloadResult = await GeoAssetService.download(
        dir,
        (name: string, received: number, total: number) => {
          this.geoAssetText = this.text('settings_geo_downloading') + ' ' + name + ' ' +
            GeoAssetService.formatBytes(received) + ' / ' + GeoAssetService.formatBytes(total);
        }
      );
      if (result.ok) {
        logViewModel.append(LogLevel.INFO, 'SettingsPage', 'geo assets downloaded');
      } else {
        this.geoAssetText = this.text('settings_geo_download_failed');
        logViewModel.append(LogLevel.ERROR, 'SettingsPage', 'geo download failed: ' + result.error);
        return;
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      this.geoAssetText = this.text('settings_geo_download_failed');
      logViewModel.append(LogLevel.ERROR, 'SettingsPage', 'geo download threw: ' + err.message);
      return;
    } finally {
      this.geoBusy = false;
    }
    this.refreshGeoAssets();
  }

  /** 预取三类选择器的文案（顺序与对话框内的枚举顺序一致） */
  private loadPickerLabels(): void {
    const options: string[] = [
      this.text('settings_routing_global'),
      this.text('settings_routing_rule'),
      this.text('settings_routing_direct'),
      this.text('settings_app_mode_off'),
      this.text('settings_app_mode_allow'),
      this.text('settings_app_mode_block'),
      this.text('settings_log_level_debug'),
      this.text('settings_log_level_info'),
      this.text('settings_log_level_warn'),
      this.text('settings_log_level_error')
    ];
    this.pickerLabels = options;
    // 首次渲染前资源管理器可能尚未就绪：下一帧再补一次，保证弹窗文案不为空
    setTimeout(() => {
      if (this.pickerLabels.length > 0 && this.pickerLabels[0].length > 0) {
        return;
      }
      const retry: string[] = [
        this.text('settings_routing_global'),
        this.text('settings_routing_rule'),
        this.text('settings_routing_direct'),
        this.text('settings_app_mode_off'),
        this.text('settings_app_mode_allow'),
        this.text('settings_app_mode_block'),
        this.text('settings_log_level_debug'),
        this.text('settings_log_level_info'),
        this.text('settings_log_level_warn'),
        this.text('settings_log_level_error')
      ];
      this.pickerLabels = retry;
    }, 0);
  }

  /** 从 bundleManager 读取真实的应用版本号 */
  private loadAppVersion(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName.length > 0) {
        this.vm.appVersion = info.versionName;
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      this.vm.appVersion = '1.0.0';
      logViewModel.append(LogLevel.WARN, 'SettingsPage', 'read bundle info failed: ' + err.code.toString());
    }
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

  private routingModeText(): string {
    if (this.vm.routingMode === RoutingMode.GLOBAL) {
      return this.text('settings_routing_global');
    }
    if (this.vm.routingMode === RoutingMode.DIRECT) {
      return this.text('settings_routing_direct');
    }
    return this.text('settings_routing_rule');
  }

  private appProxyModeText(): string {
    if (this.vm.appProxyMode === AppProxyMode.ALLOW_LIST) {
      return this.text('settings_app_mode_allow');
    }
    if (this.vm.appProxyMode === AppProxyMode.BLOCK_LIST) {
      return this.text('settings_app_mode_block');
    }
    return this.text('settings_app_mode_off');
  }

  private openRoutingPicker(): void {
    this.pickerKind = 'routing';
    this.pickerTitle = this.text('settings_routing_mode');
    this.pickerSelectedKey = this.vm.routingMode.toString();
    this.pickerController.open();
  }

  private openAppProxyPicker(): void {
    this.pickerKind = 'appProxy';
    this.pickerTitle = this.text('settings_app_proxy_mode');
    this.pickerSelectedKey = this.vm.appProxyMode.toString();
    this.pickerController.open();
  }

  private openLogLevelPicker(): void {
    this.pickerKind = 'logLevel';
    this.pickerTitle = this.text('settings_log_level');
    this.pickerSelectedKey = this.vm.logLevel.toString();
    this.pickerController.open();
  }

  /** 选择器回调：按当前类别写回对应字段 */
  private applyPick(key: string): void {
    if (this.pickerKind === 'routing') {
      if (key === RoutingMode.GLOBAL.toString()) {
        this.vm.setRoutingMode(RoutingMode.GLOBAL);
        connectionViewModel.setRoutingMode(RoutingMode.GLOBAL);
      } else if (key === RoutingMode.DIRECT.toString()) {
        this.vm.setRoutingMode(RoutingMode.DIRECT);
        connectionViewModel.setRoutingMode(RoutingMode.DIRECT);
      } else {
        this.vm.setRoutingMode(RoutingMode.RULE);
        connectionViewModel.setRoutingMode(RoutingMode.RULE);
      }
      return;
    }
    if (this.pickerKind === 'appProxy') {
      if (key === AppProxyMode.ALLOW_LIST.toString()) {
        this.vm.setAppProxyMode(AppProxyMode.ALLOW_LIST);
      } else if (key === AppProxyMode.BLOCK_LIST.toString()) {
        this.vm.setAppProxyMode(AppProxyMode.BLOCK_LIST);
      } else {
        this.vm.setAppProxyMode(AppProxyMode.OFF);
      }
      return;
    }
    if (key === LogLevel.DEBUG.toString()) {
      this.vm.setLogLevel(LogLevel.DEBUG);
    } else if (key === LogLevel.WARN.toString()) {
      this.vm.setLogLevel(LogLevel.WARN);
    } else if (key === LogLevel.ERROR.toString()) {
      this.vm.setLogLevel(LogLevel.ERROR);
    } else {
      this.vm.setLogLevel(LogLevel.INFO);
    }
  }

  build() {
    Column() {
      PageHeader({ title: $r('app.string.settings_title'), showBack: false })

      Scroll() {
        Column() {
          // ---------------- 路由 ----------------
          SettingGroupTitle({ title: $r('app.string.settings_group_routing') })
          SettingsCard() {
            SettingValueRow({
              title: $r('app.string.settings_routing_mode'),
              value: this.routingModeText(),
              onTap: () => {
                this.openRoutingPicker();
              }
            })
            Divider().color(Theme.divider)
            SettingSwitchRow({
              title: $r('app.string.settings_bypass_cn'),
              checked: this.vm.bypassChina,
              onToggle: (value: boolean) => {
                this.vm.setBypassChina(value);
              }
            })
            Divider().color(Theme.divider)
            // 「绕过大陆」能不能真的按国家/地区分流，取决于这两份数据在不在
            // <filesDir>/assets 里；缺失时生成器会降级并给出 note，这里把它前置暴露。
            SettingValueRow({
              title: $r('app.string.settings_geo_assets'),
              value: this.geoAssetText,
              onTap: () => {
                this.downloadGeoAssets();
              }
            })
            Text($r('app.string.settings_geo_hint'))
              .fontSize(FontSizes.caption)
              .fontColor(Theme.textSecondary)
              .width('100%')
              .padding({ bottom: Dimens.item })
            Divider().color(Theme.divider)
            SettingSwitchRow({
              title: $r('app.string.settings_custom_rules'),
              checked: this.vm.customRulesEnabled,
              onToggle: (value: boolean) => {
                this.vm.setCustomRulesEnabled(value);
              }
            })
          }

          // ---------------- VPN / TUN ----------------
          SettingGroupTitle({ title: $r('app.string.settings_group_tun') })
          SettingsCard() {
            SettingSwitchRow({
              title: $r('app.string.settings_tun_enabled'),
              checked: this.vm.tunEnabled,
              onToggle: (value: boolean) => {
                this.vm.setTunEnabled(value);
              }
            })
            Divider().color(Theme.divider)
            SettingValueRow({
              title: $r('app.string.settings_mtu'),
              value: this.vm.mtu.toString(),
              clickable: false
            })
            Slider({
              value: this.vm.mtu,
              min: MTU_MIN,
              max: MTU_MAX,
              step: 4,
              style: SliderStyle.OutSet
            })
              .selectedColor(Theme.brand)
              .width('100%')
              .onChange((value: number) => {
                this.vm.setMtu(value);
              })
            Divider().color(Theme.divider)
            SettingSwitchRow({
              title: $r('app.string.settings_ipv6'),
              checked: this.vm.ipv6Enabled,
              onToggle: (value: boolean) => {
                this.vm.setIpv6Enabled(value);
              }
            })
            Divider().color(Theme.divider)
            SettingSwitchRow({
              title: $r('app.string.settings_allow_lan'),
              checked: this.vm.allowLan,
              onToggle: (value: boolean) => {
                this.vm.setAllowLan(value);
              }
            })
          }

          // ---------------- DNS / 嗅探 ----------------
          SettingGroupTitle({ title: $r('app.string.settings_group_dns') })
          SettingsCard() {
            SettingTextRow({
              title: $r('app.string.settings_dns_remote'),
              hint: $r('app.string.settings_dns_hint'),
              value: this.vm.remoteDns,
              onValueChange: (value: string) => {
                this.vm.setRemoteDns(value);
              }
            })
            Divider().color(Theme.divider)
            SettingTextRow({
              title: $r('app.string.settings_dns_direct'),
              hint: $r('app.string.settings_dns_hint'),
              value: this.vm.directDns,
              onValueChange: (value: string) => {
                this.vm.setDirectDns(value);
              }
            })
            Divider().color(Theme.divider)
            SettingSwitchRow({
              title: $r('app.string.settings_sniffing'),
              checked: this.vm.sniffingEnabled,
              onToggle: (value: boolean) => {
                this.vm.setSniffingEnabled(value);
              }
            })
            Divider().color(Theme.divider)
            SettingSwitchRow({
              title: $r('app.string.settings_sniffing_dest'),
              checked: this.vm.sniffingOverrideDestination,
              onToggle: (value: boolean) => {
                this.vm.setSniffingOverride(value);
              }
            })
          }

          // ---------------- 分应用代理 ----------------
          SettingGroupTitle({ title: $r('app.string.settings_group_app') })
          SettingsCard() {
            SettingValueRow({
              title: $r('app.string.settings_app_proxy_mode'),
              value: this.appProxyModeText(),
              onTap: () => {
                this.openAppProxyPicker();
              }
            })
            Divider().color(Theme.divider)
            SettingTextRow({
              title: $r('app.string.settings_app_list'),
              hint: $r('app.string.settings_app_list_hint'),
              value: this.vm.appProxyListText,
              onValueChange: (value: string) => {
                this.vm.setAppProxyListText(value);
              }
            })
          }

          // ---------------- 日志 ----------------
          SettingGroupTitle({ title: $r('app.string.settings_group_log') })
          SettingsCard() {
            SettingValueRow({
              title: $r('app.string.settings_log_level'),
              value: this.vm.logLevel.toString().toUpperCase(),
              onTap: () => {
                this.openLogLevelPicker();
              }
            })
            Divider().color(Theme.divider)
            SettingSwitchRow({
              title: $r('app.string.settings_log_to_file'),
              checked: this.vm.logToFile,
              onToggle: (value: boolean) => {
                this.vm.setLogToFile(value);
              }
            })
          }

          // ---------------- 关于 ----------------
          SettingGroupTitle({ title: $r('app.string.settings_group_about') })
          SettingsCard() {
            SettingValueRow({
              title: $r('app.string.settings_about_app'),
              value: this.vm.appVersion,
              clickable: false
            })
            Divider().color(Theme.divider)
            SettingValueRow({
              title: $r('app.string.settings_about_core'),
              value: this.vm.coreVersion.length > 0 ? this.vm.coreVersion : this.text('settings_about_core_unknown'),
              clickable: false
            })
            Divider().color(Theme.divider)
            SettingValueRow({
              title: $r('app.string.settings_about_license'),
              value: this.text('settings_about_license_value'),
              clickable: false
            })
            Divider().color(Theme.divider)
            SettingValueRow({
              title: $r('app.string.settings_about_source'),
              value: PROJECT_URL,
              clickable: false
            })
          }

          // ---------------- 保存 / 恢复默认 ----------------
          Row({ space: Dimens.item }) {
            Button($r('app.string.common_save'))
              .fontSize(FontSizes.body)
              .backgroundColor(Theme.brand)
              .fontColor(Theme.textOnBrand)
              .layoutWeight(1)
              .enabled(this.vm.dirty)
              .onClick(() => {
                this.vm.save();
              })
            Button($r('app.string.common_reset_default'))
              .fontSize(FontSizes.body)
              .backgroundColor(Theme.surfaceAlt)
              .fontColor(Theme.textPrimary)
              .layoutWeight(1)
              .onClick(() => {
                this.vm.resetToDefault();
              })
          }
          .width('100%')
          .padding({ top: Dimens.card, bottom: Dimens.card })
        }
        .width('100%')
        .padding({ left: Dimens.page, right: Dimens.page })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      NavigationBar({ current: Routes.SETTINGS })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

}

/**
 * 分组卡片外壳（设置页六个分组共用）。
 *
 * 为什么是独立结构体而不是 `@Builder Card(content: () => void) { Column() { content() } }`：
 * ArkUI 的 UI 语法校验不允许在 build / @Builder 体内直接调用「函数类型的参数」——
 * 编译器报 `'content()' does not meet UI component syntax`。
 * 传入 UI 结构的唯一受支持写法是 @BuilderParam + 尾随闭包（结构体）。
 */
@Builder
function emptyCardContent(): void {
}

@ComponentV2
struct SettingsCard {
  /**
   * 卡片内容。必须给默认值：预览器的 lint 规则
   * `mandatory-default-value-for-local-initialization` 要求「支持本地初始化的组件属性」
   * 必须有合法且不依赖运行时的默认值，否则预览会被拦截（"Preview check failed"）。
   * 本页 6 个分组都传了尾随闭包，这个默认值不会被实际渲染。
   */
  @BuilderParam contentSection: () => void = emptyCardContent;

  build() {
    Column() {
      this.contentSection()
    }
    .width('100%')
    .padding({ left: Dimens.card, right: Dimens.card })
    .backgroundColor(Theme.surface)
    .borderRadius(Radii.card)
    .margin({ bottom: Dimens.tight })
  }
}