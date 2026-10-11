/**
 * LogViewModel.ets
 * 日志页状态：环形缓冲保存最近 N 条日志，支持按级别过滤、清空、导出文本。
 * 通过 Logger.onRecord 订阅 utils 层产生的日志，因此 core/viewmodel 都不依赖 UI。
 */
import { LogEntry } from '../model/LogEntry';
import { LogId, LogLevel } from '../model/Types';
import { Logger } from '../utils/Logger';
import { formatFullDateTime, formatLogTime } from '../utils/DateFormat';

/** 最多保留的日志条数（防止长时间运行吃内存） */
const MAX_ENTRIES: number = 500;

/** 日志页 ViewModel */
@ObservedV2
export class LogViewModel {
  /** 全部日志（新 -> 旧） */
  @Trace entries: LogEntry[] = [];
  /** 当前过滤级别 */
  @Trace filterLevel: LogLevel = LogLevel.INFO;
  @Trace filterEnabled: boolean = false;

  private seq: number = 0;

  constructor() {
    Logger.onRecord((level: LogLevel, tag: string, message: string) => {
      this.append(level, tag, message);
    });
  }

  /** 追加一条日志 */
  append(level: LogLevel, tag: string, message: string): void {
    this.seq = this.seq + 1;
    const id: LogId = 'log-' + this.seq.toString();
    const entry: LogEntry = {
      id: id,
      timestamp: Date.now(),
      level: level,
      tag: tag,
      message: message
    };
    this.entries.unshift(entry);
    if (this.entries.length > MAX_ENTRIES) {
      this.entries.splice(MAX_ENTRIES, this.entries.length - MAX_ENTRIES);
    }
  }

  /** 清空日志 */
  clear(): void {
    this.entries = [];
  }

  /** 当前过滤条件下的日志 */
  visibleEntries(): LogEntry[] {
    if (!this.filterEnabled) {
      return this.entries;
    }
    const level: LogLevel = this.filterLevel;
    const result: LogEntry[] = this.entries.filter((entry: LogEntry) => {
      return entry.level === level;
    });
    return result;
  }

  /** 日志行文本（UI 展示用，级 + 时间 + tag + 正文） */
  static lineText(entry: LogEntry): string {
    return formatLogTime(entry.timestamp) + ' [' + entry.level.toString().toUpperCase() + '] ' + entry.tag + ': ' +
      entry.message;
  }

  /** 导出为可复制文本 */
  exportText(): string {
    const lines: string[] = this.visibleEntries().map((entry: LogEntry) => {
      return formatFullDateTime(entry.timestamp) + ' [' + entry.level.toString().toUpperCase() + '] ' + entry.tag +
        ': ' + entry.message;
    });
    return lines.join('\n');
  }

  /** 可见日志条数 */
  visibleCount(): number {
    return this.visibleEntries().length;
  }
}

/** 全局单例：跨页面共享，保证导航过程中日志不丢 */
export const logViewModel: LogViewModel = new LogViewModel();
