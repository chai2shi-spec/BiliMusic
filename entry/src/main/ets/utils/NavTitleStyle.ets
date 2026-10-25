/**
 * 顶栏尺寸令牌（全站唯一来源）。
 *
 * 把「标题行 / 辅助行 / 返回键 / 水平基线」的数值收敛到一处：
 * 各页散写魔数会导致同层级页面间尺寸不一，跨页转场时标题横跳。
 *
 * ===== 结构（自上而下三段）=====
 *   [状态栏 safeTop]        由 HdsNavigation 的 avoidLayoutSafeArea 让开
 *   [标题行 56]             HDS 材质 + 滚动渐变模糊（HdsTitleBarStyle）
 *   [辅助行 44]（可选）     页签胶囊 / 多选工具条，纯内容件、无背板
 *   [内容]
 *
 * 水平基线统一 NAV_H_PADDING：标题行、搜索行、页签行、列表内容行共用同一条
 * 左缘，滚动时标题与内容在一条竖线上。
 */

/** 标题行高度（vp）：HDS titleBar 的 stackBuilder 可用空间，不得超出 */
export const NAV_TITLE_BAR_HEIGHT: number = 56;

/** 辅助行高度（vp）：页签胶囊行 / 多选工具条（胶囊 32 + 上下留白 12） */
export const NAV_SUB_BAR_HEIGHT: number = 44;

/** 顶栏水平基线（vp）：标题、搜索框、页签胶囊、列表内容共用 */
export const NAV_H_PADDING: number = 16;

/** 返回键区域宽（vp）：标题行首让出 HDS 默认返回键的占位宽 */
export const NAV_BACK_SIZE: number = 44;

/** 返回键占位与标题之间的视觉间距（vp） */
export const NAV_TITLE_GAP: number = 4;

/** 顶栏文字动作按钮高（vp） */
export const NAV_ACTION_HEIGHT: number = 32;

/** 顶栏文字动作按钮字号（fp） */
export const NAV_ACTION_FONT_SIZE: number = 13;
