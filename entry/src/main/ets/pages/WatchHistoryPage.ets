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
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { stripHtmlTags, toThumbUrl, toHttpsUrl } from '../utils/TextUtil';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  CapsuleSegmentButtonV2,
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
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';

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

/** 顶栏滚动模糊时机（2026-10-09 全站定档）：滚动 0~30vp 完全透明 → 30~80vp 材质渐变 → >80vp 满强度 */
const HISTORY_BLUR_START_VP: number = 30;
const HISTORY_BLUR_END_VP: number = 80;

/** 秒 → `m:ss`（超一小时 `h:mm:ss`）；非正数返回空串表示「没有时长」 */
function formatProgress(seconds: number): string {
  const total: number = Math.floor(seconds);
  if (!(total > 0)) {
    return '';
  }
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const ss: string = s < 10 ? `0${s}` : `${s}`;
  if (h > 0) {
    return `${h}:${mm}:${ss}`;
  }
  return `${m}:${ss}`;
}

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
  /** 下一页游标（0 = 没有更多） */
  private cursor: number = 0;
  /** 历史页签是否已成功加载过（页签来回切换不重复请求） */
  private historyLoaded: boolean = false;

  // ── 稍后再看页签数据 ──
  @State toviewItems: BiliToViewItem[] = [];
  private toviewSource: ArrayDataSource<BiliToViewItem> = new ArrayDataSource<BiliToViewItem>([]);
  /** 稍后再看是否已成功加载过（首次切换才请求） */
  private toviewLoaded: boolean = false;

  // ── 加入歌单选择弹层（与 SearchPage 同款） ──
  @State showPlaylistPicker: boolean = false;
  @State playlistOptions: Playlist[] = [];
  @State pickerTrack: Track | null = null;

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

  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 段切换行 44。
   * 标题行与 bottomBuilder 段切换行高度均为定值且段切换行恒在（含未登录空态），
   * 无需实测——contentStartOffset 挂载即拿到正确让位量（旧 onAreaChange 实测机制已废弃）。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + HISTORY_TABS_ROW_HEIGHT;
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
        const merged: BiliHistoryItem[] = [...this.historyItems, ...data.list];
        this.historyItems = merged;
        this.historySource.reload(merged);
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
      return `看到 ${formatProgress(item.progress)}`;
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

  /** 「⋮」标准菜单项（阶段 2 迁移：自绘菜单弹窗 → bindMenu + MenuElement 数组） */
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
    NavStackHolder.upMid = mid;
    NavStackHolder.upName = track.artist;
    NavStackHolder.upFace = faceUrl.length > 0 ? toThumbUrl(faceUrl, 96) : '';
    NavStackHolder.stack.pushPath({ name: 'UpSpace' });
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

  // ===== 加入歌单（与 SearchPage 同款：自动建单兜底 + 选择弹层） =====

  /** 没有任何歌单时的兜底：新建歌单并直接把这首放进去（名字取自歌名） */
  private createPlaylistAndAdd(track: Track, existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(track, existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(created.id, track);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  private openPlaylistPicker(track: Track): void {
    const options: Playlist[] = LibraryStore.getPlaylists();
    if (options.length === 0) {
      this.createPlaylistAndAdd(track, options);
      return;
    }
    this.playlistOptions = options;
    this.pickerTrack = track;
    this.showPlaylistPicker = true;
  }

  /** 弹层里的「新建歌单并加入」：省掉一次跳转 */
  private createPlaylistFromPicker(): void {
    const track: Track | null = this.pickerTrack;
    this.dismissPicker();
    if (!track) {
      return;
    }
    // 弹层打开时的快照（playlistOptions）就是用户看到的列表，重名检查基于它即可
    this.createPlaylistAndAdd(track, this.playlistOptions);
  }

  private addToPlaylist(p: Playlist): void {
    const track: Track | null = this.pickerTrack;
    this.dismissPicker();
    if (!track) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(p.id, track);
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  private dismissPicker(): void {
    this.showPlaylistPicker = false;
    this.pickerTrack = null;
  }

  // ===== 标题栏内容 =====

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 返回键 + 「观看历史」标题。材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  historyBar() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(26)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(22)
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .accessibilityText('返回')
      .accessibilityLevel('yes')
      .onClick((): void => {
        NavStackHolder.stack.pop();
      })

      Text('观看历史')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(NAV_TITLE_BAR_HEIGHT)
    // 行内边距与 AboutPage.aboutBar 完全一致（真机要求：返回键样式对齐关于页）
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载，恒配置——含未登录空态）：
   * 段切换行（观看历史 / 稍后再看，2026-10-11 按用户要求移除「播放全部」按钮）。
   * ⚠️ bottomBuilder 高度不自适应，由 titleBar 参数显式给定
   * （HISTORY_TABS_ROW_HEIGHT），行定高排布。
   */
  @Builder
  historyTabsRow() {
    Row() {
      // 段切换（观看历史 / 稍后再看）：2026-10-11 组件标准化迁移 —— 自绘
      // Stack+粉片 translate 滑块换成 CapsuleSegmentButtonV2 标准分段按钮
      // （与 SearchTabBar 同款），B 站粉经 itemSelectedBackgroundColor 覆写；
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
        // itemPadding 8×2），靠左贴近旧自绘滑块 134vp 密度。
        .width(150)
    }
    .width('100%')
    .height(HISTORY_TABS_ROW_HEIGHT)
    .padding({ left: 16, right: 16, bottom: 4 })
    .alignItems(VerticalAlign.Center)
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

      Text('⋮')
        .fontSize(22)
        .fontColor($r('app.color.text_tertiary'))
        .width(44)
        .height(44)
        .borderRadius(22)
        .textAlign(TextAlign.Center)
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

      Text(formatProgress(v.duration))
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ left: 8 })

      Text('⋮')
        .fontSize(22)
        .fontColor($r('app.color.text_tertiary'))
        .width(44)
        .height(44)
        .borderRadius(22)
        .textAlign(TextAlign.Center)
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

  /** 「加入歌单」选择弹层（遮罩 + 面板，与 SearchPage 同款） */
  @Builder
  pickerOverlay() {
    Column() {
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.scrim'))
    .onClick((): void => {
      this.dismissPicker();
    })
    .justifyContent(FlexAlign.Center)

    Column() {
      Text('加入歌单')
        .fontSize(18)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 8 })
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
                  NavStackHolder.stack.pushPath({ name: 'Login' });
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
              if (this.tab === TAB_HISTORY) {
                LazyForEach(
                  this.historySource,
                  (item: BiliHistoryItem): void => {
                    ListItem() {
                      this.historyRow(item)
                    }
                  },
                  (item: BiliHistoryItem): string => `${item.history.bvid}_${item.view_at}`
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
              if (this.loadingMore) {
                ListItem() {
                  Row() {
                    LoadingProgress()
                      .width(18)
                      .height(18)
                      .color($r('app.color.text_tertiary'))
                    Text('加载中…')
                      .fontSize(12)
                      .fontColor($r('app.color.text_tertiary'))
                      .margin({ left: 8 })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                  .padding({ top: 12, bottom: 12 })
                }
              } else if (this.tab === TAB_HISTORY && !this.hasMore) {
                ListItem() {
                  Text('没有更多了')
                    .fontSize(11)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 12, bottom: 12 })
                }
              }
            }
            .layoutWeight(1)
            // 边界回弹：到顶/到底的反馈动效
            .edgeEffect(EdgeEffect.Spring)
            // 顶部让位（Sumy 式穿透）：列表视口铺满全屏，首行从 HDS 标题栏底部起排
            .contentStartOffset(this.barTotalHeight())
            .onReachEnd((): void => {
              this.loadHistoryMore();
            })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // ⚠️ 不整体 padding top / safeAreaPadding bottom：列表视口铺满全屏并直接
        // 扩展进底部安全区（2026-10-09：不做底部避让，沉浸到底）
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })

        // 「加入歌单」选择弹层：盖在标题栏之上
        if (this.showPlaylistPicker) {
          this.pickerOverlay()
        }
      }
    }
    // HDS 沉浸光感标题栏（批 1 样板同款，真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(HISTORY_BLUR_START_VP, HISTORY_BLUR_END_VP),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：返回键 + 标题
        stackBuilder: (): void => {
          this.historyBar();
        },
        // 标题行下方自定义区：段切换行（观看历史 / 稍后再看 + 播放全部），恒配置——
        // 含未登录空态（「去登录」按钮也在段切换行下方的空态里，段切换本身恒可见）。
        // ⚠️ 段切换行不能塞进 stackBuilder（会溢出 56vp 标题行、与列表内容重叠，
        // 真机复现），必须走 bottomBuilder 显式高度。
        bottomBuilder: {
          builder: (): void => {
            this.historyTabsRow();
          },
          height: HISTORY_TABS_ROW_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 内容避让（2026-10-14）：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由 contentStartOffset / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}
