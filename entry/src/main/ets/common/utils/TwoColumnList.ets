/**
 * 两列列表共享模块（2026-10-23 横屏宽屏改造）。
 *
 * 触发条件（2026-10-23 平板竖屏扩展）：
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

/** 两列槽间距（vp）：左右两列之间的留白（挂在第二个槽的 left margin 上） */
export const TWO_COL_GAP_VP: number = 12;

/**
 * 平板设备判定（2026-10-23 平板竖屏两列）：deviceType 静态只读，进程生命周期
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
}

/**
 * LazyForEach 的两列视图数据源（无状态视图，2026-10-23）：
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
