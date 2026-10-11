/**
 * Clipboard.ets
 * 剪贴板读写封装（@kit.BasicServicesKit 的 pasteboard）。
 * 用于「从剪贴板导入订阅 / 分享链接」以及「复制日志」。
 *
 * 注意：读取剪贴板自 API 12 起需要 ohos.permission.READ_PASTEBOARD（user_grant），
 * 已在 module.json5 的 requestPermissions 中声明；未授权时会抛 201，这里统一降级为空串，
 * 由调用方提示用户。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

const TAG: string = 'Clipboard';

/** 剪贴板工具 */
export class Clipboard {
  /** 读取纯文本；失败（无权限 / 空剪贴板）时返回空串 */
  static async readText(): Promise<string> {
    try {
      const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
      if (data === undefined || data === null) {
        return '';
      }
      return data.getPrimaryText();
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, 'readText failed: ' + err.code.toString() + ' ' + err.message);
      return '';
    }
  }

  /** 写入纯文本；返回是否成功 */
  static async writeText(text: string): Promise<boolean> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, 'writeText failed: ' + err.code.toString() + ' ' + err.message);
      return false;
    }
  }
}
