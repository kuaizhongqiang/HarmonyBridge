/**
 * Logger.ets
 * 统一日志出口：包装 @kit.PerformanceAnalysisKit 的 hilog。
 * 同时通过 Logger.onRecord 回调把日志同步给 LogViewModel（UI 的「日志」页），
 * 这样核心/桥接层不需要依赖 UI 层。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LogLevel } from '../model/Types';
import { LOG_DOMAIN, LOG_TAG } from '../constants/Common';

/** 日志记录回调签名（由 LogViewModel 注册，避免 utils -> viewmodel 的反向依赖） */
export type LogRecordHandler = (level: LogLevel, tag: string, message: string) => void;

/** 日志工具 */
export class Logger {
  private static handler: LogRecordHandler | undefined = undefined;

  /** 注册 UI 侧的日志收集器（同一时刻只保留一个） */
  static onRecord(handler: LogRecordHandler): void {
    Logger.handler = handler;
  }

  static debug(tag: string, message: string): void {
    Logger.emit(LogLevel.DEBUG, tag, message);
  }

  static info(tag: string, message: string): void {
    Logger.emit(LogLevel.INFO, tag, message);
  }

  static warn(tag: string, message: string): void {
    Logger.emit(LogLevel.WARN, tag, message);
  }

  static error(tag: string, message: string): void {
    Logger.emit(LogLevel.ERROR, tag, message);
  }

  /** 把 Error / BusinessError 统一格式化成一行文本 */
  static describe(error: Object): string {
    if (error instanceof Error) {
      return error.name + ': ' + error.message;
    }
    return JSON.stringify(error);
  }

  private static emit(level: LogLevel, tag: string, message: string): void {
    if (level === LogLevel.DEBUG) {
      hilog.debug(LOG_DOMAIN, LOG_TAG, '%{public}s %{public}s', tag, message);
    } else if (level === LogLevel.INFO) {
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s %{public}s', tag, message);
    } else if (level === LogLevel.WARN) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s %{public}s', tag, message);
    } else {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s %{public}s', tag, message);
    }
    const handler: LogRecordHandler | undefined = Logger.handler;
    if (handler !== undefined) {
      handler(level, tag, message);
    }
  }
}
