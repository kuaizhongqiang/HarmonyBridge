/**
 * SettingsViewModel.ets
 * 设置页状态：持有 AppSettings 的扁平副本（每个字段都标注 @Trace，逐项可观察），
 * 暴露 intent 方法给 UI 调用；后续接入 preferences 持久化时只需在 save() 里落盘。
 */
import { AppProxyMode, LogLevel, RoutingMode } from '../model/Types';
import {
  AppSettings,
  DEFAULT_DNS_DIRECT,
  DEFAULT_DNS_REMOTE,
  defaultSettings,
  MTU_MAX,
  MTU_MIN
} from '../model/AppSettings';
import { Logger } from '../utils/Logger';

const TAG: string = 'SettingsViewModel';

/** 设置页 ViewModel */
@ObservedV2
export class SettingsViewModel {
  @Trace routingMode: RoutingMode = RoutingMode.RULE;
  @Trace customRulesEnabled: boolean = false;
  @Trace bypassChina: boolean = true;

  @Trace tunEnabled: boolean = true;
  @Trace mtu: number = 1500;
  @Trace ipv6Enabled: boolean = false;
  @Trace allowLan: boolean = false;

  @Trace remoteDns: string = DEFAULT_DNS_REMOTE;
  @Trace directDns: string = DEFAULT_DNS_DIRECT;
  @Trace sniffingEnabled: boolean = true;
  @Trace sniffingOverrideDestination: boolean = true;

  @Trace appProxyMode: AppProxyMode = AppProxyMode.OFF;
  @Trace appProxyListText: string = '';

  @Trace logLevel: LogLevel = LogLevel.INFO;
  @Trace logToFile: boolean = false;

  /** 应用版本（由 AboutSection 展示，暂时写常量，后续从 bundleManager 读取） */
  @Trace appVersion: string = '1.0.0';
  /** 内核版本（由 Bridge 异步填充） */
  @Trace coreVersion: string = '';
  /** 是否有未保存的修改 */
  @Trace dirty: boolean = false;

  private seeded: boolean = false;

  /** 幂等初始化：从默认设置装载 */
  init(): void {
    if (this.seeded) {
      return;
    }
    this.seeded = true;
    this.apply(defaultSettings());
    this.dirty = false;
  }

  /** 用一份设置快照覆盖全部字段 */
  apply(settings: AppSettings): void {
    this.routingMode = settings.routingMode;
    this.customRulesEnabled = settings.customRulesEnabled;
    this.bypassChina = settings.bypassChina;
    this.tunEnabled = settings.tunEnabled;
    this.mtu = settings.mtu;
    this.ipv6Enabled = settings.ipv6Enabled;
    this.allowLan = settings.allowLan;
    this.remoteDns = settings.remoteDns;
    this.directDns = settings.directDns;
    this.sniffingEnabled = settings.sniffingEnabled;
    this.sniffingOverrideDestination = settings.sniffingOverrideDestination;
    this.appProxyMode = settings.appProxyMode;
    this.appProxyListText = settings.appProxyList.join(', ');
    this.logLevel = settings.logLevel;
    this.logToFile = settings.logToFile;
    this.dirty = false;
  }

  /** 导出当前设置为一份快照（传给 Bridge / 配置生成器） */
  snapshot(): AppSettings {
    const settings: AppSettings = {
      routingMode: this.routingMode,
      customRulesEnabled: this.customRulesEnabled,
      bypassChina: this.bypassChina,
      tunEnabled: this.tunEnabled,
      mtu: this.mtu,
      ipv6Enabled: this.ipv6Enabled,
      allowLan: this.allowLan,
      remoteDns: this.remoteDns,
      directDns: this.directDns,
      sniffingEnabled: this.sniffingEnabled,
      sniffingOverrideDestination: this.sniffingOverrideDestination,
      appProxyMode: this.appProxyMode,
      appProxyList: this.appProxyList(),
      logLevel: this.logLevel,
      logToFile: this.logToFile,
      coreAutoRestart: false
    };
    return settings;
  }

  /** 分应用清单（把逗号分隔文本解析成数组） */
  appProxyList(): string[] {
    const result: string[] = [];
    const parts: string[] = this.appProxyListText.split(',');
    for (let i = 0; i < parts.length; i++) {
      const item: string = parts[i].trim();
      if (item.length > 0) {
        result.push(item);
      }
    }
    return result;
  }

  /** 挂载到 VpnConfig 时需要的应用列表（按模式取 allow 或 block） */
  appProxyBundleNames(): string[] {
    if (this.appProxyMode === AppProxyMode.OFF) {
      return [];
    }
    return this.appProxyList();
  }

  /** 修改路由模式 */
  setRoutingMode(mode: RoutingMode): void {
    this.routingMode = mode;
    this.dirty = true;
    Logger.info(TAG, 'routingMode -> ' + mode.toString());
  }

  /** 修改 MTU（自动夹紧到系统允许的 576~1500） */
  setMtu(value: number): void {
    let next: number = Math.floor(value);
    if (next < MTU_MIN) {
      next = MTU_MIN;
    }
    if (next > MTU_MAX) {
      next = MTU_MAX;
    }
    this.mtu = next;
    this.dirty = true;
  }

  /** 修改分应用代理模式 */
  setAppProxyMode(mode: AppProxyMode): void {
    this.appProxyMode = mode;
    this.dirty = true;
  }

  /** 修改日志级别 */
  setLogLevel(level: LogLevel): void {
    this.logLevel = level;
    this.dirty = true;
  }

  /** 通用布尔开关变更（由页面按字段名逐个调用具体 setter，避免动态属性访问） */
  setTunEnabled(value: boolean): void {
    this.tunEnabled = value;
    this.dirty = true;
  }

  setIpv6Enabled(value: boolean): void {
    this.ipv6Enabled = value;
    this.dirty = true;
  }

  setAllowLan(value: boolean): void {
    this.allowLan = value;
    this.dirty = true;
  }

  setBypassChina(value: boolean): void {
    this.bypassChina = value;
    this.dirty = true;
  }

  setCustomRulesEnabled(value: boolean): void {
    this.customRulesEnabled = value;
    this.dirty = true;
  }

  setSniffingEnabled(value: boolean): void {
    this.sniffingEnabled = value;
    this.dirty = true;
  }

  setSniffingOverride(value: boolean): void {
    this.sniffingOverrideDestination = value;
    this.dirty = true;
  }

  setLogToFile(value: boolean): void {
    this.logToFile = value;
    this.dirty = true;
  }

  setRemoteDns(value: string): void {
    this.remoteDns = value;
    this.dirty = true;
  }

  setDirectDns(value: string): void {
    this.directDns = value;
    this.dirty = true;
  }

  setAppProxyListText(value: string): void {
    this.appProxyListText = value;
    this.dirty = true;
  }

  /** 保存（当前是内存态；接入 preferences 后在此落盘） */
  save(): void {
    this.dirty = false;
    Logger.info(TAG, 'settings saved (in-memory)');
  }

  /** 恢复默认 */
  resetToDefault(): void {
    this.apply(defaultSettings());
    this.dirty = true;
  }

  /** 设置内核版本展示值 */
  setCoreVersion(version: string): void {
    this.coreVersion = version;
  }
}

/** 全局单例：设置页与首页共享同一份状态 */
export const settingsViewModel: SettingsViewModel = new SettingsViewModel();
