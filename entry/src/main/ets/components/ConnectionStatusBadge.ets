/**
 * ConnectionStatusBadge.ets
 * 连接状态徽标：文字 + 圆点颜色，首页标题栏与设置页都会用到。
 */
import { Dimens, FontSizes, Radii } from '../constants/Dimens';
import { Theme } from '../constants/Theme';
import { ConnectionState } from '../model/Types';

/** 连接状态徽标 */
@ComponentV2
export struct ConnectionStatusBadge {
  @Param state: ConnectionState = ConnectionState.DISCONNECTED;

  private label(): ResourceStr {
    if (this.state === ConnectionState.CONNECTED) {
      return $r('app.string.state_connected');
    }
    if (this.state === ConnectionState.CONNECTING) {
      return $r('app.string.state_connecting');
    }
    if (this.state === ConnectionState.DISCONNECTING) {
      return $r('app.string.state_disconnecting');
    }
    if (this.state === ConnectionState.ERROR) {
      return $r('app.string.state_error');
    }
    return $r('app.string.state_disconnected');
  }

  private dotColor(): Resource {
    if (this.state === ConnectionState.CONNECTED) {
      return Theme.success;
    }
    if (this.state === ConnectionState.ERROR) {
      return Theme.error;
    }
    if (this.state === ConnectionState.CONNECTING || this.state === ConnectionState.DISCONNECTING) {
      return Theme.warning;
    }
    return Theme.idle;
  }

  build() {
    Row({ space: Dimens.tight }) {
      Circle({ width: 8, height: 8 })
        .fill(this.dotColor())
      Text(this.label())
        .fontSize(FontSizes.caption)
        .fontColor(Theme.textSecondary)
    }
    .padding({ left: Dimens.item, right: Dimens.item, top: Dimens.tight, bottom: Dimens.tight })
    .backgroundColor(Theme.surfaceAlt)
    .borderRadius(Radii.chip)
    .alignItems(VerticalAlign.Center)
  }
}
