/**
 * 断点常量（移植自 audio-interaction-master，配合 BreakpointSystem 使用）。
 * SM=手机 / MD=折叠屏展开·小平板 / LG=平板·大屏。
 */

export class BreakpointConstants {
  static readonly BREAKPOINT_SM: string = 'sm';
  static readonly BREAKPOINT_MD: string = 'md';
  static readonly BREAKPOINT_LG: string = 'lg';

  static readonly RANGE_SM: string = '(320vp<=width<600vp)';
  static readonly RANGE_MD: string = '(600vp<=width<840vp)';
  static readonly RANGE_LG: string = '(840vp<=width)';

  static readonly COLUMN_SM: number = 4;
  static readonly COLUMN_MD: number = 8;
  static readonly COLUMN_LG: number = 12;
  /** LG 歌词区的栅格总列数（歌词只占 7 列居中） */
  static readonly COLUMN_LYRIC_LG: number = 7;

  static readonly GUTTER_MUSIC_X: number = 24;

  static readonly SPAN_SM: number = 4;
  static readonly SPAN_MD: number = 6;
  static readonly SPAN_LYRIC_LG: number = 5;

  static readonly OFFSET_MD: number = 1;
  static readonly OFFSET_LG: number = 2;

  /** 当前断点在 AppStorage 中的键（BreakpointSystem 写入，各组件 @StorageProp 订阅） */
  static readonly CURRENT_BREAKPOINT: string = 'currentBreakpoint';

  /**
   * 列表类页面内容列的最大宽度（vp）：大屏上收窄居中，避免一行列表被拉到整屏宽
   * （平板上 1200vp 宽的「封面 + 两行字 + 按钮」行，阅读密度和点按效率都很差）。
   *
   * SM 取 600 是「无约束」的写法：sm 断点的窗口宽度本身就 < 600vp，永远触不到上限，
   * 这样各页可以无脑挂 constraintSize，不必按断点增删属性。
   */
  static readonly CONTENT_MAX_WIDTH_SM: number = 600;
  /** 折叠屏展开（600~840vp）：内容列收在 600vp 居中，行宽保持手机上的阅读密度 */
  static readonly CONTENT_MAX_WIDTH_MD: number = 600;
  /** 平板（≥840vp）：内容列放宽到 720vp 居中，两侧留白 */
  static readonly CONTENT_MAX_WIDTH_LG: number = 720;

  /** 按断点取内容列最大宽度（配合页面里的 @StorageProp(CURRENT_BREAKPOINT) 使用） */
  static contentMaxWidth(breakpoint: string): number {
    if (breakpoint === BreakpointConstants.BREAKPOINT_LG) {
      return BreakpointConstants.CONTENT_MAX_WIDTH_LG;
    }
    if (breakpoint === BreakpointConstants.BREAKPOINT_MD) {
      return BreakpointConstants.CONTENT_MAX_WIDTH_MD;
    }
    return BreakpointConstants.CONTENT_MAX_WIDTH_SM;
  }

  /**
   * 横屏媒体查询（2026-10-23 两列列表改造）：窗口宽 > 高。
   * BreakpointSystem 注册监听，命中状态写入 AppStorage（IS_LANDSCAPE 键）。
   */
  static readonly RANGE_LANDSCAPE: string = '(orientation: landscape)';
  /** 当前横竖屏在 AppStorage 中的键（true = 横屏，缺省 false = 按竖屏处理） */
  static readonly IS_LANDSCAPE: string = 'isLandscape';

  /**
   * 两列模式内容列上限（vp）：两列激活（横屏宽屏：折叠屏展开横屏 / 平板横屏 /
   * 手机横屏；2026-10-23 扩展：平板竖屏亦两列）时列表条目两列显示，内容列
   * 放宽到 840vp，保证每列约 400vp 以上的行宽；其余（折叠屏展开竖屏等）仍走
   * contentMaxWidth（600/720）。判定见 TwoColumnLayout.isActive。
   */
  static readonly CONTENT_MAX_WIDTH_TWOCOL: number = 840;
}
