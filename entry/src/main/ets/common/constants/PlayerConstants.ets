/**
 * 播放页常量。
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
   * 紧凑横屏分支直板机路径的窗口高度上限（vp）：
   * 直板机横屏（窗口内容高 ~391vp）经「横屏且窗口高低于此值」命中紧凑横屏
   * 布局；折叠屏展开横屏（Pura X 展开横屏 ~721vp 高）不走
   * 高度阈值，由 isFoldFull && isLandscape 直进同一分支；阔折叠外屏横屏
   * / 平板横屏（高 ≥600vp）均不命中，维持既有分支（md·lg 栅格 / 分栏）。
   */
  static readonly LANDSCAPE_COMPACT_MAX_WINDOW_H_VP: number = 500;

  /**
   * 紧凑横屏封面与下方歌名块的最小间隙（vp）：
   * 封面预算 = min(封面壳实测宽, 壳实测高 − 本值)。壳高由 layoutWeight(1)
   * 天然扣除歌名/歌手/三键块的实测高（自适应 lg 档按钮 76vp / 字号缩放，
   * 不做脆弱的固定保留区估算）；本值只留封面与歌名的呼吸间隙，防贴死。
   */
  static readonly LANDSCAPE_COVER_GAP_VP: number = 12;

  /**
   * 阔折叠判定——折起外屏（竖屏）窗口宽高比下限。
   * 系统无公开 API 区分阔折叠（Pura X 类）与常规折叠（Mate X 类），按外屏
   * 宽高比分档：阔折叠外屏 ≈0.62（近方偏宽），常规折叠外屏 ≈0.49（窄长），
   * 取两档中分为阈值。宽高比与 px/vp 密度换算无关（比例恒定）。
   * 配套真机诊断日志见 PlayerInfoComponent 的 [PlayerInfo] 前缀输出。
   */
  static readonly WIDE_FOLD_OUTER_ASPECT_MIN: number = 0.56;

  /**
   * 阔折叠判定——展开内屏（竖屏）窗口宽高比下限。
   * 阔折叠展开内屏 ≈1.04（近方偏宽），常规折叠展开内屏 ≈0.89（偏长方），
   * 取两档中分为阈值。命中即按直板机版式渲染（用户拍板：仅阔折叠展开去分栏，
   * 常规折叠展开保持左右分栏——md 断点下两类折叠屏均出现，无法按断点区分，
   * 只能按宽高比）。
   */
  static readonly WIDE_FOLD_INNER_ASPECT_MIN: number = 0.97;
}
