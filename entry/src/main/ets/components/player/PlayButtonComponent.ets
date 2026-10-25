/**
 * 播放 / 暂停主按钮（独立子组件）。
 *
 * 基础样式：无底板纯图标，居中播放/暂停图标。
 *
 * 动效：
 *   · 播放态 —— ScaleSymbolEffect 连续脉冲（isActive 形态挂在
 *     SymbolGlyph 上，isPlay 翻转即启停，无需 @Watch）；
 *   · 点击 —— keyframeAnimateTo 一次快速缩小回弹（1→0.88→1.02→1，400ms），
 *     作用在 Column 命中区上，与 glyph 上的官方脉冲分属不同节点，互不叠加。
 */

import { MusicPlayer } from '../../player/MusicPlayer';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { STORE_IS_PLAYING } from '../../common/Constants';

/** 图标字号 */
const PLAY_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 44, md: 44, lg: 52 });
/** 透明命中区直径（vp），不渲染底板 */
const PLAY_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 64, md: 64, lg: 76 });

@Component
export struct PlayButtonComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** isPlay 翻转直接驱动 glyph 上的官方脉冲启停（isActive 形态），无需 @Watch */
  @StorageLink(STORE_IS_PLAYING) isPlay: boolean = false;

  /** 点击回弹缩放（仅点击瞬间的 Column 形变，与 glyph 脉冲分属不同节点） */
  @State playScaleX: number = 1;
  @State playScaleY: number = 1;

  private player: MusicPlayer = MusicPlayer.getInstance();

  /** 点击反馈：一次快速缩小回弹 */
  private playTapBounce(): void {
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      {
        duration: 0,
        event: (): void => {
          this.playScaleX = 1;
          this.playScaleY = 1;
        }
      },
      {
        duration: 120,
        curve: Curve.EaseIn,
        event: (): void => {
          this.playScaleX = 0.88;
          this.playScaleY = 0.88;
        }
      },
      {
        duration: 180,
        curve: Curve.EaseOut,
        event: (): void => {
          this.playScaleX = 1.02;
          this.playScaleY = 1.02;
        }
      },
      {
        duration: 100,
        curve: Curve.EaseOut,
        event: (): void => {
          this.playScaleX = 1;
          this.playScaleY = 1;
        }
      }
    ]);
  }

  build() {
    Column() {
      SymbolGlyph(this.isPlay ? $r('sys.symbol.pause_round_triangle_fill') : $r('sys.symbol.play_round_triangle_fill'))
        .fontSize(PLAY_ICON_SIZE.getValue(this.currentBreakpoint))
        .fontColor([Color.White])
        .symbolEffect(new ScaleSymbolEffect(EffectScope.WHOLE), this.isPlay)
    }
    .width(PLAY_BUTTON_SIZE.getValue(this.currentBreakpoint))
    .height(PLAY_BUTTON_SIZE.getValue(this.currentBreakpoint))
    .scale({ x: this.playScaleX, y: this.playScaleY })
    .onClick((): void => {
      // 先翻转播放态（glyph 脉冲随 isActive 启停），再补一次点击回弹
      this.player.togglePlay();
      this.playTapBounce();
    })
  }
}
