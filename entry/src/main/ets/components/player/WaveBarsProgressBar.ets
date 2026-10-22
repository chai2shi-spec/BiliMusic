/**
 * 播放页进度条样式 D ——「律动频谱条」（ControlAreaComponent 四分支之一）。
 *
 * 视觉：N 根 3vp 宽圆头竖条（8~14vp 伪随机高度）—— 已播主题色 / 未播半透明白；
 * 高度由曲目 id 播种：同曲稳定、切歌「换一首波形」，像真频谱的指纹。
 *
 * 动效（createAnimator 无限循环 + 一次 animateTo，与 CoverDiscComponent 同底座）：
 *   · 头部律动 —— 0.7s/周期，进度头 ±2 根竖条 scaleY 1→1.12 邻近衰减波动
 *     （只动 transform，不逐帧改 height，零重排）；
 *   · 拖拽增亮 —— 拖拽中未播条提亮（#33 → #66 白），经过处随进度点亮；
 *   · 落位亮波 —— 松手 seek 后一次性 350ms 头部 ±4 根竖条 scaleY 波峰回落。
 * 播放态 play/pause（@Watch STORE_IS_PLAYING）；aboutToDisappear 统一 finish。
 *
 * 交互契约与其余三档一致：拖动本地跟随、松手才 seek、点按定位 —— 触摸
 * 事件只换算上报，交互状态（dragging/dragValue/插值）全部由父组件持有。
 */

import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { Track } from '../../model/MusicModels';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { STORE_CURRENT_TRACK, STORE_IS_PLAYING, STORE_THEME_PRIMARY } from '../../common/Constants';

/** 命中区高度（vp） */
const WAVE_HIT_VP: number = 32;
/** 单根竖条宽度（vp） */
const WAVE_BAR_VP: number = 3;
/** 竖条间距（vp） */
const WAVE_GAP_VP: number = 2;
/** 竖条最低高度（vp） */
const WAVE_BAR_MIN_VP: number = 8;
/** 竖条最高高度（vp） */
const WAVE_BAR_MAX_VP: number = 14;
/** 头部律动周期（ms） */
const WAVE_HEAD_MS: number = 700;
/** 律动邻近影响半径（根）：±2 三档线性衰减 */
const WAVE_HEAD_RADIUS: number = 2;
/** 律动最大 scaleY 增幅 */
const WAVE_HEAD_AMP: number = 0.12;
/** 落位亮波影响半径（根） */
const WAVE_FLASH_RADIUS: number = 4;
/** 落位亮波时长（ms） */
const WAVE_FLASH_MS: number = 350;
/** 落位亮波最大 scaleY 增幅 */
const WAVE_FLASH_AMP: number = 0.3;

@Component
export struct WaveBarsProgressBar {
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

  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  @StorageLink(STORE_IS_PLAYING) @Watch('onPlayingChanged') isPlay: boolean = false;
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  /** 实测轨道宽度（vp）：竖条数量与手势换算的数据源 */
  @State trackWidth: number = 0;
  /** 组件内拖拽态：只驱动视觉反馈（未播条提亮），交互真值在父组件 */
  @State dragging: boolean = false;
  /** 各竖条高度（vp）：轨宽 / 曲目变化时一次性重算，不逐帧动 */
  @State barHeights: number[] = [];
  /** 头部律动相位（0~1）：headAnim 每帧回写 */
  @State headT: number = 0;
  /** 落位亮波进度（0 起波 → 1 平息） */
  @State flashPhase: number = 1;

  /** 头部律动 animator（aboutToAppear 创建，销毁时 finish） */
  private headAnim: AnimatorResult | null = null;

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

  private headOptions(): AnimatorOptions {
    return {
      duration: WAVE_HEAD_MS,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: -1,
      begin: 0,
      end: WAVE_HEAD_MS
    };
  }

  aboutToAppear(): void {
    // UIContext 在属性初始化时未就绪，animator 延迟到这里创建（同 CoverDisc）
    try {
      this.headAnim = this.getUIContext().createAnimator(this.headOptions());
      this.headAnim.onFrame = (v: number): void => {
        this.headT = v / WAVE_HEAD_MS;
      };
      // 挂载时可能已在播放中（@Watch 不会触发，需手动起动）
      if (this.isPlay) {
        this.headAnim.play();
      }
    } catch (e) {
      // animator 创建失败只影响律动，进度展示与拖拽不受影响
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[WaveBars] createAnimator failed: ${msg}`);
    }
  }

  aboutToDisappear(): void {
    if (this.headAnim !== null) {
      this.headAnim.finish();
      this.headAnim = null;
    }
  }

  /** 播放态变化：律动续动/冻结 */
  onPlayingChanged(_propName: string): void {
    const anim: AnimatorResult | null = this.headAnim;
    if (anim !== null) {
      if (this.isPlay) {
        anim.play();
      } else {
        anim.pause();
      }
    }
  }

  /** 切歌 → 伪随机高度集整体换样（同轨宽下数量不变，只换高度） */
  onTrackChanged(_propName: string): void {
    this.recomputeHeights();
  }

  /** 进度比例（0~1）：时长未知时恒 0（全部按未播色） */
  private pct(): number {
    if (this.max <= 0) {
      return 0;
    }
    const p: number = this.value / this.max;
    return Math.min(1, Math.max(0, p));
  }

  /** 竖条高度集：N = floor((轨宽+间距)/(条宽+间距))；曲目 id 播种伪随机 */
  private recomputeHeights(): void {
    if (this.trackWidth <= 0) {
      return;
    }
    const n: number = Math.max(1, Math.floor((this.trackWidth + WAVE_GAP_VP) / (WAVE_BAR_VP + WAVE_GAP_VP)));
    const seed: string = this.currentTrack !== null ? this.currentTrack.id : 'waveDefault';
    const heights: number[] = [];
    for (let i: number = 0; i < n; i++) {
      heights.push(this.barHeightAt(seed, i));
    }
    this.barHeights = heights;
  }

  /**
   * FNV-1a 字符哈希 + 索引扰动 → [MIN, MAX] 高度：
   * Math.imul 保证 32 位乘法不丢精度；同 (曲, 索引) 恒定，换曲换样。
   */
  private barHeightAt(seed: string, i: number): number {
    let h: number = 2166136261;
    for (let k: number = 0; k < seed.length; k++) {
      h = (h ^ seed.charCodeAt(k)) >>> 0;
      h = Math.imul(h, 16777619) >>> 0;
    }
    h = (h + Math.imul(i, 2654435761)) >>> 0;
    return WAVE_BAR_MIN_VP + (h % (WAVE_BAR_MAX_VP - WAVE_BAR_MIN_VP + 1));
  }

  /** 竖条根数（高度集就绪前为 1，避免除零） */
  private barCount(): number {
    return Math.max(1, this.barHeights.length);
  }

  /** 进度头所在竖条索引（钳制在有效区间） */
  private headIdx(): number {
    const n: number = this.barCount();
    return Math.min(n - 1, Math.floor(this.pct() * n));
  }

  /** 邻近衰减系数：|i - head| ≤ radius 内线性衰减，超出为 0 */
  private proximity(i: number, radius: number): number {
    const d: number = Math.abs(i - this.headIdx());
    if (d > radius) {
      return 0;
    }
    return 1 - d / (radius + 1);
  }

  /** 竖条颜色：已播主题色 / 未播半透明白（拖拽中提亮一档，整排增亮反馈） */
  private barColor(i: number): ResourceColor {
    if ((i + 1) / this.barCount() <= this.pct()) {
      return this.themePrimary;
    }
    return this.dragging ? '#66FFFFFF' : $r('app.color.slider_track');
  }

  /** 竖条合成 scaleY：头部律动（播放中）+ 落位亮波（一次性）——只动 transform 零重排 */
  private barScaleY(i: number): number {
    let s: number = 1;
    if (this.isPlay) {
      s += WAVE_HEAD_AMP * Math.max(0, Math.sin(this.headT * Math.PI * 2)) * this.proximity(i, WAVE_HEAD_RADIUS);
    }
    s += WAVE_FLASH_AMP * (1 - this.flashPhase) * this.proximity(i, WAVE_FLASH_RADIUS);
    return s;
  }

  /** 触摸横坐标 → 秒（钳制 0~max） */
  private secAt(x: number): number {
    if (this.trackWidth <= 0) {
      return 0;
    }
    const ratio: number = Math.min(1, Math.max(0, x / this.trackWidth));
    return ratio * this.max;
  }

  /** 松手落位亮波：0 起波 → 1 平息（完成后恢复常态） */
  private playFlash(): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.flashPhase = 0;
    });
    this.getUIContext().animateTo({ duration: WAVE_FLASH_MS, curve: Curve.EaseOut }, (): void => {
      this.flashPhase = 1;
    });
  }

  build() {
    Row({ space: WAVE_GAP_VP }) {
      ForEach(this.barHeights, (h: number, i: number) => {
        Column() {}
          .width(WAVE_BAR_VP)
          .height(h)
          .borderRadius(WAVE_BAR_VP / 2)
          .backgroundColor(this.barColor(i))
          .scale({ x: 1, y: this.barScaleY(i) })
      }, (h: number, i: number) => `${i}_${h}`)
    }
    .width(StyleConstants.FULL_WIDTH)
    .height(WAVE_HIT_VP)
    .alignItems(VerticalAlign.Center)
    .onAreaChange((_old: Area, n: Area): void => {
      const w: number = this.toVp(n.width);
      if (w <= 0 || Math.abs(w - this.trackWidth) < 0.5) {
        return;
      }
      this.trackWidth = w;
      // 数量随轨宽变化（断点/旋转），高度集整体重算
      this.recomputeHeights();
    })
    .onTouch((event: TouchEvent): void => {
      // 时长未知/未测宽时手势无效（与其余档位 max<=0 的守卫一致）
      if (this.max <= 0 || this.trackWidth <= 0) {
        return;
      }
      const sec: number = this.secAt(event.touches[0].x);
      if (event.type === TouchType.Down) {
        this.dragging = true;
        this.onSeekStart();
        this.onSeekMove(sec);
      } else if (event.type === TouchType.Move) {
        this.onSeekMove(sec);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        if (!this.dragging) {
          return;
        }
        this.dragging = false;
        this.playFlash();
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
