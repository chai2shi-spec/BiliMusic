/**
 * 子页标题栏高度常量（vp）。
 *
 * 各 NavDestination 子页（PlaylistDetail / RecentPage / AboutPage）的内容区
 * 顶部以此高度为避让基准，标题栏整体落在状态栏下方（不与状态栏 / 挖孔重叠）。
 *
 * 历史：本文件原先还有一个沉浸光感标题栏配置函数（uiMaterial THIN 材质），
 * 但各子页从未调用过（标题栏样式由各页 .title() 自行配置），已按死代码移除。
 */

/** 沉浸标题栏高度（内容区顶部避让基准） */
export const NAV_TITLE_BAR_HEIGHT: number = 56;
