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
  LAYER_DELAY_TOP
} from '../../common/constants/InteractionConstants';

@Component
export struct TopAreaComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp(STORE_PLAYER_BG_DARK) isDark: boolean = true;
  /**
   * 播放页展开态：收起（→ false，落在 Index.closePlayer 的主动画闭包内）时
   * 把本层入场状态复位为隐藏 —— 与 onContentExit 复位幂等兜底（那时已是隐藏值，
   * 同值复位不产生属性变化，不会触发动画）。
   */
  @StorageProp(STORE_PLAYER_OPEN) @Watch('onPlayerOpenChanged') playerOpen: boolean = false;
  /**
   * 收起时内容层瞬隐信号（seq 递增，写在 Index.closePlayer 的主动画闭包**外**）：
   * 复位不在任何隐式动画作用域内 → 顶栏单帧直接消失（2026-10-22 用户要求
   * 「除封面和背景的其他元素直接消失」，替代 2026-10-21 的俯冲退场）。
   */
  @StorageProp(STORE_PLAYER_CONTENT_EXIT) @Watch('onContentExit') contentExitSeq: number = 0;
  /** 瞬隐闸门：onContentExit 置 true 后，在途的延迟入场闭包不得再把顶栏点亮 */
  private exitRequested: boolean = false;

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

  /** 收起复位：入场状态回隐藏态（幂等兜底，见 playerOpen 注释） */
  private onPlayerOpenChanged(): void {
    if (this.playerOpen) {
      return;
    }
    this.enterOpacity = 0;
  }

  /** 瞬隐复位：入场状态回隐藏态（闭包外单帧生效） + 拦截在途延迟入场 */
  private onContentExit(): void {
    this.exitRequested = true;
    this.enterOpacity = 0;
  }

  aboutToAppear(): void {
    this.exitRequested = false;
    this.getUIContext().animateTo(
      { duration: ENTRANCE_DURATION_MS, curve: Curve.EaseOut, delay: LAYER_DELAY_TOP },
      (): void => {
        // 竞态闸门：打开后 530ms 内收起时，本延迟闭包仍在途——不拦会把已瞬隐的
        // 顶栏重新点亮（收起飞行途中闪现）。
        if (!this.exitRequested) {
          this.enterOpacity = 1;
        }
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
    // 分层入场只挂 opacity；收起为闭包外瞬隐（onContentExit 单帧置 0），无退场变换
    .opacity(this.enterOpacity)
  }
}
