/**
 * ConnectionViewModel.ets
 * 首页/连接状态机：连接、断开、选中节点、实时流量、路由模式。
 *
 * 连接流程（真实链路）：
 *   1. Bridge.generateConfig()  -> 在沙箱里生成内核 config.json
 *   2. Bridge.connectVpn()      -> startVpnExtensionAbility + connectServiceExtensionAbility
 *   3. Bridge.startCore()       -> 由扩展进程拉起 Xray/sing-box
 *   4. TrafficMonitor 订阅 VPN_TRAFFIC 刷新速率/累计流量
 * 断开流程按 3 -> 2 的顺序反向执行。
 *
 * MOCK 模式下 1~3 由 Bridge 内部模拟，4 由本文件用定时器产生模拟流量，
 * 从而让 UI 的「连接 / 速率 / 累计流量」在没有内核时也是可见、可验证的。
 */
import { common } from '@kit.AbilityKit';
import { ConnectionState, emptyTrafficStats, RoutingMode, TrafficStats } from '../model/Types';
import { nodeToJsonText, ServerNode } from '../model/ServerNode';
import { Bridge, ConfigPathResult, MOCK_BRIDGE, StartCoreResult } from '../core/Bridge';
import { ConfigStore } from '../core/ConfigStore';
import { TrafficMonitor } from '../core/TrafficMonitor';
import { Logger } from '../utils/Logger';
import { nodeViewModel } from './NodeViewModel';
import { settingsViewModel } from './SettingsViewModel';

const TAG: string = 'ConnectionViewModel';
/** MOCK 流量刷新间隔（毫秒） */
const MOCK_TICK_MS: number = 1000;

/** 连接页 ViewModel */
@ObservedV2
export class ConnectionViewModel {
  /** 连接状态机 */
  @Trace state: ConnectionState = ConnectionState.DISCONNECTED;
  /** 实时流量统计 */
  @Trace traffic: TrafficStats = emptyTrafficStats();
  /** 当前路由模式（与 SettingsViewModel 同步） */
  @Trace routingMode: RoutingMode = RoutingMode.RULE;
  /** 内核版本（启动后由 Bridge 填充） */
  @Trace coreVersion: string = '';
  /**
   * 内核的本地入站**是否真的在监听**（契约 §4.1 的 `wired`，不是"tun 已挂载"）。
   *
   * **本阶段恒为 false**：没有真机、真实监听未验证。把它做成可观察状态，是为了不让
   * UI 把"内核已启动"和"数据面已连通"混为一谈 —— 前者由 `state === CONNECTED`
   * 表达，后者只能由这个字段表达。
   * ⚠️ 给 wired=false 加一条独立的界面提示需要新增 string 资源（`$r('app.string.*')`，
   * 见 AGENT.md §3 第 8 条），本轮没有新增资源，因此界面上的诚实表达仍由既有的
   * MOCK 横幅承担（`mockMode === true`）；日志侧则逐条打印原生 notes。
   */
  @Trace coreWired: boolean = false;
  /** 最近一次错误信息 */
  @Trace lastError: string = '';
  /** 是否 MOCK 模式（首页横幅） */
  @Trace mockMode: boolean = MOCK_BRIDGE;

  /** VPN 扩展连接 id；-1 表示未连接 */
  private connectionId: number = -1;
  /** 当前用于连接的内核配置路径 */
  private configPath: string = '';
  private assetPath: string = '';
  private mockTimerId: number = -1;
  private trafficBound: boolean = false;

  /** 幂等初始化 */
  init(): void {
    if (this.trafficBound) {
      return;
    }
    this.trafficBound = true;
    this.routingMode = settingsViewModel.routingMode;
    this.bindTraffic();
    this.refreshCoreVersion();
  }

  /** 订阅流量事件 */
  private bindTraffic(): void {
    TrafficMonitor.start((stats: TrafficStats) => {
      this.traffic = stats;
    });
    this.traffic = TrafficMonitor.latest();
  }

  /** 拉取内核版本（Mock 下也能拿到占位版本，便于 UI 展示） */
  async refreshCoreVersion(): Promise<void> {
    const version: string = await Bridge.version();
    if (version.length > 0) {
      this.coreVersion = version;
      settingsViewModel.setCoreVersion(version);
    }
  }

  /** 当前选中节点 */
  currentNode(): ServerNode | undefined {
    return nodeViewModel.selectedNode();
  }

  /** 是否处于「已连接」 */
  isConnected(): boolean {
    return this.state === ConnectionState.CONNECTED;
  }

  /** 是否处于过渡态（连接中/断开中），UI 据此禁用按钮 */
  isBusy(): boolean {
    return this.state === ConnectionState.CONNECTING || this.state === ConnectionState.DISCONNECTING;
  }

  /** 连接 / 断开 的统一切换入口（首页大按钮直接调用） */
  async toggle(context: common.UIAbilityContext | undefined): Promise<void> {
    if (this.isBusy()) {
      return;
    }
    if (this.isConnected() || this.state === ConnectionState.ERROR) {
      await this.disconnect(context);
    } else {
      await this.connect(context);
    }
  }

  /** 建立连接 */
  async connect(context: common.UIAbilityContext | undefined): Promise<void> {
    if (this.isBusy() || this.isConnected()) {
      return;
    }
    const node: ServerNode | undefined = this.currentNode();
    if (node === undefined) {
      this.lastError = 'no-node-selected';
      Logger.warn(TAG, 'connect skipped: no node selected');
      return;
    }
    this.lastError = '';
    this.transition(ConnectionState.CONNECTING);
    try {
      const settings = settingsViewModel.snapshot();
      // extra = 节点完整字段的 JSON（见 model/ServerNode.ets#nodeToJsonText 与
      // docs/design/ipc-contract.md §4 「ConfigService.Generate」）。
      // 原生侧只认这份 JSON，不去查 ArkTS 的节点表。
      const filesDir: string = context !== undefined ? context.filesDir : '';
      const generated: ConfigPathResult = await Bridge.generateConfig(
        node.id,
        settings.routingMode.toString(),
        settings.bypassChina,
        nodeToJsonText(node),
        ConfigStore.pathsOf(filesDir)
      );
      // 生成器的妥协项（被内核删除的特性、分流降级）必须落到日志里，
      // 否则用户只会看到"连上了但行为不对"。
      for (let i = 0; i < generated.notes.length; i++) {
        Logger.warn(TAG, 'config note: ' + generated.notes[i]);
      }
      this.configPath = generated.configPath;
      this.assetPath = generated.assetPath;
      // 入站端口**只有一个来源**：ConfigService.Generate 的结果（原生回显的正是它
      // 写进 config.json 的那个端口）。同一份值同时给 Start 与 VPN 扩展进程
      // （扩展里的 tun2socks 要连它）。此前三处各自写死 10808，一旦漂移的症状是
      // "tun2socks 连到一个没人在听的端口" —— 静默不通，没有任何报错。
      const socksPort: number = generated.socksPort;
      const httpPort: number = generated.httpPort;

      if (context !== undefined) {
        this.connectionId = await Bridge.connectVpn(
          context, this.configPath, this.assetPath, socksPort, httpPort
        );
      } else {
        Logger.warn(TAG, 'connect without UIAbilityContext: VPN extension not started');
      }

      const started: StartCoreResult = await Bridge.startCore(
        this.configPath, this.assetPath, socksPort, httpPort
      );
      // 成功判据是 `started.ok`（= 信封成功 **且** 原生回报 started===true）。
      //
      // 🔴 曾经的真 bug：这里写的是 `started.pid <= 0`，而 `pid` 按契约**恒为 0**
      // （内核跑在 VPN 扩展进程内，不是独立进程），于是**原生明明启动成功，UI 也
      // 必然判失败**。pid 不是判据，ok 才是。
      if (!started.ok) {
        this.lastError = started.error.length > 0
          ? 'start-core-failed: ' + started.error
          : 'start-core-failed';
        this.transition(ConnectionState.ERROR);
        Logger.error(TAG, 'connect aborted: ' + this.lastError);
        return;
      }
      // wired=false 是本阶段的常态，不是可以省略的细节：内核起来了但本地入站还没
      // 真实监听，流量此时过不去。如实体现在状态与日志里，不让 UI 假装"已连通"。
      this.coreWired = started.wired;
      for (let i = 0; i < started.notes.length; i++) {
        Logger.warn(TAG, 'start note: ' + started.notes[i]);
      }
      if (!this.coreWired) {
        Logger.warn(TAG, 'core started but wired=false: no local inbound is listening, '
          + 'traffic cannot flow yet (this is the expected state in the current phase)');
      }
      await this.refreshCoreVersion();
      this.transition(ConnectionState.CONNECTED);
      this.startMockTrafficIfNeeded();
      Logger.info(TAG, 'core started for ' + node.remarks
        + ' (socks=' + started.socksPort.toString()
        + ', http=' + started.httpPort.toString()
        + ', wired=' + started.wired.toString() + ')');
    } catch (error) {
      this.lastError = Logger.describe(error as Object);
      this.transition(ConnectionState.ERROR);
      Logger.error(TAG, 'connect failed: ' + this.lastError);
    }
  }

  /** 断开连接 */
  async disconnect(context: common.UIAbilityContext | undefined): Promise<void> {
    if (this.state === ConnectionState.DISCONNECTED || this.state === ConnectionState.DISCONNECTING) {
      return;
    }
    this.transition(ConnectionState.DISCONNECTING);
    try {
      this.stopMockTraffic();
      await Bridge.stopCore();
      if (context !== undefined && this.connectionId >= 0) {
        await Bridge.disconnectVpn(context, this.connectionId);
      }
      this.connectionId = -1;
      this.coreWired = false;
      this.traffic = emptyTrafficStats();
      this.transition(ConnectionState.DISCONNECTED);
      Logger.info(TAG, 'disconnected');
    } catch (error) {
      this.lastError = Logger.describe(error as Object);
      this.transition(ConnectionState.ERROR);
      Logger.error(TAG, 'disconnect failed: ' + this.lastError);
    }
  }

  /** 同步路由模式（首页/设置页都可切换） */
  setRoutingMode(mode: RoutingMode): void {
    this.routingMode = mode;
    settingsViewModel.setRoutingMode(mode);
    Logger.info(TAG, 'routing mode -> ' + mode.toString());
  }

  /** 状态迁移 + 日志 */
  private transition(next: ConnectionState): void {
    if (this.state === next) {
      return;
    }
    Logger.info(TAG, 'state ' + this.state.toString() + ' -> ' + next.toString());
    this.state = next;
  }

  // -------------------------------------------------------------------------
  // MOCK 流量：内核未接入时让「速率 / 累计」也有可观察的变化
  // -------------------------------------------------------------------------

  private startMockTrafficIfNeeded(): void {
    if (!MOCK_BRIDGE || this.mockTimerId >= 0) {
      return;
    }
    this.mockTimerId = setInterval(() => {
      const previous: TrafficStats = this.traffic;
      const speedUp: number = 20 * 1024 + Math.floor(Math.random() * 180 * 1024);
      const speedDown: number = 120 * 1024 + Math.floor(Math.random() * 1800 * 1024);
      const stats: TrafficStats = {
        speedUp: speedUp,
        speedDown: speedDown,
        totalUp: previous.totalUp + speedUp,
        totalDown: previous.totalDown + speedDown,
        updatedAt: Date.now()
      };
      TrafficMonitor.publish(stats);
    }, MOCK_TICK_MS);
  }

  private stopMockTraffic(): void {
    if (this.mockTimerId < 0) {
      return;
    }
    clearInterval(this.mockTimerId);
    this.mockTimerId = -1;
  }
}

/** 全局单例：首页与其它页面共享连接状态 */
export const connectionViewModel: ConnectionViewModel = new ConnectionViewModel();
