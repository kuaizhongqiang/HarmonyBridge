/**
 * CoreStateMonitor.ets
 * 订阅 VPN 扩展进程发布的 `VPN_CORE_STATE` 公共事件，把内核的**真实**状态交给 UI。
 *
 * 为什么需要它（2026-10-12 真机实测的结论）：
 *   `libcore.so` 是**按进程各加载一份**的 —— 每个进程有自己的 Go 运行时与自己的
 *   服务注册表。内核跑在**扩展进程**里（见 `VpnAbility#startCoreInProcess`），
 *   所以在 UI 进程里调 `CoreService.Status` / `LogService.Tail` 读到的只是 UI 进程
 *   那份**从未启动过**的空实例，会得出"内核没在跑"的错误结论。
 *
 *   实测证据：内核被 UI 进程启动、UI 进程退到后台后被系统冻结（CPU ticks 10 秒内
 *   delta = 0），Xray 的 accept 循环随之停摆，而扩展进程里的 tun2socks 仍在把流量
 *   交给 `127.0.0.1:10808` —— 于是 `SYN_SENT` 堆积、accept 队列堵死、上行计数照涨
 *   而**下行归零**。把内核搬进扩展进程之后，UI 进程的启停不再影响数据面。
 *
 * 与 `TrafficMonitor` 同构：emitter 负责同进程，commonEventManager 负责跨进程，
 * 两条通道解码逻辑一致，重复回调只刷新同一份状态。
 */
import { commonEventManager, emitter } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CORE_STATE_ERROR,
  CORE_STATE_HTTP_PORT,
  CORE_STATE_SOCKS_PORT,
  CORE_STATE_STARTED,
  CORE_STATE_VERSION,
  CORE_STATE_WIRED,
  VPN_CORE_STATE_EVENT
} from '../constants/Common';
import { Logger } from '../utils/Logger';
import { jsonBool, jsonNum, jsonStr } from '../service/JsonHelpers';

const TAG: string = 'CoreStateMonitor';

/** 内核状态（跨进程上报的真实值） */
export interface CoreState {
  /** 内核实例是否已启动 */
  started: boolean;
  /** 本地 SOCKS 入站已监听 **且** tun2socks 已运行 */
  wired: boolean;
  /** 内核版本；拿不到时空串 */
  version: string;
  socksPort: number;
  httpPort: number;
  /** 失败原因；成功时空串 */
  error: string;
}

/** 空状态（尚未收到任何上报时的初值） */
export function emptyCoreState(): CoreState {
  return {
    started: false,
    wired: false,
    version: '',
    socksPort: 0,
    httpPort: 0,
    error: ''
  };
}

type CoreStateResolver = (state: CoreState | undefined) => void;

/** 内核状态监听器 */
export class CoreStateMonitor {
  private static subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private static emitterSubscribed: boolean = false;
  private static pending: CoreStateResolver | undefined = undefined;
  /**
   * 在 `wait()` 之前就到来的那一条状态。
   *
   * 有必要存在：扩展进程报得很快（`vpn.create()` 之后立刻上报），而 UI 侧要先
   * `await startVpnExtensionAbility` 再 `await wait(...)`。没有这个队列，
   * 首个状态会被丢掉，UI 只能等到超时 —— 变成"功能是对的、却总是报超时"。
   */
  private static queued: CoreState | undefined = undefined;

  /** 开始监听（幂等）。应在发起连接**之前**调用。 */
  static start(): void {
    CoreStateMonitor.subscribeCommonEvent();
    CoreStateMonitor.subscribeEmitter();
  }

  /**
   * 等待扩展进程上报的下一条内核状态。
   * @param timeoutMs 超时；超时返回 undefined（调用方负责如实报错，不要假装成功）
   */
  static wait(timeoutMs: number): Promise<CoreState | undefined> {
    CoreStateMonitor.start();
    return new Promise<CoreState | undefined>((resolve: CoreStateResolver) => {
      const cached: CoreState | undefined = CoreStateMonitor.queued;
      if (cached !== undefined) {
        CoreStateMonitor.queued = undefined;
        resolve(cached);
        return;
      }
      let settled: boolean = false;
      CoreStateMonitor.pending = (state: CoreState | undefined) => {
        settled = true;
        resolve(state);
      };
      setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        CoreStateMonitor.pending = undefined;
        Logger.warn(TAG, 'no core state within ' + timeoutMs.toString() + 'ms');
        resolve(undefined);
      }, timeoutMs);
    });
  }

  /** 停止监听（页面退出 / 断开连接时调用） */
  static stop(): void {
    CoreStateMonitor.pending = undefined;
    CoreStateMonitor.queued = undefined;
    const subscriber: commonEventManager.CommonEventSubscriber | undefined = CoreStateMonitor.subscriber;
    if (subscriber !== undefined) {
      commonEventManager.unsubscribe(subscriber);
      CoreStateMonitor.subscriber = undefined;
    }
    if (CoreStateMonitor.emitterSubscribed) {
      emitter.off(VPN_CORE_STATE_EVENT);
      CoreStateMonitor.emitterSubscribed = false;
    }
  }

  // -------------------------------------------------------------------------
  // 内部实现
  // -------------------------------------------------------------------------

  private static subscribeCommonEvent(): void {
    if (CoreStateMonitor.subscriber !== undefined) {
      return;
    }
    const info: commonEventManager.CommonEventSubscribeInfo = { events: [VPN_CORE_STATE_EVENT] };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      CoreStateMonitor.subscriber = subscriber;
      commonEventManager.subscribe(subscriber, (error: BusinessError, data: commonEventManager.CommonEventData) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          Logger.warn(TAG, 'common event error: ' + error.code.toString());
          return;
        }
        CoreStateMonitor.deliver(CoreStateMonitor.decode(data.parameters));
      });
      Logger.info(TAG, 'subscribed common event ' + VPN_CORE_STATE_EVENT);
    }).catch((error: BusinessError) => {
      Logger.error(TAG, 'createSubscriber failed: ' + error.code.toString() + ' ' + error.message);
    });
  }

  private static subscribeEmitter(): void {
    if (CoreStateMonitor.emitterSubscribed) {
      return;
    }
    emitter.on(VPN_CORE_STATE_EVENT, (data: emitter.EventData) => {
      if (data.data === undefined) {
        return;
      }
      CoreStateMonitor.deliver(CoreStateMonitor.decode(data.data));
    });
    CoreStateMonitor.emitterSubscribed = true;
  }

  /** 把事件 parameters 解码成 CoreState（字段缺失时取安全默认值） */
  private static decode(parameters: Object | undefined): CoreState {
    if (parameters === undefined) {
      return emptyCoreState();
    }
    const state: CoreState = {
      started: jsonBool(parameters, CORE_STATE_STARTED, false),
      wired: jsonBool(parameters, CORE_STATE_WIRED, false),
      version: jsonStr(parameters, CORE_STATE_VERSION),
      socksPort: jsonNum(parameters, CORE_STATE_SOCKS_PORT, 0),
      httpPort: jsonNum(parameters, CORE_STATE_HTTP_PORT, 0),
      error: jsonStr(parameters, CORE_STATE_ERROR)
    };
    return state;
  }

  private static deliver(state: CoreState): void {
    Logger.info(TAG, 'core state: started=' + state.started.toString()
      + ' wired=' + state.wired.toString()
      + ' version=' + state.version
      + (state.error.length > 0 ? ' error=' + state.error : ''));
    const resolver: CoreStateResolver | undefined = CoreStateMonitor.pending;
    if (resolver === undefined) {
      CoreStateMonitor.queued = state;
      return;
    }
    CoreStateMonitor.pending = undefined;
    resolver(state);
  }
}
