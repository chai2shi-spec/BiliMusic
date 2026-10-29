/**
 * 歌单详情页：展示歌单内单曲，支持播放全部 / 多选批量（加入歌单 / 下载 / 移除）/
 * 单曲播放 / 加入队列 / 从歌单移除 / 长按拖动排序 / 一键排序（按名称 / 时长 / 播放量）。
 * 排序开放范围：普通歌单 + 订阅 UP 歌单；收藏夹镜像禁用（顺序由 B 站服务端决定，
 * 完整同步会覆盖手动顺序）。目标歌单 id 由路由参数 PlaylistDetailRouteParam 传入。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 标题行 + 头部区；返回键为 HDS 默认键）；栏内不放标题文字
 * （歌单名只在头部区 28fp 大标题显示一次），标题行为空占位。
 * avoidLayoutSafeArea 后栏顶 = safeTop，滚动时曲目从沉浸材质下穿过；
 * 侧滑返回是 Navigation 级能力，不受影响。
 *
 * 钉顶头部区：整个头部区「封面 + 28fp 大标题 + 元信息/简介 + 播放全部/拉取新投稿」
 * 接在标题行下，仅曲目列表滚动并从材质下透出；
 * 重命名 / 删除歌单入口在歌单列表页行内 ⋮ 菜单。
 */

import { Playlist, Track, DownloadTask, DownloadStatus, buildTrack, VideoDetail, ITEM_DISPLAY_LIST, ITEM_DISPLAY_GRID } from '../model/MusicModels';
import { LibraryStore, PlaylistSortKey, PlaylistDedupResult } from '../service/LibraryStore';
import { isFolderTwoway } from '../service/FavTwowayStore';
import * as BilibiliApi from '../api/BilibiliApi';
import { SpaceVideo } from '../api/BilibiliApi';
import { toHttpsUrl, stripHtmlTags, parseDurationText } from '../utils/TextUtil';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { TrackCard } from '../components/TrackCard';
import { CoverImage } from '../components/CoverImage';
// 菜单弹层：曲目菜单动作有三个，AlertDialog 只有两颗按钮放不下，用 MenuDialog。
import { showConfirm } from '../components/AppAlertDialog';
// 下载链：与 SearchPage 同一套（requestDownload → 仅 WiFi 拦截询问 → toast 回执）
import { DownloadManager, DownloadStartResult, WIFI_ONLY_BLOCKED } from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import { sleep } from '../utils/AsyncUtil';
import { scanDuplicateTracks, TrackDedupScan } from '../utils/TrackDedup';
import {
  FavFlushSummary,
  flushFavPushes,
  cancelFavPushFlush,
  FLUSH_DEBOUNCE_MS
} from '../service/FavPushRunner';
import { PlaylistDetailRouteParam, NavRouteParamReader, UpSpaceRouteParam } from '../service/NavRouteParams';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP, SEARCH_FILTER_DEBOUNCE_MS } from '../common/constants/InteractionConstants';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { CustomContentDialog } from '@kit.ArkUI';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { SearchBox } from '../components/SearchBox';
import { filterTracksByKeyword } from '../utils/TrackFilter';
import {
  CONTENT_END_OFFSET,
  STORE_CURRENT_TRACK,
  STORE_DOWNLOAD_TASKS,
  STORE_ITEM_DISPLAY_STYLE,
  STORE_LIBRARY_REV,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_DEEP
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  PairOf,
  makePairs,
  TWO_COL_GAP_VP,
  GRID_EDGE_PADDING_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import { showAppToast } from '../components/AppToast';
import { UpSpaceCacheEntry, getUpSpaceCache, saveUpSpaceCache } from '../service/UpSpaceCacheStore';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/**
 * 「拉取新投稿」每次最多收多少条。
 * ⚠️ 放在 import 之后 —— ArkTS 不允许 import 出现在其它语句之后（arkts-no-misplaced-imports）。
 */
const UP_REFRESH_MAX_ITEMS: number = 60;

/**
 * 曲目分批揭示的每批条数（SearchPage 排行榜页签同款的前端切片模式）：
 * 歌单数据本就全量在本地（playlist.tracks），不发请求，
 * onReachEnd 每次多放一批，首屏只建第一批的行。
 */
const PD_REVEAL_PAGE_SIZE: number = 20;

/**
 * 批量下载串行入队的每首间隔：requestDownload 内部每首选一次 view 请求，
 * 密集连发会被 B 站匿名限流（PlaylistsPage 整单下载同一条经验）。
 */
const PD_ENQUEUE_GAP_MS: number = 350;

/** 多选态搜索区 / 动作区交叉淡化时长（UpSpacePage SELECT_FADE_MS 同款） */
const PD_SELECT_FADE_MS: number = 250;

/** ArkTS 没有原生 sleep，用 setTimeout 包一个 Promise（批量下载串行节流用） */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * 歌单头部区（bottomBuilder 承载）实测前的估计高度：封面行 + 元信息 + 简介 + padding。
 * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定；实测值
 * （headerAreaHeight）回来后覆盖，此值只防首次布局 0 高闪跳。
 */
const PLAYLIST_HEADER_ESTIMATE_HEIGHT: number = 174;

@Component
export struct PlaylistDetail {
  /** 曲目列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 头部按钮（播放全部 / 拉取新投稿）沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /**
   * 搜索本地过滤防抖定时器 id：按键路径的过滤重算延迟 200ms（大歌单千级
   * 条目每键同步全量过滤 + 列表 diff 有卡顿风险）；clearSearch / 数据刷新
   * 路径直调 applyLocalFilter 不防抖。aboutToDisappear 清理，防回调打进
   * 已销毁实例。
   */
  private filterDebounceTimer: number = -1;
  @State playlist: Playlist | null = null;
  @State titleText: string = '歌单';
  /** 「拉取新投稿」进行中：防止连点重复发请求 */
  @State upRefreshing: boolean = false;
  /**
   * 歌单头部区实测高（vp，bottomBuilder 内层根节点 onAreaChange 回写，随简介行数浮动）。
   * ⚠️ 初值必须为 0：歌单数据来自本地缓存，
   * 列表带着条目与初值一起挂载会让占位条目先按不含头部区的让位量排布、实测回来
   * 再整体下移（内容跳变）。列表挂载门控直接判 headerAreaHeight > 0（见 build 里的
   * if）——barTotalHeight() 恒 > 0 不能当门控。
   * @Watch（onHeaderMeasured）：门控首次翻转是「定位」下钻入参的一次性消费点
   * （pendingLocateTrackId 非空才做事；后续实测变化因 pending 已清空而空跑）。
   */
  @State @Watch('onHeaderMeasured') headerAreaHeight: number = 0;

  /** 目标歌单 id（路由参数 PlaylistDetailRouteParam 带入，aboutToAppear 取参一次） */
  private playlistId: string = '';

  /**
   * 「定位当前播放」延时滚动定时器 id：扩切片 / 入参定位改布局后
   * 等一帧布局完成再滚；
   * aboutToDisappear 清理，防回调打进已销毁实例。
   */
  private locateTimerId: number = -1;

  /**
   * 入参定位暂存（歌单页签「定位」下钻入口带入的曲目 id，空 = 无）：
   * 列表挂载门控（headerAreaHeight）首次翻转时经 onHeaderMeasured 消费一次。
   */
  private pendingLocateTrackId: string = '';

  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 头部区实测高。
   * 头部区高度随简介行数浮动，无法定值，沿用「实测 + 挂载门控」机制。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + this.headerAreaHeight;
  }

  /**
   * 自绘顶栏渐变模糊层进度更新器 + 校准：onDidScroll / onScrollStop 命令式
   * 驱动 opacity（不标 @State，滚动高频回调零重建）；yOffset 0 →
   * TITLE_BLUR_END_VP 线性映射 0 → 1（updater 内截断，边缘回弹负偏移
   * 归零为死区）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.listScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }
  /** 媒体库变更信号：在别处（如弹层里）改到这个歌单时同步刷新 */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryChanged') libraryRev: number = 0;
  /** 状态栏高度（vp）：标题栏要整体落在状态栏下方，由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;

  /** 主题色运行时值：头部浅底按钮（Surface 底 + Primary 字）与弹层新建行深粉字（Deep）跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时曲目条目两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  private player: MusicPlayer = MusicPlayer.getInstance();

  /**
   * 横屏宽屏时两列显示。
   *
   * ⚠️ 可拖动排序的本地歌单（canReorder()）**保持单列**：ForEach.onMove 的
   * 长按拖动排序以 ListItem 为单位，配对后拖动会以「一对」为单位错乱 ——
   * 有意取舍，不是遗漏。收藏夹镜像等不可排序歌单横屏照常两列。
   */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape)
      && !this.canReorder();
  }

  /** 条目展示（外观设置「条目展示」）：长条（默认）/ 大封面双列网格 */
  @StorageProp(STORE_ITEM_DISPLAY_STYLE) itemDisplay: string = ITEM_DISPLAY_LIST;

  /**
   * 大封面模式：曲目以双列网格卡（TrackCard）渲染，竖屏 / 横屏均双列。
   * ⚠️ 可拖动排序的歌单（canReorder()）**恒为长条**：网格不注册 onMove，
   * 配对后拖动会以「一对」为单位错乱 —— 与 isTwoCol() 同一门控口径，
   * 拖动排序优先于展示样式（有意取舍，不是遗漏）。
   */
  private isGrid(): boolean {
    return this.itemDisplay === ITEM_DISPLAY_GRID && !this.canReorder();
  }

  /**
   * 下载任务快照：订阅它只为派生「哪些曲目已下载完成」
   * （下载完成 / 删除时徽标要即时出现 / 消失），本页不做下载管理。
   */
  @StorageLink(STORE_DOWNLOAD_TASKS) @Watch('onDownloadTasks') downloadTasks: DownloadTask[] = [];
  /**
   * 已下载完成的曲目 id 集合。刻意用数组而不是 Set ——
   * @State 感知不到 Set 的内容变化（与 DownloadsPage.selectedIds 同一坑）。
   * 曲目行读它显示「已下载」徽标；精确匹配（见 isDownloaded 注释）。
   */
  @State downloadedIds: string[] = [];

  /**
   * 列表已揭示的曲目切片（SearchPage 排行榜页签同款前端分页）：
   * 全量在 this.playlist.tracks（本地数据，不发请求），onReachEnd 每次多放
   * PD_REVEAL_PAGE_SIZE 条；load() 重载时保留已揭示的条数（至少一批），
   * 删曲目 / 合并新投稿后列表不跳回第一批。
   * 搜索激活时切片源换成过滤匹配数组（activeSource），语义 = 「当前源的已揭示切片」，
   * 三个渲染分支（网格 / 两列 / 单列）与底部状态行零改动复用。
   */
  @State tracks: Track[] = [];

  /** 搜索框文本：输入即本地过滤歌单内曲目（onChange 显式调 onKeywordChanged，不走 @Watch —— UpSpacePage 同款显式调用风格） */
  @State searchKeyword: string = '';
  /**
   * 本地过滤全量匹配（标题 / 歌手包含关键词，小写化匹配）；
   * 空数组 = 无关键词或 0 命中，靠 searchKeyword 区分。
   * 过滤范围是歌单全量 playlist.tracks 而非已揭示切片 —— 歌单数据本就全量在本地，
   * 未滚动到的曲目也要能搜到（UpSpacePage 只过滤已加载分页，那是远端分页；此处有意差异）。
   */
  @State filteredTracks: Track[] = [];

  // ===== 曲目多选（头部「选择」按钮进入，批量加入歌单 / 下载 / 移除） =====
  /** 多选模式：true = 头部「选择」已进入，点条目切换选中、搜索区淡出为动作区、「⋯」隐藏 */
  @State selecting: boolean = false;
  /**
   * 选中曲目 id 集（track.id）。切换一律**整表重赋值**（不用 push/splice
   * 原地改）：@State 对数组重赋值的观测路径最稳，配合 TrackItem/TrackCard 的
   * selected @Prop 逐条驱动勾选回显。
   */
  @State selectedIds: string[] = [];
  /** 多选批量下载串行入队进行中（防重复点击：再点「下载」提示稍候） */
  @State downloadingSelected: boolean = false;
  /** 「加入歌单」弹窗曲目（多选批量入口专用） */
  private pickerTracks: Track[] = [];
  /** 弹窗打开时的可加歌单快照（「新建歌单并加入」的重名检查基于它即可） */
  private playlistOptions: Playlist[] = [];
  /**
   * 「加入歌单」弹窗 controller：官方 CustomContentDialog 标准对话框
   * （默认遮罩 + 官方按钮槽，替代原根 Stack 内自绘弹层）。标题/按钮为
   * 常量 → 建一次永不重建（faqs-arkui-555 只定格构造参数，动态内容经
   * contentBuilder 闭包在 open() 时读当次状态）。
   */
  private playlistPickerController: CustomDialogController | undefined = undefined;

  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
   */
  @State navTransX: string = '0%';

  /**
   * 头部区展示用的派生字段（load() 时重算）：@Builder 体内不放局部声明、
   * 也不便反复对 playlist 判空，元信息 / 封面 / 简介统一在 load() 算好成串。
   */
  @State coverUrl: string = '';
  @State metaText: string = '';
  @State descText: string = '';

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
    // 路由入参：目标歌单 id 随 pushPathByName 入栈，
    // 读取器内部 getParamByName 取回 + instanceof 判型（返回已判型对象或 null）。
    const routeParam: PlaylistDetailRouteParam | null =
      NavRouteParamReader.readPlaylistDetailParam(NavStackHolder.stack);
    this.playlistId = routeParam !== null ? routeParam.playlistId : '';
    // 「定位」下钻入口（歌单页签）：带入要定位的曲目 id，
    // 等列表挂载门控翻转（onHeaderMeasured）后消费一次。
    this.pendingLocateTrackId = routeParam !== null ? routeParam.locateTrackId : '';
    this.load();
    // @Watch 不为 @StorageLink 的初始同步触发（工程内已踩过两次的坑），
    // 这里必须补一次已下载集合的初算；ensureLoaded 幂等 —— AppContainer 启动链
    // 已装填过的话这是空操作，冷启动直接进本页时它负责推第一份快照。
    this.rebuildDownloadedIds();
    DownloadManager.getInstance().ensureLoaded().catch((e: Error): void => {
      console.error(`load downloads failed: ${JSON.stringify(e)}`);
    });
    // 「加入歌单」弹窗：官方标准对话框，标题/按钮常量（见成员声明处注释）。
    // 关闭路径刻意不清暂存数据：关闭有退场动画，清了会让正文在淡出途中
    // 先变空；pickerTracks / playlistOptions 每次打开前都会重写，残留值
    // 无消费方。
    this.playlistPickerController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '加入歌单',
        contentBuilder: (): void => {
          this.PlaylistPickerBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.playlistPickerController?.close();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
  }

  aboutToDisappear(): void {
    // 「定位」延时滚动定时器：销毁前清理，防回调打进已销毁实例。
    if (this.locateTimerId >= 0) {
      clearTimeout(this.locateTimerId);
      this.locateTimerId = -1;
    }
    // 搜索过滤防抖定时器：同上清理。
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
      this.filterDebounceTimer = -1;
    }
  }

  /** 下载快照到达：重建「已下载完成」曲目 id 集合（COMPLETED 且文件还在才算数） */
  private onDownloadTasks(): void {
    this.rebuildDownloadedIds();
  }

  private rebuildDownloadedIds(): void {
    const ids: string[] = [];
    for (let i = 0; i < this.downloadTasks.length; i++) {
      const t: DownloadTask = this.downloadTasks[i];
      if (t.status === DownloadStatus.COMPLETED && t.localFilePath.length > 0
        && ids.indexOf(t.musicId) < 0) {
        ids.push(t.musicId);
      }
    }
    this.downloadedIds = ids;
  }

  /**
   * 这首曲目是否已下载完成：**musicId 精确匹配**，与 DownloadManager 去重键
   * （getDownloadByMusicId）同一语义 —— 多 P 首 P 条目 id = 纯 bvid、其余 =
   * `bvid#cid`，各自独立判定，不会「整合集下过就把所有分 P 都标成已下载」。
   */
  private isDownloaded(t: Track): boolean {
    return this.downloadedIds.indexOf(t.id) >= 0;
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
   * · push 入场：先把页面挪到屏幕右侧外（'100%'），event 闭包内回到 '0%'，
   *   系统按闭包内的状态变化生成 400ms EaseOut 过渡；
   * · pop 出场（含侧滑返回手势触发的返回）：反向滑回右侧，与手势方向一致；
   * · 其余场景（本页被上层页覆盖 / 上层页返回后重新露出）返回 undefined，
   *   走系统默认转场。
   */
  private navTransitionDelegate(op: NavigationOperation,
    isEnter: boolean): Array<NavDestinationTransition> | undefined {
    if (op === NavigationOperation.PUSH && isEnter) {
      this.navTransX = '100%';
      const enter: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '0%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [enter];
      return transitions;
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [exit];
      return transitions;
    }
    return undefined;
  }

  onLibraryChanged(): void {
    this.load();
  }

  private load(): void {
    const p: Playlist | null = LibraryStore.getPlaylist(this.playlistId);
    this.playlist = p;
    this.titleText = p ? p.name : '歌单';
    this.coverUrl = p ? p.coverUrl : '';
    this.descText = p && p.description.length > 0 ? p.description : '';
    this.metaText = this.buildMetaText(p);
    // 过滤结果先与歌单换新同步，再从当前源（关键词激活 = 匹配数组，否则歌单全量）切片
    this.applyLocalFilter();
    const all: Track[] = this.activeSource();
    const keep: number = Math.max(this.tracks.length, PD_REVEAL_PAGE_SIZE);
    this.tracks = all.slice(0, Math.min(keep, all.length));
  }

  /** 是否还有未揭示的曲目（底部状态行与 onReachEnd 闸门共用；搜索态对匹配数组比较） */
  private hasMoreTracks(): boolean {
    return this.tracks.length < this.activeSource().length;
  }

  /**
   * List 的 onReachEnd（SearchPage 排行榜页签同款，纯前端切片不发请求）：
   * 每次多放一批；没有下一批时直接返回（短列表首帧布局触发的空回调不做事）。
   */
  private onReachEnd(): void {
    const all: Track[] = this.activeSource();
    if (this.tracks.length >= all.length) {
      return;
    }
    // 增量揭示（SearchPage.revealMoreRanking 同款）：push 揭示区间，
    // 不再 slice 整表重新赋值，ForEach 只 diff 新增 key。
    const from: number = this.tracks.length;
    const next: number = Math.min(from + PD_REVEAL_PAGE_SIZE, all.length);
    for (let i = from; i < next; i++) {
      this.tracks.push(all[i]);
    }
  }

  // ===== 歌单内搜索（纯本地过滤，无远程搜索）=====

  /** 当前切片源：有关键词 → 全量匹配数组；否则 → 歌单全量（歌单空给空数组）。 */
  private activeSource(): Track[] {
    if (this.searchKeyword.trim().length > 0) {
      return this.filteredTracks;
    }
    return this.playlist !== null ? this.playlist.tracks : [];
  }

  /**
   * 本地过滤：标题 / 歌手包含关键词（小写化匹配），输入即生效、离线可用。
   * 过滤谓词收口在 filterTracksByKeyword（与 UpSpacePage / CollectionDetailPage
   * 三页共用同一份实现）。空关键词 → 清空匹配（activeSource 退回歌单全量）。
   * 过滤范围是歌单全量 playlist.tracks 而非已揭示切片 —— 歌单数据本就全量在本地，
   * 未滚动到的曲目也要能搜到（UpSpacePage 只过滤已加载分页，那是远端分页；此处有意差异）。
   */
  private applyLocalFilter(): void {
    const p: Playlist | null = this.playlist;
    this.filteredTracks = p !== null ? filterTracksByKeyword(p.tracks, this.searchKeyword) : [];
  }

  /**
   * 输入变化（按键路径）：过滤重算 + 切片重置走 200ms 防抖 —— 大歌单千级
   * 条目每键同步全量过滤 + 列表 diff 有卡顿风险；新关键词 = 新列表，防抖
   * 回调里从头揭示第一批。回调读当刻 this.searchKeyword（不捕获旧词），幂等。
   */
  private onKeywordChanged(): void {
    // 关键词变化 = 用户切换任务，退出多选（搜索框在多选态本就淡出不可点，此处兜底）
    this.exitSelecting();
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
    }
    this.filterDebounceTimer = setTimeout((): void => {
      this.filterDebounceTimer = -1;
      this.applyLocalFilter();
      this.tracks = this.activeSource().slice(0, PD_REVEAL_PAGE_SIZE);
    }, SEARCH_FILTER_DEBOUNCE_MS);
  }

  /**
   * 框内 × 清除：关键词置空 + 退回全量第一批（无远程态要清，UpSpacePage 简化版）。
   * 取消在途防抖后立即执行 —— 防抖回调若不清，清态后 200ms 会拿旧词把过滤
   * 结果复活回来。
   */
  private clearSearch(): void {
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
      this.filterDebounceTimer = -1;
    }
    this.searchKeyword = '';
    this.applyLocalFilter();
    this.tracks = this.activeSource().slice(0, PD_REVEAL_PAGE_SIZE);
  }

  // ===== 定位当前播放（标题行「定位」按钮 + 歌单页签「定位」下钻入参） =====

  /**
   * 「定位当前播放」入口（标题行「定位」按钮）：取 AppStorage 在播曲目
   * 转曲目级定位；没有在播曲目则 toast（PlaylistsPage / DownloadsPage 同一口径）。
   */
  private locateCurrentPlaying(): void {
    const cur: Track | undefined = AppStorage.get<Track>(STORE_CURRENT_TRACK);
    if (cur === undefined || cur === null) {
      this.toast('还没有正在播放的曲目', 1500);
      return;
    }
    this.locateTrackById(cur.id);
  }

  /**
   * 按 id 定位曲目行（id 精确匹配，与 TrackItem「正在播放」高亮同一语义）：
   * 在当前展示源（activeSource：搜索态 = 匹配数组，否则歌单全量）中找目标，
   * 未揭示区先扩切片，再换算 List 下标延时居中滚动。
   * 找不到：搜索态提示不在筛选结果，否则提示不在此歌单（toast 兜底，不跳转）。
   */
  private locateTrackById(trackId: string): void {
    const all: Track[] = this.activeSource();
    let target: number = -1;
    for (let i: number = 0; i < all.length; i++) {
      if (all[i].id === trackId) {
        target = i;
        break;
      }
    }
    if (target < 0) {
      this.toast(this.searchKeyword.trim().length > 0
        ? '当前播放的曲目不在筛选结果中'
        : '当前播放的曲目不在此歌单', 1800);
      return;
    }
    // 目标在未揭示区（前端分页切片之外）：扩切片到含目标（+1 便于居中后有上下文；
    // 增量 push 揭示区间，ForEach 只 diff 新增 key，onReachEnd 同款）。
    if (target >= this.tracks.length) {
      const next: number = Math.min(target + 1, all.length);
      for (let i: number = this.tracks.length; i < next; i++) {
        this.tracks.push(all[i]);
      }
    }
    // List 下标换算：首项为顶部占位（+1）；网格 / 两列分支 makePairs 配对
    //（每个 ListItem 两个曲目，÷2 取行）；单列直接用曲目下标。
    const cols: number = (this.isGrid() || this.isTwoCol()) ? 2 : 1;
    const listIndex: number = 1 + (cols > 1 ? Math.floor(target / cols) : target);
    // 扩切片改变布局：等一帧布局完成再滚（DownloadsPage 同款 100ms 延时），
    // 重复点击先清旧定时器（最后一次点击为准）。
    if (this.locateTimerId >= 0) {
      clearTimeout(this.locateTimerId);
    }
    this.locateTimerId = setTimeout((): void => {
      this.locateTimerId = -1;
      this.listScroller.scrollToIndex(listIndex, false, ScrollAlign.CENTER);
    }, 100);
  }

  /**
   * 头部区实测回写（@Watch onHeaderMeasured）：列表挂载门控首次翻转
   * 且带入参定位（歌单页签「定位」下钻）→ 消费一次；
   * pending 清空后后续实测变化（横竖屏切换等）空跑，不重复定位。
   */
  private onHeaderMeasured(): void {
    if (this.headerAreaHeight > 0 && this.pendingLocateTrackId.length > 0) {
      const trackId: string = this.pendingLocateTrackId;
      this.pendingLocateTrackId = '';
      this.locateTrackById(trackId);
    }
  }

  /**
   * 本歌单是否开放「长按拖动排序 / 自动排序」：
   * 普通歌单 + 订阅 UP 歌单可排；**收藏夹镜像禁用** —— applyFavMirror 双向同步
   * 会按 B 站服务端顺序整体重建，手动顺序会被覆盖，开放只会误导用户。
   */
  private canReorder(): boolean {
    return this.playlist !== null && !LibraryStore.isFavMirror(this.playlist);
  }

  /**
   * 长按拖动排序落库（ForEach.onMove 回调）。
   *
   * onMove 由系统在拖拽**松手后**触发一次（from = 拖起下标，to = 落点下标），
   * 下标限定在 ForEach 数据（this.tracks 切片）内 —— 不含列表首尾的占位/状态条目；
   * 切片是 playlist.tracks 的**前缀**，切片下标即全量下标，movePlaylistTrack
   * 内部按 trackId 定位（不收 from），传错下标也只影响 to 的 clamp，删不错歌。
   *
   * 本地切片先对齐（与系统已完成的视觉移动一致），再落库；落库 →
   * STORE_LIBRARY_REV bump → onLibraryChanged → load() 重切（保留揭示条数），
   * 结果与本地切片同序，无视觉跳变。
   */
  private onTrackMove(from: number, to: number): void {
    const p: Playlist | null = this.playlist;
    // 过滤态 / 多选态禁用拖动排序（双保险之二，onMove 注册处已不注册）：
    // 过滤态切片下标是匹配数组下标，不对应歌单全量下标，落库会错歌；
    // 多选态条目点击语义已让位点选，不允许再拖动。
    if (p === null || this.selecting || this.searchKeyword.trim().length > 0
      || from < 0 || from >= this.tracks.length) {
      return;
    }
    const moved: Track = this.tracks[from];
    const next: Track[] = [...this.tracks];
    next.splice(from, 1);
    const target: number = Math.max(0, Math.min(to, next.length));
    next.splice(target, 0, moved);
    this.tracks = next;
    LibraryStore.movePlaylistTrack(p.id, moved.id, target);
  }

  /**
   * 「排序」菜单项（bindMenu）：按名称（拼音升序，复用
   * LibraryStore.compareByTitle 同款比较器）/ 按时长（降序）/ 按播放量（降序）/
   * 按加入时间（降序，新在前；存量无戳条目首排时物化，见 materializeAddedAt）。
   * 自动排序是一次性动作，不启用 titleSorted 持续规则（见 sortPlaylistTracks 注释）。
   * 自建歌单（sourceKind === ''）末尾追加「去重」入口（见 confirmDedup）。
   */
  private sortMenuItems(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: '按名称',
        action: (): void => {
          this.applyAutoSort('title', '已按名称排序');
        }
      },
      {
        value: '按时长',
        action: (): void => {
          this.applyAutoSort('duration', '已按时长排序');
        }
      },
      {
        value: '按播放量',
        action: (): void => {
          this.applyAutoSort('playCount', '已按播放量排序');
        }
      },
      {
        value: '按加入时间',
        action: (): void => {
          this.applyAutoSort('addedTime', '已按加入时间排序');
        }
      }
    ];
    // 去重只对自建歌单开放：订阅歌单内容随投稿自动重建、收藏夹镜像
    // 由 B 站服务端决定，去重成果都会被下次同步覆盖，开放只会误导。
    if (this.playlist !== null && this.playlist.sourceKind === '') {
      items.push({
        value: '去重',
        action: (): void => {
          this.confirmDedup();
        }
      });
    }
    return items;
  }

  /** 执行自动排序并 toast 回执（歌单不存在 = 菜单打开期间被删，静默返回） */
  private applyAutoSort(sortKey: PlaylistSortKey, toastText: string): void {
    const sorted: Playlist | null = LibraryStore.sortPlaylistTracks(this.playlistId, sortKey);
    if (sorted !== null) {
      this.toast(toastText, 1500);
    }
  }

  /**
   * 「去重」入口：先扫描报数（同 id 精确重复 + 同名同歌手、时长差 ≤ 5 秒
   * 或时长未知的智能重复），确认后交给 LibraryStore.dedupPlaylistTracks
   * 一次性重建落盘（每组保留最靠前的一首，单次 persist 保序）。
   * 落盘 → STORE_LIBRARY_REV bump → onLibraryChanged → load() 自动刷新。
   */
  private confirmDedup(): void {
    const p: Playlist | null = this.playlist;
    if (p === null) {
      return;
    }
    const scan: TrackDedupScan = scanDuplicateTracks(p.tracks);
    const dupCount: number = scan.removeIndexes.length;
    if (dupCount === 0) {
      this.toast('没有发现重复歌曲', 1800);
      return;
    }
    showConfirm(this.getUIContext(), {
      title: '歌单去重',
      message: `在「${p.name}」中发现 ${dupCount} 首重复歌曲，移除后剩 ${p.tracks.length - dupCount} 首（每组保留最靠前的一首）。`,
      confirmText: '去重',
      onConfirm: (): void => {
        // 以执行时刻的扫描结果为准（弹窗打开期间歌单可能已变）
        const result: PlaylistDedupResult | null = LibraryStore.dedupPlaylistTracks(this.playlistId);
        if (result === null) {
          return;
        }
        this.toast(result.removed > 0 ? `已移除 ${result.removed} 首重复歌曲` : '没有发现重复歌曲', 1800);
      }
    });
  }


  /**
   * 头部区元信息行：歌曲数 + 来源。
   * 收藏夹镜像显示「同步自 收藏夹名」；
   * 订阅歌单优先显示 UP 昵称（订阅关系的核心信息）；
   * 普通歌单显示创建日期（取 ISO 串前 10 位，零格式化风险）。
   */
  private buildMetaText(p: Playlist | null): string {
    if (!p) {
      return '';
    }
    const countText: string = `${p.tracks.length} 首`;
    if (LibraryStore.isFavMirror(p)) {
      // 双向夹：本地增删会写回 B 站，元信息必须与单向镜像区分开
      const twoway: boolean = isFolderTwoway(LibraryStore.favMediaIdOf(p));
      if (twoway) {
        return p.upName.length > 0 ? `${countText} · 双向同步自 ${p.upName}` : `${countText} · B 站收藏夹（双向）`;
      }
      return p.upName.length > 0 ? `${countText} · 同步自 ${p.upName}` : `${countText} · B 站收藏夹`;
    }
    if (LibraryStore.isUpSubscription(p)) {
      return p.upName.length > 0 ? `${countText} · 订阅自 ${p.upName}` : countText;
    }
    return p.createdAt.length >= 10 ? `${countText} · 创建于 ${p.createdAt.slice(0, 10)}` : countText;
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 从已有曲目里取出「同一个 UP 的 bvid」当作 related 扩散的种子。
   *
   * 只取前几个：`getUserVideosViaRelated` 默认最多用 2 个种子（每个种子一次请求），
   * 取多了既没收益又会增加被限流的机会。
   */
  private seedBvids(tracks: Track[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < tracks.length && out.length < 4; i++) {
      const bvid: string = tracks[i].bvid;
      if (bvid.length > 0 && out.indexOf(bvid) < 0) {
        out.push(bvid);
      }
    }
    return out;
  }

  /**
   * 拉取该订阅 UP 的新投稿并入歌单（按 id 去重，新的排前面）。
   *
   * 走 `collectUpVideos`（三级兜底：搜索反查 → related 扩散 → 空间接口），策略只在
   * `BilibiliApi` 里维护一份，这里不再自己拼链路。
   *
   * ⚠️ 关于「只成功一次」：这不是接口被限流 —— 实测搜索接口连打 8 次 8/8 成功。
   * 真实原因是**去重**：搜索反查固定按 pubdate 返回最近那几十条，第一次拉进歌单后，
   * 之后再拉回来的还是同一批，`mergeUpTracks` 全去重掉 → added=0。
   * 所以 `added === 0` 时提示必须说「已是最新」，否则用户会以为是故障。
   */
  private refreshUpTracks(): void {
    const p: Playlist | null = this.playlist;
    // 只有「订阅 UP 投稿」歌单才有这条链路；收藏夹镜像（upMid='fav_x'）不能走，
    // 否则会用收藏夹 id 去调 UP 投稿接口 → 必然失败
    if (!p || !LibraryStore.isUpSubscription(p) || this.upRefreshing) {
      return;
    }
    this.upRefreshing = true;
    this.toast('正在拉取新投稿…', 1200);
    const name: string = p.upName;
    BilibiliApi.collectUpVideos(p.upMid, name, this.seedBvids(p.tracks), UP_REFRESH_MAX_ITEMS)
      .then((res: BilibiliApi.UpVideosCollectResult): void => {
        const collected: SpaceVideo[] = res.list;
        if (collected.length === 0) {
          // 三条路都没货：有具体原因就说原因，否则说清「是 B 站没给，不是 App 坏了」
          this.toast(res.reason.length > 0
            ? `B 站暂时没返回投稿：${res.reason}`
            : 'B 站暂时没返回投稿，稍后再试', 2200);
          return;
        }
        const tracks: Track[] = collected.map((v: SpaceVideo): Track => {
          return buildTrack({
            id: v.bvid,
            bvid: v.bvid,
            aid: String(v.aid ?? 0),
            title: stripHtmlTags(v.title),
            artist: v.author || name,
            upMid: p.upMid,
            coverUrl: toHttpsUrl(v.pic),
            duration: parseDurationText(v.length),
            playCount: v.play ?? 0,
            pubdate: v.created || 0
          });
        });
        const r = LibraryStore.mergeUpTracks(p.id, tracks);
        this.load();
        // 拉新结果同步回 UP 主页缓存：重进 UP 页即显示本次拉到的最新一页
        this.syncUpSpaceCache(tracks, res.via);
        if (r.added === 0) {
          // 拿到了数据但全是已有的 = 确实没有新投稿，不是故障
          this.toast('已是最新 · 该 UP 还没有新投稿', 1800);
        } else if (r.dropped > 0) {
          this.toast(`新增 ${r.added} 首，已满 ${r.playlist ? r.playlist.tracks.length : 0} 首`, 2000);
        } else {
          this.toast(`新增 ${r.added} 首`, 1800);
        }
      })
      .catch((e: Error): void => {
        console.error(`refreshUpTracks failed: ${e.message}`);
        this.toast('拉取失败，B 站可能限制了访问', 2000);
      })
      .then((): void => {
        this.upRefreshing = false;
      });
  }

  /**
   * 拉新结果同步回 UP 主页缓存：歌单页拉新只写歌单，UP 主页缓存里
   * 还是旧一页 —— 重进 UP 页显示旧列表，用户以为没拉到又得再拉一次。
   * 这里把刚取回的最新一页整表写进缓存，与 UpSpacePage「拉取新投稿」的落盘语义
   * 一致（列表换新、page=1、hasMore 按 via 推导）；资料字段沿用缓存已有值，
   * 缓存不存在时以歌单资料新建（头像 / fans / archiveCount 置空值，UP 页有兜底显示，
   * 下拉刷新即补全）。
   */
  private syncUpSpaceCache(collected: Track[], via: number): void {
    const p: Playlist | null = this.playlist;
    if (!p || p.upMid.length === 0 || collected.length === 0) {
      return;
    }
    getUpSpaceCache(p.upMid)
      .then((cached: UpSpaceCacheEntry | null): void => {
        const entry: UpSpaceCacheEntry = {
          upMid: p.upMid,
          upName: cached !== null && cached.upName.length > 0 ? cached.upName : p.upName,
          upFace: cached !== null ? cached.upFace : '',
          fans: cached !== null ? cached.fans : 0,
          archiveCount: cached !== null ? cached.archiveCount : 0,
          tracks: collected,
          page: 1,
          // 空间接口真分页（ps 上限 50，BilibiliApi.SPACE_PS_MAX 未导出）：拿满一页才可能还有下页
          hasMore: via === BilibiliApi.UP_VIA_SPACE && collected.length >= 50,
          sourceVia: via,
          cachedAtMs: Date.now()
        };
        saveUpSpaceCache(entry).catch((): void => {
          // 失败已在 saveUpSpaceCache 内记日志，这里只兜 rejection
        });
      })
      .catch((): void => {
        // 读旧缓存失败：放弃同步（不阻塞拉新主流程，UP 页下次联网自会重建缓存）
      });
  }

  /**
   * 曲目「⋯」菜单（bindMenu + MenuElement 数组）。
   *
   * 顺序刻意为「加入队列 / 下载 / 从歌单移除」：破坏性的移除放**最后**，
   * 用户扫一眼就能把安全操作与不可逆操作分开，减少误触。
   */
  private trackMenuItems(track: Track): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          this.toast('已加入播放队列', 1500);
        }
      },
      {
        value: '下载',
        action: (): void => {
          this.startDownload(track);
        }
      },
      {
        value: '进入 UP 主页',
        action: (): void => {
          this.openUpSpace(track);
        }
      },
      {
        value: '从歌单移除',
        action: (): void => {
          this.confirmRemoveTrack(track);
        }
      }
    ];
  }

  /**
   * 「进入 UP 主页」→ 站内页（UpSpacePage），与 SearchPage 同款。
   * mid 两条来源：
   *  1. 曲目自带的 upMid（搜索 / 排行榜 / 订阅投稿映射时已落下）—— 直接用，零请求；
   *  2. 旧版本落盘曲目没有 upMid（读出来是 undefined，⚠️ `?? ''` 不能省）→
   *     用 bvid 走 `getVideoDetail` 换 `owner.mid`（该接口带 viewCache，TTL 内不重复发请求）。
   * 头像传空串占位：曲目行不带 UP 头像，UpSpacePage 用 CoverImage 兜占位图，
   * loadCard 拿到真图后覆盖。
   */
  private async openUpSpace(track: Track): Promise<void> {
    let mid: string = track.upMid ?? '';
    if (mid.length === 0) {
      const bvid: string = track.bvid.length > 0 ? track.bvid : track.id;
      if (bvid.indexOf('BV') !== 0) {
        this.toast('这条没有 UP 主信息', 1500);
        return;
      }
      this.toast('正在获取投稿作者…', 1200);
      try {
        const detail: VideoDetail = await BilibiliApi.getVideoDetail(bvid);
        mid = detail.owner ? String(detail.owner.mid) : '';
      } catch (e) {
        console.error(`openUpSpace resolve mid failed: ${JSON.stringify(e)}`);
        mid = '';
      }
      if (mid.length === 0) {
        this.toast('获取 UP 主失败', 1500);
        return;
      }
    }
    NavStackHolder.stack.pushPathByName('UpSpace', new UpSpaceRouteParam(mid, track.artist, ''));
  }

  /**
   * 「从歌单移除」的真实入口。
   * 普通歌单：保持原行为（本地删，零影响）。
   * 双向收藏夹：移除会实时写回 B 站（= 取消收藏），
   *   弹确认讲清楚后果，确认后走 store 挂钩自动推送。
   * 单向收藏夹镜像：本地移除**不会取消 B 站收藏**，只动本地 —— 但要弹确认
   *   讲清楚「下次同步会重新出现」，避免用户误以为删掉的就是 B 站收藏。
   */
  private confirmRemoveTrack(track: Track): void {
    const p: Playlist | null = this.playlist;
    if (p === null || !LibraryStore.isFavMirror(p)) {
      // 普通歌单：原行为，不打扰用户
      LibraryStore.removeTracksFromPlaylist(this.playlistId, [track.id]);
      this.load();
      return;
    }
    if (isFolderTwoway(LibraryStore.favMediaIdOf(p))) {
      showConfirm(this.getUIContext(), {
        title: '取消收藏并移除',
        message: `「${p.name}」已开启双向同步，移除将同时取消 B 站收藏夹中的这首收藏。`,
        confirmText: '取消收藏并移除',
        onConfirm: (): void => {
          // store 挂钩会自动把移除意图实时推送到 B 站（失败自动补推）
          LibraryStore.removeTracksFromPlaylist(this.playlistId, [track.id]);
          this.load();
          this.toast('已移除，正在同步到 B 站…', 2000);
          this.reportFavPushResult();
        }
      });
      return;
    }
    showConfirm(this.getUIContext(), {
      title: '从收藏夹镜像移除',
      message: `「${p.name}」是 B 站收藏夹的镜像。同步为单向（B 站 → 本地），移除不会取消 B 站收藏，下次同步这首歌会重新出现。`,
      confirmText: '仅本地移除',
      onConfirm: (): void => {
        LibraryStore.removeTracksFromPlaylist(this.playlistId, [track.id]);
        this.load();
        this.toast('已从本地移除（下次同步会重新出现）', 2000);
      }
    });
  }

  /**
   * 双向夹删除的写回结果回执：接管去抖窗口（取消去抖计时器），到点自己
   * 显式冲刷拿真实结果，把「正在同步到 B 站…」的下文补上 —— 此前成功/
   * 失败全部静默，用户永远不知道有没有真的取消 B 站收藏。
   * 全零且无失败 = 队列空（对冲抵消：B 站本就没有该视频，本地已一致）→ 静默。
   */
  private reportFavPushResult(): void {
    cancelFavPushFlush();
    sleep(FLUSH_DEBOUNCE_MS + 300)
      .then((): Promise<FavFlushSummary> => flushFavPushes())
      .then((s: FavFlushSummary): void => {
        if (s.needLogin) {
          this.toast('登录已失效，未能取消 B 站收藏，请重新登录', 2600);
          return;
        }
        if (s.pushDropped > 0) {
          this.toast(`写回 B 站失败 ${s.pushDropped} 首（视频可能已失效）`, 2400);
          return;
        }
        if (s.pushPending > 0) {
          this.toast('B 站暂未确认写回，稍后同步时会自动补推', 2400);
          return;
        }
        if (s.pushed > 0) {
          this.toast('已取消 B 站收藏', 2000);
        }
      })
      .catch((e: Error): void => {
        console.error(`reportFavPushResult failed: ${e.message}`);
      });
  }

  private startDownload(track: Track): void {
    this.requestDownload(track, false);
  }

  /**
   * 发起下载（与 SearchPage 同一套链路）。
   *
   * 分 P 合集会在内核里被展开成多条任务（见 DownloadManager.requestDownload），
   * 所以结果不是布尔而是「排上几首 / 跳过几首」；「仅 WiFi 下载」被拦时
   * 弹一次询问，用户确认后以 override 重入。
   */
  private requestDownload(track: Track, ignoreWifiLimit: boolean): void {
    DownloadManager.getInstance().requestDownload(track, ignoreWifiLimit)
      .then((r: DownloadStartResult): void => {
        if (r.blockedReason.length > 0) {
          this.confirmDownloadOnCellular(track);
          return;
        }
        this.toast(this.downloadResultText(r), 2000);
      })
      .catch((e: Error): void => {
        console.error(`requestDownload failed: ${JSON.stringify(e)}`);
        this.toast('下载启动失败', 1800);
      });
  }

  /** 把下载请求结果翻译成人话：0 条 / 1 条 / N 条要分开说，否则用户不知道合集是不是都排上了 */
  private downloadResultText(r: DownloadStartResult): string {
    if (r.queued === 0) {
      return r.skipped > 0 ? '该歌曲已在下载列表中' : '没有可下载的曲目';
    }
    const head: string = r.queued > 1 ? `已开始下载 ${r.queued} 首` : '已开始下载';
    const tail: string = r.skipped > 0 ? `（另有 ${r.skipped} 首已在列表中）` : '';
    return `${head}，可在「下载」页查看进度${tail}`;
  }

  /** 「仅 WiFi 下载」被触发：先问一句而不是直接拒绝（开关的本意是防偷跑，不是绝对禁用） */
  private confirmDownloadOnCellular(track: Track): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        this.requestDownload(track, true);
      }
    });
  }

  // ===== 曲目多选核心（UpSpacePage 同款口径） =====

  /** 进入多选（头部「选择」按钮）：选区从空起步，条目点击切换选中 */
  private enterSelecting(): void {
    this.selecting = true;
    this.selectedIds = [];
  }

  /** 切换选中（多选态点条目 / 点勾选槽位） */
  private toggleSelected(track: Track): void {
    if (this.selectedIds.indexOf(track.id) >= 0) {
      this.selectedIds = this.selectedIds.filter((id: string): boolean => id !== track.id);
      return;
    }
    const next: string[] = this.selectedIds.slice(0);
    next.push(track.id);
    this.selectedIds = next;
  }

  /** 全选判定：与已揭示切片（this.tracks）比对，全选的是「正在看的那份列表」 */
  private isAllSelected(): boolean {
    if (this.tracks.length === 0) {
      return false;
    }
    for (let i = 0; i < this.tracks.length; i++) {
      if (this.selectedIds.indexOf(this.tracks[i].id) < 0) {
        return false;
      }
    }
    return true;
  }

  /** 全选 / 取消全选（多选动作区按钮） */
  private toggleSelectAll(): void {
    if (this.isAllSelected()) {
      this.selectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (let i = 0; i < this.tracks.length; i++) {
      ids.push(this.tracks[i].id);
    }
    this.selectedIds = ids;
  }

  /** 退出多选（「完成」/ 返回键 / 关键词变化 / 批量移除完成） */
  private exitSelecting(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  /** 选中的曲目（按已揭示切片收口：切片里已不存在的 id 自动略过，不盲信选区） */
  private selectedTracks(): Track[] {
    return this.tracks.filter((t: Track): boolean => this.selectedIds.indexOf(t.id) >= 0);
  }

  // ===== 加入歌单（UpSpacePage 同款：无歌单自动建单兜底 + 选择弹层；多曲批量走 addTracksToPlaylist） =====

  /** 没有任何可加歌单时的兜底：新建歌单并直接加入（名字取自第一首） */
  private createPlaylistAndAdd(tracks: Track[], existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(tracks[0], existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTracksToPlaylist(created.id, tracks);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  /**
   * 打开「加入歌单」选择弹层；可加歌单为空时跳过弹层直接自动建单。
   * 歌单列表走 getAddablePlaylists（过滤 UP 订阅歌单：订阅歌单由订阅机制
   * 维护曲目，手动加歌会被「拉取新投稿」合并逻辑搅乱）。
   */
  private openPickerFor(tracks: Track[]): void {
    if (tracks.length === 0) {
      return;
    }
    const options: Playlist[] = LibraryStore.getAddablePlaylists();
    if (options.length === 0) {
      this.createPlaylistAndAdd(tracks, options);
      return;
    }
    this.playlistOptions = options;
    this.pickerTracks = tracks;
    this.playlistPickerController?.open();
  }

  /** 弹层里的「新建歌单并加入」（省一次跳转；快照沿用弹层打开时的列表，重名检查基于它即可） */
  private createPlaylistFromPicker(): void {
    const tracks: Track[] = this.pickerTracks;
    const options: Playlist[] = this.playlistOptions;
    this.playlistPickerController?.close();
    if (tracks.length > 0) {
      this.createPlaylistAndAdd(tracks, options);
    }
  }

  private addToPlaylistFromPicker(p: Playlist): void {
    const tracks: Track[] = this.pickerTracks;
    this.playlistPickerController?.close();
    if (tracks.length === 0) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTracksToPlaylist(p.id, tracks);
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  /**
   * 多选动作区「加入歌单」：选区曲目开弹层。
   * 加入成功后**保持多选态与选区**（UpSpacePage / DownloadsPage 口径）：用户
   * 可再选一个歌单连着加，不必从头重选。选区清空出口只有「完成」/ 返回键 /
   * 关键词变化 / 批量移除。
   */
  private addSelectedToPlaylist(): void {
    const tracks: Track[] = this.selectedTracks();
    if (tracks.length === 0) {
      this.toast('先选择歌曲', 1500);
      return;
    }
    this.openPickerFor(tracks);
  }

  /**
   * 多选动作区「下载」：先确认，再串行入队（间隔见 PD_ENQUEUE_GAP_MS）。
   * 下载来源标记为本歌单（下载页聚成歌单卡，PlaylistsPage 整单下载同款）。
   * 入队后保持多选态与选区（与「加入歌单」同口径，用户可继续操作选区）。
   */
  private confirmDownloadSelected(): void {
    const tracks: Track[] = this.selectedTracks();
    if (tracks.length === 0) {
      this.toast('先选择歌曲', 1500);
      return;
    }
    showConfirm(this.getUIContext(), {
      title: '下载选中歌曲',
      message: `将把选中的 ${tracks.length} 首歌曲加入下载队列。\n已下载的会自动跳过。`,
      confirmText: '开始下载',
      onConfirm: (): void => {
        this.enqueueSelectedSerial(tracks);
      }
    });
  }

  /**
   * 串行入队 + 每首间隔节流（B 站匿名密集请求直接限流，见
   * PD_ENQUEUE_GAP_MS 注释）。「仅 WiFi 下载」闸门在 requestDownload 入口，
   * 只会在**首条**返回 blockedReason —— 用它探测一次，被拦则询问，
   * 用户确认后整批以 ignoreWifiLimit 重跑（已入队的自动跳过计数，
   * UpSpacePage / PlaylistsPage 同一套逻辑）。
   */
  private async enqueueSelectedSerial(tracks: Track[]): Promise<void> {
    if (this.downloadingSelected) {
      this.toast('正在加入下载队列，请稍候', 1500);
      return;
    }
    this.downloadingSelected = true;
    let queued: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < tracks.length; i++) {
      const r: DownloadStartResult = await DownloadManager.getInstance().requestDownload(
        tracks[i], false, { playlistId: this.playlistId, playlistName: this.titleText });
      if (r.blockedReason.length > 0) {
        // 首条就被「仅 WiFi 下载」拦下：收尾状态交给确认弹窗的两条分支
        this.downloadingSelected = false;
        this.confirmCellularSelected(tracks);
        return;
      }
      queued += r.queued;
      skipped += r.skipped;
      if ((i + 1) % 5 === 0) {
        this.toast(`正在加入下载队列（${i + 1}/${tracks.length}）`, 800);
      }
      if (i < tracks.length - 1) {
        await delay(PD_ENQUEUE_GAP_MS);
      }
    }
    this.downloadingSelected = false;
    this.toast(this.selectedDownloadResultText(queued, skipped), 2500);
  }

  /** 「仅 WiFi 下载」拦下批量下载：问一次（措辞与单曲 confirmDownloadOnCellular 一致） */
  private confirmCellularSelected(tracks: Track[]): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        this.enqueueSelectedWithWifiOverride(tracks);
      }
    });
  }

  /** 用户确认用流量后：整批 ignoreWifiLimit=true 重跑（已入队/已下载的自动跳过） */
  private async enqueueSelectedWithWifiOverride(tracks: Track[]): Promise<void> {
    if (this.downloadingSelected) {
      return;
    }
    this.downloadingSelected = true;
    let queued: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < tracks.length; i++) {
      const r: DownloadStartResult = await DownloadManager.getInstance().requestDownload(
        tracks[i], true, { playlistId: this.playlistId, playlistName: this.titleText });
      queued += r.queued;
      skipped += r.skipped;
      if (i < tracks.length - 1) {
        await delay(PD_ENQUEUE_GAP_MS);
      }
    }
    this.downloadingSelected = false;
    this.toast(this.selectedDownloadResultText(queued, skipped), 2500);
  }

  /** 批量入队结果文案：排上 / 跳过 分开说，用户才知道有多少真进了队列 */
  private selectedDownloadResultText(queued: number, skipped: number): string {
    if (queued === 0 && skipped === 0) {
      return '没有可下载的歌曲';
    }
    if (queued === 0) {
      return `全部已在下载队列中（${skipped} 首）`;
    }
    const tail: string = skipped > 0 ? `，跳过 ${skipped} 首已在队列/已下载` : '';
    return `已加入下载队列 ${queued} 首${tail}`;
  }

  /**
   * 多选动作区「移除」：统一弹确认讲清楚后果（批量是不可逆动作，普通歌单也不免）。
   * 收藏夹镜像沿 confirmRemoveTrack 同一套三态文案（双向 = 实时取消收藏，
   * 单向 = 仅本地、下次同步会回来）。确认后 load() 重载 + 退出多选
   * （选区里的 id 已被移除，保留只会残留死选区）。
   */
  private confirmRemoveSelected(): void {
    const tracks: Track[] = this.selectedTracks();
    if (tracks.length === 0) {
      this.toast('先选择歌曲', 1500);
      return;
    }
    const p: Playlist | null = this.playlist;
    if (p === null) {
      return;
    }
    const ids: string[] = tracks.map((t: Track): string => t.id);
    const countText: string = `选中的 ${tracks.length} 首`;
    if (!LibraryStore.isFavMirror(p)) {
      showConfirm(this.getUIContext(), {
        title: '从歌单移除',
        message: `确定从「${p.name}」移除${countText}吗？`,
        confirmText: '移除',
        onConfirm: (): void => {
          LibraryStore.removeTracksFromPlaylist(this.playlistId, ids);
          this.load();
          this.exitSelecting();
          this.toast('已移除', 1500);
        }
      });
      return;
    }
    if (isFolderTwoway(LibraryStore.favMediaIdOf(p))) {
      showConfirm(this.getUIContext(), {
        title: '取消收藏并移除',
        message: `「${p.name}」已开启双向同步，移除${countText}将同时取消 B 站收藏夹中的这些收藏。`,
        confirmText: '取消收藏并移除',
        onConfirm: (): void => {
          // store 挂钩会自动把移除意图实时推送到 B 站（失败自动补推）
          LibraryStore.removeTracksFromPlaylist(this.playlistId, ids);
          this.load();
          this.exitSelecting();
          this.toast('已移除，正在同步到 B 站…', 2000);
          this.reportFavPushResult();
        }
      });
      return;
    }
    showConfirm(this.getUIContext(), {
      title: '从收藏夹镜像移除',
      message: `「${p.name}」是 B 站收藏夹的镜像。同步为单向（B 站 → 本地），移除${countText}不会取消 B 站收藏，下次同步这些歌曲会重新出现。`,
      confirmText: '仅本地移除',
      onConfirm: (): void => {
        LibraryStore.removeTracksFromPlaylist(this.playlistId, ids);
        this.load();
        this.exitSelecting();
        this.toast('已从本地移除（下次同步会重新出现）', 2000);
      }
    });
  }

  /**
   * 头部区（整体钉在悬浮固定栏内，不随列表滚动）：
   * 左侧 96vp 圆角封面（CoverImage 自带空图 / 失败占位），
   * 右侧 28fp 大标题 + 元信息行 + 可选简介；封面行下方是操作按钮行
   * （播放全部 / 拉取新投稿）。
   * 数据全部来自 load() 预计算的派生字段（coverUrl / metaText / descText），
   * @Builder 体内不声明局部变量、不对 playlist 判空。
   */
  @Builder
  PlaylistHeader(): void {
    Column() {
      Row() {
        CoverImage({
          url: this.coverUrl,
          imgWidth: 96,
          imgHeight: 96,
          imgRadius: 12,
          altText: this.titleText
        })
        Column() {
          Text(this.titleText)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.metaText.length > 0) {
            Text(this.metaText)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
          }
          if (this.descText.length > 0) {
            Text(this.descText)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
          }
        }
        .layoutWeight(1)
        .margin({ left: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 操作按钮行：随头部区一起滚动（用户明确不要钉在顶部固定栏）。
      // 行内 Stack 整行换层：常态行 = 播放全部 + 选择 + 拉取新投稿 + 排序 + 搜索框，
      // 多选行 = 完成 + 全选 / 加入歌单 / 下载 / 移除。
      // · 播放全部：有曲目才显示；样式与 RecentPage 逐字一致（真机约束，勿动）。
      // · 拉取新投稿：订阅歌单（upMid 非空）才显示，空的订阅歌单也保留它 ——
      //   正好是一键填歌单的入口。
      // ⚠️ 不用「按钮 visibility 摘布局 + 尾部槽位换层」旧结构：退出多选时常态
      //   按钮瞬时回位，尾部槽位连同正在淡出的动作行一起被推向右侧（真机表现：
      //   动作组「向右消失」而非淡出）。整行换层让两层几何在转场期间恒定，
      //   交叉纯淡出（CollectionDetailPage 槽位行 B 同款模式）。
      // ⚠️ 隐藏层必须条件渲染（不挂载），不能双层叠放 + 透明层：
      //   HitTestMode.None 只豁免容器自身，子按钮仍响应点击（真机复现：
      //   常态点搜索框位置误触透明的「加入歌单」/「移除」，搜索框要点多次）。
      Row({ space: 8 }) {
        if (this.playlist && this.playlist.tracks.length > 0) {
        Stack() {
        if (!this.selecting) {
        // 常态行：播放全部 + 选择 + 拉取新投稿 + 排序 + 搜索框
        Row({ space: 8 }) {
          // 真机要求：与 RecentPage 播放全部逐字一致（浅粉底 + 粉字 + 沉浸光感）
          Button('播放全部', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              if (this.playlist) {
                this.player.playAll(this.playlist.tracks);
              }
            })
        // 选择：多选入口（完成在多选行最前，两行整行交叉淡出）
        if (this.playlist && this.playlist.tracks.length > 0) {
          Button('选择', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.enterSelecting();
            })
        }
        // 「拉取新投稿」只对订阅 UP 歌单开放；收藏夹镜像走同步页的「立即同步」，
        // 不能出现在这里（会把 fav_ id 当 UP mid 去请求）
        if (this.playlist && LibraryStore.isUpSubscription(this.playlist)) {
          Button(this.upRefreshing ? '正在拉取…' : '拉取新投稿', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .enabled(!this.upRefreshing)
            .onClick((): void => {
              this.refreshUpTracks();
            })
        }
        // 「排序」入口：长按拖动排序管「手动微调」，这颗按钮管
        // 「一键排序」（按名称拼音升序 / 按时长降序 / 按播放量降序，见 sortMenuItems）。
        // 与拖动同一闸门（canReorder）：收藏夹镜像顺序由 B 站服务端决定，不开放；
        // 空歌单没东西可排，不显示。
        if (this.canReorder() && this.playlist && this.playlist.tracks.length > 0) {
          Button('排序', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .bindMenu(this.sortMenuItems())
        }
        // 搜索框（尾部 layoutWeight 1 收窄适应）：输入即本地过滤歌单内曲目
        //（标题 / 歌手，离线可用；过滤重算 200ms 防抖，见 onKeywordChanged）；
        // 框内右侧 × = 清除。无「搜索」按钮 —— 歌单数据全在本地，没有远程搜索。
        // UI 收口在 SearchBox 共享组件（材质 / × 清除逻辑三页同一份实现）。
          SearchBox({
            placeholder: '搜索歌单内歌曲',
            keyword: this.searchKeyword,
            clearVisible: this.searchKeyword.trim().length > 0,
            onKeywordChange: (v: string): void => {
              this.searchKeyword = v;
              this.onKeywordChanged();
            },
            onClear: (): void => {
              this.clearSearch();
            }
          })
          .layoutWeight(1)
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY
          .animation({ duration: PD_SELECT_FADE_MS, curve: Curve.EaseInOut }))
        }
        // 多选行：完成 + 全选 / 加入歌单 / 下载 / 移除（与常态行整行交叉淡出）。
        // 动作按钮不带计数（窄屏放不下，空选区由各动作方法 toast 兜底）；
        // 动作按钮左右 padding 收紧到 10vp：多选行 5 元素，
        // 默认 16vp padding 在 360vp 窄屏放不下。
        if (this.selecting) {
        Row({ space: 8 }) {
          Button('完成', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.exitSelecting();
            })
          Button(this.isAllSelected() ? '取消全选' : '全选', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.toggleSelectAll();
            })
          Button('加入歌单', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.addSelectedToPlaylist();
            })
          Button('下载', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.confirmDownloadSelected();
            })
          // 移除放最后：破坏性操作与安全操作分开（trackMenuItems 同款原则）
          Button('移除', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.confirmRemoveSelected();
            })
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY
          .animation({ duration: PD_SELECT_FADE_MS, curve: Curve.EaseInOut }))
        }
        }
        // ⚠️ 固定高度（faqs-arkui-384 同款结论）：换层期间退场节点脱离布局，
        // 容器无固定尺寸会塌缩、退场动画按塌缩位置渲染。固定 32 = 按钮高。
        .layoutWeight(1)
        .height(32)
        }
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 头部区间距：top 4 紧贴标题行下沿，bottom 8 让首个曲目条目同步上移
    //（列表占位随 headerAreaHeight 实测自动跟随）。
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 无标题（歌单名只在头部区大标题显示一次，返回键为 HDS 默认键），
   * 尾部插槽装「定位」按钮（滚动居中到正在播放的曲目行）。
   * 材质与滚动模糊由 HDS titleBar 负责。
   */
  /** 标题行尾部「定位」按钮（trailing 插槽内容，样式与 PlaylistsTabBar「定位」一致） */
  @Builder
  LocateTrailing() {
    Button('定位', { type: ButtonType.Normal })
      .fontSize(13)
      .height(32)
      .borderRadius(BUTTON_RADIUS_VP)
      .backgroundColor(this.themeSurface)
      .fontColor(this.themePrimary)
      .attributeModifier(this.buttonMaterial)
      .onClick((): void => {
        this.locateCurrentPlaying();
      })
  }

  @Builder
  playlistBar() {
    NavTitleRow({
      title: '',
      // 标题行右侧「定位」按钮：滚动居中到正在播放的曲目行
      //（经 @Builder 委托，与上方「加入歌单」弹窗 contentBuilder 同款传法）。
      trailing: (): void => {
        this.LocateTrailing();
      }
    })
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载）：歌单头部区
   * （封面 / 歌单名 / 元信息 / 简介 / 操作按钮）。
   * ⚠️ bottomBuilder 高度不自适应（官方约束），内层 Column 是天然高的实测载体——
   * onAreaChange 挂内层根节点，回写 headerAreaHeight（随简介行数浮动）；
   * 实测前用估计高度垫底防 0 高闪跳。
   */
  @Builder
  playlistHeaderArea() {
    Column() {
      Column() {
        this.PlaylistHeader()
      }
      .width('100%')
      .onAreaChange((_old: Area, cur: Area): void => {
        const h: number = cur.height as number;
        if (h > 0) {
          this.headerAreaHeight = h;
        }
      })
    }
    .width('100%')
  }

  /**
   * 标题行收窄容器（平板模式宽度适配）：HDS titleBar 的 stackBuilder
   * 横跨目的地整列全宽，而本页条目内容列被 constraintSize 收窄居中 —— 大屏上
   * 标题行会贴到整列左缘、与居中条目错位。外层 Row 居中 + 内层 Column
   * constraintSize（上限与本页内容列 constraintSize 完全同口径：两列 840 /
   * 可排序歌单恒单列 600/720），标题行与条目列同宽对齐；两侧空白区
   * hitTestBehavior(Transparent) 穿透点击。sm 回退 600（窗口 <600vp）
   * 天然无操作，手机零变化。
   */
  @Builder
  playlistBarNarrow() {
    Row() {
      Column() {
        this.playlistBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: this.isTwoCol()
        ? BreakpointConstants.CONTENT_MAX_WIDTH_TWOCOL
        : BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 歌单头部区收窄容器（平板模式宽度适配）：同 playlistBarNarrow
   * 口径 —— bottomBuilder 也横跨整列全宽，收窄后封面 / 歌单名 / 操作按钮与
   * 曲目列同宽对齐；bottomBuilder 显式高度（实测 headerAreaHeight / 估计值
   * 垫底）不动，内层 onAreaChange 实测载体原样保留（高度不受收窄影响）。
   */
  @Builder
  playlistHeaderAreaNarrow() {
    Row() {
      Column() {
        this.playlistHeaderArea()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: this.isTwoCol()
        ? BreakpointConstants.CONTENT_MAX_WIDTH_TWOCOL
        : BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 「加入歌单」弹窗正文（官方 CustomContentDialog，UpSpacePage /
   * DownloadsPage 同款；多曲时曲名行带「等 N 首」）。
   * 标题在 primaryTitle；取消在 buttons 槽（自动关闭）。
   */
  @Builder
  PlaylistPickerBody(): void {
    Column() {
      // 曲名行：多选批量显示「曲名 等 N 首」
      Text(this.pickerTracks.length > 1
        ? `${this.pickerTracks[0].title} 等 ${this.pickerTracks.length} 首`
        : (this.pickerTracks.length > 0 ? this.pickerTracks[0].title : ''))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: 12 })
      // 第一项就是「新建歌单并加入」：想单独存歌时不必再跑到歌单页
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
    }
    .width('100%')
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          // 列表挂载门控（见 headerAreaHeight 注释）：等头部区首次实测完成再挂载。
          // ⚠️ 不能用 barTotalHeight() > 0 当门控 —— safeTop + 56 恒 > 0，门控形同虚设，
          // 列表会在 headerAreaHeight 实测前挂载并固化 safeTop + 56 的错误让位量
          // （首项被封面压住，真机复现）；必须直接判 headerAreaHeight > 0。
          if (this.playlist && this.playlist.tracks.length > 0 && this.headerAreaHeight > 0) {
            List({ scroller: this.listScroller }) {
              // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在
               // 屏幕顶端（y=0）。占位高度 = 标题栏总让位量（barTotalHeight：
               // safeTop + 56 + 头部区实测高，随简介行数浮动），首个真实条目恰从
               // 栏底起排，滚动时占位与条目一起从沉浸材质下方穿过。
              // 头部区已钉顶（固定栏），占位后的列表只装曲目行：ForEach 的
              // index 是已揭示切片内下标（0 起，对应第一首曲目），TrackItem.entranceIndex 不受影响。
              ListItem() {
                // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
               // 条目渲染（SearchPage 同款）：@State tracks 切片数组直接驱动 ForEach。
               // 多选三件套（selecting / selected / onToggleSelect）直接接线：
               // 本页三分支全部是 ForEach（无需 UpSpacePage 的 ForEach/LazyForEach
               // 双路径），@State 变化重跑 itemGenerator 就地更新勾选回显。
               // 长按拖动排序：ForEach.onMove 是官方推荐路线（系统自带
              // 浮起/让位动画 + 拖到列表边缘自动滚动；List.onItemDragStart 路线拖到
              // 边缘不滚动，见 list.d.ts 注释）。onMove 下标限定在 ForEach 数据
              //（this.tracks 切片）内，自动避开首尾占位/状态条目；系统只在**松手后**
              // 回调一次，落库与刷新见 onTrackMove。
              // 收藏夹镜像禁用：canReorder() 为 false 时传 undefined = 不注册，
              // 长按不浮起（顺序由 B 站服务端决定，完整同步会覆盖手动顺序）。
              //
               // 横屏宽屏：不可排序歌单条目配对，每个
              // ListItem 左右两列；可排序歌单（isTwoCol() 已含 !canReorder 门控）
              // 走单列 + onMove，拖动排序不受影响。
              //
               // 大封面模式（外观设置「条目展示」）：不可排序歌单
              // （收藏夹镜像等）的曲目配对成双列网格卡（TrackCard），竖屏 /
              // 横屏均双列；可排序歌单恒为长条（isGrid() 已含 !canReorder 门控，
              // 拖动排序优先于展示样式）。已下载徽标读 @State downloadedIds。
              if (this.isGrid()) {
                ForEach(
                  makePairs<Track>(this.tracks),
                  (pair: PairOf<Track>): void => {
                    ListItem() {
                        Row() {
                          TrackCard({
                            track: pair.first,
                            downloaded: this.isDownloaded(pair.first),
                            onPlay: (tr: Track): void => {
                              this.player.playOrToggle(tr);
                            },
                            moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
                            selecting: this.selecting,
                            selected: this.selectedIds.indexOf(pair.first.id) >= 0,
                            onToggleSelect: (tr: Track): void => {
                              this.toggleSelected(tr);
                            }
                          }).layoutWeight(1)
                         // 固定宽间隔条（非 weighted）：两卡均 layoutWeight(1) 且零
                         // margin → 左右封面严格等宽（layoutWeight 份额含 margin，
                         // margin 挂 weighted 卡会让该卡窄 12vp）；奇数末行也保留
                         // 间隔条，末卡与满行卡等宽。
                         Blank().width(TWO_COL_GAP_VP)
                          if (pair.second !== null) {
                            TrackCard({
                              track: pair.second,
                              downloaded: this.isDownloaded(pair.second),
                              onPlay: (tr: Track): void => {
                                this.player.playOrToggle(tr);
                              },
                              moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
                              selecting: this.selecting,
                              selected: this.selectedIds.indexOf(pair.second.id) >= 0,
                              onToggleSelect: (tr: Track): void => {
                                this.toggleSelected(tr);
                              }
                            }).layoutWeight(1)
                         } else {
                           // 奇数末尾：右侧槽留空占位，左列卡宽与前面各行一致
                           Blank().layoutWeight(1)
                         }
                       }
                       .width('100%')
                        // 网格行页边距：两边留白 + 封面整体
                       // 缩小约 15%，见 GRID_EDGE_PADDING_VP 注释。
                       .padding({ left: GRID_EDGE_PADDING_VP, right: GRID_EDGE_PADDING_VP })
                        // Top 对齐：卡高随标题行数浮动，
                       // Row 默认 Center 会把矮卡垂直居中 → 左右封面错位；
                       // Top 让左右封面严格同高起步。
                       .alignItems(VerticalAlign.Top)
                    }
                  },
                  (pair: PairOf<Track>): string =>
                    `${pair.first.id}|${pair.second !== null ? pair.second.id : 'x'}`
                )
              } else if (this.isTwoCol()) {
                ForEach(
                  makePairs<Track>(this.tracks),
                  (pair: PairOf<Track>, pIndex: number): void => {
                    ListItem() {
                      Row() {
                         TrackItem({
                           track: pair.first,
                           entranceIndex: pIndex * 2,
                           // 已下载徽标：读 @State downloadedIds，下载完成的
                           // 快照到达时可见行局部刷新出徽标
                           downloaded: this.isDownloaded(pair.first),
                           onPlay: (tr: Track): void => {
                             this.player.playOrToggle(tr);
                           },
                           moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
                           selecting: this.selecting,
                           selected: this.selectedIds.indexOf(pair.first.id) >= 0,
                           onToggleSelect: (tr: Track): void => {
                             this.toggleSelected(tr);
                           }
                         }).layoutWeight(1)
                         if (pair.second !== null) {
                           TrackItem({
                             track: pair.second,
                             entranceIndex: pIndex * 2 + 1,
                             downloaded: this.isDownloaded(pair.second),
                             onPlay: (tr: Track): void => {
                               this.player.playOrToggle(tr);
                             },
                             moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
                             selecting: this.selecting,
                             selected: this.selectedIds.indexOf(pair.second.id) >= 0,
                             onToggleSelect: (tr: Track): void => {
                               this.toggleSelected(tr);
                             }
                           }).layoutWeight(1).margin({ left: TWO_COL_GAP_VP })
                        } else {
                          // 奇数末尾：右侧槽留空占位，左列行宽与前面各行一致
                          Blank().layoutWeight(1)
                        }
                      }
                      .width('100%')
                    }
                  },
                  (pair: PairOf<Track>): string =>
                    `${pair.first.id}|${pair.second !== null ? pair.second.id : 'x'}`
                )
              } else {
                ForEach(
                  this.tracks,
                  (t: Track, index: number): void => {
                    ListItem() {
                     TrackItem({
                         track: t,
                         entranceIndex: index,
                          // 已下载徽标：读 @State downloadedIds，
                          // 下载完成的快照到达时可见行局部刷新出徽标（保留节点读
                          // @State 是活的，与下载页「正在播放」同一机制）
                         downloaded: this.isDownloaded(t),
                         onPlay: (tr: Track): void => {
                           this.player.playOrToggle(tr);
                         },
                         moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
                         selecting: this.selecting,
                         selected: this.selectedIds.indexOf(t.id) >= 0,
                         onToggleSelect: (tr: Track): void => {
                           this.toggleSelected(tr);
                         }
                       })
                    }
                  },
                  (t: Track): string => t.id
                )
                  .onMove(this.canReorder() && !this.selecting && this.searchKeyword.trim().length === 0
                    ? (from: number, to: number): void => {
                      this.onTrackMove(from, to);
                    }
                    : undefined)
              }
              // 搜索状态行（关键词激活时常驻，UpSpacePage footer 口径对齐）：
              // 命中 N 首给计数，0 命中给人话提示。
              //（底部状态行门控 tracks.length > 0，0 命中时不与「没有匹配」同现。）
              if (this.searchKeyword.trim().length > 0) {
                ListItem() {
                  Text(this.filteredTracks.length > 0
                    ? `命中 ${this.filteredTracks.length} 首歌曲`
                    : '没有匹配的歌曲')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              // 加载更多状态条（SearchPage 同款）：本地切片即时揭示，没有加载中态，
              // 只区分「上拉加载更多」与「已经到底啦」。
              if (this.tracks.length > 0) {
                ListItem() {
                  Column() {
                    if (!this.hasMoreTracks()) {
                      Text('已经到底啦')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    } else {
                      Text('上拉加载更多')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                  }
                  .width('100%')
                  .padding({ top: 14, bottom: 14 })
                  .justifyContent(FlexAlign.Center)
                }
              }
            }
            .layoutWeight(1)
            // 边界回弹：到顶/到底的反馈动效
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            // 列表末端常规留白 + 前端切片上拉加载（SearchPage 排行榜页签同款）。
            .contentEndOffset(CONTENT_END_OFFSET)
            .onReachEnd((): void => {
              this.onReachEnd();
            })
            // 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已应用
            // 后回调，onWillScroll 是应用前，快滑时差一帧会让模糊层滞后一跳）。
            .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
              this.syncTopBlurProgress();
            })
            .onScrollStop((): void => {
              // Idle 校准终态：兜住 Fling 期丢帧 / 死区过滤累计的偏差。
              this.syncTopBlurProgress();
            })
            // 顶部 HDS 标题栏让位（Sumy 式穿透）：由 List 首个空白占位 ListItem 负责
            //（见上方占位注释，下载页同款），不用 contentStartOffset。
          } else if (!this.playlist || this.playlist.tracks.length === 0) {
            Column() {
              Text('歌单还是空的')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text('在搜索页点击“⋯”把歌曲加进来吧')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .margin({ top: 8 })
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            // 内容列不再整体 padding top（列表穿透需要），空态自己补让位（标题栏总让位量）
            .padding({ top: this.barTotalHeight() })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // ⚠️ 不再整体 padding top / safeAreaPadding top：列表视口要铺满全屏
        // （List 首个空白占位 ListItem 负责让出「状态栏+原生栏+头部条带」），
        // 滚动时曲目从头部材质下穿过；底部不做避让，沉浸到底（与
        // 关注/最近页同口径，见目的地链上的 ignoreLayoutSafeArea 声明）。
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给内容列挂上限即可。
        // 横屏宽屏：上限放宽到 840vp；可排序歌单
        //（isTwoCol() 含 !canReorder 门控，恒单列）维持原收窄值。
        .constraintSize({ maxWidth: this.isTwoCol()
          ? BreakpointConstants.CONTENT_MAX_WIDTH_TWOCOL
          : BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })

        // 顶栏渐变模糊层：盖内容列之上（z 序低于 HDS
        // titleBar，歌单头部区属标题栏 bottomBuilder、随整栏一起盖），进度由
        // 列表 onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏（真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // stackBuilder / bottomBuilder 均走收窄容器
    //（playlistBarNarrow / playlistHeaderAreaNarrow），标题行与歌单头部区和
    // 曲目列同宽对齐。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：空占位（返回键为 HDS 默认键；收窄容器内）
        stackBuilder: (): void => {
          this.playlistBarNarrow();
        },
        // 标题行下方自定义区：歌单头部区（封面 / 歌单名 / 简介 / 操作按钮，
        // 收窄容器内与曲目列对齐）。
        // ⚠️ 头部区不能塞进 stackBuilder（会溢出 56vp 标题行、与列表内容重叠，
        // 真机复现），必须走 bottomBuilder；高度用实测值（未实测时估计值垫底）。
        bottomBuilder: {
          builder: (): void => {
            this.playlistHeaderAreaNarrow();
          },
          height: this.headerAreaHeight > 0 ? this.headerAreaHeight : PLAYLIST_HEADER_ESTIMATE_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    // 返回键：用 HDS 默认返回键（"<" 系统样式，位置由 HDS 管理以避开状态栏）。
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：多选态先退出多选（选区清空，留在本页）；否则播放页 overlay
    // 打开时吞掉返回并发收起请求（留在本页），再否则走默认 pop —— 详见
    // utils/SubPageBackPress。
    .onBackPressed((): boolean => {
      if (this.selecting) {
        this.exitSelecting();
        return true;
      }
      return handleSubPageBackPress();
    })
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由顶部占位条目 / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 已不再静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function PlaylistDetailBuilder(): void {
  PlaylistDetail()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const PlaylistDetailWrapped: WrappedBuilder<[]> = wrapBuilder(PlaylistDetailBuilder);

