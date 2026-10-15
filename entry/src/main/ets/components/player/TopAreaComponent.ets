/**
 * 播放页顶栏（移植自 audio-interaction-master 的 TopAreaComponent）。
 *
 * 右侧投播按钮（AVCastPicker）：颜色随沉浸背景明暗切换 —— 暗背景白图标、
 * 亮背景黑图标（STORE_PLAYER_BG_DARK 由 PlayerInfoComponent 取色后写入）。
 */

import { AVCastPicker } from '@kit.AVSessionKit';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { STORE_PLAYER_BG_DARK } from '../../common/Constants';
import {
  ENTRANCE_DURATION_MS,
  LAYER_DELAY_TOP
} from '../../common/constants/InteractionConstants';

@Component
export struct TopAreaComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp(STORE_PLAYER_BG_DARK) isDark: boolean = true;

  /**
   * 分层入场（方案 B）：顶栏与页面同批出现，**只淡入不位移** ——
   * 顶栏上下位移会像「从上面掉下来」，与「从下往上长出来」的整页方向相冲。
   * 必须是 `@State`：普通成员只在创建时初始化一次，父组件重渲染不会重新赋值。
   */
  @State enterOpacity: number = 0;

  aboutToAppear(): void {
    this.getUIContext().animateTo(
      { duration: ENTRANCE_DURATION_MS, curve: Curve.EaseOut, delay: LAYER_DELAY_TOP },
      (): void => {
        this.enterOpacity = 1;
      }
    );
  }

  build() {
    Row() {
      AVCastPicker({
        normalColor: this.isDark ? Color.White : Color.Black,
        activeColor: this.isDark ? Color.White : Color.Black
      })
        .width(new BreakpointType<Resource>({
          sm: $r('app.float.common_image'),
          md: $r('app.float.common_image'),
          lg: $r('app.float.control_image_lg')
        }).getValue(this.currentBreakpoint))
        .height(new BreakpointType<Resource>({
          sm: $r('app.float.common_image'),
          md: $r('app.float.common_image'),
          lg: $r('app.float.control_image_lg')
        }).getValue(this.currentBreakpoint))
    }
    .height($r('app.float.info_margin_top_sm'))
    .width(StyleConstants.FULL_WIDTH)
    .justifyContent(FlexAlign.End)
    // 分层入场只挂 opacity（不动 layout 属性，避免整树重排）
    .opacity(this.enterOpacity)
  }
}
