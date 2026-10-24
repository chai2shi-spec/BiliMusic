/**
 * 歌单详情页：展示歌单内单曲，支持播放全部 / 单曲播放 / 加入队列 / 从歌单移除 /
 * 长按拖动排序 / 一键排序（按名称 / 时长 / 播放量，2026-10-22）。
 * 排序开放范围：普通歌单 + 订阅 UP 歌单；收藏夹镜像禁用（顺序由 B 站服务端决定，
 * 完整同步会覆盖手动顺序）。目标歌单 id 由路由参数 PlaylistDetailRouteParam 传入。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 标题行 + 头部区，批 1 样板同款；返回键为 HDS 默认键）；栏内不放标题文字
 * （歌单名只在头部区 28fp 大标题显示一次），标题行为空占位。
 * avoidLayoutSafeArea 后栏顶 = safeTop，滚动时曲目从沉浸材质下穿过；
 * 侧滑返回是 Navigation 级能力，不受影响。
 *
 * 钉顶头部区：整个头部区「封面 + 28fp 大标题 + 元信息/简介 + 播放全部/拉取新投稿」
 * 接在标题行下，仅曲目列表滚动并从材质下透出；
 * 重命名 / 删除歌单入口在歌单列表页行内 ⋮ 菜单。
 */

import { Playlist, Track, DownloadTask, DownloadStatus, buildTrack, VideoDetail } from '../model/MusicModels';
import { LibraryStore, PlaylistSortKey } from '../service/LibraryStore';
import * as BilibiliApi from '../api/BilibiliApi';
import { SpaceVideo } from '../api/BilibiliApi';
import { toHttpsUrl, stripHtmlTags, parseDurationText } from '../utils/TextUtil';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { CoverImage } from '../components/CoverImage';
// 菜单弹层（2026-10-08）：曲目菜单从双按钮 AlertDialog 换成 MenuDialog ——
// 新增「下载」后动作到三个，AlertDialog 只有两颗按钮放不下。
import { showAppAlertDialog } from '../components/AppAlertDialog';
// 下载链（2026-10-08）：与 SearchPage 同一套（requestDownload → 仅 WiFi 拦截询问 → toast 回执）
import { DownloadManager, DownloadStartResult, WIFI_ONLY_BLOCKED } from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import { PlaylistDetailRouteParam, NavRouteParamReader, UpSpaceRouteParam } from '../service/NavRouteParams';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import {
  CONTENT_END_OFFSET,
  STORE_DOWNLOAD_TASKS,
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
 * 歌单头部区（bottomBuilder 承载）实测前的估计高度：封面行 + 元信息 + 简介 + padding。
 * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定；实测值
 * （headerAreaHeight）回来后覆盖，此值只防首次布局 0 高闪跳。
 * 2026-10-22 头部区间距 top 12→4、bottom 16→8 后同步 -16。
 */
const PLAYLIST_HEADER_ESTIMATE_HEIGHT: number = 174;

@Component
export struct PlaylistDetail {
  /** 曲目列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 头部按钮（播放全部 / 拉取新投稿）沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  @State playlist: Playlist | null = null;
  @State titleText: string = '歌单';
  /** 「拉取新投稿」进行中：防止连点重复发请求 */
  @State upRefreshing: boolean = false;
  /**
   * 歌单头部区实测高（vp，bottomBuilder 内层根节点 onAreaChange 回写，随简介行数浮动）。
   * ⚠️ 初值必须为 0（2026-10-08 修复首项被钉顶栏遮挡）：歌单数据来自本地缓存，
   * 列表带着条目与初值一起挂载会让占位条目先按不含头部区的让位量排布、实测回来
   * 再整体下移（内容跳变）。列表挂载门控直接判 headerAreaHeight > 0（见 build 里的
   * if）——barTotalHeight() 恒 > 0 不能当门控。
   */
  @State headerAreaHeight: number = 0;

  /** 目标歌单 id（路由参数 PlaylistDetailRouteParam 带入，aboutToAppear 取参一次） */
  private playlistId: string = '';

  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 头部区实测高。
   * 头部区高度随简介行数浮动，无法定值，沿用「实测 + 挂载门控」机制。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + this.headerAreaHeight;
  }

  /**
   * [任务③·推广二级页] 自绘顶栏渐变模糊层进度更新器 + 校准（SearchPage 原型
   * 推广，四页签同款）：onDidScroll / onScrollStop 命令式驱动 opacity（不标
   * @State，滚动高频回调零重建）；yOffset 0 → TITLE_BLUR_END_VP 线性映射
   * 0 → 1（updater 内截断，边缘回弹负偏移归零 = 用户方案 ③ 死区）。
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

  /** 主题色运行时值：头部按钮浅底 / 主色 / 深字跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时曲目条目两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  private player: MusicPlayer = MusicPlayer.getInstance();

  /**
   * 横屏宽屏时两列显示（2026-10-23 两列改造）。
   *
   * ⚠️ 可拖动排序的本地歌单（canReorder()）**保持单列**：ForEach.onMove 的
   * 长按拖动排序以 ListItem 为单位，配对后拖动会以「一对」为单位错乱 ——
   * 有意取舍，不是遗漏。收藏夹镜像等不可排序歌单横屏照常两列。
   */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape)
      && !this.canReorder();
  }

  /**
   * 下载任务快照（2026-10-08）：订阅它只为派生「哪些曲目已下载完成」
   * （下载完成 / 删除时徽标要即时出现 / 消失），本页不做下载管理。
   */
  @StorageLink(STORE_DOWNLOAD_TASKS) @Watch('onDownloadTasks') downloadTasks: DownloadTask[] = [];
  /**
   * 已下载完成的曲目 id 集合（2026-10-08）。刻意用数组而不是 Set ——
   * @State 感知不到 Set 的内容变化（与 DownloadsPage.selectedIds 同一坑）。
   * 曲目行读它显示「已下载」徽标；精确匹配（见 isDownloaded 注释）。
   */
  @State downloadedIds: string[] = [];

  /**
   * 列表已揭示的曲目切片（SearchPage 排行榜页签同款前端分页）：
   * 全量在 this.playlist.tracks（本地数据，不发请求），onReachEnd 每次多放
   * PD_REVEAL_PAGE_SIZE 条；load() 重载时保留已揭示的条数（至少一批），
   * 删曲目 / 合并新投稿后列表不跳回第一批。
   */
  @State tracks: Track[] = [];

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
    // [任务③·推广二级页] 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
    // 路由入参（2026-10-22 传参改造）：目标歌单 id 随 pushPathByName 入栈，
    // 读取器内部 getParamByName 取回 + instanceof 判型（返回已判型对象或 null）。
    const routeParam: PlaylistDetailRouteParam | null =
      NavRouteParamReader.readPlaylistDetailParam(NavStackHolder.stack);
    this.playlistId = routeParam !== null ? routeParam.playlistId : '';
    this.load();
    // @Watch 不为 @StorageLink 的初始同步触发（工程内已踩过两次的坑），
    // 这里必须补一次已下载集合的初算；ensureLoaded 幂等 —— AppContainer 启动链
    // 已装填过的话这是空操作，冷启动直接进本页时它负责推第一份快照。
    this.rebuildDownloadedIds();
    DownloadManager.getInstance().ensureLoaded().catch((e: Error): void => {
      console.error(`load downloads failed: ${JSON.stringify(e)}`);
    });
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
    // 揭示切片：保留已看过的条数（删曲目 / 拉新投稿重载后列表不跳回第一批），至少一批
    const all: Track[] = p ? p.tracks : [];
    const keep: number = Math.max(this.tracks.length, PD_REVEAL_PAGE_SIZE);
    this.tracks = all.slice(0, Math.min(keep, all.length));
  }

  /** 是否还有未揭示的曲目（底部状态行与 onReachEnd 闸门共用） */
  private hasMoreTracks(): boolean {
    return this.playlist !== null && this.tracks.length < this.playlist.tracks.length;
  }

  /**
   * List 的 onReachEnd（SearchPage 排行榜页签同款，纯前端切片不发请求）：
   * 每次多放一批；没有下一批时直接返回（短列表首帧布局触发的空回调不做事）。
   */
  private onReachEnd(): void {
    const p: Playlist | null = this.playlist;
    if (p === null) {
      return;
    }
    const all: Track[] = p.tracks;
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

  /**
   * 本歌单是否开放「长按拖动排序 / 自动排序」（2026-10-22 用户确认的范围）：
   * 普通歌单 + 订阅 UP 歌单可排；**收藏夹镜像禁用** —— applyFavMirror 双向同步
   * 会按 B 站服务端顺序整体重建，手动顺序会被覆盖，开放只会误导用户。
   */
  private canReorder(): boolean {
    return this.playlist !== null && !LibraryStore.isFavMirror(this.playlist);
  }

  /**
   * 长按拖动排序落库（ForEach.onMove 回调，2026-10-22）。
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
    if (p === null || from < 0 || from >= this.tracks.length) {
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
   * 「排序」菜单项（bindMenu，2026-10-22）：按名称（拼音升序，复用
   * LibraryStore.compareByTitle 同款比较器）/ 按时长（降序）/ 按播放量（降序）/
   * 按加入时间（降序，新在前；存量无戳条目首排时物化，见 materializeAddedAt）。
   * 自动排序是一次性动作，不打开旧的 titleSorted 持续规则（见 sortPlaylistTracks 注释）。
   */
  private sortMenuItems(): MenuElement[] {
    return [
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
  }

  /** 执行自动排序并 toast 回执（歌单不存在 = 菜单打开期间被删，静默返回） */
  private applyAutoSort(sortKey: PlaylistSortKey, toastText: string): void {
    const sorted: Playlist | null = LibraryStore.sortPlaylistTracks(this.playlistId, sortKey);
    if (sorted !== null) {
      this.toast(toastText, 1500);
    }
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
        // 拉新结果同步回 UP 主页缓存（2026-10-23）：重进 UP 页即显示本次拉到的最新一页
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
   * 拉新结果同步回 UP 主页缓存（2026-10-23）：歌单页拉新只写歌单，UP 主页缓存里
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
   * 曲目「⋯」菜单（2026-10-08，阶段 2 迁移为 bindMenu + MenuElement 数组）。
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
   * 收藏夹镜像：同步是单向的（B 站 → 本地），本地移除**不会取消 B 站收藏**，
   *   只动本地 —— 但要弹确认讲清楚「下次同步会重新出现」，避免用户误以为
   *   删掉的就是 B 站收藏。
   */
  private confirmRemoveTrack(track: Track): void {
    const p: Playlist | null = this.playlist;
    if (p === null || !LibraryStore.isFavMirror(p)) {
      // 普通歌单：原行为，不打扰用户
      LibraryStore.removeTracksFromPlaylist(this.playlistId, [track.id]);
      this.load();
      return;
    }
    showAppAlertDialog(this.getUIContext(), {
      title: '从收藏夹镜像移除',
      message: `「${p.name}」是 B 站收藏夹的镜像。同步为单向（B 站 → 本地），移除不会取消 B 站收藏，下次同步这首歌会重新出现。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 取消：不做任何事
        }
      },
      secondaryButton: {
        value: '仅本地移除',
        action: (): void => {
          LibraryStore.removeTracksFromPlaylist(this.playlistId, [track.id]);
          this.load();
          this.toast('已从本地移除（下次同步会重新出现）', 2000);
        }
      }
    });
  }

  private startDownload(track: Track): void {
    this.requestDownload(track, false);
  }

  /**
   * 发起下载（与 SearchPage 同一套链路，2026-10-08）。
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
    showAppAlertDialog(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      primaryButton: {
        value: '取消'
      },
      secondaryButton: {
        value: '继续下载',
        action: (): void => {
          this.requestDownload(track, true);
        }
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
      // 播放全部：有曲目才显示；拉取新投稿：订阅歌单（upMid 非空）才显示，
      // 空的订阅歌单也保留它 —— 正好是一键填歌单的入口。
      Row({ space: 8 }) {
        if (this.playlist && this.playlist.tracks.length > 0) {
          Button('播放全部', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            // 真机要求：与 RecentPage 播放全部逐字一致（浅粉底 + 粉字 + 沉浸光感）
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              if (this.playlist) {
                this.player.playAll(this.playlist.tracks);
              }
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
            .fontColor(this.themeDeep)
            .attributeModifier(this.buttonMaterial)
            .enabled(!this.upRefreshing)
            .onClick((): void => {
              this.refreshUpTracks();
            })
        }
        // 「排序」入口（2026-10-22）：长按拖动排序管「手动微调」，这颗按钮管
        // 「一键排序」（按名称拼音升序 / 按时长降序 / 按播放量降序，见 sortMenuItems）。
        // 与拖动同一闸门（canReorder）：收藏夹镜像顺序由 B 站服务端决定，不开放；
        // 空歌单没东西可排，不显示。
        if (this.canReorder() && this.playlist && this.playlist.tracks.length > 0) {
          Button('排序', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themeDeep)
            .attributeModifier(this.buttonMaterial)
            .bindMenu(this.sortMenuItems())
        }
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 头部区间距（2026-10-22 用户要求上移）：top 12→4 紧贴标题行下沿，
    // bottom 16→8 让首个曲目条目同步上移（列表占位随 headerAreaHeight 实测自动跟随）。
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 空占位，无标题 —— 歌单名只在头部区大标题显示一次（返回键为 HDS 默认键）。
   * 材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  playlistBar() {
    NavTitleRow({ title: '' })
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
   * 标题行收窄容器（2026-10-23 平板模式宽度适配）：HDS titleBar 的 stackBuilder
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
   * 歌单头部区收窄容器（2026-10-23 平板模式宽度适配）：同 playlistBarNarrow
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
              // 栏底起排（静置位与旧 contentStartOffset 等值），滚动时占位与条目
              // 一起从沉浸材质下方穿过。
              // 头部区已钉顶（固定栏），占位后的列表只装曲目行：ForEach 的
              // index 是已揭示切片内下标（0 起，对应第一首曲目），TrackItem.entranceIndex 不受影响。
              ListItem() {
                // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              // 条目渲染（SearchPage 同款）：@State tracks 切片数组直接驱动 ForEach。
              // 长按拖动排序（2026-10-22）：ForEach.onMove 是官方推荐路线（系统自带
              // 浮起/让位动画 + 拖到列表边缘自动滚动；List.onItemDragStart 路线拖到
              // 边缘不滚动，见 list.d.ts 注释）。onMove 下标限定在 ForEach 数据
              //（this.tracks 切片）内，自动避开首尾占位/状态条目；系统只在**松手后**
              // 回调一次，落库与刷新见 onTrackMove。
              // 收藏夹镜像禁用：canReorder() 为 false 时传 undefined = 不注册，
              // 长按不浮起（顺序由 B 站服务端决定，完整同步会覆盖手动顺序）。
              //
              // 横屏宽屏（2026-10-23 两列改造）：不可排序歌单条目配对，每个
              // ListItem 左右两列；可排序歌单（isTwoCol() 已含 !canReorder 门控）
              // 走单列 + onMove，拖动排序不受影响。
              if (this.isTwoCol()) {
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
                          moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                        }).layoutWeight(1)
                        if (pair.second !== null) {
                          TrackItem({
                            track: pair.second,
                            entranceIndex: pIndex * 2 + 1,
                            downloaded: this.isDownloaded(pair.second),
                            onPlay: (tr: Track): void => {
                              this.player.playOrToggle(tr);
                            },
                            moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
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
                        // 已下载徽标（2026-10-08）：读 @State downloadedIds，
                        // 下载完成的快照到达时可见行局部刷新出徽标（保留节点读
                        // @State 是活的，与下载页「正在播放」同一机制）
                        downloaded: this.isDownloaded(t),
                        onPlay: (tr: Track): void => {
                          this.player.playOrToggle(tr);
                        },
                        moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                      })
                    }
                  },
                  (t: Track): string => t.id
                )
                  .onMove(this.canReorder()
                    ? (from: number, to: number): void => {
                      this.onTrackMove(from, to);
                    }
                    : undefined)
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
            // 边界回弹（2026-10-08）：到顶/到底的反馈动效
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            // 列表末端常规留白 + 前端切片上拉加载（SearchPage 排行榜页签同款）。
            .contentEndOffset(CONTENT_END_OFFSET)
            .onReachEnd((): void => {
              this.onReachEnd();
            })
            // [任务③·推广二级页] 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已应用
            // 后回调，onWillScroll 是应用前，快滑时差一帧会让模糊层滞后一跳）。
            .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
              this.syncTopBlurProgress();
            })
            .onScrollStop((): void => {
              // Idle 校准终态（用户方案 ②）：兜住 Fling 期丢帧 / 死区过滤累计的偏差。
              this.syncTopBlurProgress();
            })
            // 顶部 HDS 标题栏让位（Sumy 式穿透）：由 List 首个空白占位 ListItem 负责
            //（见上方占位注释，下载页同款），不再使用 contentStartOffset。
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
        // 滚动时曲目从头部材质下穿过；底部不做避让，沉浸到底（2026-10-14 与
        // 关注/最近页同口径，见目的地链上的 ignoreLayoutSafeArea 声明）。
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给内容列挂上限即可。
        // 横屏宽屏（2026-10-23 两列改造）：上限放宽到 840vp；可排序歌单
        //（isTwoCol() 含 !canReorder 门控，恒单列）维持原收窄值。
        .constraintSize({ maxWidth: this.isTwoCol()
          ? BreakpointConstants.CONTENT_MAX_WIDTH_TWOCOL
          : BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })

        // [任务③·推广二级页] 顶栏渐变模糊层：盖内容列之上（z 序低于 HDS
        // titleBar，歌单头部区属标题栏 bottomBuilder、随整栏一起盖），进度由
        // 列表 onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏（批 1 样板同款，真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // 2026-10-23 平板模式宽度适配：stackBuilder / bottomBuilder 均走收窄容器
    //（playlistBarNarrow / playlistHeaderAreaNarrow），标题行与歌单头部区和
    // 曲目列同宽对齐（原「标题栏宽度跟随本页内容列」为不实声称，本轮根治）。
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
    // 返回键（2026-10-24 返回键避开状态栏整改）：自绘键已从 NavTitleRow 移除，
    // 改用 HDS 默认返回键（"<" 系统样式，位置由 HDS 管理以避开状态栏）。
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截（2026-10-24 二级页播放页返回修复）：播放页 overlay 打开时
    // 吞掉返回并发收起请求（留在本页），否则走默认 pop —— 详见 utils/SubPageBackPress。
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让（2026-10-14）：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由顶部占位条目 / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets，2026-10-17 启动优化）：
 * Index 已不再静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function PlaylistDetailBuilder(): void {
  PlaylistDetail()
}


/** 懒加载注册表预包装（2026-10-17）：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const PlaylistDetailWrapped: WrappedBuilder<[]> = wrapBuilder(PlaylistDetailBuilder);

