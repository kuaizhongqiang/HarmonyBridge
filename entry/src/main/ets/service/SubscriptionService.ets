/**
 * SubscriptionService.ets
 * 订阅拉取：用 @kit.NetworkKit 的 http 模块下载订阅正文，交给 SubscriptionParser 解析。
 * 只做「拉取 + 解析」，不持有任何 UI 状态。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Timestamp } from '../model/Types';
import { parseSubscriptionBody, SubscriptionParseResult, SubscriptionFormat } from './SubscriptionParser';
import { Logger } from '../utils/Logger';

const TAG: string = 'SubscriptionService';
/** 单次订阅拉取的读超时（毫秒） */
const READ_TIMEOUT: number = 15000;
/** 连接超时（毫秒） */
const CONNECT_TIMEOUT: number = 10000;
/** 部分机场会按 UA 返回不同格式，统一用 v2rayN 的 UA */
const USER_AGENT: string = 'v2rayN/7.0 (HarmonyOS)';

/** 拉取结果 */
export interface FetchResult {
  success: boolean;
  /** HTTP 状态码；0 表示请求未发出 */
  statusCode: number;
  /** 失败原因 */
  error: string;
  body: string;
}

/** 拉取订阅正文 */
export async function fetchSubscription(url: string): Promise<FetchResult> {
  const request: http.HttpRequest = http.createHttp();
  const header: Record<string, string> = {
    'User-Agent': USER_AGENT,
    'Accept': '*/*'
  };
  const options: http.HttpRequestOptions = {
    method: http.RequestMethod.GET,
    header: header,
    readTimeout: READ_TIMEOUT,
    connectTimeout: CONNECT_TIMEOUT
  };
  try {
    const response: http.HttpResponse = await request.request(url, options);
    const status: number = response.responseCode as number;
    if (status !== 200) {
      const failed: FetchResult = {
        success: false,
        statusCode: status,
        error: 'http-' + status.toString(),
        body: ''
      };
      return failed;
    }
    let body: string = '';
    if (typeof response.result === 'string') {
      body = response.result as string;
    }
    const ok: FetchResult = { success: true, statusCode: status, error: '', body: body };
    return ok;
  } catch (error) {
    const err: BusinessError = error as BusinessError;
    Logger.error(TAG, 'fetch failed: ' + err.code.toString() + ' ' + err.message);
    const failed: FetchResult = {
      success: false,
      statusCode: 0,
      error: err.code.toString() + ' ' + err.message,
      body: ''
    };
    return failed;
  } finally {
    request.destroy();
  }
}

/** 拉取并解析（订阅更新的主入口） */
export async function fetchAndParseSubscription(
  url: string,
  now: Timestamp
): Promise<SubscriptionParseResult> {
  const fetched: FetchResult = await fetchSubscription(url);
  if (!fetched.success) {
    const failed: SubscriptionParseResult = {
      format: SubscriptionFormat.UNKNOWN,
      nodes: [],
      skipped: 0,
      error: fetched.error
    };
    return failed;
  }
  return parseSubscriptionBody(fetched.body, now);
}

/** 从剪贴板文本里解析节点（支持分享链接列表或整段 base64） */
export function parseClipboardPayload(text: string, now: Timestamp): SubscriptionParseResult {
  return parseSubscriptionBody(text, now);
}
