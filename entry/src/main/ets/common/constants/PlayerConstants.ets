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
   * 阔折叠判定——展开内屏（竖屏）窗口宽高比上限。
   * 阔折叠（Pura X 类）内外屏同为 16:10 长屏：展开内屏竖屏宽高比 ≈0.62
   * （1320/2120），与折起外屏（≈0.62）同比例；常规折叠（Mate X 类）展开
   * 内屏近方偏宽 ≈0.83~0.92（三星 Fold ≈0.83、Mate X5 ≈0.89）。取两档
   * 中分为阈值：≤0.75 判阔折叠（按直板机版式渲染，用户拍板：仅阔折叠展开
   * 去分栏，常规折叠展开保持左右分栏——md 断点下两类折叠屏均出现，无法按
   * 断点区分，只能按宽高比）。宽高比与 px/vp 密度换算无关（比例恒定）。
   * ⚠️ 修正史：早期按「展开内屏 ≈1.04 近方」设下限 0.97 —— 与真机不符
   * （Pura X 展开内屏为 16:10 长屏而非近方屏，竖屏宽高比 ≈0.62），展开
   * 竖屏从未命中过阔折叠分支、一直落常规折叠分栏，已按真机实测修正为上限。
   * 已知边界：三折叠全展开竖屏（≈0.70）落本口径会走直板机版式；系统无公开
   * API 按机型区分，暂不处理。
   * 配套真机诊断日志见 PlayerInfoComponent 的 [PlayerInfo] 前缀输出。
   */
  static readonly WIDE_FOLD_INNER_ASPECT_MAX: number = 0.75;
}
