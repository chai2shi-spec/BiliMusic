/**
 * 迷你栏进度指示（独立子组件，PlayBar 拆分）：
 *   · PlayBarRingProgress —— 水平融合收起态的圆环进度（叠在恒驻唱片边缘）；
 *   · PlayBarLineProgress —— 整行内容底边的 2vp 直线进度。
 *
 * 独立成组件的原因（PlayerProgressArea 同款纪律）：STORE_PROGRESS 播放中
 * 每 500ms 推送一次，若订阅挂在 PlayBar 根部，整条迷你栏（唱片 / 文字 /
 * 控制键）都会 2Hz 重渲染。进度订阅圈死在本文件两个小子组件内：
 *   · 500ms 快照驱动的重渲染被圈死在进度节点自身；
 *   · PlayBar 主体播放期间零重渲染。
 *
 * 挂载 / 卸载与交叉淡入淡出仍由 PlayBar 侧的 if 条件（ringVisible /
 * bodyVisible + miniBarProgress 开关）+ 本组件根节点 OPACITY transition
 * 承担（CONTENT_FADE_MS，与 Body 淡入淡出共用同一时长）。
 */

import {
  STORE_PROGRESS,
  STORE_DURATION,
  STORE_THEME_PRIMARY
} from '../common/Constants';
import { MaterialCompat } from '../utils/MaterialCompat';

/** 收起态圆环进度描边宽（vp）：同尺寸叠在圆盘边缘、盖在封面上 */
const RING_STROKE_VP: number = 2.5;
/** 整行内容底边直线进度条厚度（vp） */
const LINE_HEIGHT_VP: number = 2;
/** 直线进度底轨的主题色透明度（淡显，不与文字抢焦点） */
const LINE_TRACK_ALPHA: number = 0.18;
/** 直线进度左右内缩（vp）：避开胶囊圆角（只铺播放栏槽位，HDS 会裁槽位外内容） */
const LINE_INSET_VP: number = 8;
/**
 * 内容体（Body）/ 直线进度 与 圆环进度 交叉淡入淡出的时长（ms）。
 * 刻意略长于 HDS 槽位形变（内建约 250~300ms，不可配）—— 收放结束后留一点
 * 柔和余韵；观感拖沓只调这一处。PlayBar 的 Body 出入场 transition 共用本值。
 */
export const CONTENT_FADE_MS: number = 400;

/**
 * 收起态圆环进度：与圆盘同尺寸的兄弟节点 → 描边画在组件边界内侧、贴圆盘
 * 边缘，不触发 enableMiniBarClip 裁剪；不参与 geometryTransition（转场时环
 * 留在槽位内，无跳变）。挂载条件（ringVisible + miniBarProgress）在 PlayBar
 * 侧；本组件只管 duration<=0（加载中 / 未解析）不渲染，切歌瞬间随清零短暂
 * 隐藏属预期。底轨透明：封面不被灰圈压住，只显示主题色弧线。
 */
@Component
export struct PlayBarRingProgress {
  /** 播放进度（秒，500ms 分桶推送）：只读订阅，播放内核 MusicPlayer 唯一写入 */
  @StorageProp(STORE_PROGRESS) progressSec: number = 0;
  /** 曲目总时长（秒）：<=0（加载中 / 未解析）时不渲染 */
  @StorageProp(STORE_DURATION) durationSec: number = 0;
  /** 主题色主色（hex 字符串，ThemeColors 发布）：进度弧线用色，切主题即时跟随 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 圆盘边长（vp）= 环外径（PlayBar 的 discSizeVp 运行时值传入） */
  @Prop sizeVp: number = 40;

  build() {
    if (this.durationSec > 0) {
      Progress({ value: Math.min(this.progressSec, this.durationSec), total: this.durationSec, type: ProgressType.Ring })
        .width(this.sizeVp)
        .height(this.sizeVp)
        .style({ strokeWidth: RING_STROKE_VP })
        .color(this.themePrimary)
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.animation({ duration: CONTENT_FADE_MS, curve: Curve.EaseInOut }))
    }
  }
}

/**
 * 整行底边直线进度：贴槽位底边（= 胶囊底边的播放栏段），随 bodyVisible
 * 淡入淡出。只铺播放栏槽位 —— HDS enableMiniBarClip 把 miniBar 内容裁在
 * 槽位内，延伸不到右侧页签段。底轨 = 淡主题色，进度 = 实主题色，左右内缩
 * 避开胶囊圆角；hitTest 透传：2vp 细条不截胡整行的「点击进播放页」。
 * 挂载条件（bodyVisible + miniBarProgress）在 PlayBar 侧；本组件只管
 * duration<=0（加载中 / 未解析）不渲染。
 */
@Component
export struct PlayBarLineProgress {
  /** 播放进度（秒，500ms 分桶推送）：只读订阅，播放内核 MusicPlayer 唯一写入 */
  @StorageProp(STORE_PROGRESS) progressSec: number = 0;
  /** 曲目总时长（秒）：<=0（加载中 / 未解析）时不渲染 */
  @StorageProp(STORE_DURATION) durationSec: number = 0;
  /** 主题色主色（hex 字符串，ThemeColors 发布）：进度与底轨用色，切主题即时跟随 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  /** 播放进度比例（0~1，钳制）：duration<=0 返回 0（该情形下进度条不渲染） */
  private progressPct(): number {
    if (this.durationSec <= 0) {
      return 0;
    }
    return Math.min(1, Math.max(0, this.progressSec / this.durationSec));
  }

  build() {
    if (this.durationSec > 0) {
      Row() {
        Row()
          .width(`${(this.progressPct() * 100).toFixed(1)}%`)
          .height('100%')
          .backgroundColor(this.themePrimary)
      }
      .width('100%')
      .height(LINE_HEIGHT_VP)
      .padding({ left: LINE_INSET_VP, right: LINE_INSET_VP })
      .backgroundColor(MaterialCompat.withAlpha(this.themePrimary, LINE_TRACK_ALPHA))
      .hitTestBehavior(HitTestMode.Transparent)
      .transition(TransitionEffect.OPACITY.animation({ duration: CONTENT_FADE_MS, curve: Curve.EaseInOut }))
    }
  }
}
