/**
 * ConnectionViewModel.ets
 * 首页/连接状态机：连接、断开、选中节点、实时流量、路由模式。
 *
 * 连接流程（真实链路）：
 *   1. Bridge.generateConfig()  -> 在沙箱里生成内核 config.json
 *   2. Bridge.connectVpn()      -> startVpnExtensionAbility（用户授权后扩展进程建 vpn-tun）
 *   3. Bridge.startCore()       -> 由扩展进程拉起 Xray/sing-box
 *   4. TrafficMonitor 订阅 VPN_TRAFFIC 刷新速率/累计流量
 * 断开流程：stopCore -> stopVpnExtensionAbility。
 *
 * ⚠️ 第 2 步**不再**用 `connectServiceExtensionAbility`（2026-10-12 真机实测否掉了那条路，
 * 证据见 `core/Bridge.ets#connectVpn`），因此这里也不再持有 ServiceExtension 连接 id ——
 * `connectionId` 现在只表示"扩展是否被成功拉起"（0 成功 / -1 失败）。
 *
 * MOCK 模式下 1~3 由 Bridge 内部模拟，4 由本文件用定时器产生模拟流量，
 * 从而让 UI 的「连接 / 速率 / 累计流量」在没有内核时也是可见、可验证的。
 */
import { common } from '@kit.AbilityKit';
import { ConnectionState, emptyTrafficStats, RoutingMode, TrafficStats } from '../model/Types';
import { nodeToJsonText, ServerNode } from '../model/ServerNode';
import { Bridge, ConfigPathResult, MOCK_BRIDGE } from '../core/Bridge';
import { CoreState, CoreStateMonitor } from '../core/CoreStateMonitor';
import { ConfigStore } from '../core/ConfigStore';
import { TrafficMonitor } from '../core/TrafficMonitor';
import { Logger } from '../utils/Logger';
import { nodeViewModel } from './NodeViewModel';
import { settingsViewModel } from './SettingsViewModel';

const TAG: string = 'ConnectionViewModel';
/** MOCK 流量刷新间隔（毫秒） */
const MOCK_TICK_MS: number = 1000;
/**
 * 等待扩展进程上报内核状态的超时（毫秒）。
 *
 * 超时就如实报错**并把已经拉起的 VPN 收掉** —— 宁可"连接失败"，也不留一个
 * "抓了所有流量却没人处理"的网卡（那正是用户断网的形态）。
 */
const CORE_STATE_TIMEOUT_MS: number = 15000;

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
    // 只订阅事件，**不**在这里问内核版本：内核跑在扩展进程里，UI 进程去问只会
    // 白搭一次 33 MB 的 `libcore.so` 加载，再拿到自己那份从未启动过的空实例的答案。
    // 版本由扩展进程在启动后随状态事件一起上报（见 CoreStateMonitor）。
    CoreStateMonitor.start();
  }

  /** 订阅流量事件 */
  private bindTraffic(): void {
    TrafficMonitor.start((stats: TrafficStats) => {
      this.traffic = stats;
    });
    this.traffic = TrafficMonitor.latest();
  }

  // 说明：这里**曾经**有一个 refreshCoreVersion()，它在 UI 进程里调 Bridge.version()。
  // 内核搬到扩展进程之后它就成了误导：UI 进程会因此加载一份自己永远不会使用的
  // libcore.so，并把它那份空实例的答案当成"内核版本"。版本现在随
  // CoreStateMonitor 的状态事件从扩展进程过来。

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
      await this.disconnect();
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

      if (context === undefined) {
        // 没有 context 就没有 filesDir，配置根本没落盘 —— 如实报错，不要往下走。
        this.lastError = 'connect-without-context';
        this.transition(ConnectionState.ERROR);
        Logger.error(TAG, 'connect aborted: no UIAbilityContext');
        return;
      }

      // 在发起连接**之前**开始监听内核状态：扩展进程报得很快，先订阅才不会漏掉第一条。
      CoreStateMonitor.start();
      this.connectionId = await Bridge.connectVpn(
        this.configPath, this.assetPath, socksPort, httpPort
      );

      // 🔴 内核**不在这里启动**。它由 VPN 扩展进程自己拉起
      // （`VpnAbility#startCoreInProcess`）—— 这是 2026-10-12 真机实测后的修正：
      // 原先在 **UI 进程**里启动内核，用户一切到别的应用，UI 进程就被系统冻结
      // （实测 cpuTicks 10 秒内 delta = 0），Xray 随之停摆；而扩展进程里的
      // tun2socks 仍在往 10808 送流量 —— `SYN_SENT` 堆积、上行计数照涨、
      // **下行归零**。完整证据链见 `VpnAbility#startCoreInProcess` 的注释。
      //
      // 这里只等扩展进程把真实状态报过来；超时即如实报错，绝不假装成功。
      const state: CoreState | undefined = await CoreStateMonitor.wait(CORE_STATE_TIMEOUT_MS);
      if (state === undefined) {
        this.lastError = 'core-state-timeout';
        this.transition(ConnectionState.ERROR);
        Logger.error(TAG, 'the VPN extension reported no core state within '
          + CORE_STATE_TIMEOUT_MS.toString() + 'ms');
        // 把已经拉起来的 VPN 收掉，避免留下一个"抓了流量但没人处理"的网卡。
        await Bridge.disconnectVpn();
        return;
      }
      if (!state.started) {
        this.lastError = state.error.length > 0
          ? 'start-core-failed: ' + state.error
          : 'start-core-failed';
        this.transition(ConnectionState.ERROR);
        Logger.error(TAG, 'connect aborted: ' + this.lastError);
        return;
      }

      // 端口以**内核实际声明**的为准（扩展进程回传）；拿不到时回落本地值。
      const reportedSocks: number = state.socksPort > 0 ? state.socksPort : socksPort;
      const reportedHttp: number = state.httpPort > 0 ? state.httpPort : httpPort;
      // wired 的权威定义在扩展进程里：「内核已启动」**且**「tun2socks 已运行」。
      // （Go 内核自己的 wired 字段恒为 false，是一句改不掉的假话 —— 见 VpnAbility。）
      this.coreWired = state.wired;
      if (state.version.length > 0) {
        this.coreVersion = state.version;
        settingsViewModel.setCoreVersion(state.version);
      }
      if (!this.coreWired) {
        Logger.warn(TAG, 'core started but wired=false: the local inbound is not usable yet '
          + '(tun2socks not running, or the core refused to listen)');
      }

      this.transition(ConnectionState.CONNECTED);
      this.startMockTrafficIfNeeded();
      Logger.info(TAG, 'core started for ' + node.remarks
        + ' (socks=' + reportedSocks.toString()
        + ', http=' + reportedHttp.toString()
        + ', wired=' + this.coreWired.toString()
        + ', version=' + this.coreVersion + ')');
    } catch (error) {
      this.lastError = Logger.describe(error as Object);
      this.transition(ConnectionState.ERROR);
      Logger.error(TAG, 'connect failed: ' + this.lastError);
    }
  }

  /** 断开连接 */
  async disconnect(): Promise<void> {
    if (this.state === ConnectionState.DISCONNECTED || this.state === ConnectionState.DISCONNECTING) {
      return;
    }
    this.transition(ConnectionState.DISCONNECTING);
    try {
      this.stopMockTraffic();
      // ⚠️ 这里**不再**调 `Bridge.stopCore()`：内核跑在扩展进程里，UI 进程调它只会
      // 停掉自己那份从未启动过的空实例，而真正的内核照样在跑 —— 一个"看起来停了、
      // 其实没停"的假动作，比不做更糟。
      // 内核由扩展进程在 `onDestroy` 时随进程一起结束；这里只负责让系统关掉扩展。
      //
      // **无条件**请求系统关闭扩展（多调一次是幂等的）。漏掉一次的代价是 VPN
      // 留在那里、用户断网 —— 所以宁滥勿缺。
      await Bridge.disconnectVpn();
      CoreStateMonitor.stop();
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
