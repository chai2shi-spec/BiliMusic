/**
 * 播放页进度条样式 C ——「脉冲波点」（ControlAreaComponent 四分支之一）。
 *
 * 视觉：2.5vp 细线轨道（未播半透明白 / 已播主题色）+ 进度头 12vp 主题色圆点，
 * 无块状滑块 —— 轻量克制版。
 *
 * 动效（createAnimator 无限循环 + 一次 animateTo，与 CoverDiscComponent 同底座）：
 *   · 双层脉冲 —— 1.2s/周期，两枚 24vp 描边圆环相位错开半周期外扩渐隐
 *     （onFrame 单帧算两个相位，scale 0.5→2.2 / opacity 0.55→0）；
 *   · 待机呼吸 —— 暂停时圆点 1.8s/周期 1↔1.04 缩放（脉冲环隐藏）；
 *   · 落位涟漪 —— 松手 seek 后一次性 320ms 涟漪（scale 1→2.4 / 渐隐）；
 *   · 拖拽放大 —— 按下圆点 1.35，松手回 1（animateTo）。
 * 播放态 play/pause（@Watch STORE_IS_PLAYING）；aboutToDisappear 统一 finish。
 *
 * 性能：脉冲/呼吸只动 scale/opacity（合成器属性）；涟漪一次 animateTo。
 * 交互契约与其余三档一致：拖动本地跟随、松手才 seek、点按定位 —— 触摸
 * 事件只换算上报，交互状态（dragging/dragValue/插值）全部由父组件持有。
 */

import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { STORE_IS_PLAYING, STORE_THEME_PRIMARY } from '../../common/Constants';

/** 命中区高度（vp） */
const PULSE_HIT_VP: number = 32;
/** 轨道线厚度（vp） */
const PULSE_LINE_VP: number = 2.5;
/** 圆点直径（vp） */
const PULSE_DOT_VP: number = 12;
/** 脉冲环边长（vp） */
const PULSE_RING_VP: number = 24;
/** 涟漪环边长（vp） */
const PULSE_RIPPLE_VP: number = 28;
/** 脉冲周期（ms）：两环共用一个相位时钟，第二环错开半周期 */
const PULSE_WAVE_MS: number = 1200;
/** 待机呼吸周期（ms） */
const PULSE_BREATHE_MS: number = 1800;
/** 落位涟漪时长（ms） */
const PULSE_RIPPLE_MS: number = 320;
/** 拖拽圆点放大系数 */
const PULSE_DRAG_SCALE: number = 1.35;
/** 呼吸缩放幅度 */
const PULSE_BREATHE_AMP: number = 0.04;

@Component
export struct PulseDotProgressBar {
  /** 显示进度（秒）：父组件按拖拽态合成（dragging ? dragValue : sliderValue） */
  @Prop value: number = 0;
  /** 生效总时长（秒）：<=0 时进度按 0 处理、触摸不上报 */
  @Prop max: number = 0;
  /**
   * 拖拽起止/移动回调（秒）：父组件持有交互状态并决定是否 seek。
   * ⚠️ 不能叫 onDragStart/onDragMove/onDragEnd —— 与 CustomComponent 内置
   * 拖拽事件方法同名，编译器按基类签名校验直接报类型不兼容。
   */
  onSeekStart: () => void = (): void => {};
  onSeekMove: (sec: number) => void = (_sec: number): void => {};
  onSeekEnd: (sec: number) => void = (_sec: number): void => {};

  @StorageLink(STORE_IS_PLAYING) @Watch('onPlayingChanged') isPlay: boolean = false;
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  /** 实测轨道宽度（vp）：手势换算数据源 */
  @State trackWidth: number = 0;
  /** 组件内拖拽态：只驱动视觉反馈（藏环/放大），交互真值在父组件 */
  @State dragging: boolean = false;
  /** 圆点拖拽放大系数（animateTo 驱动） */
  @State dragScale: number = 1;
  /** 脉冲环①相位（0~1）：pulseAnim 每帧回写 */
  @State ring1Phase: number = 0;
  /** 脉冲环②相位（0~1）：与①错开半周期 */
  @State ring2Phase: number = 0.5;
  /** 待机呼吸缩放（breatheAnim 每帧回写；播放中不参与合成） */
  @State breatheScale: number = 1;
  /** 落位涟漪进度（0 起播 → 1 完成；完成态透明不可见） */
  @State ripplePhase: number = 1;

  /** 脉冲 animator（aboutToAppear 创建，销毁时 finish） */
  private pulseAnim: AnimatorResult | null = null;
  /** 待机呼吸 animator（aboutToAppear 创建，销毁时 finish） */
  private breatheAnim: AnimatorResult | null = null;

  /** Area 尺寸（Length）→ vp 数值；资源型（理论上不会出现）按 0 兜底 */
  private toVp(v: Length): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      return parseFloat(v);
    }
    return 0;
  }

  private pulseOptions(): AnimatorOptions {
    return {
      duration: PULSE_WAVE_MS,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: -1,
      begin: 0,
      end: PULSE_WAVE_MS
    };
  }

  private breatheOptions(): AnimatorOptions {
    return {
      duration: PULSE_BREATHE_MS,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: -1,
      begin: 0,
      end: PULSE_BREATHE_MS
    };
  }

  aboutToAppear(): void {
    // UIContext 在属性初始化时未就绪，animator 延迟到这里创建（同 CoverDisc）
    try {
      this.pulseAnim = this.getUIContext().createAnimator(this.pulseOptions());
      this.pulseAnim.onFrame = (v: number): void => {
        // 单一相位时钟驱动两环（第二环错开半周期），onFrame 只写 number
        const p: number = v / PULSE_WAVE_MS;
        this.ring1Phase = p;
        this.ring2Phase = (p + 0.5) % 1;
      };
      this.breatheAnim = this.getUIContext().createAnimator(this.breatheOptions());
      this.breatheAnim.onFrame = (v: number): void => {
        this.breatheScale = 1 + PULSE_BREATHE_AMP * Math.sin(v / PULSE_BREATHE_MS * Math.PI * 2);
      };
      // 挂载时按播放态手动起停（@Watch 不会触发）
      if (this.isPlay) {
        this.pulseAnim.play();
      } else {
        this.breatheAnim.play();
      }
    } catch (e) {
      // animator 创建失败只影响脉冲/呼吸，进度展示与拖拽不受影响
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[PulseDot] createAnimator failed: ${msg}`);
    }
  }

  aboutToDisappear(): void {
    if (this.pulseAnim !== null) {
      this.pulseAnim.finish();
      this.pulseAnim = null;
    }
    if (this.breatheAnim !== null) {
      this.breatheAnim.finish();
      this.breatheAnim = null;
    }
  }

  /** 播放态变化：播放 → 脉冲续动、呼吸停；暂停 → 脉冲冻结、呼吸起 */
  onPlayingChanged(_propName: string): void {
    const pulse: AnimatorResult | null = this.pulseAnim;
    const breathe: AnimatorResult | null = this.breatheAnim;
    if (this.isPlay) {
      if (pulse !== null) {
        pulse.play();
      }
      if (breathe !== null) {
        breathe.pause();
      }
      this.breatheScale = 1;
    } else {
      if (pulse !== null) {
        pulse.pause();
      }
      if (breathe !== null) {
        breathe.play();
      }
    }
  }

  /** 进度比例（0~1）：时长未知时恒 0（不显示已播段） */
  private pct(): number {
    if (this.max <= 0) {
      return 0;
    }
    const p: number = this.value / this.max;
    return Math.min(1, Math.max(0, p));
  }

  /** 进度头中心 x（vp）：钳制在轨道内，未测宽时贴左 */
  private headX(): number {
    return Math.min(this.trackWidth, this.trackWidth * this.pct());
  }

  /** 圆点合成缩放：拖拽放大 × 待机呼吸（播放中呼吸恒 1） */
  private dotScale(): number {
    const breathe: number = this.isPlay ? 1 : this.breatheScale;
    return this.dragScale * breathe;
  }

  /** 触摸横坐标 → 秒（钳制 0~max） */
  private secAt(x: number): number {
    if (this.trackWidth <= 0) {
      return 0;
    }
    const ratio: number = Math.min(1, Math.max(0, x / this.trackWidth));
    return ratio * this.max;
  }

  /** 松手落位涟漪：0 落位起播 → 1 渐隐完成（完成后透明不可见） */
  private playRipple(): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.ripplePhase = 0;
    });
    this.getUIContext().animateTo({ duration: PULSE_RIPPLE_MS, curve: Curve.EaseOut }, (): void => {
      this.ripplePhase = 1;
    });
  }

  build() {
    Stack() {
      // 未播段底线
      Row() {}
        .width(StyleConstants.FULL_WIDTH)
        .height(PULSE_LINE_VP)
        .borderRadius(PULSE_LINE_VP / 2)
        .backgroundColor($r('app.color.slider_track'))

      // 已播段：主题色细线。
      // ⚠️ 百分比宽的已播段必须包在全宽 Row 里：外层 Stack 默认
      // alignContent Center 会把它水平居中 → 进度看起来「从中间向两侧推进」；
      // 全宽 Row 主轴从起点排布，内层百分比细线才能从左向右生长。
      Row() {
        Row() {}
          .width(`${(this.pct() * 100).toFixed(2)}%`)
          .height(PULSE_LINE_VP)
          .borderRadius(PULSE_LINE_VP / 2)
          .backgroundColor(this.themePrimary)
      }
      .width(StyleConstants.FULL_WIDTH)
      .height(PULSE_LINE_VP)

      // 落位涟漪（一次性，完成态 opacity 0 不可见）。
      // 环用 Column+border 画（不用 Circle.stroke/fill —— SDK 26 API，兼容 23 无效）
      Column() {}
        .width(PULSE_RIPPLE_VP)
        .height(PULSE_RIPPLE_VP)
        .borderRadius(PULSE_RIPPLE_VP / 2)
        .border({ width: 2, color: this.themePrimary })
        .position({
          x: this.headX() - PULSE_RIPPLE_VP / 2,
          y: (PULSE_HIT_VP - PULSE_RIPPLE_VP) / 2
        })
        .scale({ x: 1 + 1.4 * this.ripplePhase, y: 1 + 1.4 * this.ripplePhase })
        .opacity(0.6 * (1 - this.ripplePhase))

      // 脉冲环①：外扩渐隐（播放且非拖拽时可见）
      Column() {}
        .width(PULSE_RING_VP)
        .height(PULSE_RING_VP)
        .borderRadius(PULSE_RING_VP / 2)
        .border({ width: 2, color: this.themePrimary })
        .position({
          x: this.headX() - PULSE_RING_VP / 2,
          y: (PULSE_HIT_VP - PULSE_RING_VP) / 2
        })
        .scale({ x: 0.5 + 1.7 * this.ring1Phase, y: 0.5 + 1.7 * this.ring1Phase })
        .opacity(this.isPlay && !this.dragging ? 0.55 * (1 - this.ring1Phase) : 0)

      // 脉冲环②：错开半周期
      Column() {}
        .width(PULSE_RING_VP)
        .height(PULSE_RING_VP)
        .borderRadius(PULSE_RING_VP / 2)
        .border({ width: 2, color: this.themePrimary })
        .position({
          x: this.headX() - PULSE_RING_VP / 2,
          y: (PULSE_HIT_VP - PULSE_RING_VP) / 2
        })
        .scale({ x: 0.5 + 1.7 * this.ring2Phase, y: 0.5 + 1.7 * this.ring2Phase })
        .opacity(this.isPlay && !this.dragging ? 0.55 * (1 - this.ring2Phase) : 0)

      // 进度头圆点：拖拽放大 × 待机呼吸
      Column() {}
        .width(PULSE_DOT_VP)
        .height(PULSE_DOT_VP)
        .borderRadius(PULSE_DOT_VP / 2)
        .backgroundColor(this.themePrimary)
        .position({
          x: this.headX() - PULSE_DOT_VP / 2,
          y: (PULSE_HIT_VP - PULSE_DOT_VP) / 2
        })
        .scale({ x: this.dotScale(), y: this.dotScale() })
    }
    .width(StyleConstants.FULL_WIDTH)
    .height(PULSE_HIT_VP)
    .onAreaChange((_old: Area, n: Area): void => {
      const w: number = this.toVp(n.width);
      if (w > 0) {
        this.trackWidth = w;
      }
    })
    .onTouch((event: TouchEvent): void => {
      // 时长未知/未测宽时手势无效（与其余档位 max<=0 的守卫一致）
      if (this.max <= 0 || this.trackWidth <= 0) {
        return;
      }
      const sec: number = this.secAt(event.touches[0].x);
      if (event.type === TouchType.Down) {
        this.dragging = true;
        this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, (): void => {
          this.dragScale = PULSE_DRAG_SCALE;
        });
        this.onSeekStart();
        this.onSeekMove(sec);
      } else if (event.type === TouchType.Move) {
        this.onSeekMove(sec);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        if (!this.dragging) {
          return;
        }
        this.dragging = false;
        this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, (): void => {
          this.dragScale = 1;
        });
        this.playRipple();
        this.onSeekEnd(sec);
      }
    })
    // 消费型横向手势（2026-10-22 修「拖进度条整页横移」）：onTouch 只观察不消费、
    // 不进手势仲裁 —— SM 形态下本组件在 PlayerInfoComponent 的 Swiper（封面页|
    // 歌词页）子树内，横向拖动会穿透到 Swiper 的**内置翻页 PanGesture**（swiper.d.ts
    // 明载 Swiper 翻页即内置 pan），整页跟着手指横移。此条 PanGesture 作为子节点
    // 自定义手势参与仲裁、深于 Swiper 必胜 → 翻页永不启动；onTouch 与手势仲裁
    // 互不影响，拖拽换算逻辑原样。方向锁 Horizontal：歌词页列表竖向滚动不受牵连。
    // 取舍：进度条命中区内的横向手势归进度条所有，想翻页需从条外起手。
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 1 }))
  }
}
