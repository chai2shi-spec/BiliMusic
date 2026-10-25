/**
 * 自绘顶栏渐变模糊层。
 *
 * 背景：渐变类滚动效果（GRADIENT_BLUR / IMMERSIVE_GRADIENT_BLUR）在
 * ScrollState.Fling 阶段被渲染管线丢弃渐变 pass；COMMON_BLUR 均匀模糊抛行
 * 不丢，但无渐变软边（硬边不符「沉浸光感」）。
 *
 * 本层用「均匀模糊 + 渐变 alpha 打孔」伪造渐变软边：
 * - 外层 Column：backgroundEffect 均匀高斯模糊（radius=TITLE_BLUR_RADIUS_VP，
 *   与 COMMON_BLUR 同通路，抛行期存活——COMMON_BLUR 真机实证支持）；
 * - 内层 Column：linearGradient 渐变 + blendMode(DST_IN)，在外层离屏合成
 *   （blendMode(SRC_OVER, OFFSCREEN)）缓冲内对外层模糊结果逐像素打孔 ——
 *   栏区不透明、尾部 24vp（TITLE_FADE_TAIL_VP）渐隐到透明，得到渐变软边；
 * - 进度（0→1 随滚动 0→TITLE_BLUR_END_VP）由 TopBlurProgressUpdater 经
 *   attributeModifier 命令式写 opacity：不标 @State、不触发 build，滚动
 *   高频回调零重建（禁 @State 驱动模糊）；
 * - 页面驱动方负责：onDidScroll 逐帧更新 + onScrollStop Idle 校准终态 +
 *   yOffset ≤ 0 死区归零（见 SearchPage.syncTopBlurProgress）。
 *
 * 挂载位置：页面根 Stack 内、主内容列之上、面板/弹窗之下；z 序在 HDS
 * titleBar 之下（页面层 < 标题栏），栏区文字不被本层遮挡。
 * hitTestBehavior(None)：不挡下层列表触摸。
 * ⚠️ 待真机验证项：offscreen 离屏合成下 backgroundEffect 的 backdrop 采样
 * 是否正常；本层抛行期是否真存活（COMMON_BLUR 证据支持但未直测）。
 */
import { AttributeUpdater } from '@ohos.arkui.modifier';
import { MaterialTokens } from '../common/style/MaterialTokens';

/**
 * 整层不透明上限：progress 满档 1 时整层合成结果按此系数与下层内容混合
 * （0.9 = 模糊浓度降一成）。只调满档浓度，页面侧零改动。
 */
const TITLE_MAX_OVERLAY_OPACITY: number = 0.9;

/**
 * 尾部渐隐区长度（vp）。
 * 与 MaterialTokens.TITLE_MASK_EXTRA_VP（32，HDS 官方 maskExtraHeight 语义）
 * **解耦**：该令牌在 COMMON_BLUR 下是死参数，尾带实际只由本层消费；调令牌
 * 会误伤 HDS 语义，故立本地常量。
 */
const TITLE_FADE_TAIL_VP: number = 24;

/**
 * 渐变模糊层进度更新器：命令式写 opacity（0~1）。
 * 未挂载（attribute 为 undefined）时只存进度值，挂载时 initializeModifier
 * 会把存的值补上 —— 页面 aboutToAppear 早于挂载同步初值不丢。
 */
export class TopBlurProgressUpdater extends AttributeUpdater<ColumnAttribute> {
  private progress: number = 0;

  initializeModifier(instance: ColumnAttribute): void {
    instance.opacity(this.progress * TITLE_MAX_OVERLAY_OPACITY);
  }

  /**
   * 写入进度：越界截断到 0~1（边缘回弹负偏移归零死区）；
   * |Δ|<0.01 抖动过滤。this.attribute?.opacity() 不标状态变量，不触发 build。
   */
  setProgress(p: number): void {
    const c: number = p < 0 ? 0 : (p > 1 ? 1 : p);
    if (Math.abs(c - this.progress) < 0.01) {
      return;
    }
    this.progress = c;
    this.attribute?.opacity(c * TITLE_MAX_OVERLAY_OPACITY);
  }
}

/**
 * 顶栏渐变模糊层组件（原型先行 SearchPage，验收后推广其余页签）。
 * barHeightVp 传根栏整栏高（状态栏 + 标题行 + 页签行）；本层高度 =
 * barHeightVp + TITLE_FADE_TAIL_VP（尾部渐隐区）。
 */
@Component
export struct TopGradientBlurOverlay {
  /** 根栏整栏高（vp）：栏区不透明模糊、栏底起渐隐到透明 */
  @Prop barHeightVp: number = 0;
  /** 命令式进度更新器（页面持有并经滚动回调驱动） */
  updater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  build() {
    Column() {
      // DST_IN 渐变打孔层：只取渐变 alpha（颜色被 DST_IN 丢弃），栏区 alpha=1、
      // 尾部渐隐到 0 —— 对外层模糊结果逐像素遮罩出渐变软边。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 180, colors: this.gradientStops() })
        .blendMode(BlendMode.DST_IN)
    }
    .width('100%')
    .height(this.totalHeightVp())
    // 根 Stack 默认居中对齐，必须显式钉回顶部（历史面板遮罩同款 position 定位）。
    .position({ x: 0, y: 0 })
    .backgroundEffect({
      radius: MaterialTokens.TITLE_BLUR_RADIUS_VP,
      saturation: 1.3,
      brightness: 1.0,
      color: $r('app.color.header_glass_tint')
    })
    // 离屏合成：本组件与子节点先合成进离屏缓冲（DST_IN 在缓冲内打孔模糊
    // 结果），再以 SRC_OVER 落回页面 —— .mask() 不支持线性渐变 alpha 遮罩，
    // 只能走 blendMode 打孔。
    .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
    .attributeModifier(this.updater)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 本层总高（vp）：整栏高 + 尾部渐隐区（本地常量，与 HDS 令牌解耦） */
  private totalHeightVp(): number {
    return this.barHeightVp + TITLE_FADE_TAIL_VP;
  }

  /**
   * 渐变打孔色标（颜色任意，DST_IN 只用 alpha）：栏区不透明，尾部渐隐。
   * 尾部曲线用**半余弦 0.5×(1+cos(πt))** 八段色标近似（每 0.125 span 一档）：
   * 两端零斜率，渐隐起点缓降、不形成可见陡边（三次缓出 (1-t)³ 在 t=0.25 处
   * alpha 已跌到 42%，是栏下可见陡边主因；半余弦同处 85%）。
   * 渐隐起点取 85% 栏高（再往上收要连 tabs 行背板一起评估可读性）。
   */
  private gradientStops(): Array<[ResourceColor, number]> {
    const barRatio: number = this.barHeightVp / this.totalHeightVp();
    // 渐隐起点：栏高 85%（再往上收要连 tabs 行背板一起评估可读性）
    const fadeStart: number = barRatio * 0.85;
    const span: number = 1 - fadeStart;
    // 半余弦 0.5×(1+cos(πt)) 八段近似（每 0.125 span 一档，段内线性插值）：
    // t=0.125→0x F5、0.25→DA、0.375→B0、0.5→80、0.625→4F、0.75→25、0.875→0A。
    const stops: Array<[ResourceColor, number]> = [
      ['#FF000000', 0.0],
      ['#FF000000', fadeStart],
      ['#F5000000', fadeStart + 0.125 * span],
      ['#DA000000', fadeStart + 0.25 * span],
      ['#B0000000', fadeStart + 0.375 * span],
      ['#80000000', fadeStart + 0.5 * span],
      ['#4F000000', fadeStart + 0.625 * span],
      ['#25000000', fadeStart + 0.75 * span],
      ['#0A000000', fadeStart + 0.875 * span],
      ['#00000000', 1.0]
    ];
    return stops;
  }
}
