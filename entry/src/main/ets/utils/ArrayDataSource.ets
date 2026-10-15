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
}
