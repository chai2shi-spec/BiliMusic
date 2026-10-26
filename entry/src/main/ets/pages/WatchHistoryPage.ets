/**
 * 观看历史页（站内）：拉取登录用户的 B 站**真实观看历史**与**稍后再看**
 * （「设置 → 账户 → 观看历史与稍后再看」）。
 *
 * 两个页签共用一页：
 *  · 「观看历史」走 `/x/web-interface/history/cursor` 游标分页（business=archive
 *    只取普通视频），行内显示「看到 x:xx / 已看完」与相对时间；
 *  · 「稍后再看」走 `/x/v2/history/toview/web` 一次性列表，懒加载（首次切换才请求）。
 *
 * 条目即音源：行点击直接播放（历史条目带上 `history.cid`，多 P 视频能定位到
 * 上次看过的分 P）；「⋯」菜单与搜索页同款（加入队列 / 加入歌单 / 下载 / 进 UP 主页）。
 *
 * 骨架照 FollowsPage：登录自检 + STORE_LOGIN_REV 版本号 @Watch（去登录返回后补拉）、
 * 骨架屏 / 失败态（风控码人话 + 4s 重试冷却）、LazyForEach + ArrayDataSource、
 * HDS 沉浸光感标题栏（定值让位 barTotalHeight + 列表挂载门控）、customTransition 子页转场。
 */

import {
  BiliApiError,
  BiliHistoryData,
  BiliHistoryItem,
  BiliToViewItem,
  getToView,
  getWatchHistory
} from '../api/BilibiliApi';
import { getLoginUser, LoginUser } from '../service/LoginStore';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam } from '../service/NavRouteParams';
import { LibraryStore } from '../service/LibraryStore';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../service/DownloadManager';
import { MusicPlayer } from '../player/MusicPlayer';
import { Playlist, Track, buildTrack } from '../model/MusicModels';
import { CoverImage } from '../components/CoverImage';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { showAppToast } from '../components/AppToast';
import { showConfirm } from '../components/AppAlertDialog';
import { stripHtmlTags, toThumbUrl, toHttpsUrl, formatDurationText } from '../utils/TextUtil';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  CapsuleSegmentButtonV2,
  CustomContentDialog,
  LengthMetrics,
  SegmentButtonV2Items
} from '@kit.ArkUI';
import {
  ButtonMaterialModifier,
  makeBiliSegmentColors,
  makeButtonMaterialModifier,
  SegmentColors
} from '../utils/HeaderBarMaterial';
import {
  STORE_LOGIN_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_DEEP,
  STORE_THEME_ON
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  PairOf,
  PairDataSource,
  TWO_COL_GAP_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import {
  NAV_TRANSITION_MS,
  BUTTON_RADIUS_VP,
  LIST_FOOTER_HEIGHT_VP
} from '../common/constants/InteractionConstants';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/** 失败后「重试」的冷却（ms）：历史接口与 followings 同属风控敏感区，连点只会继续被拒 */
const RETRY_COOLDOWN_MS: number = 4000;

/** 历史游标分页每页条数（服务端上限 30，留余量） */
const HISTORY_PAGE_SIZE: number = 20;

/** 页签下标（刻意用数字常量而不是 enum：.ets 里声明 enum 会连带报 SDK 解析错误） */
const TAB_HISTORY: number = 0;
const TAB_TOVIEW: number = 1;

/**
 * 标题栏段切换行（观看历史 / 稍后再看 + 播放全部）固定高：
 * 段切换 Column 40 + 行 padding bottom 4 = 44。
 * bottomBuilder 高度不自适应（官方约束），必须与行内容定高一致。
 */
const HISTORY_TABS_ROW_HEIGHT: number = 44;

/** 秒级时间戳 → 相对时间（刚刚 / x分钟前 / x小时前 / x天前，超 30 天给日期） */
function relativeTime(tsSeconds: number): string {
  if (tsSeconds <= 0) {
    return '';
  }
  const diff: number = Math.floor(Date.now() / 1000) - tsSeconds;
  if (diff < 60) {
    return '刚刚';
  }
  if (diff < 3600) {
    return `${Math.floor(diff / 60)}分钟前`;
  }
  if (diff < 86400) {
    return `${Math.floor(diff / 3600)}小时前`;
  }
  if (diff < 86400 * 30) {
    return `${Math.floor(diff / 86400)}天前`;
  }
  return new Date(tsSeconds * 1000).toISOString().slice(0, 10);
}

@Component
export struct WatchHistoryPage {
  /** 当前页签：0 = 观看历史（默认），1 = 稍后再看 */
  @State tab: number = TAB_HISTORY;
  /** 未登录：渲染登录引导空态（不发请求） */
  @State needLogin: boolean = false;
  /** 当前页签首屏加载中（骨架屏） */
  @State loading: boolean = false;
  /** 历史页签翻页加载中（列表底部「加载中…」） */
  @State loadingMore: boolean = false;
  /** 当前页签首屏是否失败（空态区分「没记录」与「拉不到」） */
  @State loadFailed: boolean = false;
  /** 失败原因（人话，含 code：该等风控过去还是该换网络） */
  @State failReason: string = '';
  /** 历史页签还有没有下一页 */
  @State hasMore: boolean = false;
  /** 重试冷却中：按钮禁用（真正的门在 retryLocked 成员，状态只是给用户看的） */
  @State retryCooling: boolean = false;
  private retryLocked: boolean = false;
  private retryTimer: number = -1;

  // ── 观看历史页签数据 ──
  @State historyItems: BiliHistoryItem[] = [];
  private historySource: ArrayDataSource<BiliHistoryItem> = new ArrayDataSource<BiliHistoryItem>([]);
  /**
   * 两列视图数据源（无状态视图）：读 historySource 现场
   * 构造 PairOf，不缓存不注册 listener —— 数据变化处显式调 historyPairs.sync()
   * （见 TwoColumnList.PairDataSource 注释）。
   */
  private historyPairs: PairDataSource<BiliHistoryItem> = new PairDataSource<BiliHistoryItem>(this.historySource);
  /** 下一页游标（0 = 没有更多） */
  private cursor: number = 0;
  /** 历史页签是否已成功加载过（页签来回切换不重复请求） */
  private historyLoaded: boolean = false;

  // ── 稍后再看页签数据 ──
  @State toviewItems: BiliToViewItem[] = [];
  private toviewSource: ArrayDataSource<BiliToViewItem> = new ArrayDataSource<BiliToViewItem>([]);
  /** 两列视图数据源（同 historyPairs，读 toviewSource 现场配对） */
  private toviewPairs: PairDataSource<BiliToViewItem> = new PairDataSource<BiliToViewItem>(this.toviewSource);
  /** 稍后再看是否已成功加载过（首次切换才请求） */
  private toviewLoaded: boolean = false;

  // ── 加入歌单弹窗（官方 CustomContentDialog，与 SearchPage 同款） ──
  @State playlistOptions: Playlist[] = [];
  @State pickerTrack: Track | null = null;
  /**
   * 「加入歌单」弹窗 controller：官方 CustomContentDialog 标准对话框
   * （默认遮罩 + 官方按钮槽，替代原根 Stack 内自绘弹层）。标题/按钮为
   * 常量 → 建一次永不重建（faqs-arkui-555 只定格构造参数，动态内容经
   * contentBuilder 闭包在 open() 时读当次状态）。
   */
  private playlistPickerController: CustomDialogController | undefined = undefined;

  /**
   * 登录态版本号：从本页「去登录」登录成功 / 退出登录时 LoginStore 会递增它，
   * @Watch 里重新查登录态并按需加载 —— aboutToAppear 只触发一次，不订阅的话
   * 「登录成功返回本页」会一直停在登录引导空态。
   */
  @StorageProp(STORE_LOGIN_REV) @Watch('onLoginRevChanged') loginRev: number = 0;
  /** 状态栏高度（vp）：自绘顶栏由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：列表末尾要自己让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;

  /** 主题色运行时值：分段按钮配色与操作按钮跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时条目两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** 横屏宽屏（窗口 ≥600vp 的横屏）时条目两列显示；竖屏 / 窄窗口单列不变 */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }

  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 段切换行 44。
   * 标题行与 bottomBuilder 段切换行高度均为定值且段切换行恒在（含未登录空态），
   * 无需实测——顶部占位条目（下载页同款）与空态 padding 直接绑定该值。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + HISTORY_TABS_ROW_HEIGHT;
  }

  /**
   * 自绘顶栏渐变模糊层进度更新器 + 校准（四页签同款）：onDidScroll /
   * onScrollStop 命令式驱动 opacity（不标 @State，滚动高频回调零重建）；
   * yOffset 0 → TITLE_BLUR_END_VP 线性映射 0 → 1（updater 内截断，
   * 边缘回弹负偏移归零 = 死区）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.listScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /** 列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 「去登录 / 重试 / 播放全部」按钮沉浸光感材质修饰器：26+ 生效，低版本 no-op 兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 段切换（观看历史 / 稍后再看）分段按钮条目：静态一次构造 */
  private segmentItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '观看历史' },
    { text: '稍后再看' }
  ]);
  /** 分段按钮主题色配色组：每次渲染现取（读 AppStorage），缓存成字段切色不刷新 */
  private segColors(): SegmentColors {
    return makeBiliSegmentColors();
  }
  private player: MusicPlayer = MusicPlayer.getInstance();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
    // 「加入歌单」弹窗：官方标准对话框，标题/按钮常量（见成员声明处注释）。
    // 关闭路径刻意不清暂存曲目：关闭有退场动画，清了会让副标题在淡出途中
    // 先变空；pickerTrack 每次打开前都会重写，残留值无消费方。
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
    this.checkLoginAndLoad();
  }

  aboutToDisappear(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut，与 FollowsPage 同款。
   * pop 出场（含侧滑返回手势）反向滑回右侧；其余场景返回 undefined 走系统默认。
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

  /** 登录态自检：未登录渲染引导空态；已登录按当前页签加载 */
  private checkLoginAndLoad(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      this.needLogin = true;
      this.loading = false;
      return;
    }
    this.needLogin = false;
    this.loadCurrentTab();
  }

  /** 按当前页签加载首屏（已成功加载过的页签直接展示缓存，不重复请求） */
  private loadCurrentTab(): void {
    if (this.tab === TAB_HISTORY) {
      this.loadHistoryFirst();
    } else {
      this.loadToview();
    }
  }

  /** 观看历史首页（max=0）；失败态由 loadFailed 承载 */
  private async loadHistoryFirst(): Promise<void> {
    if (this.loading || this.loadingMore || this.historyLoaded) {
      return;
    }
    this.loading = true;
    this.loadFailed = false;
    this.failReason = '';
    this.cursor = 0;
    try {
      const data: BiliHistoryData = await getWatchHistory(0, HISTORY_PAGE_SIZE);
      this.historyItems = data.list;
      this.historySource.reload(data.list);
      // 两列视图同步：横屏 LazyForEach 读 historyPairs，reload 后必须显式通知
      this.historyPairs.sync();
      this.cursor = data.cursorMax;
      this.hasMore = data.list.length > 0 && data.cursorMax > 0;
      this.historyLoaded = true;
      console.info(`watch history first load: ${data.list.length}, cursor=${data.cursorMax}`);
    } catch (err) {
      this.loadFailed = true;
      this.failReason = this.humanizeError(err);
      console.error(`watch history first load failed: ${JSON.stringify(err)}`);
    } finally {
      this.loading = false;
    }
  }

  /** 观看历史翻页：用上一页返回的 cursor 续拉，滚动到底触发 */
  private async loadHistoryMore(): Promise<void> {
    if (this.tab !== TAB_HISTORY || this.needLogin || this.loading
      || this.loadingMore || !this.hasMore) {
      return;
    }
    this.loadingMore = true;
    const reqCursor: number = this.cursor;
    try {
      const data: BiliHistoryData = await getWatchHistory(reqCursor, HISTORY_PAGE_SIZE);
      this.cursor = data.cursorMax;
      // 三重终止闸门：返回空页 / 游标归零 / 游标原地踏步（防死循环）
      this.hasMore = data.list.length > 0 && data.cursorMax > 0 && data.cursorMax !== reqCursor;
      if (data.list.length > 0) {
        // 增量追加：镜像数组 push + historySource.append 只发 onDataAdd，
        // 避免整表 reload（onDataReloaded 让可视区节点失效重建、锚点重算）。
        for (let i = 0; i < data.list.length; i++) {
          this.historyItems.push(data.list[i]);
        }
        this.historySource.append(data.list);
        // 两列视图同步：追加后配对数变化，显式整表通知（末尾按需重建，粒度同 reload）
        this.historyPairs.sync();
      }
    } catch (err) {
      // 翻页失败不切失败态（首屏数据还在可看），提示一句即可
      console.warn(`watch history load more failed: ${JSON.stringify(err)}`);
      this.toast('加载更多失败，稍后再试', 1800);
    } finally {
      this.loadingMore = false;
    }
  }

  /** 稍后再看首屏（一次性列表，无分页）；已加载过则直接展示缓存 */
  private async loadToview(): Promise<void> {
    if (this.loading || this.loadingMore || this.toviewLoaded) {
      return;
    }
    this.loading = true;
    this.loadFailed = false;
    this.failReason = '';
    try {
      const list: BiliToViewItem[] = await getToView();
      this.toviewItems = list;
      this.toviewSource.reload(list);
      // 两列视图同步（同 historyPairs）
      this.toviewPairs.sync();
      this.toviewLoaded = true;
      console.info(`toview load: ${list.length}`);
    } catch (err) {
      this.loadFailed = true;
      this.failReason = this.humanizeError(err);
      console.error(`toview load failed: ${JSON.stringify(err)}`);
    } finally {
      this.loading = false;
    }
  }

  /** 段切换：重置失败态后按需加载目标页签（缓存不丢，来回切不重复请求） */
  private switchTab(target: number): void {
    if (this.tab === target || this.needLogin || this.loading) {
      return;
    }
    this.tab = target;
    this.loadFailed = false;
    this.failReason = '';
    this.loadCurrentTab();
  }

  /** 重试（带 4s 冷却防风控连点）：只强制重拉**当前**页签 */
  private retry(): void {
    if (this.retryLocked) {
      return;
    }
    this.retryLocked = true;
    this.retryCooling = true;
    this.retryTimer = setTimeout((): void => {
      this.retryLocked = false;
      this.retryCooling = false;
      this.retryTimer = -1;
    }, RETRY_COOLDOWN_MS);
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      this.needLogin = true;
      this.loadFailed = false;
      return;
    }
    if (this.tab === TAB_HISTORY) {
      this.historyLoaded = false;
    } else {
      this.toviewLoaded = false;
    }
    this.loadCurrentTab();
  }

  private onLoginRevChanged(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      // 退出登录：清数据回登录引导态（防止残留上一账号的观看记录）
      this.needLogin = true;
      this.loading = false;
      this.loadingMore = false;
      this.loadFailed = false;
      this.failReason = '';
      this.tab = TAB_HISTORY;
      this.historyItems = [];
      this.toviewItems = [];
      this.historySource.reload([]);
      this.toviewSource.reload([]);
      // 两列视图同步：清空后配对视图归零
      this.historyPairs.sync();
      this.toviewPairs.sync();
      this.cursor = 0;
      this.hasMore = false;
      this.historyLoaded = false;
      this.toviewLoaded = false;
      return;
    }
    if (this.needLogin) {
      // 从本页「去登录」成功返回：补拉首屏
      this.checkLoginAndLoad();
    }
  }

  /** 错误 → 人话：-101 是登录失效（重试没用，该重新登录）；风控码该等；其余按网络问题报 */
  private humanizeError(err: Object): string {
    if (err instanceof BiliApiError) {
      if (err.code === -101) {
        return '登录态已失效，请退出登录后重新登录';
      }
      return `拉取失败（code ${err.code}），B 站接口可能风控中，稍等片刻再试`;
    }
    return '网络异常，请检查网络后重试';
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  // ===== 条目 → 可播放曲目 =====

  /** 历史条目标题：分 P 视频把分 P 名拼在后面，帮用户区分同一投稿的不同分 P */
  private historyTitle(item: BiliHistoryItem): string {
    const base: string = stripHtmlTags(item.title);
    const part: string = stripHtmlTags(item.show_title);
    return part.length > 0 ? `${base} · ${part}` : base;
  }

  /** 观看进度 → 行内文案：看完 / 看到 x:xx / 刚开始看 */
  private progressText(item: BiliHistoryItem): string {
    if (item.progress < 0 || (item.duration > 0 && item.progress >= item.duration)) {
      return '已看完';
    }
    if (item.progress > 0) {
      return `看到 ${formatDurationText(item.progress)}`;
    }
    return '刚开始看';
  }

  private historyToTrack(item: BiliHistoryItem): Track {
    return buildTrack({
      id: item.history.bvid,
      bvid: item.history.bvid,
      aid: String(item.history.oid),
      // 历史记录的是「看过的那个分 P」的 cid：带上它，播放内核能直接定位到该分 P
      cid: item.history.cid > 0 ? String(item.history.cid) : '',
      title: this.historyTitle(item),
      artist: item.author_name,
      upMid: String(item.author_mid),
      coverUrl: toHttpsUrl(item.cover),
      duration: item.duration
    });
  }

  private toviewToTrack(v: BiliToViewItem): Track {
    return buildTrack({
      id: v.bvid,
      bvid: v.bvid,
      aid: String(v.aid),
      title: stripHtmlTags(v.title),
      artist: v.owner.name,
      upMid: String(v.owner.mid),
      coverUrl: toHttpsUrl(v.pic),
      duration: v.duration
    });
  }

  // ===== 「⋯」菜单（与搜索页同款四项） =====

  /** 「⋮」菜单项：bindMenu + MenuElement 数组 */
  private trackMenuItems(track: Track, faceUrl: string): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          this.toast('已加入播放队列', 1500);
        }
      },
      {
        value: '加入歌单',
        action: (): void => {
          this.openPlaylistPicker(track);
        }
      },
      {
        value: '下载',
        action: (): void => {
          this.startDownload(track);
        }
      },
      {
        value: '进入 UP 主主页',
        action: (): void => {
          this.openUpSpace(track, faceUrl);
        }
      }
    ];
  }

  /** 「进入 UP 主主页」→ 站内页（UpSpacePage）；头像顺手传过去当首帧占位 */
  private openUpSpace(track: Track, faceUrl: string): void {
    const mid: string = track.upMid;
    if (mid.length === 0 || mid === '0') {
      this.toast('这条没有 UP 主信息', 1500);
      return;
    }
    NavStackHolder.stack.pushPathByName('UpSpace',
      new UpSpaceRouteParam(mid, track.artist, faceUrl.length > 0 ? toThumbUrl(faceUrl, 96) : ''));
  }

  // ===== 下载链（与 SearchPage / PlaylistDetail 同一套） =====

  private startDownload(track: Track): void {
    this.requestDownload(track, false);
  }

  /**
   * 发起下载。分 P 合集会在内核里被展开成多条任务（见 DownloadManager.requestDownload），
   * 所以要把「排上几首 / 跳过几首」都告诉用户。
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

  /** 把下载请求结果翻译成人话：0 条 / 1 条 / N 条要分开说 */
  private downloadResultText(r: DownloadStartResult): string {
    if (r.queued === 0) {
      return r.skipped > 0 ? '该歌曲已在下载列表中' : '没有可下载的曲目';
    }
    const head: string = r.queued > 1 ? `已开始下载 ${r.queued} 首` : '已开始下载';
    const tail: string = r.skipped > 0 ? `（另有 ${r.skipped} 首已在列表中）` : '';
    return `${head}，可在「下载」页查看进度${tail}`;
  }

  /** 「仅 WiFi 下载」被拦下：先问一句，同意后整批放行 */
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

  // ===== 加入歌单（与 SearchPage 同款：自动建单兜底 + 选择弹层） =====

  /** 没有任何歌单时的兜底：新建歌单并直接把这首放进去（名字取自歌名） */
  private createPlaylistAndAdd(track: Track, existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(track, existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(created.id, track);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  private openPlaylistPicker(track: Track): void {
    const options: Playlist[] = LibraryStore.getAddablePlaylists();
    if (options.length === 0) {
      this.createPlaylistAndAdd(track, options);
      return;
    }
    this.playlistOptions = options;
    this.pickerTrack = track;
    this.playlistPickerController?.open();
  }

  /** 弹层里的「新建歌单并加入」：省掉一次跳转 */
  private createPlaylistFromPicker(): void {
    const track: Track | null = this.pickerTrack;
    this.playlistPickerController?.close();
    if (!track) {
      return;
    }
    // 弹层打开时的快照（playlistOptions）就是用户看到的列表，重名检查基于它即可
    this.createPlaylistAndAdd(track, this.playlistOptions);
  }

  private addToPlaylist(p: Playlist): void {
    const track: Track | null = this.pickerTrack;
    this.playlistPickerController?.close();
    if (!track) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(p.id, track);
    // 双向收藏夹拦截提示：非 B 站曲目被 store 过滤时明确告知而非「已加入」
    //（被滤时 addTrackToPlaylist 仍返回歌单对象）
    const skipped: number = LibraryStore.consumeFavMirrorSkippedCount();
    if (updated !== null && skipped > 0) {
      this.toast(`「${p.name}」是双向同步收藏夹，仅支持添加 B 站曲目`, 2200);
      return;
    }
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  // ===== 标题栏内容 =====

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 「观看历史」标题（返回键为 HDS 默认键）。材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  historyBar() {
    NavTitleRow({ title: '观看历史' })
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载，恒配置——含未登录空态）：
   * 段切换行（观看历史 / 稍后再看）。
   * ⚠️ bottomBuilder 高度不自适应，由 titleBar 参数显式给定
   * （HISTORY_TABS_ROW_HEIGHT），行定高排布。
   */
  @Builder
  historyTabsRow() {
    Row() {
      // 段切换（观看历史 / 稍后再看）：CapsuleSegmentButtonV2 标准分段按钮
      //（与 SearchTabBar 同款），B 站粉经 itemSelectedBackgroundColor 覆写；
      // selectedIndex 由 this.tab 重算，点击 → onItemClicked → switchTab
      // （内含切换守卫与按需懒加载）。
      CapsuleSegmentButtonV2({
        items: this.segmentItems,
        selectedIndex: this.tab,
        onItemClicked: (index: number): void => {
          this.switchTab(index);
        },
        itemSelectedBackgroundColor: this.segColors().selectedBg,
        itemSelectedFontColor: this.segColors().selectedFont,
        itemSelectedFontWeight: FontWeight.Medium,
        itemFontColor: this.segColors().unselectedFont,
        itemFontWeight: FontWeight.Normal,
        itemFontSize: LengthMetrics.vp(13),
        itemSelectedFontSize: LengthMetrics.vp(13),
        buttonBackgroundColor: this.segColors().grooveBg,
        buttonBorderRadius: LengthMetrics.vp(BUTTON_RADIUS_VP),
        itemBorderRadius: LengthMetrics.vp(6),
        // 内部背板最小高度默认系统 token（约 36vp）会盖过外层 .height(32)
        // （真机验收：与搜索框/按钮高度不一致），对齐到 32
        buttonMinHeight: LengthMetrics.vp(32),
        // 紧凑内边距：系统默认 start/end 16vp（padding_level4）空气感过强
        // （真机验收「留空太多」），收到 8vp
        itemPadding: { start: LengthMetrics.vp(8), end: LengthMetrics.vp(8) }
      })
        .height(32)
        // ⚠️ V2 分段按钮测量特性：给多大渲染多大（均摊到各段），不会内容自适应
        // —— 宽度显式收紧到 150vp（背板 padding 4×2 + 两段 4 字文案 52 +
        // itemPadding 8×2）。
        .width(150)
    }
    .width('100%')
    .height(HISTORY_TABS_ROW_HEIGHT)
    .padding({ left: 16, right: 16, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 标题行收窄容器：HDS titleBar 的 stackBuilder
   * 横跨目的地整列全宽，而本页条目内容列被 constraintSize 收窄居中 —— 大屏上
   * 标题行会贴到整列左缘、与居中条目错位。外层 Row 居中 + 内层 Column
   * constraintSize（上限与本页内容列完全同口径），标题行与条目列同宽对齐；
   * 两侧空白区 hitTestBehavior(Transparent) 穿透点击。
   * sm 回退 600（窗口 <600vp）天然无操作，手机零变化。
   */
  @Builder
  historyBarNarrow() {
    Row() {
      Column() {
        this.historyBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 段切换行收窄容器：同 historyBarNarrow 口径 ——
   * bottomBuilder 也横跨整列全宽，收窄后段切换行与本页条目列同宽对齐；
   * bottomBuilder 显式高度（HISTORY_TABS_ROW_HEIGHT）不动。sm 天然无操作。
   */
  @Builder
  historyTabsRowNarrow() {
    Row() {
      Column() {
        this.historyTabsRow()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 一条观看历史行：封面 + 标题（UP · 进度）+ 相对时间 + 「⋯」 */
  @Builder
  historyRow(item: BiliHistoryItem) {
    Row() {
      CoverImage({
        url: toThumbUrl(item.cover, 96),
        imgWidth: 48,
        imgHeight: 48,
        imgRadius: 8,
        altText: item.title
      })

      Column() {
        Text(this.historyTitle(item))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${item.author_name} · ${this.progressText(item)}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      Text(relativeTime(item.view_at))
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ left: 8 })

      Row() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.text_tertiary')])
      }
        .width(44)
        .height(44)
        .borderRadius(22)
        .justifyContent(FlexAlign.Center)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .accessibilityText('更多操作')
        .accessibilityLevel('yes')
        .bindMenu(this.trackMenuItems(this.historyToTrack(item), item.author_face))
    }
    .width('100%')
    .padding({ left: 16, right: 4, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(`${this.historyTitle(item)}，${this.progressText(item)}，${relativeTime(item.view_at)}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.player.playOrToggle(this.historyToTrack(item));
    })
  }

  /** 一条稍后再看行：封面 + 标题（UP · 分 P 数）+ 时长 + 「⋯」 */
  @Builder
  toviewRow(v: BiliToViewItem) {
    Row() {
      CoverImage({
        url: toThumbUrl(v.pic, 96),
        imgWidth: 48,
        imgHeight: 48,
        imgRadius: 8,
        altText: v.title
      })

      Column() {
        Text(stripHtmlTags(v.title))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(v.count > 1 ? `${v.owner.name} · ${v.count} 个分P` : v.owner.name)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      Text(formatDurationText(v.duration))
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ left: 8 })

      Row() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.text_tertiary')])
      }
        .width(44)
        .height(44)
        .borderRadius(22)
        .justifyContent(FlexAlign.Center)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .accessibilityText('更多操作')
        .accessibilityLevel('yes')
        .bindMenu(this.trackMenuItems(this.toviewToTrack(v), v.owner.face))
    }
    .width('100%')
    .padding({ left: 16, right: 4, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(`${stripHtmlTags(v.title)}，${v.owner.name}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.player.playOrToggle(this.toviewToTrack(v));
    })
  }

  /**
   * 「加入歌单」弹窗正文（官方 CustomContentDialog，与 SearchPage 同款）。
   * 标题在 primaryTitle；取消在 buttons 槽（自动关闭）。
   */
  @Builder
  PlaylistPickerBody(): void {
    Column() {
      Text(this.pickerTrack ? this.pickerTrack.title : '')
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
                this.addToPlaylist(p);
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
        // 内容层：五态互斥（登录引导 / 骨架屏 / 失败态 / 空态 / 列表）
        Column() {
          if (this.needLogin) {
            Column() {
              Text('登录后才能查看观看历史')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
              Text('与 B 站网页版共用同一份登录态，凭据只保存在本机')
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 8 })
              Button('去登录', { type: ButtonType.Normal })
                .fontSize(13)
                .height(32)
                .borderRadius(BUTTON_RADIUS_VP)
                .backgroundColor(this.themePrimary)
                .fontColor(this.themeOn)
                .attributeModifier(this.buttonMaterial)
                .margin({ top: 20 })
                .onClick((): void => {
                  NavStackHolder.stack.pushPathByName('Login', undefined);
                })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          } else if (this.loading) {
            // 骨架屏：行数取一页的一半即可示意（与 FollowsPage 同思路）
            Column() {
              SkeletonTrackItem()
              SkeletonTrackItem()
              SkeletonTrackItem()
              SkeletonTrackItem()
              SkeletonTrackItem()
              SkeletonTrackItem()
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ top: this.barTotalHeight() })
          } else if (this.loadFailed) {
            Column() {
              Text('观看记录拉取失败')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
              Text(this.failReason)
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
              Button(this.retryCooling ? '稍候重试' : '重试', { type: ButtonType.Normal })
                .fontSize(13)
                .height(32)
                .borderRadius(BUTTON_RADIUS_VP)
                .backgroundColor(this.themePrimary)
                .fontColor(this.themeOn)
                .attributeModifier(this.buttonMaterial)
                .enabled(!this.retryCooling)
                .opacity(this.retryCooling ? 0.5 : 1)
                .margin({ top: 20 })
                .onClick((): void => {
                  this.retry();
                })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          } else if ((this.tab === TAB_HISTORY
            ? this.historyItems.length : this.toviewItems.length) === 0) {
            Column() {
              if (this.tab === TAB_HISTORY) {
                Text('还没有观看记录')
                  .fontSize(16)
                  .fontColor($r('app.color.text_secondary'))
                Text('去 B 站看些视频，最近看过的会出现在这里')
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 8 })
              } else {
                Text('稍后再看列表是空的')
                  .fontSize(16)
                  .fontColor($r('app.color.text_secondary'))
                Text('在 B 站 App 里点「稍后再看」的视频会出现在这里')
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 8 })
              }
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
            // 列表挂载门控：让位量为定值计算（safeTop 启动即有），挂载即正确
          } else if (this.barTotalHeight() > 0) {
            List({ scroller: this.listScroller }) {
              // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在
              // 屏幕顶端（y=0）。占位高度 = 标题栏总让位量（barTotalHeight：
              // safeTop + 56 + 段切换行 44），首个真实条目恰从栏底起排，
              // 滚动时占位与条目一起从沉浸材质下方穿过。
              ListItem() {
                // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              if (this.tab === TAB_HISTORY) {
                // 横屏宽屏：historyRow 配对两列（左右槽各渲染一次，
                // 行内按压/菜单/点击状态按行独立）；占位与尾部状态条保持整行宽。
                if (this.isTwoCol()) {
                  LazyForEach(
                    this.historyPairs,
                    (pair: PairOf<BiliHistoryItem>): void => {
                      ListItem() {
                        Row() {
                          Column() {
                            this.historyRow(pair.first)
                          }
                          .layoutWeight(1)
                          if (pair.second !== null) {
                            Column() {
                              this.historyRow(pair.second)
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
                    (pair: PairOf<BiliHistoryItem>): string =>
                      `${pair.first.history.bvid}_${pair.first.view_at}` +
                      `|${pair.second !== null
                        ? `${pair.second.history.bvid}_${pair.second.view_at}`
                        : 'x'}`
                  )
                } else {
                  LazyForEach(
                    this.historySource,
                    (item: BiliHistoryItem): void => {
                      ListItem() {
                        this.historyRow(item)
                      }
                    },
                    (item: BiliHistoryItem): string => `${item.history.bvid}_${item.view_at}`
                  )
                }
              } else {
                // 稍后再看页签：同观看历史页签的两列配对
                if (this.isTwoCol()) {
                  LazyForEach(
                    this.toviewPairs,
                    (pair: PairOf<BiliToViewItem>): void => {
                      ListItem() {
                        Row() {
                          Column() {
                            this.toviewRow(pair.first)
                          }
                          .layoutWeight(1)
                          if (pair.second !== null) {
                            Column() {
                              this.toviewRow(pair.second)
                            }
                            .layoutWeight(1)
                            .margin({ left: TWO_COL_GAP_VP })
                          } else {
                            Blank().layoutWeight(1)
                          }
                        }
                        .width('100%')
                      }
                    },
                    (pair: PairOf<BiliToViewItem>): string =>
                      `${pair.first.bvid}|${pair.second !== null ? pair.second.bvid : 'x'}`
                  )
                } else {
                  LazyForEach(
                    this.toviewSource,
                    (v: BiliToViewItem): void => {
                      ListItem() {
                        this.toviewRow(v)
                      }
                    },
                    (v: BiliToViewItem): string => v.bvid
                  )
                }
              }
              // 尾部状态条（常驻 + 固定高度）：只换内容不插拔条目，
              // 数据落地帧尾部 extent 只增不减，底部弹簧过滚动不被收缩强制解析。
              // 仅历史页签挂（稍后再看是一次性列表，无分页）。
              if (this.tab === TAB_HISTORY) {
                ListItem() {
                  Row() {
                    if (this.loadingMore) {
                      LoadingProgress()
                        .width(18)
                        .height(18)
                        .color($r('app.color.text_tertiary'))
                      Text('加载中…')
                        .fontSize(12)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ left: 8 })
                    } else if (!this.hasMore) {
                      Text('没有更多了')
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                    } else {
                      Text('上拉加载更多')
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                  }
                  .width('100%')
                  .height(LIST_FOOTER_HEIGHT_VP)
                  .justifyContent(FlexAlign.Center)
                }
              }
            }
            .layoutWeight(1)
            // 边界回弹：到顶/到底的反馈动效
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            // 顶部 HDS 标题栏让位（Sumy 式穿透）：由 List 首个空白占位 ListItem 负责
            //（见上方占位注释，下载页同款）。
            .onReachEnd((): void => {
              this.loadHistoryMore();
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
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // ⚠️ 不整体 padding top / safeAreaPadding bottom：列表视口铺满全屏并直接
        // 扩展进底部安全区（不做底部避让，沉浸到底）
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）；
        // 横屏宽屏两列时上限放宽到 840（CONTENT_MAX_WIDTH_TWOCOL），竖屏维持原值
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

        // 顶栏渐变模糊层：盖内容列之上（z 序低于「加入歌单」
        // 弹层、低于 HDS titleBar，段切换行属标题栏 bottomBuilder、随整栏一起盖），
        // 进度由列表 onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏（真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // 平板模式宽度适配：stackBuilder / bottomBuilder 均走收窄容器
    //（historyBarNarrow / historyTabsRowNarrow），标题行与段切换行和条目列同宽对齐。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：标题（收窄容器内；返回键为 HDS 默认键）
        stackBuilder: (): void => {
          this.historyBarNarrow();
        },
        // 标题行下方自定义区：段切换行（观看历史 / 稍后再看），恒配置——
        // 含未登录空态（「去登录」按钮也在段切换行下方的空态里，段切换本身恒可见）。
        // ⚠️ 段切换行不能塞进 stackBuilder（会溢出 56vp 标题行、与列表内容重叠，
        // 真机复现），必须走 bottomBuilder 显式高度。
        bottomBuilder: {
          builder: (): void => {
            this.historyTabsRowNarrow();
          },
          height: HISTORY_TABS_ROW_HEIGHT,
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
    // 系统返回拦截：播放页 overlay 打开时吞掉返回并发收起请求（留在本页），
    // 否则走默认 pop —— 详见 utils/SubPageBackPress。
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由顶部占位条目 / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function WatchHistoryPageBuilder(): void {
  WatchHistoryPage()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const WatchHistoryPageWrapped: WrappedBuilder<[]> = wrapBuilder(WatchHistoryPageBuilder);

