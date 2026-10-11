/**
 * TrafficMonitor.ets
 * 订阅 VPN 扩展进程发布的 VPN_TRAFFIC 公共事件，把字节数换算成 UI 需要的 TrafficStats。
 *
 * 事件契约（与 VpnAbility.ets 中的发布端一致）：
 *   event      : 'VPN_TRAFFIC'
 *   parameters : { TOTAL_UP, TOTAL_DOWN, SPEED_UP, SPEED_DOWN }  // 字节 / 字节每秒
 *
 * 使用 emitter + commonEventManager 双通道：
 *   - 同进程（Mock / 扩展与 UI 同进程调试）：emitter 立即回调；
 *   - 跨进程（真实 VPN 扩展）：commonEventManager 投递。
 * 两条通道的解码逻辑完全一致，重复回调只会刷新同一份统计，不会叠加计数。
 */
import { commonEventManager, emitter } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { emptyTrafficStats, TrafficStats } from '../model/Types';
import { VPN_TRAFFIC_EVENT } from '../constants/Common';
import { Logger } from '../utils/Logger';
import { jsonNum } from '../service/JsonHelpers';

const TAG: string = 'TrafficMonitor';

/** 统计回调签名 */
export type TrafficListener = (stats: TrafficStats) => void;

/** 流量统计监听器 */
export class TrafficMonitor {
  private static listener: TrafficListener | undefined = undefined;
  private static subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private static emitterSubscribed: boolean = false;
  private static lastStats: TrafficStats = emptyTrafficStats();

  /** 最近一次统计（供页面首次渲染时补齐数据） */
  static latest(): TrafficStats {
    return TrafficMonitor.lastStats;
  }

  /** 注册 UI 侧回调并开始监听事件 */
  static start(listener: TrafficListener): void {
    TrafficMonitor.listener = listener;
    TrafficMonitor.subscribeCommonEvent();
    TrafficMonitor.subscribeEmitter();
  }

  /** 停止监听（页面退出 / 断开连接时调用） */
  static stop(): void {
    TrafficMonitor.listener = undefined;
    TrafficMonitor.unsubscribeCommonEvent();
    TrafficMonitor.unsubscribeEmitter();
  }

  /** 发布一条统计（供 Mock 与测试使用；扩展进程内由 VpnAbility 自行发布） */
  static publish(stats: TrafficStats): void {
    TrafficMonitor.emitStats(stats);
  }

  // -------------------------------------------------------------------------
  // 内部实现
  // -------------------------------------------------------------------------

  private static subscribeCommonEvent(): void {
    if (TrafficMonitor.subscriber !== undefined) {
      return;
    }
    const info: commonEventManager.CommonEventSubscribeInfo = { events: [VPN_TRAFFIC_EVENT] };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      TrafficMonitor.subscriber = subscriber;
      commonEventManager.subscribe(subscriber, (error: BusinessError, data: commonEventManager.CommonEventData) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          Logger.warn(TAG, 'common event error: ' + error.code.toString());
          return;
        }
        TrafficMonitor.decodeAndEmit(data.parameters);
      });
      Logger.info(TAG, 'subscribed common event ' + VPN_TRAFFIC_EVENT);
    }).catch((error: BusinessError) => {
      Logger.error(TAG, 'createSubscriber failed: ' + error.code.toString() + ' ' + error.message);
    });
  }

  private static unsubscribeCommonEvent(): void {
    const subscriber: commonEventManager.CommonEventSubscriber | undefined = TrafficMonitor.subscriber;
    if (subscriber === undefined) {
      return;
    }
    commonEventManager.unsubscribe(subscriber);
    TrafficMonitor.subscriber = undefined;
  }

  private static subscribeEmitter(): void {
    if (TrafficMonitor.emitterSubscribed) {
      return;
    }
    emitter.on(VPN_TRAFFIC_EVENT, (data: emitter.EventData) => {
      if (data.data === undefined) {
        return;
      }
      TrafficMonitor.decodeAndEmit(data.data);
    });
    TrafficMonitor.emitterSubscribed = true;
  }

  private static unsubscribeEmitter(): void {
    if (!TrafficMonitor.emitterSubscribed) {
      return;
    }
    emitter.off(VPN_TRAFFIC_EVENT);
    TrafficMonitor.emitterSubscribed = false;
  }

  /** 把事件 parameters 解码成 TrafficStats 并回调 */
  private static decodeAndEmit(parameters: Object | undefined): void {
    if (parameters === undefined) {
      return;
    }
    const stats: TrafficStats = {
      speedUp: jsonNum(parameters, 'SPEED_UP', 0),
      speedDown: jsonNum(parameters, 'SPEED_DOWN', 0),
      totalUp: jsonNum(parameters, 'TOTAL_UP', 0),
      totalDown: jsonNum(parameters, 'TOTAL_DOWN', 0),
      updatedAt: Date.now()
    };
    TrafficMonitor.emitStats(stats);
  }

  private static emitStats(stats: TrafficStats): void {
    TrafficMonitor.lastStats = stats;
    const listener: TrafficListener | undefined = TrafficMonitor.listener;
    if (listener !== undefined) {
      listener(stats);
    }
  }
}
