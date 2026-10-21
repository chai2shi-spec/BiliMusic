/**
 * 播放页进度条样式 B ——「流光渐变条」（ControlAreaComponent 四分支之一）。
 *
 * 视觉：4vp 胶囊轨道（未播段半透明白 / 已播段主题色→白渐变）+ 12vp 主题色圆点
 * 滑块；流光带在已播段内循环扫动（clip 裁切，只照亮已播区）。
 *
 * 动效（全部 createAnimator 无限循环，与 CoverDiscComponent 同一套底座）：
 *   · 流光扫动 —— 1.6s/周期线性扫过全轨，onFrame 回写 shimmerX；
 *   · 呼吸光晕 —— 2s/周期正弦回写滑块 shadow 透明度；
 *   · 拖拽增厚 —— 按下轨道 4→8vp + 滑块放大 1.3，松手回弹（animateTo）。
 * 播放态 play/pause（@Watch STORE_IS_PLAYING），暂停即冻结不销毁；
 * aboutToDisappear 统一 finish。
 *
 * 性能：流光只动 position（合成器属性）；厚度/缩放只在拖拽起止各动一次。
 * 交互契约与其余三档一致：拖动本地跟随、松手才 seek、点按定位 —— 触摸
 * 事件只换算上报，交互状态（dragging/dragValue/插值）全部由父组件持有。
 */

import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { STORE_IS_PLAYING, STORE_THEME_PRIMARY } from '../../common/Constants';

/** 命中区高度（vp）：视觉轨道居中，上下留手指余量 */
const SHIMMER_HIT_VP: number = 32;
/** 常态轨道厚度（vp） */
const SHIMMER_TRACK_THICK: number = 4;
/** 拖拽态轨道厚度（vp）：按下增厚，突出「正在拖动」 */
const SHIMMER_TRACK_THICK_DRAG: number = 8;
/** 滑块直径（vp） */
const SHIMMER_THUMB_VP: number = 12;
/** 流光带宽度（vp） */
const SHIMMER_BAND_VP: number = 60;
/** 流光扫动周期（ms） */
const SHIMMER_SWEEP_MS: number = 1600;
/** 呼吸光晕周期（ms） */
const SHIMMER_BREATHE_MS: number = 2000;
/** 增厚/回弹动画时长（ms） */
const SHIMMER_THICKEN_MS: number = 160;

@Component
export struct ShimmerProgressBar {
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

  /** 实测轨道宽度（vp）：手势换算与流光扫动范围的数据源 */
  @State trackWidth: number = 0;
  /** 组件内拖拽态：只驱动视觉反馈（增厚/藏流光），交互真值在父组件 */
  @State dragging: boolean = false;
  /** 轨道当前厚度（vp）：拖拽起止各 animateTo 一次 */
  @State trackThickness: number = SHIMMER_TRACK_THICK;
  /** 滑块拖拽放大系数 */
  @State thumbScale: number = 1;
  /** 流光带当前位置（vp）：sweepAnim 每帧回写 */
  @State shimmerX: number = 0;
  /** 滑块光晕透明度（0~1）：breatheAnim 每帧回写，暂停时冻结回静态值 */
  @State glowOpacity: number = 0.4;

  /** 流光扫动 animator（aboutToAppear 创建，销毁时 finish） */
  private sweepAnim: AnimatorResult | null = null;
  /** 呼吸光晕 animator（aboutToAppear 创建，销毁时 finish） */
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

  /** 流光扫动动画参数：end = 全轨 + 带宽（扫出右边界再回卷，循环无缝） */
  private sweepOptions(): AnimatorOptions {
    return {
      duration: SHIMMER_SWEEP_MS,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: -1,
      begin: 0,
      end: this.trackWidth + SHIMMER_BAND_VP
    };
  }

  /** 呼吸光晕动画参数 */
  private breatheOptions(): AnimatorOptions {
    return {
      duration: SHIMMER_BREATHE_MS,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: -1,
      begin: 0,
      end: SHIMMER_BREATHE_MS
    };
  }

  aboutToAppear(): void {
    // UIContext 在属性初始化时未就绪，animator 延迟到这里创建（同 CoverDisc）
    try {
      this.sweepAnim = this.getUIContext().createAnimator(this.sweepOptions());
      this.sweepAnim.onFrame = (v: number): void => {
        this.shimmerX = v;
      };
      this.breatheAnim = this.getUIContext().createAnimator(this.breatheOptions());
      this.breatheAnim.onFrame = (v: number): void => {
        // 0.4 ± 0.2 正弦呼吸：onFrame 的 v 即相位毫秒
        this.glowOpacity = 0.4 + 0.2 * Math.sin(v / SHIMMER_BREATHE_MS * Math.PI * 2);
      };
      // 挂载时可能已在播放中（@Watch 不会触发，需手动起转）
      if (this.isPlay) {
        this.sweepAnim.play();
        this.breatheAnim.play();
      }
    } catch (e) {
      // animator 创建失败只影响流光/呼吸，进度展示与拖拽不受影响
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[ShimmerBar] createAnimator failed: ${msg}`);
    }
  }

  aboutToDisappear(): void {
    if (this.sweepAnim !== null) {
      this.sweepAnim.finish();
      this.sweepAnim = null;
    }
    if (this.breatheAnim !== null) {
      this.breatheAnim.finish();
      this.breatheAnim = null;
    }
  }

  /** 播放态变化：流光续扫/冻结、呼吸续动/回静态值 */
  onPlayingChanged(_propName: string): void {
    const sweep: AnimatorResult | null = this.sweepAnim;
    const breathe: AnimatorResult | null = this.breatheAnim;
    if (this.isPlay) {
      if (sweep !== null) {
        sweep.play();
      }
      if (breathe !== null) {
        breathe.play();
      }
    } else {
      if (sweep !== null) {
        sweep.pause();
      }
      if (breathe !== null) {
        breathe.pause();
      }
      this.glowOpacity = 0.4;
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

  /** 已播段宽度（百分比字符串）：拖拽/插值每帧重算 */
  private filledWidthStr(): string {
    return `${(this.pct() * 100).toFixed(2)}%`;
  }

  /** 滑块中心 x（vp）：钳制在轨道内，未测宽时贴左 */
  private headX(): number {
    return Math.min(this.trackWidth, this.trackWidth * this.pct());
  }

  /** 触摸横坐标 → 秒（钳制 0~max） */
  private secAt(x: number): number {
    if (this.trackWidth <= 0) {
      return 0;
    }
    const ratio: number = Math.min(1, Math.max(0, x / this.trackWidth));
    return ratio * this.max;
  }

  /** 光晕颜色：主题色 + 当前透明度（0~1 → 两位 hex） */
  private glowColor(): string {
    const aNum: number = Math.round(Math.min(1, Math.max(0, this.glowOpacity)) * 255);
    const a: string = aNum < 16 ? `0${aNum.toString(16)}` : aNum.toString(16);
    const base: string = this.themePrimary;
    if (base.length === 7) {
      return `#${a}${base.substring(1)}`.toUpperCase();
    }
    return base;
  }

  build() {
    Stack() {
      // 未播段底轨
      Row() {}
        .width(StyleConstants.FULL_WIDTH)
        .height(this.trackThickness)
        .borderRadius(this.trackThickness / 2)
        .backgroundColor($r('app.color.slider_track'))

      // 已播段（clip 裁切）：主题色→白渐变底 + 流光带。
      // ⚠️ 百分比宽的已播段必须包在全宽 Row 里：外层 Stack 默认
      // alignContent Center 会把它水平居中 → 进度看起来「从中间向两侧推进」；
      // 全宽 Row 主轴从起点排布，内层百分比 Stack 才能从左向右生长。
      Row() {
        Stack() {
          Row() {}
            .width(StyleConstants.FULL_WIDTH)
            .height(this.trackThickness)
            .linearGradient({
              angle: 90,
              colors: [
                [this.themePrimary, 0.0],
                ['#FFFFFFFF', 1.0]
              ]
            })
          // 流光带：透明→白→透明，position 只走合成器
          Row() {}
            .width(SHIMMER_BAND_VP)
            .height(this.trackThickness)
            .linearGradient({
              angle: 90,
              colors: [
                ['#00FFFFFF', 0.0],
                ['#8CFFFFFF', 0.5],
                ['#00FFFFFF', 1.0]
              ]
            })
            .position({ x: this.shimmerX, y: 0 })
            .opacity(this.isPlay && !this.dragging ? 1 : 0)
            .animation({ duration: 200, curve: Curve.EaseOut })
        }
        .width(this.filledWidthStr())
        .height(this.trackThickness)
        .borderRadius(this.trackThickness / 2)
        .clip(true)
      }
      .width(StyleConstants.FULL_WIDTH)
      .height(this.trackThickness)

      // 滑块：主题色圆点 + 呼吸光晕（Column+borderRadius 画圆，不用 Circle.fill ——
      // fill 是 SDK 26 API，兼容 SDK 23 上无效）
      Column() {}
        .width(SHIMMER_THUMB_VP)
        .height(SHIMMER_THUMB_VP)
        .borderRadius(SHIMMER_THUMB_VP / 2)
        .backgroundColor(this.themePrimary)
        .shadow({ radius: 10, color: this.glowColor() })
        .position({
          x: this.headX() - SHIMMER_THUMB_VP / 2,
          y: (SHIMMER_HIT_VP - SHIMMER_THUMB_VP) / 2
        })
        .scale({ x: this.thumbScale, y: this.thumbScale })
    }
    .width(StyleConstants.FULL_WIDTH)
    .height(SHIMMER_HIT_VP)
    .onAreaChange((_old: Area, n: Area): void => {
      const w: number = this.toVp(n.width);
      if (w <= 0 || Math.abs(w - this.trackWidth) < 0.5) {
        return;
      }
      this.trackWidth = w;
      // 扫动范围随轨宽重建（断点/旋转轨宽变化）；CoverDisc 同款 reset 范式
      const sweep: AnimatorResult | null = this.sweepAnim;
      if (sweep !== null) {
        try {
          sweep.reset(this.sweepOptions());
        } catch (e) {
          const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
          console.error(`[ShimmerBar] animator reset failed: ${msg}`);
          return;
        }
        if (this.isPlay) {
          sweep.play();
        }
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
        this.getUIContext().animateTo({ duration: SHIMMER_THICKEN_MS, curve: Curve.EaseOut }, (): void => {
          this.trackThickness = SHIMMER_TRACK_THICK_DRAG;
          this.thumbScale = 1.3;
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
        this.getUIContext().animateTo({ duration: SHIMMER_THICKEN_MS, curve: Curve.EaseOut }, (): void => {
          this.trackThickness = SHIMMER_TRACK_THICK;
          this.thumbScale = 1;
        });
        this.onSeekEnd(sec);
      }
    })
  }
}
