/**
 * 播放页进度区（独立子组件）：
 * 进度条四分支（经典 Slider / 流光 / 波点 / 频谱，设置 → 外观可切）+ 双侧时间行。
 *
 * 独立成组件的原因：STORE_PROGRESS 播放中每 500ms 推送一次，进度订阅
 * （@StorageLink + @Watch）必须圈死在本组件小子树内 ——
 *   · 500ms 快照驱动的重渲染被圈死在本组件内（进度条 + 两个时间标签）；
 *   · 控制区其余部分播放期间零重渲染；
 *   · 紧凑模式（阔折叠外屏）下本组件整体不挂载，订阅与插值随卸载注销。
 *
 * 进度插值：500ms 快照 + 520ms 线性插值（animateTo 反复重定目标，滑块匀速
 * 连续推进而非半秒一跳；属性差值插值走渲染管线，JS 侧每秒只跑两次状态写入）；
 * 大跳（seek / 切歌）duration 0 直接落位不扫动。
 *
 * 进度条交互仍为「拖动本地跟随、松手才 seek」：拖动期间 STORE_PROGRESS 照常
 * 更新，由 dragging + dragValue 隔离，插值动画在拖动中暂停。
 */

import {
  Track,
  PROGRESS_STYLE_SHIMMER,
  PROGRESS_STYLE_PULSE,
  PROGRESS_STYLE_WAVE
} from '../../model/MusicModels';
import { MusicPlayer } from '../../player/MusicPlayer';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { PlayerConstants } from '../../common/constants/PlayerConstants';
import { ShimmerProgressBar } from './ShimmerProgressBar';
import { PulseDotProgressBar } from './PulseDotProgressBar';
import { WaveBarsProgressBar } from './WaveBarsProgressBar';
import {
  STORE_CURRENT_TRACK,
  STORE_PROGRESS,
  STORE_DURATION,
  STORE_PROGRESS_STYLE
} from '../../common/Constants';

function formatTime(totalSeconds: number): string {
  const s: number = Math.max(0, Math.floor(totalSeconds));
  const m: number = Math.floor(s / 60);
  const r: number = s % 60;
  return `${m}:${r < 10 ? '0' : ''}${r}`;
}

/** 进度插值时长（ms）：STORE_PROGRESS 按 500ms 分桶推送，插值略长避免步进感 */
const PROGRESS_TWEEN_MS: number = 520;
/** 判定「大跳」的阈值（秒）：超过视为 seek / 切歌，直接落位不做扫动 */
const PROGRESS_JUMP_SEC: number = 2;

@Component
export struct PlayerProgressArea {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 播放进度（秒，500ms 分桶推送）：只读订阅，播放内核 MusicPlayer 唯一写入 */
  @StorageProp(STORE_PROGRESS) @Watch('onProgressTick') progress: number = 0;
  @StorageProp(STORE_DURATION) duration: number = 0;
  @StorageProp(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /**
   * 播放页进度条样式（设置页镜像）：SHIMMER（流光）/ PULSE（波点）/ WAVE（频谱）
   * 走自绘分支，其余取值（含未知值）回落经典 Slider —— 交互契约四档一致。
   */
  @StorageProp(STORE_PROGRESS_STYLE) progressStyle: string = '';
  /** 拖动隔离：拖动中滑块显示 dragValue，松手恢复跟随插值进度 */
  @State dragging: boolean = false;
  @State dragValue: number = 0;
  /** 进度条平滑显示值（本动画独占）：播放中由 onProgressTick 插值驱动 */
  @State sliderValue: number = 0;
  /** 进度条拖拽反馈缩放（本动画独占） */
  @State trackScale: number = 1;

  private player: MusicPlayer = MusicPlayer.getInstance();

  aboutToAppear(): void {
    this.sliderValue = this.progress;
  }

  /**
   * 进度写入（500ms 一次）→ 520ms 线性插值：animateTo 反复重定目标，
   * 滑块匀速连续推进而非半秒一跳；拖动中不插值（滑块跟手指）；
   * 大跳（seek / 切歌）duration 0 直接落位。
   */
  private onProgressTick(): void {
    if (this.dragging) {
      return;
    }
    const target: number = this.progress;
    const jump: number = Math.abs(target - this.sliderValue);
    const duration: number = jump > PROGRESS_JUMP_SEC ? 0 : PROGRESS_TWEEN_MS;
    this.getUIContext().animateTo({ duration: duration, curve: Curve.Linear }, (): void => {
      this.sliderValue = target;
    });
  }

  /** 拖拽开始：进度条轻微放大（独立 animateTo，不与插值共用通道） */
  private scaleUpTrack(): void {
    this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, (): void => {
      this.trackScale = 1.04;
    });
  }

  /** 松手：先落位显示值，再关键帧回弹（轻微下探 → 回 1） */
  private bounceBackTrack(value: number): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.sliderValue = value;
    });
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      {
        duration: 0,
        event: (): void => {
          this.trackScale = 1.04;
        }
      },
      {
        duration: 150,
        curve: Curve.EaseOut,
        event: (): void => {
          this.trackScale = 0.99;
        }
      },
      {
        duration: 130,
        curve: Curve.EaseOut,
        event: (): void => {
          this.trackScale = 1;
        }
      }
    ]);
  }

  /**
   * 生效总时长：AVPlayer 的 durationUpdate 在部分流上拿不到值，
   * 回退曲目自带时长，否则 max=0 时拖动手势按 0 换算、seek 永远是 0 秒。
   */
  private effectiveDuration(): number {
    if (this.duration > 0) {
      return this.duration;
    }
    // ?. 同时兜住 null / undefined（@StorageLink 运行时可能送 undefined）
    return this.currentTrack?.duration ?? 0;
  }

  // ===== 自绘进度条（流光 / 波点 / 频谱）的拖拽回调 =====
  // 交互契约与经典 Slider 完全一致：按下/拖动只写本地隔离值，松手才 seek。

  /** 自绘条按下：进入拖拽隔离（视觉反馈由子组件自理，父只置位） */
  private onBarDragStart(): void {
    this.dragging = true;
  }

  /** 自绘条拖动：本地跟随，不写播放进度 */
  private onBarDragMove(sec: number): void {
    this.dragValue = sec;
  }

  /** 自绘条松手 / 点按定位：交给播放内核；显示值直接落位（trackScale 无视觉、等效空跑） */
  private onBarDragEnd(sec: number): void {
    this.dragging = false;
    if (this.effectiveDuration() > 0) {
      this.player.seek(sec);
    }
    this.bounceBackTrack(sec);
  }

  build() {
    Column() {
      // 进度条四分支（设置 → 外观「播放页进度条样式」）：三种自绘样式共用
      // value/max/拖拽回调契约，经典 Slider 保持原样（含未知值兜底）。
      if (this.progressStyle === PROGRESS_STYLE_SHIMMER) {
        ShimmerProgressBar({
          value: this.dragging ? this.dragValue : this.sliderValue,
          max: this.effectiveDuration(),
          onSeekStart: (): void => {
            this.onBarDragStart();
          },
          onSeekMove: (sec: number): void => {
            this.onBarDragMove(sec);
          },
          onSeekEnd: (sec: number): void => {
            this.onBarDragEnd(sec);
          }
        })
          .margin({
            left: new BreakpointType<Resource>({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint),
            right: new BreakpointType<Resource>({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint)
          })
      } else if (this.progressStyle === PROGRESS_STYLE_PULSE) {
        PulseDotProgressBar({
          value: this.dragging ? this.dragValue : this.sliderValue,
          max: this.effectiveDuration(),
          onSeekStart: (): void => {
            this.onBarDragStart();
          },
          onSeekMove: (sec: number): void => {
            this.onBarDragMove(sec);
          },
          onSeekEnd: (sec: number): void => {
            this.onBarDragEnd(sec);
          }
        })
          .margin({
            left: new BreakpointType<Resource>({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint),
            right: new BreakpointType<Resource>({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint)
          })
      } else if (this.progressStyle === PROGRESS_STYLE_WAVE) {
        WaveBarsProgressBar({
          value: this.dragging ? this.dragValue : this.sliderValue,
          max: this.effectiveDuration(),
          onSeekStart: (): void => {
            this.onBarDragStart();
          },
          onSeekMove: (sec: number): void => {
            this.onBarDragMove(sec);
          },
          onSeekEnd: (sec: number): void => {
            this.onBarDragEnd(sec);
          }
        })
          .margin({
            left: new BreakpointType<Resource>({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint),
            right: new BreakpointType<Resource>({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint)
          })
      } else {
        Slider({
          min: 0,
          max: Math.max(1, this.effectiveDuration()),
          step: 1,
          style: SliderStyle.OutSet,
          value: this.dragging ? this.dragValue : this.sliderValue
        })
          .selectedColor($r('app.color.slider_select'))
          .trackColor($r('app.color.slider_track'))
          .scale({ x: this.trackScale, y: this.trackScale })
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.Begin) {
              // 按下：只动本地滑块并轻微放大，不写播放进度
              this.dragging = true;
              this.dragValue = value;
              this.scaleUpTrack();
              return;
            }
            if (mode === SliderChangeMode.Moving) {
              this.dragValue = value;
              return;
            }
            // 松手 / 点击定位：交给播放内核，进度条回弹
            this.dragging = false;
            if (this.effectiveDuration() > 0) {
              this.player.seek(value);
            }
            this.bounceBackTrack(value);
          })
          .height($r('app.float.slider_height'))
          .margin({
            left: new BreakpointType<Resource>({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint),
            right: new BreakpointType<Resource>({
              sm: $r('app.float.slider_margin_sm'),
              md: $r('app.float.slider_margin_md'),
              lg: $r('app.float.slider_margin_lg')
            }).getValue(this.currentBreakpoint)
          })
      }
      Row() {
        Text(formatTime(this.dragging ? this.dragValue : this.sliderValue))
          .fontColor($r('app.color.play_text_color'))
          .fontSize($r('app.float.singer_title_sm'))
          .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
          .lineHeight('14vp')
        Text(formatTime(this.effectiveDuration()))
          .fontColor($r('app.color.play_text_color'))
          .fontSize($r('app.float.singer_title_sm'))
          .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
          .lineHeight('14vp')
      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .margin({
      top: $r('app.float.slider_margin_top'),
      bottom: this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG ?
      $r('app.float.slider_margin_bottom_lg') : $r('app.float.slider_margin_bottom')
    })
  }
}
