/**
 * 播放页顶栏（移植自 audio-interaction-master 的 TopAreaComponent）。
 *
 * 左侧收起按钮（2026-10-21 组件状态切换动画改版）：chevron_down，点击发
 * STORE_PLAYER_CLOSE_REQUEST（seq 递增）→ Index.closePlayer 逆向收起镜像
 * （容器缩回、封面回飞、页签图标恢复）。收起按钮在 overlay 深层组件树里，
 * 跨层信号走 AppStorage（与 toast 同款 seq 写法），不走回调穿透。
 *
 * 右侧投播按钮（AVCastPicker）：颜色随沉浸背景明暗切换 —— 暗背景白图标、
 * 亮背景黑图标（STORE_PLAYER_BG_DARK 由 PlayerInfoComponent 取色后写入）。
 */

import { AVCastPicker } from '@kit.AVSessionKit';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { STORE_PLAYER_BG_DARK, STORE_PLAYER_CLOSE_REQUEST, STORE_PLAYER_CONTENT_EXIT, STORE_PLAYER_OPEN } from '../../common/Constants';
import {
  ENTRANCE_DURATION_MS,
  LAYER_DELAY_TOP,
  LAYER_EXIT_DIVE_TOP_VP,
  LAYER_EXIT_SCALE
} from '../../common/constants/InteractionConstants';

@Component
export struct TopAreaComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp(STORE_PLAYER_BG_DARK) isDark: boolean = true;
  /**
   * 播放页展开态：收起（→ false，落在 Index.closePlayer 的 animateTo 闭包内）时
   * 把本层入场状态复位为隐藏 —— 随收起动画一起插值淡出（逆向镜像的一部分）。
   */
  @StorageProp(STORE_PLAYER_OPEN) @Watch('onPlayerOpenChanged') playerOpen: boolean = false;
  /**
   * 收起时内容层退场信号（seq 递增，写在 Index.closePlayer 主动画闭包内）：
   * 复位落在该闭包内 → 顶栏「淡出 + 俯冲下潜 + 缩小」与背景面收缩同曲线同步插值
   * （2026-10-21 用户要求：退场不要纯淡出，要跟着收缩走向迷你栏）。与 playerOpen 复位幂等共存。
   */
  @StorageProp(STORE_PLAYER_CONTENT_EXIT) @Watch('onContentExit') contentExitSeq: number = 0;
  /** 收起退场：俯冲向迷你栏的下潜位移（vp）与缩放（复位落在收起主动画闭包内 → 随收缩同步动画） */
  @State exitDiveY: number = 0;
  @State exitScale: number = 1;

  /**
   * 分层入场（方案 B）：顶栏在主动画落位后第一批淡入，**只淡入不位移** ——
   * 顶栏上下位移会像「从上面掉下来」，与「从下往上长出来」的整页方向相冲。
   * 必须是 `@State`：普通成员只在创建时初始化一次，父组件重渲染不会重新赋值。
   */
  @State enterOpacity: number = 0;

  /** 收起按钮点击 → 发收起请求（seq 递增，Index @Watch 消费） */
  private requestClose(): void {
    const seq: number | undefined = AppStorage.get<number>(STORE_PLAYER_CLOSE_REQUEST);
    AppStorage.setOrCreate(STORE_PLAYER_CLOSE_REQUEST, (seq ?? 0) + 1);
  }

  /** 收起复位：入场状态回隐藏态（落在收起 animateTo 内即动画淡出） */
  private onPlayerOpenChanged(): void {
    if (this.playerOpen) {
      return;
    }
    this.enterOpacity = 0;
  }

  /** 退场复位：淡出 + 俯冲向迷你栏（复位落在收起主动画闭包内 → 与背景面收缩同步插值） */
  private onContentExit(): void {
    this.enterOpacity = 0;
    this.exitDiveY = LAYER_EXIT_DIVE_TOP_VP;
    this.exitScale = LAYER_EXIT_SCALE;
  }

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
      // 收起按钮：整页唯一的收起入口（另一路是系统返回，Index.onBackPress 拦截）。
      // 颜色随背景明暗（与投播按钮同口径）；padding 8 扩大命中区。
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(24)
        .fontColor([this.isDark ? Color.White : Color.Black])
        .padding(8)
        .onClick((): void => {
          this.requestClose();
        })
      // 中间弹性占位：收起键贴左、投播键贴右
      Blank()
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
    // 分层入场只挂 opacity；收起退场在此叠 translate/scale（俯冲向迷你栏），均不动 layout 属性
    .opacity(this.enterOpacity)
    .translate({ y: this.exitDiveY })
    .scale({ x: this.exitScale, y: this.exitScale })
  }
}
