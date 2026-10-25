/**
 * 通用数组数据源：List + LazyForEach 的标准配套（实现 IDataSource）。
 *
 * 适用场景：一次性读入、整表替换的长列表（歌单详情 / 最近播放等）。
 * 页面持有**唯一**实例，数据变化时调用 reload() 整表替换并通知重载；
 * LazyForEach 只为可视区 + 缓存区建节点，上百条数据首屏不再全量构建。
 *
 * ⚠️ 不适合高频局部变更的列表（如下载页每秒推进度）：本类只有整表重载，
 * 局部刷新请用 onDataAdd / onDataChange 精确通知，或继续用带 key 的 ForEach。
 *
 * ⚠️ LazyForEach 依赖 itemGenerator 的 keyGenerator 判等：key 必须稳定且唯一
 * （用业务 id，不要用下标），否则滚动复用时会串行。
 */

export class ArrayDataSource<T> implements IDataSource {
  private listener: DataChangeListener | undefined;
  private items: Array<T>;

  constructor(items: Array<T>) {
    this.items = items;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listener = listener;
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listener = undefined;
  }

  /** 整表替换并通知 LazyForEach 重载（可视区外的节点按需重建） */
  reload(items: Array<T>): void {
    this.items = items;
    if (this.listener !== undefined) {
      this.listener.onDataReloaded();
    }
  }

  /**
   * 尾部增量追加（上拉加载更多专用）：
   * 只通知 LazyForEach「新增了下标 start..start+n-1 的数据」（onDataAdd），
   * 可视区已建节点不重建、缓存区不丢弃、滚动锚点不重算 —— 区别于 reload 的
   * 整表重载（onDataReloaded 会让可视区节点失效重建，列表在底部过滚动 /
   * 惯性动画在途时表现为「整体跳一下」）。
   * 调用方自行去重（按业务 id），本方法不判重；空数组直接 no-op。
   */
  append(items: Array<T>): void {
    if (items.length === 0) {
      return;
    }
    const start: number = this.items.length;
    for (let i = 0; i < items.length; i++) {
      this.items.push(items[i]);
    }
    if (this.listener !== undefined) {
      for (let i = 0; i < items.length; i++) {
        this.listener.onDataAdd(start + i);
      }
    }
  }
}
