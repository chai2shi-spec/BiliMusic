/**
 * 播放控制区（参考 audio-interaction-master 的 ControlAreaComponent 版式重做）。
 *
 * 版式自上而下：功能行（播放模式 / 播放列表）→ 进度条 + 双侧时间 → 三键控制行。
 * 控制调用全部走 MusicPlayer 单例；队列弹层复用共享组件 QueueSheet；
 * 按用户决策不引入收藏 / 静音按钮。
 *
 * 动效拆分（每条动画独立变量、互不共用，无全局统一 animation）：
 *   · 播放/暂停主按钮 → 独立子组件 PlayButtonComponent（呼吸形变 + 点击回弹自理）；
 *   · 模式 / 列表 / 上一曲 / 下一曲 → BounceIconButton（仅点击单次回弹，无持续动画）；
 *   · 进度条 → 播放时对 500ms 一次的进度写入做 520ms 线性插值（平滑推进，
 *     大跳即 seek/切歌直接落位不扫动）；拖拽时轻微放大，松手关键帧回弹。
 *
 * 进度条交互仍为「拖动本地跟随、松手才 seek」：拖动期间 STORE_PROGRESS 照常
 * 更新，由 dragging + dragValue 隔离，插值动画在拖动中暂停。
 */

import { Track, RepeatMode } from '../../model/MusicModels';
import { MusicPlayer } from '../../player/MusicPlayer';
import { QueueSheet, repeatLabelOf, modeIconOf, nextRepeatMode } from '../QueueSheet';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { showAppToast } from '../AppToast';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { PlayerConstants } from '../../common/constants/PlayerConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { PlayButtonComponent } from './PlayButtonComponent';
import { BounceIconButton } from './BounceIconButton';
import {
  STORE_CURRENT_TRACK,
  STORE_PROGRESS,
  STORE_DURATION,
  STORE_REPEAT_MODE
} from '../../common/Constants';

function formatTime(totalSeconds: number): string {
  const s: number = Math.max(0, Math.floor(totalSeconds));
  const m: number = Math.floor(s / 60);
  const r: number = s % 60;
  return `${m}:${r < 10 ? '0' : ''}${r}`;
}

/** 切歌键（上一曲 / 下一曲）图标与圆底尺寸 */
const PREVNEXT_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 26, md: 26, lg: 30 });
const PREVNEXT_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 52, md: 52, lg: 60 });
/** 功能键（播放模式 / 播放列表）图标与圆底尺寸 */
const FUNC_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 22, md: 22, lg: 26 });
const FUNC_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 40, md: 40, lg: 46 });
/** 进度插值时长（ms）：STORE_PROGRESS 按 500ms 分桶推送，插值略长避免步进感 */
const PROGRESS_TWEEN_MS: number = 520;
/** 判定「大跳」的阈值（秒）：超过视为 seek / 切歌，直接落位不做扫动 */
const PROGRESS_JUMP_SEC: number = 2;

@Component
export struct ControlAreaComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink(STORE_PROGRESS) @Watch('onProgressTick') progress: number = 0;
  @StorageLink(STORE_DURATION) duration: number = 0;
  @StorageLink(STORE_REPEAT_MODE) repeatMode: RepeatMode = RepeatMode.NONE;
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /** 队列弹层开关（本组件自持，bindSheet 挂在播放列表按钮上） */
  @State showQueueSheet: boolean = false;
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
    return this.currentTrack !== null ? this.currentTrack.duration : 0;
  }

  /** 短提示：模式这种「图标变化不明显」的切换给一次文字反馈 */
  private toast(message: string): void {
    showAppToast(message);
  }

  private cycleRepeat(): void {
    const next: RepeatMode = nextRepeatMode(this.repeatMode);
    this.player.setRepeatMode(next);
    this.toast(`播放模式：${repeatLabelOf(next)}`);
  }

  build() {
    Column() {
      Row() {
        BounceIconButton({
          icon: modeIconOf(this.repeatMode),
          iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
          buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
          onTap: (): void => {
            this.cycleRepeat();
          }
        })

        BounceIconButton({
          icon: $r('sys.symbol.list_bullet'),
          iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
          buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
          onTap: (): void => {
            this.showQueueSheet = true;
          }
        })
          .bindSheet($$this.showQueueSheet, this.QueueSheetHost(), {
            height: SheetSize.MEDIUM,
            dragBar: true,
            showClose: false
          })
      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceBetween)

      Column() {
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

      Row() {
        BounceIconButton({
          icon: $r('sys.symbol.backward_end_fill'),
          iconSize: PREVNEXT_ICON_SIZE.getValue(this.currentBreakpoint),
          buttonSize: PREVNEXT_BUTTON_SIZE.getValue(this.currentBreakpoint),
          onTap: (): void => {
            this.player.prev();
          }
        })

        PlayButtonComponent()

        BounceIconButton({
          icon: $r('sys.symbol.forward_end_fill'),
          iconSize: PREVNEXT_ICON_SIZE.getValue(this.currentBreakpoint),
          buttonSize: PREVNEXT_BUTTON_SIZE.getValue(this.currentBreakpoint),
          onTap: (): void => {
            this.player.next();
          }
        })
      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('app.float.control_padding'),
        right: $r('app.float.control_padding')
      })
    }
  }

  /** 队列弹层宿主：bindSheet 只收 CustomBuilder，包一层共享 QueueSheet */
  @Builder
  QueueSheetHost(): void {
    QueueSheet({ showSheet: this.showQueueSheet })
  }
}
