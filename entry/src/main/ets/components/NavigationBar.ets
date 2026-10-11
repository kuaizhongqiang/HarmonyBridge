/**
 * NavigationBar.ets
 * 底部导航栏：首页 / 节点 / 订阅 / 设置。四个主页面共用，保证页面切换体验一致。
 * 当前页高亮由传入的 current 参数决定。
 */
import { Dimens, FontSizes } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { Routes } from '../constants/Routes';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN, LOG_TAG } from '../constants/Common';

/** 导航项定义 */
interface NavItem {
  key: string;
  label: Resource;
  route: string;
}

/** 底部导航栏 */
@ComponentV2
export struct NavigationBar {
  /** 当前页路由（Routes 之一） */
  @Param current: string = Routes.INDEX;
  /** 是否隐藏 */
  @Param hidden: boolean = false;

  private items(): NavItem[] {
    const list: NavItem[] = [
      { key: 'home', label: $r('app.string.nav_home'), route: Routes.INDEX },
      { key: 'nodes', label: $r('app.string.nav_nodes'), route: Routes.NODES },
      { key: 'subs', label: $r('app.string.nav_subscriptions'), route: Routes.SUBSCRIPTIONS },
      { key: 'settings', label: $r('app.string.nav_settings'), route: Routes.SETTINGS }
    ];
    return list;
  }

  private go(route: string): void {
    if (route === this.current) {
      return;
    }
    const routerInstance = this.getUIContext().getRouter();
    if (route === Routes.INDEX && this.current !== Routes.INDEX) {
      // 从二级页回首页：清栈，保证首页只有一个实例（符合底部 Tab 直觉）
      routerInstance.clear();
      return;
    }
    routerInstance.pushUrl({ url: route }).catch((error: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'nav push %{public}s failed: %{public}s', route, error.message);
    });
  }

  build() {
    Row() {
      ForEach(this.items(), (item: NavItem) => {
        Column({ space: 2 }) {
          Text(item.label)
            .fontSize(FontSizes.caption)
            .fontColor(item.route === this.current ? Theme.brand : Theme.textSecondary)
            .fontWeight(item.route === this.current ? FontWeight.Medium : FontWeight.Normal)
        }
        .layoutWeight(1)
        .height(Dimens.navBar)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.go(item.route);
        })
      }, (item: NavItem) => item.key)
    }
    .width('100%')
    .height(Dimens.navBar)
    .backgroundColor(Theme.surface)
    .border({ width: { top: 1 }, color: Theme.divider })
    .visibility(this.hidden ? Visibility.None : Visibility.Visible)
  }
}
