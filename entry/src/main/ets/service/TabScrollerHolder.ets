/**
 * 各 Tab 页滚动控制器持有器（HdsNavigation 迁移批 3，Tab 页方案验证）。
 *
 * 为什么需要它：Tab 页顶栏走「Navigation 级统一 titleBar」（任务书问题 1 方案 B）时，
 * 根容器 Index 需要拿到**当前激活 Tab 页的 List scroller** 交给 `.bindToScrollable()`
 * 驱动滚动模糊——而 TabContent 子组件是声明式创建，根侧拿不到其实例，
 * 故用这个静态持有器承载四个 scroller。
 *
 * ⚠️ 静态字段即**唯一真源**（2026-10-11 四页签首开无模糊修复）：页面**直接把该实例
 * 挂到自己的 List**（`List({ scroller: TabScrollerHolder.xxx })`），**禁止 new 后替换**。
 * 旧模式「页面 new 私有 scroller → aboutToAppear 里替换静态字段」会让 Index 的
 * bindToScrollable 在页面注册之前求值时拿到从未挂载的占位实例，滚动事件零反馈，
 * 顶栏滚动模糊整段失效——表现为「首开无模糊、运行一段时间偶尔恢复、有时要滚半屏」。
 * 身份恒定后，绑定与挂载的先后顺序不再敏感（同一实例，事件随挂载开始流动）。
 *
 * 批 4（铺开）扩展：顶栏内容迁到根容器后，栏内按钮的动作（选择/全选/重试/删除等）
 * 仍归页面私有方法，根栏侧组件经这里的静态回调转交页面执行（页面 aboutToAppear 注册）。
 * 回调刻意用「默认空实现」而不是可空类型：栏组件直接调用，无需判空。
 */

export class TabScrollerHolder {
  /** 设置页列表控制器（SettingsPage 的 List 直挂此实例；根 HdsNavigation 绑定它驱动顶栏滚动模糊） */
  static settings: Scroller = new Scroller();
  /** 下载页列表控制器（DownloadsPage 的 List 直挂此实例） */
  static downloads: Scroller = new Scroller();

  // ---- 下载页顶栏动作（DownloadsPage 注册；DownloadsTabBar 调用） ----
  /** 「选择 / 完成」切换（进出多选模式，同时清空选区） */
  static dlToggleSelecting: () => void = (): void => {};
  /** 「全选 / 取消全选」 */
  static dlToggleSelectAll: () => void = (): void => {};
  /** 「重试选中」：只对选中的失败项生效（非失败项由 retryTasks 跳过） */
  static dlRetrySelected: () => void = (): void => {};
  /** 「删除选中」：弹确认框后删任务与本地文件 */
  static dlRemoveSelected: () => void = (): void => {};
  /** 「全部开始」：恢复下载队列 */
  static dlResumeAll: () => void = (): void => {};
  /** 「全部暂停」：暂停下载队列 */
  static dlPauseAll: () => void = (): void => {};

  /** 歌单页列表控制器（PlaylistsPage 的 List 直挂此实例） */
  static playlists: Scroller = new Scroller();

  // ---- 歌单页顶栏动作（PlaylistsPage 注册；PlaylistsTabBar 调用） ----
  /** 「选择 / 完成」切换（进出多选模式，同时清空选区） */
  static plToggleSelecting: () => void = (): void => {};
  /** 「新建」：打开新建歌单弹窗 */
  static plOpenCreate: () => void = (): void => {};
  /** 「全选 / 取消全选」 */
  static plToggleSelectAll: () => void = (): void => {};
  /** 「合并选中」：选中不足两个时页面内兜底提示 */
  static plOpenMergeEditor: () => void = (): void => {};
  /** 「删除选中」：确认后批量删除选中的歌单（收藏夹镜像仅删本地） */
  static plDeleteSelected: () => void = (): void => {};

  /** 搜索页列表控制器（SearchPage 的 List 直挂此实例） */
  static search: Scroller = new Scroller();

  // ---- 搜索页顶栏动作（SearchPage 注册；SearchTabBar 调用） ----
  /** 提交搜索（输入框回车）：由 SearchPage 在 **onAppear** 里接管 */
  static searchSubmit: () => void = (): void => {};
  /**
   * 当前接管 searchSubmit 的 SearchPage 实例号（-1 = 无人接管）。
   *
   * 为什么需要归属：平板分支下 HdsNavigation 会先建一个临时 SearchPage 再销毁它；
   * 临时实例若在 aboutToAppear 里绑回调，会把静态槽位抢走 → 提交打到已销毁实例，
   * 「请求发出去了但界面不动」。改在 onAppear 绑定 + 按归属清空即可。
   */
  static searchSubmitOwner: number = -1;
  /** 点 / 获焦搜索框：有历史则展开面板（面板本体仍在页面层渲染） */
  static searchOpenHistory: () => void = (): void => {};
  /** 收起历史面板（开始输入 / 点页签行空白处时根栏侧调用） */
  static searchCloseHistory: () => void = (): void => {};
  /** 切换搜索类型（视频 / UP 主）：白片动画在根栏滑片上，页面只换值 + 结果态自动重搜 */
  static searchSetKind: (kind: string) => void = (kind: string): void => {};
  /** 切换内容页签（搜索 / 推荐 / 排行榜 / 音乐中心） */
  static searchSwitchTab: (target: string) => void = (target: string): void => {};
}
