/**
 * VpnAbility.ets
 * HarmonyOS 第三方 VPN 扩展（VpnExtensionAbility）骨架。
 *
 * 它在 module.json5 里声明为：{ name: "VpnAbility", srcEntry: "./ets/vpnability/VpnAbility.ets", type: "vpn" }，
 * 只需要 ohos.permission.INTERNET，不需要（也拿不到）ohos.permission.MANAGE_VPN。
 *
 * 生命周期（本文件已按真实顺序搭好结构）：
 *   onCreate(want)   -> vpnExtension.createVpnConnection(this.context) 建立 VpnConnection 对象，
 *                       并从 want.parameters 取出内核配置路径 / 资源目录
 *   onConnect()      -> connection.create(config) 拿到虚拟网卡 fd；把这个 fd 交给内核（TODO）；
 *                       启动 VPN_TRAFFIC 上报定时器
 *   onDisconnected() -> connection.destroy() 释放网卡，停止上报
 *   onDestroy()      -> 清理定时器 + process.ProcessManager().exit(0) 退出扩展进程
 *
 * 说明：本文件不引入 libbridge.so（它由另一工作流实现且当前不存在），
 * 内核拉起位置留了一个带完整契约说明的 TODO。
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
  VPN_IFACE_NAME,
  VPN_TRAFFIC_EVENT,
  VPN_TUN_ADDRESS,
  VPN_TUN_DNS,
  VPN_TUN_PREFIX_LENGTH,
  WANT_KEY_ASSET_PATH,
  WANT_KEY_CONFIG_PATH
} from '../constants/Common';

/** 日志域 / 标签（扩展进程独立打日志，便于 hdc 过滤） */
const DOMAIN: number = 0x0000;
const TAG: string = 'VpnAbility';

/** 流量上报间隔（毫秒） */
const TRAFFIC_INTERVAL_MS: number = 1000;
/** 默认 MTU（与设置页默认值保持一致，可被配置覆盖） */
const DEFAULT_MTU: number = 1500;

export default class VpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined = undefined;
  /** 内核写入的配置路径（来自 want.parameters[CONFIG_PATH]） */
  private configPath: string = '';
  /** 资源目录（geoip / geosite 等，来自 want.parameters[ASSET_PATH]） */
  private assetPath: string = '';
  /** 定时器 id */
  private timerId: number = -1;
  /** 上一次采样的收发字节数，用于计算瞬时速率 */
  private lastTx: number = 0;
  private lastRx: number = 0;

  onCreate(want: Want): void {
    console.info(`${TAG} onCreate`);
    this.configPath = readWantString(want, WANT_KEY_CONFIG_PATH);
    this.assetPath = readWantString(want, WANT_KEY_ASSET_PATH);

    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`${TAG} createVpnConnection failed: ${err.code} ${err.message}`);
    }
  }

  onConnect(): void {
    console.info(`${TAG} onConnect`);
    const vpn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (vpn === undefined) {
      console.error(`${TAG} onConnect without VpnConnection, abort`);
      return;
    }

    const config: vpnExtension.VpnConfig = buildVpnConfig();
    vpn.create(config).then((vfd: number) => {
      console.info(`${TAG} vpn created, vfd=${vfd}`);
      // TODO(native): 把 vfd 交给内核进程（Xray/sing-box 的 tun 入站）：
      //   1. 通过配置文件把 tun.fd 传给内核（config.json 的 inbounds[].fd 字段）；
      //   2. 或者由扩展进程 fork 出内核并传入已继承的 fd；
      //   3. 内核启动后本文件只负责保活与流量上报。
      // 在 libbridge.so 就绪前，这里只完成网卡与上报，不拉起内核。
      this.startTrafficReporting();
    }).catch((error: BusinessError) => {
      console.error(`${TAG} vpn.create failed: ${error.code} ${error.message}`);
    });
  }

  onDisconnected(): void {
    console.info(`${TAG} onDisconnected`);
    this.stopTrafficReporting();
    const vpn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (vpn === undefined) {
      return;
    }
    vpn.destroy().then(() => {
      console.info(`${TAG} vpn destroyed`);
    }).catch((error: BusinessError) => {
      console.error(`${TAG} vpn.destroy failed: ${error.code} ${error.message}`);
    });
  }

  onDestroy(): void {
    console.info(`${TAG} onDestroy`);
    this.stopTrafficReporting();
    const vpn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (vpn !== undefined) {
      vpn.destroy().catch((error: BusinessError) => {
        console.error(`${TAG} destroy on onDestroy failed: ${error.code} ${error.message}`);
      });
    }
    // 扩展结束后主动退出进程，避免残留（否则系统会再次拉起上一次的 VPN 扩展）
    const processManager: process.ProcessManager = new process.ProcessManager();
    processManager.exit(0);
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
 * 构造 VpnConfig。
 * 路由策略：默认路由（0.0.0.0/0）交给 VPN，DNS 指向 TUN 内网地址；
 * 分应用代理通过 trustedApplications / blockedApplications 二选一实现（两者互斥）。
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
    isInternal: false
  };
  return config;
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
