/**
 * 播放 / 暂停主按钮（独立子组件，从 ControlAreaComponent 抽出）。
 *
 * 基础样式：无底板纯图标（磨砂圆底已按需求移除），居中播放/暂停图标。
 *
 * 动效（变量全部自持，不与其他动画共用状态）：
 *   · 播放态 —— 持续「不规则呼吸」微形变：随机时长（1.6~3.0s）+ 随机目标
 *     （scale x/y 各自 0.97~1.03）的 EaseInOut 属性动画链，
 *     步与步之间目标 / 节奏都不同，无固定循环节奏；
 *   · 暂停态 —— duration 0 的新动画顶掉在途形变，立刻恢复标准尺寸；
 *   · 点击 —— keyframeAnimateTo 一次快速缩小回弹（1→0.88→1.02→1，400ms）。
 *
 * 定时器隔离：呼吸链由 breathGen 代际 + breathTimer 句柄管理，
 * aboutToDisappear 里统一清除，组件销毁不残留回调。
 */

import { MusicPlayer } from '../../player/MusicPlayer';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { STORE_IS_PLAYING } from '../../common/Constants';

/** 图标字号（沿用原控制区规格） */
const PLAY_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 44, md: 44, lg: 52 });
/** 透明命中区直径（vp），不渲染底板 */
const PLAY_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 64, md: 64, lg: 76 });

@Component
export struct PlayButtonComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink(STORE_IS_PLAYING) @Watch('onPlayingChanged') isPlay: boolean = false;

  /** 呼吸微形变：x/y 独立缩放 */
  @State playScaleX: number = 1;
  @State playScaleY: number = 1;

  /** 呼吸链调度代际与定时器句柄（销毁时清理） */
  private breathGen: number = 0;
  private breathTimer: number = -1;

  private player: MusicPlayer = MusicPlayer.getInstance();

  aboutToAppear(): void {
    if (this.isPlay) {
      this.startBreathing();
    }
  }

  aboutToDisappear(): void {
    this.stopBreathing(false);
  }

  /** 播放态变化：播放开启呼吸；暂停立刻停形变并恢复标准尺寸 */
  onPlayingChanged(_propName: string): void {
    if (this.isPlay) {
      this.startBreathing();
    } else {
      this.stopBreathing(true);
    }
  }

  private startBreathing(): void {
    this.stopBreathing(false);
    const gen: number = ++this.breathGen;
    this.breathStep(gen);
  }

  private breathStep(gen: number): void {
    if (!this.isPlay || gen !== this.breathGen) {
      return;
    }
    const duration: number = 1600 + Math.floor(Math.random() * 1400);
    this.getUIContext().animateTo({ duration: duration, curve: Curve.EaseInOut }, (): void => {
      this.playScaleX = 0.97 + Math.random() * 0.06;
      this.playScaleY = 0.97 + Math.random() * 0.06;
    });
    this.breathTimer = setTimeout((): void => {
      this.breathTimer = -1;
      this.breathStep(gen);
    }, duration);
  }

  /**
   * 停止微形变。reset=true（暂停）：duration 0 动画**顶掉在途动画**，
   * 立刻恢复标准尺寸；reset=false 仅清链（重启前内部调度 / 销毁清理）。
   */
  private stopBreathing(reset: boolean): void {
    this.breathGen++;
    if (this.breathTimer !== -1) {
      clearTimeout(this.breathTimer);
      this.breathTimer = -1;
    }
    if (reset) {
      this.getUIContext().animateTo({ duration: 0 }, (): void => {
        this.playScaleX = 1;
        this.playScaleY = 1;
      });
    }
  }

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
    }
    .width(PLAY_BUTTON_SIZE.getValue(this.currentBreakpoint))
    .height(PLAY_BUTTON_SIZE.getValue(this.currentBreakpoint))
    .scale({ x: this.playScaleX, y: this.playScaleY })
    .onClick((): void => {
      // 先翻转播放态（@Watch 停下/重启呼吸），再补一次点击回弹
      this.player.togglePlay();
      this.playTapBounce();
    })
  }
}
