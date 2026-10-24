/**
 * 下载管理页：任务列表（实时进度 / 速度 / **实际码率**）、点击播放已下载音频、
 * 全部暂停 · 全部开始、多选批量删除。
 * 条目右侧「⋯」更多菜单（2026-10-23，歌单页同款）：加入队列 / 加入歌单 /
 * 进入 UP 主页 / 删除（破坏性操作放最后）；单曲行、分P子行与合集/歌单组头统一。
 *
 * 数据订阅 AppStorage(STORE_DOWNLOAD_TASKS)：DownloadManager 持有内存态任务表，
 * 插入 / 进度 / 完成 / 失败都会推一份新快照，因此无需轮询，也不必重启才看得到状态。
 *
 * 简约 iOS 风格：根栏标题行常显；队列控制（全部开始/暂停）在标题行右侧
 * （留白整改迁入），多选工具条只在多选态出现（标题行正下方，不随列表滚动）。
 *
 * ⚠️⚠️ **ForEach 的 key（见 rowKey / groupRowKey）是本页最容易改坏、且症状最迷惑的地方。**
 * `DownloadTask` 是普通 interface 对象而不是 `@Observed` 类，ForEach 只按 key 判等：
 * key 不变就**复用旧节点**，而复用出来的节点里 itemGenerator 的入参 `t` 冻结在
 * 首次渲染那一刻 —— 只读 `t` 的字段，属性怎么变界面都不动。
 * 但保留节点并非死节点：**组件 @State 的读取是活的**，快照/选择/按压状态变化会触发
 * 保留节点局部重渲染（本页的按压缩放 pressedKey、「正在播放」徽标、排队中的
 * 「已暂停」后缀都靠这个机制工作，下载中的行则靠下述动画镜像）。
 * 因此 key 只需编入「不靠镜像/局部状态刷新」的变化；改渲染逻辑务必连带检查两个 key：
 *   · status / totalBytes 未知→已知：结构性分支（进度环↔进度条），必须重建；
 *   · 未被镜像接管的下载行：进度 5% 分桶兜底（防未来并发下载时镜像外的行冻结）；
 *   · 选择模式（selecting / 选中态）**刻意不进 key**：多选进出要对保留节点做
 *     250ms 槽位展开动画，key 一变就是整节点重建、无从动画（见 TaskRow）。
 */

import { DownloadTask, DownloadStatus, Playlist, Track, VideoDetail, buildTrack } from '../model/MusicModels';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../service/DownloadManager';
import { MusicPlayer } from '../player/MusicPlayer';
import {
  CONTENT_END_OFFSET,
  STORE_ACTIVE_TAB,
  STORE_CURRENT_TRACK,
  STORE_DL_BAR_ALL_SELECTED,
  STORE_DL_BAR_CAN_RETRY,
  STORE_DL_BAR_HAS_TASKS,
  STORE_DL_BAR_QUEUE_ACTIVE,
  STORE_DL_BAR_QUEUE_PAUSED,
  STORE_DL_BAR_SELECTED_COUNT,
  STORE_DL_BAR_SELECTING,
  STORE_DOWNLOAD_PAUSED,
  STORE_DOWNLOAD_TASKS,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_DEEP,
  STORE_THEME_ON,
  formatTrackQuality
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  PairOf,
  makePairs,
  TWO_COL_GAP_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { PRESS_SCALE, PRESS_ANIM_MS, SELECT_SLOT_VP, SELECT_TOGGLE_MS, DOWNLOAD_SMOOTH_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { showAppToast } from '../components/AppToast';
import { CoverImage } from '../components/CoverImage';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { toThumbUrl } from '../utils/TextUtil';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { Chip, ChipSize } from '@kit.ArkUI';
// 「⋯」菜单（2026-10-23）：进入 UP 主页要 getVideoDetail 解析 mid，
// 加入歌单要 LibraryStore / 弹层，跳转要 NavStackHolder —— 与歌单详情页同一套
import * as BilibiliApi from '../api/BilibiliApi';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam } from '../service/NavRouteParams';
import { LibraryStore } from '../service/LibraryStore';
// 2026-10-24 导出：已完成任务经系统保存对话框（AudioViewPicker）导出到文件管理
import { exportTasks, ExportResult } from '../service/AudioExporter';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/**
 * 行内图标按钮的命中区边长。
 *
 * 视觉上图标只有 18px，但手指可靠触达的下限是 44vp（约 7mm）——
 * 直接把图标做到 44px 会破坏版面，正确做法是**视觉不变、命中区撑开**
 * （外层容器 44×44 + 图标居中）。列表行右侧的删除按钮即用此值。
 */
const ROW_ACTION_HIT: number = 44;

/**
 * 下载页在 Index.HdsTabs 里的页签下标（0 搜索 / 1 歌单 / 2 下载 / 3 设置）。
 * 2026-10-08 卡顿优化：快照门控用它判断「当前是否是本页在前台」。
 * ⚠️ 与 Index.build() 里 TabContent 的声明顺序强耦合，调整页签顺序务必同步这里。
 */
const DOWNLOADS_TAB_INDEX: number = 2;

/** DownloadsPage 实例序号：dl* 静态回调的归属校验用（searchSubmitOwner 同款手法） */
let dlPageInstanceSeq: number = 0;

function mbText(bytes: number): string {
  return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

function speedText(bytesPerSecond: number): string {
  if (bytesPerSecond < 1024) {
    return `${bytesPerSecond} B/s`;
  }
  const kb: number = bytesPerSecond / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB/s`;
  }
  return `${(kb / 1024).toFixed(2)} MB/s`;
}

/**
 * 下载列表的分组视图模型：多 P 合集展开出的 N 个分 P 任务归成**一个**条目显示，
 * 点开才看到每个分 P 各自的进度（分组的推导见 groupKeyOf）。
 */
interface DownloadGroup {
  /** 分组键：合集的 bvid；非合集条目为任务 id（永不与 bvid 撞车） */
  key: string;
  /** 组头标题：取组内最早创建任务的标题（下载入口保证首个分 P 带的是合集标题） */
  title: string;
  coverUrl: string;
  /** 组内任务（按创建时间升序 = 分 P 的排队顺序） */
  tasks: DownloadTask[];
  /**
   * 组内各状态计数（2026-10-08 卡顿优化）：buildGroups 归组时一次算好。
   * 此前 groupStatusText / groupRowKey 每次重渲染都全组遍历 countGroup，
   * 组头一行 = 一次 O(组大小) 扫描，多 P 合集下载时 5Hz 快照 × 若干组全在热路径上。
   * 缓存值与旧 countGroup 输出完全一致 → groupRowKey 的 key 串逐字节不变，无重建风险。
   */
  counts: GroupCounts;
  /** 是否合集（多 P）组（判定逻辑见 isCollectionGroup，归组时一次算好） */
  isCollection: boolean;
}

/** 合组的各状态计数，供组头文案与 ForEach key 共用 */
interface GroupCounts {
  done: number;
  downloading: number;
  pending: number;
  paused: number;
  failed: number;
}

@Component
export struct DownloadsPage {
  @StorageLink(STORE_DOWNLOAD_TASKS) @Watch('onTasksSnapshot') tasks: DownloadTask[] = [];
  /** 主题色运行时值：删除确认弹层、「正在播放」徽标与全选 Checkbox 跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时下载组两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** 横屏宽屏（窗口 ≥600vp 的横屏）时按「下载组」配对两列；竖屏 / 窄窗口单列不变 */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }
  /**
   * 列表滚动控制器：List 直接挂 TabScrollerHolder.downloads（唯一真源，身份恒定），
   * 由根 HdsNavigation bindToScrollable 绑定驱动顶栏滚动模糊（批 4 起模糊由 HDS 承担；
   * 2026-10-11 起不再 new 私有实例后注册替换——首开无模糊修复）。
   */
  /** 队列级暂停状态：单条任务的 PAUSED 只说明它自己停了，这里表示整条队列都不动了 */
  @StorageLink(STORE_DOWNLOAD_PAUSED) queuePaused: boolean = false;
  /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /**
   * 状态栏高度（vp）：根 HdsNavigation 标题栏的材质从 y=0 铺起覆盖状态栏
   * （avoidLayoutSafeArea 覆盖式渲染）；本页内容避让是常量表达式（无 onAreaChange
   * 实测），需显式 +safeTop。
   */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 正在播放的曲目：给对应的下载行打「正在播放」标记 */
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;

  /**
   * 当前活动页签（2026-10-08 卡顿优化）：Index 的受控 HdsTabs 写穿 AppStorage。
   * 非本页页签时 onTasksSnapshot 只置脏标记直接返回 —— TabContent 常驻，
   * 切走后下载快照照推，全量重分组 + 镜像动画重定目标都在白跑，还抢滚动帧。
   * @Watch 只在变化时触发：@StorageLink 初值同步不算变化，aboutToAppear 里
   * 已无条件做一次初始分组，不存在「初值不是本页就漏算」的窗口。
   */
  @StorageLink(STORE_ACTIVE_TAB) @Watch('onTabChanged') activeTab: number = 0;
  /** 非活动页签期间错过快照的脏标记：切回本页时补算一次（普通字段即可，只在 watch 回调读写） */
  private snapshotStale: boolean = false;

  /**
    * ControlBar 字色派生缓存（2026-10-08 卡顿优化）：「全部暂停 / 全部开始」的
   * 可用色原先每次重渲染都对全任务表 some() 一遍（hasActive/canResume），
   * 镜像动画期间它们跟着每帧重求值。改为每份快照算一次。
   * canResume 里的 queuePaused 部分刻意**不**并入缓存 —— queuePaused 是
   * @StorageLink，它自身变化就能驱动重渲染，绑定处写 `queuePaused || queueHasPaused`
   * 保证「全部暂停」按下立即点亮「全部开始」。
   */
  @State queueHasActive: boolean = false;
  @State queueHasPaused: boolean = false;

  /**
   * 多选模式开关（批 4 状态迁移）：顶栏迁根容器后，栏内「选择/完成」按钮
   * （components/DownloadsTabBar.ets）要读它 —— 直接挂 AppStorage 单向镜像给根栏。
   */
  @StorageLink(STORE_DL_BAR_SELECTING) selecting: boolean = false;
  /**
   * 已选中的任务 id。刻意用数组而不是 Set —— @State 感知不到 Set 的内容变化。
   * @Watch 同步顶栏派生镜像（选中数 / 全选态 / 可重试态），根栏工具条据此刷新。
   */
  @State @Watch('syncBarState') selectedIds: string[] = [];
  /** 已展开的合集分组键（bvid）。默认收起：列表里一个合集只占一行，点开才铺开分 P */
  @State expandedGroups: string[] = [];
  /**
   * 分组视图缓存：buildGroups 是全量重算（Map 归组 + 两次排序），写在 ForEach 参数里
   * 会在每次重渲染时执行。改为只在 tasks 快照到达时重算一次（onTasksSnapshot），
   * 镜像动画（animPercent 等）驱动的每帧重渲染直接复用这份缓存。
   */
  @State groups: DownloadGroup[] = [];

  /**
   * 按压缩放（TrackItem 模式推广）：当前被按下行的稳定标识，空串＝无按压。
   * 单指操作同一时刻只有一行被按下，一个变量即可驱动任意行缩放，
   * 不必给每个 @Builder 行配独立组件/独立状态。
   * 刻意用稳定 id（任务 id / 合集 bvid）而不是 rowKey —— rowKey 编入了
   * 进度档位，下载中每秒都在变，按住期间 key 漂移会让缩放中途弹回 1.0。
   */
  @State pressedKey: string = '';
  /** 重试请求进行中：防止连点重复发（重试是「删旧记录 + 重新入队」，重复发会互相踩） */
  @State retrying: boolean = false;
  /** 本实例在 dlPageInstanceSeq 里的序号：静态回调解绑的归属校验用 */
  private instanceId: number = 0;

  // ── 「加入歌单」选择弹层（WatchHistoryPage 同款，多曲支持） ──
  @State showPlaylistPicker: boolean = false;
  @State playlistOptions: Playlist[] = [];
  @State pickerTracks: Track[] = [];

  /** 按压状态回写：Down 记录、Up/Cancel 清除；只清自己，避免误清别的行的按压 */
  private setPressed(type: TouchType, key: string): void {
    if (type === TouchType.Down) {
      this.pressedKey = key;
    } else if ((type === TouchType.Up || type === TouchType.Cancel) && this.pressedKey === key) {
      this.pressedKey = '';
    }
  }

  /**
   * ══════════ 下载中数值的动画镜像 ══════════
   *
   * 快照里的数字是瞬时值，直接渲染会让进度条按 5% 分桶跳档、速度/体积长时间冻结后
   * 突跳。快照到达时（onTasksSnapshot）用 animateTo 把镜像平滑推到新值；下载中的行
   * 读镜像而非冻结的 t（见 percent / statusText / groupPercent），进度条因此连续滑动。
   * 串行下载队列同时最多一条在传，单任务镜像 + 单分组镜像即可覆盖。
   */
  /** 镜像接管的在传任务 id（空串 = 无在传任务，全部行回落到冻结快照渲染） */
  @State animTaskId: string = '';
  /** 0~100 连续浮点（不取整：进度条交给 animateTo 插值，文案展示处再取整） */
  @State animPercent: number = 0;
  @State animSpeed: number = 0;
  @State animBytes: number = 0;
  /** 镜像接管的分组键（bvid）；分组聚合进度/速度同理 */
  @State animGroupKey: string = '';
  /** -1 = 分组总大小未知（界面据此显示不确定进度环） */
  @State animGroupPercent: number = -1;
  @State animGroupSpeed: number = 0;

  /**
   * 快照到达：把在传任务（及其所在分组）的目标值用 fast(150ms) Linear animateTo
   * 推给镜像。animateTo 重定目标时从**当前视觉值**起算，快照连发时进度条连续滑动
   * 不回跳（与播放页进度条同一套手法，见 ControlAreaComponent）。
   * 文本数字不吃插值（Text 内容非动画属性），但镜像每份快照都更新，数字从
   * 「每 5% 一档」细化到「每份快照一小步」，配合进度条已足够平滑。
   */
  private onTasksSnapshot(): void {
    // Tab 门控（2026-10-08 卡顿优化）：本页不在前台页签时跳过全部重算与镜像动画，
    // 只留脏标记；切回本页时 onTabChanged 补算。镜像动画在不可见时没有意义。
    if (this.activeTab !== DOWNLOADS_TAB_INDEX) {
      this.snapshotStale = true;
      return;
    }
    this.applyTasksSnapshot();
  }

  /** 切回本页页签：补算非活动期间错过的最后一份快照（中间份无需逐份追，直接到最新） */
  private onTabChanged(): void {
    if (this.activeTab === DOWNLOADS_TAB_INDEX && this.snapshotStale) {
      this.applyTasksSnapshot();
    }
  }

  /**
   * 快照落地：分组重算 + ControlBar 派生缓存 + 镜像动画重定目标。
   * 2026-10-08 卡顿优化前这段叫 onTasksSnapshot 全量直跑；抽成独立方法后
   * Tab 门控（onTasksSnapshot）与切回补算（onTabChanged）共用同一条路径，
   * 不会出现「门控期间漏掉的派生状态在切回后不更新」。
   */
  private applyTasksSnapshot(): void {
    this.snapshotStale = false;
    // 选区剪枝（2026-10-23 审查修复）：重试走「删旧任务 + 建新任务」，selectedIds
    // 里的旧 id 无人清理 → 选中计数虚高、「全选」误判为已全选、删除选中空转。
    // 每份快照对照当前任务表过滤一次死 id（@Watch syncBarState 同步顶栏镜像）。
    if (this.selectedIds.length > 0) {
      const aliveIds: Set<string> = new Set<string>();
      for (let i = 0; i < this.tasks.length; i++) {
        aliveIds.add(this.tasks[i].id);
      }
      const alive: string[] = this.selectedIds.filter((id: string): boolean => aliveIds.has(id));
      if (alive.length !== this.selectedIds.length) {
        this.selectedIds = alive;
      }
    }
    // tasks 每变一次就重算一次分组缓存：放在 active 判断之前，
    // 否则「无在传任务就 return」会把增删/完成引起的列表变化漏掉
    this.rebuildGroups();
    this.refreshQueueFlags();
    // 顶栏镜像跟着每份快照刷新（有无任务 / 可重试态都随 tasks 变化）
    this.syncBarState();
    const active: DownloadTask | undefined =
      this.tasks.find((t: DownloadTask): boolean => t.status === DownloadStatus.DOWNLOADING);
    if (active === undefined) {
      // 无在传任务：清掉镜像归属即可；刚停下的行会因 status 变化走重建渲染最终文案
      this.animTaskId = '';
      this.animGroupKey = '';
      return;
    }
    // 2026-10-08 卡顿优化：组字节聚合**复用刚算好的 groups**，不再对全表逐条
    // groupKeyOf（字符串推导 ×N）。active 必然落在这份 groups 里（同一快照归组），
    // find 不到只可能是逻辑 bug，全 0 兜底表现为「不确定进度环」，无害可观测。
    const gk: string = this.groupKeyOf(active);
    const grp: DownloadGroup | undefined =
      this.groups.find((g: DownloadGroup): boolean => g.key === gk);
    let doneBytes: number = 0;
    let totalBytes: number = 0;
    let groupSpeed: number = 0;
    if (grp !== undefined) {
      for (let i = 0; i < grp.tasks.length; i++) {
        doneBytes += grp.tasks[i].downloadedBytes;
        totalBytes += grp.tasks[i].totalBytes;
        groupSpeed += grp.tasks[i].speed;
      }
    }
    // 下载字节数可能略超 Content-Length，夹住避免出现 100.x%
    const rawPercent: number = active.totalBytes > 0
      ? (active.downloadedBytes / active.totalBytes) * 100 : 0;
    const targetPercent: number = rawPercent > 100 ? 100 : rawPercent;
    const targetGroupPercent: number = totalBytes > 0 ? (doneBytes / totalBytes) * 100 : -1;
    this.getUIContext().animateTo({ duration: DOWNLOAD_SMOOTH_MS, curve: Curve.Linear }, (): void => {
      this.animTaskId = active.id;
      this.animPercent = targetPercent;
      this.animSpeed = active.speed;
      this.animBytes = active.downloadedBytes;
      this.animGroupKey = gk;
      this.animGroupPercent = targetGroupPercent;
      this.animGroupSpeed = groupSpeed;
    });
  }

  /** ControlBar 派生缓存唯一写入口：每份快照扫一遍全表，双条件短路提前退出 */
  private refreshQueueFlags(): void {
    let hasActive: boolean = false;
    let hasPaused: boolean = false;
    for (let i = 0; i < this.tasks.length; i++) {
      const s: DownloadStatus = this.tasks[i].status;
      if (s === DownloadStatus.PENDING || s === DownloadStatus.DOWNLOADING) {
        hasActive = true;
      } else if (s === DownloadStatus.PAUSED) {
        hasPaused = true;
      }
      if (hasActive && hasPaused) {
        break;
      }
    }
    this.queueHasActive = hasActive;
    this.queueHasPaused = hasPaused;
    // 顶栏镜像（批 4）：根栏工具条「全部开始 / 全部暂停」的可用色读这两份镜像
    AppStorage.setOrCreate(STORE_DL_BAR_QUEUE_ACTIVE, hasActive);
    AppStorage.setOrCreate(STORE_DL_BAR_QUEUE_PAUSED, hasPaused);
  }

  /**
   * 顶栏派生镜像唯一写入口（批 4 状态迁移）：把根栏渲染所需的派生状态
   * （有无任务 / 选中数 / 全选态 / 可重试态）推到 AppStorage，根栏侧组件
    * （components/DownloadsTabBar.ets + Index 的行 2 门控）@StorageProp 订阅。
   * 触发点：selectedIds @Watch + applyTasksSnapshot（tasks 每份快照）+ aboutToAppear 初值。
   */
  private syncBarState(): void {
    AppStorage.setOrCreate(STORE_DL_BAR_HAS_TASKS, this.tasks.length > 0);
    AppStorage.setOrCreate(STORE_DL_BAR_SELECTED_COUNT, this.selectedIds.length);
    AppStorage.setOrCreate(STORE_DL_BAR_ALL_SELECTED, this.allSelected());
    AppStorage.setOrCreate(STORE_DL_BAR_CAN_RETRY, this.canRetrySelected());
  }

  /**
   * [任务③·推广] 自绘顶栏渐变模糊层进度更新器 + 校准（SearchPage 原型推广）：
   * onDidScroll / onScrollStop 命令式驱动 opacity（不标 @State，滚动高频
   * 回调零重建）；yOffset 0 → TITLE_BLUR_END_VP 线性映射 0 → 1（updater
   * 内截断，边缘回弹负偏移归零 = 用户方案 ③ 死区）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (TabScrollerHolder.downloads.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    // 批 4：顶栏迁根容器 —— scroller 与栏内按钮动作注册进持有器，
    // 根 HdsNavigation 经 TabScrollerHolder 转发点击动作
    // （scroller 不再注册替换——List 直挂 Holder.downloads 唯一真源，2026-10-11）
    // 2026-10-23 审查修复：登记实例号，销毁时据此做归属校验解绑（见 aboutToDisappear）
    this.instanceId = ++dlPageInstanceSeq;
    // [任务③·推广] 挂载前先存当前偏移对应的进度（updater 未挂载只存值，挂载时
    // initializeModifier 补上），防「已滚过再进页签」首帧缺模糊。
    this.syncTopBlurProgress();
    TabScrollerHolder.dlCallbacksOwner = this.instanceId;
    TabScrollerHolder.dlToggleSelecting = (): void => {
      this.toggleSelecting();
    };
    TabScrollerHolder.dlToggleSelectAll = (): void => {
      this.toggleSelectAll();
    };
    TabScrollerHolder.dlRetrySelected = (): void => {
      this.retryFailed(this.selectedIds);
    };
    TabScrollerHolder.dlRemoveSelected = (): void => {
      this.confirmRemoveSelected();
    };
    TabScrollerHolder.dlAddSelectedToPlaylist = (): void => {
      this.addSelectedToPlaylist();
    };
    // 2026-10-24 导出功能：多选工具条「导出选中」→ 系统保存对话框批量导出到文件管理
    TabScrollerHolder.dlExportSelected = (): void => {
      this.exportSelected();
    };
    TabScrollerHolder.dlResumeAll = (): void => {
      this.resumeAll();
    };
    TabScrollerHolder.dlPauseAll = (): void => {
      this.pauseAll();
    };
    // @StorageLink 从 AppStorage 的初始同步不算「变化」，@Watch 不会为它触发：
    // DownloadManager 可能早在别的 Tab 就推过快照，这里必须补一次分组缓存初始化。
    this.rebuildGroups();
    // ControlBar 派生缓存同理（activeTab @Watch 的初值同步也不触发）
    this.refreshQueueFlags();
    // 顶栏镜像初值同理（根栏可能在页面 aboutToAppear 前就已渲染）
    this.syncBarState();
    // 载入历史任务；后续所有进度/状态变化由 DownloadManager 推送到同一个 AppStorage 键
    DownloadManager.getInstance().ensureLoaded().catch((e: Error): void => {
      console.error(`load downloads failed: ${JSON.stringify(e)}`);
    });
  }

  /**
   * 静态回调解绑（2026-10-23 审查修复）：dl* 槽位的闭包捕获 this，实例销毁后
   * 不清理会持续持有已销毁组件（无法 GC）且触发时往死实例的 @State 写值——
   * 平板/横竖屏分支存在「临时实例先建后销毁」，同病已用 searchSubmitOwner 修过。
   * 归属校验：只有「最后注册的实例」才有权清空，防止先销毁的旧实例误清
   * 后注册新实例的回调（并发实例窗口期）。
   */
  aboutToDisappear(): void {
    if (TabScrollerHolder.dlCallbacksOwner === this.instanceId) {
      TabScrollerHolder.dlCallbacksOwner = -1;
      TabScrollerHolder.dlToggleSelecting = (): void => {};
      TabScrollerHolder.dlToggleSelectAll = (): void => {};
      TabScrollerHolder.dlRetrySelected = (): void => {};
      TabScrollerHolder.dlRemoveSelected = (): void => {};
      TabScrollerHolder.dlAddSelectedToPlaylist = (): void => {};
      TabScrollerHolder.dlExportSelected = (): void => {};
      TabScrollerHolder.dlResumeAll = (): void => {};
      TabScrollerHolder.dlPauseAll = (): void => {};
    }
  }

  private percent(t: DownloadTask): number {
    if (t.status === DownloadStatus.COMPLETED) {
      return 100;
    }
    // 镜像接管的在传任务：返回连续浮点，进度条由 animateTo 插值平滑推进；
    // 文案展示处再取整（见 statusText）。
    if (this.animTaskId === t.id && t.status === DownloadStatus.DOWNLOADING) {
      return this.animPercent;
    }
    if (t.totalBytes <= 0) {
      return 0;
    }
    const p: number = Math.floor((t.downloadedBytes / t.totalBytes) * 100);
    return p > 100 ? 100 : p;
  }

  /**
   * 实际码率文案。**优先实测带宽**：低码率源会给 30280 这个「192K」标签
   * 配上只有 66k 的实测带宽（B 站侧只有一份低码率音源时三个档位指向同一份数据），
   * 直接显示档位标签就是在骗用户。
   *
   * 逻辑已抽成公共函数 `formatTrackQuality`（`common/Constants.ts`），
   * 播放页显示同一首歌时要给出一致的文案，不要在这里另写一份。
   */
  private qualityText(t: DownloadTask): string {
    return formatTrackQuality(t.audioQuality, t.audioBandwidth);
  }

  /**
   * 状态行文案。
   *
   * 下载中拼成「下载中 42%  ·  1.2 MB/s  ·  3.4MB/8.0MB」：
   * 百分比给整体感，速度给「是不是卡住了」的判断依据，两个体积给精确进度。
   * 速度缺失（刚开始的 1s 内 / 已断流归零）时该段自动省略，不留空占位。
   */
  private statusText(t: DownloadTask): string {
    switch (t.status) {
      case DownloadStatus.DOWNLOADING: {
        // 速度/体积同样读镜像：每份快照都刷新，不再随 5% 分桶冻结后突跳
        const tracked: boolean = this.animTaskId === t.id;
        const speed: number = tracked ? this.animSpeed : t.speed;
        const bytes: number = tracked ? this.animBytes : t.downloadedBytes;
        const parts: string[] = [];
        parts.push(t.totalBytes > 0 ? `下载中 ${Math.floor(this.percent(t))}%` : '下载中');
        if (speed > 0) {
          parts.push(speedText(speed));
        }
        if (t.totalBytes > 0) {
          parts.push(`${mbText(bytes)}/${mbText(t.totalBytes)}`);
        } else if (bytes > 0) {
          parts.push(`已下载 ${mbText(bytes)}`);
        }
        return parts.join('  ·  ');
      }
      case DownloadStatus.COMPLETED: {
        const parts: string[] = ['已完成'];
        const q: string = this.qualityText(t);
        if (q.length > 0) {
          parts.push(q);
        }
        if (t.totalBytes > 0) {
          parts.push(mbText(t.totalBytes));
        }
        return parts.join('  ·  ');
      }
      case DownloadStatus.ERROR:
        return t.errorMessage.length > 0 ? t.errorMessage : '下载失败';
      case DownloadStatus.PENDING:
        return this.queuePaused ? '排队中…（已暂停）' : '排队中…';
      case DownloadStatus.PAUSED:
        // 暂停时把已下到哪儿也说出来，用户才知道「继续」是从这儿接着走的
        return t.totalBytes > 0
          ? `已暂停  ${this.percent(t)}%  ·  ${mbText(t.downloadedBytes)}/${mbText(t.totalBytes)}`
          : '已暂停';
      default:
        return '';
    }
  }

  private isCurrent(t: DownloadTask): boolean {
    const cur: Track | null = this.currentTrack;
    if (!cur) {
      return false;
    }
    return cur.id === (t.musicId.length > 0 ? t.musicId : t.id);
  }

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  /**
   * ForEach 的 key。**只编入不靠镜像/局部状态刷新的变化** —— 理由见文件头注释。
   *   · status：任何状态迁移都要重建（文案/结构全变）；
   *   · hasTotal：totalBytes 未知→已知切换「不确定进度环 ↔ 进度条」结构分支；
   *   · bucket：**仅未被镜像接管的下载行**编入 5% 分桶兜底；镜像行若也编入，
   *     每 5% 一次的重建会把进度条打回目标值，animateTo 就断了。
   * 选择模式（selecting / 选中态）刻意不进 key：多选进出要对保留节点做
   * 槽位展开动画（见 TaskRow），选中 ✓ 由保留节点读 @State selectedIds 局部刷新。
   */
  private rowKey(t: DownloadTask): string {
    const tracked: boolean = this.animTaskId === t.id && t.status === DownloadStatus.DOWNLOADING;
    const bucket: number = !tracked && t.status === DownloadStatus.DOWNLOADING
      ? Math.floor(this.percent(t) / 5) : 0;
    const hasTotal: number = t.totalBytes > 0 ? 1 : 0;
    return `${t.id}|${t.status}|${hasTotal}${bucket}`;
  }

  /**
   * 行标题展示（2026-10-08）：合集子行带 P 序号前缀，展开后一眼看出「第几个分 P」；
   * 普通行 / 老任务（无序号标记）原样显示。序号随任务不变，无需进 rowKey。
   */
  private taskTitleText(t: DownloadTask, nested: boolean): string {
    if (nested && t.partTotal > 1 && t.partNo > 0) {
      return `P${t.partNo} · ${t.title}`;
    }
    return t.title;
  }

  // ===== 合集（多 P）分组 =====

  /**
   * 推导一条任务所属的分组键。
   *
   * 分 P 任务由 expandVideoParts 展开，musicId 形如 `BV1xx…#cid`（首个分 P 复用
   * 原条目 id，即纯 bvid）。因此：BV 开头的 musicId 取 `#` 前的 bvid 归组；
   * 音乐中心那类音乐 id 一条任务自成一组，用任务 id 保证绝不与别人合并。
   * 单 P 视频的组里只有它自己，渲染上与普通行完全一致（见 buildGroups 后的分支）。
   */
  private groupKeyOf(t: DownloadTask): string {
    // ⚠️ 歌单组**优先级最高**：整单下载的曲目既可能与别人同 bvid（不会），
    // 也可能自身是分 P（会），但只要带 playlistId 就必须按歌单归组 ——
    // 用户看到的是「一张歌单卡片」，不是一堆单曲行。
    if (t.playlistId.length > 0) {
      return `pl:${t.playlistId}`;
    }
    const mid: string = t.musicId.length > 0 ? t.musicId : t.id;
    if (mid.indexOf('BV') === 0) {
      const hash: number = mid.indexOf('#');
      return hash > 0 ? mid.substring(0, hash) : mid;
    }
    return t.id;
  }

  /**
   * 组内第一个非空的合集标题（2026-10-08）。多 P 任务入库时每条都带同一份
   * collectionTitle，取第一个即可；老任务（无该字段）返回空串。
   */
  private collectionTitleOf(g: DownloadGroup): string {
    for (let i = 0; i < g.tasks.length; i++) {
      const ct: string = g.tasks[i].collectionTitle;
      if (ct.length > 0) {
        return ct;
      }
    }
    return '';
  }

  /**
   * 是否是合集（多 P）组（2026-10-08）。
   *
   * 新任务看显式 `partTotal > 1` 标记；兼容升级前的在途/历史任务——
   * BV 键 + 组内多条也按合集处理（旧推导方式兜底）。
   * 歌单组（`pl:` 键）不算：它的聚合语义是「歌单卡片」，不是分 P 合集。
   * **组内仅剩 1 条的合集也返回 true**：渲染分支用它判定组头，
   * 避免合集删到只剩一首后退化和普通行无法区分（用户 2026-10-08 的诉求）。
   *
   * 2026-10-08 卡顿优化：本方法含全组 some()，**只允许 buildGroups 归组时调用**
   * （结果缓存进 g.isCollection）；渲染热路径一律读缓存，别再直接调这里。
   */
  private isCollectionGroup(g: DownloadGroup): boolean {
    if (g.key.indexOf('pl:') === 0) {
      return false;
    }
    if (g.tasks.length > 1) {
      return true;
    }
    return g.tasks.some((t: DownloadTask): boolean => t.partTotal > 1);
  }

  /**
   * 歌单组（`pl:` 键）显示修复（2026-10-21）：批量下载的歌单此前只渲染组内
   * 第一首的普通行（isCollectionGroup 对 pl: 组返回 false，渲染分支因此跳过
   * 组头），其余 N-1 首歌在下载页完全不可见，且歌单组行与单曲行视觉无法区分。
   * 组内 >1 条时渲染为带组头的歌单卡片（标题=歌单名、徽标「歌单」、可展开子行）；
   * 只剩 1 条（单曲下载同样携带 playlistId、或批量删剩一首）退回普通行，
   * 保持单曲下载的既有观感。
   */
  private isPlaylistCard(g: DownloadGroup): boolean {
    return g.key.indexOf('pl:') === 0 && g.tasks.length > 1;
  }

  /**
   * 把扁平任务表归成分组视图。
   * 组内按创建时间升序（= 分 P 排队顺序）；组间按组内最新任务的创建时间降序，
   * 与原列表「新在前」的观感保持一致。
   */
  private buildGroups(): DownloadGroup[] {
    const map: Map<string, DownloadGroup> = new Map<string, DownloadGroup>();
    for (let i = 0; i < this.tasks.length; i++) {
      const t: DownloadTask = this.tasks[i];
      const key: string = this.groupKeyOf(t);
      let g: DownloadGroup | undefined = map.get(key);
      if (g === undefined) {
        // 占位派生字段（counts/isCollection）：map.forEach 里逐组重算覆盖。
        // 对象字面量必须补全这两个字段 —— DownloadGroup 已把它们改成必填。
        const created: DownloadGroup = {
          key: key,
          title: '',
          coverUrl: '',
          tasks: [],
          counts: { done: 0, downloading: 0, pending: 0, paused: 0, failed: 0 },
          isCollection: false
        };
        map.set(key, created);
        g = created;
      }
      g.tasks.push(t);
    }
    const groups: DownloadGroup[] = [];
    map.forEach((g: DownloadGroup): void => {
      g.tasks.sort((a: DownloadTask, b: DownloadTask): number => a.createdAt - b.createdAt);
      const head: DownloadTask = g.tasks[0];
      // 歌单组的标题用**歌单名**（组头要能一眼看出是哪张歌单，而不是组内第一首歌名）；
      // 合集组优先用显式 collectionTitle（2026-10-08）——此前依赖「首条任务标题恰为
      // 合集标题」的隐式约定，首 P 被删后组标题就退化成分 P 名；老任务无字段时回退旧约定。
      const collectionTitle: string = this.collectionTitleOf(g);
      g.title = head.playlistName.length > 0
        ? head.playlistName
        : (collectionTitle.length > 0 ? collectionTitle : head.title);
      g.coverUrl = head.coverUrl;
      // 派生字段缓存（2026-10-08 卡顿优化）：每份快照每组各算一次，
      // 渲染热路径（组头文案 / key 生成 / 渲染分支）全部改读缓存，O(组大小) → O(1)。
      // 值与旧实现（countGroup/isCollectionGroup 逐次现算）完全一致。
      g.counts = this.countGroup(g);
      g.isCollection = this.isCollectionGroup(g);
      groups.push(g);
    });
    groups.sort((a: DownloadGroup, b: DownloadGroup): number => {
      const la: number = a.tasks[a.tasks.length - 1].createdAt;
      const lb: number = b.tasks[b.tasks.length - 1].createdAt;
      return lb - la;
    });
    return groups;
  }

  /** 分组缓存唯一写入口：aboutToAppear 初始化 + onTasksSnapshot 每次快照重算 */
  private rebuildGroups(): void {
    this.groups = this.buildGroups();
  }

  /**
   * 组内各状态计数。2026-10-08 卡顿优化后**只允许 buildGroups 归组时调用**
   * （结果缓存进 g.counts）；渲染热路径读缓存，别再直接调这里。
   */
  private countGroup(g: DownloadGroup): GroupCounts {
    const c: GroupCounts = { done: 0, downloading: 0, pending: 0, paused: 0, failed: 0 };
    for (let i = 0; i < g.tasks.length; i++) {
      switch (g.tasks[i].status) {
        case DownloadStatus.COMPLETED:
          c.done += 1;
          break;
        case DownloadStatus.DOWNLOADING:
          c.downloading += 1;
          break;
        case DownloadStatus.PENDING:
          c.pending += 1;
          break;
        case DownloadStatus.PAUSED:
          c.paused += 1;
          break;
        case DownloadStatus.ERROR:
          c.failed += 1;
          break;
        default:
          break;
      }
    }
    return c;
  }

  /** 整组进度（0~100）。任何一条的总大小未知时返回 -1（界面据此显示不确定态） */
  private groupPercent(g: DownloadGroup): number {
    // 镜像接管的在传分组：返回连续浮点，进度条由 animateTo 插值平滑推进
    if (this.animGroupKey === g.key) {
      return this.animGroupPercent;
    }
    let doneBytes: number = 0;
    let totalBytes: number = 0;
    for (let i = 0; i < g.tasks.length; i++) {
      doneBytes += g.tasks[i].downloadedBytes;
      totalBytes += g.tasks[i].totalBytes;
    }
    if (totalBytes <= 0) {
      return -1;
    }
    const p: number = Math.floor((doneBytes / totalBytes) * 100);
    return p > 100 ? 100 : p;
  }

  /** 整组实时速度 = 各分 P 速度之和（串行队列里同时最多一条在传，求和即为兼容并发而写） */
  private groupSpeed(g: DownloadGroup): number {
    if (this.animGroupKey === g.key) {
      return this.animGroupSpeed;
    }
    let sum: number = 0;
    for (let i = 0; i < g.tasks.length; i++) {
      sum += g.tasks[i].speed;
    }
    return sum;
  }

  private groupStatusText(g: DownloadGroup): string {
    // 2026-10-08 卡顿优化：counts / isCollection 全部读 buildGroups
    // 归组时的缓存值（与旧实现逐次现算的输出一致），组头文案不再全组遍历。
    const c: GroupCounts = g.counts;
    const total: number = g.tasks.length;
    // 合集组前缀「N 个分P」（2026-10-08）：与单视频条目拉开区分，折叠态一眼可见规模。
    // N = 组内剩余任务数（2026-10-19）：此前用 partTotal（任务携带的合集原始分 P 数），
    // 删除 1P / 多P 后永远显示原值，「剩余 P 数」不刷新；改用组内任务数后与下方
    // 「已下载 x/N」的 N 同源，删除后随快照立刻变小（tasks.length 在 groupRowKey 里）。
    // 歌单卡片（2026-10-21 显示修复）同位前缀「N 首」。
    const prefix: string = g.isCollection
      ? `${total} 个分P  ·  `
      : (this.isPlaylistCard(g) ? `${total} 首  ·  ` : '');
    if (c.done === total) {
      return `${prefix}已完成 · 共 ${total} 首`;
    }
    const parts: string[] = [];
    if (c.downloading > 0) {
      // 镜像接管时为连续浮点，展示取整
      const p: number = this.groupPercent(g);
      parts.push(p >= 0 ? `下载中 ${Math.floor(p)}%` : '下载中');
      const sp: number = this.groupSpeed(g);
      if (sp > 0) {
        parts.push(speedText(sp));
      }
    } else if (c.pending > 0) {
      parts.push(this.queuePaused ? '排队中…（已暂停）' : '排队中…');
    } else if (c.paused > 0) {
      const p: number = this.groupPercent(g);
      parts.push(p >= 0 ? `已暂停 ${p}%` : '已暂停');
    }
    parts.push(`已下载 ${c.done}/${total}`);
    if (c.failed > 0) {
      parts.push(`${c.failed} 首失败`);
    }
    return prefix + parts.join('  ·  ');
  }

  /**
   * 分组行的 ForEach key。与 rowKey 同理（见文件头注释）：只编入不靠镜像/局部状态
   * 刷新的变化 —— 状态计数、任务数、总大小未知→已知、展开态。
   * bucket 仅未接管的分组编入；选择模式刻意不进 key（见 rowKey）。
   */
  private groupRowKey(g: DownloadGroup): string {
    // 2026-10-08 卡顿优化：counts 读归组缓存 —— 值与旧 countGroup(g) 完全一致，
    // key 串逐字节不变，保留节点行为不受本次优化影响。
    const c: GroupCounts = g.counts;
    const tracked: boolean = this.animGroupKey === g.key && c.downloading > 0;
    const pct: number = this.groupPercent(g);
    const hasTotal: number = pct >= 0 ? 1 : 0;
    const bucket: number = tracked ? 0 : (hasTotal ? Math.floor(pct / 5) : 0);
    const expanded: number = this.isExpanded(g.key) ? 1 : 0;
    return `${g.key}|${g.tasks.length}|${c.done},${c.downloading},${c.pending},${c.paused},${c.failed}|${hasTotal}${bucket}|${expanded}`;
  }

  private isExpanded(key: string): boolean {
    return this.expandedGroups.indexOf(key) >= 0;
  }

  private toggleGroup(key: string): void {
    if (this.isExpanded(key)) {
      this.expandedGroups = this.expandedGroups.filter((k: string): boolean => k !== key);
    } else {
      this.expandedGroups = [...this.expandedGroups, key];
    }
  }

  private groupTaskIds(g: DownloadGroup): string[] {
    return g.tasks.map((t: DownloadTask): string => t.id);
  }

  private isGroupSelected(g: DownloadGroup): boolean {
    return g.tasks.every((t: DownloadTask): boolean => this.isSelected(t.id));
  }

  /** 选择模式下点组头：整组全选 / 整组取消，子行仍可单独微调 */
  private toggleSelectGroup(g: DownloadGroup): void {
    const ids: string[] = this.groupTaskIds(g);
    if (this.isGroupSelected(g)) {
      this.selectedIds = this.selectedIds.filter((id: string): boolean => ids.indexOf(id) < 0);
      return;
    }
    const merged: string[] = [...this.selectedIds];
    for (let i = 0; i < ids.length; i++) {
      if (merged.indexOf(ids[i]) < 0) {
        merged.push(ids[i]);
      }
    }
    this.selectedIds = merged;
  }

  /**
   * 把一条已下载任务转成可播放曲目。
   *
   * 关键是带上 `localFilePath` —— 播放内核看到它就完全跳过音源解析，直接播沙箱文件
   * （断网也能放）。id 用 musicId 而不是任务 id，这样行上的「正在播放」标记、
   * 以及播放页显示的曲目都和下载条目的音乐身份对得上。
   */
  private toLocalTrack(t: DownloadTask): Track {
    return buildTrack({
      id: t.musicId.length > 0 ? t.musicId : t.id,
      title: t.title,
      artist: t.artist,
      coverUrl: t.coverUrl,
      localFilePath: t.localFilePath
    });
  }

  /** 点击已完成的条目：以「这首打头、其余已下载的跟在后面」组成队列播放 */
  private play(t: DownloadTask): void {
    // 点的就是当前曲目：切换播放/暂停（播放中→暂停，暂停中→续播），
    // 与其它列表页 playOrToggle 的语义一致；不重建队列从头重播。
    // isCurrent 与「正在播放」徽标同一套 id 映射（musicId 优先、回落任务 id）。
    if (this.isCurrent(t)) {
      MusicPlayer.getInstance().togglePlay();
      return;
    }
    const done: DownloadTask[] = this.tasks.filter(
      (x: DownloadTask): boolean =>
        x.status === DownloadStatus.COMPLETED && x.localFilePath.length > 0
    );
    if (done.length === 0) {
      return;
    }
    const list: Track[] = [this.toLocalTrack(t)];
    for (let i = 0; i < done.length; i++) {
      if (done[i].id !== t.id) {
        list.push(this.toLocalTrack(done[i]));
      }
    }
    MusicPlayer.getInstance().playAll(list);
  }

  private deleteFile(t: DownloadTask): void {
    if (t.localFilePath && t.localFilePath.length > 0) {
      // （2026-10-16 AppFreeze 加固）unlinkSync → 异步 unlink，不阻塞主线程
      fs.unlink(t.localFilePath).catch((): void => {
        // 文件可能已不存在，忽略
      });
    }
  }

  private remove(t: DownloadTask): void {
    DownloadManager.getInstance().removeTask(t.id).catch((e: Error): void => {
      console.error(`remove download failed: ${JSON.stringify(e)}`);
    });
    this.deleteFile(t);
    this.toast(`已删除「${t.title}」`, 1200);
  }

  /** 删除前二次确认（整组）：一次删掉合集下的全部分 P 任务 / 整张歌单的全部曲目与文件 */
  private confirmRemoveGroup(g: DownloadGroup): void {
    const isPlaylist: boolean = g.tasks[0].playlistId.length > 0;
    showAppAlertDialog(this.getUIContext(), {
      title: isPlaylist ? '删除歌单下载' : '删除合集下载',
      message: isPlaylist
        ? `确定删除「${g.title}」下载的全部 ${g.tasks.length} 首吗？已下载的音频文件也会一并移除。`
        : `确定删除「${g.title}」下的 ${g.tasks.length} 个分 P 任务吗？已下载的音频文件也会一并移除。`,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          this.removeGroup(g);
        }
      }
    });
  }

  private removeGroup(g: DownloadGroup): void {
    const ids: string[] = this.groupTaskIds(g);
    // 先删文件：任务快照里有 localFilePath，删完库记录就拿不到了
    for (let i = 0; i < g.tasks.length; i++) {
      this.deleteFile(g.tasks[i]);
    }
    DownloadManager.getInstance().removeTasks(ids).catch((e: Error): void => {
      console.error(`remove downloads failed: ${JSON.stringify(e)}`);
    });
    // 收起该组的展开态，避免残留一个指向空组的记录
    this.expandedGroups = this.expandedGroups.filter((k: string): boolean => k !== g.key);
    this.toast(`已删除「${g.title}」的 ${ids.length} 个任务`, 1200);
  }

  /** 统一 Toast 封装：与设置 / 搜索等页保持同一套回执通道（规范 5.2）。 */
  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /** 删除前二次确认：避免误触把已下载的音频一并删掉。 */
  private confirmRemove(t: DownloadTask): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '删除下载',
      message: `确定删除「${t.title}」吗？已下载的音频文件也会一并移除。`,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          this.remove(t);
        }
      }
    });
  }

  // ===== 条目「⋯」菜单（2026-10-23，与歌单详情页同一套交互） =====

  /** 从任务反推 bvid：musicId 形如 `BV1xx…`（单视频）/ `BV1xx…#cid`（分 P）；非 BV（音乐中心）返回空串 */
  private bvidOfTask(t: DownloadTask): string {
    const rawId: string = t.musicId.length > 0 ? t.musicId : t.id;
    if (rawId.indexOf('BV') !== 0) {
      return '';
    }
    const hash: number = rawId.indexOf('#');
    return hash > 0 ? rawId.substring(0, hash) : rawId;
  }

  /**
   * 菜单动作用 Track（加入队列 / 加入歌单共用）。刻意**不带 localFilePath**：
   * 播放层已有「本地优先」（MusicPlayer.loadAndPlay 按 track.id 查
   * completedLocalPath，命中直接播沙箱文件）—— 带上反而会在下载被删后残留
   * 脏路径（localFilePath 非空直接走本地分支、不再回在线解析）。
   * id = musicId，与 completedLocalPath 的 musicId 精确匹配同源。
   */
  private toMenuTrack(t: DownloadTask): Track {
    const rawId: string = t.musicId.length > 0 ? t.musicId : t.id;
    const hash: number = rawId.indexOf('#');
    return buildTrack({
      id: rawId,
      bvid: hash > 0 ? rawId.substring(0, hash) : rawId,
      cid: hash > 0 ? rawId.substring(hash + 1) : '',
      title: t.title,
      artist: t.artist,
      coverUrl: t.coverUrl
    });
  }

  /**
   * 「进入 UP 主页」：bvid → getVideoDetail（带 viewCache，TTL 内不重复请求）
   * → owner.mid → push UpSpace（PlaylistDetail.openUpSpace 同款）。
   * 音乐中心条目（musicId 非 BV）没有 UP 信息，toast 后返回。
   */
  private async openUpSpaceFromTask(t: DownloadTask): Promise<void> {
    const bvid: string = this.bvidOfTask(t);
    if (bvid.length === 0) {
      this.toast('这条没有 UP 主信息', 1500);
      return;
    }
    this.toast('正在获取投稿作者…', 1200);
    let mid: string = '';
    try {
      const detail: VideoDetail = await BilibiliApi.getVideoDetail(bvid);
      mid = detail.owner ? String(detail.owner.mid) : '';
    } catch (e) {
      console.error(`openUpSpace resolve mid failed: ${JSON.stringify(e)}`);
    }
    if (mid.length === 0) {
      this.toast('获取 UP 主失败', 1500);
      return;
    }
    NavStackHolder.stack.pushPathByName('UpSpace', new UpSpaceRouteParam(mid, t.artist, ''));
  }

  /** 单条「加入队列」：菜单恒显，未下载完成点选时 toast 拦截（宁可无反应也不播半截文件） */
  private addToQueueFromTask(t: DownloadTask): void {
    if (t.status !== DownloadStatus.COMPLETED || t.localFilePath.length === 0) {
      this.toast('这首歌还没下载完成', 1500);
      return;
    }
    MusicPlayer.getInstance().addToQueue(this.toMenuTrack(t));
    this.toast('已加入播放队列', 1500);
  }

  /** 组头「加入队列」：组内全部已完成任务入队；一首都没有则拦截 */
  private addToQueueFromGroup(g: DownloadGroup): void {
    const done: DownloadTask[] = g.tasks.filter((x: DownloadTask): boolean =>
      x.status === DownloadStatus.COMPLETED && x.localFilePath.length > 0);
    if (done.length === 0) {
      this.toast('组内还没有下载完成的条目', 1500);
      return;
    }
    for (let i = 0; i < done.length; i++) {
      MusicPlayer.getInstance().addToQueue(this.toMenuTrack(done[i]));
    }
    this.toast(done.length > 1 ? `已加入播放队列 ${done.length} 首` : '已加入播放队列', 1500);
  }

  /** 单曲行 / 分 P 子行「⋯」菜单（顺序纪律：破坏性的删除放最后） */
  private taskMenuItems(t: DownloadTask): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.addToQueueFromTask(t);
        }
      },
      {
        value: '加入歌单',
        action: (): void => {
          this.openPicker([this.toMenuTrack(t)]);
        }
      },
      {
        value: '进入 UP 主页',
        action: (): void => {
          this.openUpSpaceFromTask(t);
        }
      },
      {
        // 2026-10-24 导出：未完成点选时 toast 拦截（与「加入队列」同款恒显模式）
        value: '导出到文件管理',
        action: (): void => {
          this.exportDownloaded([t]);
        }
      },
      {
        value: '删除',
        action: (): void => {
          this.confirmRemove(t);
        }
      }
    ];
  }

  /** 组头「⋯」菜单：加入队列取组内已完成、加入歌单收组内全部、UP 主页取第一首、导出取组内已完成、删除 = 整组（沿用二次确认） */
  private groupMenuItems(g: DownloadGroup): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.addToQueueFromGroup(g);
        }
      },
      {
        value: '加入歌单',
        action: (): void => {
          this.openPicker(g.tasks.map((x: DownloadTask): Track => this.toMenuTrack(x)));
        }
      },
      {
        value: '进入 UP 主页',
        action: (): void => {
          this.openUpSpaceFromTask(g.tasks[0]);
        }
      },
      {
        // 2026-10-24 导出：组内已完成条目批量导出（导出模块自动过滤未完成）
        value: '导出已完成',
        action: (): void => {
          this.exportDownloaded(g.tasks);
        }
      },
      {
        value: '删除',
        action: (): void => {
          this.confirmRemoveGroup(g);
        }
      }
    ];
  }

  // ===== 导出到系统文件管理（2026-10-24：下载格式 m4a/flac 正确化 + 文件管理器可见）=====

  /** 导出互斥：系统保存对话框全屏独占，双击入口拉起两个对话框会把结果串台 */
  private exporting: boolean = false;

  /** 多选工具条「导出选中」：把选区任务交给导出流程 */
  private exportSelected(): void {
    const selected: DownloadTask[] =
      this.tasks.filter((t: DownloadTask): boolean => this.selectedIds.indexOf(t.id) >= 0);
    this.exportDownloaded(selected);
  }

  /**
   * 批量导出已完成任务到系统文件管理。
   *
   * 经 AudioViewPicker 拉起系统保存对话框（免权限），用户确认位置后由
   * AudioExporter 复制沙箱文件过去；命名 `歌名 - 歌手.flac/.m4a/.mp3`
   * （扩展名按任务实际音质派生）。结果 toast：取消静默、无可导出项提示、
   * 成功报数量（含失败数时附带）。
   */
  private exportDownloaded(tasks: DownloadTask[]): void {
    if (this.exporting) {
      return;
    }
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.exporting = true;
    exportTasks(ctx, tasks)
      .then((result: ExportResult): void => {
        if (result.cancelled) {
          // 用户在系统对话框取消：静默返回
          return;
        }
        if (result.nothingToDo) {
          this.toast('还没有下载完成的歌曲', 1500);
          return;
        }
        const suffix: string = result.failed > 0 ? `，${result.failed} 首失败` : '';
        this.toast(`已导出 ${result.ok} 首，可在「文件管理」查看${suffix}`, 2400);
      })
      .catch((e: Error): void => {
        console.error(`export failed: ${e.message}`);
        this.toast('导出失败', 1500);
      })
      .finally((): void => {
        this.exporting = false;
      });
  }

  // ===== 加入歌单（WatchHistoryPage 同款：无歌单自动建单兜底 + 选择弹层；多曲批量走 addTracksToPlaylist） =====

  /** 没有任何歌单时的兜底：新建歌单并直接加入（名字取自第一首） */
  private createPlaylistAndAdd(tracks: Track[], existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(tracks[0], existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTracksToPlaylist(created.id, tracks);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  /** 打开「加入歌单」选择弹层；已有歌单列表为空时跳过弹层直接自动建单 */
  private openPicker(tracks: Track[]): void {
    if (tracks.length === 0) {
      return;
    }
    const options: Playlist[] = LibraryStore.getPlaylists();
    if (options.length === 0) {
      this.createPlaylistAndAdd(tracks, options);
      return;
    }
    this.playlistOptions = options;
    this.pickerTracks = tracks;
    this.showPlaylistPicker = true;
  }

  /** 弹层里的「新建歌单并加入」：省掉一次跳转（快照沿用弹层打开时的列表，重名检查基于它即可） */
  private createPlaylistFromPicker(): void {
    const tracks: Track[] = this.pickerTracks;
    const options: Playlist[] = this.playlistOptions;
    this.dismissPicker();
    if (tracks.length > 0) {
      this.createPlaylistAndAdd(tracks, options);
    }
  }

  private addToPlaylistFromPicker(p: Playlist): void {
    const tracks: Track[] = this.pickerTracks;
    this.dismissPicker();
    if (tracks.length === 0) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTracksToPlaylist(p.id, tracks);
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  private dismissPicker(): void {
    this.showPlaylistPicker = false;
    this.pickerTracks = [];
  }

  /**
   * 多选工具条「加入歌单」：选区任务转 Track（组头菜单同款配方，不过滤下载状态 ——
   * 加歌单只是元数据，不依赖本地文件）后开「加入歌单」选择弹层。
   * 加入后保持多选态与选区不变：用户可再点一次连加到多个歌单。
   */
  private addSelectedToPlaylist(): void {
    if (this.selectedIds.length === 0) {
      this.toast('还没有选中条目', 1500);
      return;
    }
    const tracks: Track[] = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      // taskById 取不到 = 快照与内存表刚好错开一拍（点击瞬间被删），跳过即可
      const t: DownloadTask | undefined = this.taskById(this.selectedIds[i]);
      if (t !== undefined) {
        tracks.push(this.toMenuTrack(t));
      }
    }
    this.openPicker(tracks);
  }

  /**
   * 重试一批失败任务（单条 / 整组 / 多选都走这里）。
   *
   * 只对 **FAILED** 的条目生效：正常进行中 / 已完成的传进来会被 `retryTasks` 跳过，
   * 所以外层不必先过滤一遍（少一处判断就少一处不一致）。
   *
   * 「仅 WiFi 下载」被拦时照样**只问一次**，用户同意后整批以 override 重跑
   * （与歌单整单下载同一套做法，见 PlaylistsPage.enqueuePlaylist）。
   */
  private retryFailed(ids: string[]): void {
    if (this.retrying) {
      // 2026-10-23 审查修复：此前静默 return，连点没有任何反馈
      this.toast('正在重试，请稍候', 1200);
      return;
    }
    if (ids.length === 0) {
      this.toast('没有失败的任务', 1500);
      return;
    }
    this.retrying = true;
    DownloadManager.getInstance().retryTasks(ids, false)
      .then((r: DownloadStartResult): void => {
        if (r.blockedReason.length > 0) {
          // 2026-10-23 审查修复：弹窗是 autoCancel，点遮罩/返回键关闭不触发任何
          // 按钮回调 → retrying 永久卡 true。先释放再弹：retrying 只表达「网络
          // 请求在途」，弹窗等待期不该占用（真正的重试请求由弹窗按钮再次置起）。
          this.retrying = false;
          this.confirmRetryOnCellular(ids);
          return;
        }
        this.retrying = false;
        this.toast(this.retryResultText(r), 2000);
      })
      .catch((e: Error): void => {
        this.retrying = false;
        console.error(`retry failed: ${e.message}`);
        this.toast('重试失败，请稍后再试', 1800);
      });
  }

  /** 「仅 WiFi 下载」拦下时的批量重试询问（整批放行，不逐条问） */
  private confirmRetryOnCellular(ids: string[]): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n继续会使用移动数据重试这 ${ids.length} 个失败任务。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
          // retrying 已在弹窗前释放，这里无需再动
        }
      },
      secondaryButton: {
        value: '继续重试',
        action: (): void => {
          // retrying 语义 = 「重试网络请求在途」：真正发请求前重新置起，
          // 弹窗等待期不占用（见 retryFailed 里 blocked 分支的说明）
          this.retrying = true;
          DownloadManager.getInstance().retryTasks(ids, true)
            .then((r: DownloadStartResult): void => {
              this.retrying = false;
              this.toast(this.retryResultText(r), 2000);
            })
            .catch((e: Error): void => {
              this.retrying = false;
              console.error(`retry(ignoreWifiLimit) failed: ${e.message}`);
              this.toast('重试失败，请稍后再试', 1800);
            });
        }
      }
    });
  }

  private retryResultText(r: DownloadStartResult): string {
    if (r.queued === 0 && r.skipped === 0) {
      return '没有可重试的任务';
    }
    if (r.queued === 0) {
      return '选中的任务都不是失败状态';
    }
    const tail: string = r.skipped > 0 ? `，跳过 ${r.skipped} 个非失败任务` : '';
    return `已重新加入队列 ${r.queued} 个${tail}`;
  }

  /** 组内失败项的 id 列表（组级「重试」传参）；计数走 g.counts.failed，这里只负责收集 id */
  private groupFailedIds(g: DownloadGroup): string[] {
    const out: string[] = [];
    for (let i = 0; i < g.tasks.length; i++) {
      if (g.tasks[i].status === DownloadStatus.ERROR) {
        out.push(g.tasks[i].id);
      }
    }
    return out;
  }

  /** 按 id 取任务（取不到返回 undefined —— 快照与内存表可能刚好错开一拍） */
  private taskById(id: string): DownloadTask | undefined {
    return this.tasks.find((t: DownloadTask): boolean => t.id === id);
  }

  /** 选区里是否有失败任务（决定「重试选中」是否可用；空选区为 false） */
  private canRetrySelected(): boolean {
    return this.selectedIds.some((id: string): boolean => {
      const t: DownloadTask | undefined = this.taskById(id);
      return t !== undefined && t.status === DownloadStatus.ERROR;
    });
  }

  private confirmRemoveSelected(): void {
    const count: number = this.selectedIds.length;
    if (count === 0) {
      return;
    }
    showAppAlertDialog(this.getUIContext(), {
      title: '删除下载',
      message: `确定删除选中的 ${count} 个任务吗？已下载的音频文件也会一并移除。`,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          this.removeSelected();
        }
      }
    });
  }

  private removeSelected(): void {
    const ids: string[] = this.selectedIds.slice();
    // 先删文件：任务快照里有 localFilePath，删完库记录就拿不到了
    for (let i = 0; i < this.tasks.length; i++) {
      if (ids.indexOf(this.tasks[i].id) >= 0) {
        this.deleteFile(this.tasks[i]);
      }
    }
    DownloadManager.getInstance().removeTasks(ids).catch((e: Error): void => {
      console.error(`remove downloads failed: ${JSON.stringify(e)}`);
    });
    this.selectedIds = [];
    this.selecting = false;
    this.toast(`已删除 ${ids.length} 个任务`, 1200);
  }

  private toggleSelecting(): void {
    this.selecting = !this.selecting;
    this.selectedIds = [];
  }

  private toggleSelect(id: string): void {
    if (this.isSelected(id)) {
      this.selectedIds = this.selectedIds.filter((x: string): boolean => x !== id);
    } else {
      this.selectedIds = [...this.selectedIds, id];
    }
  }

  private allSelected(): boolean {
    return this.tasks.length > 0 && this.selectedIds.length >= this.tasks.length;
  }

  private toggleSelectAll(): void {
    if (this.allSelected()) {
      this.selectedIds = [];
      return;
    }
    const all: string[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      all.push(this.tasks[i].id);
    }
    this.selectedIds = all;
  }

  private pauseAll(): void {
    DownloadManager.getInstance().pauseAll().catch((e: Error): void => {
      console.error(`pause downloads failed: ${JSON.stringify(e)}`);
    });
  }

  private resumeAll(): void {
    DownloadManager.getInstance().resumeAll().catch((e: Error): void => {
      console.error(`resume downloads failed: ${JSON.stringify(e)}`);
    });
  }

  /**
   * 单条暂停（下载页点「下载中 / 排队中」的行）。
   * 与「全部暂停」共用内核收尾路径：正在传输的那条会被中止并保留半截文件，
   * 恢复时断点续传，不会白下已经拿到的那部分。
   */
  private pauseOne(t: DownloadTask): void {
    DownloadManager.getInstance().pauseTask(t.id).catch((e: Error): void => {
      console.error(`pause download failed: ${JSON.stringify(e)}`);
    });
  }

  /** 单条恢复（点「已暂停」的行）：队列里那条还在（带 Track），直接接着跑 */
  private resumeOne(t: DownloadTask): void {
    DownloadManager.getInstance().resumeTask(t.id).catch((e: Error): void => {
      console.error(`resume download failed: ${JSON.stringify(e)}`);
    });
  }

  /**
   * 单条任务行。
   * @param nested true = 合集展开后的分 P 子行：左侧缩进一级，与组头形成从属关系
   */
  @Builder
  TaskRow(t: DownloadTask, nested: boolean): void {
    Row() {
      // 常驻复选框槽位：进出多选的动画位。绝不能用 if(selecting) 条件挂载 ——
      // 节点增删没有过渡；改为槽位 width 0↔44 的布局动画（行内容随之右移/回位），
      // 复选框本体叠 translate 从右侧滑入，clip 保证槽位收拢时内容不外溢。
      // 阶段 5（2026-10-11）：自绘「✓ 圆圈」换成系统标准 Checkbox（圆形选中圈）。
      Row() {
        Checkbox({ name: t.id, group: 'dlSelect' })
          .select(this.isSelected(t.id))
          .selectedColor(this.themePrimary)
          .unselectedColor($r('app.color.text_disabled'))
          .shape(CheckBoxShape.CIRCLE)
          .width(20)
          .height(20)
          .translate({ x: this.selecting ? 0 : SELECT_SLOT_VP })
          .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })
          // 选中态指示是装饰：切换入口是整行点击，别让空勾选框占一个读屏焦点，
          // 也不让它吃掉整行的点击
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
      }
      .width(this.selecting ? SELECT_SLOT_VP : 0)
      .height(20)
      .clip(true)
      .justifyContent(FlexAlign.Center)
      .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })

      // 64vp 显示位按 2x 请求缩略图（双行标题改版 2026-10-21 与 TrackItem 同步：
      // 封面 56→64，高度预算 = 标题两行 lineHeight(21)×2 + 间距 4 + 状态行 17 = 63 ≤ 64）；
      // 加载中 / 失败由 CoverImage 兜浅粉占位
      CoverImage({
        url: toThumbUrl(t.coverUrl, 128),
        imgWidth: 64,
        imgHeight: 64,
        imgRadius: 8,
        altText: t.title
      })

      Column() {
        Row() {
          // 合集子行带 P 序号前缀（见 taskTitleText）：与组头徽标一起构成「合集」的显式区分
          // 标题双行显示（2026-10-21 与 TrackItem 同步）：maxLines(2) + 第二行省略号；
          // 显式 lineHeight(21) 锁行高（默认随字体浮动会破坏「信息 ≤ 封面」硬预算）。
          Text(this.taskTitleText(t, nested))
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(21)
            .layoutWeight(1)
          if (this.isCurrent(t)) {
            // 阶段 5：小字徽标改用系统标准 Chip（Chip 不能链式挂属性 → 外边距挂外层 Row）
            Row() {
              Chip({
                label: {
                  text: '正在播放',
                  fontSize: 11,
                  fontColor: this.themeDeep
                },
                size: ChipSize.SMALL,
                allowClose: false,
                backgroundColor: this.themeSurface
              })
            }
            .margin({ left: 6 })
            .hitTestBehavior(HitTestMode.None)
          }
        }
        // 顶对齐（2026-10-21 双行标题）：「正在播放」徽标对齐标题第一行
        .width('100%')
        .alignItems(VerticalAlign.Top)

        // 状态行行高锁 17（13sp）：与标题 lineHeight(21) 构成高度预算（见封面注释）
        Text(this.statusText(t))
          .fontSize(13)
          .fontColor(t.status === DownloadStatus.ERROR ? $r('app.color.state_error') : $r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
          .margin({ top: 4 })

        if (t.status === DownloadStatus.DOWNLOADING || t.status === DownloadStatus.PENDING) {
          if (t.totalBytes > 0) {
            Progress({ value: this.percent(t), total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color(this.themePrimary)
              .backgroundColor($r('app.color.progress_track'))
              .margin({ top: 6 })
          } else {
            // 大小未知（服务器没给 Content-Length）：用不确定进度环表达「下载中」，
            // 比画一条永远停在 0% 的空进度条诚实
            LoadingProgress()
              .width(18)
              .height(18)
              .color(this.themePrimary)
              .margin({ top: 6 })
          }
        }
        if (t.status === DownloadStatus.PAUSED && t.totalBytes > 0) {
          Progress({ value: this.percent(t), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(3)
            .color($r('app.color.progress_paused'))
            .backgroundColor($r('app.color.progress_track'))
            .margin({ top: 6 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      // 完成态不再有右侧标记（2026-10-23）：状态行文字「已完成 · 音质 · 大小」已承载该信息。
      // 失败条目的「重试」：这是下载失败后**唯一**不用删掉重找的入口，
      // 必须显式可见（只靠「点整行」太隐蔽，用户根本猜不到整行可点）。
      if (t.status === DownloadStatus.ERROR) {
        Row() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(18)
            .fontColor([this.themeDeep])
        }
        .width(ROW_ACTION_HIT)
        .height(ROW_ACTION_HIT)
        .justifyContent(FlexAlign.Center)
        .borderRadius(22)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .visibility(this.selecting ? Visibility.None : Visibility.Visible)
        .accessibilityText('重试下载')
        .accessibilityLevel('yes')
        .onClick((): void => {
          this.retryFailed([t.id]);
        })
      }
      // 「⋯」更多按钮（2026-10-23，歌单页 TrackItem 同款）：右侧垃圾桶退役，
      // 删除入口收进标准菜单（加入队列 / 加入歌单 / 进入 UP 主页 / 删除），
      // 破坏性操作多一层菜单路径也降低误触。视觉 20px 文字、44vp 命中区
      //（复用 ROW_ACTION_HIT，与 TrackItem 的 MORE_HIT 等值）。
      // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
      // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
      Row() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(ROW_ACTION_HIT)
      .height(ROW_ACTION_HIT)
      .justifyContent(FlexAlign.Center)
      .margin({ right: 4 })
      .visibility(this.selecting ? Visibility.None : Visibility.Visible)
      .accessibilityText('更多操作')
      .accessibilityLevel('yes')
      .bindMenu(this.taskMenuItems(t))
    }
    .width('100%')
    .padding({ left: nested ? 44 : 16, right: 4, top: 10, bottom: 10 })
    // 按压态（TrackItem 模式）：纯缩放形变替代原 stateStyles 底色 —— 不改底色、
    // 不加蒙层，scale 挂根 Row 零加层；.animation() 紧随其后，链上其余属性
    // （width/padding）恒定不变，动画只作用于 scale。
    .scale({ x: this.pressedKey === t.id ? PRESS_SCALE : 1, y: this.pressedKey === t.id ? PRESS_SCALE : 1 })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    // onTouch 只回写按压状态、不消费事件：onClick 照常触发；列表滚动抢占
    // 手势时系统派发 Cancel，条目自动回弹。
    .onTouch((event: TouchEvent): void => {
      this.setPressed(event.type, t.id);
    })
    .onClick((): void => {
      if (this.selecting) {
        this.toggleSelect(t.id);
        return;
      }
      // 失败条目：整行点击 = 重试（右侧已有显式按钮，这里是第二入口，符合直觉）
      if (t.status === DownloadStatus.ERROR) {
        this.retryFailed([t.id]);
        return;
      }
      // 下载中 / 排队中：整行点击 = **只暂停这一条**（2026-10-11 新增，
      // 与「全部暂停」同一套收尾：保留半截文件、恢复时断点续传）
      if (t.status === DownloadStatus.DOWNLOADING || t.status === DownloadStatus.PENDING) {
        this.pauseOne(t);
        return;
      }
      // 已暂停：再点 = 继续这一条（与「全部开始」同源，只作用单条）
      if (t.status === DownloadStatus.PAUSED) {
        this.resumeOne(t);
        return;
      }
      // 只有「真的下载完且文件还在」的条目才可播：ERROR / 半截文件点了必然是失败，
      // 不如什么都不做（宁可无反应，也不要弹一个「无法播放」让人困惑）
      if (t.status === DownloadStatus.COMPLETED && t.localFilePath.length > 0) {
        this.play(t);
      }
    })
  }

  /**
   * 一个下载组的完整内容（2026-10-23 两列改造从 ListItem 内抽出）：
   * 合集 / 歌单组 = 组头 + 展开的分 P 子行；单曲 / 单 P = 普通行。
   * 单列分支直接做 ListItem 内容；两列分支由配对 Row 的左右槽各调一次
   * （组与组并排，Row 默认顶对齐，合集组与单曲组高度不齐时右侧留白，可接受）。
   */
  @Builder
  GroupContent(g: DownloadGroup): void {
    Column() {
      // isCollection 读归组缓存（2026-10-08 卡顿优化）。
      // 判定语义不变（原 isCollectionGroup）：partTotal>1 的显式标记
      // 让「删到只剩一首的合集」仍渲染组头，不会退化成与单视频无异。
      // 歌单组显示修复（2026-10-21）：批量下载的歌单（pl: 组 >1 条）
      // 同样渲染组头卡片，其余歌曲不再不可见；删到剩一首退回普通行
      if (g.isCollection || this.isPlaylistCard(g)) {
        this.GroupHeader(g)
        if (this.isExpanded(g.key)) {
          ForEach(
            g.tasks,
            (t: DownloadTask): void => {
              this.TaskRow(t, true)
            },
            (t: DownloadTask): string => this.rowKey(t)
          )
        }
      } else {
        // 单曲 / 单 P：与旧版完全一致的普通行
        this.TaskRow(g.tasks[0], false)
      }
    }
    .width('100%')
  }

  /**
   * 合集组头行：整组一个条目（封面 + 合集标题 + 聚合状态/进度），
   * 点击展开/收起分 P 子行；选择模式下点击 = 整组全选/取消。
   */
  @Builder
  GroupHeader(g: DownloadGroup): void {
    Row() {
      // 常驻复选框槽位（与 TaskRow 同款动画：槽位展开 + 复选框右滑入）
      Row() {
        Checkbox({ name: g.key, group: 'dlSelect' })
          .select(this.isGroupSelected(g))
          .selectedColor(this.themePrimary)
          .unselectedColor($r('app.color.text_disabled'))
          .shape(CheckBoxShape.CIRCLE)
          .width(20)
          .height(20)
          .translate({ x: this.selecting ? 0 : SELECT_SLOT_VP })
          .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })
          // 选中态指示是装饰（同 TaskRow）：切换入口是整行点击
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
      }
      .width(this.selecting ? SELECT_SLOT_VP : 0)
      .height(20)
      .clip(true)
      .justifyContent(FlexAlign.Center)
      .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })

      // 64vp 显示位按 2x 请求缩略图（双行标题改版 2026-10-21 与 TrackItem 同步：
      // 封面 56→64，高度预算 = 标题两行 lineHeight(21)×2 + 间距 4 + 状态行 17 = 63 ≤ 64）；
      // 加载中 / 失败由 CoverImage 兜浅粉占位
      CoverImage({
        url: toThumbUrl(g.coverUrl, 128),
        imgWidth: 64,
        imgHeight: 64,
        imgRadius: 8,
        altText: g.title
      })

      Column() {
        Row() {
          // 标题双行显示（2026-10-21 与 TrackItem 同步）：maxLines(2) + 第二行省略号；
          // 显式 lineHeight(21) 锁行高（默认随字体浮动会破坏「信息 ≤ 封面」硬预算）。
          Text(g.title)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(21)
            .layoutWeight(1)
          // 「合集/歌单」徽标（2026-10-08）：显式区分可展开组头与普通行——
          // 此前组头与普通行只差一个小箭头，用户分不清「这是可展开的合集」。
          // 品牌粉胶囊底 + 白字，10 号小字不抢标题视觉。
          // isCollection 读归组缓存（2026-10-08 卡顿优化）；
          // 歌单卡片（pl: 组，2026-10-21 显示修复）同款徽标、文案「歌单」。
          if (g.isCollection || this.isPlaylistCard(g)) {
            // 阶段 5：小字徽标改用系统标准 Chip（实底品牌粉 + 白字，与「大会员」同款）
            Row() {
              Chip({
                label: {
                  text: this.isPlaylistCard(g) ? '歌单' : '合集',
                  fontSize: 11,
                  fontColor: this.themeOn
                },
                size: ChipSize.SMALL,
                allowClose: false,
                backgroundColor: this.themePrimary
              })
            }
            .margin({ left: 6 })
            .hitTestBehavior(HitTestMode.None)
          }
        }
        // 顶对齐（2026-10-21 双行标题）：「合集」徽标对齐标题第一行
        .width('100%')
        .alignItems(VerticalAlign.Top)

        // 状态行行高锁 17（13sp）：与标题 lineHeight(21) 构成高度预算（见封面注释）
        Text(this.groupStatusText(g))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
          .margin({ top: 4 })

        // 2026-10-08 卡顿优化：读归组缓存，不再每次渲染全组 some()
        if (g.counts.downloading > 0 || g.counts.pending > 0) {
          if (this.groupPercent(g) >= 0) {
            Progress({ value: this.groupPercent(g), total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color(this.themePrimary)
              .backgroundColor($r('app.color.progress_track'))
              .margin({ top: 6 })
          } else {
            // 总大小未知（分块传输）：用不确定进度表达「在动」，不画停在 0% 的假进度
            LoadingProgress()
              .width(18)
              .height(18)
              .color(this.themePrimary)
              .margin({ top: 6 })
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      // 组级重试：**只在组内有失败项时出现**（整单下载失败几首时最省事的一次操作）。
      // 不常驻显示 —— 组内全成功时挂一个灰按钮只会让人以为还有别的动作。
      // failed 读归组缓存（2026-10-08 卡顿优化）。
      if (g.counts.failed > 0) {
        Row() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(18)
            .fontColor([this.themeDeep])
        }
        .width(ROW_ACTION_HIT)
        .height(ROW_ACTION_HIT)
        .justifyContent(FlexAlign.Center)
        .borderRadius(22)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .visibility(this.selecting ? Visibility.None : Visibility.Visible)
        .accessibilityText('重试本组失败项')
        .accessibilityLevel('yes')
        .onClick((): void => {
          this.retryFailed(this.groupFailedIds(g));
        })
      }
      // 组头「⋯」更多按钮（2026-10-23，与 TaskRow 同款）：整组垃圾桶退役，
      // 删除收进标准菜单（加入队列 = 组内已完成 / 加入歌单 = 组内全部 /
      // 进入 UP 主页 = 组内第一首 / 删除 = 整组，沿用 confirmRemoveGroup 二次确认）。
      // 多选时 visibility 摘出布局（同 TaskRow 的处理）。
      Row() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(ROW_ACTION_HIT)
      .height(ROW_ACTION_HIT)
      .justifyContent(FlexAlign.Center)
      .margin({ right: 4 })
      .visibility(this.selecting ? Visibility.None : Visibility.Visible)
      .accessibilityText('更多操作')
      .accessibilityLevel('yes')
      .bindMenu(this.groupMenuItems(g))

      // 展开指示：复用 arrow_right，展开时旋转 90° 朝下（不引入未验证的新符号名）
      SymbolGlyph($r('sys.symbol.arrow_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_secondary')])
        .rotate({ angle: this.isExpanded(g.key) ? 90 : 0 })
        .margin({ right: 14 })
        // 装饰性指示：展开/收起由整行点击触发，箭头本身不是独立控件
        .accessibilityLevel('no')
    }
    .width('100%')
    .padding({ left: 16, right: 4, top: 10, bottom: 10 })
    // 按压态（TrackItem 模式，同 TaskRow）：纯缩放形变替代原 stateStyles 底色。
    .scale({ x: this.pressedKey === g.key ? PRESS_SCALE : 1, y: this.pressedKey === g.key ? PRESS_SCALE : 1 })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      this.setPressed(event.type, g.key);
    })
    .onClick((): void => {
      if (this.selecting) {
        this.toggleSelectGroup(g);
        return;
      }
      this.toggleGroup(g.key);
    })
  }

  /** 「加入歌单」选择弹层（遮罩 + 面板，WatchHistoryPage 同款；多曲时曲名行带「等 N 首」） */
  @Builder
  pickerOverlay(): void {
    // 全屏点击捕获层：只负责「点弹窗外关闭」，不带遮罩底色
    //（2026-10-23 用户要求：加入歌单弹窗周围不要暗色/主题色遮罩，与 SearchPage 同步）
    Column() {
    }
    .width('100%')
    .height('100%')
    .onClick((): void => {
      this.dismissPicker();
    })
    .justifyContent(FlexAlign.Center)

    Column() {
      Text('加入歌单')
        .fontSize(18)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 8 })
      // 曲名行：单曲显示曲名；组头批量入单显示「曲名 等 N 首」
      Text(this.pickerTracks.length > 1
        ? `${this.pickerTracks[0].title} 等 ${this.pickerTracks.length} 首`
        : (this.pickerTracks.length > 0 ? this.pickerTracks[0].title : ''))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: 12 })
      // 第一项就是「新建歌单并加入」：想单独存一首歌时不必再跑到歌单页
      Row() {
        Text('＋ 新建歌单并加入')
          .fontSize(16)
          .fontColor(this.themeDeep)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        this.createPlaylistFromPicker();
      })
      Divider()
        .color($r('app.color.bg_divider'))
      List() {
        ForEach(
          this.playlistOptions,
          (p: Playlist): void => {
            ListItem() {
              Row() {
                Text(p.name)
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(`${p.tracks.length} 首`)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.press_overlay')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .onClick((): void => {
                this.addToPlaylistFromPicker(p);
              })
            }
          },
          // key 含渲染字段（与 PlaylistsPage 同因）：改名/数量变化后行才会重渲染
          (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
        )
      }
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
      .constraintSize({ maxHeight: 260 })
      Button('取消', { type: ButtonType.Normal })
        .width('100%')
        .height(44)
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor($r('app.color.bg_divider'))
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 12 })
        .onClick((): void => {
          this.dismissPicker();
        })
    }
    .padding(20)
    .width('80%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
  }

  /**
   * 顶栏在根 HdsNavigation titleBar（留白整改同版）：标题行
   * 「选择」+ 队列控制（全部开始/暂停）+ 多选工具条（仅多选态行 2）由根栏
   * stackBuilder 承载（components/DownloadsTabBar.ets），本页只留列表与状态逻辑；
   * 滚动模糊由根栏 bindToScrollable(TabScrollerHolder.downloads) 驱动。
   */
  build() {
    Stack() {
      // 内容层：顶部让出根标题栏（safeTop + 56 常量，与歌单页同节奏）
      Column() {
        if (this.tasks.length === 0) {
          Column() {
            Text('还没有下载任务')
              .fontColor($r('app.color.text_secondary'))
              .fontSize(16)
            Text('在搜索页点击“⋯”→“下载”即可保存歌曲')
              .fontColor($r('app.color.text_tertiary'))
              .fontSize(13)
              .margin({ top: 8 })
            Text('多 P 合集会作为一个整体下载，点开合集可查看每个分 P 的进度')
              .fontColor($r('app.color.text_tertiary'))
              .fontSize(13)
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          // 内容列不再整体 padding top（列表穿透需要），空态自己补栏高避让
          // （此分支必然 tasks.length === 0，固定栏只有标题行）
          .padding({ top: this.safeTop + NAV_TITLE_BAR_HEIGHT })
        } else {
          List({ scroller: TabScrollerHolder.downloads }) {
            // 顶部空白占位条目：列表视口铺满全屏，条目起始位置在屏幕顶端（y=0）。
            // 占位高度 = 根标题栏（safeTop + 56），首个真实条目恰从栏底起排（静置位
            // 与旧 contentStartOffset 等值），滚动时占位与条目一起从模糊板下方穿过。
            ListItem() {
              // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
              Row()
                .width('100%')
                .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
            }
            // 横屏宽屏（2026-10-23 两列改造）：下载组配对，每个 ListItem 左右两列
            //（组 = GroupContent 抽出的完整内容，含组头与展开的分 P 子行）；
            // 竖屏 / 窄窗口走原单列分支，行为与原先完全一致。
            if (this.isTwoCol()) {
              ForEach(
                makePairs<DownloadGroup>(this.groups),
                (pair: PairOf<DownloadGroup>): void => {
                  ListItem() {
                    Row() {
                      Column() {
                        this.GroupContent(pair.first)
                      }
                      .layoutWeight(1)
                      if (pair.second !== null) {
                        Column() {
                          this.GroupContent(pair.second)
                        }
                        .layoutWeight(1)
                        .margin({ left: TWO_COL_GAP_VP })
                      } else {
                        // 奇数末尾：右侧槽留空占位，左列行宽与前面各行一致
                        Blank().layoutWeight(1)
                      }
                    }
                    .width('100%')
                  }
                },
                (pair: PairOf<DownloadGroup>): string =>
                  `${this.groupRowKey(pair.first)}|${pair.second !== null ? this.groupRowKey(pair.second) : 'x'}`
              )
            } else {
              ForEach(
                this.groups,
                (g: DownloadGroup): void => {
                  ListItem() {
                    this.GroupContent(g)
                  }
                },
                (g: DownloadGroup): string => this.groupRowKey(g)
              )
            }
          }
          .layoutWeight(1)
          // 边界回弹（2026-10-08）：到顶/到底的反馈动效
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(6)
          // 顶部根标题栏让位（Sumy 式穿透）：由 List 首个空白占位 ListItem 负责
          //（见上方占位注释），不再使用 contentStartOffset。
          // 留白整改：常规态队列控制迁标题行（DlQueueActions），不再常驻行 2；
          // 多选工具条（行 2）为瞬时覆盖层 —— 占位条目高度恒定（safeTop + 56），
          // 多选时覆盖首项（歌单页同款已接受的行为局限）。
          // 列表末端常规留白（2026-10-09：不再叠加 safeBottom —— 底部不做避让，
          // 视口直接扩展进安全区，末行可滚到悬浮胶囊与手势条下）
          .contentEndOffset(CONTENT_END_OFFSET)
          // [任务③·推广] 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已应用后回调，
          // onWillScroll 是应用前，快滑时差一帧会让模糊层滞后一跳）。
          .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
            this.syncTopBlurProgress();
          })
          .onScrollStop((): void => {
            // Idle 校准终态（用户方案 ②）：兜住 Fling 期丢帧 / 死区过滤累计的偏差。
            this.syncTopBlurProgress();
          })
        }
      }
      .width('100%')
      .height('100%')
      // ⚠️ 不再整体 padding top：列表视口要铺满全屏（List 首个空白占位 ListItem
      // 负责让出标题栏 safeTop + 56），否则条目在栏底被裁掉、滑不进模糊板下方。
      // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）
      // 横屏宽屏（2026-10-23 两列改造）：上限放宽到 840vp，两列每列行宽约 400vp+。
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

      // [任务③·推广] 顶栏渐变模糊层：盖内容列之上（z 序低于根栏 HDS titleBar 与
      // 「加入歌单」选择弹层），进度由列表 onDidScroll/onScrollStop 经
      // topBlurUpdater 命令式驱动。
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })

      // 「加入歌单」选择弹层：盖在列表之上（catch 层全屏捕获点击关闭）
      if (this.showPlaylistPicker) {
        this.pickerOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
