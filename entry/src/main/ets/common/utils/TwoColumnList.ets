/**
 * 两列列表共享模块。
 *
 * 触发条件：
 *   · 平板（deviceType 'tablet'）：横竖屏皆两列 —— 竖屏窗口约 800vp，每列约
 *     394vp 仍保持阅读密度；只保留 sm 门控（自由窗口窄态单列）；
 *   · 折叠屏 / 手机：横屏 且 宽度断点非 sm（窗口 ≥600vp 才算「宽屏」）—— 覆盖
 *     折叠屏展开横屏 / 手机横屏；竖屏与窄窗口（自由窗口小态）保持单列
 *     （折叠屏展开竖屏 ~640-720vp 刻意单列，靠设备类型与平板竖屏区分）。
 *
 * 技术路线＝**配对（pairing）**而非 List.lanes：两列时每个 ListItem 内
 * Row 左右并排渲染两个条目。原因：
 *   · PlaylistsPage 首个 ListItem 是「占位 + 点选提示工具条」、SearchPage 有
 *     下拉刷新骨架条目、各页有尾部「加载更多」状态条 —— lanes 会把这些整行
 *     结构全部劈成半宽；
 *   · FavSyncPage 列表内容异构（提示块 / 节头 / InsetCard 卡片），lanes 完全不可用；
 *   · PlaylistDetail 的 ForEach.onMove 长按拖动排序在 lanes 下行为未知。
 * 配对方案下占位 / 骨架 / 工具条 / 状态条天然保持整行宽，HDS 渐变模糊绑定
 * scroller 的机制、onReachEnd / contentEndOffset / 分页逻辑完全不动。
 */

import { BreakpointConstants } from '../constants/BreakpointConstants';
import { ArrayDataSource } from '../../utils/ArrayDataSource';
import { deviceInfo } from '@kit.BasicServicesKit';

/** 一对条目：second 为 null 表示奇数末尾只有一列（右侧槽留空） */
export class PairOf<T> {
  first: T;
  second: T | null;

  constructor(first: T, second: T | null) {
    this.first = first;
    this.second = second;
  }
}

/** 数组 → 对数组（两列模式的 ForEach 数据源；只装引用，O(n) 无拷贝） */
export function makePairs<T>(items: Array<T>): Array<PairOf<T>> {
  const pairs: Array<PairOf<T>> = [];
  for (let i = 0; i < items.length; i += 2) {
    pairs.push(new PairOf<T>(items[i], i + 1 < items.length ? items[i + 1] : null));
  }
  return pairs;
}

// ── N 列泛化（平板横屏铺满改造，2026-10-25）──────────────────────────────
// PairOf 写死 2 列；RowOf 泛化为 N 槽（尾部空槽 null = 奇数末行右侧留空）。
// 旧 PairOf/makePairs/PairDataSource 保留（二级页继续 2 列 840 上限，
// 页签页换 RowOf 路线铺满窗口，见 TwoColumnLayout.listColumns 注释）。

/** 长条行列数公式参数：目标列宽（vp）——每列保持手机阅读密度 */
const LIST_COL_TARGET_W: number = 400;
/** 长条行列数上限：超过 4 列每列信息量过低（封面+两行字+按钮行） */
const LIST_MAX_COLS: number = 4;
/** 网格卡列数公式参数：目标卡宽（vp）——大封面卡视觉密度 */
const GRID_COL_TARGET_W: number = 240;
/** 网格卡列数上限：超过 6 卡每卡过小 */
const GRID_MAX_COLS: number = 6;
/** 页签页铺满上限（vp）：= 4×400 + 3×12 间隔 + 2×16 页边，4 列封顶的物理宽 */
const FILL_MAX_VP: number = 1660;

/**
 * 行槽：N 列一行（配对方案的 N 列泛化）。
 * slots 长度 = 当前列数；尾部空槽为 null（奇数末行右侧槽留空占位）。
 */
export class RowOf<T> {
  slots: Array<T | null>;

  constructor(slots: Array<T | null>) {
    this.slots = slots;
  }
}

/** 数组 → 行数组（makeRows(items, cols)，makePairs 的 N 列泛化；只装引用） */
export function makeRows<T>(items: Array<T>, cols: number): Array<RowOf<T>> {
  const rows: Array<RowOf<T>> = [];
  const n: number = cols < 1 ? 1 : cols;
  for (let i = 0; i < items.length; i += n) {
    const slots: Array<T | null> = [];
    for (let j = 0; j < n; j++) {
      slots.push(i + j < items.length ? items[i + j] : null);
    }
    rows.push(new RowOf<T>(slots));
  }
  return rows;
}

/** 两列槽间距（vp）：左右两列之间的留白（挂在第二个槽的 left margin 上） */
export const TWO_COL_GAP_VP: number = 12;

/**
 * 大封面网格行页边距（vp）：网格配对 Row 的
 * 左右 padding，封面宽 = (行宽 − 2×24 − 12) / 2 ≈ 134vp（用户选定档位）。
 * 挂 Row padding 而非卡内 padding：配对 Row 才知道
 * 「这一行是网格行」，且奇数末行能与满行卡严格等宽。
 * ⚠️ 只用于 isGrid() 网格分支；横屏两列长条分支不加（TrackItem 自带 16/4 内边距，
 * 长条模式回归零容忍）。
 */
export const GRID_EDGE_PADDING_VP: number = 24;

/**
 * 平板设备判定：deviceType 静态只读，进程生命周期
 * 内不变，模块加载时读一次即可。平板返回 'tablet'；折叠屏 / 手机返回 'phone'
 * 且不受折叠形态影响 —— 正是用它把「平板竖屏两列」与「折叠屏竖屏单列」区分开。
 */
const IS_TABLET_DEVICE: boolean = deviceInfo.deviceType === 'tablet';

/** 两列布局判定 + 内容列上限（各页 @StorageProp 订阅后调用，纯函数无状态） */
export class TwoColumnLayout {
  /** 两列激活条件：平板横竖屏皆可（仅 sm 门控）；折叠屏 / 手机须「横屏宽屏」（宽度 ≥600vp 的横屏） */
  static isActive(breakpoint: string, isLandscape: boolean): boolean {
    // 平板（deviceType 'tablet'）：横竖屏皆两列 —— 竖屏窗口约 800vp，每列约
    // 394vp 仍保持阅读密度；只保留 sm 门控（自由窗口窄态单列）。
    if (IS_TABLET_DEVICE) {
      return breakpoint !== BreakpointConstants.BREAKPOINT_SM;
    }
    // 折叠屏 / 手机：维持「横屏宽屏」触发（折叠屏展开竖屏 ~640-720vp 保持单列）
    return isLandscape && breakpoint !== BreakpointConstants.BREAKPOINT_SM;
  }

  /**
   * 两列模式内容列上限 840vp（每列约 400vp+ 行宽），否则回落 contentMaxWidth
   * （sm 600 / md 600 / lg 720）。页面 constraintSize 的 maxWidth 换成本方法即可。
   * 两列激活（横屏宽屏 / 平板竖屏）即取 840：13" 平板竖屏内容列由 720 放宽到
   * 840；11" 平板竖屏（窗口约 800vp）上限不绑定，表现为整宽两列。
   */
  static contentMaxWidth(breakpoint: string, isLandscape: boolean): number {
    if (TwoColumnLayout.isActive(breakpoint, isLandscape)) {
      return BreakpointConstants.CONTENT_MAX_WIDTH_TWOCOL;
    }
    return BreakpointConstants.contentMaxWidth(breakpoint);
  }

  /**
   * 长条行列数（页签页铺满改造）：非两列态 1 列；两列激活时按窗口宽反推
   * clamp(floor((w-32)/400), 2, 4)——窗口 0（冷启动未首发）回落 2 列现行为。
   * 各形态落点：手机横屏 ~780 → 2（不变）；平板竖屏 ~800 → 2（不变）；
   * 平板横屏 ~1280 → 3、~1600 → 4（本次改造目标）。
   */
  static listColumns(breakpoint: string, isLandscape: boolean, windowWidthVp: number): number {
    if (!TwoColumnLayout.isActive(breakpoint, isLandscape)) {
      return 1;
    }
    if (windowWidthVp <= 0) {
      return 2;
    }
    const cols: number = Math.floor((windowWidthVp - 32) / LIST_COL_TARGET_W);
    return cols < 2 ? 2 : (cols > LIST_MAX_COLS ? LIST_MAX_COLS : cols);
  }

  /**
   * 网格卡列数（页签页铺满改造）：非两列态仍 2 列（大封面模式手机竖屏本就
   * 双列网格）；两列激活时 clamp(floor((w-48)/240), 2, 6)。
   * 手机横屏 ~780 由 2 卡加密为 3 卡（列数公式自然结果，更饱满）。
   */
  static gridColumns(breakpoint: string, isLandscape: boolean, windowWidthVp: number): number {
    if (!TwoColumnLayout.isActive(breakpoint, isLandscape)) {
      return 2;
    }
    if (windowWidthVp <= 0) {
      return 2;
    }
    const cols: number = Math.floor((windowWidthVp - 48) / GRID_COL_TARGET_W);
    return cols < 2 ? 2 : (cols > GRID_MAX_COLS ? GRID_MAX_COLS : cols);
  }

  /**
   * 页签页内容列上限（铺满口径）：两列激活 → min(窗口宽, 1660) 铺满
   * （列数由 listColumns/gridColumns 按同窗口宽反推，行宽保持密度）；
   * 否则回落 contentMaxWidth（600/720）。窗口 0 回落 840 现行为。
   * 仅页签页 + Index 顶栏收窄包装使用；二级页仍走 contentMaxWidth。
   */
  static fillContentMaxWidth(breakpoint: string, isLandscape: boolean, windowWidthVp: number): number {
    if (!TwoColumnLayout.isActive(breakpoint, isLandscape)) {
      return TwoColumnLayout.contentMaxWidth(breakpoint, isLandscape);
    }
    if (windowWidthVp <= 0) {
      return BreakpointConstants.CONTENT_MAX_WIDTH_TWOCOL;
    }
    return windowWidthVp > FILL_MAX_VP ? FILL_MAX_VP : windowWidthVp;
  }
}

/**
 * LazyForEach 的两列视图数据源（无状态视图）：
 * totalCount / getData 直接读 base（每次 getData(i) 现场构造 PairOf），
 * 不缓存、不在 base 上注册 listener（ArrayDataSource 是单 listener 槽位，
 * 双向注册会在横竖屏切换 LazyForEach 换绑数据源时互相覆盖）。
 *
 * 通知方向＝页面显式 sync()：凡调用 base.reload() / base.append() 的地方，
 * 紧跟一行 this.xxxPairs.sync()（整表 onDataReloaded，可视区外按需重建，
 * 与 ArrayDataSource.reload 的重建粒度一致）。
 */
export class PairDataSource<T> implements IDataSource {
  private base: ArrayDataSource<T>;
  private listener: DataChangeListener | undefined;

  constructor(base: ArrayDataSource<T>) {
    this.base = base;
  }

  totalCount(): number {
    return Math.ceil(this.base.totalCount() / 2);
  }

  getData(index: number): PairOf<T> {
    const i: number = index * 2;
    return new PairOf<T>(
      this.base.getData(i),
      i + 1 < this.base.totalCount() ? this.base.getData(i + 1) : null
    );
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listener = listener;
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listener = undefined;
  }

  /** 页面在 base 数据变化后调用：通知 LazyForEach 整表重载 */
  sync(): void {
    if (this.listener !== undefined) {
      this.listener.onDataReloaded();
    }
  }
}

/**
 * LazyForEach 的 N 列行数据源（RowOf 路线，PairDataSource 的泛化）：
 * 无状态视图，totalCount = ceil(base.totalCount() / columns)，getData(i)
 * 现场构造 RowOf（不缓存、不在 base 上挂 listener，理由同 PairDataSource）。
 *
 * 列数可变（旋转 / 自由窗口拖宽）：页面 @Watch 重算后 setColumns(n)，
 * 值变化才需紧跟 sync()（onDataReloaded），否则 totalCount 与渲染数不一致。
 * 数据变化的通知方向与 PairDataSource 相同：base.reload()/append() 后页面显式 sync()。
 */
export class RowDataSource<T> implements IDataSource {
  private base: ArrayDataSource<T>;
  private columns: number;
  private listener: DataChangeListener | undefined;

  constructor(base: ArrayDataSource<T>, columns: number) {
    this.base = base;
    this.columns = columns < 1 ? 1 : columns;
  }

  setColumns(columns: number): void {
    this.columns = columns < 1 ? 1 : columns;
  }

  totalCount(): number {
    return Math.ceil(this.base.totalCount() / this.columns);
  }

  getData(index: number): RowOf<T> {
    const start: number = index * this.columns;
    const slots: Array<T | null> = [];
    for (let j = 0; j < this.columns; j++) {
      slots.push(start + j < this.base.totalCount() ? this.base.getData(start + j) : null);
    }
    return new RowOf<T>(slots);
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listener = listener;
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listener = undefined;
  }

  /** 页面在 base 数据变化 / 列数变化后调用：通知 LazyForEach 整表重载 */
  sync(): void {
    if (this.listener !== undefined) {
      this.listener.onDataReloaded();
    }
  }
}
