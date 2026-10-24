/**
 * 播放页常量（移植自 audio-interaction-master）。
 */

export class PlayerConstants {
  static readonly FONT_WEIGHT_700: number = 700;
  static readonly FONT_WEIGHT_500: number = 500;

  static readonly FONT_FAMILY_BLACK: string = 'HarmonyHeiTi';
  static readonly FONT_FAMILY_BOLD: string = 'HarmonyHeiTi-Bold';
  static readonly FONT_FAMILY_MEDIUM: string = 'HarmonyHeiTi-Medium';

  /** 背景封面模糊半径（effectKit blur） */
  static readonly IMAGE_BLUR: number = 15;

  /**
   * 紧凑横屏分支直板机路径的窗口高度上限（vp，2026-10-24 播放页横屏方案）：
   * 直板机横屏（窗口内容高 ~391vp）经「横屏且窗口高低于此值」命中紧凑横屏
   * 布局；折叠屏展开横屏（Pura X 展开横屏 ~721vp 高，2026-10-24 推广）不走
   * 高度阈值，由 isFoldFull && isLandscape 直进同一分支；阔折叠外屏横屏
   * 632vp / 平板横屏 ≥600vp 均不命中，维持既有分支（md·lg 栅格 / 分栏）。
   */
  static readonly LANDSCAPE_COMPACT_MAX_WINDOW_H_VP: number = 500;

  /**
   * 紧凑横屏封面与下方歌名块的最小间隙（vp，2026-10-24 横屏版式重设计）：
   * 封面预算 = min(封面壳实测宽, 壳实测高 − 本值)。壳高由 layoutWeight(1)
   * 天然扣除歌名/歌手/三键块的实测高（自适应 lg 档按钮 76vp / 字号缩放，
   * 不做脆弱的固定保留区估算）；本值只留封面与歌名的呼吸间隙，防贴死。
   */
  static readonly LANDSCAPE_COVER_GAP_VP: number = 12;
}
