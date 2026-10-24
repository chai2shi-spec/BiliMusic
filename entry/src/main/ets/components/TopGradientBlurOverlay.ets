/**
 * 自绘顶栏渐变模糊层（任务③「松手抛行阶段顶栏渐变模糊消失」新方案，2026-10-24）。
 *
 * 背景（MaterialTokens / HdsTitleBarStyle 简史 ⑧⑨）：渐变类滚动效果
 * （GRADIENT_BLUR / IMMERSIVE_GRADIENT_BLUR）在 ScrollState.Fling 阶段被
 * 渲染管线丢弃渐变 pass；COMMON_BLUR 均匀模糊抛行不丢，但无渐变软边，
 * 用户否决其观感（硬边不符「沉浸光感」）。
 *
 * 本层用「均匀模糊 + 渐变 alpha 打孔」伪造渐变软边：
 * - 外层 Column：backgroundEffect 均匀高斯模糊（radius=TITLE_BLUR_RADIUS_VP，
 *   与 COMMON_BLUR 同通路，抛行期存活——COMMON_BLUR 真机实证支持）；
 * - 内层 Column：linearGradient 渐变 + blendMode(DST_IN)，在外层离屏合成
 *   （blendMode(SRC_OVER, OFFSCREEN)）缓冲内对外层模糊结果逐像素打孔 ——
 *   栏区不透明、尾部 32vp（TITLE_MASK_EXTRA_VP）渐隐到透明，得到渐变软边；
 * - 进度（0→1 随滚动 0→TITLE_BLUR_END_VP）由 TopBlurProgressUpdater 经
 *   attributeModifier 命令式写 opacity：不标 @State、不触发 build，滚动
 *   高频回调零重建（用户方案 ①②：禁 @State 驱动模糊）；
 * - 页面驱动方负责：onDidScroll 逐帧更新 + onScrollStop Idle 校准终态 +
 *   yOffset ≤ 0 死区归零（用户方案 ②③，见 SearchPage.syncTopBlurProgress）。
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
 * 整层不透明上限（⑦ 2026-10-24 用户观感反馈「overlay 可以更透明一些」）：
 * progress 满档 1 时整层合成结果按此系数与下层内容混合（0.9 = 模糊浓度降
 * 一成，0.8 档实测后回调）。尾带渐隐曲线（⑤ 三次缓出）不动；只调满档浓度，
 * 页面侧零改动。
 */
const TITLE_MAX_OVERLAY_OPACITY: number = 0.9;

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
   * 写入进度：越界截断到 0~1（边缘回弹负偏移归零 = 用户方案 ③ 死区）；
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
 * barHeightVp + TITLE_MASK_EXTRA_VP（尾部渐隐区）。
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

  /** 本层总高（vp）：整栏高 + 尾部渐隐区 */
  private totalHeightVp(): number {
    return this.barHeightVp + MaterialTokens.TITLE_MASK_EXTRA_VP;
  }

  /**
   * 渐变打孔色标（颜色任意，DST_IN 只用 alpha）：栏区不透明，尾部渐隐。
   * 尾部曲线（2026-10-24 用户验收①~⑥）：①~③「更浅」×3；④ 栏底陡降版
   *（避开搜索框 / 两个滑块，但 100→25% 陡降在栏底形成可见台阶）——
   * 用户实测后要求恢复上一版；⑤ 恢复 **85% 栏高渐隐起点 + 三次缓出
   * (1-t)³**（t=0.25→0x6B、t=0.5→0x20、t=0.75→0x04）；⑥（状态栏封盖 +
   * 行区透明版）真机实测封盖与栏下软边不可见，整体回退到⑤，根因未查
   *（overlay 渐变 / 材质板移除 / HDS 默认背板三者谁吞了封盖待查）。
   * ⑦ 2026-10-24 用户反馈「整体更透明」→ 满档 opacity 经
   * TITLE_MAX_OVERLAY_OPACITY 收到 0.9（0.8 实测后回调一档；曲线不动，只降浓度）。
   */
  private gradientStops(): Array<[ResourceColor, number]> {
    const barRatio: number = this.barHeightVp / this.totalHeightVp();
    // 渐隐起点：栏高 85%（再往上收要连 tabs 行背板一起评估可读性）
    const fadeStart: number = barRatio * 0.85;
    const span: number = 1 - fadeStart;
    const stops: Array<[ResourceColor, number]> = [
      ['#FF000000', 0.0],
      ['#FF000000', fadeStart],
      ['#6B000000', fadeStart + 0.25 * span],
      ['#20000000', fadeStart + 0.5 * span],
      ['#04000000', fadeStart + 0.75 * span],
      ['#00000000', 1.0]
    ];
    return stops;
  }
}
