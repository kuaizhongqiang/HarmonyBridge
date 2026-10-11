/**
 * Routes.ets
 * 路由常量与页面跳转辅助。
 *
 * 说明：HarmonyOS 自 API 18 起把全局 `@ohos.router` 标记为 deprecated，推荐用
 * `UIContext.getRouter()`。本项目采用后者（页面路由）而不是 Navigation/NavPathStack，
 * 因为每个页面都需要独立入口并注册进 main_pages.json，且 router 与 EntryAbility 的
 * `windowStage.loadContent('pages/Index')` 天然兼容（见 docs/design/ui.md）。
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN, LOG_TAG } from './Common';

/** 页面路由（与 base/profile/main_pages.json 中的 src 一一对应） */
export class Routes {
  static readonly INDEX: string = 'pages/Index';
  static readonly NODES: string = 'pages/NodesPage';
  static readonly SUBSCRIPTIONS: string = 'pages/SubscriptionsPage';
  static readonly SETTINGS: string = 'pages/SettingsPage';
  static readonly LOGS: string = 'pages/LogsPage';

  /** 全部页面（供自检 / 文档核对） */
  static all(): string[] {
    return [Routes.INDEX, Routes.NODES, Routes.SUBSCRIPTIONS, Routes.SETTINGS, Routes.LOGS];
  }
}

/** 页面间传参 */
export interface RouteParams {
  /** 进入页面时要高亮的对象 id（例如订阅 id 或节点 id） */
  highlightId?: string;
}

/**
 * 跳转辅助：集中处理错误，避免每个页面重复写 try/catch。
 * 调用方：`RouterHelper.push(this.getUIContext().getRouter(), Routes.NODES)`
 */
export class RouterHelper {
  /** 打开新页面（压栈） */
  static push(routerInstance: router.Router, url: string, params?: RouteParams): void {
    const options: router.RouterOptions = { url: url };
    if (params !== undefined) {
      options.params = params;
    }
    routerInstance.pushUrl(options).catch((error: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'push %{public}s failed: %{public}s', url, error.message);
    });
  }

  /** 返回上一页 */
  static back(routerInstance: router.Router): void {
    routerInstance.back();
  }

  /** 清空栈并回到首页（用于错误兜底） */
  static replaceToIndex(routerInstance: router.Router): void {
    const options: router.RouterOptions = { url: Routes.INDEX };
    routerInstance.replaceUrl(options).catch((error: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'replace to index failed: %{public}s', error.message);
    });
  }
}
