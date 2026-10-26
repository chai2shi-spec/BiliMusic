/**
 * 播放页进度条样式 B ——「流光渐变条」（ControlAreaComponent 四分支之一）。
 *
 * 视觉：4vp 胶囊轨道（未播段半透明白 / 已播段主题色→白渐变）+ 12vp 主题色圆点
 * 滑块 + 呼吸光晕；流光带在已播段内循环扫动（clip 裁切，只照亮已播区）。
 *
 * 动效（全部为无限属性动画，插值由渲染管线按 DECORATIVE_ANIM_FRAME_RATE
 * （LTPO 30fps）驱动，JS 侧零逐帧回调、零逐帧重渲染）：
 *   · 流光扫动 —— animateTo(iterations:-1) 驱动流光带 translate
 *     （-带宽 → 轨宽+带宽，无限循环），只动合成器属性；
 *   · 呼吸光晕 —— 滑块后方光晕节点 opacity 0.35↔0.95 无限往返
 *     （Alternate，半周期 1s 正弦近似），滑块本体投影固定 0.4 透明度主题色；
 *   · 拖拽增厚 —— 按下轨道 4→8vp + 滑块放大 1.3，松手回弹（animateTo）。
 * 播放态 play/pause（@Watch STORE_IS_PLAYING）：暂停取消无限动画回静态；
 * 属性动画随节点销毁，aboutToDisappear 无需清理。
 *
 * 性能：流光只动 translate、光晕只动 opacity（合成器属性）；厚度/缩放只在
 * 拖拽起止各动一次。
 * 交互契约与其余三档一致：拖动本地跟随、松手才 seek、点按定位 —— 触摸
 * 事件只换算上报，交互状态（dragging/dragValue/插值）全部由父组件持有。
 */

import { StyleConstants } from '../../common/constants/StyleConstants';
import { DECORATIVE_ANIM_FRAME_RATE } from '../../common/constants/InteractionConstants';
import { STORE_IS_PLAYING, STORE_THEME_PRIMARY } from '../../common/Constants';
import { ProgressMath } from './ProgressMath';

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
/** 呼吸光晕直径（vp）：滑块后方主题色径向渐变光斑 */
const SHIMMER_HALO_VP: number = 28;
/** 呼吸光晕透明度下限（Alternate 无限往返的起点/回静值） */
const SHIMMER_GLOW_MIN: number = 0.35;
/** 呼吸光晕透明度上限 */
const SHIMMER_GLOW_MAX: number = 0.95;
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

  /** 实测轨道宽度（vp）：手势换算和流光扫动范围的数据源 */
  @State trackWidth: number = 0;
  /** 组件内拖拽态：只驱动视觉反馈（增厚/藏流光），交互真值在父组件 */
  @State dragging: boolean = false;
  /** 轨道当前厚度（vp）：拖拽起止各 animateTo 一次 */
  @State trackThickness: number = SHIMMER_TRACK_THICK;
  /** 滑块拖拽放大系数 */
  @State thumbScale: number = 1;
  /** 流光带当前位移（vp）：播放中由无限属性动画驱动（-带宽 ↔ 轨宽+带宽） */
  @State bandX: number = -SHIMMER_BAND_VP;
  /** 光晕呼吸透明度：播放中 0.35↔0.95 无限往返（Alternate 属性动画） */
  @State glowBreath: number = SHIMMER_GLOW_MIN;

  /** Area 尺寸（Length）→ vp 数值；资源型（理论上不会出现）按 0 兜底 */
  private toVp(v: Length): number {
    return ProgressMath.toVp(v);
  }

  /** 起播：流光带从左界外线性扫到右界外，无限循环（LTPO 30fps，合成器插值） */
  private startSweep(): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.bandX = -SHIMMER_BAND_VP;
    });
    this.getUIContext().animateTo({
      duration: SHIMMER_SWEEP_MS,
      curve: Curve.Linear,
      iterations: -1,
      expectedFrameRateRange: DECORATIVE_ANIM_FRAME_RATE
    }, (): void => {
      this.bandX = this.trackWidth + SHIMMER_BAND_VP;
    });
  }

  /** 停扫：取消无限动画，流光带回卷左界外（暂停态带子已被门控隐藏） */
  private stopSweep(): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.bandX = -SHIMMER_BAND_VP;
    });
  }

  /** 起呼吸：光晕透明度下限→上限无限往返（半周期 1s，正弦近似） */
  private startBreathe(): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.glowBreath = SHIMMER_GLOW_MIN;
    });
    this.getUIContext().animateTo({
      duration: SHIMMER_BREATHE_MS / 2,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate,
      expectedFrameRateRange: DECORATIVE_ANIM_FRAME_RATE
    }, (): void => {
      this.glowBreath = SHIMMER_GLOW_MAX;
    });
  }

  /** 停呼吸：取消无限动画，透明度回静态下限（暂停态光晕被 isPlay 门控隐藏） */
  private stopBreathe(): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.glowBreath = SHIMMER_GLOW_MIN;
    });
  }

  aboutToAppear(): void {
    // 挂载时可能已在播放中（@Watch 不会触发，需手动起播）
    if (this.isPlay) {
      this.startSweep();
      this.startBreathe();
    }
  }

  /** 播放态变化：流光续扫/回卷、光晕续呼吸/回静态 */
  onPlayingChanged(_propName: string): void {
    if (this.isPlay) {
      this.startSweep();
      this.startBreathe();
    } else {
      this.stopSweep();
      this.stopBreathe();
    }
  }

  /** 进度比例（0~1）：时长未知时恒 0（不显示已播段） */
  private pct(): number {
    return ProgressMath.pct(this.value, this.max);
  }

  /** 已播段宽度（百分比字符串）：拖拽/插值每帧重算 */
  private filledWidthStr(): string {
    return ProgressMath.filledWidthStr(this.value, this.max);
  }

  /** 滑块中心 x（vp）：钳制在轨道内，未测宽时贴左 */
  private headX(): number {
    return ProgressMath.headX(this.trackWidth, this.value, this.max);
  }

  /** 触摸横坐标 → 秒（钳制 0~max） */
  private secAt(x: number): number {
    return ProgressMath.secAt(x, this.trackWidth, this.max);
  }

  /** 主题色加透明度前缀（#RRGGBB → #AARRGGBB）；非 7 位原样返回 */
  private alphaTheme(alphaHex: string): string {
    const base: string = this.themePrimary;
    if (base.length === 7) {
      return `#${alphaHex}${base.substring(1)}`.toUpperCase();
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
          // 流光带：透明→白→透明。门控（播放且非拖拽可见，200ms 淡入淡出）在
          // 外层包装节点，translate 无限动画在内层 —— 两类属性分属不同节点，
          // 门控翻转不打断扫动动画
          Column() {
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
              .translate({ x: this.bandX })
          }
          .position({ x: 0, y: 0 })
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

      // 呼吸光晕：滑块后方主题色径向渐变光斑，播放中透明度 0.35↔0.95
      // 无限往返呼吸；暂停态隐藏（滑块保留固定 0.4 透明度投影）
      Column() {}
        .width(SHIMMER_HALO_VP)
        .height(SHIMMER_HALO_VP)
        .borderRadius(SHIMMER_HALO_VP / 2)
        .radialGradient({
          center: [SHIMMER_HALO_VP / 2, SHIMMER_HALO_VP / 2],
          radius: SHIMMER_HALO_VP / 2,
          colors: [
            [this.alphaTheme('73'), 0.0],
            [this.alphaTheme('00'), 1.0]
          ]
        })
        .position({
          x: this.headX() - SHIMMER_HALO_VP / 2,
          y: (SHIMMER_HIT_VP - SHIMMER_HALO_VP) / 2
        })
        .opacity(this.isPlay ? this.glowBreath : 0)

      // 滑块：主题色圆点 + 固定光晕投影（Column+borderRadius 画圆，不用
      // Circle.fill —— fill 是 SDK 26 API，兼容 SDK 23 上无效）
      Column() {}
        .width(SHIMMER_THUMB_VP)
        .height(SHIMMER_THUMB_VP)
        .borderRadius(SHIMMER_THUMB_VP / 2)
        .backgroundColor(this.themePrimary)
        .shadow({ radius: 10, color: this.alphaTheme('66') })
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
      // 扫动范围随轨宽重建（断点/旋转轨宽变化）：重启无限扫动动画
      if (this.isPlay) {
        this.startSweep();
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
    // 消费型横向手势：onTouch 只观察不消费、
    // 不进手势仲裁 —— SM 形态下本组件在 PlayerInfoComponent 的 Swiper（封面页|
    // 歌词页）子树内，横向拖动会穿透到 Swiper 的**内置翻页 PanGesture**（swiper.d.ts
    // 明载 Swiper 翻页即内置 pan），整页跟着手指横移。此条 PanGesture 作为子节点
    // 自定义手势参与仲裁、深于 Swiper 必胜 → 翻页永不启动；onTouch 与手势仲裁
    // 互不影响，拖拽换算逻辑原样。方向锁 Horizontal：歌词页列表竖向滚动不受牵连。
    // 取舍：进度条 32vp 命中区内的横向手势归进度条所有，想翻页需从条外起手。
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 1 }))
  }
}
