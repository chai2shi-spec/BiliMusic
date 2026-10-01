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

@Component
export struct TopAreaComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp(STORE_PLAYER_BG_DARK) isDark: boolean = true;

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
  }
}
