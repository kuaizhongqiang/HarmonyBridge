/**
 * Toast.ets
 * 轻提示封装：优先使用 / 页面的 UIContext.getPromptAction()（推荐用法，
 * 避免使用已废弃的全局 @ohos.promptAction 静态入口）。
 */
import { promptAction, PromptAction } from '@kit.ArkUI';
import { Logger } from './Logger';

const TAG: string = 'Toast';
/** toast 默认展示时长（毫秒） */
const DEFAULT_DURATION: number = 2000;

/** 轻提示工具 */
export class Toast {
  /**
   * 展示一条 toast。
   * @param action 调用方通过 this.getUIContext().getPromptAction() 取得（类型是 UIContext.PromptAction）
   * @param message 已完成本地化的文案（调用方用 stringOf 求值后传入）
   */
  static show(action: PromptAction, message: string): void {
    const options: promptAction.ShowToastOptions = {
      message: message,
      duration: DEFAULT_DURATION
    };
    try {
      action.showToast(options);
    } catch (error) {
      Logger.warn(TAG, 'showToast failed: ' + Logger.describe(error as Object));
    }
  }
}
