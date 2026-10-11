/**
 * VpnAbility.ets
 * HarmonyOS 第三方 VPN 扩展（VpnExtensionAbility）骨架。
 *
 * 它在 module.json5 里声明为：{ name: "VpnAbility", srcEntry: "./ets/vpnability/VpnAbility.ets", type: "vpn" }，
 * 只需要 ohos.permission.INTERNET，不需要（也拿不到）ohos.permission.MANAGE_VPN。
 *
 * 生命周期 —— 只以 SDK 契约里声明的回调为准：
 *   onCreate(want)   -> 建立 VpnConnection，并**立即 create(config) 拿到虚拟网卡 fd**；
 *                       同时从 want.parameters 取出配置路径 / 资源目录。
 *                       这个 fd 之后交给 **tun2socks**（不是内核的 tun 入站）；
 *                       内核只做本地 SOCKS/HTTP 入站（裁决见
 *                       docs/design/ipc-contract.md §2）。
 *   onDestroy()      -> 清理定时器 + process.ProcessManager().exit(0) 退出扩展进程
 *
 * ⚠️ 关于 onConnect / onDisconnected：
 *   它们是**本项目自创的方法名**。本机 SDK 的
 *   @ohos.app.ability.VpnExtensionAbility.d.ts 只声明了 onCreate(want) 与 onDestroy()
 *   （已逐行复核），运行时是否回调它们属于未证实项。因此：
 *   - 网卡的创建放在 onCreate —— 那是唯一**确定**会被调用的入口。若等 onConnect
 *     才创建，而运行时又不调用它，结果就是"扩展起来了、却没有任何网卡"，VPN 完全不生效；
 *   - onConnect / onDisconnected 只作为"若某版本确实会回调则额外可观测/兜底"保留，
 *     并且与 onCreate 共享幂等守卫，绝不会重复建网卡。
 *
 * 说明：数据面通过 core/Bridge 的 `DataPlane` 门面调用原生 tun2socks
 * （libhevsocks5tun.so，构建见 scripts/build-tun2socks.*）。内核 libcore.so 的
 * 拉起不在本文件里（CoreService.Start 负责），本文件只负责"把 fd 交给数据面"。
 */
import { VpnExtensionAbility } from '@kit.NetworkKit';
import { vpnExtension } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { statistics } from '@kit.NetworkKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import {
  APP_BUNDLE_NAME,
  CORE_HTTP_PORT,
  CORE_SOCKS_PORT,
  VPN_IFACE_NAME,
  VPN_TRAFFIC_EVENT,
  VPN_TUN_ADDRESS,
  VPN_TUN_DNS,
  VPN_TUN_PREFIX_LENGTH,
  WANT_KEY_ASSET_PATH,
  WANT_KEY_CONFIG_PATH,
  WANT_KEY_HTTP_PORT,
  WANT_KEY_SOCKS_PORT
} from '../constants/Common';
import { DataPlane, DataPlaneStartResult } from '../core/Bridge';

/** 日志域 / 标签（扩展进程独立打日志，便于 hdc 过滤） */
const DOMAIN: number = 0x0000;
const TAG: string = 'VpnAbility';

/** 流量上报间隔（毫秒） */
const TRAFFIC_INTERVAL_MS: number = 1000;
/** 默认 MTU（与设置页默认值保持一致，可被配置覆盖） */
const DEFAULT_MTU: number = 1500;
// ⚠️ 这里**不再**有 `const SOCKS_PORT = 10808`。
// 端口由 UI 进程通过 want.parameters 传进来（WANT_KEY_SOCKS_PORT / WANT_KEY_HTTP_PORT），
// 因为扩展是**另一个进程**，拿不到 UI 的 ConfigPathResult；回落值统一取
// constants/Common.ets 的 CORE_SOCKS_PORT / CORE_HTTP_PORT（唯一 ArkTS 来源）。
// 曾经的缺陷：这个文件、Bridge 的 Start 默认值、Go 侧的 DefaultSocksPort 各自
// 写死同一个数字，一旦漂移，症状是 tun2socks 连到一个没人在听的端口 —— 静默不通。

export default class VpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined = undefined;
  /** 内核写入的配置路径（来自 want.parameters[CONFIG_PATH]） */
  private configPath: string = '';
  /** 资源目录（geoip / geosite 等，来自 want.parameters[ASSET_PATH]） */
  private assetPath: string = '';
  /**
   * 内核本地入站端口，来自 want.parameters（UI 进程转交的
   * `ConfigService.Generate` 结果值）。收不到时回落到 constants/Common 的常量。
   */
  private socksPort: number = CORE_SOCKS_PORT;
  private httpPort: number = CORE_HTTP_PORT;
  /**
   * 网卡创建状态。onCreate（SDK 契约保证）与 onConnect（非契约、运行时可能不被
   * 回调）都会尝试创建网卡，用这两个标志做幂等守卫，保证恰好创建一次。
   */
  private vpnCreating: boolean = false;
  private vpnCreated: boolean = false;
  /** 定时器 id */
  private timerId: number = -1;
  /** 上一次采样的收发字节数，用于计算瞬时速率 */
  private lastTx: number = 0;
  private lastRx: number = 0;

  onCreate(want: Want): void {
    this.configPath = readWantString(want, WANT_KEY_CONFIG_PATH);
    this.assetPath = readWantString(want, WANT_KEY_ASSET_PATH);
    // 端口从 want 收；收不到就用常量回落。两者都会打印，方便在真机上一条日志就
    // 看出"tun2socks 要连的端口"与"内核该监听的端口"是否一致。
    this.socksPort = readWantPort(want, WANT_KEY_SOCKS_PORT, CORE_SOCKS_PORT);
    this.httpPort = readWantPort(want, WANT_KEY_HTTP_PORT, CORE_HTTP_PORT);
    console.info(`${TAG} onCreate config=${this.configPath} asset=${this.assetPath} `
      + `socksPort=${this.socksPort} httpPort=${this.httpPort}`);

    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`${TAG} createVpnConnection failed: ${err.code} ${err.message}`);
      return;
    }

    // onCreate 是 SDK 契约里唯一**保证**会被调用的入口，网卡必须在这里创建。
    // 若等 onConnect（非契约、运行时可能根本不回调）才创建，结果就是
    // "扩展起来了、却没有任何网卡"，VPN 完全不生效。
    this.ensureVpnCreated();
  }

  /**
   * ⚠️ 非 SDK 契约：本机 SDK 的 @ohos.app.ability.VpnExtensionAbility.d.ts
   * 只声明了 onCreate / onDestroy，**没有** onConnect。
   *
   * 保留它的原因：某些系统版本可能额外回调它，此时作为幂等兜底 ——
   * 与 onCreate 共享守卫，绝不会重复建网卡。
   */
  onConnect(): void {
    console.info(`${TAG} onConnect (non-contract, idempotent fallback)`);
    this.ensureVpnCreated();
  }

  /**
   * ⚠️ 非 SDK 契约（同 onConnect）。保留为"若被回调则提前释放网卡"；
   * 真正的释放由 onDestroy 负责。
   */
  onDisconnected(): void {
    console.info(`${TAG} onDisconnected (non-contract)`);
    this.stopTrafficReporting();
    this.destroyVpn();
  }

  onDestroy(): void {
    console.info(`${TAG} onDestroy`);
    this.stopTrafficReporting();
    this.destroyVpn();
    // 扩展结束后主动退出进程，避免残留（否则系统会再次拉起上一次的 VPN 扩展）
    const processManager: process.ProcessManager = new process.ProcessManager();
    processManager.exit(0);
  }

  /**
   * 幂等地创建虚拟网卡。
   *
   * 调用点有两个：onCreate（契约保证）与 onConnect（非契约、可选）。
   * 无论 SDK 是否回调 onConnect，网卡都恰好被创建一次。
   */
  private ensureVpnCreated(): void {
    if (this.vpnCreated || this.vpnCreating) {
      return;
    }
    const vpn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (vpn === undefined) {
      console.error(`${TAG} ensureVpnCreated without VpnConnection, abort`);
      return;
    }
    this.vpnCreating = true;

    const config: vpnExtension.VpnConfig = buildVpnConfig();
    vpn.create(config).then((vfd: number) => {
      this.vpnCreating = false;
      this.vpnCreated = true;
      console.info(`${TAG} vpn created, vfd=${vfd}`);
      // 网卡就绪 -> 立刻把 fd 交给 tun2socks（数据面）。
      // 这一步失败**不影响**网卡与上报：扩展仍然"能授权、能建网卡"，只是流量
      // 过不去。失败原因会写进 hilog —— 这正是 AGENT.md §9 第 2 步
      // （先单独验证空壳 VPN）想要的行为。
      this.startDataPlane(vfd);
      this.startTrafficReporting();
    }).catch((error: BusinessError) => {
      this.vpnCreating = false;
      // 2203002 = VPN 已存在：上一次没 destroy 干净，需要用户先断开再重试。
      console.error(`${TAG} vpn.create failed: ${error.code} ${error.message}`);
    });
  }

  /** 幂等地销毁虚拟网卡（onDisconnected 与 onDestroy 都会调用）。 */
  private destroyVpn(): void {
    const vpn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (vpn === undefined) {
      return;
    }
    this.vpnCreated = false;
    this.vpnCreating = false;
    // 先停数据面再销毁网卡：反过来会让 tun2socks 在已经关闭的 fd 上读，
    // 日志里会出现一串 "read: bad file descriptor" 之类的噪声。
    this.stopDataPlane();
    vpn.destroy().then(() => {
      console.info(`${TAG} vpn destroyed`);
    }).catch((error: BusinessError) => {
      console.error(`${TAG} vpn.destroy failed: ${error.code} ${error.message}`);
    });
  }

  // -------------------------------------------------------------------------
  // 数据面：TUN fd -> tun2socks（libhevsocks5tun.so）-> 127.0.0.1:SOCKS
  // -------------------------------------------------------------------------

  /**
   * 把 vNIC fd 交给 tun2socks。
   *
   * 失败时只记日志、不抛异常：网卡已经建好，扩展该做的是"如实报告"，
   * 而不是把整个 VPN 拆掉。
   */
  private startDataPlane(tunFd: number): void {
    // 端口用**收进来的那一个**（UI 进程转交的 Generate 结果），不是本地常量。
    const yaml: string = buildTun2socksYaml(this.socksPort);
    console.info(`${TAG} starting tun2socks on fd=${tunFd} socksPort=${this.socksPort}`);
    DataPlane.start(yaml, tunFd).then((result: DataPlaneStartResult) => {
      if (result.started) {
        console.info(`${TAG} tun2socks running (lib=${result.libPath})`);
      } else {
        console.error(`${TAG} tun2socks not started: ${result.error}`);
      }
    }).catch((error: BusinessError) => {
      console.error(`${TAG} tun2socks start rejected: ${error.code} ${error.message}`);
    });
  }

  /** 停止数据面（幂等）。onDisconnected / onDestroy 都会调用。 */
  private stopDataPlane(): void {
    DataPlane.stop().then((stopped: boolean) => {
      if (stopped) {
        console.info(`${TAG} tun2socks stopped`);
      }
    }).catch((error: BusinessError) => {
      console.error(`${TAG} tun2socks stop rejected: ${error.code} ${error.message}`);
    });
  }

  // -------------------------------------------------------------------------
  // 流量上报：定时读取 vpn-tun 网卡的收发字节，换算成速率后发布公共事件
  // -------------------------------------------------------------------------

  private startTrafficReporting(): void {
    if (this.timerId >= 0) {
      return;
    }
    this.timerId = setInterval(() => {
      this.reportTrafficOnce();
    }, TRAFFIC_INTERVAL_MS);
  }

  private stopTrafficReporting(): void {
    if (this.timerId < 0) {
      return;
    }
    clearInterval(this.timerId);
    this.timerId = -1;
  }

  private reportTrafficOnce(): void {
    // statistics.getIfaceTxBytes/getIfaceRxBytes 返回的是该网卡自启动以来的累计字节数
    statistics.getIfaceTxBytes(VPN_IFACE_NAME).then((tx: number) => {
      statistics.getIfaceRxBytes(VPN_IFACE_NAME).then((rx: number) => {
        const speedUp: number = computeSpeed(tx, this.lastTx);
        const speedDown: number = computeSpeed(rx, this.lastRx);
        this.lastTx = tx;
        this.lastRx = rx;
        publishTraffic(tx, rx, speedUp, speedDown);
      }).catch((error: BusinessError) => {
        console.warn(`${TAG} getIfaceRxBytes failed: ${error.code}`);
      });
    }).catch((error: BusinessError) => {
      console.warn(`${TAG} getIfaceTxBytes failed: ${error.code}`);
    });
  }
}

/**
 * 读取 want.parameters 里的字符串。
 * want.parameters 的类型是 { [key: string]: Object }，这里做一次显式判空与类型收窄。
 */
function readWantString(want: Want, key: string): string {
  const parameters: Record<string, Object> | undefined = want.parameters;
  if (parameters === undefined) {
    return '';
  }
  const value: Object | undefined = parameters[key];
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value as string;
  }
  return '';
}

/**
 * 读取 want.parameters 里的端口号。
 *
 * 接受 number 与"数字字符串"两种形态：want 跨进程传递时类型理论上会被保留，
 * 但这里宁可多接一种形态 —— 若只认 number，一旦运行时把它变成字符串，
 * 扩展就会**静默**回落到常量，而那正是这条链路要消灭的"两侧各猜一个端口"。
 * 非法值（缺失 / 非数字 / <=0）一律回落 `fallback`。
 */
function readWantPort(want: Want, key: string, fallback: number): number {
  const parameters: Record<string, Object> | undefined = want.parameters;
  if (parameters === undefined) {
    return fallback;
  }
  const value: Object | undefined = parameters[key];
  if (typeof value === 'number') {
    const port: number = value as number;
    return port > 0 ? port : fallback;
  }
  if (typeof value === 'string') {
    const parsed: number = Number.parseInt(value as string, 10);
    return Number.isNaN(parsed) || parsed <= 0 ? fallback : parsed;
  }
  return fallback;
}

/**
 * 构造 VpnConfig。
 * 路由策略：默认路由（0.0.0.0/0）交给 VPN，DNS 指向 TUN 内网地址。
 *
 * 防环（关键，见冻结契约 docs/design/ipc-contract.md §2 与 AGENT.md §2.4）：
 * 把**本应用自己的包名**放进 `blockedApplications`，使本应用自己的出站流量
 * 不回到 TUN，从而**不需要** `protect()`（Go 侧没有 hook 能把自建 socket 交给
 * ArkTS 调 protect，所以那条路走不通）。
 *
 * SDK 取证（本机 `D:\Harmony\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.net.vpnExtension.d.ts`，
 * `VpnConfig` 定义见 :283）：`blockedApplications?: Array<string>`（:388），
 * 语义为"**只有不在列表里的应用**才会按 routes 被 VPN 代理"（:378-381），
 * 即列表 = 被排除、直连的应用；取值是 **bundleName 字符串数组**（不是 ApplicationInfo[]）。
 * 同一份注释两处（:371 / :383）都声明它与 `trustedApplications` **互斥**，
 * 因此这里**只设 blockedApplications**，绝不两个都设。
 *
 * ⚠️ 未验证：真机上"自身包名在 blockedApplications 里是否确实止住环路"未经实测
 * （没有真机，AGENT.md §1 / §7 B3）。
 */
function buildVpnConfig(): vpnExtension.VpnConfig {
  const address: connection.NetAddress = { address: VPN_TUN_ADDRESS, family: 1 };
  const linkAddress: connection.LinkAddress = { address: address, prefixLength: VPN_TUN_PREFIX_LENGTH };

  const defaultDestinationAddress: connection.NetAddress = { address: '0.0.0.0', family: 1 };
  const defaultDestination: connection.LinkAddress = { address: defaultDestinationAddress, prefixLength: 0 };
  const gateway: connection.NetAddress = { address: '0.0.0.0', family: 1 };
  const defaultRoute: connection.RouteInfo = {
    interface: VPN_IFACE_NAME,
    destination: defaultDestination,
    gateway: gateway,
    hasGateway: false,
    isDefaultRoute: true
  };

  const config: vpnExtension.VpnConfig = {
    addresses: [linkAddress],
    routes: [defaultRoute],
    dnsAddresses: [VPN_TUN_DNS],
    mtu: DEFAULT_MTU,
    isIPv4Accepted: true,
    isIPv6Accepted: false,
    isBlocking: false,
    isInternal: false,
    // 防环：只排除**本应用自己**，其余应用照常走 VPN。
    // 注意语义方向 —— blocked = "不被代理"，所以自身的出站流量因此不回到 TUN，
    // tun2socks 才能把还原出的连接交给本地 SOCKS 而不形成回路。
    // 一旦这里漏掉，真机症状是"连上即断网"。
    blockedApplications: [APP_BUNDLE_NAME]
    // ⚠️ 不要同时设置 trustedApplications：SDK 明确两者互斥（d.ts:371 / :383）。
  };
  return config;
}

/**
 * 生成 hev-socks5-tunnel 的 YAML 配置。
 *
 * 只写必要的三段：
 *   tunnel.mtu  与 VpnConfig.mtu 共用同一个常量（同一块网卡，两个数字必须对上）
 *   socks5      tun2socks 把还原出的连接交给内核的本地入站
 *   misc        warn 级日志，避免隧道内部的调试噪声灌满 hilog
 *
 * @param socksPort 内核本地 SOCKS 入站端口。**必须由调用方传入**（来自
 *        want.parameters，即 UI 进程转交的 ConfigService.Generate 结果），
 *        不能在这个文件里写死：写死就会与内核真正监听的那个端口各说各话。
 *
 * ⚠️ tunnel 段里**不写** name / ipv4：网卡由 VpnConfig 创建，fd 由系统经
 * `hev_socks5_tunnel_main_from_str(cfg, len, tun_fd)` 交给我们，这里再声明接口名
 * 与地址只会制造两份互相冲突的配置。hev 是否接受省略这两个字段**未在真机验证**，
 * 属于 U3 的一部分。
 */
function buildTun2socksYaml(socksPort: number): string {
  const port: number = socksPort > 0 ? socksPort : CORE_SOCKS_PORT;
  return 'tunnel:\n' +
    '  mtu: ' + DEFAULT_MTU.toString() + '\n' +
    'socks5:\n' +
    '  address: 127.0.0.1\n' +
    '  port: ' + port.toString() + '\n' +
    '  udp: udp\n' +
    'misc:\n' +
    '  log-level: warn\n';
}

/** 用两次采样差值估算瞬时速率（字节/秒） */
function computeSpeed(current: number, previous: number): number {
  const delta: number = current - previous;
  if (delta <= 0) {
    return 0;
  }
  return Math.floor(delta * 1000 / TRAFFIC_INTERVAL_MS);
}

/**
 * 发布 VPN_TRAFFIC 公共事件。
 * 契约（app 侧 core/TrafficMonitor.ets 按同一组 key 解析）：
 *   parameters = { TOTAL_UP, TOTAL_DOWN, SPEED_UP, SPEED_DOWN }（字节 / 字节每秒）
 */
function publishTraffic(totalUp: number, totalDown: number, speedUp: number, speedDown: number): void {
  const parameters: Record<string, number> = {
    'TOTAL_UP': totalUp,
    'TOTAL_DOWN': totalDown,
    'SPEED_UP': speedUp,
    'SPEED_DOWN': speedDown
  };
  const options: commonEventManager.CommonEventPublishData = { parameters: parameters };
  commonEventManager.publish(VPN_TRAFFIC_EVENT, options, (error: BusinessError) => {
    if (error !== undefined && error !== null && error.code !== 0) {
      console.warn(`${TAG} publish traffic failed: ${error.code}`);
    }
  });
}
